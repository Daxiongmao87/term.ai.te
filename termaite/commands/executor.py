"""Command execution utilities for termaite."""

import subprocess
from typing import Optional, Tuple
from pathlib import Path

from ..utils.logging import logger


class CommandResult:
    """Represents the result of a command execution."""
    
    def __init__(self, 
                 command: str,
                 exit_code: int,
                 stdout: str = "",
                 stderr: str = "",
                 error_message: str = ""):
        self.command = command
        self.exit_code = exit_code
        self.stdout = stdout
        self.stderr = stderr
        self.error_message = error_message
    
    @property
    def output(self) -> str:
        """Combined stdout and stderr output."""
        combined = []
        if self.stdout.strip():
            combined.append(self.stdout.strip())
        if self.stderr.strip():
            combined.append(self.stderr.strip())
        return "\n".join(combined) if combined else ""
    
    @property
    def success(self) -> bool:
        """Whether the command executed successfully."""
        return self.exit_code == 0 and not self.error_message
    
    def __str__(self) -> str:
        return f"Exit Code: {self.exit_code}. Output:\n{self.output if self.output else '(no output)'}"


class CommandExecutor:
    """Executes shell commands with timeout and error handling."""
    
    def __init__(self, default_timeout: int = 30):
        """Initialize command executor.
        
        Args:
            default_timeout: Default timeout for command execution in seconds
        """
        self.default_timeout = default_timeout
    
    def execute(self, command: str, timeout: Optional[int] = None) -> CommandResult:
        """Execute a shell command with timeout and error handling.
        
        Args:
            command: Shell command to execute
            timeout: Command timeout in seconds (uses default if None)
            
        Returns:
            CommandResult object with execution details
        """
        if timeout is None:
            timeout = self.default_timeout
        
        logger.system(f"Executing command: {command} - timeout: {timeout}s")
        
        try:
            process = subprocess.run(
                command, 
                shell=True, 
                capture_output=True, 
                text=True,
                timeout=timeout
            )
            
            result = CommandResult(
                command=command,
                exit_code=process.returncode,
                stdout=process.stdout,
                stderr=process.stderr
            )
            
            logger.system(f"Command completed with exit code {result.exit_code}")
            if result.output:
                logger.system(f"Output:\n{result.output}")
            else:
                logger.system("(no output)")
            
            return result
            
        except subprocess.TimeoutExpired:
            error_msg = f"Command timed out after {timeout} seconds"
            logger.warning(error_msg)
            return CommandResult(
                command=command,
                exit_code=124,  # Standard timeout exit code
                error_message=error_msg
            )
            
        except Exception as e:
            error_msg = f"Error executing command: {e}"
            logger.error(error_msg)
            return CommandResult(
                command=command,
                exit_code=-1,
                error_message=error_msg
            )
    
    def get_command_help(self, command_name: str, timeout: Optional[int] = None) -> Tuple[bool, str]:
        """Get help output for a command.
        
        Args:
            command_name: Name of the command to get help for
            timeout: Timeout for help command execution
            
        Returns:
            Tuple of (success, help_output)
        """
        if timeout is None:
            timeout = min(self.default_timeout, 10)  # Shorter timeout for help commands
        
        logger.debug(f"Attempting to get help output for command: {command_name}")
        
        # Try common help flags
        for flag in ["--help", "-h"]:
            help_command = f"{command_name} {flag}"
            result = self.execute(help_command, timeout)
            
            if result.success and result.stdout:
                logger.debug(f"Successfully got help output for '{help_command}'")
                return True, result.stdout.strip()
            else:
                logger.debug(f"Help command '{help_command}' failed (exit: {result.exit_code}) or no output")
        
        logger.warning(f"Could not get help output for command: {command_name}")
        return False, ""
    
    def test_command_exists(self, command_name: str) -> bool:
        """Test if a command exists in the system PATH.
        
        Args:
            command_name: Name of the command to test
            
        Returns:
            True if command exists, False otherwise
        """
        result = self.execute(f"command -v {command_name}", timeout=5)
        return result.success and result.stdout.strip() != ""


def create_command_executor(timeout: int = 30) -> CommandExecutor:
    """Create a command executor with the specified default timeout."""
    return CommandExecutor(timeout)
