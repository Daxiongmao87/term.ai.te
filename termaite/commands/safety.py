"""Command safety checks and validation for termaite."""

import re
from typing import List, Dict, Any, Tuple, Optional

from ..utils.logging import logger


class CommandSafetyChecker:
    """Performs safety checks on commands before execution."""
    
    def __init__(self):
        """Initialize safety checker with default dangerous patterns."""
        self.dangerous_patterns = [
            # Destructive file operations
            r'rm\s+.*-[rf].*/',
            r'rm\s+.*--recursive.*/',
            r'rm\s+.*--force.*/',
            r'rm\s+-[rf]+\s*\*',
            r'sudo\s+rm\s+.*-[rf]',
            
            # System directories
            r'rm\s+.*/(bin|boot|dev|etc|lib|proc|root|sbin|sys|usr|var)',
            r'rm\s+.*/\*',
            r'rm\s+/\*',
            
            # Format/partition operations
            r'mkfs\.',
            r'fdisk\s+/dev/',
            r'parted\s+/dev/',
            r'dd\s+.*of=/dev/',
            
            # Network dangerous operations
            r'curl\s+.*\|\s*sh',
            r'wget\s+.*\|\s*sh',
            r'curl\s+.*\|\s*bash',
            r'wget\s+.*\|\s*bash',
            
            # Fork bombs and resource exhaustion
            r':\(\)\{.*\}:',
            r'while\s+true.*do',
            
            # File descriptor manipulation
            r'exec\s+\d+',
            
            # Privilege escalation attempts
            r'sudo\s+.*passwd',
            r'su\s+-',
            
            # Database operations
            r'DROP\s+DATABASE',
            r'DROP\s+TABLE',
            
            # Process killers
            r'killall\s+.*-9',
            r'pkill\s+.*-9',
            r'kill\s+.*-9\s+1',
        ]
        
        self.warning_patterns = [
            # Potentially dangerous but sometimes legitimate
            r'sudo\s+',
            r'rm\s+.*',
            r'chmod\s+.*777',
            r'chown\s+.*root',
            r'mv\s+.*/.*',
            r'cp\s+.*>.*',
            r'>\s*/dev/',
            r'crontab\s+-',
            r'at\s+',
            r'nohup\s+',
        ]
    
    def check_command_safety(self, command: str, 
                           blacklisted_commands: Dict[str, Any] = None) -> Tuple[bool, str, List[str]]:
        """Check if a command is safe to execute.
        
        Args:
            command: Command to check
            blacklisted_commands: Dictionary of blacklisted commands
            
        Returns:
            Tuple of (is_safe, risk_level, warnings)
            risk_level: "safe", "warning", "dangerous"
        """
        warnings = []
        
        # Check blacklist first
        if blacklisted_commands:
            command_name = self._extract_command_name(command)
            if command_name in blacklisted_commands:
                return False, "dangerous", [f"Command '{command_name}' is blacklisted"]
        
        # Check for dangerous patterns
        for pattern in self.dangerous_patterns:
            if re.search(pattern, command, re.IGNORECASE):
                logger.warning(f"Dangerous pattern detected in command: {command}")
                return False, "dangerous", [f"Dangerous pattern detected: {pattern}"]
        
        # Check for warning patterns
        for pattern in self.warning_patterns:
            if re.search(pattern, command, re.IGNORECASE):
                warnings.append(f"Potentially risky pattern: {pattern}")
        
        # Additional semantic checks
        semantic_warnings = self._perform_semantic_checks(command)
        warnings.extend(semantic_warnings)
        
        if warnings:
            return True, "warning", warnings
        else:
            return True, "safe", []
    
    def _extract_command_name(self, command: str) -> str:
        """Extract the base command name from a command string."""
        # Remove leading sudo/env/etc.
        clean_command = re.sub(r'^(sudo\s+|env\s+)', '', command.strip())
        parts = clean_command.split()
        return parts[0] if parts else command
    
    def _perform_semantic_checks(self, command: str) -> List[str]:
        """Perform semantic safety checks on the command."""
        warnings = []
        
        # Check for commands with suspicious arguments
        if re.search(r'--force', command, re.IGNORECASE):
            warnings.append("Command uses --force flag")
        
        if re.search(r'-f\s', command):
            warnings.append("Command uses -f (force) flag")
        
        # Check for recursive operations
        if re.search(r'(-r|--recursive)', command, re.IGNORECASE):
            warnings.append("Command uses recursive flag")
        
        # Check for wildcard operations
        if '*' in command or '?' in command:
            warnings.append("Command uses wildcards")
        
        # Check for redirection to system files
        if re.search(r'>\s*/etc/', command):
            warnings.append("Command redirects output to /etc/ directory")
        
        # Check for pipe to shell
        if re.search(r'\|\s*(sh|bash|zsh|fish)', command):
            warnings.append("Command pipes output to shell interpreter")
        
        # Check for background processes
        if command.strip().endswith('&'):
            warnings.append("Command runs in background")
        
        # Check for network operations
        if re.search(r'(curl|wget|nc|netcat)', command, re.IGNORECASE):
            warnings.append("Command performs network operations")
        
        return warnings
    
    def get_safety_recommendation(self, command: str, risk_level: str, 
                                warnings: List[str]) -> str:
        """Get a safety recommendation for the command.
        
        Args:
            command: The command being checked
            risk_level: Risk level from check_command_safety
            warnings: Warnings from check_command_safety
            
        Returns:
            Formatted safety recommendation string
        """
        if risk_level == "safe":
            return "✅ Command appears safe to execute."
        
        elif risk_level == "warning":
            warning_text = "\n".join(f"⚠️  {w}" for w in warnings)
            return f"⚠️  Command has potential risks:\n{warning_text}\n\nProceed with caution."
        
        elif risk_level == "dangerous":
            warning_text = "\n".join(f"🚫 {w}" for w in warnings)
            return f"🚫 Command is potentially dangerous:\n{warning_text}\n\nExecution blocked for safety."
        
        return "❓ Unknown safety level."
    
    def add_dangerous_pattern(self, pattern: str):
        """Add a custom dangerous pattern."""
        if pattern not in self.dangerous_patterns:
            self.dangerous_patterns.append(pattern)
            logger.debug(f"Added dangerous pattern: {pattern}")
    
    def add_warning_pattern(self, pattern: str):
        """Add a custom warning pattern."""
        if pattern not in self.warning_patterns:
            self.warning_patterns.append(pattern)
            logger.debug(f"Added warning pattern: {pattern}")
    
    def remove_pattern(self, pattern: str):
        """Remove a pattern from both dangerous and warning lists."""
        if pattern in self.dangerous_patterns:
            self.dangerous_patterns.remove(pattern)
            logger.debug(f"Removed dangerous pattern: {pattern}")
        
        if pattern in self.warning_patterns:
            self.warning_patterns.remove(pattern)
            logger.debug(f"Removed warning pattern: {pattern}")


def create_safety_checker() -> CommandSafetyChecker:
    """Create a command safety checker with default patterns."""
    return CommandSafetyChecker()
