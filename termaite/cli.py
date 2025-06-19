"""Command-line interface for termaite."""

import argparse
import sys
from typing import List, Optional

from colorama import init as colorama_init

from .core.application import create_application
from .utils.logging import logger
from . import __version__


def create_parser() -> argparse.ArgumentParser:
    """Create the command-line argument parser."""
    parser = argparse.ArgumentParser(
        description="term.ai.te: LLM-powered shell assistant with Plan-Act-Evaluate multi-agent architecture.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  termaite "list all python files in the current directory"
  termaite "create a backup of my documents folder"
  termaite --debug "find all large files over 100MB"
  termaite  # Interactive mode

Operation Modes:
  normal  - Allowed commands require confirmation, others are blocked
  gremlin - Allowed commands run automatically, others prompt for permission
  goblin  - All commands run without confirmation (USE WITH CAUTION!)
        """
    )
    
    parser.add_argument(
        'task_prompt',
        nargs='*',
        help="Initial task description. If empty, enters interactive mode."
    )
    
    parser.add_argument(
        '--version',
        action='version',
        version=f'termaite {__version__}'
    )
    
    parser.add_argument(
        '--debug',
        action='store_true',
        help="Enable debug logging output"
    )
    
    parser.add_argument(
        '--config-dir',
        type=str,
        help="Custom configuration directory path"
    )
    
    parser.add_argument(
        '--config-summary',
        action='store_true',
        help="Show configuration summary and exit"
    )
    
    return parser


def main(args: Optional[List[str]] = None) -> None:
    """Main entry point for the CLI."""
    # Initialize colorama for cross-platform colored output
    colorama_init(autoreset=True)
    
    # Parse command-line arguments
    parser = create_parser()
    parsed_args = parser.parse_args(args)
    
    # Initialize the application
    try:
        app = create_application(
            config_dir=parsed_args.config_dir,
            debug=parsed_args.debug
        )
    except SystemExit:
        # Configuration setup was needed - already handled
        return
    except Exception as e:
        logger.error(f"Failed to initialize termaite: {e}")
        sys.exit(1)
    
    # Handle config summary request
    if parsed_args.config_summary:
        app.print_config_summary()
        return
    
    # Run in command-line or interactive mode
    if parsed_args.task_prompt:
        # Command-line mode: execute the given task
        user_task = " ".join(parsed_args.task_prompt)
        success = app.run_single_task(user_task)
        sys.exit(0 if success else 1)
    else:
        # Interactive mode
        app.run_interactive_mode()
    
    logger.system("termaite session ended.")


if __name__ == "__main__":
    main()
