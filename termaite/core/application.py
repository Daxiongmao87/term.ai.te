"""Main application class for termaite."""

import signal
import sys
from typing import Optional
from pathlib import Path

from ..config.manager import create_config_manager
from ..core.task_handler import create_task_handler
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
        logger.system("term.ai.te starting...")
        
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
        
        # Initialize task handler
        self.task_handler = create_task_handler(self.config, self.config_manager)
        
        # Set up signal handlers
        self._setup_signal_handlers()
        
        logger.debug("Application initialization complete")
    
    def handle_task(self, prompt: str) -> bool:
        """Handle a user task through the Plan-Act-Evaluate loop.
        
        Args:
            prompt: The user's task request
            
        Returns:
            True if task completed successfully, False otherwise
        """
        try:
            return self.task_handler.handle_task(prompt)
        except KeyboardInterrupt:
            logger.system("Task interrupted by user")
            return False
        except Exception as e:
            logger.error(f"Unexpected error during task handling: {e}")
            return False
    
    def run_interactive_mode(self) -> None:
        """Run the application in interactive mode."""
        logger.system("Starting interactive mode. Type 'exit' or 'quit' to stop.")
        
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
                    
                    # Handle the task
                    success = self.handle_task(user_input)
                    
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
    
    def run_single_task(self, task: str) -> bool:
        """Run a single task and exit.
        
        Args:
            task: Task to execute
            
        Returns:
            True if task completed successfully, False otherwise
        """
        logger.system(f"Running single task: {task}")
        return self.handle_task(task)
    
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


def create_application(config_dir: Optional[str] = None, debug: bool = False) -> TermAIte:
    """Create and initialize a TermAIte application instance.
    
    Args:
        config_dir: Custom configuration directory path
        debug: Enable debug logging
        
    Returns:
        Initialized TermAIte instance
    """
    return TermAIte(config_dir, debug)
