#!/bin/bash
# This script is designed to perform a given task in a Linux environment, providing
# environment details such as time, pwd, hostname, and system instructions.

# --- Dependency Check ---
for cmd in jq curl yq mktemp timeout awk sha256sum sed grep head cut; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: Required command '$cmd' is not installed. Exiting." >&2
        exit 1
    fi
    if [ "$cmd" = "yq" ]; then
        # Specifically check for mikefarah/yq
        if ! yq --version 2>&1 | grep -q 'https://github.com/mikefarah/yq'; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: Go-based yq (https://github.com/mikefarah/yq) is required." >&2
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: You may have a different yq installed (e.g., Python yq)." >&2
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Please install the Go version (e.g., 'sudo snap install yq' or see https://github.com/mikefarah/yq)." >&2
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
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: jq version 1.6 or higher is required for certain JSON operations (like gsub). You have $JQ_VERSION." >&2
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Please upgrade jq (e.g., sudo apt install --only-upgrade jq or check your package manager)." >&2
            exit 1
        fi
    fi
done

# --- Tool Call Instructions for LLM ---
TOOL_CALL_INSTRUCTIONS="IMPORTANT: You are a shell assistant. To perform any task that requires executing a shell command, you MUST respond by providing ONLY the exact bash command(s) to be run, wrapped in a specific code block like this:

\`\`\`agent_command
<the exact bash command to run>
\`\`\`

Do NOT provide explanations before or after this block. Do NOT output the expected result of the command. Only output the command itself in this format. This is the ONLY way commands will be executed."

# --- Configuration Variables ---
SCRIPT_NAME=$(basename "$0" .sh)
CONFIG_DIR="$HOME/.config/$SCRIPT_NAME"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
PAYLOAD_FILE="$CONFIG_DIR/payload.json"
RESPONSE_PATH_FILE="$CONFIG_DIR/response_path_template.txt"
CONTEXT_FILE="$CONFIG_DIR/context.json"
JQ_ERROR_LOG="$CONFIG_DIR/jq_error.log" # File to log specific jq errors for context handling

# --- Template Definitions ---
CONFIG_TEMPLATE="# config.yaml - REQUIRED
# The endpoint for your LLM API (e.g., http://localhost:11434/api/generate for Ollama)
endpoint: \"http://localhost:11434/api/generate\"
# Your API key (if required, leave empty if not, e.g., for local Ollama)
api_key: \"\"
# The system prompt for the LLM.
system_prompt: |
  You are a helpful shell assistant.
  You can answer questions and suggest commands.
  Please be verbose and safe.
  When you want to suggest a bash command for the user to run, always wrap it in a code block like this:
  \`\`\`agent_command
  <the bash command>
  \`\`\`
  Never use any other format for commands. Only use this format for commands you want the agent to execute.
# List of allowed commands (whitelist). Only the command itself, not arguments.
whitelist:
  - ls
  - cat
  - echo
  - pwd
  - cd
  - mkdir
  - touch
  - head
  - tail
  - grep
  - find
# List of forbidden commands (blacklist).
blacklist:
  - rm
  - shutdown
  - reboot
  - sudo # Example: prevent sudo usage
# If true, commands are executed automatically. If false, user confirmation is required.
gremlin_mode: false
# Timeout for command execution (in seconds)
command_timeout: 10
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
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Generated config template: $CONFIG_FILE"
    MISSING_SETUP_FILE=1
fi
if [ ! -f "$PAYLOAD_FILE" ]; then
    echo "$PAYLOAD_TEMPLATE" > "$PAYLOAD_FILE" # Will contain comments initially
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Generated payload template: $PAYLOAD_FILE"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: IMPORTANT: Review and edit $PAYLOAD_FILE to be valid JSON matching your LLM API, then remove comments."
    MISSING_SETUP_FILE=1
fi
if [ ! -f "$RESPONSE_PATH_FILE" ]; then
    echo "$RESPONSE_PATH_TEMPLATE" > "$RESPONSE_PATH_FILE"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Generated response path template: $RESPONSE_PATH_FILE"
    MISSING_SETUP_FILE=1
fi
if [ $MISSING_SETUP_FILE -eq 1 ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: One or more configuration templates were generated in $CONFIG_DIR."
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Please review and configure them before running $SCRIPT_NAME again."
    exit 1
fi

# --- Load Configuration ---
# Validate required config fields using yq
REQUIRED_CONFIG_FIELDS=(endpoint system_prompt whitelist blacklist gremlin_mode command_timeout) # api_key is optional
for field in "${REQUIRED_CONFIG_FIELDS[@]}"; do
    if ! cat "$CONFIG_FILE" | yq ".$field" >/dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: Missing or invalid config field '$field' in $CONFIG_FILE." >&2
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Field value found: '$(cat "$CONFIG_FILE" | yq ".$field" 2>&1)'" >&2
        exit 1
    fi
done

# Helper to read YAML fields (raw output, no quotes)
get_yaml_field() { cat "$CONFIG_FILE" | yq -r "$1"; }
# Helper to read YAML lists into a bash array
get_yaml_list_as_array() {
    local field_path="$1"
    local arr=()
    mapfile -t arr < <(cat "$CONFIG_FILE" | yq -r "${field_path}[]") # e.g., .whitelist[]
    echo "${arr[@]}"
}

ENDPOINT=$(get_yaml_field '.endpoint')
API_KEY=$(get_yaml_field '.api_key') # Can be empty
SYSTEM_PROMPT=$(get_yaml_field '.system_prompt')
WHITELIST=( $(get_yaml_list_as_array '.whitelist[]') )
BLACKLIST=( $(get_yaml_list_as_array '.blacklist[]') )
GREMLIN_MODE=$(get_yaml_field '.gremlin_mode')
COMMAND_TIMEOUT=$(get_yaml_field '.command_timeout // 10') # Default to 10 if not set

# Read the first non-comment, non-empty line from RESPONSE_PATH_FILE
RESPONSE_PATH=$(grep -vE '^\s*#|^\s*$' "$RESPONSE_PATH_FILE" | head -n 1 | tr -d '[:space:]')
if [ -z "$RESPONSE_PATH" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: No valid JQ path found in $RESPONSE_PATH_FILE. It must contain a non-comment, non-empty line with the JQ path (e.g., .response)." >&2
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
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: mktemp failed to create a temporary file. Cannot save context." >&2
      [ -n "$tmp_file" ] && rm -f "$tmp_file"
      return 1
    fi

    # Ensure the context file exists and is a valid JSON object before trying to merge
    if [ ! -f "$CONTEXT_FILE" ]; then
        echo "{}" > "$CONTEXT_FILE" # Initialize with an empty JSON object if it doesn't exist
    else
        # Check if the existing context file is valid JSON, if not, initialize it
        if ! jq -e . "$CONTEXT_FILE" > /dev/null 2>&1; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Warning: $CONTEXT_FILE was not valid JSON. Initializing a new one." >&2
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
        local current_ts_log
        current_ts_log=$(date +'%Y-%m-%d %H:%M:%S')
        echo "[$current_ts_log] [System]: Error: jq failed to update $CONTEXT_FILE. JQ exit status: $jq_status." >&2
        echo "[$current_ts_log] [System]: JQ error messages (if any) logged to: $JQ_ERROR_LOG" >&2
        rm -f "$tmp_file"
        return 1
    elif [ -z "$jq_command_output" ]; then # jq succeeded but produced no output
         local current_ts_log
         current_ts_log=$(date +'%Y-%m-%d %H:%M:%S')
         echo "[$current_ts_log] [System]: Warning: jq produced empty output while updating $CONTEXT_FILE. This might indicate an issue with the context structure or the jq filter." >&2
         echo "[$current_ts_log] [System]: JQ error messages (if any) logged to: $JQ_ERROR_LOG" >&2
         # Attempt to re-initialize if this happens, as it's unexpected.
         local backup_file="${CONTEXT_FILE}.empty_jq_output.$(date +'%Y%m%d%H%M%S')"
         mv "$CONTEXT_FILE" "$backup_file"
         echo "{}" | jq --arg hash "$PWD_HASH" --argjson entry "$context_entry_json" '. + {($hash): [$entry]}' > "$tmp_file"
         if [ $? -ne 0 ]; then # Check status of the re-initialization attempt
            echo "[$current_ts_log] [System]: Error re-initializing context after empty jq output. Context not saved." >&2
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
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: Temporary context file was empty. Context not saved." >&2
        rm -f "$tmp_file"
        return 1
    fi
    return 0
}

# --- Payload Preparation ---
prepare_payload() {
    local user_prompt="$1"
    # Prepend TOOL_CALL_INSTRUCTIONS to the system prompt from config.yaml
    local final_system_prompt="$TOOL_CALL_INSTRUCTIONS"$'\n'"$SYSTEM_PROMPT"

    # Ensure payload.json is valid JSON before processing. User must fix this manually.
    if ! jq -e . "$PAYLOAD_FILE" > /dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Error: $PAYLOAD_FILE is not valid JSON. Please fix it manually (remove comments, ensure correct syntax)." >&2
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
    echo "[$timestamp_for_task] [User]: Processing task: $task_prompt"

    # Prepare payload
    PAYLOAD=$(prepare_payload "$task_prompt")
    if [ $? -ne 0 ]; then # Check if prepare_payload indicated an error (e.g., invalid PAYLOAD_FILE)
        # Error message already printed by prepare_payload
        return 1
    fi

    # Query LLM endpoint
    RESPONSE=$(curl -s -X POST "$ENDPOINT" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    local llm_response_timestamp
    llm_response_timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    if [[ -z "$RESPONSE" || "$RESPONSE" == "null" ]]; then
        echo "[$llm_response_timestamp] [LLM]: Error: No response or null response from LLM endpoint."
        # Attempt to log context even with empty/null LLM response
        append_context "$task_prompt" "{\"error\": \"No response or null response from LLM endpoint at $llm_response_timestamp\"}"
        return 1 # Indicate error
    fi

    LLM_MESSAGE_CONTENT=$(echo "$RESPONSE" | jq -r "$RESPONSE_PATH")

    if [ $? -ne 0 ] || [ "$LLM_MESSAGE_CONTENT" == "null" ] || [ -z "$LLM_MESSAGE_CONTENT" ]; then
        echo "[$llm_response_timestamp] [LLM]: Error: Failed to extract message content from LLM response using JQ path '$RESPONSE_PATH'." >&2
        echo "[$llm_response_timestamp] [LLM]: Raw Response was: $RESPONSE" # Print raw response for debugging this specific error
        append_context "$task_prompt" "$RESPONSE" # Log the full raw response
        return 1
    fi

    LLM_THOUGHT=$(parse_llm_thought "$LLM_MESSAGE_CONTENT")
    if [ -n "$LLM_THOUGHT" ]; then
        echo "$LLM_THOUGHT" | while IFS= read -r line; do
            if [ -n "$line" ]; then # Avoid printing empty lines if thought parsing results in them
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [Agent]: $line"
            fi
        done
    fi

    SUGGESTED_CMD=$(parse_suggested_command "$LLM_MESSAGE_CONTENT")

    if [[ -n "$SUGGESTED_CMD" ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [Command]: $SUGGESTED_CMD"
        
        local blacklisted_cmd=0
        # Check blacklist
        for bad in "${BLACKLIST[@]}"; do
            if [[ "$SUGGESTED_CMD" == *"$bad"* ]]; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Command '$SUGGESTED_CMD' contains blacklisted term '$bad'. Aborting."
                blacklisted_cmd=1
                break
            fi
        done
        if [ "$blacklisted_cmd" -eq 1 ]; then
            append_context "$task_prompt" "$RESPONSE"
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [Agent]: Task aborted due to blacklist."
            return 1 
        fi

        local whitelisted_cmd=0
        if [ ${#WHITELIST[@]} -gt 0 ]; then # Only check whitelist if it has entries
            for good in "${WHITELIST[@]}"; do
                # Check if the command starts with a whitelisted term followed by a space or end of string
                if [[ "$SUGGESTED_CMD" == "$good "* || "$SUGGESTED_CMD" == "$good" ]]; then
                    whitelisted_cmd=1
                    break
                fi
            done
            if [ "$whitelisted_cmd" -eq 0 ]; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Command '$SUGGESTED_CMD' is not in whitelist or does not match expected format. Aborting."
                append_context "$task_prompt" "$RESPONSE"
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [Agent]: Task aborted due to whitelist."
                return 1
            fi
        else
            whitelisted_cmd=1 # If whitelist is empty, all commands are allowed (subject to blacklist)
        fi
        
        CMD_STATUS=0 # Initialize CMD_STATUS
        if [[ "$GREMLIN_MODE" == "true" ]]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Executing (Gremlin Mode): $SUGGESTED_CMD (timeout: ${COMMAND_TIMEOUT}s)"
            timeout "$COMMAND_TIMEOUT" bash -c "$SUGGESTED_CMD" 2>&1 | while IFS= read -r line; do echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: $line"; done
            CMD_STATUS=${PIPESTATUS[0]}
        else
            local confirm_timestamp=$(date +'%Y-%m-%d %H:%M:%S')
            read -rp "[$confirm_timestamp] [User]: Execute suggested command? '$SUGGESTED_CMD' [y/N]: " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Executing: $SUGGESTED_CMD (timeout: ${COMMAND_TIMEOUT}s)"
                timeout "$COMMAND_TIMEOUT" bash -c "$SUGGESTED_CMD" 2>&1 | while IFS= read -r line; do echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: $line"; done
                CMD_STATUS=${PIPESTATUS[0]}
            else
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [User]: Command execution cancelled."
                CMD_STATUS=1 # Treat cancellation as a failure for task status
            fi
        fi

        if [[ $CMD_STATUS -eq 0 ]]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [Agent]: Command executed successfully. Task complete."
        else
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [Agent]: Command failed or was cancelled. Exit code: $CMD_STATUS. Please review output."
        fi
    else
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [Agent]: No command suggested by LLM."
    fi

    append_context "$task_prompt" "$RESPONSE" # Log the original full LLM response
    return $CMD_STATUS # Return command status, or 0 if no command, 1 if other error
}

# --- Main Loop ---
trap 'echo "[$(date +"%Y-%m-%d %H:%M:%S")] [System]: Session terminated by user (Ctrl-C)."; exit 0' INT

if [ "$#" -gt 0 ]; then
    USER_PROMPT_ARGS="$*"
    handle_task "$USER_PROMPT_ARGS"
else
    while true; do
        read -rp "Enter your task (or 'exit' to quit): " USER_PROMPT_LOOP
        if [[ "$USER_PROMPT_LOOP" == "exit" ]]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [User]: Exiting session."
            break
        fi
        handle_task "$USER_PROMPT_LOOP"
    done
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [System]: Bash Agent finished."
