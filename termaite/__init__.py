"""
term.ai.te - LLM-powered shell assistant with multi-agent architecture.

This package provides an intelligent command-line assistant that uses Large Language Models
to understand natural language requests and execute shell commands safely through a
multi-agent system (Plan, Action, Evaluation).
"""

__version__ = "1.0.0"
__author__ = "term.ai.te Team"

# Main API imports
from .core.application import TermAIte, create_application
from .core.task_handler import TaskHandler, create_task_handler
from .config.manager import ConfigManager, create_config_manager

__all__ = [
    "TermAIte",
    "create_application",
    "TaskHandler", 
    "create_task_handler",
    "ConfigManager",
    "create_config_manager",
    "__version__",
]
