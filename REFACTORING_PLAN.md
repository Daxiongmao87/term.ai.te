# term.ai.te Refactoring Analysis & Implementation Plan

## Current Structure Analysis

### Current State (1329 lines in single file)
- **Lines 1-70**: Imports, constants, and global state
- **Lines 71-181**: Configuration templates (large YAML/JSON strings)
- **Lines 182-238**: Global dictionaries and utility functions
- **Lines 239-317**: Dependency checking and initial setup
- **Lines 318-431**: Configuration management
- **Lines 432-511**: Context management  
- **Lines 512-612**: LLM payload preparation
- **Lines 613-633**: LLM response parsing functions
- **Lines 634-795**: Command permission and configuration updates
- **Lines 796-824**: Permission prompting
- **Lines 825-1271**: Main task handling loop (447 lines!)
- **Lines 1272-1329**: Signal handling and main entry point

## Proposed Package Structure for pip Installation

```
termaite/
├── __init__.py                 # Package initialization, version
├── __main__.py                 # Entry point for `python -m termaite`
├── cli.py                      # CLI interface and argument parsing
├── constants.py                # Constants, templates, and color codes
├── config/
│   ├── __init__.py
│   ├── manager.py              # Configuration loading and validation
│   ├── templates.py            # Default config templates
│   └── setup.py                # Initial setup and file creation
├── core/
│   ├── __init__.py
│   ├── application.py          # Main application class
│   ├── task_handler.py         # Task execution orchestration
│   └── context.py              # Context management
├── agents/
│   ├── __init__.py
│   ├── base.py                 # Base agent class
│   ├── planner.py              # Planning agent
│   ├── actor.py                # Action agent
│   └── evaluator.py            # Evaluation agent
├── llm/
│   ├── __init__.py
│   ├── client.py               # LLM API communication
│   ├── payload.py              # Payload preparation
│   └── parsers.py              # Response parsing utilities
├── commands/
│   ├── __init__.py
│   ├── executor.py             # Command execution
│   ├── permissions.py          # Permission management
│   └── safety.py               # Safety checks and validation
└── utils/
    ├── __init__.py
    ├── logging.py              # Logging utilities
    ├── dependencies.py         # Dependency checking
    └── helpers.py              # General utilities
```

## Implementation Strategy

### Phase 1: Package Structure & Entry Points
1. Create package directory structure
2. Set up __init__.py and __main__.py
3. Create setup.py/pyproject.toml for pip installation
4. Move constants and templates to separate modules

### Phase 2: Configuration System
1. Extract configuration management (manager.py)
2. Move templates to dedicated module (templates.py)
3. Separate initial setup logic (setup.py)

### Phase 3: Core Application Logic
1. Create main Application class (application.py)
2. Extract task handling orchestration (task_handler.py)
3. Separate context management (context.py)

### Phase 4: Agent System
1. Create base agent abstraction (base.py)
2. Implement individual agent classes
3. Clean separation of concerns

### Phase 5: LLM Integration
1. Extract LLM client logic (client.py)
2. Separate payload preparation (payload.py)
3. Dedicated response parsing (parsers.py)

### Phase 6: Command System
1. Command execution abstraction (executor.py)
2. Permission management system (permissions.py)
3. Safety validation (safety.py)

### Phase 7: Utilities & Support
1. Logging system (logging.py)
2. Dependency checking (dependencies.py)
3. Helper functions (helpers.py)

## Key Design Principles

### 1. Single Responsibility Principle
Each module has one clear purpose:
- Config modules only handle configuration
- Agent modules only handle agent logic
- LLM modules only handle LLM communication

### 2. Dependency Injection
- Application class accepts dependencies
- Agents receive LLM client and config
- No global state except where absolutely necessary

### 3. Clean Interfaces
```python
class BaseAgent:
    def execute(self, input_data: AgentInput) -> AgentOutput:
        pass

class LLMClient:
    def request(self, payload: dict) -> LLMResponse:
        pass

class CommandExecutor:
    def execute(self, command: str, permissions: Permissions) -> CommandResult:
        pass
```

### 4. Configuration as Code
- Type-safe configuration classes
- Validation at load time
- Immutable config objects

### 5. Testability
- All components are easily mockable
- Clear interfaces for testing
- Separation of I/O from business logic

## Package Installation Structure

### pyproject.toml
```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "termaite"
dynamic = ["version"]
description = "LLM-powered shell assistant with multi-agent architecture"
authors = [{name = "Your Name", email = "your.email@example.com"}]
dependencies = [
    "PyYAML>=6.0",
    "requests>=2.25.0",
    "colorama>=0.4.4",
]
requires-python = ">=3.8"

[project.scripts]
termaite = "termaite.__main__:main"

[project.urls]
Homepage = "https://github.com/yourusername/termaite"
Repository = "https://github.com/yourusername/termaite"
```

### Entry Points
- `termaite` command line tool
- `python -m termaite` module execution
- Importable as library: `from termaite import TermAIte`

## Benefits of This Structure

1. **Maintainability**: Small, focused modules
2. **Testability**: Clear interfaces and dependency injection
3. **Extensibility**: Easy to add new agents or LLM providers
4. **Installability**: Proper Python package for pip
5. **Type Safety**: Full type hints throughout
6. **Documentation**: Each module has clear purpose
7. **Performance**: Lazy loading of heavy components

## Migration Plan

Each phase will be a separate commit, maintaining functionality throughout:

1. **Create skeleton** - Package structure with empty modules
2. **Move constants** - Extract templates and constants
3. **Extract config** - Configuration management system
4. **Create app class** - Main application orchestration
5. **Implement agents** - Agent abstraction and implementations
6. **LLM system** - Client and communication layer
7. **Command system** - Execution and permissions
8. **Utilities** - Logging and helpers
9. **Package setup** - pip installability
10. **Final cleanup** - Remove old file and polish

This approach ensures we can make the transition gradually while maintaining a working system at each step.
