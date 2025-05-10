#!/usr/bin/env python3
# agent_shelly.py
# Python port of the agentic bash script.

# --- Standard Library Imports ---
import os
import sys
import subprocess
import json
import re
import datetime
import time
import shutil
import hashlib
import signal
import tempfile
import argparse
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple, Union

# --- Third-party Library Imports ---
# These libraries need to be installed:
# pip install PyYAML requests colorama
try:
    import yaml # PyYAML
    import requests
    from colorama import Fore, Style, init as colorama_init
except ImportError as e:
    print(f"Error: Missing required Python libraries. Please install them: pip install PyYAML requests colorama\nDetails: {e}")
    sys.exit(1)

# --- ANSI Color Codes (using colorama) ---
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

# --- Global Configuration Variables ---
SCRIPT_NAME = Path(__file__).name
CONFIG_DIR = Path.home() / ".config" / "agent-shelly"
CONFIG_FILE = CONFIG_DIR / "config.yaml"
PAYLOAD_FILE = CONFIG_DIR / "payload.json"
RESPONSE_PATH_FILE = CONFIG_DIR / "response_path_template.txt"
CONTEXT_FILE = CONFIG_DIR / "context.json"
# For logging Python-side JSON processing errors, analogous to bash JQ_ERROR_LOG
JQ_EQUIVALENT_ERROR_LOG = CONFIG_DIR / "python_json_processing_error.log"

# --- Global State for Agent Loop ---
ENABLE_DEBUG = False # Will be updated from config
CURRENT_PLAN_STR = ""
CURRENT_INSTRUCTION = ""
CURRENT_PLAN_ARRAY: List[str] = []
CURRENT_STEP_INDEX = 0
LAST_ACTION_TAKEN = ""
LAST_ACTION_RESULT = ""
USER_CLARIFICATION_RESPONSE = ""
LAST_EVAL_DECISION_TYPE = ""

# --- Template Definitions ---
CONFIG_TEMPLATE = """\
# config.yaml - REQUIRED - Configure this file for your environment and LLM
# Ensure this is valid YAML.
# endpoint: The URL of your LLM API endpoint.
# api_key: Your API key, if required by the endpoint. Leave empty or comment out if not needed.
# plan_prompt: The system-level instructions for the planning phase.
# action_prompt: The system-level instructions for the action phase.
# evaluate_prompt: The system-level instructions for the evaluation phase.
# allowed_commands: A list of commands the LLM is permitted to suggest.
#   Each command should have a brief description.
#   Example:
#     ls: "List directory contents."
#     cat: "Display file content."
#     echo: "Print text to the console."
# blacklisted_commands: A list of commands that are NEVER allowed.
#   Can be a list of strings or a map like allowed_commands.
#   Example:
#     - rm
#     - sudo
# operation_mode: normal # Options: normal, gremlin, goblin. Default: normal.
#   normal: Whitelisted commands require confirmation. Non-whitelisted commands are rejected.
#   gremlin: Whitelisted commands run without confirmation. Non-whitelisted commands prompt for approval (yes/no/add to whitelist).
#   goblin: All commands run without confirmation. USE WITH EXTREME CAUTION!
# command_timeout: 30 # Default timeout for commands in seconds
# enable_debug: false # Set to true for verbose debugging output
# allow_clarifying_questions: true # Set to false to prevent agents from asking clarifying questions

endpoint: "http://localhost:11434/api/generate" # Example for Ollama /api/generate

# api_key: "YOUR_API_KEY_HERE" # Uncomment and replace if your LLM requires an API key

plan_prompt: |
  You are the "Planner" module of a multi-step AI assistant specialized in the Linux shell environment.
  Your primary goal is to understand the user's overall task and create a step-by-step plan to achieve it.
  You operate with the current context:
  Time: {current_time}
  Directory: {current_directory}
  Hostname: {current_hostname}
  Refer to your detailed directives for output format (using <checklist>, <instruction>, and <think> tags, or <decision>CLARIFY_USER</decision>).
  {{if ALLOW_CLARIFYING_QUESTIONS}}
  If clarification is absolutely necessary, use <decision>CLARIFY_USER: Your question here</decision>.
  {{else}}
  You must not ask clarifying questions. Make reasonable assumptions and proceed with a plan.
  {{end}}

action_prompt: |
  You are the "Actor" module of a multi-step AI assistant specialized in the Linux shell environment.
  You will be given the user's original request, the overall plan (if available), and the specific current instruction to execute.
  Your primary goal is to determine the appropriate bash command (in ```agent_command```) or formulate a question (if allowed and necessary) based on the current instruction.
  You operate with the current context:
  Time: {current_time}
  Directory: {current_directory}
  Hostname: {current_hostname}
  {tool_instructions_addendum}
  Refer to your detailed directives for command generation and textual responses (using <think> tags).
  If you need to ask the user a question (and it's allowed), respond with the question directly, without any special tags other than <think>.

evaluate_prompt: |
  You are the "Evaluator" module of a multi-step AI assistant specialized in the Linux shell environment.
  You will be given the original request, plan, action taken, and result.
  Your primary goal is to assess the outcome and decide the next course of action (using <decision>TAG: message</decision> and <think> tags).
  You operate with the current context:
  Time: {current_time}
  Directory: {current_directory}
  Hostname: {current_hostname}
  Refer to your detailed directives for decision making (CONTINUE_PLAN, REVISE_PLAN, TASK_COMPLETE, CLARIFY_USER, TASK_FAILED).
  {{if ALLOW_CLARIFYING_QUESTIONS}}
  If clarification from the user is absolutely necessary to evaluate the step, use <decision>CLARIFY_USER: Your question here</decision>.
  {{else}}
  You must not ask clarifying questions. Evaluate based on the information provided.
  {{end}}

allowed_commands:
  ls: "List directory contents. Use common options like -l, -a, -h as needed."
  cat: "Display file content. Example: cat filename.txt"
  echo: "Print text. Example: echo 'Hello World'"
  # Add more commands and their descriptions as needed.

blacklisted_commands:
  - "rm -rf /" # Example of a dangerous command to blacklist
  # Add other commands you want to explicitly forbid.

operation_mode: normal # Default operation mode
command_timeout: 30 # Default timeout for commands in seconds
enable_debug: false
allow_clarifying_questions: true
"""

PAYLOAD_TEMPLATE = """{
  "model": "your-model-name:latest",
  "system": "<system_prompt>",
  "prompt": "<user_prompt>",
  "stream": false,
  "options": {
    "temperature": 0.7,
    "top_k": 50,
    "top_p": 0.95,
    "num_ctx": 4096
  }
}"""

RESPONSE_PATH_TEMPLATE = """\
# response_path_template.txt - REQUIRED
# This file must contain a jq-compatible path to extract the LLM's main response text
# from the LLM's JSON output.
# Example for OpenAI API: .choices[0].message.content
# Example for Ollama /api/generate: .response
# Example for Ollama /api/chat (if response is {"message": {"content": "..."}}): .message.content
.response
"""

# --- Global Dictionaries for Commands ---
ALLOWED_COMMAND_CHECK_MAP: Dict[str, str] = {} # Stores command_name: description
BLACKLISTED_COMMAND_CHECK_MAP: Dict[str, Union[str, bool]] = {} # Stores command_name: True or description

# --- Helper Functions ---
def get_current_timestamp() -> str:
    """Returns the current timestamp in YYYY-MM-DD HH:MM:SS format."""
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

def log_message(level: str, message: str) -> None:
    """Logs a message with a given level and color coding."""
    if level == "Debug" and not ENABLE_DEBUG:
        return

    timestamp = get_current_timestamp()
    header_color = ""
    content_color = ""
    stream = sys.stdout

    level_map = {
        "System": (CLR_CYAN, CLR_BOLD_CYAN),
        "User": (CLR_GREEN, CLR_BOLD_GREEN),
        "Plan Agent": (CLR_MAGENTA, CLR_BOLD_MAGENTA),
        "Action Agent": (CLR_BLUE, CLR_BOLD_BLUE),
        "Eval Agent": (CLR_YELLOW, CLR_BOLD_YELLOW),
        "LLM": (CLR_WHITE, CLR_BOLD_WHITE),
        "Command": (CLR_YELLOW, CLR_BOLD_YELLOW), # Shared
        "Error": (CLR_RED, CLR_BOLD_RED),
        "Warning": (CLR_YELLOW, CLR_BOLD_YELLOW), # Shared
        "Debug": (CLR_WHITE, CLR_BOLD_WHITE), # Shared
    }

    if level in level_map:
        header_color, content_color = level_map[level]
    else: # Default for unknown types
        header_color, content_color = CLR_WHITE, CLR_BOLD_WHITE

    if level in ["Error", "Warning"]:
        stream = sys.stderr

    header_text = f"{header_color}[{timestamp}] [{level}]: {CLR_RESET}"
    
    indent_length = len(f"[{timestamp}] [{level}]: ") 
    indent_str = ' ' * indent_length

    lines = message.splitlines()
    if not lines: 
        print(f"{header_text}{content_color}{CLR_RESET}", file=stream)
        return

    print(f"{header_text}{content_color}{lines[0]}{CLR_RESET}", file=stream)
    for line in lines[1:]:
        print(f"{indent_str}{content_color}{line}{CLR_RESET}", file=stream)
    
    stream.flush()


def check_dependencies() -> None:
    """
    Checks for required Python libraries and some external CLI tools.
    CLI tools might be invoked by LLM-suggested commands or for getting command help.
    """
    log_message("System", f"Python version: {sys.version.split()[0]}")

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
        log_message("Warning", 
                    f"Potentially missing CLI tool(s): {', '.join(missing_deps)}. "
                    "These might be needed if suggested by the LLM or for help output of certain commands. "
                    "The script's core LLM calls and hashing use Python internals.")
    
    log_message("Debug", "Dependency check (Python libs imported, some optional CLI tools checked).")


def initial_setup() -> bool:
    """Creates config directory and default files if they don't exist."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    missing_setup_file = False

    if not CONFIG_FILE.exists():
        try:
            current_time_val = get_current_timestamp()
            current_dir_val = os.getcwd()
            current_hostname_val = os.uname().nodename
            
            # Ensure prompt templates in config.yaml are authored carefully if they need
            # to contain literal curly braces, as .format() is used here.
            formatted_config_template = CONFIG_TEMPLATE.format(
                current_time=current_time_val,
                current_directory=current_dir_val,
                current_hostname=current_hostname_val,
                tool_instructions_addendum="{tool_instructions_addendum}" 
            )
            CONFIG_FILE.write_text(formatted_config_template)
            log_message("System", f"Generated config template: {CONFIG_FILE}")
            missing_setup_file = True
        except Exception as e:
            log_message("Error", f"Failed to write config template {CONFIG_FILE}: {e}")
            sys.exit(1)

    if not PAYLOAD_FILE.exists():
        try:
            PAYLOAD_FILE.write_text(PAYLOAD_TEMPLATE)
            log_message("System", f"Generated payload template: {PAYLOAD_FILE}")
            log_message("System", f"IMPORTANT: Review and edit {PAYLOAD_FILE} to be valid JSON matching your LLM API.")
            missing_setup_file = True
        except Exception as e:
            log_message("Error", f"Failed to write payload template {PAYLOAD_FILE}: {e}")
            sys.exit(1)

    if not RESPONSE_PATH_FILE.exists():
        try:
            RESPONSE_PATH_FILE.write_text(RESPONSE_PATH_TEMPLATE)
            log_message("System", f"Generated response path template: {RESPONSE_PATH_FILE}")
            missing_setup_file = True
        except Exception as e:
            log_message("Error", f"Failed to write response path template {RESPONSE_PATH_FILE}: {e}")
            sys.exit(1)

    if missing_setup_file:
        log_message("System", f"One or more configuration templates were generated in {CONFIG_DIR}.")
        log_message("System", f"Please review and configure them before running {SCRIPT_NAME} again.")
        return False 
    return True 

def _get_nested_value(data: Dict[str, Any], path: str, default: Any = None) -> Any:
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

def load_config() -> Dict[str, Any]:
    """Loads configuration from CONFIG_FILE."""
    global ENABLE_DEBUG, ALLOWED_COMMAND_CHECK_MAP, BLACKLISTED_COMMAND_CHECK_MAP
    
    if not CONFIG_FILE.exists():
        log_message("Error", f"Configuration file {CONFIG_FILE} not found.")
        sys.exit(1)

    try:
        with open(CONFIG_FILE, 'r') as f:
            config_data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        log_message("Error", f"Error parsing YAML file {CONFIG_FILE}: {e}")
        sys.exit(1)
    except IOError as e:
        log_message("Error", f"Could not read {CONFIG_FILE}: {e}")
        sys.exit(1)

    if not isinstance(config_data, dict):
        log_message("Error", f"{CONFIG_FILE} is not a valid YAML dictionary.")
        sys.exit(1)

    required_fields = ["endpoint", "plan_prompt", "action_prompt", "evaluate_prompt", 
                       "allowed_commands", "operation_mode", "command_timeout"]
    for field in required_fields:
        if field not in config_data:
            log_message("Error", f"Required key '.{field}' missing in {CONFIG_FILE}.")
            sys.exit(1)
        if config_data[field] is None and field not in ["api_key", "blacklisted_commands"]:
             log_message("Error", f"Required key '.{field}' is null/empty in {CONFIG_FILE}.")
             sys.exit(1)

    ENABLE_DEBUG = config_data.get("enable_debug", False)
    if not isinstance(ENABLE_DEBUG, bool):
        log_message("Warning", f"ENABLE_DEBUG in {CONFIG_FILE} must be true/false. Defaulting to false.")
        ENABLE_DEBUG = False
    log_message("Debug", f"ENABLE_DEBUG set to: {ENABLE_DEBUG}")

    allowed_cmds_config = config_data.get("allowed_commands", {})
    if isinstance(allowed_cmds_config, dict):
        ALLOWED_COMMAND_CHECK_MAP = {str(k): str(v) for k, v in allowed_cmds_config.items()}
    else:
        log_message("Warning", f"'.allowed_commands' in {CONFIG_FILE} is not a map. No allowed commands loaded.")
        ALLOWED_COMMAND_CHECK_MAP = {}
    log_message("Debug", f"Loaded {len(ALLOWED_COMMAND_CHECK_MAP)} allowed commands.")

    blacklisted_cmds_config = config_data.get("blacklisted_commands", [])
    if isinstance(blacklisted_cmds_config, list): 
        BLACKLISTED_COMMAND_CHECK_MAP = {str(cmd): True for cmd in blacklisted_cmds_config}
    elif isinstance(blacklisted_cmds_config, dict): 
        BLACKLISTED_COMMAND_CHECK_MAP = {str(k): str(v) for k, v in blacklisted_cmds_config.items()}
    else:
        log_message("Warning", f"'.blacklisted_commands' in {CONFIG_FILE} is not a list or map. No blacklisted commands loaded.")
        BLACKLISTED_COMMAND_CHECK_MAP = {}
    log_message("Debug", f"Loaded {len(BLACKLISTED_COMMAND_CHECK_MAP)} blacklisted commands.")

    op_mode = config_data.get("operation_mode", "normal")
    if op_mode not in ["normal", "gremlin", "goblin"]:
        log_message("Error", f"OPERATION_MODE in {CONFIG_FILE} must be 'normal', 'gremlin', or 'goblin', got '{op_mode}'.")
        sys.exit(1)
    config_data["operation_mode"] = op_mode

    cmd_timeout = config_data.get("command_timeout", 30)
    if not (isinstance(cmd_timeout, int) and cmd_timeout >= 0):
        log_message("Error", f"COMMAND_TIMEOUT ('{cmd_timeout}') in {CONFIG_FILE} must be a non-negative integer.")
        sys.exit(1)
    config_data["command_timeout"] = cmd_timeout

    allow_questions = config_data.get("allow_clarifying_questions", True)
    if not isinstance(allow_questions, bool):
        log_message("Warning", f"ALLOW_CLARIFYING_QUESTIONS in {CONFIG_FILE} must be true/false. Defaulting to true.")
        allow_questions = True
    config_data["allow_clarifying_questions"] = allow_questions
    log_message("Debug", f"ALLOW_CLARIFYING_QUESTIONS set to: {allow_questions}")
    
    return config_data

def get_response_path() -> str:
    """Reads the response path from RESPONSE_PATH_FILE."""
    if not RESPONSE_PATH_FILE.exists():
        log_message("Error", f"Response path file {RESPONSE_PATH_FILE} not found.")
        sys.exit(1)
    try:
        with open(RESPONSE_PATH_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    return line
        log_message("Error", f"No valid response path found in {RESPONSE_PATH_FILE}.")
        sys.exit(1)
    except IOError as e:
        log_message("Error", f"Could not read {RESPONSE_PATH_FILE}: {e}")
        sys.exit(1)

def append_context(user_prompt_for_context: str, raw_llm_output_for_context: str, config: Dict[str, Any]) -> bool:
    """Appends interaction to the context file, organized by PWD hash."""
    pwd_hash = hashlib.sha256(os.getcwd().encode('utf-8')).hexdigest()
    timestamp_now = datetime.datetime.utcnow().isoformat() + "Z"
    
    context_entry: Dict[str, Any]
    try:
        llm_resp_json = json.loads(raw_llm_output_for_context)
        context_entry = {
            "type": "success",
            "user_prompt": user_prompt_for_context,
            "llm_full_response": llm_resp_json,
            "timestamp": timestamp_now
        }
    except json.JSONDecodeError as e_json:
        context_entry = {
            "type": "error",
            "user_prompt": user_prompt_for_context,
            "llm_error_message": raw_llm_output_for_context,
            "timestamp": timestamp_now
        }
        # Log this specific JSON error to the dedicated log file
        try:
            with open(JQ_EQUIVALENT_ERROR_LOG, 'a') as f_err:
                f_err.write(f"[{timestamp_now}] Error decoding LLM output as JSON for context storage:\n")
                f_err.write(f"Input: {raw_llm_output_for_context}\nError: {e_json}\n---\n")
        except IOError as e_log:
            log_message("Warning", f"Could not write to {JQ_EQUIVALENT_ERROR_LOG}: {e_log}")


    current_context_data: Dict[str, List[Dict[str, Any]]] = {}
    if CONTEXT_FILE.exists():
        try:
            with open(CONTEXT_FILE, 'r') as f:
                current_context_data = json.load(f)
            if not isinstance(current_context_data, dict):
                log_message("Warning", f"{CONTEXT_FILE} was not a valid JSON object. Initializing.")
                current_context_data = {}
        except (json.JSONDecodeError, IOError) as e:
            log_message("Warning", f"Error reading {CONTEXT_FILE} ({e}). Initializing.")
            try:
                with open(JQ_EQUIVALENT_ERROR_LOG, 'a') as f_err:
                    f_err.write(f"[{timestamp_now}] Error reading or decoding existing context file {CONTEXT_FILE}:\nError: {e}\n---\n")
            except IOError as e_log:
                log_message("Warning", f"Could not write to {JQ_EQUIVALENT_ERROR_LOG}: {e_log}")

            backup_file = CONTEXT_FILE.with_suffix(f".invalid.{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}")
            try:
                shutil.move(str(CONTEXT_FILE), str(backup_file))
                log_message("System", f"Backed up invalid context file to {backup_file}")
            except Exception as move_err:
                log_message("Error", f"Could not back up invalid context file: {move_err}")
            current_context_data = {}
            
    if pwd_hash not in current_context_data:
        current_context_data[pwd_hash] = []
    
    if not isinstance(current_context_data.get(pwd_hash), list):
        log_message("Warning", f"Context for PWD hash '{pwd_hash}' was not a list. Re-initializing.")
        current_context_data[pwd_hash] = []
        
    current_context_data[pwd_hash].append(context_entry)

    try:
        with tempfile.NamedTemporaryFile('w', delete=False, dir=CONFIG_DIR, suffix='.json') as tmp_f:
            json.dump(current_context_data, tmp_f, indent=2)
            temp_name = tmp_f.name
        shutil.move(temp_name, str(CONTEXT_FILE))
        return True
    except (IOError, json.JSONDecodeError) as e: # Catch potential error during dump or move
        log_message("Error", f"Failed to write updated context to {CONTEXT_FILE}: {e}")
        try:
            with open(JQ_EQUIVALENT_ERROR_LOG, 'a') as f_err:
                f_err.write(f"[{timestamp_now}] Error writing context file {CONTEXT_FILE}:\nError: {e}\n---\n")
        except IOError as e_log:
            log_message("Warning", f"Could not write to {JQ_EQUIVALENT_ERROR_LOG}: {e_log}")
        if 'temp_name' in locals() and Path(temp_name).exists():
            Path(temp_name).unlink()
        return False

def prepare_payload(phase: str, current_prompt_content: str, config: Dict[str, Any]) -> Optional[str]:
    """Prepares the JSON payload for the LLM API call."""
    system_prompt_for_phase = ""
    phase_map = {
        "plan": config.get("plan_prompt", ""),
        "action": config.get("action_prompt", ""),
        "evaluate": config.get("evaluate_prompt", "")
    }
    if phase not in phase_map:
        log_message("Error", f"Invalid phase '{phase}' provided to prepare_payload.")
        return None
    system_prompt_for_phase = phase_map[phase]

    # WARNING: Prompts from config.yaml should be authored carefully if they need to contain
    # literal curly braces, as Python's .format() method is used below. Double {{ or }}
    # to escape them if they are not intended as placeholders for .format().
    context_vars = {
        "current_time": get_current_timestamp(),
        "current_directory": os.getcwd(),
        "current_hostname": os.uname().nodename,
        "tool_instructions_addendum": "" 
    }

    allow_cq = config.get("allow_clarifying_questions", True)
    if "{{if ALLOW_CLARIFYING_QUESTIONS}}" in system_prompt_for_phase:
        if allow_cq:
            system_prompt_for_phase = re.sub(
                r"\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}(.*?)\{\{else\}\}.*?\{\{end\}\}", 
                r"\1", system_prompt_for_phase, flags=re.DOTALL
            )
        else:
            system_prompt_for_phase = re.sub(
                r"\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}.*?\{\{else\}\}(.*?)\{\{end\}\}", 
                r"\1", system_prompt_for_phase, flags=re.DOTALL
            )
        system_prompt_for_phase = system_prompt_for_phase.replace("{{if ALLOW_CLARIFYING_QUESTIONS}}", "")
        system_prompt_for_phase = system_prompt_for_phase.replace("{{else}}", "")
        system_prompt_for_phase = system_prompt_for_phase.replace("{{end}}", "")

    tool_instructions_addendum_text = ""
    if phase == "action":
        operation_mode = config.get("operation_mode", "normal")
        if operation_mode == "normal":
            if ALLOWED_COMMAND_CHECK_MAP:
                 allowed_commands_yaml_block = yaml.dump(
                     {"allowed_commands": ALLOWED_COMMAND_CHECK_MAP}, 
                     indent=2, default_flow_style=False, sort_keys=False
                 )
                 tool_instructions_addendum_text = (
                    "You are permitted to use ONLY the following commands. Their names and descriptions are provided below in YAML format. "
                    "Adhere strictly to these commands and their specified uses:\n\n```yaml\n"
                    f"{allowed_commands_yaml_block.strip()}\n```\n\n"
                    "If an appropriate command is not on this list, you should state that you cannot perform the action "
                    "with the available commands and explain why.\n"
                )
            else:
                log_message("Warning", "NORMAL mode: allowed_commands list is empty. LLM instructed it cannot use commands.")
                tool_instructions_addendum_text = (
                    "The list of allowed commands is currently empty. Therefore, you cannot suggest any shell commands. "
                    "You must state that you cannot perform any action requiring a command and explain this limitation.\n"
                )
        elif operation_mode in ["gremlin", "goblin"]:
            tool_instructions_addendum_text = (
                f"You are operating in {operation_mode} mode. This mode allows you to suggest any standard Linux shell command "
                "you deem best for the current task step. You are NOT restricted to a predefined list. "
                "Choose the most appropriate and effective command to achieve the step's goal. "
                "Ensure the command is safe and directly relevant to the task.\n\n"
            )
    context_vars["tool_instructions_addendum"] = tool_instructions_addendum_text.strip()
    
    try:
        final_system_prompt_for_phase = system_prompt_for_phase.format(**context_vars)
    except KeyError as e:
        log_message("Warning", f"Missing placeholder in prompt template for phase '{phase}': {e}. Using raw prompt.")
        final_system_prompt_for_phase = system_prompt_for_phase 

    try:
        with open(PAYLOAD_FILE, 'r') as f:
            payload_data_str = f.read()
        
        # Use json.dumps to correctly escape the content for JSON string values
        escaped_system_prompt = json.dumps(final_system_prompt_for_phase.strip())[1:-1]
        escaped_user_prompt = json.dumps(current_prompt_content.strip())[1:-1]

        payload_data_str = payload_data_str.replace("<system_prompt>", escaped_system_prompt)
        payload_data_str = payload_data_str.replace("<user_prompt>", escaped_user_prompt)
        
        json.loads(payload_data_str) 
        return payload_data_str

    except FileNotFoundError:
        log_message("Error", f"{PAYLOAD_FILE} not found.")
        return None
    except json.JSONDecodeError as e:
        log_message("Error", f"{PAYLOAD_FILE} (after substitutions) is not valid JSON: {e}.")
        log_message("Debug", f"Problematic payload string before JSON parsing: {payload_data_str}")
        return None
    except Exception as e:
        log_message("Error", f"Failed to prepare payload for phase '{phase}': {e}")
        return None

# --- Command Parsing Functions ---
def parse_suggested_command(llm_output: str) -> Optional[str]:
    match = re.search(r"```agent_command\s*\n(.*?)\n```", llm_output, re.DOTALL)
    return match.group(1).strip() if match else None

def parse_llm_thought(llm_output: str) -> str:
    match = re.search(r"<think>(.*?)</think>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""

def parse_llm_plan(llm_output: str) -> str:
    match = re.search(r"<checklist>(.*?)</checklist>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""

def parse_llm_instruction(llm_output: str) -> str:
    match = re.search(r"<instruction>(.*?)</instruction>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""

def parse_llm_decision(llm_output: str) -> str:
    match = re.search(r"<decision>(.*?)</decision>", llm_output, re.DOTALL)
    return match.group(1).strip() if match else ""

def get_llm_description_and_add_to_config(command_name: str, config: Dict[str, Any], response_path: str) -> bool:
    """Gets LLM description for a command and adds it to config.yaml and global map."""
    global ALLOWED_COMMAND_CHECK_MAP
    log_message("System", f"Attempting to get help output for command: {command_name}")
    help_output = ""
    cmd_timeout_val = config.get("command_timeout", 10)

    for flag in ["--help", "-h"]:
        try:
            process = subprocess.run(
                f"{command_name} {flag}", shell=True, capture_output=True, text=True,
                timeout=cmd_timeout_val, check=False 
            )
            if process.returncode == 0 and process.stdout:
                help_output = process.stdout.strip()
                log_message("Debug", f"Successfully got help output for '{command_name} {flag}'.")
                break
            else:
                log_message("Debug", f"Cmd '{command_name} {flag}' failed (status: {process.returncode}) or no output.")
        except subprocess.TimeoutExpired:
            log_message("Warning", f"Timeout getting help for '{command_name} {flag}'.")
        except Exception as e:
            log_message("Warning", f"Error getting help for '{command_name} {flag}': {e}")
    
    max_help_length = 1500
    if len(help_output) > max_help_length:
        log_message("Warning", f"Help output for '{command_name}' ({len(help_output)} chars) truncated.")
        help_output = help_output[:max_help_length] + "..."

    log_message("System", f"Requesting LLM to describe command: {command_name}")
    system_prompt_for_description = (
        "You are an assistant that provides concise descriptions of Linux commands. "
        "Your response MUST be a valid JSON object containing a single key 'description' "
        "whose value is a short, one-sentence command description. "
        "Do NOT include any other text, explanations, or XML tags in your response. Output ONLY the JSON object."
    )
    
    description_prompt_content: str
    if help_output:
        description_prompt_content = (
            f"Based on the following help output for the Linux shell command '{command_name}', "
            "provide your response as a JSON object containing a single key \"description\" "
            "with a short, one-sentence string value describing the command's primary purpose. "
            "Output ONLY the JSON object.\n\nHelp Output:\n```\n"
            f"{help_output}\n```\n\nJSON Output:"
        )
    else:
        description_prompt_content = (
            f"Describe the general purpose and typical usage of the Linux shell command '{command_name}'. "
            "Provide your response as a JSON object containing a single key \"description\" "
            "with a short, one-sentence string value. Do not include any other text or formatting "
            "outside the JSON object. Example for 'ls': {\"description\": \"List directory contents.\"}\n\nJSON Output:"
        )
    
    # Corrected: Directly construct payload for this specific LLM call.
    # The previous, incorrect call to prepare_payload has been removed.
    desc_payload_str: Optional[str] = None
    try:
        payload_template_dict = json.loads(PAYLOAD_FILE.read_text())
        # Override system and prompt fields for this specific call
        payload_template_dict["system"] = system_prompt_for_description
        payload_template_dict["prompt"] = description_prompt_content
        # Ensure other essential parts of the payload like "model" are preserved from the template
        desc_payload_str = json.dumps(payload_template_dict)
    except Exception as e:
        log_message("Error", f"Failed to create description payload for '{command_name}': {e}")
        return False

    if not desc_payload_str: # Should not happen if above try succeeded
        log_message("Error", f"Payload string for description of '{command_name}' is empty.")
        return False

    log_message("Debug", f"Description Payload for '{command_name}': {desc_payload_str}")

    try:
        headers = {"Content-Type": "application/json"}
        if config.get("api_key"):
            headers["Authorization"] = f"Bearer {config['api_key']}"
        
        response = requests.post(config["endpoint"], headers=headers, data=desc_payload_str, 
                                 timeout=config.get("command_timeout", 60)) # Potentially longer timeout for generative task
        response.raise_for_status() 
        llm_desc_response_raw = response.text
    except requests.exceptions.RequestException as e:
        log_message("Error", f"LLM API request failed for cmd description '{command_name}': {e}")
        return False

    if not llm_desc_response_raw:
        log_message("Error", f"No response from LLM for description of '{command_name}'.")
        return False
    log_message("Debug", f"LLM Raw Full Response for description of '{command_name}': {llm_desc_response_raw}")

    try:
        llm_full_json = json.loads(llm_desc_response_raw)
        llm_response_field_content = _get_nested_value(llm_full_json, response_path.lstrip('.'))
        if llm_response_field_content is None:
            raise ValueError("Response path extraction returned None.")
    except (json.JSONDecodeError, ValueError) as e:
        log_message("Error", f"Failed to parse/extract LLM response field for '{command_name}' using RESPONSE_PATH ('{response_path}'). Error: {e}")
        log_message("Debug", f"Raw LLM Full Response: {llm_desc_response_raw}")
        return False
    
    log_message("Debug", f"LLM Response Field Content for '{command_name}' (pre-JSON isolation): [{llm_response_field_content}]")

    extracted_json_object_str = ""
    if isinstance(llm_response_field_content, str):
        match = re.search(r"(\{.*?\})", llm_response_field_content, re.DOTALL) # Find first JSON-like object
        if match:
            extracted_json_object_str = match.group(1)
        else: 
            extracted_json_object_str = llm_response_field_content.strip() # Assume the whole field is the JSON string
    elif isinstance(llm_response_field_content, dict):
         extracted_json_object_str = json.dumps(llm_response_field_content)
    else:
        log_message("Error", f"LLM response field for '{command_name}' is not str or dict: {type(llm_response_field_content)}")
        return False

    if not extracted_json_object_str:
        log_message("Error", f"Could not isolate JSON object from LLM response field for '{command_name}'.")
        log_message("Debug", f"Searched content: [{llm_response_field_content}]")
        return False
    log_message("Debug", f"Isolated JSON Object for '{command_name}': [{extracted_json_object_str}]")
    
    command_description = ""
    try:
        desc_json = json.loads(extracted_json_object_str)
        command_description = desc_json.get("description", "").strip()
    except json.JSONDecodeError:
        log_message("Error", f"Failed to parse isolated JSON object for '{command_name}': [{extracted_json_object_str}]")
        return False

    if not command_description:
        log_message("Error", f"Extracted cmd description for '{command_name}' is empty or missing '.description' key.")
        return False
    log_message("System", f"LLM suggested description for '{command_name}': '{command_description}'")

    try:
        with open(CONFIG_FILE, 'r') as f:
            current_config_yaml = yaml.safe_load(f)
        
        if "allowed_commands" not in current_config_yaml or not isinstance(current_config_yaml["allowed_commands"], dict):
            current_config_yaml["allowed_commands"] = {}
        current_config_yaml["allowed_commands"][command_name] = command_description

        with tempfile.NamedTemporaryFile('w', delete=False, dir=CONFIG_DIR, suffix='.yaml', encoding='utf-8') as tmp_f:
            yaml.dump(current_config_yaml, tmp_f, sort_keys=False, indent=2, default_flow_style=False)
            temp_name = tmp_f.name
        
        with open(temp_name, 'r') as f_check: # Validate temp file
            yaml.safe_load(f_check) 

        shutil.move(temp_name, str(CONFIG_FILE))
        log_message("System", f"Command '{command_name}' with description added/updated in {CONFIG_FILE}.")
        ALLOWED_COMMAND_CHECK_MAP[command_name] = command_description 
        return True
    except (yaml.YAMLError, IOError, Exception) as e:
        log_message("Error", f"Error updating {CONFIG_FILE} for command '{command_name}': {e}")
    
    if 'temp_name' in locals() and Path(temp_name).exists():
        Path(temp_name).unlink()
    return False

def prompt_for_command_permission_and_update_config(cmd_to_check: str, config_data: Dict[str, Any], response_path: str) -> int:
    """Prompts user for permission. Returns: 0 (allowed), 1 (denied), 2 (cancel task)"""
    print(f"{CLR_YELLOW}The agent wants to use the command '{CLR_BOLD_YELLOW}{cmd_to_check}{CLR_YELLOW}', which is not in the allowed list.{CLR_RESET}")
    while True:
        user_decision = input(f"{CLR_YELLOW}Allow? (y)es/(n)o/(a)lways/(c)cancel task: {CLR_RESET}").lower()
        if user_decision in ['y', 'n', 'a', 'c']:
            break
        print(f"{CLR_RED}Invalid choice. Enter y, n, a, or c.{CLR_RESET}")

    if user_decision == 'y':
        log_message("User", f"Allowed command '{cmd_to_check}' for this instance.")
        return 0
    elif user_decision == 'n':
        log_message("User", f"Denied command '{cmd_to_check}' for this instance.")
        return 1
    elif user_decision == 'c':
        log_message("User", "User chose to cancel the task.")
        return 2
    elif user_decision == 'a':
        log_message("User", f"Chose 'always' allow for '{cmd_to_check}'. Adding to config.")
        if get_llm_description_and_add_to_config(cmd_to_check, config_data, response_path):
            log_message("System", f"Command '{cmd_to_check}' added to allowed_commands.")
            return 0
        else:
            log_message("Error", f"Failed to add '{cmd_to_check}' to config. Not executed.")
            return 1
    return 1 

# --- Main Task Handling Logic ---
def handle_task(initial_user_prompt: str, config_data: Dict[str, Any], response_path_jq: str) -> bool:
    """Handles a single task through the Plan-Act-Evaluate loop."""
    global CURRENT_PLAN_STR, CURRENT_INSTRUCTION, CURRENT_PLAN_ARRAY, CURRENT_STEP_INDEX
    global LAST_ACTION_TAKEN, LAST_ACTION_RESULT, USER_CLARIFICATION_RESPONSE, LAST_EVAL_DECISION_TYPE

    CURRENT_PLAN_STR = ""
    CURRENT_INSTRUCTION = ""
    CURRENT_PLAN_ARRAY = []
    CURRENT_STEP_INDEX = 0
    LAST_ACTION_TAKEN = ""
    LAST_ACTION_RESULT = ""
    USER_CLARIFICATION_RESPONSE = "" 
    LAST_EVAL_DECISION_TYPE = ""    

    current_context_for_llm = initial_user_prompt
    task_status = "IN_PROGRESS" 
    current_iteration = 0

    log_message("User", f"Starting task: {initial_user_prompt}")

    while task_status == "IN_PROGRESS":
        current_iteration += 1
        log_message("System", f"Iteration: {current_iteration}")

        needs_new_plan = not CURRENT_PLAN_STR or \
                         LAST_EVAL_DECISION_TYPE == "REVISE_PLAN" or \
                         (USER_CLARIFICATION_RESPONSE and LAST_EVAL_DECISION_TYPE in ["CLARIFY_USER", "PLANNER_CLARIFY"])

        if needs_new_plan:
            log_message("System", "Entering PLAN phase.")
            planner_input_prompt = current_context_for_llm 

            payload_str = prepare_payload("plan", planner_input_prompt, config_data)
            if not payload_str:
                log_message("Error", "Failed to prepare payload for PLAN phase.")
                task_status = "TASK_FAILED"; break
            
            try:
                headers = {"Content-Type": "application/json"}
                if config_data.get("api_key"):
                    headers["Authorization"] = f"Bearer {config_data['api_key']}"
                response = requests.post(config_data["endpoint"], headers=headers, data=payload_str, 
                                         timeout=config_data.get("command_timeout", 60) * 2) 
                response.raise_for_status()
                raw_llm_response = response.text
            except requests.exceptions.RequestException as e:
                log_message("Error", f"LLM API request failed for PLAN phase: {e}")
                task_status = "TASK_FAILED"; break
            
            if not raw_llm_response:
                log_message("Error", "No response from LLM for PLAN phase.")
                task_status = "TASK_FAILED"; break

            append_context(f"Planner Input: {planner_input_prompt}", raw_llm_response, config_data)
            
            try:
                llm_json_response = json.loads(raw_llm_response)
                llm_response_content = _get_nested_value(llm_json_response, response_path_jq.lstrip('.'))
                if llm_response_content is None: raise ValueError("Response path extraction returned None.")
            except (json.JSONDecodeError, ValueError) as e:
                log_message("Error", f"Failed to extract/validate LLM response for PLAN. Error: {e}. Raw: {raw_llm_response}")
                task_status = "TASK_FAILED"; break
            
            llm_thought = parse_llm_thought(str(llm_response_content))
            if llm_thought: log_message("Plan Agent", f"[Planner Thought]: {llm_thought}")

            decision_from_planner = parse_llm_decision(str(llm_response_content))
            if decision_from_planner.startswith("CLARIFY_USER:"):
                if config_data.get("allow_clarifying_questions", True):
                    clarification_question = decision_from_planner.split(":", 1)[1].strip()
                    log_message("Plan Agent", f"[Planner Clarification]: {clarification_question}")
                    print(f"{CLR_GREEN}Plan Agent asks: {CLR_RESET}{CLR_BOLD_GREEN}{clarification_question}{CLR_RESET} ")
                    USER_CLARIFICATION_RESPONSE = input()
                    current_context_for_llm = (
                        f"Original request: '{initial_user_prompt}'. "
                        f"My previous question (from Planner): '{clarification_question}'. "
                        f"User's answer: '{USER_CLARIFICATION_RESPONSE}'. "
                        "Please generate a new plan based on this clarification."
                    )
                    LAST_EVAL_DECISION_TYPE = "PLANNER_CLARIFY" 
                    CURRENT_PLAN_STR = "" 
                    continue 
                else:
                    log_message("Warning", f"Plan Agent attempted CLARIFY_USER when questions disabled: '{decision_from_planner.split(':', 1)[1].strip()}'")
                    current_context_for_llm = (
                        f"Original request: '{initial_user_prompt}'. IMPORTANT: Clarifying questions are disabled. "
                        f"You attempted to ask: '{decision_from_planner.split(':', 1)[1].strip()}'. "
                        "You must not ask questions. Make reasonable assumptions and continue with a complete plan and instruction."
                    )
                    LAST_EVAL_DECISION_TYPE = "REVISE_PLAN" 
                    CURRENT_PLAN_STR = ""
                    continue

            CURRENT_PLAN_STR = parse_llm_plan(str(llm_response_content))
            CURRENT_INSTRUCTION = parse_llm_instruction(str(llm_response_content))

            if not CURRENT_PLAN_STR:
                log_message("Warning", "Planner did not return a checklist. Requesting new plan.")
                current_context_for_llm = (
                    f"Original request: '{initial_user_prompt}'. Your previous response lacked a <checklist>. "
                    "Please create a new plan with a <checklist> and the first <instruction>."
                )
                LAST_EVAL_DECISION_TYPE = "REVISE_PLAN"
                CURRENT_PLAN_STR = "" 
                continue
            
            if not CURRENT_INSTRUCTION:
                log_message("Warning", "Planner did not return an instruction. Requesting new plan with instruction.")
                current_context_for_llm = (
                    f"Original request: '{initial_user_prompt}'. Plan: {CURRENT_PLAN_STR}. Your response lacked an <instruction>. "
                    "Please provide the first <instruction> for this plan."
                )
                LAST_EVAL_DECISION_TYPE = "REVISE_PLAN" 
                CURRENT_PLAN_STR = "" 
                continue

            log_message("Plan Agent", f"[Planner Checklist]:\n{CURRENT_PLAN_STR}")
            log_message("Plan Agent", f"[Next Instruction]: {CURRENT_INSTRUCTION}")
            
            CURRENT_PLAN_ARRAY = [line.strip() for line in CURRENT_PLAN_STR.splitlines() if line.strip()]
            CURRENT_STEP_INDEX = 0 
            USER_CLARIFICATION_RESPONSE = "" 
            LAST_EVAL_DECISION_TYPE = "" 

        if not CURRENT_INSTRUCTION: 
            log_message("Error", "ACTION phase: No current instruction. This may indicate a loop error or incomplete plan.")
            task_status = "TASK_FAILED"; break

        log_message("System", f"Entering ACTION phase for instruction: {CURRENT_INSTRUCTION}")
        actor_input_prompt = (
            f"User's original request: '{initial_user_prompt}'\n\n"
            f"Instruction to execute: '{CURRENT_INSTRUCTION}'"
        )
        if USER_CLARIFICATION_RESPONSE: 
             actor_input_prompt += f"\n\nContext: User responded '{USER_CLARIFICATION_RESPONSE}' to my last question."
             USER_CLARIFICATION_RESPONSE = "" 

        payload_str = prepare_payload("action", actor_input_prompt, config_data)
        if not payload_str:
            log_message("Error", "Failed to prepare payload for ACTION phase.")
            task_status = "TASK_FAILED"; break

        try:
            headers = {"Content-Type": "application/json"}
            if config_data.get("api_key"):
                headers["Authorization"] = f"Bearer {config_data['api_key']}"
            response = requests.post(config_data["endpoint"], headers=headers, data=payload_str, 
                                     timeout=config_data.get("command_timeout", 60))
            response.raise_for_status()
            raw_llm_response = response.text
        except requests.exceptions.RequestException as e:
            log_message("Error", f"LLM API request failed for ACTION phase: {e}")
            task_status = "TASK_FAILED"; break
        
        if not raw_llm_response:
            log_message("Error", "No response from LLM for ACTION phase.")
            task_status = "TASK_FAILED"; break
        
        append_context(f"Actor Input: {actor_input_prompt}", raw_llm_response, config_data)

        try:
            llm_json_response = json.loads(raw_llm_response)
            llm_response_content = _get_nested_value(llm_json_response, response_path_jq.lstrip('.'))
            if llm_response_content is None: raise ValueError("Response path extraction returned None.")
        except (json.JSONDecodeError, ValueError) as e:
            log_message("Error", f"Failed to extract/validate LLM response for ACTION. Error: {e}. Raw: {raw_llm_response}")
            task_status = "TASK_FAILED"; break

        llm_thought = parse_llm_thought(str(llm_response_content))
        if llm_thought: log_message("Action Agent", f"[Actor Thought]: {llm_thought}")

        suggested_cmd_raw = parse_suggested_command(str(llm_response_content))
        cmd_output_str = ""
        cmd_status = -1 

        if suggested_cmd_raw:
            # Design Note: In Python version, Action Agent signals completion, Evaluator confirms.
            if suggested_cmd_raw == "report_task_completion":
                log_message("Action Agent", "Received 'report_task_completion'. Signaling to Evaluator.")
                LAST_ACTION_TAKEN = "Internal signal: report_task_completion"
                LAST_ACTION_RESULT = "Action Agent determined task is complete and signaled Evaluator."
                cmd_status = 0 
            else:
                execute_this_command = False
                final_reason_for_not_executing = ""
                
                # Note: Splitting shell commands by regex is an approximation.
                # Complex shell syntax (subshells, advanced redirection) might not be fully parsed by this.
                potential_cmds_in_sequence = re.split(r'\s*(?:&&|\|\||;)\s*|\s+\|\s+', suggested_cmd_raw)
                
                all_parts_allowed_by_config = True
                no_blacklisted_parts = True
                disallowed_parts_pending_approval = []
                blacklisted_detected_parts = []

                for part in potential_cmds_in_sequence:
                    base_cmd_of_part = part.strip().split(" ")[0]
                    if not base_cmd_of_part: continue

                    if base_cmd_of_part in BLACKLISTED_COMMAND_CHECK_MAP:
                        no_blacklisted_parts = False
                        blacklisted_detected_parts.append(base_cmd_of_part)
                        break 
                    
                    if base_cmd_of_part not in ALLOWED_COMMAND_CHECK_MAP:
                        all_parts_allowed_by_config = False
                        if base_cmd_of_part not in disallowed_parts_pending_approval:
                             disallowed_parts_pending_approval.append(base_cmd_of_part)
                
                if not no_blacklisted_parts:
                    final_reason_for_not_executing = (
                        f"Command '{suggested_cmd_raw}' contains blacklisted parts: {', '.join(blacklisted_detected_parts)}. "
                        "Blacklisted commands are never allowed."
                    )
                    cmd_status = 1 
                elif all_parts_allowed_by_config:
                    execute_this_command = True 
                else: 
                    operation_mode = config_data.get("operation_mode", "normal")
                    if operation_mode == "goblin":
                        log_message("System", f"Goblin Mode: Auto-allowing: {', '.join(disallowed_parts_pending_approval)}")
                        execute_this_command = True
                    elif operation_mode == "gremlin":
                        log_message("System", f"Gremlin Mode: Approval for: {', '.join(disallowed_parts_pending_approval)}")
                        all_dynamically_approved = True
                        for cmd_part_to_approve in disallowed_parts_pending_approval:
                            if cmd_part_to_approve in ALLOWED_COMMAND_CHECK_MAP: # Already approved via 'always'
                                continue
                            permission_result = prompt_for_command_permission_and_update_config(cmd_part_to_approve, config_data, response_path_jq)
                            if permission_result == 0: 
                                log_message("System", f"Permission granted for '{cmd_part_to_approve}'.")
                            elif permission_result == 1: 
                                all_dynamically_approved = False
                                final_reason_for_not_executing = f"Command part '{cmd_part_to_approve}' denied by user."
                                cmd_status = 1; break 
                            elif permission_result == 2: 
                                all_dynamically_approved = False
                                task_status = "TASK_FAILED" 
                                final_reason_for_not_executing = f"Task cancelled by user for '{cmd_part_to_approve}'."
                                cmd_status = 125; break 
                        if all_dynamically_approved and task_status != "TASK_FAILED":
                            execute_this_command = True
                    else: # Normal mode
                        final_reason_for_not_executing = (
                            f"Command '{suggested_cmd_raw}' contains parts not in allowed_commands "
                            f"({', '.join(disallowed_parts_pending_approval)}) and mode is 'normal'."
                        )
                        cmd_status = 1 
                
                if execute_this_command and task_status != "TASK_FAILED":
                    LAST_ACTION_TAKEN = f"Executed command: {suggested_cmd_raw}"
                    log_message("Command", suggested_cmd_raw)
                    
                    confirm_execution = True
                    operation_mode = config_data.get("operation_mode", "normal")
                    if operation_mode == "normal":
                        print(f"{CLR_GREEN}User:{CLR_RESET}{CLR_BOLD_GREEN} Execute? {CLR_RESET}'{CLR_BOLD_YELLOW}{suggested_cmd_raw}{CLR_RESET}'{CLR_BOLD_GREEN} [y/N]: {CLR_RESET}", end="")
                        if input().lower() != 'y':
                            confirm_execution = False
                            final_reason_for_not_executing = "User cancelled at confirmation."
                            cmd_status = 124 
                    
                    if confirm_execution:
                        log_message("System", f"Executing in {operation_mode} Mode: {suggested_cmd_raw} - timeout: {config_data['command_timeout']}s")
                        try:
                            process = subprocess.run(
                                suggested_cmd_raw, shell=True, capture_output=True, text=True,
                                timeout=config_data["command_timeout"]
                            )
                            cmd_output_str = (process.stdout.strip() + "\n" + process.stderr.strip()).strip()
                            cmd_status = process.returncode
                            log_message("System", f"Output:\n{cmd_output_str if cmd_output_str else '(no output)'}")
                        except subprocess.TimeoutExpired:
                            cmd_output_str = "Command timed out."
                            cmd_status = 124 
                            log_message("Warning", cmd_output_str)
                        except Exception as e:
                            cmd_output_str = f"Error executing command: {e}"
                            cmd_status = -1 
                            log_message("Error", cmd_output_str)
                    else: 
                        LAST_ACTION_TAKEN = f"Command '{suggested_cmd_raw}' cancelled by user."
                
                if not execute_this_command or (cmd_status != 0 and not final_reason_for_not_executing):
                    if not final_reason_for_not_executing:
                         final_reason_for_not_executing = "Cmd not executed due to permissions/cancellation."
                    LAST_ACTION_TAKEN = f"Command '{suggested_cmd_raw}' not executed."
                    cmd_output_str = final_reason_for_not_executing 
                    if cmd_status == -1: cmd_status = 1 

                LAST_ACTION_RESULT = f"Exit Code: {cmd_status}. Output:\n{cmd_output_str if cmd_output_str else '(no output)'}"
        else: 
            actor_text_response = str(llm_response_content)
            if llm_thought:
                actor_text_response = actor_text_response.replace(f"<think>{llm_thought}</think>", "").strip()
            
            if not actor_text_response:
                log_message("Warning", "Actor: no command and no textual response/question.")
                LAST_ACTION_TAKEN = "Actor: no command and no question."
                LAST_ACTION_RESULT = f"Actor LLM response empty or only thought: {llm_response_content}"
                cmd_status = 1 
            elif config_data.get("allow_clarifying_questions", True):
                log_message("Action Agent", f"[Actor Question/Statement]: {actor_text_response}")
                print(f"{CLR_GREEN}Action Agent says/asks: {CLR_RESET}{CLR_BOLD_GREEN}{actor_text_response}{CLR_RESET} ")
                USER_CLARIFICATION_RESPONSE = input() 
                LAST_ACTION_TAKEN = f"Action Agent asked/stated: {actor_text_response}"
                LAST_ACTION_RESULT = f"User responded: {USER_CLARIFICATION_RESPONSE}"
                cmd_status = 0 
            else: 
                log_message("Warning", f"Actor: no command, questions disabled. Actor said: {actor_text_response}")
                LAST_ACTION_TAKEN = f"Actor: no command (questions disabled). Statement: {actor_text_response}"
                LAST_ACTION_RESULT = "No action taken: no command, questions disabled."
                cmd_status = 1 

        log_message("Debug", f"Last Action Taken: {LAST_ACTION_TAKEN}")
        log_message("Debug", f"Last Action Result: {LAST_ACTION_RESULT}")

        # 3. EVALUATION PHASE
        if task_status == "TASK_FAILED": break # e.g. cancelled during gremlin prompt

        # Simplified skip: if task already marked complete by previous eval, skip current eval.
        if task_status == "TASK_COMPLETE":
             log_message("System", "Skipping Evaluation phase as task is already marked complete.")
             break

        log_message("System", "Entering EVALUATION phase.")
        evaluator_input_prompt = (
            f"User's original request: '{initial_user_prompt}'\n\n"
            f"Current Plan Checklist (if available):\n{CURRENT_PLAN_STR}\n\n"
            f"Instruction that was attempted: '{CURRENT_INSTRUCTION}'\n\n"
            f"Action Taken by Actor:\n{LAST_ACTION_TAKEN}\n\n"
            f"Result of Action:\n{LAST_ACTION_RESULT}"
        )
        if USER_CLARIFICATION_RESPONSE: 
             evaluator_input_prompt += f"\n\nContext: User responded '{USER_CLARIFICATION_RESPONSE}' to my last question."
             USER_CLARIFICATION_RESPONSE = "" 

        payload_str = prepare_payload("evaluate", evaluator_input_prompt, config_data)
        if not payload_str:
            log_message("Error", "Failed to prepare payload for EVALUATION phase.")
            task_status = "TASK_FAILED"; break
        
        try:
            headers = {"Content-Type": "application/json"}
            if config_data.get("api_key"):
                headers["Authorization"] = f"Bearer {config_data['api_key']}"
            response = requests.post(config_data["endpoint"], headers=headers, data=payload_str, 
                                     timeout=config_data.get("command_timeout", 60))
            response.raise_for_status()
            raw_llm_response = response.text
        except requests.exceptions.RequestException as e:
            log_message("Error", f"LLM API request failed for EVALUATION phase: {e}")
            task_status = "TASK_FAILED"; break

        if not raw_llm_response:
            log_message("Error", "No response from LLM for EVALUATION phase.")
            task_status = "TASK_FAILED"; break
        
        append_context(f"Evaluator Input: {evaluator_input_prompt}", raw_llm_response, config_data)

        try:
            llm_json_response = json.loads(raw_llm_response)
            llm_response_content = _get_nested_value(llm_json_response, response_path_jq.lstrip('.'))
            if llm_response_content is None: raise ValueError("Response path extraction returned None.")
        except (json.JSONDecodeError, ValueError) as e:
            log_message("Error", f"Failed to extract/validate LLM response for EVALUATION. Error: {e}. Raw: {raw_llm_response}")
            task_status = "TASK_FAILED"; break

        llm_thought = parse_llm_thought(str(llm_response_content))
        if llm_thought: log_message("Eval Agent", f"[Evaluator Thought]: {llm_thought}")

        evaluator_decision_full = parse_llm_decision(str(llm_response_content))
        log_message("Eval Agent", f"[Evaluator Decision]: {evaluator_decision_full}")

        if not evaluator_decision_full:
            log_message("Warning", f"Evaluator: no decision. LLM Response: {llm_response_content}. Assuming CONTINUE_PLAN.")
            evaluator_decision_full = "CONTINUE_PLAN: No decision by LLM. Defaulting to continue."
        
        evaluator_decision_parts = evaluator_decision_full.split(":", 1)
        EVALUATOR_DECISION_TYPE = evaluator_decision_parts[0].strip()
        evaluator_message = evaluator_decision_parts[1].strip() if len(evaluator_decision_parts) > 1 else ""
        LAST_EVAL_DECISION_TYPE = EVALUATOR_DECISION_TYPE 

        if EVALUATOR_DECISION_TYPE == "TASK_COMPLETE":
            log_message("Eval Agent", f"Task marked COMPLETE by evaluator. Summary: {evaluator_message}")
            task_status = "TASK_COMPLETE"
        elif EVALUATOR_DECISION_TYPE == "TASK_FAILED":
            log_message("Eval Agent", f"Task marked FAILED by evaluator. Reason: {evaluator_message}")
            task_status = "TASK_FAILED"
        elif EVALUATOR_DECISION_TYPE == "CONTINUE_PLAN":
            log_message("Eval Agent", f"Evaluator: CONTINUE_PLAN. {evaluator_message}")
            current_context_for_llm = (
                f"Original request: '{initial_user_prompt}'.\n"
                f"Current Plan:\n{CURRENT_PLAN_STR}\n"
                f"Prev instruction ('{CURRENT_INSTRUCTION}') result: '{LAST_ACTION_RESULT}'.\n"
                f"Evaluator feedback: '{evaluator_message}'.\n"
                "Provide next instruction. If plan complete, instruct actor 'report_task_completion'."
            )
            CURRENT_PLAN_STR = "" 
            CURRENT_INSTRUCTION = "" 
            USER_CLARIFICATION_RESPONSE = "" 
        elif EVALUATOR_DECISION_TYPE == "REVISE_PLAN":
            log_message("Eval Agent", f"Evaluator: REVISE_PLAN. Reason: {evaluator_message}")
            current_context_for_llm = (
                f"Original request: '{initial_user_prompt}'.\n"
                f"Prev plan:\n{CURRENT_PLAN_STR}\n"
                f"Prev instruction ('{CURRENT_INSTRUCTION}') result: '{LAST_ACTION_RESULT}'.\n"
                f"Evaluator suggests revision: '{evaluator_message}'.\n"
                "Revise checklist and provide new first instruction."
            )
            CURRENT_PLAN_STR = "" 
            CURRENT_INSTRUCTION = ""
            USER_CLARIFICATION_RESPONSE = ""
        elif EVALUATOR_DECISION_TYPE == "CLARIFY_USER":
            if config_data.get("allow_clarifying_questions", True):
                clarification_question = evaluator_message
                log_message("Eval Agent", f"[Evaluator Clarification]: {clarification_question}")
                print(f"{CLR_GREEN}Eval Agent asks: {CLR_RESET}{CLR_BOLD_GREEN}{clarification_question}{CLR_RESET} ")
                USER_CLARIFICATION_RESPONSE = input()
                current_context_for_llm = (
                    f"Original request: '{initial_user_prompt}'.\n"
                    f"After action '{LAST_ACTION_TAKEN}' (result: '{LAST_ACTION_RESULT}'), "
                    f"evaluator needs clarification. Question: '{clarification_question}'.\n"
                    f"User's answer: '{USER_CLARIFICATION_RESPONSE}'.\n"
                    "Revise plan/next instruction based on this."
                )
                CURRENT_PLAN_STR = "" 
                CURRENT_INSTRUCTION = ""
            else: 
                log_message("Warning", f"Evaluator: CLARIFY_USER when questions disabled: '{evaluator_message}'")
                log_message("System", "Task FAILED: evaluator needs clarification, questions disabled.")
                task_status = "TASK_FAILED"
        else:
            log_message("Error", f"Unknown decision from Evaluator: '{evaluator_decision_full}'. Assuming task failed.")
            task_status = "TASK_FAILED"

        if task_status != "IN_PROGRESS":
            break 

    if task_status == "TASK_COMPLETE":
        log_message("User", "Task completed successfully.")
        return True
    else:
        log_message("User", "Task failed or was aborted.")
        return False

# --- Signal Handler ---
def signal_handler(sig, frame):
    log_message("System", "Session terminated by user (Ctrl-C).")
    # Consider cleanup tasks here if necessary
    sys.exit(0)

# --- Main Execution ---
def main():
    global ENABLE_DEBUG 

    colorama_init(autoreset=True)
    signal.signal(signal.SIGINT, signal_handler)

    log_message("System", f"Agent Shelly - Python Edition ({SCRIPT_NAME}) starting...")
    log_message("Debug", f"CONFIG_DIR: {CONFIG_DIR}")

    check_dependencies() 

    if not initial_setup(): 
        sys.exit(1) 

    config = load_config()
    if not config:
        sys.exit(1)
    
    response_path = get_response_path()
    if not response_path:
        sys.exit(1)
    
    log_message("System", f"Operation Mode: {config.get('operation_mode', 'normal')}")
    log_message("System", f"Command Timeout: {config.get('command_timeout', 30)}s")

    parser = argparse.ArgumentParser(description="Agent Shelly - Python Edition: LLM-powered shell assistant.")
    parser.add_argument('task_prompt', nargs='*', help="Initial task. If empty, enters interactive mode.")
    args = parser.parse_args()

    if args.task_prompt:
        user_initial_prompt = " ".join(args.task_prompt)
        handle_task(user_initial_prompt, config, response_path)
    else:
        while True:
            try:
                prompt = input(f"{CLR_GREEN}Enter your task (or 'exit' to quit):{CLR_RESET} ")
                if prompt.lower() == "exit":
                    log_message("User", "Exiting session.")
                    break
                if not prompt.strip():
                    continue
                handle_task(prompt, config, response_path)
            except EOFError: 
                log_message("System", "EOF received, exiting.")
                break
            # KeyboardInterrupt is caught by signal_handler
    
    log_message("System", f"{SCRIPT_NAME} finished.")

if __name__ == "__main__":
    main()
