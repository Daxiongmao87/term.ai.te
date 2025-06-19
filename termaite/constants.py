"""Constants used throughout the termaite package."""

from pathlib import Path
from colorama import Fore, Style

# Package information
PACKAGE_NAME = "termaite"

# Configuration paths
CONFIG_DIR = Path.home() / ".config" / "term.ai.te"
CONFIG_FILE = CONFIG_DIR / "config.yaml"
PAYLOAD_FILE = CONFIG_DIR / "payload.json"
RESPONSE_PATH_FILE = CONFIG_DIR / "response_path_template.txt"
CONTEXT_FILE = CONFIG_DIR / "context.json"
JQ_EQUIVALENT_ERROR_LOG = CONFIG_DIR / "python_json_processing_error.log"

# ANSI Color Codes (using colorama)
CLR_RESET = Style.RESET_ALL
CLR_RED = Fore.RED
CLR_BOLD_RED = Style.BRIGHT + Fore.RED
CLR_GREEN = Fore.GREEN
CLR_BOLD_GREEN = Style.BRIGHT + Fore.GREEN
CLR_YELLOW = Fore.YELLOW
CLR_BOLD_YELLOW = Style.BRIGHT + Fore.YELLOW
CLR_BLUE = Fore.BLUE
CLR_BOLD_BLUE = Style.BRIGHT + Fore.BLUE
CLR_MAGENTA = Fore.MAGENTA
CLR_BOLD_MAGENTA = Style.BRIGHT + Fore.MAGENTA
CLR_CYAN = Fore.CYAN
CLR_BOLD_CYAN = Style.BRIGHT + Fore.CYAN
CLR_WHITE = Fore.WHITE
CLR_BOLD_WHITE = Style.BRIGHT + Fore.WHITE

# Operation modes
OPERATION_MODES = ["normal", "gremlin", "goblin"]

# Agent decision types
AGENT_DECISIONS = [
    "CONTINUE_PLAN",
    "REVISE_PLAN", 
    "TASK_COMPLETE",
    "TASK_FAILED",
    "CLARIFY_USER"
]

# Default configuration values
DEFAULT_ENDPOINT = "http://localhost:11434/api/generate"
DEFAULT_COMMAND_TIMEOUT = 30
DEFAULT_OPERATION_MODE = "normal"
DEFAULT_ENABLE_DEBUG = False
DEFAULT_ALLOW_CLARIFYING_QUESTIONS = True

# Required CLI tools for dependency checking
REQUIRED_CLI_TOOLS = ["curl", "awk", "sed", "grep", "head", "cut"]
