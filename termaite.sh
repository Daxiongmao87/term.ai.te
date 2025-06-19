#!/bin/bash
# Leave out the original "set -e" which causes script to exit on any error
set +u # Do not treat unset variables as an error
set -o pipefail

# Log Bash version
echo "Bash version: $BASH_VERSION" >&2
# --- ANSI Color Codes ---
CLR_RESET=$'\e[0m'
CLR_RED=$'\e[0;31m'; CLR_BOLD_RED=$'\e[1;31m'
CLR_GREEN=$'\e[0;32m'; CLR_BOLD_GREEN=$'\e[1;32m'
CLR_YELLOW=$'\e[0;33m'; CLR_BOLD_YELLOW=$'\e[1;33m'
CLR_BLUE=$'\e[0;34m'; CLR_BOLD_BLUE=$'\e[1;34m'
CLR_MAGENTA=$'\e[0;35m'; CLR_BOLD_MAGENTA=$'\e[1;35m'
CLR_CYAN=$'\e[0;36m'; CLR_BOLD_CYAN=$'\e[1;36m'
CLR_WHITE=$'\e[0;37m'; CLR_BOLD_WHITE=$'\e[1;37m'

# --- Logging Function ---
# log_message <type> <message>
# Type can be: System, User, Plan Agent, Action Agent, Eval Agent, LLM, Command, Error, Warning, Debug
# Error messages are sent to stderr
log_message() {
    local type="$1"
    shift
    local message_content="$*" # Renamed to avoid confusion
    
    # Skip Debug messages when debug is disabled
    if [ "$type" = "Debug" ] && [ "$ENABLE_DEBUG" != "true" ]; then
        return 0
    fi
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S') # Safer quoting for date format
    local header_color=""
    local content_color=""
    local numeric_fd=1 # stdout by default

    case "$type" in
        System)       header_color="$CLR_CYAN"; content_color="$CLR_BOLD_CYAN" ;;
        User)         header_color="$CLR_GREEN"; content_color="$CLR_BOLD_GREEN" ;;
        "Plan Agent")   header_color="$CLR_MAGENTA"; content_color="$CLR_BOLD_MAGENTA" ;; # New
        "Action Agent") header_color="$CLR_BLUE"; content_color="$CLR_BOLD_BLUE" ;;     # New
        "Eval Agent")   header_color="$CLR_YELLOW"; content_color="$CLR_BOLD_YELLOW" ;;  # New
        LLM)          header_color="$CLR_WHITE"; content_color="$CLR_BOLD_WHITE" ;; # Was Magenta, changed to avoid conflict
        Command)      header_color="$CLR_YELLOW"; content_color="$CLR_BOLD_YELLOW" ;; # Eval Agent now uses Yellow, Command can share or change
        Error)
            header_color="$CLR_RED"; content_color="$CLR_BOLD_RED"
            numeric_fd=2 # stderr for errors
            ;;
        Warning)
            header_color="$CLR_YELLOW"; content_color="$CLR_BOLD_YELLOW" # Shares with Eval Agent and Command
            numeric_fd=2 # stderr for warnings
            ;;
        Debug)   header_color="$CLR_WHITE"; content_color="$CLR_BOLD_WHITE" ;; # Shares with LLM
        *)       header_color="$CLR_WHITE"; content_color="$CLR_BOLD_WHITE" ;; # Default for unknown types
    esac

    local header_text="${header_color}[$timestamp] [$type]: ${CLR_RESET}"
    # Calculate indent based on actual length of timestamp and type for consistent alignment
    local indent_length=$(( ${#timestamp} + ${#type} + 6 )) # [YYYY-MM-DD HH:MM:SS] [Type]:<space>
    local indent_str=""
    printf -v indent_str '%*s' "$indent_length" '' # Create a string of spaces for indent

    # Use a temporary file for the message to handle special characters robustly with sed
    local tmp_msg_file
    tmp_msg_file=$(mktemp)
    # Fallback if mktemp fails (should be caught by dependency check)
    if [ -z "$tmp_msg_file" ] || [ ! -f "$tmp_msg_file" ]; then
        # Direct echo if mktemp failed; formatting might be imperfect for multiline.
        echo "${header_text}${content_color}${message_content}${CLR_RESET}" >&"${numeric_fd}"
        [ -n "$tmp_msg_file" ] && rm -f "$tmp_msg_file" # Clean up if tmp_msg_file was set but ! -f
        return
    fi
    printf '%s\n' "$message_content" > "$tmp_msg_file" # Changed from echo to printf

    # Apply content_color to the message part of each line and CLR_RESET at the end of each line.
    # The first line gets the header, subsequent lines get indentation.
    sed -e "1s|^|${header_text}${content_color}|" \
        -e "2,\$s|^|${indent_str}${content_color}|" \
        -e "s|\$|${CLR_RESET}|" "$tmp_msg_file" >&"${numeric_fd}" # Sed reads from tmp_msg_file

    rm -f "$tmp_msg_file"
}

# --- Dependency Check ---
for cmd in jq curl yq mktemp timeout awk sha256sum sed grep head cut; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_message "Error" "Required command '$cmd' is not installed. Exiting."
        exit 1
    fi
    if [ "$cmd" = "yq" ]; then
        # Specifically check for mikefarah/yq
        if ! yq --version 2>&1 | grep -q 'https://github.com/mikefarah/yq'; then
            log_message "Error" "Go-based yq - see https://github.com/mikefarah/yq - is required."
            log_message "Error" "You may have a different yq installed - e.g. Python yq."
            log_message "Error" "Please install the Go version - e.g. 'sudo snap install yq' or see https://github.com/mikefarah/yq."
            exit 1
        fi
    fi
    if [ "$cmd" = "jq" ]; then
        JQ_VERSION=$(jq --version 2>/dev/null || echo "jq-0.0") # Default to a low version if command fails
        JQ_VERSION_NUMBER=$(echo "$JQ_VERSION" | sed 's/jq-//')
        MIN_JQ_MAJOR=1
        MIN_JQ_MINOR=6
        CURRENT_JQ_MAJOR=$(echo "$JQ_VERSION_NUMBER" | cut -d. -f1)
        CURRENT_JQ_MINOR=$(echo "$JQ_VERSION_NUMBER" | cut -d. -f2)

        if [[ "$CURRENT_JQ_MAJOR" -lt "$MIN_JQ_MAJOR" ]] || ([[ "$CURRENT_JQ_MAJOR" -eq "$MIN_JQ_MAJOR" ]] && [[ "$CURRENT_JQ_MINOR" -lt "$MIN_JQ_MINOR" ]]); then
            log_message "Error" "jq version 1.6 or higher is required for certain JSON operations like gsub. You have $JQ_VERSION."
            log_message "Error" "Please upgrade jq - e.g. sudo apt install --only-upgrade jq or check your package manager."
            exit 1
        fi
    fi
done

# --- Tool Call Instructions for LLM ---
# TOOL_CALL_INSTRUCTIONS will be built dynamically later based on allowed_commands
# and will include the following command execution guidelines:
#
# **Command Execution:**
# *   If the task requires a shell command, respond *only* with the EXACT command to achieve the task,
#     wrapped in a specific code block:
#     \`\`\`agent_command
#     <the exact bash command to run>
#     \`\`\`
# *   Do NOT provide any explanations or text outside of this \`\`\`agent_command ... \`\`\` block when issuing a command.

# --- Configuration Variables ---
CONFIG_DIR="$HOME/.config/term.ai.te" # Changed to use local ./config directory

log_message Debug "Preparing to set CONFIG_FILE. CONFIG_DIR='${CONFIG_DIR}'"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
declare PAYLOAD_FILE="$CONFIG_DIR/payload.json"
declare RESPONSE_PATH_FILE="$CONFIG_DIR/response_path_template.txt"
declare CONTEXT_FILE="$CONFIG_DIR/context.json"
declare JQ_ERROR_LOG="$CONFIG_DIR/jq_error.log"

# Debug flag - set to false by default, will be updated from config
ENABLE_DEBUG=false

# --- Global State for Agent Loop ---
declare CURRENT_PLAN_STR=""
declare CURRENT_INSTRUCTION=""  # New variable to hold the instruction for Action Agent
declare -a CURRENT_PLAN_ARRAY=()
declare CURRENT_STEP_INDEX=0
declare LAST_ACTION_TAKEN=""
declare LAST_ACTION_RESULT=""
declare USER_CLARIFICATION_RESPONSE=""
declare LAST_EVAL_DECISION_TYPE=""

# --- Template Definitions ---
CONFIG_TEMPLATE="# config.yaml - REQUIRED - Configure this file for your environment and LLM
# Ensure this is valid YAML.
# endpoint: The URL of your LLM API endpoint.
# api_key: Your API key, if required by the endpoint. Leave empty or comment out if not needed.
# plan_prompt: The system-level instructions for the planning phase.
# action_prompt: The system-level instructions for the action phase.
# evaluate_prompt: The system-level instructions for the evaluation phase.
# allowed_commands: A list of commands the LLM is permitted to suggest.
#   Each command should have a brief description.
#   Example:
#     ls: \"List directory contents.\"
#     cat: \"Display file content.\"
#     echo: \"Print text to the console.\"
operation_mode: normal # Options: normal, gremlin, goblin. Default: normal.
#   normal: Whitelisted commands require confirmation. Non-whitelisted commands are rejected.
#   gremlin: Whitelisted commands run without confirmation. Non-whitelisted commands prompt for approval (yes/no/add to whitelist).
#   goblin: All commands run without confirmation. USE WITH EXTREME CAUTION!
command_timeout: 30 # Default timeout for commands in seconds

endpoint: \"http://localhost:11434/api/generate\" # Example for Ollama /api/generate

# api_key: \"YOUR_API_KEY_HERE\" # Uncomment and replace if your LLM requires an API key

plan_prompt: |
  You are the \"Planner\" module of a multi-step AI assistant specialized in the Linux shell environment.
  Your primary goal is to understand the user's overall task and create a step-by-step plan to achieve it.
  You operate with the current context:
  Time: $(date +'%Y-%m-%d %H:%M:%S')
  Directory: $PWD
  Hostname: $(hostname)
  Refer to your detailed directives for output format (using <plan> and <think> tags, or <decision>CLARIFY_USER</decision>).

action_prompt: |
  You are the \"Actor\" module of a multi-step AI assistant specialized in the Linux shell environment.
  You will be given the user's original request, the overall plan, and the specific current step to execute.
  Your primary goal is to determine the appropriate bash command (in ```agent_command```) or formulate a question based on the current step.
  You operate with the current context:
  Time: $(date +'%Y-%m-%d %H:%M:%S')
  Directory: $PWD
  Hostname: $(hostname)
  Refer to your detailed directives for command generation and textual responses (using <think> tags).

evaluate_prompt: |
  You are the \"Evaluator\" module of a multi-step AI assistant specialized in the Linux shell environment.
  You will be given the original request, plan, action taken, and result.
  Your primary goal is to assess the outcome and decide the next course of action (using <decision>TAG: message</decision> and <think> tags).
  You operate with the current context:
  Time: $(date +'%Y-%m-%d %H:%M:%S')
  Directory: $PWD
  Hostname: $(hostname)
  Refer to your detailed directives for decision making (CONTINUE_PLAN, REVISE_PLAN, TASK_COMPLETE, CLARIFY_USER, TASK_FAILED).

allowed_commands:
  ls: \"List directory contents. Use common options like -l, -a, -h as needed.\"
  cat: \"Display file content. Example: cat filename.txt\"
  echo: \"Print text. Example: echo 'Hello World'\"
  # Add more commands and their descriptions as needed.

operation_mode: normal # Default operation mode
command_timeout: 30 # Default timeout for commands in seconds"

PAYLOAD_TEMPLATE='{
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
}'

RESPONSE_PATH_TEMPLATE="# response_path_template.txt - REQUIRED
# This file must contain a jq-compatible path to extract the LLM's main response text
# from the LLM's JSON output.
# Example for OpenAI API: .choices[0].message.content
# Example for Ollama /api/generate: .response
# Example for Ollama /api/chat (if response is {\"message\": {\"content\": \"...\"}}): .message.content
.response
"

# --- Initial Setup: Config Directory and Files ---
mkdir -p "$CONFIG_DIR"
MISSING_SETUP_FILE=0
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$CONFIG_TEMPLATE" > "$CONFIG_FILE"
    log_message System "Generated config template: $CONFIG_FILE"
    MISSING_SETUP_FILE=1
fi
if [ ! -f "$PAYLOAD_FILE" ]; then
    echo "$PAYLOAD_TEMPLATE" > "$PAYLOAD_FILE" # Will contain comments initially
    log_message System "Generated payload template: $PAYLOAD_FILE"
    log_message System "IMPORTANT: Review and edit $PAYLOAD_FILE to be valid JSON matching your LLM API, then remove comments."
    MISSING_SETUP_FILE=1
fi
if [ ! -f "$RESPONSE_PATH_FILE" ]; then
    echo "$RESPONSE_PATH_TEMPLATE" > "$RESPONSE_PATH_FILE"
    log_message System "Generated response path template: $RESPONSE_PATH_FILE"
    MISSING_SETUP_FILE=1
fi
if [ $MISSING_SETUP_FILE -eq 1 ]; then
    log_message System "One or more configuration templates were generated in $CONFIG_DIR."
    log_message System "Please review and configure them before running $SCRIPT_NAME again."
    exit 1
fi

# --- Load Configuration ---

# Helper function to capture yq stderr for better error reporting
read_yq_value() {
    local field_path="$1"
    local default_expr="$2" # e.g., "// \"\"" for default empty string, or "// false" for default false
    local yq_stderr_file
    yq_stderr_file=$(mktemp)
    local output
    output=$(cat "$CONFIG_FILE" | yq -r "${field_path} ${default_expr}" 2> "$yq_stderr_file")
    local yq_status=$?
    if [ $yq_status -ne 0 ]; then
        log_message "Error" "yq failed to read '$field_path' from $CONFIG_FILE. Exit status: $yq_status."
        if [ -s "$yq_stderr_file" ]; then
            log_message "Error" "yq stderr: $(cat "$yq_stderr_file")"
        fi
        rm -f "$yq_stderr_file"
        exit 1 # Critical error, exit
    fi
    if [ -s "$yq_stderr_file" ]; then # Log warnings from yq even on success if any
        log_message "Warning" "yq stderr while reading '$field_path' (but command succeeded): $(cat "$yq_stderr_file")"
    fi
    rm -f "$yq_stderr_file"
    echo "$output"
}

# Validate required config fields are present (simple check, value check later)
REQUIRED_CONFIG_FIELDS_EXISTENCE=(endpoint plan_prompt action_prompt evaluate_prompt allowed_commands operation_mode command_timeout)
for field in "${REQUIRED_CONFIG_FIELDS_EXISTENCE[@]}"; do
    if ! cat "$CONFIG_FILE" | yq -e ".$field" >/dev/null 2>&1; then # -e makes yq exit non-zero if path not found
        log_message "Error" "Required configuration key '.$field' is missing in $CONFIG_FILE."
        # Check if it was a parsing error vs missing key
        if ! cat "$CONFIG_FILE" | yq . >/dev/null 2>&1; then
            log_message "Error" "$CONFIG_FILE appears to be invalid YAML."
        fi
        exit 1
    fi
done

ENDPOINT=$(read_yq_value ".endpoint" "") # No default, check for empty later
if [ -z "$ENDPOINT" ] || [ "$ENDPOINT" == "null" ]; then
    log_message "Error" "Required field '.endpoint' is empty or null in $CONFIG_FILE."
    exit 1
fi

API_KEY=$(read_yq_value ".api_key" "// \"\"") # Default to empty string

PLAN_PROMPT=$(read_yq_value ".plan_prompt" "")
if [ -z "$PLAN_PROMPT" ] || [ "$PLAN_PROMPT" == "null" ]; then
    log_message "Error" "Required field '.plan_prompt' is empty or null in $CONFIG_FILE."
    exit 1
fi

ACTION_PROMPT=$(read_yq_value ".action_prompt" "")
if [ -z "$ACTION_PROMPT" ] || [ "$ACTION_PROMPT" == "null" ]; then
    log_message "Error" "Required field '.action_prompt' is empty or null in $CONFIG_FILE."
    exit 1
fi

EVALUATE_PROMPT=$(read_yq_value ".evaluate_prompt" "")
if [ -z "$EVALUATE_PROMPT" ] || [ "$EVALUATE_PROMPT" == "null" ]; then
    log_message "Error" "Required field '.evaluate_prompt' is empty or null in $CONFIG_FILE."
    exit 1
fi

# Load allowed_commands into an associative array for key checking (existing logic is mostly fine)
declare -A ALLOWED_COMMAND_CHECK_MAP # Moved declaration here to be sure
log_message Debug "Attempting to populate ALLOWED_COMMAND_CHECK_MAP from $CONFIG_FILE"

yq_keys_stderr_file=$(mktemp)
temp_keys_array=()

# Get raw keys, one per line. yq -r is important.
if ! mapfile -t temp_keys_array < <(cat "$CONFIG_FILE" | yq -r '.allowed_commands | keys | .[]' 2> "$yq_keys_stderr_file"); then
    log_message "Error" "Failed to read command keys using yq and mapfile."
    if [ -s "$yq_keys_stderr_file" ]; then
        log_message "Error" "yq stderr (keys): $(cat "$yq_keys_stderr_file")"
    fi
    log_message Warning "ALLOWED_COMMAND_CHECK_MAP will be empty."
else
    if [ ${#temp_keys_array[@]} -eq 0 ]; then
        log_message Warning "No command keys found under '.allowed_commands' in $CONFIG_FILE (or yq produced no output). ALLOWED_COMMAND_CHECK_MAP will be empty."
    else
        for key in "${temp_keys_array[@]}"; do
            if [ -n "$key" ]; then
                ALLOWED_COMMAND_CHECK_MAP["$key"]=1
                log_message Debug "Added allowed command key to map: '$key'"
            fi
        done
        log_message Debug "ALLOWED_COMMAND_CHECK_MAP population complete. Count: ${#ALLOWED_COMMAND_CHECK_MAP[@]}"
    fi
fi
rm -f "$yq_keys_stderr_file"

# Load blacklisted_commands into an associative array for key checking
declare -A BLACKLISTED_COMMAND_CHECK_MAP # Declare the blacklist map
log_message Debug "Attempting to populate BLACKLISTED_COMMAND_CHECK_MAP from $CONFIG_FILE"

yq_blacklist_stderr_file=$(mktemp)
temp_blacklist_array=()

# Get raw blacklisted keys, one per line
# This approach handles both formats:
# 1. blacklisted_commands:
#      cmd1: "description" 
#      cmd2: "description"
# 2. blacklisted_commands:
#      - cmd1
#      - cmd2
if ! mapfile -t temp_blacklist_array < <((cat "$CONFIG_FILE" | yq -r '.blacklisted_commands | keys | .[]' 2> "$yq_blacklist_stderr_file") || (cat "$CONFIG_FILE" | yq -r '.blacklisted_commands[]' 2> /dev/null)); then
    log_message "Warning" "Failed to read blacklisted command keys using yq and mapfile."
    if [ -s "$yq_blacklist_stderr_file" ]; then
        log_message "Warning" "yq stderr (blacklist keys): $(cat "$yq_blacklist_stderr_file")"
    fi
    log_message Warning "BLACKLISTED_COMMAND_CHECK_MAP will be empty."
else
    if [ ${#temp_blacklist_array[@]} -eq 0 ]; then
        log_message Debug "No blacklisted commands found in $CONFIG_FILE. BLACKLISTED_COMMAND_CHECK_MAP will be empty."
    else
        for key in "${temp_blacklist_array[@]}"; do
            if [ -n "$key" ]; then
                BLACKLISTED_COMMAND_CHECK_MAP["$key"]=1
                log_message Debug "Added blacklisted command key to map: '$key'"
            fi
        done
        log_message Debug "BLACKLISTED_COMMAND_CHECK_MAP population complete. Count: ${#BLACKLISTED_COMMAND_CHECK_MAP[@]}"
    fi
fi
rm -f "$yq_blacklist_stderr_file"

OPERATION_MODE=$(read_yq_value ".operation_mode" "// \"normal\"")
if [[ "$OPERATION_MODE" != "normal" && "$OPERATION_MODE" != "gremlin" && "$OPERATION_MODE" != "goblin" ]]; then
    log_message "Error" "OPERATION_MODE in $CONFIG_FILE must be 'normal', 'gremlin', or 'goblin', got '$OPERATION_MODE'."
    exit 1
fi

ALLOW_CLARIFYING_QUESTIONS=$(read_yq_value ".allow_clarifying_questions" "// true")
if [[ "$ALLOW_CLARIFYING_QUESTIONS" != "true" && "$ALLOW_CLARIFYING_QUESTIONS" != "false" ]]; then
    log_message "Warning" "ALLOW_CLARIFYING_QUESTIONS in $CONFIG_FILE must be 'true' or 'false', got '$ALLOW_CLARIFYING_QUESTIONS'. Defaulting to 'true'."
    ALLOW_CLARIFYING_QUESTIONS="true"
fi
log_message Debug "ALLOW_CLARIFYING_QUESTIONS set to: $ALLOW_CLARIFYING_QUESTIONS"

COMMAND_TIMEOUT=$(read_yq_value ".command_timeout" "// 30")
if ! [[ "$COMMAND_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$COMMAND_TIMEOUT" -lt 0 ]; then # Allow 0 for no timeout if desired, though >=1 is typical
    log_message "Error" "COMMAND_TIMEOUT ('$COMMAND_TIMEOUT') in $CONFIG_FILE must be a non-negative integer."
    exit 1
fi

ENABLE_DEBUG=$(read_yq_value ".enable_debug" "// false")
if [[ "$ENABLE_DEBUG" != "true" && "$ENABLE_DEBUG" != "false" ]]; then
    log_message "Warning" "ENABLE_DEBUG in $CONFIG_FILE must be 'true' or 'false', got '$ENABLE_DEBUG'. Defaulting to 'false'."
    ENABLE_DEBUG="false"
fi
log_message Debug "ENABLE_DEBUG set to: $ENABLE_DEBUG"

# Read the first non-comment, non-empty line from RESPONSE_PATH_FILE
RESPONSE_PATH=$(grep -vE '^\s*#|^\s*$' "$RESPONSE_PATH_FILE" | head -n 1 | tr -d '[:space:]')

if [ -z "$RESPONSE_PATH" ]; then
    log_message "Error" "TEST ERROR: RESPONSE_PATH is empty. Problem in file: $RESPONSE_PATH_FILE"
    exit 1
fi

# --- Context Management ---
PWD_HASH=$(echo -n "$PWD" | sha256sum | cut -d' ' -f1)

append_context() {
    local user_prompt_for_context="$1"
    local raw_llm_output_for_context="$2"
    local timestamp_now
    timestamp_now=$(date +'%Y-%m-%dT%H:%M:%SZ')

    local context_entry_json
    # Check if raw_llm_output_for_context is valid JSON
    if ! echo "$raw_llm_output_for_context" | jq -e . > /dev/null 2>&1; then
        context_entry_json=$(jq -n \
            --arg up "$user_prompt_for_context" \
            --arg error_msg "$raw_llm_output_for_context" \
            --arg ts "$timestamp_now" \
            '{type: "error", user_prompt: $up, llm_error_message: $error_msg, timestamp: $ts}')
    else
        context_entry_json=$(jq -n \
            --arg up "$user_prompt_for_context" \
            --argjson llm_resp "$raw_llm_output_for_context" \
            --arg ts "$timestamp_now" \
            '{type: "success", user_prompt: $up, llm_full_response: $llm_resp, timestamp: $ts}')
    fi

    local tmp_file
    tmp_file=$(mktemp)
    if [ -z "$tmp_file" ] || [ ! -f "$tmp_file" ]; then
      log_message "Error" "mktemp failed to create a temporary file. Cannot save context."
      [ -n "$tmp_file" ] && rm -f "$tmp_file"
      return 1
    fi

    # Ensure the context file exists and is a valid JSON object before trying to merge
    if [ ! -f "$CONTEXT_FILE" ]; then
        echo "{}" > "$CONTEXT_FILE" # Initialize with an empty JSON object if it doesn't exist
    else
        # Check if the existing context file is valid JSON, if not, initialize it
        if ! jq -e . "$CONTEXT_FILE" > /dev/null 2>&1; then
            log_message Warning "$CONTEXT_FILE was not valid JSON. Initializing a new one."
            local backup_file="${CONTEXT_FILE}.invalid.$(date +'%Y%m%d%H%M%S')"
            mv "$CONTEXT_FILE" "$backup_file"
            echo "{}" > "$CONTEXT_FILE"
        fi
    fi

    local jq_command_output
    jq_command_output=$(jq --arg hash "$PWD_HASH" --argjson entry "$context_entry_json" \
        '. as $original_full_context |
         ($original_full_context[$hash] // []) as $current_hash_array |
         ($current_hash_array + [$entry]) as $updated_hash_array |
         $original_full_context + {($hash): $updated_hash_array}' \
        "$CONTEXT_FILE" 2> "$JQ_ERROR_LOG")
    local jq_status=$?

    if [ $jq_status -ne 0 ]; then
        log_message "Error" "jq failed to update $CONTEXT_FILE. JQ exit status: $jq_status."
        log_message "Error" "JQ error messages logged to: $JQ_ERROR_LOG"
        rm -f "$tmp_file"
        return 1
    elif [ -z "$jq_command_output" ]; then
         log_message Warning "jq produced empty output while updating $CONTEXT_FILE. This might indicate an issue with the context structure or the jq filter."
         log_message Warning "JQ error messages logged to: $JQ_ERROR_LOG"
         local backup_file="${CONTEXT_FILE}.empty_jq_output.$(date +'%Y%m%d%H%M%S')"
         mv "$CONTEXT_FILE" "$backup_file"
         echo "{}" | jq --arg hash "$PWD_HASH" --argjson entry "$context_entry_json" '. + {($hash): [$entry]}' > "$tmp_file"
         if [ $? -ne 0 ]; then
            log_message "Error" "Error re-initializing context after empty jq output. Context not saved."
            rm -f "$tmp_file"
            return 1
         fi
    else
        echo "$jq_command_output" > "$tmp_file"
    fi

    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$CONTEXT_FILE"
    else
        log_message "Error" "Temporary context file was empty. Context not saved."
        rm -f "$tmp_file"
        return 1
    fi
    return 0
}

# --- Payload Preparation ---
prepare_payload() {
    local phase="$1" # "plan", "action", "evaluate"
    local current_prompt_content="$2" # This will be the user_request for plan, or constructed context for action/evaluate
    
    local system_prompt_for_phase=""
    case "$phase" in
        plan) system_prompt_for_phase="$PLAN_PROMPT" ;;
        action) system_prompt_for_phase="$ACTION_PROMPT" ;;
        evaluate) system_prompt_for_phase="$EVALUATE_PROMPT" ;;
        *)
            log_message "Error" "Invalid phase '$phase' provided to prepare_payload."
            return 1
            ;;
    esac

    # Process template variables in system prompts
    # Replace {{if ALLOW_CLARIFYING_QUESTIONS}}...{{else}}...{{end}} patterns
    if [[ "$ALLOW_CLARIFYING_QUESTIONS" == "true" ]]; then
        # Keep the "if" part and remove the "else" part in if/else/end blocks
        system_prompt_for_phase=$(echo "$system_prompt_for_phase" | sed -E '
            # Match the if/else/end block and capture relevant parts
            /\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}/,/\{\{end\}\}/ {
                # Delete else to end part
                /\{\{else\}\}/,/\{\{end\}\}/d
                # Remove the if tag
                s/\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}//g
            }
        ')
    else
        # Keep the "else" part and remove the "if" part in if/else/end blocks
        system_prompt_for_phase=$(echo "$system_prompt_for_phase" | sed -E '
            # For blocks with else, remove if to else
            /\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}/,/\{\{else\}\}/ {
                /\{\{else\}\}/! d
                s/\{\{else\}\}//g
            }
            # Remove end tags
            s/\{\{end\}\}//g
        ')
    fi
    
    # Clean up any remaining template markers
    system_prompt_for_phase=$(echo "$system_prompt_for_phase" | sed -E '
        s/\{\{if ALLOW_CLARIFYING_QUESTIONS\}\}//g
        s/\{\{else\}\}//g
        s/\{\{end\}\}//g
    ')

    local tool_instructions_addendum=""

    if [ "$phase" == "action" ]; then
        if [[ "$OPERATION_MODE" == "normal" ]]; then
            local allowed_commands_yaml_block
            local yq_yaml_stderr_file
            yq_yaml_stderr_file=$(mktemp)
            # Get the .allowed_commands as a YAML block string
            allowed_commands_yaml_block=$(cat "$CONFIG_FILE" | yq '.allowed_commands' 2> "$yq_yaml_stderr_file")
            local yq_yaml_status=$?

            if [ $yq_yaml_status -eq 0 ] && [ -n "$allowed_commands_yaml_block" ] && [ "$allowed_commands_yaml_block" != "null" ]; then
                tool_instructions_addendum="You are permitted to use ONLY the following commands. Their names and descriptions are provided below in YAML format. Adhere strictly to these commands and their specified uses:\\n\\n\`\`\`yaml\\n${allowed_commands_yaml_block}\\n\`\`\`\\n\\nIf an appropriate command is not on this list, you should state that you cannot perform the action with the available commands and explain why.\\n"
            else
                log_message Warning "Could not fetch or format allowed_commands YAML block for LLM instructions in NORMAL mode. LLM will not have a command list."
                if [ -s "$yq_yaml_stderr_file" ]; then
                    log_message Warning "yq stderr (allowed_commands YAML): $(cat "$yq_yaml_stderr_file")"
                fi
                tool_instructions_addendum="You were supposed to be provided with a list of allowed commands for NORMAL mode, but it is currently unavailable or empty. If the task requires a command, you MUST state that you cannot perform the action without a valid command list and explain the situation. Do not attempt to use commands not explicitly provided to you.\\n"
            fi
            rm -f "$yq_yaml_stderr_file"
        elif [[ "$OPERATION_MODE" == "gremlin" ]] || [[ "$OPERATION_MODE" == "goblin" ]]; then
            tool_instructions_addendum="You are operating in $OPERATION_MODE mode. This mode allows you to suggest any standard Linux shell command you deem best for the current task step. You are NOT restricted to a predefined list. Choose the most appropriate and effective command to achieve the step's goal. Ensure the command is safe and directly relevant to the task.\\n\\n"
        fi
    fi
    # For phases other than "action", or if no specific addendum was set, tool_instructions_addendum remains empty.

    # Prepend tool instructions to the specific system prompt for the phase
    local final_system_prompt_for_phase="${tool_instructions_addendum}${system_prompt_for_phase}"

    # Ensure payload.json is valid JSON before processing. User must fix this manually.
    if ! jq -e . "$PAYLOAD_FILE" > /dev/null 2>&1; then
        log_message "Error" "$PAYLOAD_FILE is not valid JSON. Please fix it manually - remove comments, ensure correct syntax."
        return 1 # Indicate failure
    fi

    # Substitute placeholders in the payload template
    # The generic <system_prompt> in payload.json will take the phase-specific system prompt.
    # The generic <user_prompt> in payload.json will take the current_prompt_content.
    jq --arg sys "$final_system_prompt_for_phase" --arg user "$current_prompt_content" \
        'walk(if type == "string" then
            gsub("<system_prompt>"; $sys) | gsub("<user_prompt>"; $user)
        else . end)' "$PAYLOAD_FILE"
    return $? # Return jq's exit status
}

# --- Command Parsing ---
parse_suggested_command() {
    echo "$1" | awk '/```agent_command/{flag=1; next} /```/{flag=0} flag' | head -n 1
}

parse_llm_thought() {
    local input_str="$1"
    # Check if <think> and </think> tags exist
    if [[ "$input_str" == *"<think>"* && "$input_str" == *"</think>"* ]]; then
        # Extract content between the first <think> and its corresponding </think>
        local thought="${input_str#*<think>}" # Remove part before and including the first <think>
        thought="${thought%%</think>*}"       # Remove part after and including the first </think>
        # Trim leading/trailing whitespace and newlines
        thought=$(echo "$thought" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$thought"
    else
        echo "" # No think block found or tags are mismatched
    fi
}

parse_llm_plan() {
    local input_str="$1"
    if [[ "$input_str" == *"<checklist>"* && "$input_str" == *"</checklist>"* ]]; then
        local checklist_content="${input_str#*<checklist>}"
        checklist_content="${checklist_content%%</checklist>*}"
        # Trim leading/trailing whitespace and newlines
        checklist_content=$(echo "$checklist_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$checklist_content"
    else
        echo "" # No checklist block found
    fi
}

parse_llm_instruction() {
    local input_str="$1"
    if [[ "$input_str" == *"<instruction>"* && "$input_str" == *"</instruction>"* ]]; then
        local instruction_content="${input_str#*<instruction>}"
        instruction_content="${instruction_content%%</instruction>*}"
        # Trim leading/trailing whitespace and newlines
        instruction_content=$(echo "$instruction_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$instruction_content"
    else
        echo "" # No instruction block found
    fi
}

parse_llm_decision() {
    local input_str="$1"
    # Extracts content from <decision>TAG: content</decision>
    # Returns: "TAG: content"
    if [[ "$input_str" == *"<decision>"* && "$input_str" == *"</decision>"* ]]; then
        local decision_content="${input_str#*<decision>}"
        decision_content="${decision_content%%</decision>*}"
        decision_content=$(echo "$decision_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$decision_content"
    else
        echo "" # No decision block found
    fi
}

# --- New Function: Get LLM Description and Add to Config ---
get_llm_description_and_add_to_config() {
    local command_name="$1"
    log_message System "Attempting to get help output for command: $command_name"

    local help_output=""
    local help_exit_status=-1

    # Try command --help
    help_output=$(timeout "${COMMAND_TIMEOUT:-10}" "$command_name" --help 2>&1)
    help_exit_status=$?
    if [ $help_exit_status -ne 0 ] || [ -z "$help_output" ]; then
        log_message Debug "Command '$command_name --help' failed (status: $help_exit_status) or produced no output. Trying '-h'."
        help_output=$(timeout "${COMMAND_TIMEOUT:-10}" "$command_name" -h 2>&1)
        help_exit_status=$?
        if [ $help_exit_status -ne 0 ] || [ -z "$help_output" ]; then
            log_message Warning "Could not get help output for '$command_name' using --help or -h. Will ask LLM for a general description."
            help_output="" # Ensure help_output is empty if both failed
        else
            log_message Debug "Successfully got help output for '$command_name -h'."
        fi
    else
        log_message Debug "Successfully got help output for '$command_name --help'."
    fi

    local max_help_length=1500
    if [ ${#help_output} -gt $max_help_length ]; then
        log_message Warning "Help output for '$command_name' is very long (${#help_output} chars). Truncating to $max_help_length chars for LLM prompt."
        help_output="${help_output:0:$max_help_length}..."
    fi

    log_message System "Requesting LLM to describe command: $command_name"
    local description_prompt_content=""
    local system_prompt_for_description="You are an assistant that provides concise descriptions of Linux commands. Your response MUST be a valid JSON object containing a single key 'description' whose value is a short, one-sentence command description. Do NOT include any other text, explanations, or XML tags in your response. Output ONLY the JSON object."

    if [ -n "$help_output" ]; then
        description_prompt_content="Based on the following help output for the Linux shell command '$command_name', provide your response as a JSON object containing a single key \\\"description\\\" with a short, one-sentence string value describing the command's primary purpose. Output ONLY the JSON object.\\n\\nHelp Output:\\n\\\`\\\`\\\`\\n$help_output\\n\\\`\\\`\\\`\\n\\nJSON Output:"
    else
        description_prompt_content="Describe the general purpose and typical usage of the Linux shell command '$command_name'. Provide your response as a JSON object containing a single key \\\"description\\\" with a short, one-sentence string value. Do not include any other text or formatting outside the JSON object. Example for 'ls': {\\\"description\\\": \\\"List directory contents.\\\"}\\n\\nJSON Output:"
    fi

    local DESCRIPTION_PAYLOAD
    if ! jq -e . "$PAYLOAD_FILE" > /dev/null 2>&1; then
        log_message "Error" "$PAYLOAD_FILE is not valid JSON. Please fix it manually."
        return 1
    fi
    DESCRIPTION_PAYLOAD=$(jq --arg sys "$system_prompt_for_description" --arg user "$description_prompt_content" \
        'walk(if type == "string" then gsub("<system_prompt>"; $sys) | gsub("<user_prompt>"; $user) else . end)' "$PAYLOAD_FILE")
    local jq_payload_status=$?
    if [ $jq_payload_status -ne 0 ] || [ -z "$DESCRIPTION_PAYLOAD" ]; then
        log_message "Error" "Failed to create payload for command description for '$command_name'. JQ status: $jq_payload_status"
        return 1
    fi

    log_message Debug "Description Payload for '$command_name': $DESCRIPTION_PAYLOAD"

    local LLM_DESC_RESPONSE
    LLM_DESC_RESPONSE=$(curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" ${API_KEY:+-H "Authorization: Bearer $API_KEY"} -d "$DESCRIPTION_PAYLOAD")

    if [ -z "$LLM_DESC_RESPONSE" ]; then
        log_message Error "No response from LLM when requesting description for '$command_name'."
        return 1
    fi
    log_message Debug "LLM Raw Full Response for '$command_name': $LLM_DESC_RESPONSE"

    # Step 3: Extract the Relevant Field from LLM's JSON Response (using RESPONSE_PATH)
    # This field might contain the target JSON object mixed with other text (like thoughts).
    local LLM_RESPONSE_FIELD_CONTENT
    LLM_RESPONSE_FIELD_CONTENT=$(printf "%s" "$LLM_DESC_RESPONSE" | jq -r "$RESPONSE_PATH")
    local jq_extract_field_status=$?

    if [ $jq_extract_field_status -ne 0 ] || [ -z "$LLM_RESPONSE_FIELD_CONTENT" ] || [ "$LLM_RESPONSE_FIELD_CONTENT" == "null" ]; then
        log_message Error "Failed to extract LLM response field for '$command_name' using RESPONSE_PATH ('$RESPONSE_PATH')."
        log_message Debug "Raw LLM Full Response was: $LLM_DESC_RESPONSE"
        return 1
    fi
    log_message Debug "LLM Response Field Content for '$command_name' (pre-grep): [$LLM_RESPONSE_FIELD_CONTENT]"

    # Step 4: Isolate the JSON Object using grep
    # Process LLM_RESPONSE_FIELD_CONTENT to find and extract just the JSON object part.
    local EXTRACTED_JSON_OBJECT
    EXTRACTED_JSON_OBJECT=$(printf "%s" "$LLM_RESPONSE_FIELD_CONTENT" | grep -o -E '\{[^{}]*\}' | tail -n 1 | tr -d '\n')

    if [ -z "$EXTRACTED_JSON_OBJECT" ]; then
        log_message Error "Could not find/extract a JSON object like {...} from the LLM response field for '$command_name'."
        log_message Debug "LLM Response Field Content that was searched: [$LLM_RESPONSE_FIELD_CONTENT]"
        return 1
    fi
    log_message Debug "Isolated JSON Object for '$command_name' (post-grep): [$EXTRACTED_JSON_OBJECT]"

    # Step 5: Extract the .description using jq
    # Use jq -r ".description" on EXTRACTED_JSON_OBJECT.
    local COMMAND_DESCRIPTION
    COMMAND_DESCRIPTION=$(printf "%s" "$EXTRACTED_JSON_OBJECT" | jq -r ".description")
    local jq_desc_exit_status=$?

    if [ $jq_desc_exit_status -ne 0 ] || [ -z "$COMMAND_DESCRIPTION" ] || [ "$COMMAND_DESCRIPTION" == "null" ]; then
        log_message Error "Failed to extract '.description' from the isolated JSON object for '$command_name'."
        log_message Debug "Isolated JSON object used for extraction: [$EXTRACTED_JSON_OBJECT]"
        # Check if the extracted object was valid JSON at all
        if ! printf "%s" "$EXTRACTED_JSON_OBJECT" | jq -e . > /dev/null 2>&1; then
            log_message Error "The isolated JSON object was not valid JSON: [$EXTRACTED_JSON_OBJECT]"
        fi
        return 1
    fi

    # Step 6: Sanitize COMMAND_DESCRIPTION (Whitespace)
    COMMAND_DESCRIPTION=$(printf "%s" "$COMMAND_DESCRIPTION" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$COMMAND_DESCRIPTION" ]; then # Check after trimming
        log_message Error "Extracted command description for '$command_name' is empty after sanitization."
        return 1
    fi
    log_message System "LLM suggested description for '$command_name': '$COMMAND_DESCRIPTION'"

    # Step 7: Sanitize COMMAND_DESCRIPTION (for yq embedding)
    # Escape backslashes (\\ -> \\\\\\\\) and double quotes (\" -> \\\\\\") for shell + yq.
    local sanitized_desc_for_yq_embed
    sanitized_desc_for_yq_embed=$(printf "%s" "$COMMAND_DESCRIPTION" | sed -e 's/\\/\\\\\\\\/g' -e 's/"/\\\\"/g')
    
    local temp_config_file
    temp_config_file=$(mktemp)
    if [ -z "$temp_config_file" ]; then log_message Error "mktemp failed for temp config"; return 1; fi

    local yq_mod_stderr_file
    yq_mod_stderr_file=$(mktemp)
    if [ -z "$yq_mod_stderr_file" ]; then log_message Error "mktemp failed for yq mod stderr"; rm -f "$temp_config_file"; return 1; fi

    # Step 8: Update config.yaml using yq
    # Use the cat "$CONFIG_FILE" | yq "expression" - pattern.
    echo "cat \"$CONFIG_FILE\" | yq \".allowed_commands.$command_name = \\\"$sanitized_desc_for_yq_embed\\\"\" - > \"$temp_config_file\" 2> \"$yq_mod_stderr_file\""
    echo "$(cat "$CONFIG_FILE" | yq ".allowed_commands.$command_name = \"$sanitized_desc_for_yq_embed\"")" > "$temp_config_file" 2> "$yq_mod_stderr_file"
    local yq_mod_status=$?

    if [ $yq_mod_status -eq 0 ] && [ -s "$temp_config_file" ]; then
        local yq_check_stderr_file
        yq_check_stderr_file=$(mktemp)
        if [ -z "$yq_check_stderr_file" ]; then log_message Error "mktemp failed for yq check stderr"; rm -f "$temp_config_file" "$yq_mod_stderr_file"; return 1; fi

        if ! cat "$temp_config_file" | yq '.' > /dev/null 2> "$yq_check_stderr_file"; then
            log_message Error "yq modification generated invalid YAML for command '$command_name' (validated with yq .). Config not updated."
            if [ -s "$yq_check_stderr_file" ]; then log_message Error "yq validation stderr: $(cat "$yq_check_stderr_file")"; fi
            if [ -s "$yq_mod_stderr_file" ]; then log_message Error "Original yq modification stderr: $(cat "$yq_mod_stderr_file")"; fi
            log_message Debug "Problematic temp config content ($temp_config_file):\\n$(cat "$temp_config_file")"
            #rm -f "$temp_config_file" "$yq_check_stderr_file" "$yq_mod_stderr_file"
            return 1
        fi
        rm -f "$yq_check_stderr_file" "$yq_mod_stderr_file"

        mv "$temp_config_file" "$CONFIG_FILE"
        log_message System "Command '$command_name' with description '$COMMAND_DESCRIPTION' updated in $CONFIG_FILE using yq."
        ALLOWED_COMMAND_CHECK_MAP["$command_name"]=1
        return 0
    else
        log_message Error "yq failed to update $CONFIG_FILE for command '$command_name'. Exit status: $yq_mod_status. Config not updated."
        if [ -s "$yq_mod_stderr_file" ]; then log_message Error "yq modification stderr: $(cat "$yq_mod_stderr_file")"; fi
        if [ -f "$temp_config_file" ]; then
            if [ -s "$temp_config_file" ]; then
                 log_message Debug "Failed temp config content ($temp_config_file):\\n$(cat "$temp_config_file")"
            else
                 log_message Debug "yq produced an empty temp file ($temp_config_file)."
            fi
            rm -f "$temp_config_file"
        fi
        rm -f "$yq_mod_stderr_file"
        return 1
    fi
}

# --- New Function: Prompt for Command Permission ---
prompt_for_command_permission_and_update_config() {
    local cmd_to_check="$1"

    printf "${CLR_YELLOW}The agent wants to use the command '%s', which is not in the allowed list.${CLR_RESET}\n" "$cmd_to_check"
    printf "${CLR_YELLOW}Do you want to allow this? (y)es (this instance) / (n)o (deny this instance) / (a)lways (add to config & run) / (c)cancel task: ${CLR_RESET}"
    read -r USER_DECISION

    case "$USER_DECISION" in
        [Yy])
            log_message User "User allowed command '$cmd_to_check' for this instance."
            return 0 # Allowed
            ;;
        [Nn])
            log_message User "User denied command '$cmd_to_check' for this instance."
            return 1 # Denied
            ;;
        [Aa])
            log_message User "User chose to 'always' allow command '$cmd_to_check'. Attempting to add to config."
            if get_llm_description_and_add_to_config "$cmd_to_check"; then
                log_message System "Command '$cmd_to_check' successfully added to allowed_commands and will be executed."
                return 0 # Allowed
            else
                log_message Error "Failed to add command '$cmd_to_check' to config. It will not be executed."
                return 1 # Denied due to failure in adding
            fi
            ;;
        [Cc])
            log_message User "User chose to cancel the task."
            return 2 # Cancel task
            ;;
        *)
            log_message User "Invalid choice. Assuming 'no'. Command '$cmd_to_check' will not be executed."
            return 1 # Denied
            ;;
    esac
}

# --- Task Handling (Refactored for Plan-Act-Evaluate) ---
handle_task() {
    local initial_user_prompt="$1"
    local current_iteration=0
    local task_status="IN_PROGRESS" # Can be IN_PROGRESS, TASK_COMPLETE, TASK_FAILED

    # Initialize or reset state for the new task
    CURRENT_PLAN_STR=""
    CURRENT_INSTRUCTION=""  # New variable to hold the instruction for Action Agent
    CURRENT_PLAN_ARRAY=()   # This will hold the checklist items
    CURRENT_STEP_INDEX=0
    LAST_ACTION_TAKEN=""
    LAST_ACTION_RESULT=""
    USER_CLARIFICATION_RESPONSE=""
    LAST_EVAL_DECISION_TYPE="" # Reset this at the start of a new task
    
    local current_context_for_llm="$initial_user_prompt"

    log_message User "Starting task: $initial_user_prompt"

    while [ "$task_status" == "IN_PROGRESS" ]; do # Loop until task status is no longer IN_PROGRESS
        current_iteration=$((current_iteration + 1))
        log_message System "Iteration: $current_iteration"

        # 1. PLAN PHASE (or re-plan)
        if [ -z "$CURRENT_PLAN_STR" ] || [[ "$LAST_EVAL_DECISION_TYPE" == "REVISE_PLAN" ]] || 
           ([[ -n "$USER_CLARIFICATION_RESPONSE" ]] && ([[ "$LAST_EVAL_DECISION_TYPE" == "CLARIFY_USER" ]] || [[ "$LAST_EVAL_DECISION_TYPE" == "PLANNER_CLARIFY" ]])); then # PLANNER_CLARIFY is a pseudo-type for internal logic
            log_message System "Entering PLAN phase."
            local planner_input_prompt="$current_context_for_llm"

            PAYLOAD=$(prepare_payload "plan" "$planner_input_prompt")
            if [ $? -ne 0 ]; then log_message "Error" "Failed to prepare payload for PLAN phase."; task_status="TASK_FAILED"; break; fi

            RESPONSE=$(curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" ${API_KEY:+-H "Authorization: Bearer $API_KEY"} -d "$PAYLOAD")
            if [ -z "$RESPONSE" ]; then log_message "Error" "No response from LLM for PLAN phase."; task_status="TASK_FAILED"; break; fi
            log_message Debug "PLAN phase: Attempting to parse with RESPONSE_PATH: '$RESPONSE_PATH'"
            LLM_RESPONSE_CONTENT=$(printf "%s" "$RESPONSE" | jq -r "$RESPONSE_PATH") # Changed echo to printf
            local jq_exit_status=$?

            if [ $jq_exit_status -ne 0 ] || [ -z "$LLM_RESPONSE_CONTENT" ] || [ "$LLM_RESPONSE_CONTENT" == "null" ]; then 
                log_message "Error" "Failed to extract/validate LLM response for PLAN. Raw: $RESPONSE"; 
                task_status="TASK_FAILED"; break; 
            fi
            append_context "Planner Input: $planner_input_prompt" "$RESPONSE"

            LLM_THOUGHT=$(parse_llm_thought "$LLM_RESPONSE_CONTENT")
            if [ -n "$LLM_THOUGHT" ]; then log_message "Plan Agent" "[Planner Thought]: $LLM_THOUGHT"; fi

            DECISION_FROM_PLANNER=$(parse_llm_decision "$LLM_RESPONSE_CONTENT")
            if [[ "$DECISION_FROM_PLANNER" == CLARIFY_USER:* ]]; then
                if [[ "$ALLOW_CLARIFYING_QUESTIONS" == "true" ]]; then
                    CLARIFICATION_QUESTION="${DECISION_FROM_PLANNER#CLARIFY_USER: }"
                    log_message "Plan Agent" "[Planner Clarification]: $CLARIFICATION_QUESTION"
                    printf "${CLR_GREEN}Plan Agent asks: ${CLR_RESET}${CLR_BOLD_GREEN}%s${CLR_RESET} " "$CLARIFICATION_QUESTION"
                    read -r USER_CLARIFICATION_RESPONSE
                    current_context_for_llm="Original request: '$initial_user_prompt'. My previous question (from Planner): '$CLARIFICATION_QUESTION'. User's answer: '$USER_CLARIFICATION_RESPONSE'. Please generate a new plan based on this clarification."
                    LAST_EVAL_DECISION_TYPE="PLANNER_CLARIFY" 
                    CURRENT_PLAN_STR="" 
                    continue 
                else
                    # When questions are disabled, we force a plan revision without asking the user
                    log_message "Warning" "Plan Agent attempted to ask a clarifying question when questions are disabled: '${DECISION_FROM_PLANNER#CLARIFY_USER: }'"
                    log_message "System" "Forcing Plan Agent to continue without asking the question"
                    current_context_for_llm="Original request: '$initial_user_prompt'. IMPORTANT: Clarifying questions are disabled. You attempted to ask: '${DECISION_FROM_PLANNER#CLARIFY_USER: }'. You must not ask questions. Instead, make reasonable assumptions and continue with a complete plan. Be resourceful and continue without user input."
                    LAST_EVAL_DECISION_TYPE="REVISE_PLAN"
                    CURRENT_PLAN_STR="" 
                    continue
                fi
            fi
            
            CURRENT_PLAN_STR=$(parse_llm_plan "$LLM_RESPONSE_CONTENT")
            CURRENT_INSTRUCTION=$(parse_llm_instruction "$LLM_RESPONSE_CONTENT")
            
            if [ -z "$CURRENT_PLAN_STR" ]; then
                log_message "Warning" "Planner did not return a checklist. Requesting new plan."
                current_context_for_llm="Original request: '$initial_user_prompt'. Your previous response did not include a proper <checklist> section. Please create a new plan with a proper checklist and instruction."
                LAST_EVAL_DECISION_TYPE="REVISE_PLAN"
                CURRENT_PLAN_STR="" 
                continue
            fi
            
            if [ -z "$CURRENT_INSTRUCTION" ]; then
                log_message "Warning" "Planner did not return an instruction. Requesting new plan with instruction."
                current_context_for_llm="Original request: '$initial_user_prompt'. Your previous response did not include a proper <instruction> section. Please create a new plan with a proper instruction for the next step."
                LAST_EVAL_DECISION_TYPE="REVISE_PLAN"
                CURRENT_PLAN_STR=""
                continue
            fi
            
            log_message "Plan Agent" "[Planner Checklist]:\\n$CURRENT_PLAN_STR"
            log_message "Plan Agent" "[Next Instruction]: $CURRENT_INSTRUCTION"
            
            mapfile -t CURRENT_PLAN_ARRAY < <(echo "$CURRENT_PLAN_STR" | sed '/^[[:space:]]*$/d') 
            CURRENT_STEP_INDEX=0
            USER_CLARIFICATION_RESPONSE="" 
            LAST_EVAL_DECISION_TYPE="" # Clear decision type after successful planning
        fi

        # 2. ACTION PHASE
        log_message System "Entering ACTION phase for instruction: $CURRENT_INSTRUCTION"

        local actor_input_prompt="User's original request: '$initial_user_prompt'\\n\\nInstruction to execute: '$CURRENT_INSTRUCTION'"
        
        PAYLOAD=$(prepare_payload "action" "$actor_input_prompt")
        if [ $? -ne 0 ]; then log_message "Error" "Failed to prepare payload for ACTION phase."; task_status="TASK_FAILED"; break; fi
        
        RESPONSE=$(curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" ${API_KEY:+-H "Authorization: Bearer $API_KEY"} -d "$PAYLOAD")
        if [ -z "$RESPONSE" ]; then log_message "Error" "No response from LLM for ACTION phase."; task_status="TASK_FAILED"; break; fi
        log_message Debug "ACTION phase: Attempting to parse with RESPONSE_PATH: '$RESPONSE_PATH'"
        LLM_RESPONSE_CONTENT=$(printf "%s" "$RESPONSE" | jq -r "$RESPONSE_PATH") # Changed echo to printf
        local jq_exit_status=$?

        if [ $jq_exit_status -ne 0 ] || [ -z "$LLM_RESPONSE_CONTENT" ] || [ "$LLM_RESPONSE_CONTENT" == "null" ]; then 
            log_message "Error" "Failed to extract/validate LLM response for ACTION. Raw: $RESPONSE"; 
            task_status="TASK_FAILED"; break; 
        fi
        append_context "Actor Input: $actor_input_prompt" "$RESPONSE"

        LLM_THOUGHT=$(parse_llm_thought "$LLM_RESPONSE_CONTENT")
        if [ -n "$LLM_THOUGHT" ]; then log_message "Action Agent" "[Actor Thought]: $LLM_THOUGHT"; fi

        SUGGESTED_CMD=$(parse_suggested_command "$LLM_RESPONSE_CONTENT")
        CMD_OUTPUT=""
        CMD_STATUS=-1 # Default to -1 to indicate command not run or other issue

        if [[ -n "$SUGGESTED_CMD" ]]; then
            if [[ "$SUGGESTED_CMD" == "report_task_completion" ]]; then
                log_message "Eval Agent" "Received report_task_completion. Task will be marked as complete."
                task_status="TASK_COMPLETE"
                LAST_ACTION_TAKEN="Internal command: report_task_completion"
                LAST_ACTION_RESULT="Task marked as complete by Evaluator."
            else
                # Update to handle command separators (&&, ||, ;, |, &, etc.)
                log_message "Debug" "Checking command permissions for: $SUGGESTED_CMD"
                
                # Function to check command permission
                check_cmd_permission() {
                    local cmd_to_check="$1"
                    local base_cmd=$(echo "$cmd_to_check" | awk '{print $1}')
                    
                    log_message "Debug" "Checking base command: $base_cmd from $cmd_to_check"
                    
                    if [[ -v ALLOWED_COMMAND_CHECK_MAP["$base_cmd"] || -n "${ALLOWED_COMMAND_CHECK_MAP[$base_cmd]-}" ]]; then
                        return 0  # Allowed
                    elif [[ -v BLACKLISTED_COMMAND_CHECK_MAP["$base_cmd"] || -n "${BLACKLISTED_COMMAND_CHECK_MAP[$base_cmd]-}" ]]; then
                        return 2  # Blacklisted
                    else
                        return 1  # Not allowed
                    fi
                }
                
                # Split command by separators and check each part
                local all_parts_allowed=true
                local no_blacklisted_parts=true
                local parts_to_check=()
                
                # Use sed to replace separators with newlines, then check each line
                while IFS= read -r part; do
                    part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    if [ -n "$part" ]; then
                        parts_to_check+=("$part")
                    fi
                done < <(echo "$SUGGESTED_CMD" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|[^|]/\n|/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                
                log_message "Debug" "Command parts to check: ${parts_to_check[*]}"
                
                local disallowed_cmds=()
                local blacklisted_cmds=()
                for part in "${parts_to_check[@]}"; do
                    local actual_cmd=$(echo "$part" | awk '{print $1}')
                    # Check if it is an actual command using `which`
                    if ! command -v "$actual_cmd" &> /dev/null && ! "$(which "$actual_cmd" &> /dev/null)"; then
                        log_message "Debug" "Command '$actual_cmd' not found in PATH. Skipping check."
                        continue
                    fi
                    
                    # First check if command is blacklisted (priority over allowed)
                    if [[ -v BLACKLISTED_COMMAND_CHECK_MAP["$actual_cmd"] || -n "${BLACKLISTED_COMMAND_CHECK_MAP[$actual_cmd]-}" ]]; then
                        no_blacklisted_parts=false
                        blacklisted_cmds+=("$actual_cmd")
                    # Then check if command is allowed
                    elif [[ ! -v ALLOWED_COMMAND_CHECK_MAP["$actual_cmd"] && -z "${ALLOWED_COMMAND_CHECK_MAP[$actual_cmd]-}" ]]; then
                        all_parts_allowed=false
                        disallowed_cmds+=("$actual_cmd")
                    fi
                done
                
                local execute_this_command=false
                
                # First check for blacklisted commands - these are always denied regardless of mode
                if [ "$no_blacklisted_parts" = false ]; then
                    log_message "System" "Some command parts from '$SUGGESTED_CMD' are BLACKLISTED: ${blacklisted_cmds[*]}"
                    CMD_OUTPUT="Command '$SUGGESTED_CMD' contains blacklisted commands: ${blacklisted_cmds[*]}. Blacklisted commands are never allowed."
                    CMD_STATUS=1 # Specific code for blacklist denial
                    LAST_ACTION_TAKEN="Command '$SUGGESTED_CMD' denied due to blacklist."
                    execute_this_command=false
                # If no blacklisted commands, proceed with normal command check logic
                elif [ "$all_parts_allowed" = true ]; then
                    log_message "System" "All command parts from '$SUGGESTED_CMD' are allowed by existing config."
                    execute_this_command=true
                else
                    log_message "System" "Some command parts from '$SUGGESTED_CMD' are NOT in allowed commands: ${disallowed_cmds[*]}"
                    if [[ "$OPERATION_MODE" == "gremlin" ]]; then
                        # In Gremlin mode, prompt for each disallowed command
                        for disallowed_cmd in "${disallowed_cmds[@]}"; do
                            log_message "System" "Gremlin Mode: Dynamic command approval. Requesting user permission for '$disallowed_cmd'."
                            prompt_for_command_permission_and_update_config "$disallowed_cmd"
                            local permission_status=$?
                            case "$permission_status" in
                                0) # Allowed (either 'yes' or 'always' succeeded)
                                    log_message "System" "Permission granted for '$disallowed_cmd'."
                                    execute_this_command=true
                                    ;;
                                1) # Denied
                                    log_message "System" "Permission denied for '$disallowed_cmd'."
                                    CMD_OUTPUT="Command '$disallowed_cmd' was denied by the user for this instance."
                                    CMD_STATUS=1 # Specific code for user denial
                                    LAST_ACTION_TAKEN="Command '$SUGGESTED_CMD' denied by user."
                                    execute_this_command=false
                                    ;;
                                2) # Cancel task
                                    log_message "System" "Task cancelled by user due to command permission choice for '$disallowed_cmd'."
                                    task_status="TASK_FAILED" # This will break the main loop after this iteration's EVAL
                                    CMD_OUTPUT="Task cancelled by user at command permission prompt for '$disallowed_cmd'."
                                    CMD_STATUS=125 # Arbitrary non-zero for cancellation
                                    LAST_ACTION_TAKEN="Task cancelled by user over command '$SUGGESTED_CMD'."
                                    execute_this_command=false
                                    ;;
                            esac
                        done
                    else # Normal mode: reject non-whitelisted
                        log_message "System" "Normal Mode: Command '$SUGGESTED_CMD' not in allowed_commands. Rejected."
                        CMD_OUTPUT="Command '$SUGGESTED_CMD' is not in allowed_commands and operation mode is 'normal'."
                        CMD_STATUS=1 # Indicate failure/denial
                        LAST_ACTION_TAKEN="Command '$SUGGESTED_CMD' denied (not whitelisted, mode: normal)."
                        execute_this_command=false
                    fi
                fi

                if [ "$execute_this_command" == "true" ]; then
                    LAST_ACTION_TAKEN="Executed command: $SUGGESTED_CMD"
                    log_message "Command" "$SUGGESTED_CMD"
                    if [[ "$OPERATION_MODE" == "goblin" || "$OPERATION_MODE" == "gremlin" ]]; then # Goblin and Gremlin: no confirmation for allowed/approved
                        log_message "System" "Executing in $OPERATION_MODE Mode: $SUGGESTED_CMD - timeout: ${COMMAND_TIMEOUT}s"
                        CMD_OUTPUT=$(timeout "$COMMAND_TIMEOUT" bash -c "$SUGGESTED_CMD" 2>&1)
                        CMD_STATUS=$? 
                        log_message "System" "Output:\\n$CMD_OUTPUT"
                    else # Normal mode: confirm whitelisted commands
                        printf "${CLR_GREEN}[%s] [User]:${CLR_RESET}${CLR_BOLD_GREEN} Execute suggested command? ${CLR_RESET}'${CLR_BOLD_YELLOW}%s${CLR_RESET}'${CLR_BOLD_GREEN} [y/N]: ${CLR_RESET}" "$(date +'%Y-%m-%d %H:%M:%S')" "$SUGGESTED_CMD"
                        read -r CONFIRM
                        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                            log_message "System" "Executing: $SUGGESTED_CMD - timeout: ${COMMAND_TIMEOUT}s"
                            CMD_OUTPUT=$(timeout "$COMMAND_TIMEOUT" bash -c "$SUGGESTED_CMD" 2>&1)
                            CMD_STATUS=$?
                            log_message "System" "Output:\\n$CMD_OUTPUT"
                        else
                            log_message User "Command execution cancelled by user confirmation."
                            CMD_STATUS=124 
                            CMD_OUTPUT="User cancelled execution at confirmation prompt."
                        fi
                    fi
                    LAST_ACTION_RESULT="Exit Code: $CMD_STATUS. Output:\\n$CMD_OUTPUT"
                elif [ "$task_status" == "IN_PROGRESS" ]; then
                    if [ -z "$LAST_ACTION_TAKEN" ]; then
                        LAST_ACTION_TAKEN="Command '$SUGGESTED_CMD' not executed due to permissions."
                    fi
                    LAST_ACTION_RESULT="Exit Code: $CMD_STATUS. Output:\\n$CMD_OUTPUT"
                    log_message "System" "Command '$SUGGESTED_CMD' was not executed. Reason: $CMD_OUTPUT"
                    
                    # Continue with evaluation phase even when a command is rejected
                    # This ensures the agent can recover from rejected commands rather than terminating
                fi
            fi
        else
            local actor_question_full_response="$LLM_RESPONSE_CONTENT"
            if [ -n "$LLM_THOUGHT" ]; then
                 actor_question_full_response="${actor_question_full_response//$LLM_THOUGHT/}"
                 actor_question_full_response="${actor_question_full_response//<think>/}"
                 actor_question_full_response="${actor_question_full_response//<\/think>/}"
            fi
            local actor_question=$(echo "$actor_question_full_response" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [ -z "$actor_question" ]; then
                log_message Warning "Actor did not suggest a command and provided no textual response/question."
                LAST_ACTION_TAKEN="Actor provided no command and no question."
                LAST_ACTION_RESULT="Actor LLM response was empty or only contained thought: $LLM_RESPONSE_CONTENT"
                CMD_STATUS=1 # Indicate failure for this action step, evaluator needs to decide what to do.
            else
                log_message "Action Agent" "[Actor Question]: $actor_question"
                printf "${CLR_GREEN}Action Agent asks: ${CLR_RESET}${CLR_BOLD_GREEN}%s${CLR_RESET} " "$actor_question"
                read -r USER_CLARIFICATION_RESPONSE
                LAST_ACTION_TAKEN="Asked user (by Action Agent as per instruction): $actor_question"
                LAST_ACTION_RESULT="User responded: $USER_CLARIFICATION_RESPONSE"
                CMD_STATUS=0 # Question asked and answered, considered success for this action step
            fi
        fi
        log_message Debug "Last Action Taken: $LAST_ACTION_TAKEN"
        log_message Debug "Last Action Result: $LAST_ACTION_RESULT"

        # 3. EVALUATION PHASE
        if [[ "$task_status" == "TASK_COMPLETE" && "$SUGGESTED_CMD" == "report_task_completion" ]]; then
            log_message System "Skipping Evaluation phase as task was completed by report_task_completion."
            break # Exit main while loop, task completion will be handled
        fi

        log_message System "Entering EVALUATION phase."
        local evaluator_input_prompt="User's original request: '$initial_user_prompt'\\n\\nChecklist:\\n$CURRENT_PLAN_STR\\n\\nAction Taken:\\n$LAST_ACTION_TAKEN\\n\\nResult of Action:\\n$LAST_ACTION_RESULT"

        PAYLOAD=$(prepare_payload "evaluate" "$evaluator_input_prompt")
        if [ $? -ne 0 ]; then log_message "Error" "Failed to prepare payload for EVALUATION phase."; task_status="TASK_FAILED"; break; fi

        RESPONSE=$(curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" ${API_KEY:+-H "Authorization: Bearer $API_KEY"} -d "$PAYLOAD")
        if [ -z "$RESPONSE" ]; then log_message "Error" "No response from LLM for EVALUATION phase."; task_status="TASK_FAILED"; break; fi
        log_message Debug "EVALUATION phase: Attempting to parse with RESPONSE_PATH: '$RESPONSE_PATH'"
        LLM_RESPONSE_CONTENT=$(printf "%s" "$RESPONSE" | jq -r "$RESPONSE_PATH") # Changed echo to printf
        local jq_exit_status=$?

        if [ $jq_exit_status -ne 0 ] || [ -z "$LLM_RESPONSE_CONTENT" ] || [ "$LLM_RESPONSE_CONTENT" == "null" ]; then 
            log_message "Error" "Failed to extract/validate LLM response for EVALUATION. Raw: $RESPONSE"; 
            task_status="TASK_FAILED"; break; 
        fi
        append_context "Evaluator Input: $evaluator_input_prompt" "$RESPONSE"

        LLM_THOUGHT=$(parse_llm_thought "$LLM_RESPONSE_CONTENT")
        if [ -n "$LLM_THOUGHT" ]; then log_message "Eval Agent" "[Evaluator Thought]: $LLM_THOUGHT"; fi

        EVALUATOR_DECISION_FULL=$(parse_llm_decision "$LLM_RESPONSE_CONTENT")
        log_message "Eval Agent" "[Evaluator Decision]: $EVALUATOR_DECISION_FULL"

        if [ -z "$EVALUATOR_DECISION_FULL" ]; then
            log_message "Error" "Evaluator did not return a decision. LLM Response: $LLM_RESPONSE_CONTENT. Assuming task failed."
            task_status="TASK_FAILED"; break;
        fi

        EVALUATOR_DECISION_TYPE="${EVALUATOR_DECISION_FULL%%:*}"
        EVALUATOR_MESSAGE="${EVALUATOR_DECISION_FULL#*: }"
        LAST_EVAL_DECISION_TYPE="$EVALUATOR_DECISION_TYPE"

        case "$EVALUATOR_DECISION_TYPE" in
            TASK_COMPLETE)
                log_message "Eval Agent" "Task marked COMPLETE by evaluator. Summary: $EVALUATOR_MESSAGE"
                task_status="TASK_COMPLETE"
                ;;
            TASK_FAILED)
                log_message "Eval Agent" "Task marked FAILED by evaluator. Reason: $EVALUATOR_MESSAGE"
                task_status="TASK_FAILED"
                ;;
            CONTINUE_PLAN)
                log_message "Eval Agent" "Evaluator: CONTINUE_PLAN. $EVALUATOR_MESSAGE"
                # Request the next instruction from the Plan Agent for the next iteration
                current_context_for_llm="Original request: '$initial_user_prompt'. The previous instruction ('$CURRENT_INSTRUCTION') resulted in: '$LAST_ACTION_RESULT'. Evaluator feedback: '$EVALUATOR_MESSAGE'. Please provide the next instruction based on the updated checklist."
                CURRENT_PLAN_STR="" # Force the planner to re-plan with next instruction 
                USER_CLARIFICATION_RESPONSE="" 
                ;;
            REVISE_PLAN)
                log_message "Eval Agent" "Evaluator: REVISE_PLAN. Reason: $EVALUATOR_MESSAGE"
                current_context_for_llm="Original request: '$initial_user_prompt'. The previous instruction ('$CURRENT_INSTRUCTION') resulted in: '$LAST_ACTION_RESULT'. Evaluator suggests revision: '$EVALUATOR_MESSAGE'. Please revise your checklist and provide a new instruction."
                CURRENT_PLAN_STR="" 
                USER_CLARIFICATION_RESPONSE=""
                ;;
            CLARIFY_USER)
                CLARIFICATION_QUESTION="$EVALUATOR_MESSAGE"
                log_message "Eval Agent" "[Evaluator Clarification]: $CLARIFICATION_QUESTION"
                if [[ "$ALLOW_CLARIFYING_QUESTIONS" == "true" ]]; then
                    printf "${CLR_GREEN}Eval Agent asks: ${CLR_RESET}${CLR_BOLD_GREEN}%s${CLR_RESET} " "$CLARIFICATION_QUESTION"
                    read -r USER_CLARIFICATION_RESPONSE
                    current_context_for_llm="Original request: '$initial_user_prompt'. After action '$LAST_ACTION_TAKEN' (result: '$LAST_ACTION_RESULT'), evaluator needs clarification. Question asked: '$CLARIFICATION_QUESTION'. User's answer: '$USER_CLARIFICATION_RESPONSE'. Please revise your checklist and provide a new instruction based on this clarification."
                    CURRENT_PLAN_STR="" 
                else
                    log_message "Warning" "Clarifying questions are disabled. Skipping Evaluator's clarification request."
                    task_status="TASK_FAILED"; break;
                fi
                ;;
            *)
                log_message "Error" "Unknown decision from Evaluator: '$EVALUATOR_DECISION_FULL'. Assuming task failed."
                task_status="TASK_FAILED"
                ;;
        esac
        
        if [ "$task_status" != "IN_PROGRESS" ]; then
            break 
        fi

    done # End of main while loop

    if [ "$task_status" == "TASK_COMPLETE" ]; then
        log_message User "Task completed successfully."
        return 0
    else
        log_message User "Task failed or was aborted."
        return 1
    fi
}

# --- Main Loop ---
trap 'log_message "System" "Session terminated by user - Ctrl-C."; exit 0' INT

if [ "$#" -gt 0 ]; then
    USER_PROMPT_ARGS="$*"
    handle_task "$USER_PROMPT_ARGS"
else
    while true; do
        printf "${CLR_GREEN}Enter your task (or 'exit' to quit):${CLR_RESET} "
        read -r USER_PROMPT_LOOP
        if [[ "$USER_PROMPT_LOOP" == "exit" ]]; then
            log_message User "Exiting session."
            break
        fi
        handle_task "$USER_PROMPT_LOOP"
    done
fi

log_message System "Bash Agent finished."
