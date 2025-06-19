"""Utility functions and helpers for termaite."""

from .logging import logger, log_message, get_current_timestamp
from .helpers import (
    check_dependencies,
    get_nested_value,
    get_current_context,
    format_template_string,
    ensure_directory_exists,
    validate_file_path,
    safe_file_write
)

__all__ = [
    "logger",
    "log_message", 
    "get_current_timestamp",
    "check_dependencies",
    "get_nested_value",
    "get_current_context",
    "format_template_string",
    "ensure_directory_exists",
    "validate_file_path",
    "safe_file_write",
]
