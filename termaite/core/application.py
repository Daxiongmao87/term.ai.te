"""Main application class for termaite."""

import signal
import shutil
import sys
from typing import Optional
from pathlib import Path

from ..config.manager import create_config_manager
from ..core.task_handler import create_task_handler
from ..core.simple_handler import create_simple_handler
from ..utils.logging import logger
from ..utils.helpers import check_dependencies
from ..constants import CLR_BOLD_RED, CLR_RESET


class TermAIte:
    """Main application class for term.ai.te."""
    
    def __init__(self, config_dir: Optional[str] = None, debug: bool = False):
        """Initialize the termaite application.
        
        Args:
            config_dir: Custom configuration directory path
            debug: Enable debug logging
        """
        # Set up logging first
        logger.set_debug(debug)
        
        # Initialize configuration manager
        config_path = Path(config_dir) if config_dir else None
        self.config_manager = create_config_manager(config_path)
        
        # Get configuration
        self.config = self.config_manager.config
        
        # Update debug setting from config if not explicitly set
        if not debug and self.config.get("enable_debug", False):
            logger.set_debug(True)
        
        # Check dependencies
        check_dependencies()
        
        # Initialize task handler and simple handler
        self.task_handler = create_task_handler(self.config, self.config_manager)
        self.simple_handler = create_simple_handler(self.config, self.config_manager)
        
        # Set up signal handlers
        self._setup_signal_handlers()
        
        logger.debug("Application initialization complete")
    
    def handle_task(self, prompt: str, agentic_mode: bool = False) -> bool:
        """Handle a user task using either simple or agentic mode.
        
        Args:
            prompt: The user's task request
            agentic_mode: If True, use Plan-Act-Evaluate loop; if False, use simple response
            
        Returns:
            True if task completed successfully, False otherwise
        """
        try:
            if agentic_mode:
                return self.task_handler.handle_task(prompt)
            else:
                return self.simple_handler.handle_simple_request(prompt)
        except KeyboardInterrupt:
            logger.system("Task interrupted by user")
            return False
        except Exception as e:
            logger.error(f"Unexpected error during task handling: {e}")
            return False
    
    def run_interactive_mode(self, agentic_mode: bool = False) -> None:
        """Run the application in interactive mode.
        
        Args:
            agentic_mode: Default mode for interactive session
        """
        mode_name = "agentic" if agentic_mode else "simple"
        logger.system(f"Starting interactive mode ({mode_name}). Type 'exit', 'quit', or use Ctrl+C to stop.")
        logger.system("Commands: -a <prompt> for agentic mode, -s <prompt> for simple mode")
        
        try:
            while True:
                try:
                    # Get user input
                    user_input = input(f"\n{CLR_BOLD_RED}termaite>{CLR_RESET} ").strip()
                    
                    # Check for exit commands
                    if user_input.lower() in ['exit', 'quit', 'q']:
                        logger.system("Goodbye!")
                        break
                    
                    # Skip empty input
                    if not user_input:
                        continue
                    
                    # Parse mode flags
                    current_agentic_mode = agentic_mode
                    prompt = user_input
                    
                    if user_input.startswith('-a '):
                        current_agentic_mode = True
                        prompt = user_input[3:].strip()
                    elif user_input.startswith('-s '):
                        current_agentic_mode = False
                        prompt = user_input[3:].strip()
                    
                    if not prompt:
                        logger.warning("Empty prompt after mode flag")
                        continue
                    
                    # Handle the task
                    success = self.handle_task(prompt, agentic_mode=current_agentic_mode)
                    
                    if not success:
                        logger.warning("Task did not complete successfully")
                    
                except KeyboardInterrupt:
                    logger.system("\nUse 'exit' or 'quit' to stop gracefully")
                    continue
                except EOFError:
                    logger.system("\nGoodbye!")
                    break
                    
        except Exception as e:
            logger.error(f"Error in interactive mode: {e}")
            sys.exit(1)
    
    def run_single_task(self, task: str, agentic_mode: bool = False) -> bool:
        """Run a single task and exit.
        
        Args:
            task: Task to execute
            agentic_mode: Whether to use agentic or simple mode
            
        Returns:
            True if task completed successfully, False otherwise
        """
        return self.handle_task(task, agentic_mode=agentic_mode)
    
    def _setup_signal_handlers(self) -> None:
        """Set up signal handlers for graceful shutdown."""
        def signal_handler(sig, frame):
            logger.system(f"Received signal {sig}, shutting down gracefully...")
            sys.exit(0)
        
        # Handle common termination signals
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
        
        # Handle SIGHUP on Unix systems
        if hasattr(signal, 'SIGHUP'):
            signal.signal(signal.SIGHUP, signal_handler)
    
    def get_config_summary(self) -> dict:
        """Get a summary of the current configuration.
        
        Returns:
            Dictionary with configuration summary
        """
        return {
            "endpoint": self.config.get("endpoint", "Not set"),
            "operation_mode": self.config.get("operation_mode", "normal"),
            "command_timeout": self.config.get("command_timeout", 30),
            "enable_debug": self.config.get("enable_debug", False),
            "allow_clarifying_questions": self.config.get("allow_clarifying_questions", True),
            "allowed_commands_count": len(self.config_manager.allowed_commands),
            "blacklisted_commands_count": len(self.config_manager.blacklisted_commands),
        }
    
    def print_config_summary(self) -> None:
        """Print a summary of the current configuration."""
        summary = self.get_config_summary()
        
        logger.system("Configuration Summary:")
        for key, value in summary.items():
            logger.system(f"  {key}: {value}")
    
    def print_config_location(self) -> None:
        """Print the configuration file locations."""
        logger.system("Configuration File Locations:")
        logger.system(f"  Config directory: {self.config_manager.config_dir}")
        logger.system(f"  Config file: {self.config_manager.config_file}")
        logger.system(f"  Payload file: {self.config_manager.payload_file}")
        logger.system(f"  Response template: {self.config_manager.response_path_file}")
        
        # Check if files exist
        files_status = []
        for name, path in [
            ("Config", self.config_manager.config_file),
            ("Payload", self.config_manager.payload_file),
            ("Response template", self.config_manager.response_path_file)
        ]:
            status = "✓ exists" if path.exists() else "✗ missing"
            files_status.append(f"  {name}: {status}")
        
        logger.system("File Status:")
        for status in files_status:
            logger.system(status)
    
    def edit_config(self) -> None:
        """Open the configuration file in the system's default editor."""
        import subprocess
        import os
        
        config_file = self.config_manager.config_file
        
        # Check if config file exists
        if not config_file.exists():
            logger.error(f"Configuration file not found: {config_file}")
            logger.system("Run termaite once to generate config templates first.")
            return
        
        # Determine the editor to use
        editor = os.environ.get('EDITOR') or os.environ.get('VISUAL')
        
        if not editor:
            # Try common editors as fallbacks
            for candidate in ['nano', 'vim', 'vi', 'gedit', 'kate', 'code']:
                if shutil.which(candidate):
                    editor = candidate
                    break
        
        if not editor:
            logger.error("No suitable editor found.")
            logger.error("Set the EDITOR environment variable or install nano/vim/vi.")
            logger.system(f"Config file location: {config_file}")
            return
        
        logger.system(f"Opening {config_file} with {editor}")
        
        try:
            # Open the editor
            subprocess.run([editor, str(config_file)], check=True)
            logger.system("Config file editor closed.")
        except subprocess.CalledProcessError as e:
            logger.error(f"Editor exited with error code {e.returncode}")
        except FileNotFoundError:
            logger.error(f"Editor '{editor}' not found")
        except KeyboardInterrupt:
            logger.system("Editor interrupted by user")
        except Exception as e:
            logger.error(f"Error opening editor: {e}")

def create_application(config_dir: Optional[str] = None, debug: bool = False) -> TermAIte:
    """Create and initialize a TermAIte application instance.
    
    Args:
        config_dir: Custom configuration directory path
        debug: Enable debug logging
        
    Returns:
        Initialized TermAIte instance
    """
    return TermAIte(config_dir, debug)
