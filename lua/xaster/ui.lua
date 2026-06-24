--- xaster/ui.lua
--- Visual feedback system: the Agent's presence in the editor.
---
--- Components:
---   1. Status line component -- connection + activity indicator
---   2. Action indicator -- floating window showing the Agent's current action
---   3. Changed region highlights -- visual diff of the Agent's edits
---   4. Toast notifications -- non-intrusive status messages

local M = {}

-- ============================================================================
-- State
-- ============================================================================

---@class UIState
---@field action_win integer|nil    Floating window showing current action
---@field action_buf integer|nil    Buffer for action window
---@field toast_timer integer|nil   Timer for toast auto-dismiss
---@field toast_win integer|nil
---@field toast_buf integer|nil
---@field status_ok boolean         Whether connection is healthy
---@field current_tool string|nil   Currently executing tool name
---@field ns_id integer             Highlight namespace for xaster UI elements
---@field config table              UI configuration

local ui = {
  action_win = nil,
  action_buf = nil,
  toast_timer = nil,
  toast_win = nil,
  toast_buf = nil,
  status_ok = false,
  current_tool = nil,
  ns_id = nil,
  config = {},
}

local default_config = {
  -- Action indicator
  action = {
    enabled = true,
    position = { row = 1, col = 0.5 },  -- top center (fractional)
    width = 60,
    height = 1,
    border = "rounded",
    hl_group = "xasterAction",
    auto_hide_ms = 10000,  -- auto-hide after 10s idle
    filetype = "markdown",
  },
  -- Toast notifications
  toast = {
    enabled = true,
    position = { row = 0.88, col = 0.5 },  -- bottom center
    width = 50,
    height = 1,
    border = "rounded",
    hl_group = "xasterToast",
    duration_ms = 4000,
  },
  -- Status line
  statusline = {
    enabled = true,
    icon_connected = "*",
    icon_disconnected = "-",
    icon_working = "~",
    hl_connected = "xasterStatusConnected",
    hl_disconnected = "xasterStatusDisconnected",
    hl_working = "xasterStatusWorking",
  },
  -- Changed region highlights
  highlights = {
    enabled = true,
    hl_added = "DiffAdd",
    hl_changed = "DiffChange",
    hl_removed = "DiffDelete",
    duration_ms = 3000,  -- how long to keep highlights
  },
  -- Auto-clear changed highlights after edits
  auto_clear_delay_ms = 5000,
}

-- ============================================================================
-- Highlight Groups
-- ============================================================================

--- Define highlight groups for xaster UI elements.
function M.define_highlights()
  -- Status line highlights
  vim.api.nvim_set_hl(0, "xasterStatusConnected", { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "xasterStatusDisconnected", { fg = "#6c7086" })
  vim.api.nvim_set_hl(0, "xasterStatusWorking", { fg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "xasterStatusError", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "xasterStatusUltracode", { fg = "#c4b5fd", bold = true })

  -- Floating window highlights
  vim.api.nvim_set_hl(0, "xasterAction", { fg = "#89b4fa", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "xasterActionBorder", { fg = "#89b4fa", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "xasterToast", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "xasterToastBorder", { fg = "#a6adc8", bg = "#313244" })

  -- xaster highlight groups for extmarks
  vim.api.nvim_set_hl(0, "xasterHighlightAdd", { bg = "#40a02b", fg = "#ffffff" })
  vim.api.nvim_set_hl(0, "xasterHighlightChange", { bg = "#df8e1d", fg = "#ffffff" })
  vim.api.nvim_set_hl(0, "xasterHighlightDelete", { bg = "#d20f39", fg = "#ffffff" })
end

-- ============================================================================
-- Action Indicator (floating window showing the Agent's current action)
-- ============================================================================

--- Show the Agent's current action in a floating window.
--- This is called when the Agent starts a tool execution.
---@param text string  The action description (e.g. "Reading buffer 1", "Editing line 42")
function M.action_show(text)
  if not ui.config.action or not ui.config.action.enabled then
    return
  end
  if not text or text == "" then
    return
  end

  local cfg = ui.config.action
  local lines = { " " .. text .. " " }
  local width = math.min(cfg.width or 60, vim.o.columns - 4)

  if ui.action_win and vim.api.nvim_win_is_valid(ui.action_win) then
    -- Update existing
    local buf = vim.api.nvim_win_get_buf(ui.action_win)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_config(ui.action_win, {
      relative = "editor",
      width = width,
      height = 1,
      row = 0,
      col = math.floor((vim.o.columns - width) / 2),
    })
  else
    -- Create new floating window
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    if cfg.filetype then
      vim.api.nvim_buf_set_option(buf, "filetype", cfg.filetype)
    end

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = 1,
      row = 0,
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = cfg.border or "rounded",
      noautocmd = true,
      zindex = 100,
    })

    -- Apply highlight
    vim.api.nvim_win_set_option(win, "winhl",
      "Normal:xasterAction,FloatBorder:xasterActionBorder")

    ui.action_win = win
    ui.action_buf = buf
  end

  -- Reset auto-hide timer
  if ui.action_hide_timer then
    ui.action_hide_timer:stop()
    ui.action_hide_timer:close()
    ui.action_hide_timer = nil
  end

  if cfg.auto_hide_ms and cfg.auto_hide_ms > 0 then
    ui.action_hide_timer = vim.defer_fn(function()
      M.action_hide()
    end, cfg.auto_hide_ms)
  end
end

--- Hide the action indicator.
function M.action_hide()
  if ui.action_win and vim.api.nvim_win_is_valid(ui.action_win) then
    vim.api.nvim_win_close(ui.action_win, true)
  end
  if ui.action_buf and vim.api.nvim_buf_is_valid(ui.action_buf) then
    pcall(vim.api.nvim_buf_delete, ui.action_buf, { force = true })
  end
  ui.action_win = nil
  ui.action_buf = nil

  if ui.action_hide_timer then
    ui.action_hide_timer:stop()
    ui.action_hide_timer:close()
    ui.action_hide_timer = nil
  end
end

-- ============================================================================
-- Toast Notifications
-- ============================================================================

--- Show a brief toast notification.
---@param message string
---@param level string|nil  "info", "warn", "error", "success"
function M.toast(message, level)
  if not ui.config.toast or not ui.config.toast.enabled then
    return
  end

  local cfg = ui.config.toast
  local icon = ""
  if level == "error" then icon = "X "
  elseif level == "warn" then icon = "! "
  elseif level == "success" then icon = "> "
  elseif level == "info" then icon = "* "
  end
  local text = " " .. icon .. message .. " "

  -- Close existing toast
  M.toast_dismiss()

  -- Create new
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

  local width = math.min(cfg.width or 50, #text + 2)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = 1,
    row = vim.o.lines - 4,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = cfg.border or "rounded",
    noautocmd = true,
    zindex = 200,
  })

  vim.api.nvim_win_set_option(win, "winhl", "Normal:xasterToast,FloatBorder:xasterToastBorder")

  ui.toast_win = win
  ui.toast_buf = buf

  -- Auto-dismiss
  ui.toast_timer = vim.defer_fn(function()
    M.toast_dismiss()
  end, cfg.duration_ms or 4000)
end

--- Dismiss the current toast.
function M.toast_dismiss()
  if ui.toast_timer then
    pcall(vim.loop.timer_stop, ui.toast_timer)
    pcall(vim.loop.close, ui.toast_timer)
    ui.toast_timer = nil
  end
  if ui.toast_win and vim.api.nvim_win_is_valid(ui.toast_win) then
    vim.api.nvim_win_close(ui.toast_win, true)
    ui.toast_win = nil
  end
  if ui.toast_buf and vim.api.nvim_buf_is_valid(ui.toast_buf) then
    pcall(vim.api.nvim_buf_delete, ui.toast_buf, { force = true })
    ui.toast_buf = nil
  end
end

-- ============================================================================
-- Changed Region Highlights
-- ============================================================================

local pending_highlights = {}
local highlight_clear_timer = nil

--- Highlight changed regions after the Agent makes an edit.
--- Shows the user exactly what changed.
---@param buf integer
---@param start_row integer  0-indexed
---@param start_col integer  0-indexed
---@param end_row integer     0-indexed
---@param end_col integer     0-indexed
---@param change_type string  "add" | "change" | "delete"
function M.highlight_change(buf, start_row, start_col, end_row, end_col, change_type)
  if not ui.config.highlights or not ui.config.highlights.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local hl_group = ui.config.highlights.hl_changed or "DiffChange"
  if change_type == "add" then
    hl_group = ui.config.highlights.hl_added or "DiffAdd"
  elseif change_type == "delete" then
    hl_group = ui.config.highlights.hl_removed or "DiffDelete"
  end

  -- Use extmark for precise highlighting
  local ns = ui.ns_id or vim.api.nvim_create_namespace("xaster_ui")
  ui.ns_id = ns

  local ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_row, start_col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = hl_group,
    strict = false,
    ephemeral = true, -- auto-removed when buffer changes
  })

  if ok and extmark_id then
    table.insert(pending_highlights, { buf = buf, ns = ns, id = extmark_id })
  end
end

--- Clear all pending change highlights.
function M.highlight_changes_clear()
  for _, h in ipairs(pending_highlights) do
    if vim.api.nvim_buf_is_valid(h.buf) then
      pcall(vim.api.nvim_buf_del_extmark, h.buf, h.ns, h.id)
    end
  end
  pending_highlights = {}

  if highlight_clear_timer then
    highlight_clear_timer:stop()
    highlight_clear_timer:close()
    highlight_clear_timer = nil
  end
end

--- Schedule auto-clear of highlights.
function M.highlight_changes_schedule_clear()
  if highlight_clear_timer then
    highlight_clear_timer:stop()
    highlight_clear_timer:close()
  end
  local delay = ui.config.auto_clear_delay_ms or 5000
  highlight_clear_timer = vim.defer_fn(function()
    M.highlight_changes_clear()
  end, delay)
end

-- ============================================================================
-- Status Line Component
-- ============================================================================

--- Get the xaster status line string.
--- Designed to be used in 'statusline' or lualine.
--- Shows: [*] model_name when idle, [~] Round 3/20 | 5 tools | 12.4k tokens when active
---@return string
function M.statusline()
  if not ui.config.statusline or not ui.config.statusline.enabled then
    return ""
  end

  local cfg = ui.config.statusline

  -- Agent running: show live progress
  local ok_agent, agent = pcall(require, "xaster.agent")
  local ultracode_on = ok_agent and agent.is_ultracode and agent.is_ultracode()

  if ok_agent and agent.is_running() then
    local obs = agent.observe()
    local parts = {}
    local icon = ultracode_on and "%#xasterStatusUltracode#UC%#xasterStatusWorking#" .. (cfg.icon_working or "~")
      or "%#xasterStatusWorking#" .. (cfg.icon_working or "~")
    parts[#parts + 1] = icon
    local phase_abbr = obs.phase and obs.phase:sub(1, 1):upper() or "?"
    parts[#parts + 1] = phase_abbr
    parts[#parts + 1] = string.format("R%d/%d", obs.round, obs.max_rounds)

    -- Show estimated token usage
    if obs.est_tokens > 0 then
      local kt = math.floor(obs.est_tokens / 1000)
      parts[#parts + 1] = string.format("%dK tok", kt)
    end

    -- Show compressed rounds if any
    if obs.compressed_count > 0 then
      parts[#parts + 1] = string.format("(%d compressed)", obs.compressed_count)
    end

    -- Show circuit state if any broken tools
    local broken = {}
    for tool, state in pairs(obs.circuit_state or {}) do
      local failures = type(state) == "table" and (state.failures or 0) or (state or 0)
      if failures >= 3 then
        broken[#broken + 1] = tool
      end
    end
    if #broken > 0 then
      parts[#parts + 1] = "%#xasterStatusError#" .. "[!]"
    end

    return table.concat(parts, " ")
  end

  -- Idle: show model + provider + phase
  local ok_llm, llm = pcall(require, "xaster.llm")
  if ok_llm and llm.is_configured() then
    local provider = llm.get_provider()
    local model = llm.get_model():match("[^/]+$") or llm.get_model() -- short name
    local icon = cfg.icon_connected or "*"
    local uc_suffix = ultracode_on and "%#xasterStatusUltracode#[UC]%#xasterStatusConnected#" or ""
    local phase_str = ok_agent and agent.get_phase and ("[" .. agent.get_phase():sub(1, 1):upper() .. "] ") or ""

    if ui.current_tool then
      return string.format("%%#xasterStatusWorking#%s %s%s| %s%s",
        icon, phase_str, ui.current_tool:sub(1, 20), model, uc_suffix)
    end
    return string.format("%%#xasterStatusConnected#%s %s%s:%s%s",
      icon, phase_str, provider:sub(1, 1):upper() .. provider:sub(2), model:sub(1, 20), uc_suffix)
  end

  return "%#xasterStatusDisconnected#" .. (cfg.icon_disconnected or "-") .. " no API key"
end

--- Set the currently executing tool (shown in status line).
---@param tool_name string|nil
function M.set_current_tool(tool_name)
  ui.current_tool = tool_name
  if tool_name then
    M.action_show(tool_name)
  else
    M.action_hide()
  end
end

-- ============================================================================
-- Full-screen Overlay (for big announcements)
-- ============================================================================

--- Show a large centered floating window (for diffs, plans, etc.).
---@param title string
---@param content string[]  Lines of text
---@param opts table|nil    {filetype, width_ratio, height_ratio}
---@return integer win_id
---@return integer buf_id
function M.show_large_float(title, content, opts)
  opts = opts or {}
  local width_ratio = opts.width_ratio or 0.7
  local height_ratio = opts.height_ratio or 0.6

  local width = math.floor(vim.o.columns * width_ratio)
  local height = math.floor(vim.o.lines * height_ratio)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  if opts.filetype then
    vim.api.nvim_buf_set_option(buf, "filetype", opts.filetype)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. (title or "xaster") .. " ",
    title_pos = "center",
    noautocmd = true,
    zindex = 150,
  })

  vim.api.nvim_win_set_option(win, "winhl", "Normal:NormalFloat,FloatBorder:FloatBorder")
  vim.api.nvim_win_set_option(win, "cursorline", true)
  vim.api.nvim_win_set_option(win, "wrap", true)

  -- Keymap to close with q/Esc
  local function close_float()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  vim.keymap.set("n", "q", close_float, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_float, { buffer = buf, nowait = true })

  return win, buf
end

-- ============================================================================
-- Initialization
-- ============================================================================

--- Initialize the UI system.
---@param opts table|nil  User config overrides
function M.setup(opts)
  opts = opts or {}

  -- Merge with defaults
  ui.config = vim.tbl_deep_extend("force", default_config, opts.ui or {})

  -- Define highlight groups
  M.define_highlights()

  -- Create highlight namespace if needed
  if not ui.ns_id then
    ui.ns_id = vim.api.nvim_create_namespace("xaster_ui")
  end
end

--- Clean up all UI elements.
function M.cleanup()
  M.action_hide()
  M.toast_dismiss()
  M.highlight_changes_clear()

  -- Clear namespace highlights
  if ui.ns_id then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_clear_namespace, buf, ui.ns_id, 0, -1)
      end
    end
  end

  ui = {
    action_win = nil,
    action_buf = nil,
    toast_timer = nil,
    toast_win = nil,
    toast_buf = nil,
    status_ok = false,
    current_tool = nil,
    ns_id = nil,
    config = {},
  }
end

return M
