# Contributing to Xaster

Thanks for your interest in contributing! Xaster is a Neovim-native AI agent plugin, and we welcome contributions of all kinds — bug reports, features, docs, and tests.

## Development setup

1. **Fork and clone** the repository
2. **Open in Neovim** (>= 0.10 required)
3. **Run the tests** to verify your setup:

```bash
# Run all tests
bash tests/run_tests.sh

# Run with verbose output
bash tests/run_tests.sh --verbose

# Run a specific test module
bash tests/run_tests.sh module editor
```

## Architecture overview

```
lua/xaster/
├── init.lua        Plugin entry point, setup(), commands, keymaps
├── agent.lua       Resilient Agent Loop (EXPLORE→PLAN→EXECUTE→VERIFY)
├── llm.lua         LLM API client (OpenAI-compatible, curl-based)
├── toolformat.lua  OpenAI function-calling tool schema conversion
├── tools.lua       Tool registry — 70+ tools dispatch table
├── chat.lua        Streaming chat UI + diff confirmation dialog
├── editor.lua      High-level editor operations (buffer/window/cursor)
├── memory.lua      Fast/slow memory, snapshots, jump stack, tasks
├── lock.lua        Editor lock during agent operations
├── log.lua         Structured logging ring buffer
├── checkpoint.lua  Agent state persistence
├── vcursor.lua     Virtual cursor — agent position indicator
├── history.lua     Operation history / audit trail
├── errors.lua      Error code enum
├── compat.lua      0.10 compatibility shims
└── ui.lua          Statusline, toast, action indicator, large float
```

See [CLAUDE.md](CLAUDE.md) for a detailed module dependency graph and architecture docs.

## Code style

- **Indentation**: 2 spaces (no tabs)
- **Module names**: `snake_case` (`agent.lua`, `tool_format.lua`)
- **Tool names**: `dot.case` internally (`buffer.edit`), `snake_case` in API (`buffer_edit`)
- **Comments**: Prefer `---` doc comments above functions for LSP hover support
- **Error handling**: Use `errors.lua` error codes, avoid bare strings

### Adding a new tool

1. Add handler function in `tools.lua` following the existing patterns
2. Define JSON Schema parameters with `type`, `description`, `required` fields
3. Register in the `M.handlers` table
4. If it modifies content, add to `EDIT_TOOL_NAMES` in `agent.lua`
5. Add tests in `tests/xaster/`

### Editing tools and confirmation

Every tool that modifies buffer/file content must be listed in `EDIT_TOOL_NAMES` in `agent.lua`. This triggers:

- Pre-edit snapshot capture
- Post-edit diff computation
- Edit confirmation dialog (when `config.confirm_edits` is true)
- Auto LSP diagnostic check

## Testing

Tests use `tests/run_tests.sh` which spawns headless Neovim instances:

```lua
-- tests/xaster/test_example.lua
local helpers = require("tests.helpers.init")

local ok, mod = helpers.pcall_ok(require, "xaster.module_name")
helpers.assert_eq(type(mod), "table", "module should load")
```

### Test module types

| Module | What to test |
|--------|-------------|
| `module editor` | Buffer CRUD, observe snapshots, cursor ops |
| `module memory` | Remember/recall, tasks, snapshots |
| `module tools` | Tool registration, handler execution |
| `module agent` | State machine, phase transitions, history clear |
| `module llm` | Configuration, provider detection, token estimation |
| `module log` | Namespace filtering, dump format |

## PR workflow

1. Create a feature branch: `git checkout -b feat/my-feature`
2. Make changes, following code style
3. Run tests: `bash tests/run_tests.sh`
4. Commit with a descriptive message (conventional commits preferred):
   ```
   feat(tools): add lsp_rename tool
   fix(agent): handle empty tool results without crashing
   docs(readme): add Ollama configuration example
   ```
5. Push and open a PR against `main`
6. CI will run tests + lint — ensure it passes

## First-time contributors

Look for issues labeled [`good-first-issue`](https://github.com/xaster-nvim/xaster.nvim/issues?q=is%3Aissue+is%3Aopen+label%3Agood-first-issue). These are designed to be approachable for new contributors.

## Questions?

- Open a [GitHub Discussion](https://github.com/xaster-nvim/xaster.nvim/discussions) (coming soon)
- Ask in the issue: [Create a question issue](https://github.com/xaster-nvim/xaster.nvim/issues/new)

## Code of Conduct

Be kind. Be helpful. This is a community of Neovim users building tools for each other.
