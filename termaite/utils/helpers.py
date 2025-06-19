"""Helper utility functions for termaite."""

import datetime
import os
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List

from ..utils.logging import logger


def get_current_timestamp() -> str:
    """Returns the current timestamp in YYYY-MM-DD HH:MM:SS format."""
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')


def check_dependencies() -> None:
    """
    Checks for required Python libraries and some external CLI tools.
    CLI tools might be invoked by LLM-suggested commands or for getting command help.
    """
    # Python library dependencies are checked at import time.

    # CLI tools that might be used by `subprocess` when executing LLM-suggested commands
    # or when trying to get help output for arbitrary commands.
    # `timeout` and `sha256sum` CLI checks removed as Python has internal equivalents used by this script.
    required_cli_tools = ["curl", "awk", "sed", "grep", "head", "cut"] 
    
    missing_deps = []
    for cmd_name in required_cli_tools:
        if shutil.which(cmd_name) is None:
            missing_deps.append(cmd_name)
    
    if missing_deps:
        logger.warning(
            f"Potentially missing CLI tool(s): {', '.join(missing_deps)}. "
            "These might be needed if suggested by the LLM or for help output of certain commands. "
            "The script's core LLM calls and hashing use Python internals."
        )
    
    logger.debug("Dependency check (Python libs imported, some optional CLI tools checked).")


def get_nested_value(data: Dict[str, Any], path: str, default: Any = None) -> Any:
    """Access a nested value in a dictionary using a dot-separated path."""
    keys = path.split('.')
    current = data
    for key in keys:
        if isinstance(current, dict) and key in current:
            current = current[key]
        elif isinstance(current, list):
            try:
                idx = int(key)
                if 0 <= idx < len(current):
                    current = current[idx]
                else:
                    return default
            except ValueError:
                return default 
        else:
            return default
    return current


def get_current_context() -> Dict[str, str]:
    """Get current system context (time, directory, hostname)."""
    return {
        'current_time': get_current_timestamp(),
        'current_directory': os.getcwd(),
        'current_hostname': os.uname().nodename
    }


def format_template_string(template: str, **kwargs) -> str:
    """Safely format a template string with context variables."""
    try:
        return template.format(**kwargs)
    except KeyError as e:
        logger.error(f"Missing template variable: {e}")
        return template
    except Exception as e:
        logger.error(f"Template formatting error: {e}")
        return template


def ensure_directory_exists(directory: Path) -> None:
    """Ensure a directory exists, creating it if necessary."""
    try:
        directory.mkdir(parents=True, exist_ok=True)
        logger.debug(f"Directory ensured: {directory}")
    except Exception as e:
        logger.error(f"Failed to create directory {directory}: {e}")
        raise


def validate_file_path(file_path: Path, must_exist: bool = False) -> bool:
    """Validate a file path, optionally checking if it exists."""
    try:
        if must_exist and not file_path.exists():
            logger.error(f"Required file does not exist: {file_path}")
            return False
        
        if file_path.exists() and not file_path.is_file():
            logger.error(f"Path exists but is not a file: {file_path}")
            return False
            
        return True
    except Exception as e:
        logger.error(f"Error validating file path {file_path}: {e}")
        return False


def safe_file_write(file_path: Path, content: str, description: str = None) -> bool:
    """Safely write content to a file with error handling."""
    try:
        file_path.write_text(content)
        desc = description or f"file {file_path}"
        logger.system(f"Generated {desc}")
        return True
    except Exception as e:
        desc = description or f"file {file_path}"
        logger.error(f"Failed to write {desc}: {e}")
        return False
