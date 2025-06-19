# Task Strategy: Continue Refactoring termaite.py

## Objective
Continue refactoring the 1328-line termaite.py into a modular, pip-installable package following the established structure in /home/patrick/Projects/term.ai.te/termaite/.

## Current State Analysis
- ✅ Package structure created with __init__.py files
- ✅ Constants and templates extracted to termaite/constants.py and termaite/config/templates.py
- ✅ Logging utilities implemented in termaite/utils/logging.py
- ✅ CLI entry point created in termaite/cli.py
- ✅ Configuration manager stubbed in termaite/config/manager.py
- ✅ Application and task handler stubs created
- ❌ Main application logic still in monolithic termaite.py (1328 lines)

## Next Steps (Priority Order)

### Phase 1: Extract Core Functions from termaite.py
1. **Extract utility functions** to termaite/utils/helpers.py:
   - get_current_timestamp()
   - log_message()
   - check_dependencies()
   - Various path and string manipulation functions

2. **Extract LLM integration** to termaite/llm/:
   - client.py: HTTP communication with LLM APIs
   - payload.py: Payload preparation functions
   - parsers.py: Response parsing and jq-equivalent functions

3. **Extract command execution** to termaite/commands/:
   - executor.py: Command execution with timeout
   - permissions.py: Allowlist/blacklist management
   - safety.py: Command safety validation

### Phase 2: Implement Core Application Logic
4. **Complete configuration manager** in termaite/config/manager.py:
   - Move configuration loading/validation from termaite.py
   - Implement setup functions for initial config creation

5. **Implement task handler** in termaite/core/task_handler.py:
   - Extract the main agent loop (Plan-Act-Evaluate)
   - Context management functions
   - Task orchestration logic

6. **Complete main application** in termaite/core/application.py:
   - Main entry point logic
   - Signal handling
   - Application lifecycle management

### Phase 3: Extract Agent System
7. **Create agent base class** in termaite/agents/base.py
8. **Implement specific agents** in termaite/agents/:
   - planner.py: Planning agent logic
   - actor.py: Action agent logic  
   - evaluator.py: Evaluation agent logic

### Phase 4: Finalize and Test
9. **Update CLI integration** to use new modules
10. **Test pip installation** and functionality
11. **Update documentation** to reflect new structure

## Files to Modify/Create

### New Files to Create:
- termaite/utils/helpers.py
- termaite/llm/client.py
- termaite/llm/payload.py
- termaite/llm/parsers.py
- termaite/commands/executor.py
- termaite/commands/permissions.py
- termaite/commands/safety.py
- termaite/agents/base.py
- termaite/agents/planner.py
- termaite/agents/actor.py
- termaite/agents/evaluator.py
- termaite/core/context.py

### Files to Complete:
- termaite/config/manager.py (extract config logic)
- termaite/core/task_handler.py (extract main loop)
- termaite/core/application.py (extract main entry point)
- termaite/cli.py (integrate with new modules)

### Files to Update:
- termaite/__init__.py (add new exports)
- pyproject.toml (ensure all dependencies)

## Success Criteria
- termaite.py reduced to <100 lines or completely removed
- All functionality preserved in modular structure
- pip install works: `pip install -e .`
- CLI works: `termaite --help` and `python -m termaite --help`
- All modules follow <500 line limit
- Comprehensive testing of core functionality

## Implementation Order
Start with Phase 1, Step 1 (extract utility functions) as it has the least dependencies and will immediately reduce termaite.py size.
