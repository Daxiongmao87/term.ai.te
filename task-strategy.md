# Task Strategy: Implement Simple Response Mode as Default

## User Request Summary
The user wants to change termaite's default behavior from agentic mode (Plan-Act-Evaluate loop) to a simple response mode that:
1. Only responds to prompts with messages and optionally commands when requested
2. Requires explicit `-a` (agentic mode) or `-t` (task) flags to enable the full multi-agent architecture
3. Examples:
   - `termaite 'take me to my home directory'` → Should respond with message + command
   - `termaite 'whats the best programming language'` → Should respond with just message (no command)

## Current State Analysis
- Currently, termaite defaults to full agentic mode (Plan-Act-Evaluate loop) for all prompts
- CLI parser in `termaite/cli.py` has basic argument parsing but no mode flags
- Task handler in `termaite/core/task_handler.py` always uses full agent loop
- Application in `termaite/core/application.py` always calls task handler

## Implementation Plan

### Step 1: Update CLI Parser
**File**: `termaite/cli.py`
- Add `-a`/`--agentic` flag for agentic mode
- Add `-t`/`--task` flag for task mode (alias for agentic)
- Modify argument parsing to determine mode
- Update help text and examples

### Step 2: Create Simple Response Handler
**File**: `termaite/core/simple_handler.py` (new file)
- Create new `SimpleHandler` class
- Implement single LLM call for simple responses
- Handle both message-only and message+command responses
- Use simpler prompt templates for non-agentic mode

### Step 3: Update Application Layer
**File**: `termaite/core/application.py`
- Modify `handle_task()` to route between simple and agentic modes
- Add mode parameter to initialization
- Update `run_single_task()` and `run_interactive_mode()` to use appropriate handler

### Step 4: Create Simple Mode Prompts
**File**: `termaite/config/templates.py`
- Add simple response prompt template
- Template should handle both informational queries and command requests
- Keep it lightweight compared to the complex agent prompts

### Step 5: Update Configuration
**File**: `termaite/config/manager.py` (if needed)
- Ensure configuration supports simple mode
- May need to add simple_prompt to config templates

### Step 6: Update Documentation
**Files**: `README.md`, `IMPLEMENTATION.md`
- Update usage examples to show new default behavior
- Document the new flags and mode differences
- Update architecture description

## Files to Modify
1. `termaite/cli.py` - Add mode flags, update argument parsing
2. `termaite/core/application.py` - Route between simple/agentic modes
3. `termaite/core/simple_handler.py` - NEW: Simple response handler
4. `termaite/config/templates.py` - Add simple mode prompt
5. `README.md` - Update usage examples and documentation
6. `IMPLEMENTATION.md` - Update architecture documentation

## Testing Strategy
- Test simple mode with informational queries (no command expected)
- Test simple mode with action requests (command expected)
- Test agentic mode with `-a` flag (should work as before)
- Test interactive mode with both simple and agentic modes
- Verify backward compatibility

## Key Design Considerations
1. **Backward Compatibility**: Agentic mode should work exactly as before when `-a` flag is used
2. **Command Detection**: Simple mode needs to intelligently decide when to include commands vs just text
3. **Safety**: Simple mode should still respect operation modes and command permissions
4. **User Experience**: Default should feel natural and responsive for simple queries

## Success Criteria
- `termaite 'take me to my home directory'` returns message + `cd ~` command
- `termaite 'what is the best programming language'` returns just a message
- `termaite -a 'complex multi-step task'` works exactly as current implementation
- Interactive mode supports both simple responses and `-a` flag usage
- All existing functionality preserved when using agentic mode
