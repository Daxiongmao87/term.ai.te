# bash-agent

A command-line agent that interacts with a language model (LLM) to suggest and execute shell commands based on user prompts. The agent manages context, ensures command safety, and supports iterative workflows.

## Features
- LLM-powered command suggestions
- Context management per working directory
- Command whitelist/blacklist and gremlin mode
- Configurable via JSON files in ~/.config

## Usage
Run `bash-agent.sh` and follow the prompts. See action_plan.md for technical implementation details.

## Configuration

Create a config file at `~/.config/bash-agent/config.json` with the following structure:

```json
{
  "endpoint": "https://your-llm-endpoint/api",
  "api_key": "YOUR_API_KEY",
  "system_prompt": "You are a helpful shell assistant.",
  "whitelist": ["ls", "cat", "echo", "pwd", "cd"],
  "blacklist": ["rm", "shutdown", "reboot"],
  "gremlin_mode": false
}
```

Create a payload template at `~/.config/bash-agent/payload.json`:

```json
{
  "prompt": "<system_prompt>\nUser: <user_prompt>",
  "context": []
}
```

- `<system_prompt>` and `<user_prompt>` will be replaced automatically.
- The context array will be managed by the agent.

## Context

Context is stored per working directory in `~/.config/bash-agent/context.json` and is used to maintain conversation history.

## Exiting

- Type `exit` or press Ctrl-C to end the session.
