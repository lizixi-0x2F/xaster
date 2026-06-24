local compat = require("xaster.compat")
--- xaster/lock.lua
--- Batch operation isolation -- prevents user interference during Agent edits.
---
--- When locked:
---   User CAN:     navigate (hjkl/gg), scroll, search, yank/copy, visual select
---                  switch buffers/windows/tabs, save files (:write)
---   User CANNOT:  edit (insert/change/delete/paste/replace), undo Agent changes
---
--- The Agent's tools bypass the lock transparently -- the Agent always has edit access.
--- Since Neovim's event loop is single-threaded, there's no race condition.

local M = {}

-- ============================================================================
-- State
-- ============================================================================

---@class LockState
---@field locked boolean          Whether the lock is active
---@field locked_at number|nil    os.time() when locked
---@field locked_by string|nil    Who initiated the lock ("user" | "agent")
---@field edits_bypassed integer  Count of edits the Agent made while locked
---@field autocmd_group integer|nil

local state = {
  locked = false,
  locked_at = nil,
  locked_by = nil,
  edits_bypassed = 0,
  autocmd_group = nil,
}

local LOCK_AUGROUP = "xaster_lock"

-- ============================================================================
-- Configuration
-- ============================================================================

local config = {
  allow_user_navigate = true,
  allow_user_yank = true,
  allow_user_undo = false,
  allow_user_save = true,
  block_insert = true,
  block_change = true,
  statusline_text_locked = "[AGENT]",
  statusline_text_unlocked = "",
  -- Buffers types that should NEVER be locked
  exclude_buftypes = { "nofile", "help", "terminal", "prompt", "popup", "quickfix" },
  -- When locked, new file buffers auto-get nomodifiable
  auto_lock_new_buffers = true,
}

-- ============================================================================
-- Buffer Locking
-- ============================================================================

--- Check if a buffer type should be excluded from locking.
---@param buf integer
---@return boolean
local function is_excluded(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return true
  end
  local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
  return compat.list_contains(config.exclude_buftypes, bt)
end

--- Set nomodifiable on all eligible buffers.
local function lock_all_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not is_excluded(buf) then
      pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
    end
  end
end

--- Restore modifiable on all buffers.
local function unlock_all_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not is_excluded(buf) then
      pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
    end
  end
end

-- ============================================================================
-- Autocommands (for new buffers while locked)
-- ============================================================================

function M._setup_lock_autocmds()
  if state.autocmd_group then
    return -- already set up
  end
  state.autocmd_group = vim.api.nvim_create_augroup(LOCK_AUGROUP, { clear = true })

  -- Auto-lock new file buffers
  vim.api.nvim_create_autocmd({ "BufNew", "BufRead", "BufEnter" }, {
    group = state.autocmd_group,
    pattern = "*",
    callback = function(args)
      if not state.locked then return end
      local buf = args.buf
      if is_excluded(buf) then return end
      -- Set nomodifiable on the new buffer
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and not is_excluded(buf) then
          pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
        end
      end)
    end,
    desc = "xaster: auto-lock new buffers",
  })

  -- Block insert mode entry
  if config.block_insert then
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = state.autocmd_group,
      pattern = "*",
      callback = function()
        if not state.locked then return end
        -- Leave insert mode immediately and show a toast
        vim.schedule(function()
          vim.api.nvim_command("stopinsert")
          local ok_ui, ui = pcall(require, "xaster.ui")
          if ok_ui then
            ui.toast("Editor locked -- Agent is in control", "warn")
          end
        end)
      end,
      desc = "xaster: block insert mode when locked",
    })
  end
end

function M._remove_lock_autocmds()
  if state.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.autocmd_group)
    state.autocmd_group = nil
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Enable the Agent operation isolation lock.
--- All file buffers become nomodifiable for the user.
--- The Agent's tools bypass transparently.
---@param opts table|nil  { by: "user"|"agent" }
---@return table result
function M.enable(opts)
  if state.locked then
    return { ok = true, already_locked = true, locked_at = state.locked_at }
  end

  opts = opts or {}
  state.locked = true
  state.locked_at = os.time()
  state.locked_by = opts.by or "user"
  state.edits_bypassed = 0

  lock_all_buffers()
  M._setup_lock_autocmds()

  -- Show indicator
  local ok_ui, ui = pcall(require, "xaster.ui")
  if ok_ui then
    ui.toast("Editor locked -- Agent has exclusive edit access", "info")
  end

  return {
    ok = true,
    locked = true,
    locked_at = state.locked_at,
    locked_by = state.locked_by,
  }
end

--- Disable the lock. User can edit freely again.
---@return table result
function M.disable()
  if not state.locked then
    return { ok = true, already_unlocked = true }
  end

  state.locked = false
  state.locked_at = nil

  unlock_all_buffers()
  M._remove_lock_autocmds()

  local ok_ui, ui = pcall(require, "xaster.ui")
  if ok_ui then
    ui.toast("Editor unlocked -- user can edit again", "info")
  end

  return {
    ok = true,
    locked = false,
    edits_bypassed = state.edits_bypassed,
  }
end

--- Toggle the lock.
function M.toggle()
  if state.locked then
    return M.disable()
  else
    return M.enable()
  end
end

--- Check if the lock is currently active.
---@return boolean
function M.is_locked()
  return state.locked
end

--- Bypass the lock for a specific buffer, allowing edits.
--- Called by editor.lua before the Agent makes an edit.
--- MUST be followed by restore_after_edit().
---@param buf integer
function M.bypass_for_edit(buf)
  if not state.locked then return end
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if is_excluded(buf) then return end

  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  state.edits_bypassed = state.edits_bypassed + 1
end

--- Restore the lock after the Agent finishes an edit.
---@param buf integer
function M.restore_after_edit(buf)
  if not state.locked then return end
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if is_excluded(buf) then return end

  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
end


-- ============================================================================
-- Observation
-- ============================================================================

--- Get the lock state (for state.observe and RPC).
---@return table
function M.observe()
  return {
    locked = state.locked,
    locked_at = state.locked_at,
    locked_by = state.locked_by,
    edits_bypassed = state.edits_bypassed,
    config = vim.deepcopy(config),
  }
end

--- Get the statusline indicator string.
---@return string
function M.statusline()
  if state.locked then
    return "%#xasterStatusError#" .. config.statusline_text_locked
  else
    return ""
  end
end

-- ============================================================================
-- Cleanup
-- ============================================================================

function M.cleanup()
  if state.locked then
    unlock_all_buffers()
  end
  M._remove_lock_autocmds()
  state = {
    locked = false,
    locked_at = nil,
    locked_by = nil,
    edits_bypassed = 0,
    autocmd_group = nil,
  }
end

return M
