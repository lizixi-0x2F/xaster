--- xaster/vcursor.lua
--- ============================================================================
--- Agent Cursor — the agent moves the user's real cursor directly.
--- Flash effects use extmarks for brief visual pulses.
--- ============================================================================
--- vcursor.set now directly moves the user's cursor (the agent's position IS
--- the user's cursor — no separate "virtual" indicator layer). Flash effects
--- highlight edits briefly. get/clear operate on cursor tracking state.
--- ============================================================================

local M = {}

-- ============================================================================
-- State (lightweight: tracks the last cursor position per buffer)
-- ============================================================================

---@class CursorState
---@field buf integer
---@field row integer    0-indexed
---@field col integer    0-indexed
---@field mode string    "reading" | "editing"
---@field created_at number

local cursors = {}  -- buf -> CursorState

-- Flash namespace (for brief line highlights)
local flash_ns = nil

-- ============================================================================
-- Configuration
-- ============================================================================

local config = {
  hl_flash = "xasterVirtualCursorFlash",
  flash_duration_ms = 400,
}

-- ============================================================================
-- Highlight Groups
-- ============================================================================

function M.define_highlights()
  -- Flash: bright yellow pulse for editing actions
  vim.api.nvim_set_hl(0, "xasterVirtualCursorFlash", {
    fg = "#000000", bg = "#fbbf24", bold = true, default = true,
  })
end

-- ============================================================================
-- Namespace
-- ============================================================================

local function ensure_flash_ns()
  if not flash_ns then
    flash_ns = vim.api.nvim_create_namespace("xaster_vcursor_flash")
  end
end

-- ============================================================================
-- Core Operations
-- ============================================================================

--- Move the user's cursor to a position in a buffer.
--- Finds or creates a window showing the buffer, focuses it, and moves the cursor.
---@param buf integer|nil  Buffer id (nil or 0 = current)
---@param row integer       0-indexed row
---@param col integer       0-indexed column
---@param opts table|nil    { mode: "reading"|"editing", flash: boolean }
---@return table
function M.set(buf, row, col, opts)
  buf = buf or vim.api.nvim_get_current_buf()
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(buf) then
    return { ok = false, error = "buffer not found: " .. tostring(buf) }
  end

  opts = opts or {}
  row = row or 0
  col = col or 0

  -- Find a window showing this buffer
  local target_win = nil
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current_win) == buf then
    target_win = current_win
  else
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        target_win = win
        break
      end
    end
  end

  if target_win then
    if target_win ~= current_win then
      vim.api.nvim_set_current_win(target_win)
    end
    pcall(vim.api.nvim_win_set_cursor, target_win, { row + 1, col })
  else
    -- Switch current window to show this buffer
    vim.api.nvim_win_set_buf(current_win, buf)
    pcall(vim.api.nvim_win_set_cursor, current_win, { row + 1, col })
  end

  -- Flash if requested (for editing mode)
  if opts.flash then
    M.flash(buf, row, col)
  end

  -- Track cursor state
  cursors[buf] = {
    buf = buf,
    row = row,
    col = col,
    mode = opts.mode or "reading",
    created_at = os.time(),
  }

  return { ok = true, cursor = { buf = buf, row = row, col = col, mode = opts.mode or "reading" } }
end

--- Flash a location briefly to draw attention.
---@param buf integer
---@param row integer  0-indexed
---@param col integer  0-indexed
function M.flash(buf, row, col)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  ensure_flash_ns()

  local flash_opts = {
    hl_group = config.hl_flash,
    priority = 250,
    strict = false,
    ephemeral = true,
    line_hl_group = config.hl_flash,
  }

  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, flash_ns, row or 0, 0, flash_opts)
  if ok and id then
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_del_extmark, buf, flash_ns, id)
      end
    end, config.flash_duration_ms)
  end
end

--- Get tracked cursor state for a buffer or all buffers.
---@param buf integer|nil
---@return table|nil
function M.get(buf)
  if buf then
    if buf == 0 then buf = vim.api.nvim_get_current_buf() end
    local cs = cursors[buf]
    if cs then
      return {
        buf = cs.buf,
        filename = vim.api.nvim_buf_get_name(cs.buf),
        row = cs.row,
        col = cs.col,
        mode = cs.mode,
        created_at = cs.created_at,
      }
    end
    return nil
  end

  local result = {}
  for b, cs in pairs(cursors) do
    if vim.api.nvim_buf_is_valid(b) then
      table.insert(result, {
        buf = cs.buf,
        filename = vim.api.nvim_buf_get_name(cs.buf),
        row = cs.row,
        col = cs.col,
        mode = cs.mode,
        created_at = cs.created_at,
      })
    end
  end
  return result
end

--- Clear tracked cursor state.
---@param buf integer|nil
---@return integer cleared_count
function M.clear(buf)
  local count = 0
  if buf then
    if buf == 0 then buf = vim.api.nvim_get_current_buf() end
    if cursors[buf] then
      cursors[buf] = nil
      count = 1
    end
  else
    count = #vim.tbl_keys(cursors)
    cursors = {}
  end
  return count
end

--- Get configuration.
---@return table
function M.get_config()
  return vim.deepcopy(config)
end

--- Update configuration.
---@param opts table
function M.update_config(opts)
  if not opts then return end
  if opts.flash_duration_ms then config.flash_duration_ms = opts.flash_duration_ms end
  if opts.mode then end -- kept for backward compat
end

--- Full state snapshot.
---@return table
function M.observe()
  return {
    cursors = M.get(nil),
    count = #vim.tbl_keys(cursors),
    config = M.get_config(),
  }
end

-- ============================================================================
-- Cleanup
-- ============================================================================

function M.cleanup()
  M.clear(nil)
  if flash_ns then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_clear_namespace, buf, flash_ns, 0, -1)
      end
    end
  end
end

return M
