"""Command permissions and authorization for termaite."""

import json
import tempfile
import shutil
import re
from typing import Dict, Any, Tuple, Optional
from pathlib import Path

import yaml

from ..utils.logging import logger
from ..constants import CLR_YELLOW, CLR_BOLD_YELLOW, CLR_RED, CLR_RESET


class CommandPermissionManager:
    """Manages command permissions and authorization."""
    
    def __init__(self, config_file: Path):
        """Initialize permission manager.
        
        Args:
            config_file: Path to the configuration file
        """
        self.config_file = config_file
        self.allowed_commands: Dict[str, str] = {}
        self.blacklisted_commands: Dict[str, Any] = {}
    
    def set_command_maps(self, allowed: Dict[str, str], blacklisted: Dict[str, Any]):
        """Update the command allow/blacklists."""
        self.allowed_commands = allowed
        self.blacklisted_commands = blacklisted
    
    def check_command_permission(self, command: str, operation_mode: str) -> Tuple[bool, str]:
        """Check if a command is permitted to execute.
        
        Args:
            command: Command to check
            operation_mode: Current operation mode (normal, gremlin, goblin)
            
        Returns:
            Tuple of (is_allowed, reason)
        """
        # Extract the base command name
        command_name = self._extract_command_name(command)
        
        # Check blacklist first (applies to all modes)
        if self._is_blacklisted(command_name):
            return False, f"Command '{command_name}' is blacklisted"
        
        # Check permissions based on operation mode
        if operation_mode == "normal":
            return self._check_normal_mode_permission(command_name)
        elif operation_mode in ["gremlin", "goblin"]:
            return True, f"Command allowed in {operation_mode} mode"
        else:
            return False, f"Unknown operation mode: {operation_mode}"
    
    def prompt_for_permission(self, command: str, config: Dict[str, Any], 
                            llm_client=None) -> Tuple[int, str]:
        """Prompt user for command permission.
        
        Args:
            command: Command to ask permission for
            config: Application configuration
            llm_client: LLM client for getting command descriptions
            
        Returns:
            Tuple of (decision_code, reason)
            decision_code: 0 (allowed), 1 (denied), 2 (cancel task)
        """
        command_name = self._extract_command_name(command)
        
        print(f"{CLR_YELLOW}The agent wants to use the command '{CLR_BOLD_YELLOW}{command_name}{CLR_YELLOW}', "
              f"which is not in the allowed list.{CLR_RESET}")
        
        while True:
            user_decision = input(
                f"{CLR_YELLOW}Allow? (y)es/(n)o/(a)lways/(c)cancel task: {CLR_RESET}"
            ).lower()
            
            if user_decision in ['y', 'n', 'a', 'c']:
                break
            print(f"{CLR_RED}Invalid choice. Enter y, n, a, or c.{CLR_RESET}")
        
        if user_decision == 'y':
            logger.user(f"Allowed command '{command_name}' for this instance.")
            return 0, f"User allowed '{command_name}' for this instance"
            
        elif user_decision == 'n':
            logger.user(f"Denied command '{command_name}' for this instance.")
            return 1, f"User denied '{command_name}' for this instance"
            
        elif user_decision == 'c':
            logger.user("User chose to cancel the task.")
            return 2, "User cancelled the task"
            
        elif user_decision == 'a':
            logger.user(f"Chose 'always' allow for '{command_name}'. Adding to config.")
            
            if self._add_command_to_allowed_list(command_name, config, llm_client):
                logger.system(f"Command '{command_name}' added to allowed_commands.")
                return 0, f"Command '{command_name}' permanently added to allowed list"
            else:
                logger.error(f"Failed to add '{command_name}' to config. Not executed.")
                return 1, f"Failed to add '{command_name}' to config"
        
        return 1, "Unknown error in permission prompt"
    
    def _extract_command_name(self, command: str) -> str:
        """Extract the base command name from a command string."""
        # Handle complex commands with pipes, redirects, etc.
        # For now, just take the first word
        parts = command.strip().split()
        return parts[0] if parts else command
    
    def _is_blacklisted(self, command_name: str) -> bool:
        """Check if a command is blacklisted."""
        return command_name in self.blacklisted_commands
    
    def _check_normal_mode_permission(self, command_name: str) -> Tuple[bool, str]:
        """Check permission in normal mode (allowlist-based)."""
        if command_name in self.allowed_commands:
            return True, f"Command '{command_name}' is in allowed list"
        else:
            return False, f"Command '{command_name}' not in allowed list"
    
    def _add_command_to_allowed_list(self, command_name: str, config: Dict[str, Any],
                                   llm_client=None) -> bool:
        """Add a command to the allowed list with LLM-generated description."""
        description = self._get_command_description(command_name, config, llm_client)
        if not description:
            logger.error(f"Could not get description for command '{command_name}'")
            return False
        
        return self._update_config_with_command(command_name, description)
    
    def _get_command_description(self, command_name: str, config: Dict[str, Any],
                               llm_client=None) -> Optional[str]:
        """Get a description for a command using LLM."""
        if not llm_client:
            logger.warning("No LLM client available for command description")
            return f"User-added command: {command_name}"
        
        # Get help output first
        from .executor import create_command_executor
        executor = create_command_executor(config.get("command_timeout", 10))
        success, help_output = executor.get_command_help(command_name)
        
        # Truncate help output if too long
        max_help_length = 1500
        if len(help_output) > max_help_length:
            logger.warning(f"Help output for '{command_name}' ({len(help_output)} chars) truncated.")
            help_output = help_output[:max_help_length] + "..."
        
        # Prepare LLM prompt for description
        system_prompt = (
            "You are an assistant that provides concise descriptions of Linux commands. "
            "Your response MUST be a valid JSON object containing a single key 'description' "
            "whose value is a short, one-sentence command description. "
            "Do NOT include any other text, explanations, or XML tags in your response. Output ONLY the JSON object."
        )
        
        if help_output:
            user_prompt = (
                f"Based on the following help output for the Linux shell command '{command_name}', "
                "provide your response as a JSON object containing a single key \"description\" "
                "with a short, one-sentence string value describing the command's primary purpose. "
                "Output ONLY the JSON object.\n\nHelp Output:\n```\n"
                f"{help_output}\n```\n\nJSON Output:"
            )
        else:
            user_prompt = (
                f"Describe the general purpose and typical usage of the Linux shell command '{command_name}'. "
                "Provide your response as a JSON object containing a single key \"description\" "
                "with a short, one-sentence string value. Do not include any other text or formatting "
                "outside the JSON object. Example for 'ls': {\"description\": \"List directory contents.\"}\n\nJSON Output:"
            )
        
        # Make direct LLM call for description
        try:
            from ..llm.payload import create_payload_builder
            payload_builder = create_payload_builder(config, Path(config.get("payload_file", "payload.json")))
            
            # Create a custom payload for this specific request
            desc_payload = {
                "model": config.get("model", "default"),
                "system": system_prompt,
                "prompt": user_prompt,
                "stream": False
            }
            
            response = llm_client.send_request(json.dumps(desc_payload))
            if not response:
                return None
            
            # Parse JSON response
            match = re.search(r"(\{.*?\})", response, re.DOTALL)
            if match:
                desc_json = json.loads(match.group(1))
                description = desc_json.get("description", "").strip()
                if description:
                    logger.system(f"LLM suggested description for '{command_name}': '{description}'")
                    return description
                    
        except Exception as e:
            logger.error(f"Error getting LLM description for '{command_name}': {e}")
        
        return None
    
    def _update_config_with_command(self, command_name: str, description: str) -> bool:
        """Update the configuration file with a new allowed command."""
        try:
            # Load current config
            with open(self.config_file, 'r') as f:
                current_config = yaml.safe_load(f)
            
            # Ensure allowed_commands section exists
            if "allowed_commands" not in current_config or not isinstance(current_config["allowed_commands"], dict):
                current_config["allowed_commands"] = {}
            
            # Add the new command
            current_config["allowed_commands"][command_name] = description
            
            # Write to temporary file first
            with tempfile.NamedTemporaryFile('w', delete=False, 
                                           dir=self.config_file.parent, 
                                           suffix='.yaml', encoding='utf-8') as tmp_f:
                yaml.dump(current_config, tmp_f, sort_keys=False, indent=2, default_flow_style=False)
                temp_name = tmp_f.name
            
            # Validate the temporary file
            with open(temp_name, 'r') as f:
                yaml.safe_load(f)
            
            # Move temp file to replace original
            shutil.move(temp_name, str(self.config_file))
            
            # Update in-memory map
            self.allowed_commands[command_name] = description
            
            logger.system(f"Command '{command_name}' with description added/updated in {self.config_file}.")
            return True
            
        except Exception as e:
            logger.error(f"Error updating {self.config_file} for command '{command_name}': {e}")
            
            # Clean up temp file if it exists
            if 'temp_name' in locals() and Path(temp_name).exists():
                Path(temp_name).unlink()
            
            return False


def create_permission_manager(config_file: Path) -> CommandPermissionManager:
    """Create a command permission manager."""
    return CommandPermissionManager(config_file)
