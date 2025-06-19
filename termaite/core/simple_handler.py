"""Simple response handler for termaite - handles non-agentic mode responses."""

from typing import Dict, Any, Optional, Tuple

from ..utils.logging import logger
from ..llm import create_llm_client, create_payload_builder, parse_suggested_command, parse_llm_thought
from ..commands import create_command_executor, create_permission_manager, create_safety_checker
from ..constants import CLR_GREEN, CLR_RESET, CLR_BOLD_GREEN


class SimpleHandler:
    """Handles simple, direct responses without the Plan-Act-Evaluate loop."""
    
    def __init__(self, config: Dict[str, Any], config_manager):
        """Initialize the simple handler.
        
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
        
        logger.debug("SimpleHandler initialized")
    
    def handle_simple_request(self, user_prompt: str) -> bool:
        """Handle a simple request with a direct LLM response.
        
        Args:
            user_prompt: User's request
            
        Returns:
            True if request handled successfully, False otherwise
        """
        # Get LLM response for simple mode
        payload = self.payload_builder.prepare_payload("simple", user_prompt)
        if not payload:
            logger.error("Failed to prepare payload for simple mode")
            return False
            
        response = self.llm_client.send_request(payload)
        if not response:
            logger.error("No response from LLM for simple mode")
            return False
            
        # Append to context for history
        self.config_manager.append_context(f"Simple Request: {user_prompt}", response)
        
        # Parse LLM response
        thought = parse_llm_thought(response)
        if thought:
            logger.debug(f"[Simple Handler Thought]: {thought}")
            
        # Check for suggested command
        suggested_command = parse_suggested_command(response)
        
        # Extract the main response text (remove thought and command blocks)
        response_text = self._extract_response_text(response, thought, suggested_command)
        
        # Display the response (without logging the raw response)
        if response_text:
            print(f"\n{CLR_BOLD_GREEN}{response_text}{CLR_RESET}")
        
        # Handle command if present
        if suggested_command:
            return self._handle_command_execution(suggested_command, user_prompt)
        
        return True
    
    def _extract_response_text(self, full_response: str, thought: Optional[str], command: Optional[str]) -> str:
        """Extract the main response text from the LLM output.
        
        Args:
            full_response: Complete LLM response
            thought: Extracted thought content (to remove)
            command: Extracted command content (to remove)
            
        Returns:
            Clean response text for display
        """
        import re
        
        text = full_response
        
        # Remove think blocks using regex to handle variations
        text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL).strip()
        
        # Remove command blocks
        if command:
            text = text.replace(f"```agent_command\n{command}\n```", "").strip()
            text = text.replace(f"```agent_command\n{command}```", "").strip()
            text = text.replace(f"```\n{command}\n```", "").strip()
            text = text.replace(f"```{command}```", "").strip()
        
        # Clean up any remaining artifacts
        text = text.replace("```agent_command", "").replace("```", "").strip()
        
        # Remove extra newlines and clean up whitespace
        text = re.sub(r'\n\s*\n\s*\n', '\n\n', text).strip()
        
        return text
    
    def _handle_command_execution(self, command: str, original_request: str) -> bool:
        """Handle execution of a suggested command.
        
        Args:
            command: Command to execute
            original_request: Original user request for context
            
        Returns:
            True if command executed successfully, False otherwise
        """
        # Check safety and permissions
        is_safe, risk_level, warnings = self.safety_checker.check_command_safety(command)
        if not is_safe:
            logger.warning(f"Command blocked by safety checker: {risk_level}")
            print(f"\n{CLR_GREEN}⚠️  Command blocked for safety: {risk_level}{CLR_RESET}")
            return False
        
        permission_allowed, permission_reason = self.permission_manager.check_command_permission(command, self.config.get("operation_mode", "normal"))
        if not permission_allowed:
            logger.warning(f"Command not permitted: {permission_reason}")
            print(f"\n{CLR_GREEN}Command not permitted: {permission_reason}{CLR_RESET}")
            return False
        
        # For normal mode, check if confirmation is needed
        operation_mode = self.config.get("operation_mode", "normal")
        if operation_mode == "normal" and permission_reason.startswith("Command"):
            # Command is whitelisted but requires confirmation in normal mode
            print(f"\n{CLR_GREEN}Suggested command: {CLR_RESET}{CLR_BOLD_GREEN}{command}{CLR_RESET}")
            user_input = input(f"{CLR_GREEN}Execute this command? [y/N]: {CLR_RESET}").lower()
            if user_input != 'y':
                return True  # Not an error, user chose not to execute
        
        # Execute the command
        print(f"\n{CLR_GREEN}Executing: {CLR_RESET}{CLR_BOLD_GREEN}{command}{CLR_RESET}")
        
        try:
            result = self.command_executor.execute(command, quiet=True)
            
            if result.success:
                # For successful commands, just show the output
                if result.output:
                    print(f"\n{result.output}")
                return True
            else:
                # For failed commands, have the LLM explain the error
                return self._handle_command_error(command, result)
                
        except Exception as e:
            logger.error(f"Command execution failed: {e}")
            print(f"\n{CLR_GREEN}Error executing command: {e}{CLR_RESET}")
            return False
    
    def _handle_command_error(self, command: str, result) -> bool:
        """Handle command execution errors with LLM explanation.
        
        Args:
            command: The command that failed
            result: Command execution result with error info
            
        Returns:
            False (command failed)
        """
        # Create error context for the LLM
        error_context = f"""The command '{command}' failed with exit code {result.exit_code}.
        
Command output/error:
{result.output if result.output else 'No output'}

Please explain what went wrong and suggest possible solutions."""

        # Get LLM explanation of the error
        payload = self.payload_builder.prepare_payload("simple", error_context)
        if payload:
            response = self.llm_client.send_request(payload)
            if response:
                # Clean the response (remove think tags)
                import re
                clean_response = re.sub(r'<think>.*?</think>', '', response, flags=re.DOTALL).strip()
                
                print(f"\n{CLR_GREEN}Command failed with exit code {result.exit_code}:{CLR_RESET}")
                if result.output:
                    print(f"\n{result.output}")
                print(f"\n{CLR_BOLD_GREEN}{clean_response}{CLR_RESET}")
                return False
        
        # Fallback if LLM explanation fails
        print(f"\n{CLR_GREEN}Command failed with exit code {result.exit_code}:{CLR_RESET}")
        if result.output:
            print(f"\n{result.output}")
        return False


def create_simple_handler(config: Dict[str, Any], config_manager) -> SimpleHandler:
    """Create and initialize a SimpleHandler instance.
    
    Args:
        config: Application configuration
        config_manager: Configuration manager instance
        
    Returns:
        Initialized SimpleHandler instance
    """
    return SimpleHandler(config, config_manager)
