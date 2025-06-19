"""Task handler with Plan-Act-Evaluate loop for termaite."""

from typing import Dict, Any, Optional, Tuple
from dataclasses import dataclass
from enum import Enum

from ..utils.logging import logger
from ..llm import create_llm_client, create_payload_builder, parse_llm_plan, parse_llm_instruction, parse_llm_decision, parse_llm_thought, parse_suggested_command
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
        self.llm_client = create_llm_client(config, config_manager.response_path_file)
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
        logger.user(f"Starting task: {user_prompt}")
        
        # TODO: Implement full Plan-Act-Evaluate loop
        # This is a simplified version for now
        logger.system("Task handling with Plan-Act-Evaluate loop will be fully implemented")
        return True


def create_task_handler(config: Dict[str, Any], config_manager) -> TaskHandler:
    """Create a task handler instance.
    
    Args:
        config: Application configuration
        config_manager: Configuration manager instance
        
    Returns:
        TaskHandler instance
    """
    return TaskHandler(config, config_manager)
