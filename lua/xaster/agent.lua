--- xaster/agent.lua
--- ============================================================================
--- Resilient Agent Loop -- Observe -> Plan -> Act -> Reflect
--- v3: Pure OpenAI function calling. No Anthropic, no prompt-based tools.
--- ============================================================================

local llm = require("xaster.llm")
local toolformat = require("xaster.toolformat")
local chat = require("xaster.chat")
local editor = require("xaster.editor")
local memory = require("xaster.memory")
local log = require("xaster.log").for_module("agent")

local M = {}

-- ============================================================================
-- Configuration
-- ============================================================================

local config = {
  max_rounds = 1024,
  compress_at_token_ratio = 0.80,
  keep_recent_rounds = 5,
  max_retries = 3,
  checkpoint_interval = 3,
  circuit_breaker_threshold = 3,
  ultracode = true,            -- exhaustive mode: deeper analysis, more thorough execution
  confirm_edits = true,         -- show diff and ask user to confirm before applying edits
}

-- DeepSeek: limit tools to avoid "request too large" errors.
-- Now used as INTERSECTION with phase-filtered tools (not replacement).
-- Must include all tools needed in EXPLORE/PLAN phases, plus edit tools for EXECUTE.
local DEEPSEEK_ESSENTIAL_TOOLS = {
  -- Observe / File I/O
  "observe", "file_read", "file_write", "file_ensure_open", "file_watch",
  -- Buffer tools
  "buffer_get", "buffer_set", "buffer_edit", "buffer_list", "buffer_info",
  "buffer_create", "buffer_delete", "buffer_save", "buffer_reload",
  -- Cursor / Window
  "cursor_get", "cursor_set", "window_list", "window_scroll",
  "window_split", "window_focus", "window_close", "window_config",
  -- Editor mode / Commands
  "mode_get", "eval", "command", "feedkeys", "lua",
  -- Vim-native grammar
  "vim_edit", "vim_search", "vim_substitute", "vim_normal",
  -- Undo
  "undo_savepoint", "undo", "redo", "undo_tree",
  -- Visual selection
  "visual_get",
  -- LSP
  "lsp_hover", "lsp_definition", "lsp_references", "lsp_diagnostics",
  "lsp_document_symbols", "lsp_workspace_symbols", "lsp_code_actions", "lsp_rename",
  -- Register (all operations)
  "register_get", "register_get_type", "register_set", "register_list",
  "register_push", "register_pop", "register_peek", "register_eval",
  "register_rotate", "register_set_expression", "register_jump_to",
  -- Marks
  "mark_get", "mark_set",
  -- Memory (fast layer)
  "memory_remember", "memory_forget", "memory_recall", "memory_clear",
  -- Memory (slow layer)
  "memory_learn", "memory_know", "memory_query", "memory_guide",
  "memory_promote", "memory_demote", "memory_absorb", "memory_slow_stats",
  -- Memory (tasks)
  "memory_tasks_init", "memory_task_update", "memory_task_progress",
  -- Memory (navigation)
  "memory_mark", "memory_jump", "memory_locations",
  "memory_jump_push", "memory_jump_back", "memory_jump_forward",
  "memory_jump_peek", "memory_jump_info",
  -- Memory (snapshots)
  "memory_snapshot_create", "memory_snapshot_restore", "memory_snapshot_diff",
  "memory_snapshot_list", "memory_snapshot_delete",
  -- Virtual cursor
  "vcursor_get", "vcursor_set", "vcursor_clear", "vcursor_flash",
  -- Highlights
  "highlight_add", "highlight_del", "highlight_clear", "virtual_text_show",
  -- Lock
  "lock_get", "lock_set",
  -- Quickfix / Tabs
  "quickfix_list", "quickfix_set", "tab_list",
  -- Meta
  "state_observe", "agent_observe", "log_dump", "log_observe",
  -- Bash
  "bash",
  -- Ping
  "ping",
}

function M.configure(opts)
  if not opts then return end
  if opts.max_rounds then config.max_rounds = opts.max_rounds end
  if opts.ultracode ~= nil then config.ultracode = opts.ultracode end
  if opts.confirm_edits ~= nil then config.confirm_edits = opts.confirm_edits end
end

--- Toggle ultracode exhaustive mode at runtime.
--- The new prompt takes effect on the next message.
---@param enabled boolean|nil  true=on, false=off, nil=toggle
---@return boolean  new state
function M.ultracode(enabled)
  if enabled == nil then
    config.ultracode = not config.ultracode
  else
    config.ultracode = enabled
  end
  return config.ultracode
end

function M.is_ultracode()
  return config.ultracode
end

-- ============================================================================
-- State
-- ============================================================================

local messages = {}
local running = false
local abort_flag = false
local handle = nil
local round = 0
local compressed_count = 0
local token_usage = { last_api_input = 0, last_api_output = 0 }
local circuit_state = {}    -- { [tool_name]: { failures: int, last_failure: time } }

-- ============================================================================
-- Phase Gating -- structured engineering loop
-- ============================================================================
-- The agent operates in four phases, analogous to Claude Code's
-- plan-then-execute workflow. Each phase gates tool availability
-- and tailors the system prompt.
--
--   EXPLORE -> PLAN -> EXECUTE -> VERIFY -> (loop) -> DONE
--
-- Phase transitions are driven by the agent via memory.remember("__agent_phase__", ...)
-- or by the loop itself after edit batches.

local Phase = {
  EXPLORE = "explore",   -- read-only: understand the problem space
  PLAN    = "plan",      -- read + task tools: design the approach
  EXECUTE = "execute",   -- full tool access: make changes
  VERIFY  = "verify",    -- full access, but prompt focuses on checking work
}

-- ============================================================================
-- Phase-based Tool Filtering (BLOCKLIST approach)
-- ============================================================================
-- Instead of manually curating an allowlist for each phase, we use a single
-- blocklist: tools that modify buffer/file content are blocked in EXPLORE
-- and PLAN phases. Everything else (navigation, memory, snapshots, registers,
-- marks, LSP, etc.) is automatically available in ALL phases.
--
-- This prevents the "missing tool" whack-a-mole: any new tool added to the
-- registry is automatically available in all phases unless explicitly blocked.

-- Tools that MODIFY buffer or file content.
-- These are blocked during EXPLORE and PLAN phases.
-- All other tools are freely available.
local BLOCKED_IN_READONLY_PHASES = {
  -- Direct buffer modifications
  ["buffer_edit"] = true, ["buffer_set"] = true,
  ["buffer_create"] = true, ["buffer_delete"] = true, ["buffer_save"] = true,
  ["buffer_reload"] = true,
  -- File operations (writing)
  ["file_write"] = true,
  -- Vim-native edits
  ["vim_edit"] = true, ["vim_substitute"] = true, ["vim_normal"] = true,
  -- Command execution with side effects
  ["command"] = true, ["feedkeys"] = true, ["lua"] = true,
  -- Undo (modifies buffer state)
  ["undo"] = true, ["redo"] = true,
  -- LSP code actions / rename (may modify code)
  ["lsp_code_actions"] = true, ["lsp_rename"] = true,
  -- Snapshot restore (rewrites buffer content)
  ["memory_snapshot_restore"] = true,
  -- Memory clear (destroys all memory state)
  ["memory_clear"] = true,
}

--- Build the list of API tool names allowed in EXPLORE/PLAN phases.
--- Returns all tool names from the full registry MINUS the blocked ones.
---@return string[]  API-format tool names (underscores)
local function build_readonly_tool_names()
  local all = toolformat.get_tools()
  local names = {}
  for _, t in ipairs(all) do
    local api_name = t["function"].name
    if not BLOCKED_IN_READONLY_PHASES[api_name] then
      names[#names + 1] = api_name
    end
  end
  return names
end

local function get_current_phase()
  local stored = memory.recall("__agent_phase__")
  if stored and Phase[stored:upper()] then
    -- Normalize: "EXPLORE", "explore", "Explore" all resolve to Phase.EXPLORE
    return stored:lower()
  end
  return Phase.EXPLORE  -- default: new tasks start in explore
end

local function set_current_phase(phase_name)
  memory.remember("__agent_phase__", phase_name:lower(), { source = "agent_loop" })
end

-- ============================================================================
-- Error Classification
-- ============================================================================

local ErrorTier = { TRANSIENT = 1, RECOVERABLE = 2, FATAL = 3 }

local function classify_error(error_code)
  local ec = require("xaster.errors").ErrorCode
  if error_code == ec.NETWORK_ERROR or error_code == ec.TIMEOUT or error_code == ec.RATE_LIMITED then
    return ErrorTier.TRANSIENT
  elseif error_code == ec.AUTH_ERROR or error_code == ec.INTERNAL_ERROR or error_code == ec.PARSE_ERROR then
    return ErrorTier.FATAL
  end
  return ErrorTier.RECOVERABLE
end

-- ============================================================================
-- Circuit Breaker
-- ============================================================================

-- Circuit breaker with time-based decay. Failures older than the decay
-- window (60s) are forgiven. This prevents permanent tool disablement in
-- long sessions while still catching tight failure loops.
local CIRCUIT_DECAY_SEC = 60

local function is_circuit_open(name)
  local state = circuit_state[name]
  if not state then return false end
  -- Decay: if last failure was more than CIRCUIT_DECAY_SEC ago, forgive
  if state.last_failure and (os.time() - state.last_failure) > CIRCUIT_DECAY_SEC then
    circuit_state[name] = nil
    return false
  end
  return state.failures >= config.circuit_breaker_threshold
end

local function circuit_success(name)
  circuit_state[name] = nil
end

local function circuit_failure(name)
  local state = circuit_state[name]
  if not state then
    state = { failures = 0, last_failure = 0 }
    circuit_state[name] = state
  end
  state.failures = state.failures + 1
  state.last_failure = os.time()
  return state.failures >= config.circuit_breaker_threshold
end

-- ============================================================================
-- Context Compression
-- ============================================================================

local function compress_context()
  local limit = llm.get_context_limit()
  local current = llm.count_context_tokens(messages, nil)
  if current < limit * config.compress_at_token_ratio then return end

  log.info("compressing context", { tokens = current, limit = limit })
  local rounds = {}
  local start = nil
  for i, msg in ipairs(messages) do
    if msg.role == "user" and not msg._round_marker then
      if start then rounds[#rounds + 1] = { start = start, end_ = i - 1 } end
      start = i
    end
  end
  if start then rounds[#rounds + 1] = { start = start, end_ = #messages } end
  if #rounds <= config.keep_recent_rounds then return end

  for r_idx = 1, #rounds - config.keep_recent_rounds do
    local r = rounds[r_idx]
    if r then
      local user_msg = messages[r.start]
      local user_text = type(user_msg.content) == "string" and user_msg.content or ""
      local brief = user_text:gsub("\n", " "):sub(1, 120)
      messages[r.start] = { role = "user", content = "[Compressed] " .. brief, compressed = true, _round_marker = true }
      for i = r.start + 1, r.end_ do
        if messages[i].role == "assistant" then
          messages[i] = { role = "assistant", content = "[Compressed]", compressed = true }
          break
        end
      end
      compressed_count = compressed_count + 1
    end
  end
end

-- ============================================================================
-- System Prompt
-- ============================================================================
-- The system prompt is assembled from independently-computed sections.
-- Each section is a function returning a string or nil (nil = skip).
-- Sections are separated by double-newlines for readability.
--
-- Structure:
--   1. PHASE GATE   -- EXPLORE/PLAN/VERIFY behavioral constraints (primary)
--   2. IDENTITY     -- who the agent is, where it lives
--   3. RULES        -- non-negotiable operational constraints (EXECUTE only)
--   4. EDITOR       -- current file, cursor, visible content
--   5. ENVIRONMENT  -- CWD, buffers, diagnostics
--   6. MEMORY       -- facts, tasks, locations, jump stack, snapshots
--                    (only included when non-empty)
--   7. TOOLS        -- compact categorized reference
--   8. PATTERNS     -- state machine workflows (register/jump/snapshot combos)
--   9. GUIDANCE     -- when-to-use-what decision rules (EXECUTE/VERIFY only)
--  10. ULTRACODE    -- exhaustive mode instructions (when enabled)
--
-- Phase-aware behavior:
--   EXPLORE: phase gate + identity + editor + environment + memory + read-only tools
--   PLAN:    phase gate + identity + editor + environment + memory + read+task tools
--   EXECUTE: phase gate(nil) + all sections (standard behavior)
--   VERIFY:  phase gate + identity + editor + environment + memory + tools + guidance
--
-- Phase gates override RULES and GUIDANCE: during EXPLORE/PLAN the agent is
-- explicitly constrained to read-only; during VERIFY the focus is on checking.

-- Section builders return a string or nil (nil = omit section).
-- The main builder concatenates all non-nil sections.

-- ---------------------------------------------------------------------------
-- 1. IDENTITY
-- ---------------------------------------------------------------------------
local function prompt_identity()
  return [[## Identity
You are Xaster, a Vim-native AI agent. You live inside Neovim -- not as a separate process, but as a plugin with direct access to every buffer, window, register, mark, and Vim command. You do not simulate Vim; you ARE Vim. Every tool you call executes synchronously inside the editor the user is looking at.

**You are an autonomous engineer.** The user brought you here to DO work, not to discuss it. Read, decide, execute. Do not narrate your plans -- show results. Do not ask for permission -- you already have it. If a task is clear, start immediately. When you see a problem, fix it. The only time you should ask questions is when the task is genuinely ambiguous and no reasonable default exists.]]
end

-- ---------------------------------------------------------------------------
-- 2. RULES
-- ---------------------------------------------------------------------------
local function prompt_rules()
  return [[## Rules
1. ACT, don't ask. You have full authority to read, edit, execute, and verify. Never ask "should I proceed?" or "do you want me to?" -- just do it. The user is busy; they called you to offload work, not to micro-manage.
2. READ first: call file.read or observe before modifying anything. Never guess file contents.
3. CHECKPOINT before edits: call undo.savepoint so the user can undo your changes as a single block.
4. VERIFY after edits: call lsp.diagnostics and fix any introduced errors.
5. MATCH the surrounding code: indent style, naming convention, comment density, module pattern.
6. BATCH independent reads: parallel file.read calls for unrelated files; serialize writes.
7. MINIMAL edits: use buffer.edit over buffer.set when only changing a few lines. Use vim.edit for single operations.
8. COMPLETE the task: don't stop halfway. If a task implies multiple steps, do all of them. Use memory.tasks_init to track progress on complex work.
9. BIAS for action: when in doubt between two reasonable approaches, pick one and execute. A wrong edit can be undone; hesitation wastes the user's time.]]
end

-- ---------------------------------------------------------------------------
-- 3. EDITOR STATE
-- ---------------------------------------------------------------------------
local function prompt_editor(obs, cf)
  local lines = { "## Editor" }

  if cf and cf.name ~= "" then
    local mod = cf.modified and " [+]" or ""
    lines[#lines + 1] = string.format("File: %s  |  %s %dL  |  Cursor: L%d C%d%s",
      cf.name, cf.filetype or "?", cf.line_count,
      cf.cursor and cf.cursor.row or 1, cf.cursor and cf.cursor.col or 0, mod)
  else
    lines[#lines + 1] = "File: (none open)"
  end

  if obs.visible_content and #obs.visible_content > 0 then
    lines[#lines + 1] = ""
    local s = obs.visible_range.start or 1
    for i, line in ipairs(obs.visible_content) do
      lines[#lines + 1] = string.format("%5d  %s", s + i - 1, line)
    end
  end

  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- 4. ENVIRONMENT
-- ---------------------------------------------------------------------------
local function prompt_environment(obs, cf)
  local lines = {}

  lines[#lines + 1] = "CWD: " .. vim.fn.getcwd()

  if obs.buffers and #obs.buffers > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Buffers:"
    for _, b in ipairs(obs.buffers) do
      local mark = ""
      if cf and b.id == cf.buf then mark = " <-- current" end
      if b.modified then mark = mark .. " [+]" end
      local name = b.name ~= "" and b.name or ("[no-name:" .. b.id .. "]")
      lines[#lines + 1] = string.format("  %d: %s  %s%s", b.id, name, b.filetype or "", mark)
    end
  end

  if obs.diagnostics and #obs.diagnostics > 0 then
    local errs, warns = 0, 0
    for _, d in ipairs(obs.diagnostics) do
      if d.severity == 1 then errs = errs + 1
      elseif d.severity == 2 then warns = warns + 1 end
    end
    lines[#lines + 1] = string.format("\nDiagnostics: %dE %dW", errs, warns)
    for _, d in ipairs(obs.diagnostics) do
      local sev = d.severity == 1 and "E" or (d.severity == 2 and "W" or "I")
      lines[#lines + 1] = string.format("  L%d [%s] %s", d.lnum, sev, d.message:sub(1, 120))
    end
  end

  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- 5. MEMORY (facts, tasks, locations, jump stack, snapshots)
-- ---------------------------------------------------------------------------
local function prompt_memory()
  local parts = {}

  -- Fast layer: current working set
  local mem = memory.dump()
  if #mem > 0 then parts[#parts + 1] = mem end

  -- Task state
  local tasks = memory.dump_tasks()
  if #tasks > 0 then parts[#parts + 1] = tasks end

  -- Location marks
  local locs = memory.dump_locations()
  if #locs > 0 then parts[#parts + 1] = locs end

  -- Register stacks
  local regs = editor.register_dump()
  if regs then parts[#parts + 1] = regs end

  -- Jump stack
  local jumps = memory.jump_dump()
  if #jumps > 0 then parts[#parts + 1] = jumps end

  -- Snapshots
  local snaps = memory.snapshot_dump()
  if #snaps > 0 then parts[#parts + 1] = snaps end

  -- Slow layer: accumulated knowledge (shown last, as it guides fast)
  local slow = memory.dump_slow()
  if #slow > 0 then parts[#parts + 1] = slow end

  if #parts == 0 then return nil end

  return "## Memory\n" .. table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- 6. TOOL REFERENCE (compact, categorized)
-- ---------------------------------------------------------------------------
local function prompt_tools()
  return [[## Tools
All tools are available via function calling. Key tools by category:

**Edit:** file.read, file.write (content=string or edits=array), buffer.edit, buffer.set, buffer.get
**Vim Grammar:** vim.edit(op + target) -- ciw, da}, >ap, yiw, guw, gUiw; vim.search(pattern, quickfix), vim.substitute(range, pattern, replacement, flags), vim.normal(keys)
**Navigation:** cursor.get/set, window.scroll, mark.get/set, memory.jump(key, intent)
**LSP:** lsp.diagnostics, lsp.hover, lsp.definition, lsp.references, lsp.document_symbols, lsp.code_actions
**Shell:** bash(cmd, cwd, timeout_ms) -- run tests, git, build, search
**Undo:** undo.savepoint, undo, redo, undo.tree

**Register (plain):** register.get, register.set, register.list, register.get_type
**Register (stack):** register.push/pop -- save/restore intermediate states; register.peek -- view stack; register.rotate -- cycle stack
**Register (smart):** register.set_expression(expr) -- live-evaluated register; register.eval -- re-evaluate; register.jump_to -- parse "file:line" and navigate

**Mark:** mark.set, mark.get, memory.mark(key) -- two-layer: Lua fact + Vim mark

**Memory (fast):** memory.remember(key, value), memory.recall(key) -- fast first, slow fallback, memory.forget(key)
**Memory (slow):** memory.learn(key, value, type, tags) -- persist confirmed knowledge; memory.know(key) -- direct slow read; memory.query(pattern) -- search slow by key/tag/type; memory.promote(key) -- fast->slow; memory.demote(key) -- slow->fast; memory.guide() -- slow provides relevant context; memory.absorb() -- extract patterns from fast into slow
**Memory (tasks):** memory.tasks_init([{id,title}]), memory.task_update(id, status), memory.task_progress
**Memory (navigation):** memory.jump_push(intent) -- bookmark current position with reason; memory.jump_back -- like <C-o>; memory.jump_forward -- like <C-i>; memory.jump_peek -- view stack
**Memory (snapshots):** memory.snapshot_create(name) -- capture buffer+cursor+registers+marks; memory.snapshot_restore(name) -- rewind; memory.snapshot_diff(a, b) -- compare

**Meta:** observe, state.observe, tools.list, history.list, log.dump, agent.observe
**Other:** buffer.create/delete/save/reload/info/list, window.split/focus/close, highlight.add/del/clear, virtual_text.show, quickfix.set/list, lock.set/get, vcursor.set/get/clear/flash, command, feedkeys]]
end

-- ---------------------------------------------------------------------------
-- 7. STATE MACHINE PATTERNS
-- ---------------------------------------------------------------------------
local function prompt_patterns()
  return [[## State Machine Patterns
The tools above are NOT isolated -- they compose into workflows. The key primitives are registers (data), marks (positions), jump stack (navigation history), and snapshots (rewind points).

### Pattern A: Intermediate State Stack
```
register.push("w", current_content)   -- save before editing
-- ... make changes ...
register.push("w", new_content)       -- save after
-- if wrong: register.pop("w")        -- restore previous state
-- if right: register.peek("w")       -- review history
```

### Pattern B: Semantic Navigation
```
memory.jump_push("understand the import chain")  -- mark where I am and why
memory.jump("some_target")                       -- go explore
-- ... investigate ...
memory.jump_back()                               -- return with knowledge
```

### Pattern C: Rewind Point
```
memory.snapshot_create("pre_refactor")
-- ... risky multi-file edits ...
-- if failures: memory.snapshot_restore("pre_refactor")
-- if success: memory.snapshot_diff("pre_refactor", "post_refactor") to review
```

### Pattern D: Register as Navigable Pointer
```
register.set("bug", "src/main.lua:142:8")   -- store a location
-- ... work elsewhere ...
register.jump_to("bug")                     -- jump back instantly
```

### Pattern E: Live Computed Register
```
register.set_expression("total", "vim.fn.line('$')")  -- bind expression
register.eval("total")  -- returns current line count, always up to date
```

### Pattern F: Before/After Audit
```
memory.snapshot_create("before")
-- ... edit ...
memory.snapshot_create("after")
memory.snapshot_diff("before", "after")
-- returns: {lines={added=3,removed=1,changed=5}, registers={a={from=..., to=...}}}
```

### Pattern G: Fast/Slow Recursive Loop
```
-- Fast layer finds something important
memory.remember("error_pattern", "nil check missing on L42")
-- Promote to slow (persist across rounds):
memory.promote("error_pattern", {type="pattern", tags={"bug","nil"}})
-- Later: slow guides fast
memory.guide()  -- returns high-confidence knowledge including our pattern
-- New round, fast recall falls back to slow:
local known = memory.recall("error_pattern")  -- found in slow!
-- Confirm and reinforce:
memory.learn("error_pattern", "... stronger evidence ...") -- confidence 0.5->0.65
```]]
end

-- ---------------------------------------------------------------------------
-- 8. DECISION GUIDANCE
-- ---------------------------------------------------------------------------
	local function prompt_guidance()
	  local last_line = config.ultracode
	    and "- Two reasonable approaches? Pick the MORE THOROUGH one. If both are equally valid, do both and compare. In ultracode mode, correctness beats speed."
	    or  "- Two reasonable approaches? Pick the faster one. An imperfect fix today beats a perfect plan tomorrow."
	  return [[## Decision Guide
	- Starting a new task? -> memory.tasks_init, then start immediately. Don't plan out loud -- execute step by step.
	- About to edit? -> undo.savepoint, then edit, then lsp.diagnostics. No need to explain -- just do it.
	- About to edit RISKY code (multi-file, regex, refactor)? -> snapshot_create first, then proceed.
	- Need to remember WHERE something is? -> memory.mark("key") or register.set("a", "file:line")
	- Need to remember WHAT you found? -> memory.remember("key", "value")
	- Need to explore then come back? -> memory.jump_push("why") before leaving
	- Operating on intermediate values (find -> filter -> replace)? -> register.push each step
	- Want to see the effect of your edit? -> snapshot_create before, snapshot_create after, snapshot_diff
	- Discovered something worth remembering? -> memory.learn(key, value, type, tags) -- persist to slow
	- Need to search slow memory? -> memory.query("pattern")
	- Need context for current situation? -> memory.guide() -- slow provides relevant guidance
	- Fast fact turning out to be important? -> memory.promote(key) -- fast->slow
	- Running a command? -> bash tool (prefer short commands; check exit_code)
	- Found a pattern to replace? -> vim.substitute (native regex, much faster than manual buffer.edit)
	]] .. last_line
	end

-- ---------------------------------------------------------------------------
-- 9. ULTRACODE (exhaustive mode)
-- ---------------------------------------------------------------------------
	local function prompt_ultracode()
	  if not config.ultracode then return nil end
	  return [[## Ultracode -- Exhaustive Mode

	You are operating in ULTRACODE mode. This means exhaustive analysis, adversarial verification, and zero shortcuts. The user wants the BEST answer -- correctness beats speed, every time.

	### Exhaustive Search Strategy
	Never rely on a single search angle. For every problem, search across MULTIPLE dimensions until you converge (no new findings for 2 consecutive rounds):
	- **By content**: grep for the target symbol, error message, or pattern
	- **By structure**: trace imports, callers, callees, and type hierarchies
	- **By naming**: search for related names, variants, and conventions (e.g. `get_*`, `set_*`, `handle_*`)
	- **By history**: check git log for recent changes to relevant files -- they often explain WHY code looks the way it does
	- **By proximity**: read adjacent files, sibling modules, and test fixtures
	If you only searched one way, you have blind spots. Search another way. Cover every angle before concluding.

	### Adversarial Verification
	After every finding, try to PROVE IT WRONG before acting on it:
	- "Is this really the root cause, or just a symptom?"
	- "Would my fix break any caller that relies on the current behavior?"
	- "Is there a simpler explanation that I'm overlooking?"
	- "What would a senior engineer say if they reviewed this finding?"
	At least 1/3 of your findings should fail adversarial review. If all your findings pass, you're not being skeptical enough.

	### Multi-Perspective Review
	Before calling work done, review the entire diff through four independent lenses:
	1. **Correctness**: Does the logic actually solve the problem? Are edge cases handled (nil, empty, boundary, concurrency)?
	2. **Security**: Could this introduce injection, information leak, or privilege issues?
	3. **Performance**: Is there unnecessary allocation, blocking I/O, O(n^2) where O(n) would work?
	4. **Edge cases**: What happens with zero-length input, missing files, network errors, Unicode, large datasets?
	Each lens is a separate pass. Do NOT combine them -- you will miss things.

	### Completeness Critic
	Before declaring "done", run a completeness check. Ask yourself:
	- "What modality have I NOT used?" (if you only read files, what about git log? lsp references? test output?)
	- "What files did I intentionally skip? Was that decision correct?"
	- "Are there tests I assumed pass but didn't run?"
	- "Did I update documentation, type annotations, and imports for every changed file?"
	- "If the user asked me to do X, did I also do the things X implicitly requires?"
	If you find gaps, go back and fill them. Don't hand over incomplete work.

	### No Silent Caps
	If you're forced to limit scope (top-N results, timeout, file count), say so EXPLICITLY:
	- "I checked the top 50 matches; there may be more" -- NOT "No issues found"
	- "I reviewed 3 of 12 affected callers: foo(), bar(), baz() -- the remaining 9 are unchecked"
	Never let a limit masquerade as completeness. The user must know what was NOT checked.

	### Depth Over Speed
	- Read entire files, not just the function signature. The bug often lives in the imports or the helper 20 lines down.
	- When in doubt, read one more file. When sure, double-check anyway.
	- Prefer multi-round depth: survey first, plan second, execute third, verify fourth.
	- An extra 3 minutes spent now saves 30 minutes of debugging later.

	### Finish the Job
	When you're done, the task should be FULLY resolved:
	- Tests pass (run them -- don't assume)
	- LSP diagnostics are clean on every touched file
	- No TODOs, FIXMEs, or "I'll handle this later" left behind
	- All related code (callers, tests, docs, configs) is updated, not just the one line the user pointed at
	- The user should not need to follow up with "you forgot X" -- because you didn't forget X.]]
	end
-- ---------------------------------------------------------------------------
-- 10. PHASE GATE (injected based on current phase)
-- ---------------------------------------------------------------------------
-- This section is dynamic: the builder selects one of EXPLORE / PLAN /
-- EXECUTE / VERIFY based on the current agent phase. Each phase prompt
-- overrides the generic Rules and Guidance to enforce phase-appropriate
-- behavior.

local function prompt_explore()
  return [[## Phase: EXPLORE -- Understand First

You are in the EXPLORE phase. Your ONLY job right now is to understand the problem. **DO NOT EDIT ANYTHING.**

**What you CAN do:**
- Read files (file.read, buffer.get) to build a complete mental model
- Run read-only shell commands (bash for git log, grep, ls, tests --dry-run)
- Observe editor state (observe, lsp.diagnostics, lsp.document_symbols)
- Query memory for relevant past knowledge (memory.query, memory.guide)
- Navigate and inspect (cursor.get, window.scroll, lsp.hover)

**What you CANNOT do:**
- Edit, write, delete, or modify anything
- Execute commands that have side effects
- Create buffers, change settings, or register expressions

**Exit criteria -- advance to PLAN when:**
1. You have read ALL files relevant to the task
2. You understand the code structure, dependencies, and conventions
3. You know what needs to change and why

**To advance:** call memory.remember("__agent_phase__", "plan")]]
end

local function prompt_plan()
  return [[## Phase: PLAN -- Design Before Doing

You are in the PLAN phase. Design the solution. **DO NOT EDIT CODE YET.**

**What you CAN do:**
- All EXPLORE tools (read, observe, inspect)
- Create and organize tasks (memory.tasks_init, memory.task_update)
- Store facts and plans in memory (memory.remember, memory.learn)
- Mark important locations (memory.mark, memory.jump_push)
- Run diagnostic commands (bash for test --list, build --check)

**What you CANNOT do:**
- Any edit, write, delete, or modification tool
- Command execution with side effects (no npm install, git commit, etc.)

**Exit criteria -- advance to EXECUTE when:**
1. Tasks are created with memory.tasks_init, each with a clear scope
2. The approach is designed: which files change, in what order, with what strategy
3. Risk points are identified and snapshots are planned

**To advance:** call memory.remember("__agent_phase__", "execute")]]
end

local function prompt_verify()
  return [[## Phase: VERIFY -- Check Your Work

You are in the VERIFY phase. Your job is to CHECK that your edits are correct and complete. **FOCUS ON FINDING ISSUES, not making more changes.**

**What you MUST do:**
1. Run lsp.diagnostics on every file you touched -- fix any errors
2. Run relevant tests (bash) -- if they fail, diagnose and fix
3. Review the diff between pre-edit and post-edit snapshots
4. Check that all tasks in memory.task_progress are marked "done"
5. Look for edge cases you might have missed

**If you find issues:** Fix them, then verify again.
**When clean:** Advance to DONE by marking all tasks as done and stopping.

**You are NOT done until verification passes.** LSP must be clean. Tests must pass.]]
end

local function prompt_phase_gate()
  local phase = get_current_phase()
  if phase == Phase.EXPLORE then
    return prompt_explore()
  elseif phase == Phase.PLAN then
    return prompt_plan()
  elseif phase == Phase.VERIFY then
    return prompt_verify()
  end
  -- EXECUTE phase: no special gate -- use the standard rules + ultracode if enabled
  return nil
end

-- ---------------------------------------------------------------------------
-- Main builder
-- ---------------------------------------------------------------------------
local function build_system_prompt()
  local phase = get_current_phase()
  local obs = editor.observe()
  local cf = obs.current_file

  -- Phase gate is ALWAYS first -- it sets the behavioral contract for this round.
  -- For EXECUTE phase it returns nil, so we fall through to standard behavior.
  local phase_gate = prompt_phase_gate()

  -- In EXPLORE and PLAN phases, suppress RULES ("ACT, don't ask") and GUIDANCE
  -- ("pick the faster one") -- they contradict the phase gate's deliberate pacing.
  -- In VERIFY phase, suppress RULES and GUIDANCE to focus on checking.
  local is_gated = phase == Phase.EXPLORE or phase == Phase.PLAN or phase == Phase.VERIFY

  local sections
  if phase == Phase.EXPLORE then
    -- Minimal prompt: phase gate + identity + state + read-only tool reference
    sections = {
      phase_gate,
      prompt_identity(),
      prompt_editor(obs, cf),
      prompt_environment(obs, cf),
      prompt_memory(),
      prompt_tools(),
      prompt_ultracode(),
    }
  elseif phase == Phase.PLAN then
    -- Add patterns (for task structuring) but keep rules/guidance suppressed
    sections = {
      phase_gate,
      prompt_identity(),
      prompt_editor(obs, cf),
      prompt_environment(obs, cf),
      prompt_memory(),
      prompt_tools(),
      prompt_patterns(),
      prompt_ultracode(),
    }
  elseif phase == Phase.VERIFY then
    -- Focus on diagnostics and test output; patterns and rules are noise
    sections = {
      phase_gate,
      prompt_identity(),
      prompt_editor(obs, cf),
      prompt_environment(obs, cf),
      prompt_memory(),
      prompt_tools(),
      prompt_ultracode(),
    }
  else
    -- EXECUTE: full prompt with all sections (standard behavior)
    sections = {
      prompt_identity(),
      prompt_rules(),
      prompt_editor(obs, cf),
      prompt_environment(obs, cf),
      prompt_memory(),
      prompt_tools(),
      prompt_patterns(),
      prompt_guidance(),
      prompt_ultracode(),
    }
  end

  -- Filter nil sections and join with double-newlines
  local non_empty = {}
  for _, s in ipairs(sections) do
    if s then non_empty[#non_empty + 1] = s end
  end

  return table.concat(non_empty, "\n\n")
end

-- ============================================================================
-- Tool Execution
-- ============================================================================

-- ============================================================================
-- Post-Edit Verification
-- ============================================================================
-- After any batch of edit tool calls, the loop automatically:
--   1. Creates a snapshot before the first edit (rewind point)
--   2. Runs LSP diagnostics on the affected buffer
--   3. Injects results as a system message the model CANNOT ignore
--   4. Tracks consecutive verification failures; rolls back after N attempts
--
-- This is loop-level enforcement, not a prompt-level suggestion.

local EDITED_BUFFERS = {}       -- buffers touched this batch
local VERIFY_ATTEMPTS = 0
local MAX_VERIFY_ATTEMPTS = 3

-- API-format names (underscores) of tools that modify buffer content.
-- These trigger auto-snapshot and post-edit diagnostics.
local EDIT_TOOL_NAMES = {
  buffer_edit = true, buffer_set = true, buffer_create = true,
  buffer_delete = true, file_write = true, file_ensure_open = true,
  vim_edit = true, vim_substitute = true, vim_normal = true,
  register_set = true, register_push = true, register_pop = true,
  command = true, feedkeys = true, lua = true,
}

local function is_edit_tool(api_name)
  return EDIT_TOOL_NAMES[api_name] == true
end

local PRE_EDIT_CONTENT = {}    -- { [filepath] = string[] }  pre-edit buffer content for diff

local function reset_verify_state()
  EDITED_BUFFERS = {}
  VERIFY_ATTEMPTS = 0
  PRE_EDIT_CONTENT = {}
end

-- ============================================================================
-- Edit Confirmation Helpers
-- ============================================================================

--- Resolve the target filepath from a tool call's parameters.
--- Returns a resolved absolute path or nil if the tool doesn't target a file.
---@param api_name string  Tool name in API format (underscores)
---@param params table     Parsed tool parameters
---@return string|nil filepath
local function resolve_tool_target_file(api_name, params)
  -- file_write / file_ensure_open / file_read: explicit filepath
  if api_name == "file_write" or api_name == "file_ensure_open" then
    local fp = params.filepath
    if fp and fp ~= "" then
      return vim.fn.resolve(vim.fn.expand(fp))
    end
    return nil
  end

  -- buffer.edit / buffer.set / buffer_create / buffer_delete: buf parameter
  if api_name == "buffer_edit" or api_name == "buffer_set"
    or api_name == "buffer_delete" or api_name == "buffer_create" then
    local buf = params.buf
    if buf and buf ~= 0 then
      local name = vim.api.nvim_buf_get_name(buf)
      if name and name ~= "" then return vim.fn.resolve(name) end
    end
    -- buf is 0 or nil: current buffer
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if name and name ~= "" then return vim.fn.resolve(name) end
    return nil
  end

  -- vim.edit / vim.substitute / vim.normal / command / feedkeys / lua:
  -- operate on current buffer
  if api_name == "vim_edit" or api_name == "vim_substitute"
    or api_name == "vim_normal" or api_name == "command"
    or api_name == "feedkeys" or api_name == "lua" then
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if name and name ~= "" then return vim.fn.resolve(name) end
    return nil
  end

  return nil
end

--- Capture buffer content for all files targeted by the tool calls.
--- Called BEFORE executing edit tools.
--- Tries buffer first, then filesystem, then empty (for new files).
---@param tool_calls table[]  Array of OpenAI-format tool calls
---@return table  { [filepath] = string[] }
local function capture_pre_edit_content(tool_calls)
  local content = {}
  for _, tc in ipairs(tool_calls) do
    local fn_block = tc["function"] or {}
    local api_name = fn_block.name or ""

    if is_edit_tool(api_name) then
      -- Parse arguments
      local args = fn_block.arguments
      if type(args) == "string" and #args > 0 then
        local ok, parsed = pcall(vim.json.decode, args)
        if ok and type(parsed) == "table" then args = parsed end
      end
      if type(args) ~= "table" then args = {} end

      local fp = resolve_tool_target_file(api_name, args)
      if fp and not content[fp] then
        -- 1) Try buffer first (file already open in Neovim)
        local ok_buf = editor.find_buffer_by_file(fp)
        if ok_buf then
          local lines = editor.buffer_get(ok_buf, 0, -1)
          if lines then
            content[fp] = lines
          end
        -- 2) Try filesystem (file exists but not open)
        elseif vim.loop.fs_stat(fp) then
          local fd = vim.loop.fs_open(fp, "r", 438)
          if fd then
            local stat = vim.loop.fs_fstat(fd)
            local data = vim.loop.fs_read(fd, stat.size, 0)
            vim.loop.fs_close(fd)
            if data then
              content[fp] = vim.split(data, "\n", { plain = true })
            else
              content[fp] = {}
            end
          else
            content[fp] = {}
          end
        -- 3) File doesn't exist at all (new file) -- use empty content
        else
          content[fp] = {}
        end
      end
    end
  end
  return content
end

--- Collect unified diffs for all files that had pre-edit content captured.
--- Called AFTER executing all edit tools.
--- Tries buffer first, then filesystem, then empty.
---@param pre_content table  { [filepath] = string[] }
---@return table[]  Array of {filepath, hunks, added, removed, unchanged, file_too_large}
local function collect_edit_diffs(pre_content)
  local diffs = {}
  for fp, old_lines in pairs(pre_content) do
    -- Get post-edit content: try buffer first, then filesystem
    local new_lines = {}
    local buf = editor.find_buffer_by_file(fp)
    if buf then
      local ok, lines = pcall(editor.buffer_get, buf, 0, -1)
      if ok and lines then new_lines = lines end
    elseif vim.loop.fs_stat(fp) then
      -- File exists on disk but not in a buffer
      local fd = vim.loop.fs_open(fp, "r", 438)
      if fd then
        local stat = vim.loop.fs_fstat(fd)
        local data = vim.loop.fs_read(fd, stat.size, 0)
        vim.loop.fs_close(fd)
        if data then
          new_lines = vim.split(data, "\n", { plain = true })
        end
      end
    end

    local diff = editor.compute_unified_diff(old_lines, new_lines)
    local result = {
      filepath = fp,
      hunks = diff.hunks,
      added = diff.added,
      removed = diff.removed,
      unchanged = diff.unchanged,
      file_too_large = diff.file_too_large,
    }
    -- Only include files that actually changed
    if not result.unchanged or result.file_too_large then
      diffs[#diffs + 1] = result
    end
  end
  return diffs
end

-- Called BEFORE executing edit tools: creates a snapshot as rewind point.
local function pre_edit_snapshot(tool_calls)
  -- Only snapshot if any tool is an edit tool and we don't already have one
  local has_edit = false
  for _, tc in ipairs(tool_calls) do
    local fn = tc["function"] or {}
    local api_name = fn.name or ""
    if is_edit_tool(api_name) then
      has_edit = true
      break
    end
  end
  if not has_edit then return end

  -- Check if we already have an active pre-edit snapshot from a previous round.
  -- If VERIFY_ATTEMPTS > 0, we're in a fix cycle and should reuse the original.
  if VERIFY_ATTEMPTS == 0 then
    memory.snapshot_create("__auto_pre_edit__", "auto-snapshot before edit batch")
  end
end

-- Called AFTER executing tools: runs diagnostics and injects verification.
local function post_edit_verify()
  if next(EDITED_BUFFERS) == nil then return nil end

  -- Run diagnostics on the buffer with the most recent edit
  local buf = vim.api.nvim_get_current_buf()
  local diags = {}
  local ok_diag = pcall(function()
    diags = editor.lsp_diagnostics(buf)
  end)
  if not ok_diag then return nil end

  -- Count errors (severity 1)
  local errors = {}
  for _, d in ipairs(diags) do
    if d.severity and d.severity <= 1 then
      errors[#errors + 1] = d
    end
  end

  if #errors == 0 then
    -- Clean: reset verification counter, but do NOT clear EDITED_BUFFERS.
    -- The edit confirmation and phase advancement downstream depend on it.
    VERIFY_ATTEMPTS = 0
    return nil
  end

  -- Errors found: increment counter and inject system message (LLM-only, not shown in chat)
  VERIFY_ATTEMPTS = VERIFY_ATTEMPTS + 1
  local fname = vim.api.nvim_buf_get_name(buf):match("[^/]+$") or "buffer"
  local summary_lines = { string.format("%d LSP error(s) in %s:", #errors, fname) }
  for i = 1, math.min(5, #errors) do
    local d = errors[i]
    summary_lines[#summary_lines + 1] = string.format("  L%d: %s", d.lnum, d.message:sub(1, 100))
  end
  if #errors > 5 then
    summary_lines[#summary_lines + 1] = string.format("  ... and %d more", #errors - 5)
  end

  if VERIFY_ATTEMPTS >= MAX_VERIFY_ATTEMPTS then
    -- Roll back to pre-edit snapshot
    memory.snapshot_restore("__auto_pre_edit__")
    VERIFY_ATTEMPTS = 0
    EDITED_BUFFERS = {}
    return string.format(
      "[SYSTEM] After %d fix attempts, %d error(s) remain. " ..
      "Your changes have been REVERTED to the pre-edit snapshot. " ..
      "Reconsider your approach.\n\nErrors:\n%s",
      MAX_VERIFY_ATTEMPTS, #errors, table.concat(summary_lines, "\n")
    )
  end

  return string.format(
    "[SYSTEM] Your edit batch introduced %d LSP error(s). " ..
    "You MUST fix these before continuing. " ..
    "Attempt %d of %d.\n\n%s",
    #errors, VERIFY_ATTEMPTS, MAX_VERIFY_ATTEMPTS, table.concat(summary_lines, "\n")
  )
end

-- ============================================================================
-- Tool Result Introspection
-- ============================================================================
-- Raw tool results (JSON strings, sometimes tens of KB) are preprocessed
-- before the model sees them. This prevents the model from:
--   - Missing errors buried in large outputs
--   - Ignoring exit codes / diagnostic counts
--   - Getting overwhelmed by 50K+ byte results
--
-- Each tool type gets a structured summary. Errors are surfaced prominently.

local function introspect_tool_result(tc, tr)
  local fn = tc["function"] or {}
  local api_name = fn.name or "?"

  -- 1. Error: surface prominently so the model cannot ignore it
  if tr.is_error then
    return string.format(
      "[TOOL FAILED: %s]\n%s\n\nAction required: check parameters and retry, or use an alternative tool.",
      api_name, tr.content
    )
  end

  local content = tr.content or ""
  if content == "" then return "" end

  -- 2. Parse JSON for structured introspection
  local has_parsed, parsed = false, nil
  if content:sub(1, 1) == "{" then
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then
      has_parsed, parsed = true, decoded
    end
  end

  -- 3. Tool-specific introspection
  -- Diagnostics: surface error count
  if api_name:find("lsp_diagnostics") and has_parsed then
    local errs = 0
    for _, d in ipairs(parsed) do
      if type(d) == "table" and d.severity and d.severity <= 1 then errs = errs + 1 end
    end
    if errs > 0 then
      return string.format("[LSP DIAGNOSTICS] %d error(s) found.\n%s", errs,
        content:sub(1, 2000))
    end
    return "[LSP DIAGNOSTICS] Clean -- no errors."

  -- Bash: surface exit code
  elseif api_name:find("bash") and has_parsed then
    local code = parsed.exit_code or 0
    local out = parsed.stdout or ""
    local prefix = code == 0 and "[BASH: exit 0]" or string.format("[BASH: exit %d -- FAILED]", code)
    if #out > 3000 then out = out:sub(1, 3000) .. "\n...[truncated]" end
    return prefix .. "\n" .. out

  -- File read: summary header
  elseif api_name:find("file_read") and has_parsed then
    local count = parsed.line_count or 0
    local total = parsed.total_lines or count
    local formatted = parsed.formatted or content
    if #formatted > 8000 then
      formatted = formatted:sub(1, 8000) .. "\n...[truncated " .. (#formatted - 8000) .. " bytes]"
    end
    return string.format("[FILE READ] %d lines (total file: %d lines)\n%s", count, total, formatted)

  -- Observe / state.observe: keep but mark size
  elseif (api_name:find("observe") or api_name:find("state_observe")) and has_parsed then
    if #content > 6000 then
      return content:sub(1, 6000) .. "\n...[state snapshot truncated, " .. (#content - 6000) .. " bytes]"
    end
    return content
  end

  -- 4. Default: truncate oversized results
  if #content > 10000 then
    return content:sub(1, 10000) .. "\n...[truncated " .. (#content - 10000) .. " bytes]"
  end
  return content
end

-- ============================================================================
-- Observation
-- ============================================================================

local last_obs = {}
local function reset_diff_obs()
  last_obs = { ticks = {} }
end

local function inject_observation(is_first)
  if is_first then
    local obs = editor.observe()
    local cf = obs.current_file
    reset_diff_obs()
    if cf and cf.name ~= "" then
      last_obs.current_file = cf.name
      for _, b in ipairs(obs.buffers or {}) do
        if b.name ~= "" then
          local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, b.id)
          if ok then last_obs.ticks[b.id] = tick end
        end
      end
    end
    local parts = {}
    if cf and cf.name ~= "" then
      parts[#parts + 1] = "File: " .. cf.name .. " (" .. (cf.filetype or "?") .. ") " .. cf.line_count .. "L"
      parts[#parts + 1] = "Cursor: L" .. (cf.cursor and cf.cursor.row or "?")
      if cf.modified then parts[#parts + 1] = "Modified" end
    end
    if obs.diagnostics then
      local errs = 0
      for _, d in ipairs(obs.diagnostics) do if d.severity and d.severity <= 1 then errs = errs + 1 end end
      if errs > 0 then parts[#parts + 1] = string.format("Diags: %dE", errs) end
    end
    return table.concat(parts, " | ")
  end
  return "[State unchanged]"
end

-- ============================================================================
-- Completion Verification
-- ============================================================================
-- Before the loop terminates (no more tool calls from the model), this
-- function checks whether the task is actually complete. If not, it
-- returns a summary that gets injected to continue the loop.

local function verify_completion()
  local issues = {}

  -- 1. Task progress: are all tasks done?
  local progress = memory.task_progress()
  if progress.total > 0 and progress.done < progress.total then
    local pending_tasks = {}
    for _, t in ipairs(progress.tasks) do
      if t.status ~= "done" then
        pending_tasks[#pending_tasks + 1] = string.format("%s (%s)", t.id, t.status)
      end
    end
    if #pending_tasks > 0 then
      issues[#issues + 1] = string.format(
        "%d/%d tasks NOT done: %s",
        progress.total - progress.done, progress.total,
        table.concat(pending_tasks, ", ")
      )
    end
  end

  -- 2. LSP diagnostics: any errors on current buffer?
  local buf = vim.api.nvim_get_current_buf()
  local ok_diag, diags = pcall(editor.lsp_diagnostics, buf)
  if ok_diag then
    local errs = 0
    for _, d in ipairs(diags) do
      if d.severity and d.severity <= 1 then errs = errs + 1 end
    end
    if errs > 0 then
      issues[#issues + 1] = string.format("%d LSP error(s) remain in current buffer", errs)
    end
  end

  -- 3. Unsaved buffers?
  local unsaved = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local modified = vim.api.nvim_get_option_value("modified", { buf = b })
      if modified then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" then
          unsaved[#unsaved + 1] = name:match("[^/]+$") or name
        end
      end
    end
  end
  if #unsaved > 0 then
    issues[#issues + 1] = string.format("%d unsaved buffer(s): %s", #unsaved, table.concat(unsaved, ", "))
  end

  if #issues == 0 then
    return { all_done = true }
  end

  return {
    all_done = false,
    summary = "[SYSTEM] Work is incomplete:\n  - " .. table.concat(issues, "\n  - ") ..
              "\n\nContinue until all issues are resolved. Call memory.task_update to mark tasks done."
  }
end

-- ============================================================================
-- Agent Loop
-- ============================================================================

local loop

loop = function()
  if abort_flag then running = false; return end
  round = round + 1

  if round > config.max_rounds then
    chat.show_error("Max rounds reached")
    running = false; return
  end

  compress_context()

  -- Auto-checkpoint
  if round > 1 and round % config.checkpoint_interval == 0 then
    vim.schedule(function()
      local ok_cp, cp = pcall(require, "xaster.checkpoint")
      if ok_cp then cp.save({ round = round, messages = messages, compressed_count = compressed_count }) end
    end)
  end

  local system = build_system_prompt()
  local tools = toolformat.get_tools()

  -- Phase-based tool filtering: restrict tools in EXPLORE and PLAN phases
  -- Uses blocklist approach: all tools EXCEPT buffer-modifying ones are available.
  local phase = get_current_phase()
  if phase == Phase.EXPLORE or phase == Phase.PLAN then
    local allowed = build_readonly_tool_names()
    tools = toolformat.get_tools_filtered(allowed)
  end
  -- EXECUTE and VERIFY: full tool set (no phase-based restriction)

  -- Limit tools for DeepSeek: INTERSECT with phase-filtered tools.
  -- This keeps phase gating intact while reducing tool count for DeepSeek.
  if llm.get_model():find("deepseek") then
    local keep = {}
    for _, n in ipairs(DEEPSEEK_ESSENTIAL_TOOLS) do keep[n] = true end
    local filtered = {}
    for _, t in ipairs(tools) do
      if keep[t["function"].name] then
        filtered[#filtered + 1] = t
      end
    end
    tools = filtered
  end

  chat.show_thinking()

  local ok_send, send_err = pcall(function()
    handle = llm.send_message(
      { system = system, messages = messages, tools = tools },
      {
        on_text = function(chunk) chat.append_stream_text(chunk) end,
        on_thinking = function(chunk) chat.append_think_text(chunk) end,
        on_tool_start = function(id, name) end,  -- handled in on_complete

        on_complete = function(response)
          local ok_cb, err_cb = pcall(function()
            vim.schedule(function()
              chat.hide_thinking()

              if response.usage then
                token_usage.last_api_input = response.usage.input_tokens or 0
                token_usage.last_api_output = response.usage.output_tokens or 0
              end

              local content_blocks = response.content or {}
              local text_parts = {}
              local tool_calls = {}

              -- Separate text from tool calls. Tool calls MUST go through
              -- the assistant's tool_calls field, not mixed into content.
              for _, block in ipairs(content_blocks) do
                if block.type == "text" and block.text then
                  text_parts[#text_parts + 1] = block.text
                elseif block.type == "function" then
                  local fn = block["function"] or {}
                  -- Normalize: ensure id is a string and arguments is a JSON string
                  local tc_id = block.id
                  if tc_id and tc_id ~= vim.NIL then
                    tc_id = tostring(tc_id)
                  else
                    -- Generate a synthetic id so tool_result always has tool_call_id
                    tc_id = "call_" .. tostring(os.time()) .. "_" .. tostring(#tool_calls + 1)
                  end
                  local args = fn.arguments
                  if type(args) == "table" then
                    local ok, encoded = pcall(vim.fn.json_encode, args)
                    args = ok and encoded or "{}"
                  elseif type(args) ~= "string" then
                    args = "{}"
                  end
                  tool_calls[#tool_calls + 1] = {
                    id = tc_id,
                    type = "function",
                    ["function"] = { name = fn.name or "?", arguments = args },
                  }
                end
              end

              -- Build the assistant message: text in content, tool_calls separately.
              -- OpenAI format: {role:"assistant", content:<string|null>, tool_calls:[...]}
              -- Tool calls MUST be in the tool_calls field, never in content.
              local assistant_msg = { role = "assistant" }
              if #text_parts > 0 then
                assistant_msg.content = table.concat(text_parts, "\n")
              end
              if #tool_calls > 0 then
                assistant_msg.tool_calls = tool_calls
              end
              if assistant_msg.content or assistant_msg.tool_calls then
                messages[#messages + 1] = assistant_msg
              end

              if #tool_calls > 0 then
                -- Respect abort: if user hit stop during a retry, discard tool calls
                if abort_flag then running = false; return end

                -- Auto-snapshot before first edit (rewind point).
                -- Must happen BEFORE tool execution so we capture pre-edit state.
                pre_edit_snapshot(tool_calls)

                -- Capture pre-edit buffer content for diff display (confirmation mode)
                local pre_content = {}
                if config.confirm_edits then
                  pre_content = capture_pre_edit_content(tool_calls)
                end

                chat.show_tool_status(tool_calls)
                chat.focus_editor()
                vim.cmd("redraw!")

                -- Execute each tool call, respond with a tool-result message.
                -- Protocol: assistant(tool_calls) MUST be followed by
                -- tool(tool_call_id=...) messages BEFORE any user message.
                -- {role:"tool", tool_call_id:<string>, content:<string>}
                for _, tc in ipairs(tool_calls) do
                  local tr = toolformat.execute_tool_call(tc)
                  -- Introspect tool result: errors surfaced, large outputs
                  -- truncated, diagnostics/bach results structured for the model.
                  local introspected = introspect_tool_result(tc, tr)
                  messages[#messages + 1] = {
                    role = "tool",
                    tool_call_id = tc.id,
                    content = introspected,
                  }
                  -- Track edited buffers for post-edit verification
                  local fn = tc["function"] or {}
                  if is_edit_tool(fn.name or "") then
                    EDITED_BUFFERS[vim.api.nvim_get_current_buf()] = true
                  end
                  vim.cmd("redraw!")
                end

                -- Post-edit verification: if any edit tool was called, run
                -- LSP diagnostics and inject results. The model CANNOT ignore
                -- this -- it arrives as a user message mid-loop.
                -- Does NOT clear EDITED_BUFFERS — the confirmation and phase
                -- advancement below still need it.
                local verify_msg = post_edit_verify()
                if verify_msg then
                  messages[#messages + 1] = { role = "user", content = verify_msg, _skip_chat = true }
                end

                -- Phase auto-advancement:
                -- 1. EXPLORE -> PLAN: when agent has created a task list
                -- 2. EXECUTE -> VERIFY: when edits were made
                local phase = get_current_phase()
                if phase == Phase.EXPLORE then
                  local progress = memory.task_progress()
                  if progress.total > 0 then
                    set_current_phase(Phase.PLAN)
                  end
                elseif phase == Phase.EXECUTE and next(EDITED_BUFFERS) ~= nil then
                  set_current_phase(Phase.VERIFY)
                end

                -- Shared cleanup after confirmation/rejection: clear tool status,
                -- reset edit tracking, re-focus input.
                local function finish_edit_batch()
                  chat.clear_tool_status()
                  EDITED_BUFFERS = {}
                  VERIFY_ATTEMPTS = 0
                  chat.focus_input()
                end

                -- Continue the agent loop
                local function continue_loop()
                  if not abort_flag then vim.schedule(loop) else running = false end
                end

                -- Edit confirmation: show diff and ask user to accept/reject
                if config.confirm_edits and next(EDITED_BUFFERS) ~= nil then
                  local diffs = collect_edit_diffs(pre_content)
                  if #diffs > 0 then
                    chat.confirm_edits(diffs, function(result)
                      if result == "accept" then
                        finish_edit_batch()
                        messages[#messages + 1] = { role = "user", content = "[SYSTEM] Edits accepted by user. Continue the task.", _skip_chat = true }
                        continue_loop()
                      elseif result == "abort" then
                        -- User aborted — restore snapshot and STOP the agent entirely
                        memory.snapshot_restore("__auto_pre_edit__")
                        finish_edit_batch()
                        messages[#messages + 1] = { role = "user", content = "[SYSTEM] Edits aborted by user. Agent stopped.", _skip_chat = true }
                        chat.end_stream()
                        running = false
                        chat.focus_input()
                      else
                        -- User rejected — restore pre-edit snapshot, keep going
                        memory.snapshot_restore("__auto_pre_edit__")
                        finish_edit_batch()
                        messages[#messages + 1] = { role = "user", content = "[SYSTEM] Edits rejected by user. Changes reverted. Reconsider your approach or ask for clarification.", _skip_chat = true }
                        continue_loop()
                      end
                    end)
                  else
                    -- No visible changes — skip confirmation
                    finish_edit_batch()
                    continue_loop()
                  end
                else
                  -- Non-confirmation mode or no edit tools called
                  chat.clear_tool_status()
                  chat.focus_input()
                  EDITED_BUFFERS = {}
                  VERIFY_ATTEMPTS = 0
                  continue_loop()
                end
              else
                -- Model returned no tool calls -- it claims to be done.
                -- Verify completeness before actually terminating.
                local completion = verify_completion()
                if not completion.all_done then
                  messages[#messages + 1] = { role = "user", content = completion.summary }
                  if not abort_flag then vim.schedule(loop) else running = false end
                else
                  chat.end_stream()
                  running = false
                  chat.focus_input()
                  vim.schedule(function()
                    vim.notify("[xaster] Task complete -- all tasks done, no errors.", vim.log.levels.INFO)
                  end)
                end
              end
            end)
          end)
          if not ok_cb then
            log.error("on_complete failed", { error = tostring(err_cb) })
            pcall(chat.show_error, tostring(err_cb))
            running = false
          end
        end,

        on_error = function(code, msg, retryable)
          vim.schedule(function()
            chat.hide_thinking()
            local tier = classify_error(code)
            log.error("llm error", { code = code, msg = msg, tier = tier })

            if tier == ErrorTier.TRANSIENT then
              messages[#messages + 1] = { role = "user", content = "[System: " .. (msg or "error") .. ". Continue.]" }
              vim.schedule(loop)
            elseif tier == ErrorTier.RECOVERABLE then
              messages[#messages + 1] = { role = "user", content = "[System: " .. (msg or "error") .. ". Try alternative.]" }
              vim.schedule(loop)
            else
              chat.show_error(msg or "Fatal error")
              running = false
            end
          end)
        end,
      }
    )
  end)

  if not ok_send then
    log.error("send_message failed", { error = tostring(send_err) })
    vim.schedule(function()
      chat.hide_thinking()
      chat.show_error("Failed to send: " .. tostring(send_err))
      running = false
    end)
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

function M.send_message(text)
  if running then chat.show_error("Agent busy"); return end
  if not llm.is_configured() then chat.show_error("No API key"); return end

  abort_flag = false; running = true; round = 0; compressed_count = 0
  token_usage = { last_api_input = 0, last_api_output = 0 }
  circuit_state = {}
  reset_verify_state()

  -- For new conversations (empty history), start in EXPLORE phase.
  -- This enforces "understand first, edit later" -- the agent must read
  -- the codebase before it can advance to PLAN and then EXECUTE.
  -- Multi-turn conversations preserve the existing phase.
  if #messages == 0 then
    set_current_phase(Phase.EXPLORE)
  end

  log.info("agent starting", { model = llm.get_model(), history_size = #messages, phase = get_current_phase() })
  -- Append to existing history so multi-turn conversations share full context.
  -- Previous turns' user+assistant+tool messages are preserved.
  messages[#messages + 1] = { role = "user", content = text .. "\n\n" .. inject_observation(true) }
  loop()
end

function M.stop()
  abort_flag = true
  if handle then handle.kill(); handle = nil end
  running = false
  chat.end_stream()
  -- Kill any in-flight retry at the LLM layer (belt and suspenders)
  local ok_llm, llm_mod = pcall(require, "xaster.llm")
  if ok_llm and llm_mod.stop then llm_mod.stop() end
end

function M.clear_history()
  if running then M.stop() end
  messages = {}; memory.clear(); round = 0; compressed_count = 0
  circuit_state = {}
  token_usage = { last_api_input = 0, last_api_output = 0 }
  set_current_phase(Phase.EXPLORE)
  reset_verify_state()
  chat.clear()
end

function M.is_running() return running end

-- -- Phase control (public API) ---------------------------------------------

--- Set the agent phase. The new phase takes effect on the next round.
--- Valid phases: "explore", "plan", "execute", "verify".
---@param phase_name string
function M.set_phase(phase_name)
  local p = phase_name and phase_name:lower()
  if p and Phase[p:upper()] then
    set_current_phase(p)
    log.info("phase changed", { phase = p })
  end
end

--- Get the current agent phase.
---@return string  "explore" | "plan" | "execute" | "verify"
function M.get_phase()
  return get_current_phase()
end

function M.observe()
  return {
    running = running, round = round, max_rounds = config.max_rounds,
    messages_count = #messages, compressed_count = compressed_count,
    est_tokens = llm.count_context_tokens(messages, nil),
    token_limit = llm.get_context_limit(),
    api_input_tokens = token_usage.last_api_input,
    api_output_tokens = token_usage.last_api_output,
    circuit_state = vim.deepcopy(circuit_state),
    phase = get_current_phase(),
  }
end

function M._restore_state(state)
  messages = state.messages or {}; round = state.round or 0
  compressed_count = state.compressed_count or 0
  circuit_state = {}
end

function M.cleanup() M.stop(); messages = {}; memory.clear() end

return M
