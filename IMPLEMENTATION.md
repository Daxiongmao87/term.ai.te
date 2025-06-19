# Implementation Documentation

This is a living document describing the current implementation of term.ai.te.

## Current Status

**WARNING**: The main implementation file `termaite.py` is currently **1328 lines**, which exceeds our 500-line guideline and is approaching the 800-line refactoring threshold. **Refactoring is required.**

## Architecture Overview

### Multi-Agent System

The application implements a three-agent architecture:

1. **Plan Agent** - Responsible for understanding user requests and creating execution plans
2. **Action Agent** - Executes individual steps and generates shell commands  
3. **Evaluation Agent** - Assesses results and determines next actions

### Core Components

#### Main Entry Point
- `main()` - Application entry point, handles CLI args and interactive mode
- `signal_handler()` - Graceful shutdown on SIGINT

#### Configuration Management
- `initial_setup()` - Creates config templates on first run
- `load_config()` - Loads and validates YAML configuration
- `get_response_path()` - Loads LLM response parsing configuration

#### LLM Integration
- `prepare_payload()` - Constructs API payloads for different agent phases
- `parse_*()` functions - Extract structured data from LLM responses
- Context management for multi-turn conversations

#### Command Execution & Safety
- Command whitelisting/blacklisting system
- `prompt_for_command_permission_and_update_config()` - Dynamic permission handling
- Timeout-based command execution with safety checks

#### Logging & Debugging
- Color-coded logging system using colorama
- Debug mode with detailed execution tracing
- Context persistence for debugging and auditing

## File Structure

```
termaite.py (1328 lines) - REQUIRES REFACTORING
├── Imports & Constants (lines 1-186)
├── Utility Functions (lines 187-238)
├── Dependency & Setup (lines 239-317)
├── Configuration Management (lines 318-431)
├── Context Management (lines 432-511)
├── LLM Integration (lines 512-633)
├── Command Permission System (lines 634-824)
├── Main Task Handler (lines 825-1271)
├── Signal Handling (lines 1272-1277)
└── Main Entry Point (lines 1278-1329)
```

## Immediate Refactoring Requirements

The current monolithic structure violates our development guidelines. Required refactoring:

### Proposed Module Structure

```
termaite/
├── __init__.py
├── main.py              # Entry point (~50 lines)
├── config/
│   ├── __init__.py
│   ├── manager.py       # Configuration management
│   └── templates.py     # Default templates
├── agents/
│   ├── __init__.py
│   ├── base.py         # Base agent class
│   ├── planner.py      # Plan Agent
│   ├── actor.py        # Action Agent
│   └── evaluator.py    # Evaluation Agent
├── llm/
│   ├── __init__.py
│   ├── client.py       # LLM API communication
│   └── parsers.py      # Response parsing
├── commands/
│   ├── __init__.py
│   ├── executor.py     # Command execution
│   └── permissions.py  # Permission management
└── utils/
    ├── __init__.py
    ├── logging.py      # Logging utilities
    └── context.py      # Context management
```

### Migration Plan

1. **Phase 1**: Extract utility functions and constants
2. **Phase 2**: Separate configuration management
3. **Phase 3**: Create agent abstractions
4. **Phase 4**: Isolate LLM integration
5. **Phase 5**: Extract command execution system
6. **Phase 6**: Final cleanup and optimization

## Current Dependencies

### Standard Library
- `os`, `sys`, `subprocess` - System integration
- `json`, `yaml` - Data serialization
- `datetime`, `time` - Timestamps
- `re` - Text processing
- `pathlib` - Path handling
- `typing` - Type hints
- `argparse` - CLI argument parsing
- `signal` - Signal handling
- `tempfile`, `shutil`, `hashlib` - File operations

### Third-party
- `PyYAML` - YAML configuration parsing
- `requests` - HTTP client for LLM APIs
- `colorama` - Cross-platform colored terminal output

## Configuration System

### Files
- `~/.config/term.ai.te/config.yaml` - Main configuration
- `~/.config/term.ai.te/payload.json` - LLM API payload template  
- `~/.config/term.ai.te/response_path_template.txt` - Response parsing
- `~/.config/term.ai.te/context.json` - Execution history

### Key Settings
- `operation_mode`: normal/gremlin/goblin security levels
- `allowed_commands`: Whitelist for normal mode
- `blacklisted_commands`: Always forbidden commands
- `command_timeout`: Execution timeout
- `enable_debug`: Verbose logging
- `allow_clarifying_questions`: Agent interaction control

## Agent Communication Protocol

### Plan Agent Input/Output
- **Input**: User request + context
- **Output**: `<checklist>` and `<instruction>` or `<decision>CLARIFY_USER</decision>`

### Action Agent Input/Output  
- **Input**: Current instruction + context
- **Output**: ````agent_command``` block or clarifying question

### Evaluation Agent Input/Output
- **Input**: Request + plan + action + result
- **Output**: `<decision>TAG: message</decision>` where TAG is:
  - `CONTINUE_PLAN` - Proceed to next step
  - `REVISE_PLAN` - Modify the plan
  - `TASK_COMPLETE` - Task finished successfully
  - `TASK_FAILED` - Task cannot be completed
  - `CLARIFY_USER` - Need user input

## Security Model

### Operation Modes
1. **Normal**: Whitelist-only, user confirmation required
2. **Gremlin**: Whitelist auto-approved, others require permission
3. **Goblin**: All commands auto-approved (dangerous)

### Permission Flow
1. Command suggested by Action Agent
2. Check against blacklist (always deny)
3. Check against whitelist (mode-dependent approval)
4. Unknown commands trigger permission prompt in gremlin mode
5. User can approve once, always, or deny

## Development Guidelines

### Code Quality
- **Maximum 500 lines per file** (guideline)
- **Mandatory refactoring at 800 lines**
- Single Responsibility Principle
- Type hints required
- Comprehensive error handling

### Testing Requirements
- Unit tests for all components
- Integration tests for agent workflows
- LLM integration tests with mock responses
- Command execution safety tests

### Documentation
- Update this document when making architectural changes
- Inline documentation for complex algorithms
- API documentation for public interfaces

## Known Issues

1. **Size**: Main file exceeds size guidelines
2. **Modularity**: Monolithic structure hampers maintainability
3. **Testing**: Limited test coverage
4. **Error Handling**: Some edge cases not fully handled
5. **Performance**: No optimization for large context histories

## Next Steps

1. **URGENT**: Refactor to modular structure
2. Implement comprehensive test suite
3. Add performance optimizations
4. Enhance error handling
5. Add plugin system for extensibility

## Changelog

### Recent Changes
- Renamed from agent-shelly/shellai to term.ai.te
- Archived obsolete bash implementation
- Updated all branding and configuration paths

### Technical Debt
- File size violation requiring immediate attention
- Need for proper module structure
- Missing test infrastructure
- Limited error recovery mechanisms
