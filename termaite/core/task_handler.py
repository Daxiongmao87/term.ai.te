"""Task handler with Plan-Act-Evaluate loop for termaite."""

import re
from typing import Dict, Any, Optional, Tuple
from dataclasses import dataclass
from enum import Enum

from ..utils.logging import logger
from ..llm import create_llm_client, create_payload_builder, parse_llm_plan, parse_llm_instruction, parse_llm_decision, parse_llm_thought, parse_suggested_command, parse_llm_summary
from ..commands import create_command_executor, create_permission_manager, create_safety_checker
from ..constants import CLR_GREEN, CLR_RESET, CLR_BOLD_GREEN


class TaskStatus(Enum):
    """Task execution status."""
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"


class AgentPhase(Enum):
    """Agent execution phases."""
    PLAN = "plan"
    ACTION = "action"
    EVALUATE = "evaluate"


@dataclass
class TaskState:
    """Current state of task execution."""
    current_plan: str = ""
    current_instruction: str = ""
    plan_array: list[str] = None
    step_index: int = 0
    last_action_taken: str = ""
    last_action_result: str = ""
    user_clarification: str = ""
    last_eval_decision: str = ""
    iteration: int = 0
    
    # Agent summaries for inter-agent coordination
    planner_summary: str = ""
    actor_summary: str = ""
    evaluator_summary: str = ""
    
    def __post_init__(self):
        if self.plan_array is None:
            self.plan_array = []


class TaskHandler:
    """Handles task execution through the Plan-Act-Evaluate loop."""
    
    def __init__(self, config: Dict[str, Any], config_manager):
        """Initialize the task handler.
        
        Args:
            config: Application configuration
            config_manager: Configuration manager instance
        """
        self.config = config
        self.config_manager = config_manager
        
        # Initialize components
        self.llm_client = create_llm_client(config, config_manager)
        self.payload_builder = create_payload_builder(config, config_manager.payload_file)
        self.command_executor = create_command_executor(config.get("command_timeout", 30))
        self.permission_manager = create_permission_manager(config_manager.config_file)
        self.safety_checker = create_safety_checker()
        
        # Set command maps from config
        allowed_cmds, blacklisted_cmds = config_manager.get_command_maps()
        self.payload_builder.set_command_maps(allowed_cmds, blacklisted_cmds)
        self.permission_manager.set_command_maps(allowed_cmds, blacklisted_cmds)
        
        logger.debug("TaskHandler initialized")
    
    def handle_task(self, user_prompt: str) -> bool:
        """Handle a complete task through Plan-Act-Evaluate loop.
        
        Args:
            user_prompt: Initial user request
            
        Returns:
            True if task completed successfully, False otherwise
        """
        # Initialize task state
        state = TaskState()
        task_status = TaskStatus.IN_PROGRESS
        current_context = user_prompt
        
        # Main Plan-Act-Evaluate loop
        while task_status == TaskStatus.IN_PROGRESS:
            state.iteration += 1
            
            # Determine if we need a new plan
            needs_new_plan = (not state.current_plan or 
                            state.last_eval_decision == "REVISE_PLAN" or
                            (state.user_clarification and 
                             state.last_eval_decision in ["CLARIFY_USER", "PLANNER_CLARIFY"]))
            
            if needs_new_plan:
                task_status = self._execute_plan_phase(current_context, state)
                if task_status != TaskStatus.IN_PROGRESS:
                    break
                current_context = self._build_action_context(user_prompt, state)
            
            # Execute action phase
            if not state.current_instruction:
                logger.error("ACTION phase: No current instruction")
                task_status = TaskStatus.FAILED
                break
                
            task_status = self._execute_action_phase(current_context, state)
            if task_status != TaskStatus.IN_PROGRESS:
                break
                
            # Execute evaluation phase
            eval_context = self._build_evaluation_context(user_prompt, state)
            task_status, current_context = self._execute_evaluation_phase(eval_context, state)
        
        # Return final result
        if task_status == TaskStatus.COMPLETED:
            logger.user("Task completed successfully.")
            # Generate completion summary
            self._generate_completion_summary(user_prompt, state)
            return True
        else:
            logger.user("Task failed or was aborted.")
            return False
    
    def _execute_plan_phase(self, context: str, state: TaskState) -> TaskStatus:
        """Execute the planning phase."""
        # Get LLM response for planning
        payload = self.payload_builder.prepare_payload("plan", context)
        if not payload:
            logger.error("Failed to prepare payload for PLAN phase")
            return TaskStatus.FAILED
            
        response = self.llm_client.send_request(payload)
        if not response:
            logger.error("No response from LLM for PLAN phase")
            return TaskStatus.FAILED
            
        # Append to context for history
        self.config_manager.append_context(f"Planner Input: {context}", response)
        
        # Parse LLM response
        thought = parse_llm_thought(response)
        if thought:
            logger.plan_agent(f"[Planner Thought]: {thought}")
            
        decision = parse_llm_decision(response)
        
        # Handle clarification requests
        if decision.startswith("CLARIFY_USER:"):
            if self.config.get("allow_clarifying_questions", True):
                clarification_question = decision.split(":", 1)[1].strip()
                logger.plan_agent(f"[Planner Clarification]: {clarification_question}")
                print(f"\n{CLR_BOLD_GREEN}{clarification_question}{CLR_RESET}")
                print(f"{CLR_GREEN}Response: {CLR_RESET}", end="")
                state.user_clarification = input()
                # Return to planning with clarification
                state.last_eval_decision = "PLANNER_CLARIFY"
                state.current_plan = ""
                return TaskStatus.IN_PROGRESS
            else:
                logger.warning(f"Plan Agent attempted CLARIFY_USER when questions disabled")
                state.last_eval_decision = "REVISE_PLAN"
                state.current_plan = ""
                return TaskStatus.IN_PROGRESS
        
        # Extract plan and instruction
        state.current_plan = parse_llm_plan(response)
        state.current_instruction = parse_llm_instruction(response)
        
        # Extract planner summary for inter-agent coordination
        state.planner_summary = parse_llm_summary(response)
        if state.planner_summary:
            logger.plan_agent(f"[Planner Summary]: {state.planner_summary}")
        
        # Validate plan and instruction
        if not state.current_plan:
            logger.warning("Planner did not return a checklist")
            state.last_eval_decision = "REVISE_PLAN"
            state.current_plan = ""
            return TaskStatus.IN_PROGRESS
            
        if not state.current_instruction:
            logger.warning("Planner did not return an instruction")
            state.last_eval_decision = "REVISE_PLAN"
            state.current_plan = ""
            return TaskStatus.IN_PROGRESS
        
        # Log successful planning
        logger.plan_agent(f"[Planner Checklist]:\n{state.current_plan}")
        logger.plan_agent(f"[Next Instruction]: {state.current_instruction}")
        
        # Update state
        state.plan_array = [line.strip() for line in state.current_plan.splitlines() if line.strip()]
        state.step_index = 0
        state.user_clarification = ""
        state.last_eval_decision = ""
        
        return TaskStatus.IN_PROGRESS
    
    def _execute_action_phase(self, context: str, state: TaskState) -> TaskStatus:
        """Execute the action phase."""
        # Get LLM response for action
        payload = self.payload_builder.prepare_payload("action", context)
        if not payload:
            logger.error("Failed to prepare payload for ACTION phase")
            return TaskStatus.FAILED
            
        response = self.llm_client.send_request(payload)
        if not response:
            logger.error("No response from LLM for ACTION phase")
            return TaskStatus.FAILED
            
        # Append to context for history
        self.config_manager.append_context(f"Actor Input: {context}", response)
        
        # Parse LLM response
        thought = parse_llm_thought(response)
        if thought:
            logger.action_agent(f"[Actor Thought]: {thought}")
        
        # Extract actor summary for inter-agent coordination
        state.actor_summary = parse_llm_summary(response)
        if state.actor_summary:
            logger.action_agent(f"[Actor Summary]: {state.actor_summary}")
        
        suggested_command = parse_suggested_command(response)
        
        # Handle different types of responses
        if suggested_command:
            return self._handle_command_suggestion(suggested_command, state)
        else:
            return self._handle_text_response(response, thought, state)
    
    def _handle_command_suggestion(self, command: str, state: TaskState) -> TaskStatus:
        """Handle a command suggestion from the action agent."""
        if command == "report_task_completion":
            logger.action_agent("Received 'report_task_completion'. Signaling to Evaluator.")
            state.last_action_taken = "Internal signal: report_task_completion"
            state.last_action_result = "Action Agent determined task is complete and signaled Evaluator."
            return TaskStatus.IN_PROGRESS
        
        # Check command permissions
        operation_mode = self.config.get("operation_mode", "normal")
        allowed, reason = self.permission_manager.check_command_permission(command, operation_mode)
        
        if not allowed:
            if operation_mode == "normal":
                state.last_action_taken = f"Command '{command}' not executed."
                state.last_action_result = f"Command blocked: {reason}"
                return TaskStatus.IN_PROGRESS
            elif operation_mode in ["gremlin", "goblin"]:
                # Handle dynamic permission requests
                if operation_mode == "goblin":
                    logger.system(f"Goblin Mode: Auto-allowing command")
                    allowed = True
                else:  # gremlin mode
                    decision, perm_reason = self.permission_manager.prompt_for_permission(command, self.config, self.llm_client)
                    if decision == 0:
                        allowed = True
                    elif decision == 2:  # Cancel task
                        return TaskStatus.CANCELLED
                    else:
                        state.last_action_taken = f"Command '{command}' denied by user"
                        state.last_action_result = f"User denied permission: {perm_reason}"
                        return TaskStatus.IN_PROGRESS
        
        if allowed:
            # Confirm execution in normal mode
            if operation_mode == "normal":
                print(f"{CLR_GREEN}User:{CLR_RESET}{CLR_BOLD_GREEN} Execute? {CLR_RESET}'{command}'{CLR_BOLD_GREEN} [y/N]: {CLR_RESET}", end="")
                if input().lower() != 'y':
                    state.last_action_taken = f"Command '{command}' cancelled by user"
                    state.last_action_result = "User cancelled at confirmation"
                    return TaskStatus.IN_PROGRESS
            
            # Execute the command
            logger.system(f"Executing command: {command}")
            result = self.command_executor.execute(command)
            
            state.last_action_taken = f"Executed command: {command}"
            state.last_action_result = f"Exit Code: {result.exit_code}. Output:\n{result.output or '(no output)'}"
            
            logger.system(f"Command result: {state.last_action_result}")
        
        return TaskStatus.IN_PROGRESS
    
    def _handle_text_response(self, response: str, thought: str, state: TaskState) -> TaskStatus:
        """Handle a text response (question/statement) from the action agent."""
        import re
        
        # Extract the actual response text (removing all think tags)
        text_response = re.sub(r'<think>.*?</think>', '', response, flags=re.DOTALL).strip()
        
        if not text_response:
            logger.warning("Actor: no command and no textual response/question")
            state.last_action_taken = "Actor: no command and no question"
            state.last_action_result = f"Actor LLM response empty or only thought: {response}"
            return TaskStatus.IN_PROGRESS
        
        if self.config.get("allow_clarifying_questions", True):
            logger.action_agent(f"[Actor Question/Statement]: {text_response}")
            # Clean output consistent with established standards
            print(f"\n{CLR_BOLD_GREEN}{text_response}{CLR_RESET}")
            print(f"{CLR_GREEN}Response: {CLR_RESET}", end="")
            state.user_clarification = input()
            state.last_action_taken = f"Action Agent asked/stated: {text_response}"
            state.last_action_result = f"User responded: {state.user_clarification}"
            return TaskStatus.IN_PROGRESS
        else:
            logger.warning(f"Actor: no command, questions disabled. Actor said: {text_response}")
            state.last_action_taken = f"Actor: no command (questions disabled). Statement: {text_response}"
            state.last_action_result = "No action taken: no command, questions disabled"
            return TaskStatus.IN_PROGRESS
    
    def _execute_evaluation_phase(self, context: str, state: TaskState) -> tuple[TaskStatus, str]:
        """Execute the evaluation phase."""
        # Get LLM response for evaluation
        payload = self.payload_builder.prepare_payload("evaluate", context)
        if not payload:
            logger.error("Failed to prepare payload for EVALUATION phase")
            return TaskStatus.FAILED, ""
            
        response = self.llm_client.send_request(payload)
        if not response:
            logger.error("No response from LLM for EVALUATION phase")
            return TaskStatus.FAILED, ""
            
        # Append to context for history
        self.config_manager.append_context(f"Evaluator Input: {context}", response)
        
        # Parse LLM response
        thought = parse_llm_thought(response)
        if thought:
            logger.eval_agent(f"[Evaluator Thought]: {thought}")
        
        # Extract evaluator summary for inter-agent coordination
        state.evaluator_summary = parse_llm_summary(response)
        if state.evaluator_summary:
            logger.eval_agent(f"[Evaluator Summary]: {state.evaluator_summary}")
        
        decision = parse_llm_decision(response)
        if not decision:
            logger.warning("Evaluator: no decision. Assuming CONTINUE_PLAN")
            decision = "CONTINUE_PLAN: No decision by LLM. Defaulting to continue."
        
        logger.eval_agent(f"[Evaluator Decision]: {decision}")
        
        # Parse decision type and message
        from ..llm.parsers import extract_decision_type_and_message
        decision_type, message = extract_decision_type_and_message(decision)
        state.last_eval_decision = decision_type
        
        # Handle different decision types
        return self._process_evaluation_decision(decision_type, message, state)
    
    def _process_evaluation_decision(self, decision_type: str, message: str, state: TaskState) -> tuple[TaskStatus, str]:
        """Process the evaluator's decision and return next status and context."""
        if decision_type == "TASK_COMPLETE":
            logger.eval_agent(f"Task marked COMPLETE by evaluator: {message}")
            return TaskStatus.COMPLETED, ""
        
        elif decision_type == "TASK_FAILED":
            logger.eval_agent(f"Task marked FAILED by evaluator. Reason: {message}")
            return TaskStatus.FAILED, ""
        
        elif decision_type == "CONTINUE_PLAN":
            logger.eval_agent(f"Evaluator: CONTINUE_PLAN. {message}")
            next_context = (
                f"Original request: '{state.current_instruction}'.\n"
                f"Current Plan:\n{state.current_plan}\n"
                f"Prev instruction ('{state.current_instruction}') result: '{state.last_action_result}'.\n"
                f"Evaluator feedback: '{message}'.\n"
                "Provide next instruction. If plan complete, instruct actor 'report_task_completion'."
            )
            # Reset for next instruction
            state.current_plan = ""
            state.current_instruction = ""
            state.user_clarification = ""
            return TaskStatus.IN_PROGRESS, next_context
        
        elif decision_type == "REVISE_PLAN":
            logger.eval_agent(f"Evaluator: REVISE_PLAN. Reason: {message}")
            next_context = (
                f"Original request: '{state.current_instruction}'.\n"
                f"Prev plan:\n{state.current_plan}\n"
                f"Prev instruction ('{state.current_instruction}') result: '{state.last_action_result}'.\n"
                f"Evaluator suggests revision: '{message}'.\n"
                "Revise checklist and provide new first instruction."
            )
            # Reset for new plan
            state.current_plan = ""
            state.current_instruction = ""
            state.user_clarification = ""
            return TaskStatus.IN_PROGRESS, next_context
        
        elif decision_type == "CLARIFY_USER":
            if self.config.get("allow_clarifying_questions", True):
                logger.eval_agent(f"[Evaluator Clarification]: {message}")
                print(f"\n{CLR_BOLD_GREEN}{message}{CLR_RESET}")
                print(f"{CLR_GREEN}Response: {CLR_RESET}", end="")
                state.user_clarification = input()
                next_context = (
                    f"Original request: '{state.current_instruction}'.\n"
                    f"After action '{state.last_action_taken}' (result: '{state.last_action_result}'), "
                    f"evaluator needs clarification. Question: '{message}'.\n"
                    f"User's answer: '{state.user_clarification}'.\n"
                    "Revise plan/next instruction based on this."
                )
                # Reset for revision
                state.current_plan = ""
                state.current_instruction = ""
                return TaskStatus.IN_PROGRESS, next_context
            else:
                logger.warning(f"Evaluator: CLARIFY_USER when questions disabled: '{message}'")
                logger.system("Task FAILED: evaluator needs clarification, questions disabled")
                return TaskStatus.FAILED, ""
        
        elif decision_type == "VERIFY_ACTION":
            logger.eval_agent(f"Evaluator requests verification: {message}")
            # Set the verification command as the next instruction
            verification_context = (
                f"Original request: '{state.current_instruction}'.\n"
                f"Previous action: '{state.last_action_taken}' (result: '{state.last_action_result}').\n"
                f"Evaluator needs verification. Execute this command to verify the outcome: {message}"
            )
            # Keep the same plan but set verification as next instruction
            state.current_instruction = f"Execute verification command: {message}"
            state.user_clarification = ""
            return TaskStatus.IN_PROGRESS, verification_context
        
        else:
            logger.error(f"Unknown decision from Evaluator: '{decision}'. Assuming task failed")
            return TaskStatus.FAILED, ""
    
    def _build_action_context(self, original_prompt: str, state: TaskState) -> str:
        """Build context for action phase."""
        context = (
            f"User's original request: '{original_prompt}'\n\n"
            f"Instruction to execute: '{state.current_instruction}'"
        )
        
        # Add planner summary for coordination
        if state.planner_summary:
            context += f"\n\nPlanner's Summary: {state.planner_summary}"
        
        if state.user_clarification:
            context += f"\n\nContext: User responded '{state.user_clarification}' to my last question."
            state.user_clarification = ""  # Clear after use
        return context
    
    def _build_evaluation_context(self, original_prompt: str, state: TaskState) -> str:
        """Build context for evaluation phase."""
        context = (
            f"User's original request: '{original_prompt}'\n\n"
            f"Current Plan Checklist (if available):\n{state.current_plan}\n\n"
            f"Instruction that was attempted: '{state.current_instruction}'\n\n"
            f"Action Taken by Actor:\n{state.last_action_taken}\n\n"
            f"Result of Action:\n{state.last_action_result}"
        )
        
        # Add agent summaries for coordination
        if state.planner_summary:
            context += f"\n\nPlanner's Summary: {state.planner_summary}"
        if state.actor_summary:
            context += f"\n\nActor's Summary: {state.actor_summary}"
        
        if state.user_clarification:
            context += f"\n\nContext: User responded '{state.user_clarification}' to my last question."
            state.user_clarification = ""  # Clear after use
        return context
    
    def _generate_completion_summary(self, original_prompt: str, state: TaskState):
        """Generate and display a completion summary after task success."""
        logger.system("Generating task completion summary...")
        
        # Build context for summary generation
        context_history = self.config_manager.get_current_session_context()
        summary_context = (
            f"Original User Request: '{original_prompt}'\n\n"
            f"Task Execution History:\n{context_history}\n\n"
            f"Final Task State:\n"
            f"- Plan: {state.current_plan}\n"
            f"- Last Action: {state.last_action_taken}\n"
            f"- Result: {state.last_action_result}\n"
            f"- Total Iterations: {state.iteration}"
        )
        
        # Get completion summary from LLM
        payload = self.payload_builder.prepare_payload("completion_summary", summary_context)
        if not payload:
            logger.warning("Failed to prepare payload for completion summary")
            return
            
        response = self.llm_client.send_request(payload)
        if not response:
            logger.warning("No response from LLM for completion summary")
            return
            
        # Parse and display the summary
        try:
            # Extract the summary content from between <summary> tags
            import re
            summary_match = re.search(r'<summary>(.*?)</summary>', response, re.DOTALL)
            if summary_match:
                summary_content = summary_match.group(1).strip()
                print(f"\n{summary_content}\n")
            else:
                # If no summary tags, just display the response directly
                print(f"\n## Task Completion Summary\n{response}\n")
        except Exception as e:
            logger.warning(f"Error parsing completion summary: {e}")
            print(f"\n## Task Completion Summary\n{response}\n")


def create_task_handler(config: Dict[str, Any], config_manager) -> TaskHandler:
    """Create a task handler instance.
    
    Args:
        config: Application configuration
        config_manager: Configuration manager instance
        
    Returns:
        TaskHandler instance
    """
    return TaskHandler(config, config_manager)
