# GitHub Copilot Instructions for term.ai.te

## Project-Specific Development Guidelines

### Documentation Maintenance
- **README.md** and **IMPLEMENTATION.md** must be updated whenever:
  - Architecture changes are made
  - New features are added
  - Dependencies change
  - Configuration options are modified
  - Major refactoring occurs

### File Size Constraints
- **No Python script should exceed 500 lines** unless absolutely necessary
- **At 800 lines, refactoring is MANDATORY** - do not continue development without breaking down the file
- Current violation: `termaite.py` is 1328 lines and requires immediate refactoring

### Code Organization Principles
- Follow Single Responsibility Principle
- Each module should have a clear, focused purpose
- Prefer composition over inheritance
- Use type hints consistently
- Implement proper error handling

### Development Workflow

#### Before Making Changes
1. Check current file sizes with `wc -l *.py`
2. Read IMPLEMENTATION.md to understand current architecture
3. Update documentation if architectural changes are planned

#### During Development
1. Keep functions focused and small
2. Add docstrings for public interfaces
3. Use meaningful variable and function names
4. Handle edge cases explicitly

#### After Making Changes
1. Update IMPLEMENTATION.md if architecture changed
2. Update README.md if user-facing features changed
3. Check file sizes again
4. Ensure tests still pass (when test suite exists)

### Testing Strategy
- Unit tests for all business logic
- Integration tests for agent workflows
- Mock LLM responses for predictable testing
- Safety tests for command execution

### Refactoring Guidelines
When a file approaches 500 lines:
1. Identify logical boundaries
2. Extract related functions into modules
3. Create clear interfaces between modules
4. Update imports and dependencies
5. Update documentation

### Security Considerations
- Always validate LLM outputs before command execution
- Maintain command whitelisting/blacklisting
- Log all command executions
- Never execute commands without proper safety checks

### Configuration Management
- Keep configuration in `~/.config/term.ai.te/`
- Use YAML for human-readable config
- Provide sensible defaults
- Validate configuration on load

### LLM Integration
- Support multiple LLM providers
- Use structured output parsing
- Handle API failures gracefully
- Implement retry logic for transient failures

## Current Technical Debt

### URGENT: File Size Violation
- `termaite.py` is 1328 lines - **IMMEDIATE REFACTORING REQUIRED**
- Proposed structure in IMPLEMENTATION.md
- Do not add features until this is resolved

### Missing Infrastructure
- No test suite exists
- Limited error recovery
- No performance optimization
- No plugin system

## AI Assistant Guidelines

When working on this project:

1. **Always check file sizes first** - use `wc -l *.py`
2. **Read IMPLEMENTATION.md** before making changes
3. **Prioritize refactoring** over new features if files are oversized
4. **Update documentation** when making architectural changes
5. **Follow the proposed module structure** from IMPLEMENTATION.md
6. **Maintain backward compatibility** when possible
7. **Add proper error handling** to all new code
8. **Use type hints** consistently
9. **Write docstrings** for public functions and classes
10. **Consider security implications** of all LLM-generated content

## Specific Reminders

- Configuration files go in `~/.config/term.ai.te/`
- Use colorama for cross-platform colored output
- Log all important events with appropriate levels
- Validate LLM responses before using them
- Never execute commands without safety checks
- Keep the three-agent architecture (Plan/Action/Evaluation)
- Maintain operation modes (normal/gremlin/goblin)
- Support both interactive and command-line usage
