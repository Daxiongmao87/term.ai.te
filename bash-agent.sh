#!/bin/bash
set -e # Added for stricter error checking
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
CONFIG_DIR="./config" # Changed to use local ./config directory

log_message Debug "Preparing to set CONFIG_FILE. CONFIG_DIR='${CONFIG_DIR}'"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
declare PAYLOAD_FILE="$CONFIG_DIR/payload.json"
declare RESPONSE_PATH_FILE="$CONFIG_DIR/response_path_template.txt"
declare CONTEXT_FILE="$CONFIG_DIR/context.json"
declare JQ_ERROR_LOG="$CONFIG_DIR/jq_error.log"

# --- Global State for Agent Loop ---
declare CURRENT_PLAN_STR=""
declare -a CURRENT_PLAN_ARRAY=()
declare CURRENT_STEP_INDEX=0
declare LAST_ACTION_TAKEN=""
declare LAST_ACTION_RESULT=""
declare USER_CLARIFICATION_RESPONSE=""
declare LAST_EVAL_DECISION_TYPE=""
declare MAX_ITERATIONS=10 # Prevent infinite loops

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
# gremlin_mode: If true, executes suggested commands without confirmation. DANGEROUS!
# command_timeout: Timeout in seconds for executed commands (e.g., 10 for 10 seconds).
# enable_dynamic_command_approval: If true, prompts the user for approval of non-whitelisted commands.

endpoint: \"http://localhost:11434/api/generate\" # Example for Ollama /api/generate
# endpoint: \"http://localhost:11434/api/chat\" # Example for Ollama /api/chat
# endpoint: \"https://api.openai.com/v1/chat/completions\" # Example for OpenAI

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

gremlin_mode: false # Set to true to execute commands without confirmation (DANGEROUS!)
command_timeout: 30 # Default timeout for commands in seconds
enable_dynamic_command_approval: false # Set to true to enable dynamic approval for non-whitelisted commands
"

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
REQUIRED_CONFIG_FIELDS_EXISTENCE=(endpoint plan_prompt action_prompt evaluate_prompt allowed_commands gremlin_mode command_timeout enable_dynamic_command_approval)
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

GREMLIN_MODE=$(read_yq_value ".gremlin_mode" "// false")
if [[ "$GREMLIN_MODE" != "true" && "$GREMLIN_MODE" != "false" ]]; then
    log_message "Error" "GREMLIN_MODE in $CONFIG_FILE must be 'true' or 'false', got '$GREMLIN_MODE'."
    exit 1
fi

COMMAND_TIMEOUT=$(read_yq_value ".command_timeout" "// 30")
if ! [[ "$COMMAND_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$COMMAND_TIMEOUT" -lt 0 ]; then # Allow 0 for no timeout if desired, though >=1 is typical
    log_message "Error" "COMMAND_TIMEOUT ('$COMMAND_TIMEOUT') in $CONFIG_FILE must be a non-negative integer."
    exit 1
fi

ENABLE_DYNAMIC_COMMAND_APPROVAL=$(read_yq_value ".enable_dynamic_command_approval" "// false")
if [[ "$ENABLE_DYNAMIC_COMMAND_APPROVAL" != "true" && "$ENABLE_DYNAMIC_COMMAND_APPROVAL" != "false" ]]; then
    log_message "Error" "ENABLE_DYNAMIC_COMMAND_APPROVAL in $CONFIG_FILE must be 'true' or 'false', got '$ENABLE_DYNAMIC_COMMAND_APPROVAL'."
    exit 1
fi

ENABLE_DYNAMIC_COMMAND_APPROVAL=$([[ "$ENABLE_DYNAMIC_COMMAND_APPROVAL" == "true" ]] && echo true || echo false)

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

    local allowed_commands_yaml_block
    local yq_yaml_stderr_file
    yq_yaml_stderr_file=$(mktemp)
    # Get the .allowed_commands as a YAML block string
    allowed_commands_yaml_block=$(cat "$CONFIG_FILE" | yq '.allowed_commands' 2> "$yq_yaml_stderr_file")
    local yq_yaml_status=$?
    
    local tool_instructions_addendum=""
    if [ $yq_yaml_status -eq 0 ] && [ -n "$allowed_commands_yaml_block" ] && [ "$allowed_commands_yaml_block" != "null" ]; then
        # This addendum is primarily for the "action" phase, but could be included in others if needed.
        # The action_prompt specifically mentions that allowed_commands will be provided.
        if [ "$phase" == "action" ]; then
            tool_instructions_addendum="You are permitted to use the following commands. Their names and descriptions are provided below in YAML format. Adhere to these commands and their specified uses:\\n\\n\`\`\`yaml\\n${allowed_commands_yaml_block}\\n\`\`\`\\n\\n"
        fi
    else
        log_message Warning "Could not fetch or format allowed_commands YAML block for LLM instructions."
        if [ -s "$yq_yaml_stderr_file" ]; then
            log_message Warning "yq stderr (allowed_commands YAML): $(cat "$yq_yaml_stderr_file")"
        fi
    fi
    rm -f "$yq_yaml_stderr_file"

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
    if [[ "$input_str" == *"<plan>"* && "$input_str" == *"</plan>"* ]]; then
        local plan_content="${input_str#*<plan>}"
        plan_content="${plan_content%%</plan>*}"
        # Trim leading/trailing whitespace and newlines
        plan_content=$(echo "$plan_content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$plan_content"
    else
        echo "" # No plan block found
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
    log_message System "Requesting LLM to describe command: $command_name"

    local description_prompt_content="Describe the general purpose and typical usage of the Linux shell command '$command_name'. Provide a concise, one-sentence description suitable for a configuration file entry. Example for 'ls': 'List directory contents.'"
    local system_prompt_for_description="You are a helpful assistant that provides concise descriptions of Linux commands."

    local DESCRIPTION_PAYLOAD
    DESCRIPTION_PAYLOAD=$(jq -n --arg model "your-model-name:latest" \
                              --arg sys_prompt "$system_prompt_for_description" \
                              --arg user_prompt "$description_prompt_content" \
                              '{model: $model, system: $sys_prompt, prompt: $user_prompt, stream: false}')

    if [ -z "$DESCRIPTION_PAYLOAD" ]; then
        log_message Error "Failed to create payload for command description for '$command_name'."
        return 1
    fi

    log_message Debug "Description Payload for '$command_name': $DESCRIPTION_PAYLOAD"

    local LLM_DESC_RESPONSE
    LLM_DESC_RESPONSE=$(curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" ${API_KEY:+-H "Authorization: Bearer $API_KEY"} -d "$DESCRIPTION_PAYLOAD")

    if [ -z "$LLM_DESC_RESPONSE" ]; then
        log_message Error "No response from LLM when requesting description for '$command_name'."
        return 1
    fi

    log_message Debug "LLM Raw Description Response for '$command_name': $LLM_DESC_RESPONSE"
    local COMMAND_DESCRIPTION
    COMMAND_DESCRIPTION=$(printf "%s" "$LLM_DESC_RESPONSE" | jq -r "$RESPONSE_PATH")
    local jq_desc_exit_status=$?

    if [ $jq_desc_exit_status -ne 0 ] || [ -z "$COMMAND_DESCRIPTION" ] || [ "$COMMAND_DESCRIPTION" == "null" ]; then
        log_message Error "Failed to extract description for '$command_name' from LLM response. Raw: $LLM_DESC_RESPONSE"
        return 1
    fi

    COMMAND_DESCRIPTION=$(echo "$COMMAND_DESCRIPTION" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/"/\\"/g') # Sanitize

    if [ -z "$COMMAND_DESCRIPTION" ]; then
        log_message Error "Extracted command description for '$command_name' is empty after sanitization."
        return 1
    fi
    
    log_message System "LLM suggested description for '$command_name': '$COMMAND_DESCRIPTION'"

    local yq_add_stderr_file
    yq_add_stderr_file=$(mktemp)
    
    cat "$CONFIG_FILE" | yq ".allowed_commands += {\"$command_name\": \"$COMMAND_DESCRIPTION\"}" > "${CONFIG_FILE}.tmp" 2> "$yq_add_stderr_file"
    local yq_add_status=$?

    if [ $yq_add_status -ne 0 ]; then
        log_message Error "yq failed to add command '$command_name' to $CONFIG_FILE. Exit status: $yq_add_status."
        if [ -s "$yq_add_stderr_file" ]; then
            log_message Error "yq stderr: $(cat "$yq_add_stderr_file")"
        fi
        rm -f "$yq_add_stderr_file" "${CONFIG_FILE}.tmp"
        return 1
    else
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        log_message System "Command '$command_name' with description '$COMMAND_DESCRIPTION' added to $CONFIG_FILE."
    fi
    rm -f "$yq_add_stderr_file"
    return 0
}

# --- New Function: Prompt for Command Permission ---
# Returns: 0 (allow), 1 (deny), 2 (cancel task)
prompt_for_command_permission_and_update_config() {
    local cmd_to_check="$1"

    printf "${CLR_YELLOW}The agent wants to use the command '%s', which is not in the allowed list.${CLR_RESET}\n" "$cmd_to_check"
    printf "${CLR_YELLOW}Do you want to allow this? (y)es (this instance) / (n)o (deny this instance) / (a)lways (add to config & run) / (c)ancel task: ${CLR_RESET}"
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
                ALLOWED_COMMAND_CHECK_MAP["$cmd_to_check"]=1 # Update in-memory map for current session
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
    CURRENT_PLAN_ARRAY=()
    CURRENT_STEP_INDEX=0
    LAST_ACTION_TAKEN=""
    LAST_ACTION_RESULT=""
    USER_CLARIFICATION_RESPONSE=""
    LAST_EVAL_DECISION_TYPE="" # Reset this at the start of a new task
    
    local current_context_for_llm="$initial_user_prompt"

    log_message User "Starting task: $initial_user_prompt"

    while [ "$current_iteration" -lt "$MAX_ITERATIONS" ] && [ "$task_status" == "IN_PROGRESS" ]; do
        current_iteration=$((current_iteration + 1))
        log_message System "Iteration: $current_iteration/$MAX_ITERATIONS"

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
                CLARIFICATION_QUESTION="${DECISION_FROM_PLANNER#CLARIFY_USER: }"
                log_message "Plan Agent" "[Planner Clarification]: $CLARIFICATION_QUESTION"
                printf "${CLR_GREEN}Plan Agent asks: ${CLR_RESET}${CLR_BOLD_GREEN}%s${CLR_RESET} " "$CLARIFICATION_QUESTION"
                read -r USER_CLARIFICATION_RESPONSE
                current_context_for_llm="Original request: '$initial_user_prompt'. My previous question (from Planner): '$CLARIFICATION_QUESTION'. User's answer: '$USER_CLARIFICATION_RESPONSE'. Please generate a new plan based on this clarification."
                LAST_EVAL_DECISION_TYPE="PLANNER_CLARIFY" 
                CURRENT_PLAN_STR="" 
                continue 
            fi
            
            CURRENT_PLAN_STR=$(parse_llm_plan "$LLM_RESPONSE_CONTENT")
            if [ -z "$CURRENT_PLAN_STR" ]; then
                log_message "Error" "Planner did not return a plan. LLM Response: $LLM_RESPONSE_CONTENT"
                printf "${CLR_RED}Agent: I could not devise a plan. Could you please rephrase or provide more details?${CLR_RESET}\\n"
                task_status="TASK_FAILED"; break;
            fi
            log_message "Plan Agent" "[Planner Plan]:\\n$CURRENT_PLAN_STR"
            mapfile -t CURRENT_PLAN_ARRAY < <(echo "$CURRENT_PLAN_STR" | sed '/^[[:space:]]*$/d') 
            CURRENT_STEP_INDEX=0
            USER_CLARIFICATION_RESPONSE="" 
            LAST_EVAL_DECISION_TYPE="" # Clear decision type after successful planning
        fi

        # 2. ACTION PHASE
        if [ "$CURRENT_STEP_INDEX" -ge "${#CURRENT_PLAN_ARRAY[@]}" ]; then
            log_message System "All plan steps executed or no plan steps. Moving to final evaluation or completion."
            if [[ "$task_status" == "IN_PROGRESS" ]]; then
                 log_message "System" "Plan exhausted. Last evaluator decision was: $LAST_EVAL_DECISION_TYPE. Task status: $task_status"
            fi
            break 
        fi

        local current_step_detail="${CURRENT_PLAN_ARRAY[$CURRENT_STEP_INDEX]}"
        log_message System "Entering ACTION phase for step $((CURRENT_STEP_INDEX + 1))/${#CURRENT_PLAN_ARRAY[@]}: $current_step_detail"

        local actor_input_prompt="User's original request: '$initial_user_prompt'\\n\\nOverall Plan:\\n$CURRENT_PLAN_STR\\n\\nCurrent step to execute: '$current_step_detail'"
        
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
                local base_suggested_cmd=$(echo "$SUGGESTED_CMD" | awk '{print $1}')
                local execute_this_command=false

                if [[ -v ALLOWED_COMMAND_CHECK_MAP["$base_suggested_cmd"] || -n "${ALLOWED_COMMAND_CHECK_MAP[$base_suggested_cmd]-}" ]]; then
                    log_message "System" "Command '$base_suggested_cmd' from '$SUGGESTED_CMD' is allowed by existing config."
                    execute_this_command=true
                else
                    log_message "System" "Command '$base_suggested_cmd' from '$SUGGESTED_CMD' is NOT in allowed commands."
                    if [[ "$ENABLE_DYNAMIC_COMMAND_APPROVAL" == true ]]; then
                        log_message "System" "Dynamic command approval is ENABLED. Requesting user permission for '$base_suggested_cmd'."
                        prompt_for_command_permission_and_update_config "$base_suggested_cmd"
                        local permission_status=$?

                        case "$permission_status" in
                            0) # Allowed (either 'yes' or 'always' succeeded)
                                log_message "System" "Permission granted for '$base_suggested_cmd'."
                                execute_this_command=true
                                ;;
                            1) # Denied
                                log_message "System" "Permission denied for '$base_suggested_cmd'."
                                CMD_OUTPUT="Command '$base_suggested_cmd' was denied by the user for this instance."
                                CMD_STATUS=1 #  Specific code for user denial
                                LAST_ACTION_TAKEN="Command '$SUGGESTED_CMD' denied by user."
                                execute_this_command=false
                                ;;
                            2) # Cancel task
                                log_message "System" "Task cancelled by user due to command permission choice for '$base_suggested_cmd'."
                                task_status="TASK_FAILED" # This will break the main loop after this iteration's EVAL
                                CMD_OUTPUT="Task cancelled by user at command permission prompt for '$base_suggested_cmd'."
                                CMD_STATUS=125 # Arbitrary non-zero for cancellation
                                LAST_ACTION_TAKEN="Task cancelled by user over command '$SUGGESTED_CMD'."
                                execute_this_command=false
                                ;;
                        esac
                    else
                        log_message "System" "Dynamic command approval is DISABLED. Command '$base_suggested_cmd' will not be run as it's not in allowed_commands."
                        CMD_OUTPUT="Command '$base_suggested_cmd' is not in allowed_commands and dynamic approval is disabled."
                        CMD_STATUS=1 # Indicate failure/denial
                        LAST_ACTION_TAKEN="Command '$SUGGESTED_CMD' denied (not whitelisted, dynamic approval disabled)."
                        execute_this_command=false
                    fi
                fi

                if [ "$execute_this_command" == "true" ]; then
                    LAST_ACTION_TAKEN="Executed command: $SUGGESTED_CMD"
                    log_message "Command" "$SUGGESTED_CMD"
                    if [[ "$GREMLIN_MODE" == "true" ]]; then
                        log_message "System" "Executing in Gremlin Mode: $SUGGESTED_CMD - timeout: ${COMMAND_TIMEOUT}s"
                        CMD_OUTPUT=$(timeout "$COMMAND_TIMEOUT" bash -c "$SUGGESTED_CMD" 2>&1)
                        CMD_STATUS=$? 
                        log_message "System" "Output:\\n$CMD_OUTPUT"
                    else
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
                LAST_ACTION_TAKEN="Asked user (by Action Agent as per plan): $actor_question"
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
        local evaluator_input_prompt="User's original request: '$initial_user_prompt'\\n\\nOverall Plan:\\n$CURRENT_PLAN_STR\\n\\nAction Taken for step '$((CURRENT_STEP_INDEX + 1)) ($current_step_detail)':\\n$LAST_ACTION_TAKEN\\n\\nResult of Action:\\n$LAST_ACTION_RESULT"

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
                CURRENT_STEP_INDEX=$((CURRENT_STEP_INDEX + 1))
                USER_CLARIFICATION_RESPONSE="" 
                ;;
            REVISE_PLAN)
                log_message "Eval Agent" "Evaluator: REVISE_PLAN. Reason: $EVALUATOR_MESSAGE"
                current_context_for_llm="Original request: '$initial_user_prompt'. The previous plan step ('$current_step_detail') resulted in: '$LAST_ACTION_RESULT'. Evaluator suggests revision: '$EVALUATOR_MESSAGE'. Please provide a new plan."
                CURRENT_PLAN_STR="" 
                USER_CLARIFICATION_RESPONSE=""
                ;;
            CLARIFY_USER)
                CLARIFICATION_QUESTION="$EVALUATOR_MESSAGE"
                log_message "Eval Agent" "[Evaluator Clarification]: $CLARIFICATION_QUESTION"
                printf "${CLR_GREEN}Eval Agent asks: ${CLR_RESET}${CLR_BOLD_GREEN}%s${CLR_RESET} " "$CLARIFICATION_QUESTION"
                read -r USER_CLARIFICATION_RESPONSE
                current_context_for_llm="Original request: '$initial_user_prompt'. After action '$LAST_ACTION_TAKEN' (result: '$LAST_ACTION_RESULT'), evaluator needs clarification. Question asked: '$CLARIFICATION_QUESTION'. User's answer: '$USER_CLARIFICATION_RESPONSE'. Please generate a new plan or determine next step based on this clarification."
                CURRENT_PLAN_STR="" 
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

    if [ "$current_iteration" -ge "$MAX_ITERATIONS" ] && [ "$task_status" == "IN_PROGRESS" ]; then
        log_message "Error" "Task exceeded maximum iterations ($MAX_ITERATIONS). Aborting."
        task_status="TASK_FAILED"
    fi

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
