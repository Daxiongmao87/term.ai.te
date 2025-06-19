"""Logging utilities for termaite."""

import sys
import datetime
from typing import TextIO

from ..constants import (
    CLR_RESET, CLR_CYAN, CLR_BOLD_CYAN, CLR_GREEN, CLR_BOLD_GREEN,
    CLR_MAGENTA, CLR_BOLD_MAGENTA, CLR_BLUE, CLR_BOLD_BLUE,
    CLR_YELLOW, CLR_BOLD_YELLOW, CLR_WHITE, CLR_BOLD_WHITE,
    CLR_RED, CLR_BOLD_RED
)


class Logger:
    """Centralized logging for termaite with color coding and level management."""
    
    def __init__(self, debug_enabled: bool = False):
        self.debug_enabled = debug_enabled
        
        # Level color mapping
        self.level_map = {
            "System": (CLR_CYAN, CLR_BOLD_CYAN),
            "User": (CLR_GREEN, CLR_BOLD_GREEN),
            "Plan Agent": (CLR_MAGENTA, CLR_BOLD_MAGENTA),
            "Action Agent": (CLR_BLUE, CLR_BOLD_BLUE),
            "Eval Agent": (CLR_YELLOW, CLR_BOLD_YELLOW),
            "LLM": (CLR_WHITE, CLR_BOLD_WHITE),
            "Command": (CLR_YELLOW, CLR_BOLD_YELLOW),
            "Error": (CLR_RED, CLR_BOLD_RED),
            "Warning": (CLR_YELLOW, CLR_BOLD_YELLOW),
            "Debug": (CLR_WHITE, CLR_BOLD_WHITE),
        }
    
    def set_debug(self, enabled: bool) -> None:
        """Enable or disable debug logging."""
        self.debug_enabled = enabled
    
    def get_current_timestamp(self) -> str:
        """Returns the current timestamp in YYYY-MM-DD HH:MM:SS format."""
        return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    def log_message(self, level: str, message: str) -> None:
        """Logs a message with a given level and color coding."""
        if level == "Debug" and not self.debug_enabled:
            return

        timestamp = self.get_current_timestamp()
        
        # Get color scheme for level
        if level in self.level_map:
            header_color, content_color = self.level_map[level]
        else:  # Default for unknown types
            header_color, content_color = CLR_WHITE, CLR_BOLD_WHITE

        # Choose output stream
        stream: TextIO = sys.stderr if level in ["Error", "Warning"] else sys.stdout

        # Format header
        header_text = f"{header_color}[{timestamp}] [{level}]: {CLR_RESET}"
        
        # Calculate indentation for multi-line messages
        indent_length = len(f"[{timestamp}] [{level}]: ")
        indent_str = ' ' * indent_length

        # Handle multi-line messages
        lines = message.splitlines()
        if not lines:
            print(f"{header_text}{content_color}{CLR_RESET}", file=stream)
            return

        # Print first line with header
        print(f"{header_text}{content_color}{lines[0]}{CLR_RESET}", file=stream)
        
        # Print subsequent lines with indentation
        for line in lines[1:]:
            print(f"{indent_str}{content_color}{line}{CLR_RESET}", file=stream)
        
        stream.flush()
    
    def system(self, message: str) -> None:
        """Log a system message."""
        self.log_message("System", message)
    
    def user(self, message: str) -> None:
        """Log a user message."""
        self.log_message("User", message)
    
    def plan_agent(self, message: str) -> None:
        """Log a plan agent message."""
        self.log_message("Plan Agent", message)
    
    def action_agent(self, message: str) -> None:
        """Log an action agent message."""
        self.log_message("Action Agent", message)
    
    def eval_agent(self, message: str) -> None:
        """Log an evaluation agent message."""
        self.log_message("Eval Agent", message)
    
    def llm(self, message: str) -> None:
        """Log an LLM-related message."""
        self.log_message("LLM", message)
    
    def command(self, message: str) -> None:
        """Log a command execution message."""
        self.log_message("Command", message)
    
    def error(self, message: str) -> None:
        """Log an error message."""
        self.log_message("Error", message)
    
    def warning(self, message: str) -> None:
        """Log a warning message."""
        self.log_message("Warning", message)
    
    def debug(self, message: str) -> None:
        """Log a debug message."""
        self.log_message("Debug", message)


# Global logger instance (will be initialized with proper debug setting later)
logger = Logger()

# Convenience functions for backward compatibility
def log_message(level: str, message: str) -> None:
    """Legacy logging function for backward compatibility."""
    logger.log_message(level, message)

def get_current_timestamp() -> str:
    """Legacy timestamp function for backward compatibility."""
    return logger.get_current_timestamp()
