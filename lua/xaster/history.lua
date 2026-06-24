local compat = require("xaster.compat")
--- xaster/history.lua
--- Operation history + hook/middleware system.
---
--- Every tool call that the Agent makes is intercepted, recorded, and auditable.
--- This turns xaster's own runtime into observable state -- the Agent can
--- introspect its own actions through the same RPC interface.
---
--- Architecture:
---   tools.dispatch  ->  pre-hooks  ->  tool handler  ->  post-hooks  ->  history
---                         ^ can cancel/modify          ^ log, emit events
---
--- Events emitted (via events.lua):
---   tool.call   -- before execution (params)
---   tool.result -- after execution (result, elapsed)
---
--- Hook types:
---   pre(tool_name, params) -> params | nil   (nil = cancel the call)
---   post(tool_name, params, result, elapsed_ms)

local M = {}

-- ============================================================================
-- History Ring Buffer
-- ============================================================================

---@class HistoryEntry
---@field seq integer           Monotonically increasing sequence number
---@field time number           os.time() when executed
---@field tool string           Tool name
---@field params table          Parameters (sanitized, truncated if large)
---@field result table|nil      Result (ok + data, or nil if error)
---@field error table|nil       Error info if failed
---@field elapsed_ms number     Execution time in milliseconds
---@field buf integer|nil       Affected buffer (extracted from params)
---@field filename string|nil   Affected filename

local history = {}       -- ring buffer
local max_entries = 1000
local sequence = 0

--- Add an entry to the history ring buffer.
--- Automatically trims oldest entries when exceeding max_entries.
---@param entry HistoryEntry
local function add_entry(entry)
  sequence = sequence + 1
  entry.seq = sequence
  entry.time = os.time()

  -- Extract affected buffer/filename
  if entry.params then
    local buf = entry.params.buf
    if buf and buf ~= 0 and vim.api.nvim_buf_is_valid(buf) then
      entry.buf = buf
      entry.filename = vim.api.nvim_buf_get_name(buf)
    elseif not buf or buf == 0 then
      local cb = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(cb) then
        entry.buf = cb
        entry.filename = vim.api.nvim_buf_get_name(cb)
      end
    end
  end

  table.insert(history, entry)

  -- Trim if over limit
  while #history > max_entries do
    table.remove(history, 1)
  end
end

-- ============================================================================
-- Parameter Sanitization (for safe storage + avoid massive entries)
-- ============================================================================

local MAX_PARAM_LENGTH = 5000  -- characters

--- Sanitize params for storage: truncate large values, mask sensitive data.
---@param params table
---@return table
local function sanitize_params(params)
  if not params then return {} end
  if type(params) ~= "table" then return { value = tostring(params) } end

  local result = {}
  for k, v in pairs(params) do
    if type(v) == "string" then
      if #v > 500 then
        result[k] = v:sub(1, 500) .. "...[" .. #v .. " chars]"
      else
        result[k] = v
      end
    elseif type(v) == "table" then
      local count = 0
      for _ in pairs(v) do count = count + 1 end
      result[k] = "[table:" .. count .. " elements]"
    elseif type(v) == "function" then
      result[k] = "[function]"
    else
      result[k] = v
    end
  end
  return result
end

--- Sanitize result for storage.
---@param result any
---@return any
local function sanitize_result(result)
  if result == nil then return nil end
  if type(result) == "table" then
    -- For tables, keep the structure but truncate strings
    if type(result.ok) ~= "nil" then
      -- Looks like a standard response {ok, data/error}
      return {
        ok = result.ok,
        summary = type(result.data) == "table" and ("[table:" .. compat.tbl_count(result.data) .. " keys]") or
                  type(result.data) == "string" and (#result.data > 200 and result.data:sub(1, 200) .. "..." or result.data) or
                  tostring(result.data),
      }
    end
    return { summary = "[result table:" .. compat.tbl_count(result) .. " keys]" }
  end
  if type(result) == "string" and #result > 200 then
    return result:sub(1, 200) .. "..."
  end
  return result
end

-- ============================================================================
-- Hook Registry
-- ============================================================================

---@class Hook
---@field type string        "pre" | "post"
---@field callback function
---@field priority integer   Higher = runs first
---@field id string|nil      Unique id for removal

local hooks = { pre = {}, post = {} }
local hook_id_counter = 0

--- Register a hook.
---@param hook_type string  "pre" | "post"
---@param callback function
---@param opts table|nil    { priority: integer, id: string }
---@return string hook_id   For later removal
function M.register_hook(hook_type, callback, opts)
  opts = opts or {}
  hook_id_counter = hook_id_counter + 1
  local id = opts.id or ("hook_" .. hook_id_counter)
  table.insert(hooks[hook_type], {
    id = id,
    callback = callback,
    priority = opts.priority or 0,
  })
  -- Sort by priority descending
  table.sort(hooks[hook_type], function(a, b) return a.priority > b.priority end)
  return id
end

--- Remove a hook by id.
---@param hook_type string  "pre" | "post"
---@param hook_id string
---@return boolean found
function M.remove_hook(hook_type, hook_id)
  for i, h in ipairs(hooks[hook_type]) do
    if h.id == hook_id then
      table.remove(hooks[hook_type], i)
      return true
    end
  end
  return false
end

--- Run all pre-hooks. Returns modified params, or nil if cancelled.
---@param tool_name string
---@param params table
---@return table|nil  Modified params, or nil to cancel
function M.run_pre_hooks(tool_name, params)
  local current_params = params or {}
  for _, hook in ipairs(hooks.pre) do
    local ok, result = pcall(hook.callback, tool_name, current_params)
    if not ok then
      -- Hook error: log but continue
      vim.notify("[xaster] pre-hook error (" .. (hook.id or "?") .. "): " .. tostring(result),
                 vim.log.levels.WARN)
    elseif result == nil then
      -- Hook returned nil: cancel the tool call
      return nil
    elseif type(result) == "table" then
      -- Hook returned modified params
      current_params = result
    end
    -- If hook returns true or other non-table, keep current params unchanged
  end
  return current_params
end

--- Run all post-hooks.
---@param tool_name string
---@param params table
---@param result any
---@param elapsed_ms number
function M.run_post_hooks(tool_name, params, result, elapsed_ms)
  for _, hook in ipairs(hooks.post) do
    pcall(hook.callback, tool_name, params, result, elapsed_ms)
  end
end

-- ============================================================================
-- Event Emission (for tool.call / tool.result)
-- ============================================================================

-- We use events.lua's internal notification mechanism.
-- To avoid circular requires, we use a lazy access pattern.
local function emit_event(event_name, payload)
  local ok, events_mod = pcall(require, "xaster.events")
  if ok and events_mod and events_mod.emit then
    events_mod.emit(event_name, payload)
  end
end

-- ============================================================================
-- Public API (called by tools.lua dispatch)
-- ============================================================================

-- Tools whose execution may modify registers (yank, delete, change = side effects)
local REGISTER_AFFECTING_TOOLS = {
  ["buffer.edit"] = true, ["buffer.set"] = true, ["buffer.delete"] = true,
  ["vim.edit"] = true, ["vim.substitute"] = true, ["file.write"] = true,
  ["register.set"] = true, ["register.push"] = true, ["register.pop"] = true,
  ["command"] = true, ["feedkeys"] = true, ["vim.normal"] = true,
}

--- Snapshot values of named registers (a-z) before an edit.
--- Returns a table { [reg]: value } for later diff.
local function snapshot_registers()
  local regs = {}
  for ch = 97, 122 do  -- a-z
    local reg = string.char(ch)
    local ok, val = pcall(vim.fn.getreg, reg)
    if ok and val and val ~= "" then
      regs[reg] = val
    end
  end
  return regs
end

--- Diff register snapshots: returns which registers changed.
---@param before table
---@param after table
---@return table|nil  { added, removed, changed } or nil if no changes
local function diff_registers(before, after)
  local added, removed, changed = {}, {}, {}
  for reg, val in pairs(after) do
    if not before[reg] then
      added[reg] = #val > 100 and val:sub(1, 100) .. "..." or val
    elseif before[reg] ~= val then
      changed[reg] = {
        from = #before[reg] > 80 and before[reg]:sub(1, 80) .. "..." or before[reg],
        to = #val > 80 and val:sub(1, 80) .. "..." or val,
      }
    end
  end
  for reg, val in pairs(before) do
    if not after[reg] then
      removed[reg] = #val > 100 and val:sub(1, 100) .. "..." or val
    end
  end
  if next(added) or next(removed) or next(changed) then
    return { added = added, removed = removed, changed = changed }
  end
  return nil
end

--- Intercept a tool call. Runs pre-hooks, executes the handler,
--- runs post-hooks, records to history.
--- Returns the result and whether it was cancelled.
---@param tool_name string
---@param original_params table
---@param handler fun(params: table): any  The actual tool handler
---@return table result  { ok = true, data = ... } or { ok = false, error = "..." }
function M.intercept(tool_name, original_params, handler)
  local start_time = vim.loop.hrtime()

  -- Run pre-hooks
  local params = M.run_pre_hooks(tool_name, original_params)
  if params == nil then
    -- Cancelled by pre-hook
    local result = { ok = false, error = "cancelled by hook" }
    add_entry({
      tool = tool_name,
      params = sanitize_params(original_params),
      result = nil,
      error = { code = -32000, message = "cancelled by pre-hook" },
      elapsed_ms = 0,
    })
    return result
  end

  -- Emit tool.call event
  emit_event("tool.call", {
    tool = tool_name,
    params = sanitize_params(params),
  })

  -- Snapshot registers before execution (for editing tools)
  local regs_before = nil
  if REGISTER_AFFECTING_TOOLS[tool_name] then
    regs_before = snapshot_registers()
  end

  -- Execute the handler.
  -- Capture all return values: handlers use the convention "return nil, err"
  -- for soft errors, which pcall(handler, params) returns as (true, nil, err).
  -- A two-value capture (ok, result) silently drops the error string.
  local pcall_results = { pcall(handler, params) }
  local ok = pcall_results[1]
  local handler_result = pcall_results[2]
  local handler_err = pcall_results[3]  -- nil on success, error string on soft-error

  local elapsed_ms = math.floor((vim.loop.hrtime() - start_time) / 1e6)

  -- Compute register delta for editing tools
  local register_delta = nil
  if regs_before then
    local regs_after = snapshot_registers()
    register_delta = diff_registers(regs_before, regs_after)
  end

  -- Build result
  local final_result
  if ok and handler_err == nil then
    -- Normal success or soft-success (handler returned non-nil)
    final_result = { ok = true, data = handler_result }
  elseif ok and handler_result == nil and handler_err ~= nil then
    -- Soft-error pattern: handler returned (nil, error_message)
    final_result = { ok = false, error = tostring(handler_err) }
  else
    -- Hard error: handler threw via error()
    final_result = { ok = false, error = tostring(handler_result) }
  end

  -- Emit tool.result event
  emit_event("tool.result", {
    tool = tool_name,
    ok = ok,
    elapsed_ms = elapsed_ms,
    summary = ok and sanitize_result(handler_result) or tostring(handler_result),
  })

  -- Run post-hooks
  M.run_post_hooks(tool_name, params, final_result, elapsed_ms)

  -- Record to history (include register delta for editing tools)
  add_entry({
    tool = tool_name,
    params = sanitize_params(params),
    result = final_result.ok and sanitize_result(handler_result) or nil,
    error = not final_result.ok and { message = final_result.error } or nil,
    elapsed_ms = elapsed_ms,
    register_delta = register_delta,
  })

  -- Auto-update virtual cursor if this is a cursor-moving or editing tool
  if final_result.ok then
    M._auto_vcursor(tool_name, params, final_result)
  end

  return final_result
end

-- ============================================================================
-- Auto Cursor Tracking
-- ============================================================================
-- The agent moves the user's real cursor to show where it's working.
-- Position is extracted from tool params; vcursor.set() handles window
-- switching, cursor placement, and flash effects.

--- Move the user's cursor to follow the agent's position.
--- Extracts position from tool params, then delegates to vcursor.set().
---@param tool_name string  Internal tool name (dot notation, e.g. "buffer.edit")
---@param params table      Tool parameters as passed to the handler
---@param result table      Tool result (ok + data)
function M._auto_vcursor(tool_name, params, result)
  local ok_vc, vcursor = pcall(require, "xaster.vcursor")
  if not ok_vc then return end

  local editing_tools = {
    ["buffer.set"] = true, ["buffer.edit"] = true, ["buffer.create"] = true,
    ["buffer.delete"] = true, ["buffer.save"] = true, ["buffer.reload"] = true,
    ["file.write"] = true,
    ["vim.edit"] = true, ["vim.substitute"] = true, ["vim.normal"] = true,
    ["vim.search"] = true,
    ["command"] = true, ["feedkeys"] = true, ["lua"] = true,
    ["register.set"] = true, ["register.push"] = true, ["register.pop"] = true,
    ["mark.set"] = true,
    ["lsp.code_actions"] = true, ["undo"] = true, ["redo"] = true,
  }
  local reading_tools = {
    ["buffer.get"] = true, ["buffer.list"] = true, ["buffer.info"] = true,
    ["cursor.get"] = true, ["window.list"] = true,
    ["file.read"] = true, ["file.ensure_open"] = true,
    ["lsp.hover"] = true, ["lsp.definition"] = true,
    ["lsp.references"] = true, ["lsp.diagnostics"] = true,
    ["lsp.document_symbols"] = true, ["lsp.workspace_symbols"] = true,
    ["observe"] = true, ["state.observe"] = true,
    ["register.get"] = true, ["register.get_type"] = true,
    ["register.list"] = true, ["register.peek"] = true,
    ["register.eval"] = true, ["register.size"] = true,
    ["mark.get"] = true,
    ["quickfix.list"] = true, ["tab.list"] = true,
    ["window.scroll"] = true,
  }

  local is_editing = editing_tools[tool_name]
  if not is_editing and not reading_tools[tool_name] then return end

  -- Extract position from tool params.
  local buf = nil
  local row = nil
  local col = nil

  -- buffer.edit: {buf, start_row, start_col, end_row, end_col, text}
  if params.start_row ~= nil then
    row = params.start_row
    col = params.start_col or 0
    buf = params.buf
  -- cursor.set / mark.set / vim.edit / vcursor.set: {row, col, buf/win}
  elseif params.row ~= nil then
    row = params.row - (params.row > 0 and 1 or 0)  -- 1-indexed -> 0-indexed
    col = params.col or 0
    buf = params.buf or params.win
  -- buffer.get / buffer.set: {buf, start, end_}
  elseif params.start ~= nil then
    row = params.start
    col = 0
    buf = params.buf
  -- file.read / file.write / file.ensure_open: {filepath, ...}
  elseif params.filepath then
    buf = nil
    row = 0
    col = 0
  end

  -- Resolve buf from filepath or result, fall back to current buffer
  if not buf or buf == 0 then
    local filepath = params.filepath or (result and result.data and result.data.filepath)
    if filepath then
      buf = vim.fn.bufnr(filepath, false)
    end
    if not buf or buf == -1 or buf == 0 then
      if params.buf and params.buf ~= 0 then
        buf = params.buf
      elseif result and result.data and result.data.buf then
        buf = result.data.buf
      else
        buf = vim.api.nvim_get_current_buf()
      end
    end
  end

  -- If buf looks like a window id (from cursor.set "win"), resolve to buffer
  if buf and buf > 0 and not vim.api.nvim_buf_is_valid(buf) then
    local ok_w, wb = pcall(vim.api.nvim_win_get_buf, buf)
    buf = (ok_w and wb) and wb or vim.api.nvim_get_current_buf()
  end

  if row == nil or not vim.api.nvim_buf_is_valid(buf) then return end

  -- Delegate to vcursor.set — it handles window switching, cursor movement, flash
  vcursor.set(buf, row, col, {
    mode = is_editing and "editing" or "reading",
    flash = is_editing,
  })
end

-- ============================================================================
-- History Query API
-- ============================================================================

--- List recent history entries.
---@param opts table|nil  { n: integer, tool: string, buf: integer, since: number }
---@return HistoryEntry[]
function M.list(opts)
  opts = opts or {}
  local n = opts.n or 50
  local results = {}

  -- Iterate in reverse (newest first)
  for i = #history, math.max(1, #history - n + 1), -1 do
    local entry = history[i]
    if entry then
      -- Apply filters
      if opts.tool and entry.tool ~= opts.tool then
        goto continue
      end
      if opts.buf and entry.buf ~= opts.buf then
        goto continue
      end
      if opts.since and entry.time < opts.since then
        goto continue
      end
      table.insert(results, {
        seq = entry.seq,
        time = entry.time,
        tool = entry.tool,
        params = entry.params,
        ok = entry.error == nil,
        error = entry.error,
        elapsed_ms = entry.elapsed_ms,
        register_delta = entry.register_delta,
        buf = entry.buf,
        filename = entry.filename,
      })
      ::continue::
    end
  end
  return results
end

--- Get a specific history entry by sequence number.
---@param seq integer
---@return HistoryEntry|nil
function M.get(seq)
  for _, entry in ipairs(history) do
    if entry.seq == seq then
      return entry
    end
  end
  return nil
end

--- Get statistics about tool usage.
---@return table stats
function M.stats()
  local stats = {
    total_calls = #history,
    by_tool = {},
    total_errors = 0,
    avg_elapsed_ms = 0,
    last_call_at = nil,
  }

  local total_elapsed = 0
  for _, entry in ipairs(history) do
    stats.by_tool[entry.tool] = (stats.by_tool[entry.tool] or 0) + 1
    if entry.error then
      stats.total_errors = stats.total_errors + 1
    end
    total_elapsed = total_elapsed + (entry.elapsed_ms or 0)
  end

  if #history > 0 then
    stats.avg_elapsed_ms = math.floor(total_elapsed / #history)
    stats.last_call_at = history[#history].time
  end

  -- Sort by_tool by count (descending)
  local sorted_tools = {}
  for tool, count in pairs(stats.by_tool) do
    table.insert(sorted_tools, { tool = tool, count = count })
  end
  table.sort(sorted_tools, function(a, b) return a.count > b.count end)
  stats.by_tool = sorted_tools

  return stats
end

--- Clear all history.
---@return integer erased_count
function M.clear()
  local count = #history
  history = {}
  return count
end

--- Get the maximum number of history entries.
---@return integer
function M.get_max_entries()
  return max_entries
end

--- Set the maximum number of history entries.
---@param n integer
function M.set_max_entries(n)
  max_entries = math.max(10, math.min(10000, n))
  while #history > max_entries do
    table.remove(history, 1)
  end
end

--- Get a full snapshot of the history state machine.
---@return table
function M.observe()
  return {
    total_entries = #history,
    max_entries = max_entries,
    sequence = sequence,
    stats = M.stats(),
    hooks_count = { pre = #hooks.pre, post = #hooks.post },
  }
end

-- ============================================================================
-- Default Hooks (built-in)
-- ============================================================================

-- Log slow tool calls to the log buffer only (no user-visible notification).
-- Slow tools are common and expected; they are not errors.
M.register_hook("post", function(tool_name, params, result, elapsed_ms)
  if elapsed_ms and elapsed_ms > 2000 then
    local ok_log, log_mod = pcall(require, "xaster.log")
    if ok_log then
      log_mod.for_module("history"):info("slow tool", { tool = tool_name, elapsed_ms = elapsed_ms })
    end
  end
end, { priority = -100, id = "xaster_builtin_slow_warning" })

return M
