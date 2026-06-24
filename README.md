<p align="center">
  <img src="https://raw.githubusercontent.com/xaster-nvim/xaster.nvim/main/.github/assets/logo.svg" alt="Xaster" width="160" />
</p>

<h1 align="center">Xaster</h1>
<p align="center"><strong>The native AI agent inside Neovim.</strong></p>

<p align="center">
  <a href="https://github.com/xaster-nvim/xaster.nvim/stargazers"><img src="https://img.shields.io/github/stars/xaster-nvim/xaster.nvim?style=for-the-badge&color=cba6f7&labelColor=1e1e2e" alt="Stars" /></a>
  <a href="https://github.com/xaster-nvim/xaster.nvim/blob/main/LICENSE"><img src="https://img.shields.io/github/license/xaster-nvim/xaster.nvim?style=for-the-badge&color=89dceb&labelColor=1e1e2e" alt="License" /></a>
  <a href="https://neovim.io"><img src="https://img.shields.io/badge/Neovim-%3E%3D%200.10-57A143?style=for-the-badge&logo=neovim&labelColor=1e1e2e" alt="Neovim" /></a>
</p>

<p align="center">
  <img src=".github/assets/demo.gif" alt="Xaster demo" width="720" />
</p>

---

> **Xaster** is not just another "chat with AI in a sidebar" plugin. It's a **full autonomous agent loop** — EXPLORE → PLAN → EXECUTE → VERIFY — running natively inside Neovim. It reads your codebase, plans the work, makes edits through real Vim operations, shows you every diff before applying, and verifies nothing broke. All without leaving your editor.

## ✨ Why Xaster?

Most AI tools for Neovim are **chat + diff**. You type a prompt, get a response, and manually apply patches. That's not an agent — that's a chatbot with a copy button.

Xaster is different:

| | Xaster | avante.nvim | codecompanion.nvim | Cline | Aider |
|-|:------:|:-----------:|:------------------:|:-----:|:-----:|
| **Agent Loop** (E→P→E→V) | ✅ | ❌ chat-only | ❌ chat-only | ✅ | ✅ |
| **Neovim Native** | ✅ | ✅ | ✅ | ❌ VS Code | ❌ terminal |
| **Vim Grammar Tools** | ✅ `ciw` `da{` `:%s/` | ❌ | ❌ | ❌ | ❌ |
| **Edit Confirmation** | ✅ unified diff | ✅ side-by-side | ❌ | ✅ | ❌ auto-commit |
| **Virtual Cursor** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **4-Layer Memory** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Circuit Breaker** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Checkpoint Recovery** | ✅ | ❌ | ❌ | ✅ | ✅ |
| **Auto LSP Verify** | ✅ | ❌ | ❌ | ❌ | ✅ |
| **Register Stack** | ✅ push/pop/peek | ❌ | ❌ | ❌ | ❌ |
| **Snapshots + Auto-rollback** | ✅ | ❌ | ❌ | ✅ | ✅ |
| **BYO Model** | ✅ OpenAI compat | ✅ 5 providers | ✅ 7 providers | ✅ 7 providers | ✅ 100+ |

## 🎥 See it in action

### The Agent Loop
*User asks: "add proper error handling to `parse_config`" — the agent explores, plans, executes, and verifies.*

### Edit Confirmation
*Every edit batch shows a unified diff. Green = added, Red = removed. You decide what applies.*

### Virtual Cursor
*Watch the agent work. An amber `|` shows where it's editing. A purple `|` shows where it's reading. Trails fade behind it.*

> *Demo GIFs coming soon — recording in progress.*

## ⚡ Quick Start

### Requirements
- Neovim >= 0.10
- `curl` (for API calls)

### Installation

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "xaster-nvim/xaster.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    agent = {
      api_key = "sk-...",           -- your API key
      model = "gpt-4o",             -- or "deepseek-chat", "claude-sonnet-4-20250514"
      api_url = "https://api.openai.com/v1/chat/completions",
    },
  },
  keys = {
    { "<leader>ac", "<cmd>XasterChat<cr>", desc = "Xaster Chat" },
  },
}
```
</details>

<details>
<summary><b>packer.nvim</b></summary>

```lua
use {
  "xaster-nvim/xaster.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("xaster").setup({
      agent = {
        api_key = "sk-...",
        model = "gpt-4o",
      },
    })
  end,
}
```
</details>

<details>
<summary><b>rocks.nvim</b></summary>

```lua
-- Not yet available on luarocks. Coming soon.
```
</details>

### Your first agent session

1. Open Neovim in any project
2. Press `<leader>ac` (or run `:XasterChat`)
3. Type your task: *"Find the authentication logic and document the flow"*
4. Watch the agent **Explore** your codebase → **Plan** the approach → **Execute** the changes → **Verify** nothing broke
5. Review each diff in the confirmation window — press `y` to accept, `n` to reject

```vim
:XasterChat        " Toggle the agent chat panel
:XasterStatus      " Show agent status, model, token usage
:XasterPhase plan  " Jump directly to PLAN phase
```

## 🔄 The Agent Loop

Xaster doesn't jump straight to editing. It follows a structured engineering workflow:

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ EXPLORE  │────▶│   PLAN   │────▶│ EXECUTE  │────▶│  VERIFY  │
│ read-only│     │read+plan │     │full tools│     │ verify   │
└──────────┘     └──────────┘     └──────────┘     └──────────┘
     │                  │               │                │
     │  Understand      │  Design       │  Make          │  Check
     │  the codebase    │  the approach │  the changes   │  the result
```

1. **EXPLORE** — Reads files, runs LSP queries, browses symbols. Cannot edit anything.
2. **PLAN** — Creates tasks with dependencies, designs the approach, estimates scope.
3. **EXECUTE** — Full tool access. Makes edits through Vim-native operations (`ciw`, `da{`, `:%s/`). Every edit is diffed and shown for confirmation.
4. **VERIFY** — Runs diagnostics, checks for regressions, reviews the diff. If errors found, auto-retries up to 3 times, then rolls back.

**Auto-advancement:** EXPLORE → PLAN when tasks are created. EXECUTE → VERIFY after edits are made. You can override at any time with `:XasterPhase explore|plan|execute|verify`.

## 🛠️ 70+ Native Tools

Xaster gives the AI **real editor superpowers**, not generic text manipulation:

### Vim Grammar Tools
The agent speaks Vim natively — `ciw` to change a word, `da{` to delete a block, `:%s/foo/bar/g` for project-wide substitutions. No other AI tool can do this.

| Tool | What it does |
|------|-------------|
| `vim.edit(operator, motion, text)` | Execute any Vim operator-motion combo: `ciw`, `da{`, `>ap`, `yiw` |
| `vim.search(pattern, direction)` | Search with `:vimgrep`, populate quickfix list |
| `vim.substitute(range, pattern, repl, flags)` | Native `:s` substitutions with full regex |
| `vim.normal(keys)` | Execute any normal mode command sequence |

### Buffer & Editor
`buffer.edit`, `buffer.get`, `buffer.set`, `buffer.create`, `buffer.delete`, `buffer.save`, `cursor.get`, `cursor.set`, `window.split`, `window.focus`, `visual.get`, `mode.get`, `feedkeys`, `command`, `lua`

### Rich Data Structures
Vim registers become a full stack data structure — `register.push`, `register.pop`, `register.peek`, `register.rotate`, `register.eval`

### LSP Integration
`lsp.hover`, `lsp.definition`, `lsp.references`, `lsp.diagnostics`, `lsp.code_actions`, `lsp.document_symbols`, `lsp.workspace_symbols`

### Safety Net
| Mechanism | What it does |
|-----------|-------------|
| **Pre-edit Snapshots** | Full buffer state saved before every edit batch |
| **Edit Confirmation** | Unified diff shown before applying. You approve each change. |
| **Auto LSP Verify** | Diagnostics run after every edit. Errors → retry or rollback. |
| **Circuit Breaker** | Tool failing 3x in 60s → disabled for 60s. No infinite loops. |
| **Checkpoint Recovery** | Agent state saved every 3 rounds. Survives Neovim restart. |

## 🧠 Memory Architecture

Xaster has a four-layer memory system — it remembers across turns and across sessions:

| Layer | Type | Persistence | Purpose |
|-------|------|------------|---------|
| **Fast Memory** | TTL-based scratchpad | Current task | Temporary finds, intermediate values |
| **Slow Memory** | Confidence-scored facts | Session lifetime (survives compression) | Project conventions, patterns, strategies |
| **Jump Stack** | Semantic navigation history | Session lifetime | Structured forward/back navigation with intent |
| **Snapshots** | Full editor state captures | Session lifetime | Pre-edit rewind points, diff baselines |

- `memory.learn("fact", "This project uses snake_case")` — persisted with confidence scoring
- `memory.guide()` — recalls the most relevant high-confidence knowledge
- `memory.snapshot_create("before-refactor")` — full rollback point
- `memory.jump_push("auth.ts", "checking login flow")` — navigable history with intent labels

## 🎨 UI

Everything is styled with **Catppuccin Mocha** by default:

<p align="center">
  <img src=".github/assets/chat-ui.png" alt="Chat UI" width="720" />
</p>

- **Streaming chat** — Real-time streamed responses with syntax highlighting
- **Thinking display** — Model reasoning shown in gray italic (DeepSeek `reasoning_content` supported)
- **Tool status bar** — Live tool execution status (PENDING → OK/ERROR)
- **Diff confirmation** — Floating window with color-coded unified diff, file-by-file
- **Virtual cursor** — Agent position visualized: amber = editing, purple = reading, fading trails
- **Statusline** — Agent phase, round count, token usage

### Highlights

| Group | Color | Purpose |
|-------|-------|---------|
| `XasterAgent` | Mauve | Agent messages |
| `XasterThink` | Gray italic | Reasoning/thought chain |
| `XasterUser` | Green | User messages |
| `XasterTool` | Amber | Tool calls |
| `XasterDiffAdd` | Green bg | Added lines in diff |
| `XasterDiffDel` | Red bg | Removed lines in diff |

## 🔌 Supported Models

Any provider with an OpenAI-compatible API:

| Provider | Model example | Notes |
|----------|--------------|-------|
| **OpenAI** | `gpt-4o`, `gpt-4-turbo` | Native tool calling |
| **Anthropic** | `claude-sonnet-4-20250514` | Via compatible endpoint |
| **DeepSeek** | `deepseek-chat` | Full support, optimized tool set, `reasoning_content` |
| **Groq** | `llama-3.3-70b` | Fast inference |
| **Ollama** | `codellama`, `qwen2.5-coder` | Local, private |
| **OpenRouter** | Any model | Unified API gateway |

```lua
-- Ollama (local)
opts = {
  agent = {
    api_url = "http://localhost:11434/v1/chat/completions",
    model = "qwen2.5-coder:14b",
  },
}

-- DeepSeek
opts = {
  agent = {
    api_url = "https://api.deepseek.com/v1/chat/completions",
    api_key = "sk-...",
    model = "deepseek-chat",
  },
}
```

## ⌨️ Commands & Keymaps

| Command | Keymap | Description |
|---------|--------|-------------|
| `:XasterChat` | `<leader>ac` | Toggle chat panel |
| `:XasterAgentStop` | `<leader>as` | Stop running agent |
| `:XasterAgentClear` | — | Clear conversation history |
| `:XasterPhase [phase]` | — | Show/set agent phase |
| `:XasterStatus` | — | Agent + LLM + log status |
| `:XasterObserve` | `<leader>xo` | Full editor state snapshot |
| `:XasterHistory [n]` | `<leader>xh` | Operation history (audit trail) |
| `:XasterLog [n]` | — | Internal log viewer |
| `:XasterTools` | — | List all 70+ available tools |
| `:XasterLock` / `:XasterUnlock` | — | Lock/unlock editor for agent |
| `:XasterSync [off]` | — | Toggle file sync |
| `:XasterCheckpoints` | — | List saved checkpoints |
| `:XasterRestoreLast` | — | Restore last checkpoint |
| `:XasterUltracode [on\|off]` | — | Exhaustive vs normal mode |

## 🔧 Configuration

<details open>
<summary><b>Full defaults</b></summary>

```lua
require("xaster").setup({
  agent = {
    api_key = "",                        -- Set this or use env vars
    model = "gpt-4o",
    max_tokens = 8192,
    api_url = "https://api.openai.com/v1/chat/completions",
    max_rounds = 1024,
    timeout_sec = 300,
    max_retries = 3,
    retry_delays = { 1, 4, 15 },
    ultracode = true,                    -- Exhaustive mode: deeper analysis
  },
  chat = {
    height_ratio = 0.35,
    min_chat_height = 8,
    cmd_height = 8,
    max_messages = 500,
  },
  ui = {
    action = { enabled = true },
    toast = { enabled = true },
    statusline = { enabled = true },
    highlights = { enabled = true },
  },
  vcursor = {
    mode = "line",
    auto_hide_ms = 0,
    flash_duration_ms = 400,
    show_label = false,
  },
  history = {
    max_entries = 1000,
  },
  lock = {
    auto_lock_new_buffers = true,
    block_insert = true,
  },
  file_sync = {
    enabled = true,
    check_interval_ms = 2000,
    auto_reload = true,
  },
  log = {
    level = "INFO",
    ring_size = 2000,
    file_enabled = false,
    notify_enabled = true,
  },
  checkpoint = {
    max_checkpoints = 5,
    auto_save_on_exit = true,
  },
  keymaps = {
    chat_toggle = "<leader>ac",
    agent_stop = "<leader>as",
    observe = "<leader>xo",
    history = "<leader>xh",
    action = "<leader>xa",
  },
})
```
</details>

### Environment variables

```bash
export ANTHROPIC_API_KEY="sk-ant-..."    # Anthropic API key
export ANTHROPIC_BASE_URL="..."          # Custom endpoint
export ANTHROPIC_MODEL="..."             # Model override
```

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and PR workflow.

- **Good first issues**: [Issues labeled `good-first-issue`](https://github.com/xaster-nvim/xaster.nvim/issues?q=is%3Aissue+is%3Aopen+label%3Agood-first-issue)
- **Code style**: 2-space indent, `snake_case` modules, `dot.case` tool names
- **Tests**: `bash tests/run_tests.sh` (requires Neovim >= 0.10)

## 📜 License

[MIT](LICENSE)

---

<p align="center">
  <sub>Built with 💜 in Lua. Agent loop inspired by the software engineering method. UI by Catppuccin.</sub>
</p>
