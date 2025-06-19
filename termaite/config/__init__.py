"""Configuration management for termaite."""

from .manager import ConfigManager, create_config_manager
from .templates import CONFIG_TEMPLATE, PAYLOAD_TEMPLATE, RESPONSE_PATH_TEMPLATE

__all__ = [
    "ConfigManager",
    "create_config_manager",
    "CONFIG_TEMPLATE",
    "PAYLOAD_TEMPLATE", 
    "RESPONSE_PATH_TEMPLATE",
]
