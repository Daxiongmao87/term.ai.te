#!/bin/bash
# This script is designed to perform a given task in a Linux environment, providing
# environment details such as time, pwd, hostname, and system instructions.

# --- ANSI Color Codes ---
CLR_RESET=$'\033[0m'
CLR_RED=$'\033[0;31m'
CLR_GREEN=$'\033[0;32m'
CLR_YELLOW=$'\033[0;33m'
CLR_BLUE=$'\033[0;34m'
CLR_MAGENTA=$'\033[0;35m'
CLR_CYAN=$'\033[0;36m'
CLR_WHITE=$'\033[0;37m'
CLR_BOLD_WHITE=$'\033[1;37m'
CLR_BOLD_RED=$'\033[1;31m'
CLR_BOLD_YELLOW=$'\033[1;33m'
CLR_BOLD_BLUE=$'\033[1;34m'
CLR_BOLD_MAGENTA=$'\033[1;35m'
CLR_BOLD_CYAN=$'\033[1;36m'

# --- Logging Function ---
# log_message <type> <message>
# Type can be: System, User, Agent, LLM, Command, Error, Warning, Debug
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
        System)  header_color="$CLR_CYAN"; content_color="$CLR_BOLD_CYAN" ;;
        User)    header_color="$CLR_GREEN"; content_color="$CLR_BOLD_GREEN" ;;
        Agent)   header_color="$CLR_BLUE"; content_color="$CLR_BOLD_BLUE" ;;
        LLM)     header_color="$CLR_MAGENTA"; content_color="$CLR_BOLD_MAGENTA" ;;
        Command) header_color="$CLR_YELLOW"; content_color="$CLR_BOLD_YELLOW" ;;
        Error)
            header_color="$CLR_RED"; content_color="$CLR_BOLD_RED"
            numeric_fd=2 # stderr for errors
            ;;
        Warning)
            header_color="$CLR_YELLOW"; content_color="$CLR_BOLD_YELLOW"
            numeric_fd=2 # stderr for warnings
            ;;
        Debug)   header_color="$CLR_WHITE"; content_color="$CLR_BOLD_WHITE" ;;
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

# --- Configuration Variables ---
CONFIG_DIR="./config" # Changed to use local ./config directory

log_message Debug "Preparing to set CONFIG_FILE. CONFIG_DIR='${CONFIG_DIR}'"
set -x # Enable command tracing
CONFIG_FILE="$CONFIG_DIR/config.yaml"
declare PAYLOAD_FILE="$CONFIG_DIR/payload.json"
declare RESPONSE_PATH_FILE="$CONFIG_DIR/response_path_template.txt"
declare CONTEXT_FILE="$CONFIG_DIR/context.json"
declare JQ_ERROR_LOG="$CONFIG_DIR/jq_error.log"
set +x # Disable command tracing

# --- Template Definitions ---
CONFIG_TEMPLATE="# config.yaml - REQUIRED - Configure this file for your environment and LLM
# Ensure this is valid YAML.
# endpoint: The URL of your LLM API endpoint.
# api_key: Your API key, if required by the endpoint. Leave empty or comment out if not needed.
# system_prompt: The system-level instructions for the LLM.
# allowed_commands: A list of commands the LLM is permitted to suggest.
#   Each command should have a brief description.
#   Example:
#     ls: \"List directory contents.\"
#     cat: \"Display file content.\"
#     echo: \"Print text to the console.\"
# gremlin_mode: If true, executes suggested commands without confirmation. DANGEROUS!
# command_timeout: Timeout in seconds for executed commands (e.g., 10 for 10 seconds).

endpoint: \"http://localhost:11434/api/generate\" # Example for Ollama /api/generate
# endpoint: \"http://localhost:11434/api/chat\" # Example for Ollama /api/chat
# endpoint: \"https://api.openai.com/v1/chat/completions\" # Example for OpenAI

# api_key: \"YOUR_API_KEY_HERE\" # Uncomment and replace if your LLM requires an API key

system_prompt: |
  You are a helpful AI assistant running in a Linux shell environment.
  Your goal is to assist the user with their tasks by suggesting appropriate bash commands.
  Current time: $(date +'%Y-%m-%d %H:%M:%S')
  Current directory: $PWD
  Hostname: $(hostname)

  IMPORTANT:
  1. Analyze the user's request and the environment details provided.
  2. If the task requires a shell command, respond with the EXACT command to achieve the task,
     wrapped in a specific code block like this:
     \`\`\`agent_command
     <the exact bash command to run>
     \`\`\`
  3. Do NOT provide any explanations or text outside of this \`\`\`agent_command ... \`\`\` block if a command is being issued.
  4. If you need to clarify, or if the task doesn't require a command, respond with plain text.
  5. You can use the <think></think> block to write down your thoughts before the final response.
     The content of the <think> block will not be shown to the user but will be logged for debugging.
     Example:
     <think>
     The user wants to list files. The 'ls' command is appropriate.
     I should use 'ls -l' for a detailed listing.
     </think>
     \`\`\`agent_command
     ls -l
     \`\`\`
  6. Only use commands from the allowed list. If a suitable command is not available, state that you cannot perform the task.

allowed_commands:
  ls: \"List directory contents. Use common options like -l, -a, -h as needed.\"
  cat: \"Display file content. Example: cat filename.txt\"
  echo: \"Print text. Example: echo 'Hello World'\"
  grep: \"Search for patterns in files. Example: grep 'pattern' filename.txt\"
  find: \"Find files or directories. Example: find . -name '*.txt'\"
  # Add more commands and their descriptions as needed.
  # Ensure descriptions are concise and helpful.

gremlin_mode: false # Set to true to execute commands without confirmation (DANGEROUS!)
command_timeout: 30 # Default timeout for commands in seconds
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
  // IMPORTANT: The above is an EXAMPLE structure for Ollama.
  // You MUST adapt this payload.json to match the specific API requirements of YOUR LLM.
  // The '\''<system_prompt>'\'' and '\''<user_prompt>'\'' placeholders will be filled by the script.
  // Remove these comments and the '\''user_instructions'\'' key from the actual file in ~/.config/'$SCRIPT_NAME'/payload.json
  // "user_instructions": [
  //   "ACTION REQUIRED: Edit this file ($HOME/.config/$SCRIPT_NAME/payload.json) to match your LLM'\''s API.",
  //   "Replace '\''your-model-name:latest'\'' with your actual model identifier.",
  //   "Adjust/add/remove fields like '\''stream'\'', '\''options'\'', etc., as per your LLM API documentation.",
  //   "The '\''<system_prompt>'\'' and '\''<user_prompt>'\'' placeholders are automatically filled by the script.",
  //   "After configuring, delete this '\''user_instructions'\'' key and its content."
  // ]
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
# Validate required config fields using yq
REQUIRED_CONFIG_FIELDS=(endpoint system_prompt allowed_commands gremlin_mode command_timeout) # api_key is optional
for field in "${REQUIRED_CONFIG_FIELDS[@]}"; do
    if ! cat "$CONFIG_FILE" | yq ".$field" >/dev/null 2>&1; then
        log_message "Error" "Missing or invalid config field '$field' in $CONFIG_FILE."
        log_message "Error" "Field value found: '$(cat "$CONFIG_FILE" | yq ".$field" 2>&1)'"
        exit 1
    fi
done

# Helper to read YAML fields (raw output, no quotes)
get_yaml_field() { cat "$CONFIG_FILE" | yq -r "$1"; }

ENDPOINT=$(get_yaml_field '.endpoint')
API_KEY=$(get_yaml_field '.api_key') # Can be empty
SYSTEM_PROMPT=$(get_yaml_field '.system_prompt')

# Load allowed_commands into an associative array for key checking
declare -A ALLOWED_COMMAND_CHECK_MAP
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

GREMLIN_MODE=$(get_yaml_field '.gremlin_mode')
COMMAND_TIMEOUT=$(get_yaml_field '.command_timeout // 10') # Default to 10 if not set

# Read the first non-comment, non-empty line from RESPONSE_PATH_FILE
RESPONSE_PATH=$(grep -vE '^\s*#|^\s*$' "$RESPONSE_PATH_FILE" | head -n 1 | tr -d '[:space:]')

set -x # Enable command tracing before the problematic log_message
if [ -z "$RESPONSE_PATH" ]; then
    log_message "Error" "TEST ERROR: RESPONSE_PATH is empty. Problem in file: $RESPONSE_PATH_FILE"
    exit 1
fi
set +x # Disable command tracing

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

    if [ $jq_status -ne 0 ]; then # Check only jq's exit status for critical failure
        log_message "Error" "jq failed to update $CONTEXT_FILE. JQ exit status: $jq_status."
        log_message "Error" "JQ error messages logged to: $JQ_ERROR_LOG"
        rm -f "$tmp_file"
        return 1
    elif [ -z "$jq_command_output" ]; then # jq succeeded but produced no output
         log_message Warning "jq produced empty output while updating $CONTEXT_FILE. This might indicate an issue with the context structure or the jq filter."
         log_message Warning "JQ error messages logged to: $JQ_ERROR_LOG"
         # Attempt to re-initialize if this happens, as it's unexpected.
         local backup_file="${CONTEXT_FILE}.empty_jq_output.$(date +'%Y%m%d%H%M%S')"
         mv "$CONTEXT_FILE" "$backup_file"
         echo "{}" | jq --arg hash "$PWD_HASH" --argjson entry "$context_entry_json" '. + {($hash): [$entry]}' > "$tmp_file"
         if [ $? -ne 0 ]; then # Check status of the re-initialization attempt
            log_message "Error" "Error re-initializing context after empty jq output. Context not saved."
            rm -f "$tmp_file"
            return 1
         fi
    else
        # jq command was successful and produced output
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
    local user_prompt="$1"
    local config_system_prompt="$SYSTEM_PROMPT" # SYSTEM_PROMPT is global, loaded from config

    local allowed_commands_yaml_block
    local yq_yaml_stderr_file=$(mktemp)
    # Get the .allowed_commands as a YAML block string
    allowed_commands_yaml_block=$(cat "$CONFIG_FILE" | yq '.allowed_commands' 2> "$yq_yaml_stderr_file")
    local yq_yaml_status=$?
    
    local tool_instructions_addendum=""
    if [ $yq_yaml_status -eq 0 ] && [ -n "$allowed_commands_yaml_block" ] && [ "$allowed_commands_yaml_block" != "null" ]; then
        tool_instructions_addendum="You are permitted to use the following commands. Their names and descriptions are provided below in YAML format. Adhere to these commands and their specified uses:\n\n\`\`\`yaml\n${allowed_commands_yaml_block}\n\`\`\`\n\n"
    else
        log_message Warning "Could not fetch or format allowed_commands YAML block for LLM instructions."
        if [ -s "$yq_yaml_stderr_file" ]; then
            log_message Warning "yq stderr (allowed_commands YAML): $(cat "$yq_yaml_stderr_file")"
        fi
    fi
    rm -f "$yq_yaml_stderr_file"

    local final_system_prompt="${tool_instructions_addendum}${config_system_prompt}"

    # Ensure payload.json is valid JSON before processing. User must fix this manually.
    if ! jq -e . "$PAYLOAD_FILE" > /dev/null 2>&1; then
        log_message "Error" "$PAYLOAD_FILE is not valid JSON. Please fix it manually - remove comments, ensure correct syntax."
        return 1 # Indicate failure
    fi

    # Substitute placeholders in the payload template
    jq --arg sys "$final_system_prompt" --arg user "$user_prompt" \
        'walk(if type == "string" then
            gsub("<system_prompt>"; $sys) | gsub("<user_prompt>"; $user)
        else . end)' "$PAYLOAD_FILE"
    return $? # Return jq's exit status
}

# --- Command Parsing ---
parse_suggested_command() {
    # Extracts the first bash command from a ```agent_command code block within the input string
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

# --- Task Handling ---
handle_task() {
    local task_prompt="$1"
    local timestamp_for_task
    timestamp_for_task=$(date +'%Y-%m-%d %H:%M:%S')
    # Use log_message for user task
    log_message User "Processing task: $task_prompt"

    # Prepare payload
    PAYLOAD=$(prepare_payload "$task_prompt")
    if [ $? -ne 0 ]; then # Check if prepare_payload indicated an error (e.g., invalid PAYLOAD_FILE)
        # Error message already printed by prepare_payload
        return 1
    fi

    local curl_cmd_array=("curl" "-s" "-X" "POST" "$ENDPOINT")
    curl_cmd_array+=("-H" "Content-Type: application/json")

    # Conditionally add Authorization header
    if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ] && [ "$API_KEY" != "YOUR_API_KEY_HERE" ]; then
        curl_cmd_array+=("-H" "Authorization: Bearer $API_KEY")
    fi

    curl_cmd_array+=("-d" "$PAYLOAD")

    # Query LLM endpoint
    log_message Debug "Attempting to query LLM endpoint: $ENDPOINT"
    set -x # Enable command tracing to see the exact curl command
    RESPONSE=$("${curl_cmd_array[@]}")
    set +x # Disable command tracing

    local llm_response_timestamp
    llm_response_timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    if [[ -z "$RESPONSE" || "$RESPONSE" == "null" ]]; then
        log_message "LLM" "Error: No response or null response from LLM endpoint."
        # Attempt to log context even with empty/null LLM response
        append_context "$task_prompt" "{\"error\": \"No response or null response from LLM endpoint at $llm_response_timestamp\"}"
        return 1 # Indicate error
    fi

    LLM_MESSAGE_CONTENT=$(echo "$RESPONSE" | jq -r "$RESPONSE_PATH")

    if [ $? -ne 0 ] || [ "$LLM_MESSAGE_CONTENT" == "null" ] || [ -z "$LLM_MESSAGE_CONTENT" ]; then
        log_message "LLM" "Error: Failed to extract message content from LLM response using JQ path '$RESPONSE_PATH'."
        log_message "LLM" "Raw Response was: $RESPONSE" # Print raw response for debugging this specific error
        append_context "$task_prompt" "$RESPONSE" # Log the full raw response
        return 1
    fi

    LLM_THOUGHT=$(parse_llm_thought "$LLM_MESSAGE_CONTENT")
    if [ -n "$LLM_THOUGHT" ]; then
        # log_message will handle multi-line thoughts with hanging indents
        log_message "Agent" "$LLM_THOUGHT"
    fi

    SUGGESTED_CMD=$(parse_suggested_command "$LLM_MESSAGE_CONTENT")

    if [[ -n "$SUGGESTED_CMD" ]]; then
        # Extract the base command from the suggested command string - e.g., 'ls' from 'ls -l /tmp'
        local base_suggested_cmd
        base_suggested_cmd=$(echo "$SUGGESTED_CMD" | awk '{print $1}')

        # Check if the base command is in ALLOWED_COMMAND_CHECK_MAP - keys of the associative array
        if [[ -v ALLOWED_COMMAND_CHECK_MAP["$base_suggested_cmd"] ]]; then # -v checks if key exists in bash 4.3+
            local msg_allowed
            printf -v msg_allowed "Command '%s' from '%s' is allowed." "$base_suggested_cmd" "$SUGGESTED_CMD"
            log_message "System" "$msg_allowed"
            log_message "Command" "$SUGGESTED_CMD" # Log the command only if it's allowed
        else
            # Fallback for bash < 4.3 or if -v is not behaving as expected - though it should for existing keys
            if [ -n "${ALLOWED_COMMAND_CHECK_MAP[$base_suggested_cmd]-}" ]; then # The '-' ensures it doesn't error on unbound variable if key truly doesn't exist
                 local msg_allowed_fallback
                 printf -v msg_allowed_fallback "Command '%s' from '%s' is allowed - fallback check." "$base_suggested_cmd" "$SUGGESTED_CMD"
                 log_message "System" "$msg_allowed_fallback"
                 log_message "Command" "$SUGGESTED_CMD" # Log the command only if it's allowed - fallback check
            else
                local msg_not_allowed
                printf -v msg_not_allowed "Command '%s' from '%s' is NOT in the list of allowed commands. Aborting." "$base_suggested_cmd" "$SUGGESTED_CMD"
                log_message "System" "$msg_not_allowed"
                log_message "System" "Allowed commands are: ${!ALLOWED_COMMAND_CHECK_MAP[*]}"
                append_context "$task_prompt" "$RESPONSE"
                log_message "Agent" "Task aborted because the command is not allowed."
                return 1
            fi
        fi
        
        CMD_STATUS=0 # Initialize CMD_STATUS
        if [[ "$GREMLIN_MODE" == "true" ]]; then
            log_message "System" "Executing in Gremlin Mode: $SUGGESTED_CMD - timeout: ${COMMAND_TIMEOUT}s"
            # Pipe output through log_message
            timeout "$COMMAND_TIMEOUT" bash -c "$SUGGESTED_CMD" 2>&1 | while IFS= read -r line; do log_message "System" "$line"; done
            CMD_STATUS=${PIPESTATUS[0]}
        else
            local confirm_timestamp_display
            confirm_timestamp_display=$(date +'%Y-%m-%d %H:%M:%S')
            # Use printf for the prompt part to avoid issues with read -p and complex strings/colors
            # Header: Dark Green. Question Text: Light Green. Command: Light Yellow. [y/N]: Light Green.
            printf "${CLR_GREEN}[%s] [User]:${CLR_RESET}${CLR_BOLD_GREEN} Execute suggested command? ${CLR_RESET}'${CLR_BOLD_YELLOW}%s${CLR_RESET}'${CLR_BOLD_GREEN} [y/N]: ${CLR_RESET}" "$confirm_timestamp_display" "$SUGGESTED_CMD"
            read -r CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                log_message "System" "Executing: $SUGGESTED_CMD - timeout: ${COMMAND_TIMEOUT}s"
                # Pipe output through log_message
                timeout "$COMMAND_TIMEOUT" bash -c "$SUGGESTED_CMD" 2>&1 | while IFS= read -r line; do log_message "System" "$line"; done
                CMD_STATUS=${PIPESTATUS[0]}
            else
                log_message User "Command execution cancelled."
                CMD_STATUS=1 # Treat cancellation as a failure for task status
            fi
        fi

        if [[ $CMD_STATUS -eq 0 ]]; then
            log_message Agent "Command executed successfully. Task complete."
        else
            log_message Agent "Command failed or was cancelled. Exit code: $CMD_STATUS. Please review output."
        fi
    else
        log_message Agent "No command suggested by LLM."
    fi

    append_context "$task_prompt" "$RESPONSE" # Log the original full LLM response
    return $CMD_STATUS # Return command status, or 0 if no command, 1 if other error
}

# --- Main Loop ---
trap 'log_message "System" "Session terminated by user - Ctrl-C."; exit 0' INT

if [ "$#" -gt 0 ]; then
    USER_PROMPT_ARGS="$*"
    handle_task "$USER_PROMPT_ARGS"
else
    while true; do
        # Use printf for the prompt part to avoid issues with read -p and complex strings/colors
        # Prompt text: Dark Green
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
