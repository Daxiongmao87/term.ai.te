# term.ai.te

**term.ai.te** is an LLM-powered shell assistant that provides intelligent command-line automation through a multi-agent architecture. It uses Large Language Models to understand natural language requests and execute shell commands safely and efficiently.

## Features

- **Multi-Agent Architecture**: Separate Planning, Action, and Evaluation agents for robust task execution
- **Safety Controls**: Configurable command whitelisting, blacklisting, and operation modes
- **LLM Integration**: Works with any OpenAI-compatible API (Ollama, OpenAI, etc.)
- **Interactive & Batch Modes**: Can be used interactively or with command-line arguments
- **Context Awareness**: Maintains context of previous actions for complex multi-step tasks
- **Flexible Configuration**: YAML-based configuration with customizable prompts and settings

## Architecture

The system employs a three-agent approach:

1. **Plan Agent**: Analyzes user requests and creates step-by-step execution plans
2. **Action Agent**: Executes individual steps and generates appropriate shell commands
3. **Evaluation Agent**: Assesses results and determines next actions (continue, revise, complete, fail)

## Installation

### Prerequisites

- Python 3.8+
- An LLM API endpoint (e.g., Ollama running locally)

### Quick Install (Recommended)

```bash
pip install termaite
```

### Development Install

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd term.ai.te
   ```

2. **Install in development mode:**
   ```bash
   pip install -e .
   ```

### First Run Setup

1. **Initial run (generates configuration templates):**
   ```bash
   termaite --config-summary
   ```

2. **Configure your LLM endpoint:**
   Edit `~/.config/term.ai.te/config.yaml` and set your LLM endpoint and other preferences.

3. **Configure payload template:**
   Edit `~/.config/term.ai.te/payload.json` to match your LLM's API format.

4. **Configure response parsing:**
   Edit `~/.config/term.ai.te/response_path_template.txt` with the jq path to extract responses from your LLM's output.

## Usage

### Interactive Mode

```bash
termaite
```

The assistant will prompt you for tasks and execute them step by step.

### Command Line Mode

```bash
termaite "list all python files in the current directory"
termaite "create a backup of my documents folder"
termaite --debug "find all large files over 100MB"
```

### Help and Options

```bash
termaite --help           # Show all available options
termaite --version        # Show version information
termaite --config-summary # Display current configuration
termaite --debug          # Enable debug logging
```

### Operation Modes

- **normal**: Whitelisted commands require confirmation; non-whitelisted commands are rejected
- **gremlin**: Whitelisted commands run without confirmation; non-whitelisted commands prompt for approval
- **goblin**: All commands run without confirmation ⚠️ **USE WITH EXTREME CAUTION**

## Configuration

The main configuration file is located at `~/.config/term.ai.te/config.yaml`:

```yaml
# LLM endpoint configuration
endpoint: "http://localhost:11434/api/generate"
# api_key: "your-api-key-here"

# Operation mode: normal, gremlin, or goblin
operation_mode: normal

# Command timeout in seconds
command_timeout: 30

# Enable debug output
enable_debug: false

# Allow agents to ask clarifying questions
allow_clarifying_questions: true

# Allowed commands (normal mode)
allowed_commands:
  ls: "List directory contents"
  cat: "Display file content"
  echo: "Print text to console"
  # Add more as needed

# Commands that are never allowed
blacklisted_commands:
  - "rm -rf /"
  - "sudo rm"
```

## Examples

### Basic File Operations
```bash
python3 termaite.py "show me all log files modified in the last 24 hours"
```

### Complex Tasks
```bash
python3 termaite.py "create a Python script that backs up all .txt files to a dated folder"
```

### System Administration
```bash
python3 termaite.py "check disk usage and show the largest directories"
```

## Safety Features

- **Command Whitelisting**: Only approved commands can be executed in normal mode
- **Command Blacklisting**: Dangerous commands are explicitly forbidden
- **User Confirmation**: Commands can require user approval before execution
- **Timeout Protection**: Commands are automatically terminated after a configurable timeout
- **Context Logging**: All interactions are logged for debugging and auditing

## Files and Directories

- `termaite.py` - Main Python implementation
- `archive/` - Contains obsolete bash implementation for reference
- `~/.config/term.ai.te/` - Configuration directory
  - `config.yaml` - Main configuration file
  - `payload.json` - LLM API payload template
  - `response_path_template.txt` - Response parsing configuration
  - `context.json` - Execution context and history

## Development

See [IMPLEMENTATION.md](IMPLEMENTATION.md) for detailed implementation notes and development guidelines.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes following the development guidelines in [IMPLEMENTATION.md](IMPLEMENTATION.md)
4. Submit a pull request

## License

[Add your license information here]

## Support

[Add support information here - GitHub issues, contact info, etc.]
