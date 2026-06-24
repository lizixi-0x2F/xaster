# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

**Xaster** is a Neovim-native AI coding agent plugin written in Lua. It lives inside Neovim as a plugin, not as a separate process — every tool call executes synchronously inside the editor via `nvim_buf_set_text`, `nvim_buf_set_lines`, etc.

The agent uses OpenAI-compatible function calling (no Anthropic API, no prompt-based tools). It communicates with LLM APIs through `curl` via `vim.system`.

## Commands

```bash
# Run all tests (requires Neovim >= 0.10)
bash tests/run_tests.sh

# Run with verbose output
bash tests/run_tests.sh --verbose

# Run a specific test module
bash tests/run_tests.sh module editor
```

Tests are in `tests/xaster/` (Lua test files using a custom test runner) and executed via `tests/run_tests.sh` which spawns a headless Neovim instance with `lua require('tests.helpers.init')` loaded.

## Architecture

### Module dependency graph

```
init.lua (plugin entry, setup(), commands, keymaps)
  ├── agent.lua       (Resilient Agent Loop — core)
  │   ├── llm.lua     (API client, curl-based)
  │   ├── toolformat.lua  (OpenAI function-calling tool format)
  │   │   └── tools.lua   (Tool registry — dispatch table)
  │   ├── chat.lua    (Streaming chat UI + diff confirmation)
  │   ├── editor.lua  (High-level editor ops — buffer/window/cursor)
  │   ├── memory.lua  (Fast/slow memory, snapshots, jump stack, tasks)
  │   ├── lock.lua    (Editor lock during agent operations)
  │   ├── log.lua     (Structured logging ring buffer)
  │   └── checkpoint.lua (Agent state persistence)
  ├── vcursor.lua     (Virtual cursor — agent position indicator)
  ├── history.lua     (Operation history / audit trail)
  ├── errors.lua      (Error code enum)
  ├── compat.lua      (0.10 compatibility shims)
  └── ui.lua          (Statusline, toast, action indicator, large float)
```

### Agent Loop (agent.lua)

The agent runs a four-phase loop: **EXPLORE → PLAN → EXECUTE → VERIFY**

- **EXPLORE**: Read-only. Understand the problem space. No edits allowed.
- **PLAN**: Read + memory write tools. Design the approach, create tasks.
- **EXECUTE**: Full tool access. Make all changes.
- **VERIFY**: Full access, prompt focuses on checking work (LSP diagnostics, tests, diff review).

Phase is stored via `memory.remember("__agent_phase__", "plan")`. Auto-advancement: EXPLORE→PLAN when tasks exist; EXECUTE→VERIFY after edits are made.

### Tool filtering (blocklist approach)

Instead of a manually curated allowlist per phase, the system uses a **blocklist**: tools that modify buffer/file content are blocked in EXPLORE and PLAN. Everything else (navigation, memory, snapshots, registers, marks, LSP, etc.) is automatically available.

`BLOCKED_IN_READONLY_PHASES` in `agent.lua` lists the ~19 tools that are actually destructive. All other tools pass through.

For DeepSeek models, `DEEPSEEK_ESSENTIAL_TOOLS` is intersected with the phase-filtered tools (not a replacement), preserving phase gating while keeping the tool count manageable.

### Edit confirmation flow

Before executing edit tools, `capture_pre_edit_content()` saves buffer content (tries buffer → filesystem → empty for new files). After execution, `collect_edit_diffs()` computes unified diffs via `editor.compute_unified_diff()` (LCS-based algorithm). If `config.confirm_edits` is true (default), `chat.confirm_edits()` shows a floating window with green `+` / red `-` highlighted diffs and waits for user input:

- `y` — accept edits, continue loop
- `n` / `q` / `<Esc>` — reject, restore pre-edit snapshot via `memory.snapshot_restore`
- `<C-c>` — abort, restore snapshot and fully stop the agent

### Key conventions

- **Indentation**: 2 spaces (no tabs).
- **Tool names**: Internal names use dots (`buffer.edit`). API format uses underscores (`buffer_edit`). `toolformat.lua` handles conversion.
- **Every edit tool** must be in `EDIT_TOOL_NAMES` (agent.lua) to trigger pre/post-edit verification and confirmation.
- **Buffer operations** go through `editor.lua` wrappers, not raw `vim.api` calls — they handle lock bypass, validation, and error normalization.
- **Memory layers**: "Fast" memory (TTL-based scratchpad) and "Slow" memory (persistent, confidence-scored knowledge). `memory.recall()` checks fast first, slow as fallback.
- **Snapshots** capture buffer content (up to 500 lines), cursor, all named registers (a-z, A-Z), and all named marks. Used as rewind points before risky edits.
