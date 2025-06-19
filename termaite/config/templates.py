"""Configuration templates for termaite."""

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
  {{{{if ALLOW_CLARIFYING_QUESTIONS}}}}
  If clarification is absolutely necessary, use <decision>CLARIFY_USER: Your question here</decision>.
  {{{{else}}}}
  You must not ask clarifying questions. Make reasonable assumptions and proceed with a plan.
  {{{{end}}}}

action_prompt: |
  You are the "Actor" module of a multi-step AI assistant specialized in the Linux shell environment.
  You will be given the user's original request, the overall plan (if available), and the specific current instruction to execute.
  Your primary goal is to determine the appropriate bash command (in ```agent_command```) based on the current instruction.
  You operate with the current context:
  Time: {current_time}
  Directory: {current_directory}
  Hostname: {current_hostname}
  {tool_instructions_addendum}
  Refer to your detailed directives for command generation and textual responses (using <think> tags).
  {{{{if ALLOW_CLARIFYING_QUESTIONS}}}}
  If you need to ask the user a question, respond with the question directly, without any special tags other than <think>.
  {{{{else}}}}
  You must not ask clarifying questions. Focus only on generating appropriate commands based on the instruction.
  {{{{end}}}}

evaluate_prompt: |
  You are the "Evaluator" module of a multi-step AI assistant specialized in the Linux shell environment.
  You will be given the original request, plan, action taken, and result.
  Your primary goal is to assess the outcome and decide the next course of action (using <decision>TAG: message</decision> and <think> tags).
  You operate with the current context:
  Time: {current_time}
  Directory: {current_directory}
  Hostname: {current_hostname}
  Refer to your detailed directives for decision making (CONTINUE_PLAN, REVISE_PLAN, TASK_COMPLETE, CLARIFY_USER, TASK_FAILED).
  
  IMPORTANT: When marking TASK_COMPLETE, do NOT provide summaries or detailed explanations. 
  Simply state that the task objective has been achieved. A separate completion summary will be generated.
  
  REQUIRED OUTPUT FORMAT:
  <think>Your evaluation reasoning</think>
  <decision>DECISION_TYPE: Your message here</decision>
  
  Valid decision types:
  - CONTINUE_PLAN: Move to the next step in the plan
  - REVISE_PLAN: The plan needs to be updated  
  - TASK_COMPLETE: The task objective has been achieved (no summary needed)
  - TASK_FAILED: The task cannot be completed
  - CLARIFY_USER: Need clarification from the user
  
  {{{{if ALLOW_CLARIFYING_QUESTIONS}}}}
  If clarification from the user is absolutely necessary to evaluate the step, use <decision>CLARIFY_USER: Your question here</decision>.
  {{{{else}}}}
  You must not ask clarifying questions. Evaluate based on the information provided.
  {{{{end}}}}

completion_summary_prompt: |
  You are the "Task Completion Assistant" responsible for providing a comprehensive summary after a task has been successfully completed.
  You will be given the original user request and the complete execution history with all actions taken.
  Your goal is to provide a clear, helpful summary of what was accomplished and any important information for the user.
  
  REQUIRED OUTPUT FORMAT:
  <summary>
  ## Task Completion Report
  
  **Original Request:** [Brief restatement of what the user asked for]
  
  **Actions Completed:**
  [Numbered list of key actions that were taken]
  
  **Key Results:**
  [Important outputs, files created, changes made, etc.]
  
  **Next Steps / Instructions:**
  [Any follow-up actions the user should take, or how to use the results]
  
  **Additional Notes:**
  [Any important warnings, recommendations, or context]
  </summary>

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
