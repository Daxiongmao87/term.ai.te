"""Configuration manager for termaite."""

from typing import Dict, Any, Optional, Tuple
from pathlib import Path
import os
import sys

import yaml

from ..constants import (
    CONFIG_DIR, CONFIG_FILE, PAYLOAD_FILE, RESPONSE_PATH_FILE,
    DEFAULT_ENDPOINT, DEFAULT_COMMAND_TIMEOUT, DEFAULT_OPERATION_MODE,
    DEFAULT_ENABLE_DEBUG, DEFAULT_ALLOW_CLARIFYING_QUESTIONS, OPERATION_MODES
)
from ..utils.logging import logger
from ..utils.helpers import get_current_context, format_template_string, safe_file_write
from .templates import CONFIG_TEMPLATE, PAYLOAD_TEMPLATE, RESPONSE_PATH_TEMPLATE


class ConfigManager:
    """Manages configuration loading, validation, and setup for termaite."""
    
    def __init__(self, config_dir: Optional[Path] = None):
        """Initialize the configuration manager.
        
        Args:
            config_dir: Custom configuration directory path
        """
        self.config_dir = config_dir or CONFIG_DIR
        self.config_file = self.config_dir / "config.yaml"
        self.payload_file = self.config_dir / "payload.json"
        self.response_path_file = self.config_dir / "response_path_template.txt"
        
        # Command maps for runtime access
        self.allowed_commands: Dict[str, str] = {}
        self.blacklisted_commands: Dict[str, Any] = {}
        
        # Configuration data
        self._config: Optional[Dict[str, Any]] = None
        
    def initialize(self) -> bool:
        """Initialize configuration by setting up files and loading config.
        
        Returns:
            True if initialization successful, False if setup files were created
        """
        if not self._perform_initial_setup():
            return False
        
        self._config = self._load_config()
        self._populate_command_maps()
        return True
        
    def _perform_initial_setup(self) -> bool:
        """Creates config directory and default files if they don't exist.
        
        Returns:
            True if no setup was needed, False if files were created
        """
        try:
            self.config_dir.mkdir(parents=True, exist_ok=True)
            missing_setup_file = False

            # Create config file if missing
            if not self.config_file.exists():
                context = get_current_context()
                context["tool_instructions_addendum"] = "{tool_instructions_addendum}"
                
                formatted_config = format_template_string(CONFIG_TEMPLATE, **context)
                if safe_file_write(self.config_file, formatted_config, "config template"):
                    missing_setup_file = True
                else:
                    return False

            # Create payload file if missing
            if not self.payload_file.exists():
                if safe_file_write(self.payload_file, PAYLOAD_TEMPLATE, "payload template"):
                    logger.system(f"IMPORTANT: Review and edit {self.payload_file} to match your LLM API.")
                    missing_setup_file = True
                else:
                    return False

            # Create response path file if missing
            if not self.response_path_file.exists():
                if safe_file_write(self.response_path_file, RESPONSE_PATH_TEMPLATE, "response path template"):
                    missing_setup_file = True
                else:
                    return False

            if missing_setup_file:
                logger.system(f"Configuration templates generated in {self.config_dir}")
                logger.system("Please review and configure them before running termaite again.")
                return False

            return True
            
        except Exception as e:
            logger.error(f"Failed during initial setup: {e}")
            return False
    
    def _load_config(self) -> Dict[str, Any]:
        """Load and validate the configuration file."""
        if not self.config_file.exists():
            logger.error(f"Configuration file {self.config_file} not found.")
            sys.exit(1)

        try:
            with open(self.config_file, 'r') as f:
                config_data = yaml.safe_load(f)
        except yaml.YAMLError as e:
            logger.error(f"Error parsing YAML file {self.config_file}: {e}")
            sys.exit(1)
        except IOError as e:
            logger.error(f"Could not read {self.config_file}: {e}")
            sys.exit(1)

        if not isinstance(config_data, dict):
            logger.error(f"{self.config_file} is not a valid YAML dictionary.")
            sys.exit(1)

        # Validate required fields
        required_fields = ["endpoint", "plan_prompt", "action_prompt", "evaluate_prompt", 
                          "allowed_commands", "operation_mode", "command_timeout"]
        for field in required_fields:
            if field not in config_data:
                logger.error(f"Required key '.{field}' missing in {self.config_file}.")
                sys.exit(1)
            if config_data[field] is None and field not in ["api_key", "blacklisted_commands"]:
                logger.error(f"Required key '.{field}' is null/empty in {self.config_file}.")
                sys.exit(1)

        # Validate and set debug flag
        enable_debug = config_data.get("enable_debug", DEFAULT_ENABLE_DEBUG)
        if not isinstance(enable_debug, bool):
            logger.warning(f"enable_debug in {self.config_file} must be true/false. Defaulting to false.")
            enable_debug = DEFAULT_ENABLE_DEBUG
        config_data["enable_debug"] = enable_debug
        logger.debug(f"Debug mode set to: {enable_debug}")

        # Validate operation mode
        op_mode = config_data.get("operation_mode", DEFAULT_OPERATION_MODE)
        if op_mode not in OPERATION_MODES:
            logger.error(f"operation_mode in {self.config_file} must be one of {OPERATION_MODES}, got '{op_mode}'.")
            sys.exit(1)
        config_data["operation_mode"] = op_mode

        # Validate command timeout
        cmd_timeout = config_data.get("command_timeout", DEFAULT_COMMAND_TIMEOUT)
        if not (isinstance(cmd_timeout, int) and cmd_timeout >= 0):
            logger.error(f"command_timeout ('{cmd_timeout}') in {self.config_file} must be a non-negative integer.")
            sys.exit(1)
        config_data["command_timeout"] = cmd_timeout

        # Validate clarifying questions setting
        allow_questions = config_data.get("allow_clarifying_questions", DEFAULT_ALLOW_CLARIFYING_QUESTIONS)
        if not isinstance(allow_questions, bool):
            logger.warning(f"allow_clarifying_questions in {self.config_file} must be true/false. Defaulting to true.")
            allow_questions = DEFAULT_ALLOW_CLARIFYING_QUESTIONS
        config_data["allow_clarifying_questions"] = allow_questions

        logger.debug(f"Configuration loaded successfully from {self.config_file}")
        return config_data
    
    def _populate_command_maps(self):
        """Populate allowed and blacklisted command maps from config."""
        if not self._config:
            return
        
        # Process allowed commands
        allowed_cmds_config = self._config.get("allowed_commands", {})
        if isinstance(allowed_cmds_config, dict):
            self.allowed_commands = {str(k): str(v) for k, v in allowed_cmds_config.items()}
        else:
            logger.warning(f"'allowed_commands' in {self.config_file} is not a map. No allowed commands loaded.")
            self.allowed_commands = {}
        logger.debug(f"Loaded {len(self.allowed_commands)} allowed commands.")

        # Process blacklisted commands
        blacklisted_cmds_config = self._config.get("blacklisted_commands", [])
        if isinstance(blacklisted_cmds_config, list): 
            self.blacklisted_commands = {str(cmd): True for cmd in blacklisted_cmds_config}
        elif isinstance(blacklisted_cmds_config, dict): 
            self.blacklisted_commands = {str(k): str(v) for k, v in blacklisted_cmds_config.items()}
        else:
            logger.warning(f"'blacklisted_commands' in {self.config_file} is not a list or map. No blacklisted commands loaded.")
            self.blacklisted_commands = {}
        logger.debug(f"Loaded {len(self.blacklisted_commands)} blacklisted commands.")
    
    def get_response_path(self) -> str:
        """Reads the response path from response path file."""
        if not self.response_path_file.exists():
            logger.error(f"Response path file {self.response_path_file} not found.")
            sys.exit(1)
        
        try:
            with open(self.response_path_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        logger.debug(f"Using response path: {line}")
                        return line
            
            logger.error(f"No valid response path found in {self.response_path_file}.")
            sys.exit(1)
            
        except IOError as e:
            logger.error(f"Could not read {self.response_path_file}: {e}")
            sys.exit(1)
    
    @property
    def config(self) -> Dict[str, Any]:
        """Get the current configuration."""
        if self._config is None:
            raise RuntimeError("Configuration not loaded. Call initialize() first.")
        return self._config.copy()
    
    def get(self, key: str, default: Any = None) -> Any:
        """Get a configuration value."""
        if self._config is None:
            raise RuntimeError("Configuration not loaded. Call initialize() first.")
        return self._config.get(key, default)
    
    def reload(self) -> None:
        """Reload the configuration from disk."""
        self._config = self._load_config()
        self._populate_command_maps()
    
    def get_command_maps(self) -> Tuple[Dict[str, str], Dict[str, Any]]:
        """Get the allowed and blacklisted command maps."""
        return self.allowed_commands.copy(), self.blacklisted_commands.copy()
    
    def is_initialized(self) -> bool:
        """Check if the configuration has been initialized."""
        return self._config is not None


def create_config_manager(config_dir: Optional[Path] = None) -> ConfigManager:
    """Create and initialize a configuration manager.
    
    Args:
        config_dir: Custom configuration directory path
        
    Returns:
        Initialized ConfigManager instance
    """
    manager = ConfigManager(config_dir)
    if not manager.initialize():
        logger.system("Configuration setup required. Please configure the generated files and run again.")
        sys.exit(0)
    return manager
