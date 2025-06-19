"""LLM payload preparation utilities for termaite."""

import json
import re
import yaml
from typing import Dict, Any, Optional
from pathlib import Path

from ..utils.logging import logger
from ..utils.helpers import get_current_context, format_template_string
from ..constants import DEFAULT_MODEL


class PayloadBuilder:
    """Builds JSON payloads for LLM API calls."""
    
    def __init__(self, config: Dict[str, Any], payload_file: Path):
        """Initialize payload builder.
        
        Args:
            config: Application configuration
            payload_file: Path to payload template file
        """
        self.config = config
        self.payload_file = payload_file
        self.allowed_commands = {}
        self.blacklisted_commands = {}
    
    def set_command_maps(self, allowed: Dict[str, str], blacklisted: Dict[str, Any]):
        """Set command allow/blacklists for payload building."""
        self.allowed_commands = allowed
        self.blacklisted_commands = blacklisted
    
    def prepare_payload(self, phase: str, prompt_content: str) -> Optional[str]:
        """Prepares the JSON payload for the LLM API call.
        
        Args:
            phase: Agent phase ("plan", "action", "evaluate")
            prompt_content: User prompt content
            
        Returns:
            JSON payload string or None if preparation failed
        """
        system_prompt = self._get_system_prompt_for_phase(phase)
        if not system_prompt:
            return None
        
        # Process template variables
        context_vars = get_current_context()
        context_vars["tool_instructions_addendum"] = self._get_tool_instructions(phase)
        
        # Handle conditional blocks in prompts
        system_prompt = self._process_conditional_blocks(system_prompt)
        
        # Format the system prompt with context variables
        final_system_prompt = format_template_string(system_prompt, **context_vars)
        
        # Load and prepare payload template
        return self._build_json_payload(final_system_prompt, prompt_content)
    
    def _get_system_prompt_for_phase(self, phase: str) -> Optional[str]:
        """Get the system prompt for a specific phase."""
        phase_map = {
            "plan": self.config.get("plan_prompt", ""),
            "action": self.config.get("action_prompt", ""),
            "evaluate": self.config.get("evaluate_prompt", ""),
            "completion_summary": self.config.get("completion_summary_prompt", ""),
            "simple": self.config.get("simple_prompt", "")
        }
        
        if phase not in phase_map:
            logger.error(f"Invalid phase '{phase}' provided to prepare_payload.")
            return None
        
        return phase_map[phase]
    
    def _get_tool_instructions(self, phase: str) -> str:
        """Get tool instructions addendum for the given phase."""
        if phase not in ["action", "simple"]:
            return ""
        
        operation_mode = self.config.get("operation_mode", "normal")
        
        if operation_mode == "normal":
            return self._get_normal_mode_instructions()
        elif operation_mode in ["gremlin", "goblin"]:
            return self._get_permissive_mode_instructions(operation_mode)
        
        return ""
    
    def _get_normal_mode_instructions(self) -> str:
        """Get instructions for normal (restricted) operation mode."""
        if self.allowed_commands:
            allowed_commands_yaml = yaml.dump(
                {"allowed_commands": self.allowed_commands}, 
                indent=2, default_flow_style=False, sort_keys=False
            )
            return (
                "You are permitted to use ONLY the following commands. Their names and descriptions are provided below in YAML format. "
                "Adhere strictly to these commands and their specified uses:\\n\\n```yaml\\n"
                f"{allowed_commands_yaml.strip()}\\n```\\n\\n"
                "If an appropriate command is not on this list, you should state that you cannot perform the action "
                "with the available commands and explain why.\\n"
            )
        else:
            logger.warning("NORMAL mode: allowed_commands list is empty. LLM instructed it cannot use commands.")
            return (
                "The list of allowed commands is currently empty. Therefore, you cannot suggest any shell commands. "
                "You must state that you cannot perform any action requiring a command and explain this limitation.\\n"
            )
    
    def _get_permissive_mode_instructions(self, mode: str) -> str:
        """Get instructions for gremlin/goblin (permissive) operation modes."""
        if mode == "gremlin":
            allowed_commands_info = ""
            if self.allowed_commands:
                allowed_list = ", ".join(self.allowed_commands.keys())
                allowed_commands_info = f"Pre-approved commands that will run without confirmation: {allowed_list}. "
            
            return (
                f"You are operating in GREMLIN mode. {allowed_commands_info}"
                "You can suggest ANY Linux shell command you deem necessary for the task. "
                "Commands not on the pre-approved list will prompt the user for permission, with options to allow once, "
                "deny, always allow (add to whitelist), or cancel the task. "
                "Feel free to suggest the most appropriate commands without worrying about restrictions.\\n\\n"
            )
        elif mode == "goblin":
            return (
                "You are operating in GOBLIN mode - UNRESTRICTED COMMAND ACCESS. "
                "You can suggest ANY Linux shell command and it will be executed immediately without confirmation. "
                "This mode has NO SAFETY RESTRICTIONS. Choose commands carefully and ensure they are safe and appropriate. "
                "You have full system access - use this power responsibly.\\n\\n"
            )
        else:
            return (
                f"You are operating in {mode} mode. This mode allows you to suggest any standard Linux shell command "
                "you deem best for the current task step. You are NOT restricted to a predefined list. "
                "Choose the most appropriate and effective command to achieve the step's goal. "
                "Ensure the command is safe and directly relevant to the task.\\n\\n"
            )
    
    def _process_conditional_blocks(self, prompt: str) -> str:
        """Process conditional blocks in prompt templates."""
        allow_cq = self.config.get("allow_clarifying_questions", True)
        
        if "{{if ALLOW_CLARIFYING_QUESTIONS}}" not in prompt:
            return prompt
        
        if allow_cq:
            # Keep the "if" branch, remove "else" branch
            prompt = re.sub(
                r"\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}(.*?)\{\{else\}\}.*?\{\{end\}\}", 
                r"\1", prompt, flags=re.DOTALL
            )
        else:
            # Keep the "else" branch, remove "if" branch
            prompt = re.sub(
                r"\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}.*?\{\{else\}\}(.*?)\{\{end\}\}", 
                r"\1", prompt, flags=re.DOTALL
            )
        
        # Clean up remaining template markers
        for marker in ["{{if ALLOW_CLARIFYING_QUESTIONS}}", "{{else}}", "{{end}}"]:
            prompt = prompt.replace(marker, "")
        
        return prompt
    
    def _build_json_payload(self, system_prompt: str, user_prompt: str) -> Optional[str]:
        """Build the final JSON payload from template and prompts."""
        try:
            with open(self.payload_file, 'r') as f:
                payload_template = f.read()
            
            # Use json.dumps to correctly escape the content for JSON string values
            escaped_system_prompt = json.dumps(system_prompt.strip())[1:-1]
            escaped_user_prompt = json.dumps(user_prompt.strip())[1:-1]

            payload_data_str = payload_template.replace("<system_prompt>", escaped_system_prompt)
            payload_data_str = payload_data_str.replace("<user_prompt>", escaped_user_prompt)
            
            # Substitute model name from config
            model_name = self.config.get("model", DEFAULT_MODEL)
            payload_data_str = payload_data_str.replace("<model_name>", model_name)
            
            # Validate JSON
            json.loads(payload_data_str)
            return payload_data_str

        except FileNotFoundError:
            logger.error(f"{self.payload_file} not found.")
            return None
        except json.JSONDecodeError as e:
            logger.error(f"{self.payload_file} (after substitutions) is not valid JSON: {e}.")
            logger.debug(f"Problematic payload string before JSON parsing: {payload_data_str}")
            return None
        except Exception as e:
            logger.error(f"Failed to prepare payload: {e}")
            return None


def create_payload_builder(config: Dict[str, Any], payload_file: Path) -> PayloadBuilder:
    """Create a configured payload builder instance."""
    return PayloadBuilder(config, payload_file)
