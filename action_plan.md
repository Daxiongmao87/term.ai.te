# Technical Action Plan for Iterative Implementation of bash-agent.sh

1. Initialize Project
   - git init (if not already initialized)
   - Create .gitignore for sensitive files (e.g., config.json, context.json)
   - Create README.md with project overview

2. Implement Self-Check & Dependency Verification
   - At script start, check for required commands: jq, curl
   - Exit with error if missing

3. Dynamic Script Name & Config Handling
   - Use basename "$0" to determine script name
   - Set CONFIG_DIR="$HOME/.config/<script_name>"
   - Load config.json from CONFIG_DIR
   - Validate presence of: endpoint, API key, system prompt, whitelist, blacklist, gremlin_mode

4. Payload Template Management
   - Load payload.json from CONFIG_DIR
   - Replace <system_prompt> and <user_prompt> placeholders with actual values (use sed or jq)
   - Ensure context limit is set in payload

5. Context Management
   - Set CONTEXT_FILE in CONFIG_DIR, unique per working directory (e.g., hash of $PWD)
   - On each run, load and append to context.json
   - Maintain context as an array of message objects

6. User Interaction & Session Trapping
   - Accept user prompt as argument or via read -p
   - Trap INT (Ctrl-C) to allow clean exit
   - Loop: send prompt/context to LLM, process response, update context, repeat until task complete or user exits

7. LLM Communication
   - Use curl to POST payload to endpoint
   - Pass API key in header
   - Parse LLM response (expect JSON)
   - Extract LLM message and suggested command

8. Command Execution & Safety
   - Check suggested command against whitelist/blacklist
   - If not allowed, block and log
   - If gremlin_mode is true, execute command automatically; else, prompt user for confirmation
   - Capture command output and append to context

9. Logging & Output Formatting
   - Implement log function: echo "[$(date +'%Y-%m-%d %H:%M:%S')] [<Source>]: <content>"
   - Use [LLM], [System], [User], etc. as source tags

10. Error Handling & Edge Cases
    - Handle missing/malformed config, payload, or context files
    - Handle LLM/network errors and invalid responses
    - On error, log and prompt user to retry or exit

11. Documentation & Finalization
    - Update README.md with usage, config, and workflow
    - Add inline comments to bash-agent.sh
    - Test all features and edge cases

# Iterate on each step, testing and validating before proceeding to the next.
