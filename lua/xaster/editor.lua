--- xaster/editor.lua
--- High-level editor operations wrapping Neovim's native API.
--- Every function here is synchronous (runs in Neovim's main loop via vim.schedule).
--- These are the building blocks that tools.lua calls into.

local M = {}

-- ============================================================================
-- Utilities
-- ============================================================================

--- Bypass the Agent lock for editing operations.
--- When the lock is active, buffers are nomodifiable for the user,
--- but the Agent's RPC tools need to temporarily unlock the buffer.
---@param buf integer
local function lock_bypass(buf)
  local ok, lock = pcall(require, "xaster.lock")
  if ok then
    lock.bypass_for_edit(buf)
  end
end

--- Restore the lock after an edit operation.
---@param buf integer
local function lock_restore(buf)
  local ok, lock = pcall(require, "xaster.lock")
  if ok then
    lock.restore_after_edit(buf)
  end
end

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function normalize_buf(buf)
  if buf == nil or buf == 0 then
    return vim.api.nvim_get_current_buf()
  end
  if not buf_valid(buf) then
    return nil
  end
  return buf
end

local function normalize_win(win)
  if win == nil or win == 0 then
    return vim.api.nvim_get_current_win()
  end
  if not win_valid(win) then
    return nil
  end
  return win
end

-- ============================================================================
-- Buffer Operations
-- ============================================================================

--- List all buffers with metadata.
---@return table[]  Array of {id, name, buftype, modified, line_count, listed, current}
function M.buffer_list()
  local buffers = {}
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf_valid(buf) then
      table.insert(buffers, {
        id = buf,
        name = vim.api.nvim_buf_get_name(buf),
        buftype = vim.api.nvim_get_option_value("buftype", { buf = buf }),
        filetype = vim.api.nvim_get_option_value("filetype", { buf = buf }),
        modified = vim.api.nvim_get_option_value("modified", { buf = buf }),
        line_count = vim.api.nvim_buf_line_count(buf),
        listed = vim.api.nvim_get_option_value("buflisted", { buf = buf }),
        current = buf == current,
      })
    end
  end
  return buffers
end

--- Get buffer content (lines range).
---@param buf integer|nil
---@param start_line integer|nil  0-indexed, inclusive
---@param end_line integer|nil    0-indexed, exclusive (-1 = end)
---@return string[] lines
---@return string|nil error_message
function M.buffer_get(buf, start_line, end_line)
  buf = normalize_buf(buf)
  if not buf then
    return nil, "buffer not found"
  end
  local total = vim.api.nvim_buf_line_count(buf)
  local s = math.max(0, start_line or 0)
  local e = end_line
  if e == nil or e == -1 then
    e = total
  else
    e = math.min(e, total)
  end
  if s >= e then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(buf, s, e, false)
  return lines
end

--- Set buffer content (replace lines range).
---@param buf integer|nil
---@param start_line integer  0-indexed, inclusive
---@param end_line integer     0-indexed, exclusive
---@param lines string[]
---@return boolean ok
---@return string|nil error_message
function M.buffer_set(buf, start_line, end_line, lines)
  buf = normalize_buf(buf)
  if not buf then
    return false, "buffer not found"
  end
  local total = vim.api.nvim_buf_line_count(buf)
  local s = math.max(0, start_line or 0)
  local e = end_line or total
  if s > e then
    return false, "invalid range: start > end"
  end
  lock_bypass(buf)
  vim.api.nvim_buf_set_lines(buf, s, e, false, lines or {})
  lock_restore(buf)
  return true
end

--- Apply a precise text edit using nvim_buf_set_text (character-precise).
---@param buf integer|nil
---@param start_row integer 0-indexed
---@param start_col integer 0-indexed
---@param end_row integer 0-indexed
---@param end_col integer 0-indexed (exclusive)
---@param replacement string[]  Array of lines to insert
---@return boolean ok
---@return string|nil error_message
function M.buffer_edit(buf, start_row, start_col, end_row, end_col, replacement)
  buf = normalize_buf(buf)
  if not buf then
    return false, "buffer not found"
  end
  lock_bypass(buf)
  local ok, err = pcall(vim.api.nvim_buf_set_text, buf, start_row, start_col, end_row, end_col, replacement or {})
  lock_restore(buf)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Create a new buffer.
---@param lines string[]|nil  Initial content
---@param name string|nil     Buffer name
---@param opts table|nil      {listed, scratch, buftype, filetype}
---@return integer buf_id
function M.buffer_create(lines, name, opts)
  opts = opts or {}
  local listed = opts.listed ~= false
  local scratch = opts.scratch or false
  local buf = vim.api.nvim_create_buf(listed, scratch)
  if lines and #lines > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  if name then
    -- Set buffer name (file path)
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  if opts.filetype then
    vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
  end
  if opts.buftype then
    vim.api.nvim_set_option_value("buftype", opts.buftype, { buf = buf })
  end
  return buf
end

--- Delete a buffer (force if modified).
---@param buf integer
---@param force boolean|nil
---@return boolean ok
---@return string|nil error_message
function M.buffer_delete(buf, force)
  if not buf_valid(buf) then
    return false, "buffer not found"
  end
  lock_bypass(buf)
  local ok, err = pcall(vim.api.nvim_buf_delete, buf, { force = force or false })
  lock_restore(buf)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Force-reload a buffer from disk.
---@param buf integer|nil
---@return boolean ok
---@return string|nil error_message
function M.buffer_reload(buf)
  buf = normalize_buf(buf)
  if not buf then
    return false, "buffer not found"
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return false, "buffer has no file"
  end
  -- Use :edit! to force reload
  local win = vim.api.nvim_get_current_win()
  local was_in_buf = vim.api.nvim_win_get_buf(win) == buf
  if was_in_buf then
    vim.api.nvim_command("edit!")
  else
    -- Temporarily switch to the buffer, reload, switch back
    local orig_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_command("edit!")
    vim.api.nvim_win_set_buf(win, orig_buf)
  end
  return true
end

--- Save a buffer to disk.
---@param buf integer|nil
---@return boolean ok
---@return string|nil error_message
function M.buffer_save(buf)
  buf = normalize_buf(buf)
  if not buf then
    return false, "buffer not found"
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return false, "buffer has no file name"
  end
  local win = vim.api.nvim_get_current_win()
  local was_in_buf = vim.api.nvim_win_get_buf(win) == buf
  if was_in_buf then
    vim.api.nvim_command("write")
  else
    local orig_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_command("write")
    vim.api.nvim_win_set_buf(win, orig_buf)
  end
  return true
end

--- Get the full path and metadata of a buffer.
---@param buf integer|nil
---@return table|nil buffer_info
function M.buffer_info(buf)
  buf = normalize_buf(buf)
  if not buf then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return {
    id = buf,
    name = name,
    dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or nil,
    basename = name ~= "" and vim.fn.fnamemodify(name, ":t") or nil,
    buftype = vim.api.nvim_get_option_value("buftype", { buf = buf }),
    filetype = vim.api.nvim_get_option_value("filetype", { buf = buf }),
    modified = vim.api.nvim_get_option_value("modified", { buf = buf }),
    line_count = vim.api.nvim_buf_line_count(buf),
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
  }
end

-- ============================================================================
-- Window Operations
-- ============================================================================

--- List all windows with metadata.
---@return table[]  Array of {id, buffer_id, width, height, row, col, current}
function M.window_list()
  local windows = {}
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local pos = vim.api.nvim_win_get_position(win)
      table.insert(windows, {
        id = win,
        buffer = buf,
        buffer_name = vim.api.nvim_buf_get_name(buf),
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
        row = pos[1],
        col = pos[2],
        current = win == current,
      })
    end
  end
  return windows
end

--- Focus a specific window.
---@param win integer
---@return boolean ok
---@return string|nil error_message
function M.window_focus(win)
  if not win_valid(win) then
    return false, "window not found"
  end
  vim.api.nvim_set_current_win(win)
  return true
end

--- Create a split window.
---@param direction string  "horizontal" | "vertical" | "above" | "below" | "left" | "right"
---@param file_or_buf string|integer|nil  File path or buffer id to open
---@param size integer|nil  Size of the split in lines/columns
---@return integer win_id
---@return string|nil error_message
function M.window_split(direction, file_or_buf, size)
  local cmd
  local dir = direction or "below"
  if dir == "horizontal" or dir == "below" then
    cmd = size and (size .. "split") or "split"
  elseif dir == "above" then
    cmd = size and (size .. "split") or "split"
    -- vim's split direction for above is handled differently; use bel + split then move
  elseif dir == "vertical" or dir == "right" then
    cmd = size and (size .. "vsplit") or "vsplit"
  elseif dir == "left" then
    cmd = size and ("vertical " .. "leftabove " .. size .. "vsplit") or "leftabove vsplit"
  else
    return nil, "invalid direction: " .. dir
  end

  if type(file_or_buf) == "string" and file_or_buf ~= "" then
    pcall(vim.api.nvim_command, "execute '" .. cmd .. " " .. vim.fn.fnameescape(file_or_buf) .. "'")
  elseif type(file_or_buf) == "number" and buf_valid(file_or_buf) then
    -- Split, then set the buffer
    vim.api.nvim_command(cmd)
    vim.api.nvim_win_set_buf(0, file_or_buf)
  else
    vim.api.nvim_command(cmd)
  end
  return vim.api.nvim_get_current_win()
end

--- Close a window.
---@param win integer
---@param force boolean|nil
---@return boolean ok
---@return string|nil error_message
function M.window_close(win, force)
  if not win_valid(win) then
    return false, "window not found"
  end
  -- Don't close the last window
  if #vim.api.nvim_list_wins() <= 1 then
    return false, "cannot close last window"
  end
  vim.api.nvim_win_close(win, force or false)
  return true
end

--- Set window configuration (position, size).
---@param win integer
---@param config table  {relative, width, height, row, col, anchor, style, border, ...}
---@return boolean ok
---@return string|nil error_message
function M.window_config(win, config)
  if not win_valid(win) then
    return false, "window not found"
  end
  local ok, err = pcall(vim.api.nvim_win_set_config, win, config)
  if not ok then
    return false, tostring(err)
  end
  return true
end

-- ============================================================================
-- Cursor Operations
-- ============================================================================

--- Get cursor position in a window.
---@param win integer|nil
---@return integer row  1-indexed
---@return integer col  0-indexed
function M.cursor_get(win)
  win = normalize_win(win)
  if not win then
    return 1, 0
  end
  local pos = vim.api.nvim_win_get_cursor(win)
  return pos[1], pos[2]
end

--- Set cursor position in a window.
---@param win integer|nil
---@param row integer  1-indexed
---@param col integer  0-indexed
---@return boolean ok
---@return string|nil error_message
function M.cursor_set(win, row, col)
  win = normalize_win(win)
  if not win then
    return false, "window not found"
  end
  local ok, err = pcall(vim.api.nvim_win_set_cursor, win, { row, col or 0 })
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Scroll a window.
---@param win integer|nil
---@param amount integer  Lines to scroll (positive = down)
---@return boolean ok
function M.window_scroll(win, amount)
  win = normalize_win(win)
  if not win then
    return false, "window not found"
  end
  -- Use vim.fn.winrestview / winline approach for reliability
  local current_win = vim.api.nvim_get_current_win()
  if win ~= current_win then
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_command("execute 'normal! " .. math.abs(amount) .. (amount > 0 and "\\<C-e>" or "\\<C-y>") .. "'")
  if win ~= current_win then
    vim.api.nvim_set_current_win(current_win)
  end
  return true
end

-- ============================================================================
-- Mode & Command Operations
-- ============================================================================

--- Get the current editor mode.
---@return table  {mode, blocking}
function M.mode_get()
  return vim.api.nvim_get_mode()
end

--- Execute an Ex command.
---@param cmd string
---@return boolean ok
---@return string|nil error_message
function M.command_execute(cmd)
  local ok, err = pcall(vim.api.nvim_command, cmd)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Feed keys to Neovim as if the user typed them.
---@param keys string
---@param mode string|nil  "n", "i", "v", "x", "t", "c" (default "t" = interpret)
---@return boolean ok
---@return string|nil error_message
function M.feedkeys(keys, mode)
  local ok, err = pcall(vim.api.nvim_feedkeys, keys, mode or "t", true)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Evaluate a Vim expression.
---@param expr string
---@return any result
---@return string|nil error_message
function M.vim_eval(expr)
  local ok, result = pcall(vim.fn.eval, expr)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

--- Execute arbitrary Lua code in the editor context.
---@param code string
---@return any result
---@return string|nil error_message
function M.exec_lua(code)
  local ok, result = pcall(vim.api.nvim_exec_lua, code, {})
  if not ok then
    return nil, tostring(result)
  end
  return result
end

--- Get the visual selection range (if in visual mode).
---@return table|nil  {buf, start_row, start_col, end_row, end_col, lines}
---@return string|nil error_message
function M.get_visual_selection()
  local mode = vim.api.nvim_get_mode().mode
  if not mode:match("[vV\22]") then
    return nil, "not in visual mode"
  end
  local _, start_row, start_col = unpack(vim.fn.getpos("'<"))
  local _, end_row, end_col = unpack(vim.fn.getpos("'>"))
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, start_row - 1, end_row, false)
  -- Adjust first and last lines to the selection columns
  if #lines == 1 then
    lines[1] = lines[1]:sub(start_col, end_col)
  elseif #lines > 1 then
    lines[1] = lines[1]:sub(start_col)
    lines[#lines] = lines[#lines]:sub(1, end_col)
  end
  return {
    buf = buf,
    start_row = start_row - 1,
    start_col = start_col - 1,
    end_row = end_row - 1,
    end_col = end_col,
    lines = lines,
  }
end

-- ============================================================================
-- Floating Window Operations
-- ============================================================================

--- Create a floating window.
---@param content string[]  Lines of text to display
---@param opts table|nil  {
---   row, col: position (0-1 fractional or absolute)
---   width, height: size
---   relative: "editor"|"cursor"|"win" (default "editor")
---   anchor: "NW"|"NE"|"SW"|"SE"
---   style: "minimal"
---   border: "single"|"double"|"rounded"|"solid"|"shadow"|"none"|table
---   title: string
---   filetype: string (for syntax highlighting)
---   noautocmd: boolean
---   zindex: number
--- }
---@return integer win_id
---@return integer buf_id
function M.float_create(content, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set content
  if content and #content > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  end
  if opts.filetype then
    vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
  end

  -- Calculate position
  local row, col = opts.row or 0, opts.col or 0
  local width = opts.width or math.min(80, vim.o.columns - 4)
  local height = opts.height or math.min(#content, vim.o.lines - 4)
  local relative = opts.relative or "editor"
  local anchor = opts.anchor or "NW"

  -- Handle fractional positioning
  if type(row) == "number" and row > 0 and row <= 1 then
    if relative == "editor" then
      row = math.floor((vim.o.lines - height) * row)
      col = math.floor((vim.o.columns - width) * col)
    elseif relative == "win" then
      local win_height = vim.api.nvim_win_get_height(0)
      local win_width = vim.api.nvim_win_get_width(0)
      row = math.floor((win_height - height) * row)
      col = math.floor((win_width - width) * col)
    end
  end

  -- Build border (string or table, passed through to nvim_open_win)
  local border_style = opts.border or "rounded"

  local config = {
    relative = relative,
    width = width,
    height = height,
    row = row,
    col = col,
    anchor = anchor,
    style = opts.style or "minimal",
    border = border_style,
    title = opts.title,
    zindex = opts.zindex,
    noautocmd = opts.noautocmd,
  }

  local win = vim.api.nvim_open_win(buf, false, config)

  -- Set window options for floating windows
  vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })
  vim.api.nvim_set_option_value("conceallevel", 2, { win = win })

  return win, buf
end

--- Close a floating window (and its buffer).
---@param win integer
---@param keep_buf boolean|nil  If true, don't delete the buffer
---@return boolean ok
function M.float_close(win, keep_buf)
  if not win_valid(win) then
    return false, "window not found"
  end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_close(win, true)
  if not keep_buf and buf_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  return true
end

--- Update the content of a floating window.
---@param win integer
---@param content string[]
---@param opts table|nil  Optional: update position/size too
---@return boolean ok
function M.float_update(win, content, opts)
  if not win_valid(win) then
    return false, "window not found"
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if content then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  end
  if opts then
    pcall(vim.api.nvim_win_set_config, win, opts)
  end
  return true
end

--- Close all floating windows created by xaster.
---@return integer closed_count
function M.float_clear_all()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative and config.relative ~= "" then
      -- Floating/realtive window
      local buf = vim.api.nvim_win_get_buf(win)
      local ok, buftype = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
      -- Only close if it's a scratch/popup buffer
      if ok and (buftype == "nofile" or buftype == "") then
        pcall(vim.api.nvim_win_close, win, true)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        count = count + 1
      end
    end
  end
  return count
end

-- ============================================================================
-- Highlight / Extmark Operations
-- ============================================================================

--- Default highlight namespace for xaster
local HIGHLIGHT_NS = vim.api.nvim_create_namespace("xaster_highlights")

--- Add a highlight region to a buffer using extmarks.
---@param buf integer|nil
---@param start_row integer  0-indexed
---@param start_col integer  0-indexed
---@param end_row integer     0-indexed (inclusive for highlight)
---@param end_col integer     0-indexed (exclusive)
---@param hl_group string     Highlight group name (e.g. "Visual", "Search", "ErrorMsg")
---@param opts table|nil      {virt_text, virt_text_pos, ...}
---@return integer extmark_id
---@return string|nil error_message
function M.highlight_add(buf, start_row, start_col, end_row, end_col, hl_group, opts)
  buf = normalize_buf(buf)
  if not buf then
    return nil, "buffer not found"
  end
  opts = opts or {}
  opts.hl_group = hl_group or "Visual"
  opts.end_row = end_row
  opts.end_col = end_col
  -- Ensure opts are valid for extmark
  opts.strict = false

  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, HIGHLIGHT_NS, start_row, start_col, opts)
  if not ok then
    return nil, tostring(id)
  end
  return id
end

--- Clear a specific highlight extmark.
---@param buf integer|nil
---@param extmark_id integer
---@return boolean ok
function M.highlight_del(buf, extmark_id)
  buf = normalize_buf(buf)
  if not buf then
    return false, "buffer not found"
  end
  local ok, err = pcall(vim.api.nvim_buf_del_extmark, buf, HIGHLIGHT_NS, extmark_id)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Clear all xaster highlights from a buffer.
---@param buf integer|nil
---@return integer cleared_count
function M.highlight_clear(buf)
  buf = normalize_buf(buf)
  if not buf then
    return 0
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, HIGHLIGHT_NS, 0, -1, {})
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_del_extmark, buf, HIGHLIGHT_NS, mark[1])
  end
  return #marks
end

--- Clear ALL xaster highlights from ALL buffers.
---@return integer cleared_count
function M.highlight_clear_all()
  local count = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf_valid(buf) then
      count = count + M.highlight_clear(buf)
    end
  end
  return count
end

--- Set virtual text at a position.
---@param buf integer|nil
---@param row integer  0-indexed
---@param col integer  0-indexed
---@param text string   Text to display
---@param hl_group string|nil  Highlight group
---@return integer extmark_id
function M.virtual_text_set(buf, row, col, text, hl_group)
  buf = normalize_buf(buf)
  if not buf then
    return nil, "buffer not found"
  end
  local opts = {
    virt_text = { { text, hl_group or "Comment" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  }
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, HIGHLIGHT_NS, row, col, opts)
  if not ok then
    return nil, tostring(id)
  end
  return id
end

-- ============================================================================
-- LSP Operations
-- ============================================================================

--- Get hover information at the cursor position.
---@return table|nil hover_data  {contents, range}
---@return string|nil error_message
function M.lsp_hover()
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params()
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return nil, "no LSP client attached"
  end
  local results = {}
  for _, client in ipairs(clients) do
    if client.supports_method("textDocument/hover") then
      local ok, response = pcall(client.request_sync, client, "textDocument/hover", params, 1000, bufnr)
      if ok and response and response.result then
        local r = response.result
        if r.contents then
          table.insert(results, r)
        end
      end
    end
  end
  if #results == 0 then
    return nil, "no hover information available"
  end
  return results
end

--- Go to definition of the symbol under cursor.
---@return table|nil locations  Array of {uri, range, targetUri, targetRange}
---@return string|nil error_message
function M.lsp_definition()
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params()
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.supports_method("textDocument/definition") then
      local ok, response = pcall(client.request_sync, client, "textDocument/definition", params, 1000, bufnr)
      if ok and response and response.result and not response.err then
        return response.result
      end
    end
  end
  return nil, "no definition found"
end

--- Find references of the symbol under cursor.
---@param include_declaration boolean|nil
---@return table|nil locations
---@return string|nil error_message
function M.lsp_references(include_declaration)
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params()
  params.context = { includeDeclaration = include_declaration ~= false }
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.supports_method("textDocument/references") then
      local ok, response = pcall(client.request_sync, client, "textDocument/references", params, 2000, bufnr)
      if ok and response and response.result and not response.err then
        return response.result
      end
    end
  end
  return nil, "no references found"
end

--- Rename the symbol under cursor (preview-only version).
---@param new_name string
---@return table|nil workspace_edit
---@return string|nil error_message
function M.lsp_rename(new_name)
  if not new_name or new_name == "" then
    return nil, "new name required"
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params()
  params.newName = new_name
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.supports_method("textDocument/rename") then
      local ok, response = pcall(client.request_sync, client, "textDocument/rename", params, 2000, bufnr)
      if ok and response and response.result and not response.err then
        return response.result
      end
    end
  end
  return nil, "rename not supported or failed"
end

--- Get workspace symbols matching a query.
---@param query string
---@return table|nil symbols
function M.lsp_workspace_symbols(query)
  local params = { query = query or "" }
  local results = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    if client.supports_method("workspace/symbol") then
      local ok, response = pcall(client.request_sync, client, "workspace/symbol", params, 2000, vim.api.nvim_get_current_buf())
      if ok and response and response.result and not response.err then
        for _, sym in ipairs(response.result) do
          table.insert(results, sym)
        end
      end
    end
  end
  return results
end

--- Get document symbols (outline).
---@param buf integer|nil
---@return table|nil symbols
function M.lsp_document_symbols(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
  local results = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client.supports_method("textDocument/documentSymbol") then
      local ok, response = pcall(client.request_sync, client, "textDocument/documentSymbol", params, 1000, buf)
      if ok and response and response.result and not response.err then
        for _, sym in ipairs(response.result) do
          table.insert(results, sym)
        end
      end
    end
  end
  return results
end

--- Get all diagnostics.
---@param buf integer|nil  nil = all buffers
---@return table[] diagnostics
function M.lsp_diagnostics(buf)
  if buf then
    return vim.diagnostic.get(buf)
  end
  local all = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if buf_valid(b) then
      local diags = vim.diagnostic.get(b)
      for _, d in ipairs(diags) do
        d.buf = b
        d.filename = vim.api.nvim_buf_get_name(b)
        table.insert(all, d)
      end
    end
  end
  return all
end

--- Execute a code action.
---@param action_index integer|nil  Index of action to execute (nil = list all)
---@return table|nil actions
---@return string|nil error_message
function M.lsp_code_actions(action_index)
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_range_params()
  params.context = { diagnostics = vim.lsp.util.make_lsp_range_params().context.diagnostics }
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local all_actions = {}
  for _, client in ipairs(clients) do
    if client.supports_method("textDocument/codeAction") then
      local ok, response = pcall(client.request_sync, client, "textDocument/codeAction", params, 2000, bufnr)
      if ok and response and response.result and not response.err then
        for _, action in ipairs(response.result) do
          table.insert(all_actions, action)
        end
      end
    end
  end

  if action_index and all_actions[action_index] then
    -- Execute the selected action
    local action = all_actions[action_index]
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit)
    end
    if action.command then
      vim.lsp.buf.execute_command(action.command)
    end
    return { executed = action }
  end

  return all_actions
end

-- ============================================================================
-- Register Operations
-- ============================================================================
-- Vim registers hold a single value per name. Xaster extends them with:
--   - Stack semantics (each register maintains an internal push/pop stack)
--   - Type awareness (characterwise / linewise / blockwise)
--   - Expression registers (Lua evaluation on get)
--   - Register-based navigation (jump to register-named location)

-- Internal stacks for named registers (a-z, A-Z).
-- Each stack entry: { value: string, type: string, time: number }
-- The Vim register always holds the stack top.
local register_stacks = {}
local REGISTER_MAX_STACK = 20  -- max entries per register stack

--- Get content of a register.
---@param reg string  Register name (e.g. '"', 'a', '+', '*', '0'-'9')
---@return string|nil content
function M.register_get(reg)
  if not reg or reg == "" then
    return nil, "register name required"
  end
  local ok, content = pcall(vim.fn.getreg, reg)
  if not ok then
    return nil, tostring(content)
  end
  return content
end

--- Get the type of a register.
---@param reg string  Register name
---@return string  "v" (characterwise), "V" (linewise), or "\22" (blockwise)
function M.register_get_type(reg)
  if not reg or reg == "" then return "v" end
  local ok, rtype = pcall(vim.fn.getregtype, reg)
  if not ok then return "v" end
  return rtype
end

--- Set content of a register with optional type.
---@param reg string
---@param value string
---@param regtype string|nil  "v" (characterwise, default), "V" (linewise), "\22" (blockwise)
---@return boolean ok
function M.register_set(reg, value, regtype)
  if not reg or reg == "" then
    return false, "register name required"
  end
  local ok, err = pcall(vim.fn.setreg, reg, value, regtype or "v")
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Push a value onto a register's internal stack.
--- The Vim register is updated to hold the new top.
--- Returns the new stack depth.
---@param reg string      Register name (named registers a-z, A-Z only)
---@param value string    Content to push
---@param regtype string|nil  "v"/"V"/"\22" (default "v")
---@return table  { ok, depth, reg }
function M.register_push(reg, value, regtype)
  if not reg or reg == "" then
    return { ok = false, error = "register name required" }
  end
  if not reg:match("^[a-zA-Z]$") then
    return { ok = false, error = "register_push only works with named registers a-z, A-Z" }
  end
  regtype = regtype or "v"

  -- Init stack if needed
  if not register_stacks[reg] then
    register_stacks[reg] = {}
  end

  local stack = register_stacks[reg]
  table.insert(stack, {
    value = value,
    type = regtype,
    time = os.time(),
  })

  -- Trim to max
  while #stack > REGISTER_MAX_STACK do
    table.remove(stack, 1)
  end

  -- Update Vim register to stack top
  pcall(vim.fn.setreg, reg, value, regtype)

  return { ok = true, depth = #stack, reg = reg }
end

--- Pop the top value from a register's internal stack.
--- Vim register is updated to the new top (or cleared if empty).
---@param reg string  Register name
---@return table  { ok, value, type, depth_before, depth_after, reg }
function M.register_pop(reg)
  if not reg or reg == "" then
    return { ok = false, error = "register name required" }
  end
  if not reg:match("^[a-zA-Z]$") then
    return { ok = false, error = "register_pop only works with named registers a-z, A-Z" }
  end

  local stack = register_stacks[reg]
  if not stack or #stack == 0 then
    return { ok = false, error = "register stack is empty", reg = reg }
  end

  local entry = table.remove(stack)
  local depth = #stack

  -- Update Vim register to new top or clear
  if depth > 0 then
    local top = stack[depth]
    pcall(vim.fn.setreg, reg, top.value, top.type)
  else
    pcall(vim.fn.setreg, reg, "")
  end

  return {
    ok = true,
    value = entry.value,
    type = entry.type,
    depth_before = depth + 1,
    depth_after = depth,
    reg = reg,
  }
end

--- Peek at the register stack without popping.
---@param reg string       Register name
---@param depth integer|nil  Depth from top (1 = top, nil = entire stack info)
---@return table  { ok, entries, total, reg }
function M.register_peek(reg, depth)
  if not reg or reg == "" then
    return { ok = false, error = "register name required" }
  end
  if not reg:match("^[a-zA-Z]$") then
    return { ok = false, error = "register_peek only works with named registers a-z, A-Z" }
  end

  local stack = register_stacks[reg]
  if not stack or #stack == 0 then
    return { ok = true, entries = {}, total = 0, reg = reg }
  end

  if depth then
    local idx = math.max(1, #stack - depth + 1)
    local entry = stack[idx]
    if entry then
      return { ok = true, entries = { {
        value = entry.value:sub(1, 200),
        type = entry.type,
        time = entry.time,
      } }, total = #stack, reg = reg }
    end
    return { ok = false, error = "depth " .. depth .. " out of range", reg = reg }
  end

  -- Return all entries (newest first) with truncated content
  local entries = {}
  for i = #stack, 1, -1 do
    local e = stack[i]
    entries[#entries + 1] = {
      value = #e.value > 200 and e.value:sub(1, 200) .. "..." or e.value,
      type = e.type,
      time = e.time,
    }
  end
  return { ok = true, entries = entries, total = #stack, reg = reg }
end

--- Rotate the register stack: move top to bottom (direction=1) or bottom to top (direction=-1).
--- Vim register is updated to the new stack top.
---@param reg string        Register name
---@param direction integer  1 = top->bottom (like Vim numbered registers), -1 = bottom->top
---@return table  { ok, depth, reg }
function M.register_rotate(reg, direction)
  if not reg or reg == "" then
    return { ok = false, error = "register name required" }
  end
  if not reg:match("^[a-zA-Z]$") then
    return { ok = false, error = "register_rotate only works with named registers a-z, A-Z" }
  end

  local stack = register_stacks[reg]
  if not stack or #stack < 2 then
    return { ok = false, error = "stack has fewer than 2 entries, nothing to rotate", reg = reg }
  end

  if direction >= 0 then
    -- Top -> bottom: move last entry to front
    local top = table.remove(stack)
    table.insert(stack, 1, top)
  else
    -- Bottom -> top: move first entry to end
    local bottom = table.remove(stack, 1)
    table.insert(stack, bottom)
  end

  -- Update Vim register to new top
  local top = stack[#stack]
  pcall(vim.fn.setreg, reg, top.value, top.type)

  return { ok = true, depth = #stack, reg = reg }
end

--- Get the size of the register stack.
---@param reg string
---@return integer
function M.register_size(reg)
  local stack = register_stacks[reg]
  if not stack then return 0 end
  return #stack
end

--- Set a register to an expression that is evaluated on every read.
--- The expression is Lua code stored internally; register_get evaluates it live.
---@param reg string    Register name (a-z, A-Z)
---@param expr string   Lua expression (e.g. "vim.fn.line('$')")
---@return table  { ok, reg }
function M.register_set_expression(reg, expr)
  if not reg or not reg:match("^[a-zA-Z]$") then
    return { ok = false, error = "expression register requires named register a-z, A-Z" }
  end
  if not expr or expr == "" then
    return { ok = false, error = "expression required" }
  end

  if not register_stacks[reg] then
    register_stacks[reg] = {}
  end
  local stack = register_stacks[reg]
  -- Mark the stack with an expression flag
  stack._expression = expr

  -- Evaluate and set initial value
  local ok_eval, result = pcall(function()
    return load("return " .. expr)()
  end)
  if ok_eval then
    pcall(vim.fn.setreg, reg, tostring(result))
  end

  return { ok = true, reg = reg, expression = expr }
end

--- Evaluate a register: if it has an expression, evaluate it live.
--- Otherwise behaves like normal register_get.
---@param reg string
---@return string|nil content
function M.register_eval(reg)
  if not reg or reg == "" then return nil end

  local stack = register_stacks[reg]
  if stack and stack._expression then
    local ok, result = pcall(function()
      return load("return " .. stack._expression)()
    end)
    if ok then
      local s = tostring(result)
      pcall(vim.fn.setreg, reg, s)
      return s
    end
    -- Fall through to normal get
  end
  return M.register_get(reg)
end

--- Jump to a file:line location stored in a register's content.
--- The register content is parsed as "filepath:linenumber" or "filepath:linenumber:col".
---@param reg string  Register name whose content is a file location
---@return table|nil  { ok, filepath, row, col, buf } or nil if not parseable
function M.register_jump_to(reg)
  local content = M.register_get(reg)
  if not content or content == "" then
    return nil
  end

  -- Parse "file:line" or "file:line:col"
  local file, lnum, col = content:match("^([^:]+):(%d+):?(%d*)$")
  if not file then
    -- Try just "file:line" without strict anchors
    file, lnum = content:match("(.+):(%d+)")
    col = nil
  end
  if not file or not lnum then
    return nil  -- content is not a navigable location
  end

  lnum = tonumber(lnum) or 1
  col = tonumber(col) or 0

  -- Resolve and open the file
  local resolved = vim.fn.resolve(vim.fn.expand(file))
  local ok_open, buf = pcall(function()
    local b, err = M.file_ensure_open(resolved, { focus = true })
    return b, err
  end)
  if not ok_open or not buf then
    return nil
  end

  M.cursor_set(0, lnum, col)
  vim.cmd("redraw!")
  return {
    ok = true,
    filepath = resolved,
    row = lnum,
    col = col,
    buf = buf,
  }
end

--- List all non-empty registers with stack info.
---@return table[]  Array of {name, type, content (truncated), stack_depth}
function M.register_list()
  local registers = {}
  for _, reg_name in ipairs(vim.fn.split(vim.fn.execute("registers"), "\n")) do
    if reg_name:match('^".') then
      local name = reg_name:sub(2, 2)
      local content = M.register_get(name)
      if content and content ~= "" then
        local ctype = M.register_get_type(name)
        local depth = M.register_size(name)
        table.insert(registers, {
          name = name,
          type = ctype,
          content = #content > 200 and content:sub(1, 200) .. "..." or content,
          stack_depth = depth > 1 and depth or nil,
        })
      end
    end
  end
  return registers
end

--- Dump all register stacks (for observe / system prompt).
---@return string|nil
function M.register_dump()
  local parts = {}
  for reg, stack in pairs(register_stacks) do
    if reg:match("^[a-zA-Z]$") and #stack > 0 then
      local expr_flag = stack._expression and " [expr]" or ""
      local top = stack[#stack]
      local preview = top.value:gsub("\n", "\\n"):sub(1, 80)
      if #top.value > 80 then preview = preview .. "..." end
      parts[#parts + 1] = string.format("  \"%s (%d)%s: %s", reg, #stack, expr_flag, preview)
    end
  end
  if #parts == 0 then return nil end
  return "Register stacks:\n" .. table.concat(parts, "\n")
end

-- ============================================================================
-- Mark Operations
-- ============================================================================

--- Get position of a mark.
---@param mark string  e.g. 'a'-'z', '.', "'", '"', '^', etc.
---@return table|nil  {buf, row (1-indexed), col (0-indexed), filename}
function M.mark_get(mark)
  if not mark or mark == "" then
    return nil, "mark name required"
  end
  local ok, pos = pcall(vim.fn.getpos, "'" .. mark)
  if not ok or #pos < 4 then
    return nil, "mark not set: " .. mark
  end
  local buf = pos[1]
  local row = pos[2]
  local col = pos[3] - 1 -- convert to 0-indexed
  return {
    buf = buf,
    row = row,
    col = col,
    filename = buf > 0 and vim.api.nvim_buf_get_name(buf) or nil,
  }
end

--- Set a mark at a position.
---@param mark string
---@param row integer  1-indexed
---@param col integer|nil  0-indexed
---@return boolean ok
function M.mark_set(mark, row, col)
  if not mark or mark == "" then
    return false, "mark name required"
  end
  local buf = vim.api.nvim_get_current_buf()
  local ok, err = pcall(vim.fn.setpos, "'" .. mark, { buf, row, col or 0, 0 })
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Get the jumplist for a window.
---@param win integer|nil
---@return table[] jumps
function M.jumplist_get(win)
  win = normalize_win(win)
  if not win then
    return {}
  end
  local current_win = vim.api.nvim_get_current_win()
  if win ~= current_win then
    vim.api.nvim_set_current_win(win)
  end
  local jumps = vim.fn.getjumplist(win)
  if win ~= current_win then
    vim.api.nvim_set_current_win(current_win)
  end
  if not jumps or #jumps < 2 then
    return {}
  end
  local result = {}
  local jump_list, current_index = jumps[1], jumps[2]
  for i, j in ipairs(jump_list) do
    table.insert(result, {
      buf = j.bufnr,
      row = j.lnum,
      col = j.col - 1,
      coladd = j.coladd,
      filename = j.bufnr > 0 and vim.api.nvim_buf_get_name(j.bufnr) or nil,
      current = i == current_index,
    })
  end
  return result
end

-- ============================================================================
-- Undo / Redo Operations
-- ============================================================================

--- Create an undo savepoint (undojoin barrier).
---@return boolean ok
function M.undo_savepoint()
  vim.api.nvim_command("undojoin")
  return true
end

--- Undo one or more changes.
---@param count integer|nil  Number of undo steps (default 1)
---@return boolean ok
function M.undo(count)
  count = count or 1
  vim.api.nvim_command("undo " .. count)
  return true
end

--- Redo one or more changes.
---@param count integer|nil
---@return boolean ok
function M.redo(count)
  count = count or 1
  vim.api.nvim_command("redo " .. count)
  return true
end

--- Get the undo tree for a buffer.
---@param buf integer|nil
---@return table|nil undo_tree
function M.undo_tree(buf)
  buf = normalize_buf(buf)
  if not buf then
    return nil, "buffer not found"
  end
  local ut = vim.fn.undotree(buf)
  -- Simplify for JSON serialization
  local entries = {}
  for _, entry in ipairs(ut.entries or {}) do
    table.insert(entries, {
      seq = entry.seq,
      time = entry.time,
      save = entry.save,
      newhead = entry.alt and true or nil,
      changes = entry.alt and #entry.alt or 0,
    })
  end
  return {
    seq_current = ut.seq_cur,
    seq_last = ut.seq_last,
    save_last = ut.save_last,
    entries = entries,
  }
end

-- ============================================================================
-- Tabs Operations
-- ============================================================================

--- List all tabpages.
---@return table[] tabs
function M.tab_list()
  local tabs = {}
  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local wins = {}
    local current_win = vim.api.nvim_tabpage_get_win(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      table.insert(wins, {
        id = win,
        buffer = buf,
        buffer_name = vim.api.nvim_buf_get_name(buf),
        current = win == current_win,
      })
    end
    table.insert(tabs, {
      id = tab,
      current = tab == current_tab,
      windows = wins,
    })
  end
  return tabs
end

-- ============================================================================
-- Quickfix / Location List Operations
-- ============================================================================

--- Get quickfix list items.
---@return table[] items
function M.quickfix_list()
  local items = vim.fn.getqflist()
  for _, item in ipairs(items) do
    item.filename = item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or item.text
  end
  return items
end

--- Set quickfix list and optionally open it.
---@param items table[]  Array of {filename, lnum, col, text, type}
---@param action string|nil  "open" to open the quickfix window
---@return boolean ok
function M.quickfix_set(items, action)
  vim.fn.setqflist({}, "r", { items = items })
  if action == "open" then
    vim.api.nvim_command("copen")
  end
  return true
end

-- ============================================================================
-- Complete Editor Snapshot (observe)
-- ============================================================================

--- Take a complete snapshot of the current editor state.
--- This is the primary way the Agent perceives the editor state.
---@return table snapshot
function M.observe()
  local current_buf = vim.api.nvim_get_current_buf()
  local current_win = vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode()
  local cursor = vim.api.nvim_win_get_cursor(current_win)

  -- Current file info
  local current_file = {
    buf = current_buf,
    name = vim.api.nvim_buf_get_name(current_buf),
    filetype = vim.api.nvim_get_option_value("filetype", { buf = current_buf }),
    modified = vim.api.nvim_get_option_value("modified", { buf = current_buf }),
    line_count = vim.api.nvim_buf_line_count(current_buf),
    cursor = { row = cursor[1], col = cursor[2] },
  }

  -- Visible content (current window viewport)
  local win_top = vim.fn.line("w0", current_win)
  local win_bot = vim.fn.line("w$", current_win)
  local visible_lines = vim.api.nvim_buf_get_lines(current_buf, win_top - 1, win_bot, false)

  -- All listed buffers (summary)
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf_valid(buf) and vim.api.nvim_get_option_value("buflisted", { buf = buf }) then
      local name = vim.api.nvim_buf_get_name(buf)
      local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
      local modified = vim.api.nvim_get_option_value("modified", { buf = buf })
      -- Only include files (not no-name, not special buftypes)
      local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
      if name ~= "" or bt == "" then
        table.insert(buffers, {
          id = buf,
          name = name,
          filetype = ft,
          modified = modified,
          line_count = vim.api.nvim_buf_line_count(buf),
        })
      end
    end
  end

  -- Window layout
  local windows = M.window_list()
  local tabs = M.tab_list()

  -- Diagnostics for current buffer
  local diagnostics = vim.diagnostic.get(current_buf)

  -- Xaster connection status (lazy require to avoid circular dependency)
  local xaster_status = { running = false, clients = {} }
  local ok_srv, srv = pcall(require, "xaster.server")
  if ok_srv and srv.status then
    local ok_st, st = pcall(srv.status)
    if ok_st then xaster_status = st end
  end

  return {
    current_file = current_file,
    visible_content = visible_lines,
    visible_range = { start = win_top, end_ = win_bot },
    mode = mode.mode,
    buffers = buffers,
    windows = windows,
    tabs = tabs,
    diagnostics = diagnostics,
    xaster = xaster_status,
  }
end

-- ============================================================================
-- File Operations -- Agent edits through Vim, not filesystem
-- ============================================================================
-- The Agent operates on Vim buffers directly. Vim handles saving to disk.
-- These are thin wrappers that ensure the file is open in Vim first,
-- then apply edits through Vim's native API. No filesystem round-trip.

--- Find a buffer by file path. Returns buf id or nil.
---@param filepath string
---@return integer|nil buf_id
function M.find_buffer_by_file(filepath)
  if not filepath or filepath == "" then
    return nil
  end
  local resolved = vim.fn.resolve(vim.fn.expand(filepath))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local buf_resolved = vim.fn.resolve(name)
        if resolved == buf_resolved or name == filepath then
          return buf
        end
      end
    end
  end
  return nil
end

--- Ensure a file is open in Neovim. Returns the buffer id.
--- If already open in a window, focuses that window.
--- If not open, opens it in the current window.
---@param filepath string  Absolute or relative file path
---@param opts table|nil  { focus: boolean, split: string|nil }
---@return integer buf_id
---@return string|nil error_message
function M.file_ensure_open(filepath, opts)
  if not filepath or filepath == "" then
    return nil, "filepath required"
  end

  opts = opts or {}
  local should_focus = opts.focus ~= false  -- default true
  local resolved = vim.fn.resolve(vim.fn.expand(filepath))

  -- Check if already open
  local existing_buf = M.find_buffer_by_file(resolved)
  if existing_buf then
    if should_focus then
      -- Find a window showing this buffer and focus it
      local win_found = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == existing_buf then
          vim.api.nvim_set_current_win(win)
          win_found = true
          break
        end
      end
      -- If buffer exists but isn't in any window, show it in current window
      if not win_found then
        vim.api.nvim_win_set_buf(0, existing_buf)
      end
    end
    return existing_buf
  end

  -- Not open -- open it now
  if not vim.loop.fs_stat(resolved) then
    -- File doesn't exist yet -- create a new buffer with the name
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, resolved)
    if should_focus then
      vim.api.nvim_win_set_buf(0, buf)
    end
    return buf
  end

  -- File exists on disk -- open it with :edit
  if should_focus then
    local ok, err = pcall(vim.api.nvim_command, "edit " .. vim.fn.fnameescape(resolved))
    if not ok then
      return nil, "failed to open file: " .. tostring(err)
    end
  else
    -- Open without focusing: use :badd + bufload
    vim.api.nvim_command("badd " .. vim.fn.fnameescape(resolved))
    local buf = M.find_buffer_by_file(resolved)
    if buf then
      vim.fn.bufload(buf)
      return buf
    end
    return nil, "failed to add buffer for: " .. resolved
  end

  local new_buf = vim.api.nvim_get_current_buf()
  -- Detect filetype
  vim.api.nvim_command("filetype detect")
  return new_buf
end

--- Read a file through Neovim (smart read).
--- Opens the file in Neovim if not already open, reads content,
--- and returns it in cat -n format (matching the built-in Read tool format).
---@param filepath string  Absolute or relative file path
---@param opts table|nil  { start: integer, end_: integer, focus: boolean }
---@return table  { ok, filepath, buf, lines, line_count, formatted (cat -n) }
---@return string|nil error_message
function M.file_read(filepath, opts)
  opts = opts or {}
  local start_line = opts.start or 0
  local end_line = opts.end_ or -1

  -- Ensure file is open and focused
  local buf, err = M.file_ensure_open(filepath, { focus = true })
  if not buf then
    return nil, err
  end

  local total = vim.api.nvim_buf_line_count(buf)
  local s = math.max(0, start_line)
  local e = end_line
  if e == nil or e == -1 then
    e = total
  else
    e = math.min(e, total)
  end

  local lines = vim.api.nvim_buf_get_lines(buf, s, e, false)

  -- Build cat -n formatted output (matching Read tool format)
  local formatted_lines = {}
  for i, line in ipairs(lines) do
    local line_num = s + i
    local num_str = string.format("%6d\t", line_num)
    table.insert(formatted_lines, num_str .. line)
  end

  -- Move cursor to the start of the visible content
  -- (keep whatever position if we're reading a specific range)
  if s == 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { 1, 0 })
  end

  return {
    ok = true,
    filepath = vim.api.nvim_buf_get_name(buf),
    buf = buf,
    lines = lines,
    line_count = #lines,
    total_lines = total,
    formatted = table.concat(formatted_lines, "\n"),
  }
end

--- Write content to a file through Neovim.
---
--- Default: instant write (animated=false). Content replaces the buffer at once.
--- Set animated=true for cosmetic streaming typewriter effect.
---
--- Supports two content modes:
---   1. Full replace: provide `content` (string or string[])
---   2. Precise edits: provide `edits` array of {start_row, start_col, end_row, end_col, text}
---
---@param filepath string  File to write to
---@param params table  {
---   content: string|string[],
---   edits: table[],
---   animated: boolean (default false),
---   chunk_delay_ms: integer (default 15),
--- }
---@return table  { ok, filepath, buf, bytes_written, total_lines, animated }
---@return string|nil error_message
function M.file_write(filepath, params)
  if not filepath or filepath == "" then
    return nil, "filepath required"
  end

  params = params or {}
  local animated = params.animated == true   -- default: instant (no streaming)
  local chunk_delay_ms = params.chunk_delay_ms or 15

  local resolved = vim.fn.resolve(vim.fn.expand(filepath))

  -- Ensure file is open and focused FIRST -- user sees context before edit
  local buf, err = M.file_ensure_open(resolved, { focus = true })
  if not buf then
    return nil, err
  end

  -- Determine what lines we're writing
  local new_lines = {}
  local bytes_written = 0
  local edit_mode = nil

  if params.edits and #params.edits > 0 then
    edit_mode = "edits"
  elseif params.content ~= nil then
    edit_mode = "full"
    if type(params.content) == "string" then
      new_lines = vim.split(params.content, "\n", { plain = true })
    else
      new_lines = params.content
    end
  else
    return nil, "either 'content' or 'edits' is required"
  end

  -- -- ANIMATED STREAMING MODE ------------------------------------------
  if animated and edit_mode == "full" then
    -- Create undo savepoint
    M.undo_savepoint()

    -- Clear buffer first (instant), then stream new lines
    lock_bypass(buf)
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {})
    lock_restore(buf)

    local total = #new_lines
    local ms_per_line = math.max(8, chunk_delay_ms)
    local vcursor_ns = vim.api.nvim_create_namespace("xaster_vcursor")
    local flash_ns = vim.api.nvim_create_namespace("xaster_vcursor_flash")

    -- Get or create a highlight for the "fresh line" effect
    vim.api.nvim_set_hl(0, "xasterFreshLine", {
      bg = "#1a3a1a", fg = "#a6e3a1", default = true,
    })

    -- Track fresh line extmarks for cleanup
    local fresh_extmarks = {}

    -- Start streaming: insert lines with visible animation
    local function stream_next(idx)
      if idx > total then
        -- All lines inserted -- save and check diagnostics
        vim.schedule(function()
          -- Clear remaining fresh line highlights
          for _, em_id in ipairs(fresh_extmarks) do
            pcall(vim.api.nvim_buf_del_extmark, buf, flash_ns, em_id)
          end

          M.buffer_save(buf)

          -- Move cursor to end of written content
          pcall(vim.api.nvim_win_set_cursor, 0, { total, 0 })
          vim.cmd("redraw!")

          -- Brief delay then check diagnostics
          vim.defer_fn(function()
            local diags = M.lsp_diagnostics(buf)
            local ui_ok, ui_mod = pcall(require, "xaster.ui")
            if ui_ok and #diags > 0 then
              local err_count = 0
              for _, d in ipairs(diags) do
                if d.severity and d.severity <= 1 then err_count = err_count + 1 end
              end
              if err_count > 0 then
                ui_mod.toast(string.format("[WARN] %d errors, %d warnings", err_count, #diags - err_count), "warn")
              else
                ui_mod.toast(string.format("[OK] %d lines written (%d warnings)", total, #diags), "info")
              end
            elseif ui_ok then
              ui_mod.toast(string.format("[OK] %d lines written", total), "info")
            end
          end, 100)
        end)
        return
      end

      -- Insert one line
      lock_bypass(buf)
      pcall(vim.api.nvim_buf_set_lines, buf, idx - 1, idx - 1, false, { new_lines[idx] })
      lock_restore(buf)

      -- Briefly highlight the freshly inserted line
      local ok_flash, flash_id = pcall(vim.api.nvim_buf_set_extmark, buf, flash_ns, idx - 1, 0, {
        hl_group = "xasterFreshLine",
        priority = 180,
        strict = false,
        ephemeral = true,
      })
      if ok_flash and flash_id then
        fresh_extmarks[#fresh_extmarks + 1] = flash_id
        -- Fade after 800ms
        vim.defer_fn(function()
          pcall(vim.api.nvim_buf_del_extmark, buf, flash_ns, flash_id)
        end, 800)
      end

      -- Flash the line being written (visual feedback for the user)
      local ok_flash_mod, flash_mod = pcall(require, "xaster.vcursor")
      if ok_flash_mod and flash_mod.flash then
        flash_mod.flash(buf, idx - 1, 0)
      end

      -- Move editor cursor to the current line (user sees the progress)
      vim.schedule(function()
        pcall(vim.api.nvim_win_set_cursor, 0, { idx, 0 })
        vim.cmd("redraw!")
      end)

      -- Natural typing rhythm: faster start, slower later with slight variation
      local delay = ms_per_line
      if idx > 30 then
        delay = math.floor(ms_per_line * 1.4)
      elseif idx > 60 then
        delay = math.floor(ms_per_line * 1.8)
      end

      vim.defer_fn(function()
        stream_next(idx + 1)
      end, delay)
    end

    -- Start the stream
    stream_next(1)

    -- Return immediately -- animation runs async
    return {
      ok = true,
      filepath = resolved,
      buf = buf,
      bytes_written = #table.concat(new_lines, "\n"),
      total_lines = total,
      animated = true,
      streaming = true,
    }
  end

  -- -- INSTANT MODE (animated=false) ------------------------------------
  M.undo_savepoint()

  if edit_mode == "edits" then
    lock_bypass(buf)
    for _, edit in ipairs(params.edits) do
      local text = edit.text or ""
      local replacement = vim.split(text, "\n", { plain = true })
      local ok, edit_err = pcall(
        vim.api.nvim_buf_set_text,
        buf,
        edit.start_row or 0,
        edit.start_col or 0,
        edit.end_row or 0,
        edit.end_col or 0,
        replacement
      )
      if ok then
        bytes_written = bytes_written + #text
      else
        lock_restore(buf)
        return nil, "edit failed at row " .. tostring(edit.start_row) .. ": " .. tostring(edit_err)
      end
    end
    lock_restore(buf)
  else
    lock_bypass(buf)
    local ok, set_err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, new_lines)
    lock_restore(buf)
    if not ok then
      return nil, "failed to write content: " .. tostring(set_err)
    end
    bytes_written = #table.concat(new_lines, "\n")
  end

  -- Save to disk
  local save_ok, save_err = M.buffer_save(buf)
  if not save_ok then
    return {
      ok = true,
      filepath = resolved,
      buf = buf,
      bytes_written = bytes_written,
      warning = "content modified in buffer but save failed: " .. (save_err or "unknown"),
    }
  end

  -- Check diagnostics
  local diagnostics = M.lsp_diagnostics(buf)

  return {
    ok = true,
    filepath = resolved,
    buf = buf,
    bytes_written = bytes_written,
    total_lines = edit_mode == "full" and #new_lines or #params.edits,
    diagnostics = diagnostics,
    diag_count = #diagnostics,
    has_errors = #vim.tbl_filter(function(d) return d.severity and d.severity <= 1 end, diagnostics) > 0,
    animated = false,
  }
end

--- Set up bidirectional file sync between Neovim and the filesystem.
--- Called once during plugin setup. Creates autocmds that:
---   1. Auto-reload buffers when files change on disk (FocusGained + timer)
---   2. Track which buffers xaster has modified
---@param opts table|nil  { checktime_interval_ms: integer, auto_reload: boolean }
function M.file_sync_setup(opts)
  opts = opts or {}
  local checktime_ms = opts.checktime_interval_ms or 2000
  local auto_reload = opts.auto_reload ~= false

  local augroup = vim.api.nvim_create_augroup("xaster_file_sync", { clear = true })

  -- Track file modification times for all listed buffers
  local file_mtimes = {}

  local function update_mtime(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then return end
    local stat = vim.loop.fs_stat(name)
    if stat then
      file_mtimes[buf] = stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6)
    end
  end

  local function check_and_reload()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name == "" then goto continue end
        local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
        if buftype ~= "" then goto continue end

        local stat = vim.loop.fs_stat(name)
        if not stat then goto continue end
        local cur_mtime = stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6)
        local prev_mtime = file_mtimes[buf]

        if prev_mtime and cur_mtime > prev_mtime then
          -- File changed on disk -- auto-reload
          if auto_reload then
            -- Only reload if buffer has no unsaved changes
            local modified = vim.api.nvim_get_option_value("modified", { buf = buf })
            if not modified then
              -- Find a window showing this buffer
              for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == buf then
                  local view = vim.fn.winsaveview()
                  vim.api.nvim_buf_call(buf, function()
                    vim.cmd("edit!")
                  end)
                  vim.fn.winrestview(view)
                  break
                end
              end
            end
          end
          file_mtimes[buf] = cur_mtime
        elseif not prev_mtime then
          file_mtimes[buf] = cur_mtime
        end
        ::continue::
      end
    end
  end

  -- Initialize mtime tracking for all existing buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      update_mtime(buf)
    end
  end

  -- Update mtime when a buffer is saved
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(args)
      update_mtime(args.buf)
    end,
    desc = "xaster: track file mtime after save",
  })

  -- Reload on FocusGained
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      check_and_reload()
    end,
    desc = "xaster: auto-reload externally changed files on focus",
  })

  -- Update mtime when a new buffer is entered
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      update_mtime(args.buf)
    end,
    desc = "xaster: track mtime on buffer enter",
  })

  -- Periodic check timer
  local timer = vim.loop.new_timer()
  if timer then
    timer:start(checktime_ms, checktime_ms, vim.schedule_wrap(function()
      if vim.api.nvim_get_mode().mode == "n" then
        check_and_reload()
      end
    end))
  end

  -- Cleanup on VimLeave
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end,
    desc = "xaster: cleanup file sync timer",
    once = true,
  })

  -- Return control handle
  return {
    check = check_and_reload,
    update_mtime = update_mtime,
  }
end

-- ============================================================================
-- Diff Computation
-- ============================================================================

--- Compute a unified diff between two line arrays.
--- Uses LCS (Longest Common Subsequence) to produce standard diff -u output.
--- Falls back to a fast summary for very large files (>2000 lines total).
---@param old_lines string[]  Original content
---@param new_lines string[]  New content
---@param context_lines integer|nil  Context lines around hunks (default 3)
---@return table  { hunks: table[], added: integer, removed: integer, unchanged: boolean|nil, file_too_large: boolean|nil }
function M.compute_unified_diff(old_lines, new_lines, context_lines)
  context_lines = context_lines or 3
  local m = #old_lines
  local n = #new_lines

  -- Fallback for very large files: skip full LCS
  if m + n > 2000 then
    local added = math.max(0, n - m)
    local removed = math.max(0, m - n)
    local changed = 0
    local min_len = math.min(m, n)
    for i = 1, min_len do
      if old_lines[i] ~= new_lines[i] then changed = changed + 1 end
    end
    return {
      hunks = {},
      added = added + changed,
      removed = removed + changed,
      file_too_large = true,
    }
  end

  -- Step 1: Compute LCS table
  local L = {}
  for i = 0, m do
    L[i] = {}
    for j = 0, n do
      L[i][j] = 0
    end
  end
  for i = 1, m do
    local oi = old_lines[i]
    for j = 1, n do
      if oi == new_lines[j] then
        L[i][j] = L[i-1][j-1] + 1
      else
        L[i][j] = math.max(L[i-1][j], L[i][j-1])
      end
    end
  end

  -- Step 2: Backtrack to get edit script
  local edits = {}  -- {type="keep"|"del"|"add", old_idx, new_idx, line}
  local i, j = m, n
  while i > 0 or j > 0 do
    if i > 0 and j > 0 and old_lines[i] == new_lines[j] then
      edits[#edits + 1] = { type = "keep", old_idx = i, new_idx = j, line = old_lines[i] }
      i = i - 1
      j = j - 1
    elseif j > 0 and (i == 0 or L[i][j-1] >= (L[i-1] and L[i-1][j] or 0)) then
      edits[#edits + 1] = { type = "add", old_idx = i, new_idx = j, line = new_lines[j] }
      j = j - 1
    else
      edits[#edits + 1] = { type = "del", old_idx = i, new_idx = j, line = old_lines[i] }
      i = i - 1
    end
  end

  -- edits are in reverse order -- reverse them
  local reversed = {}
  for k = #edits, 1, -1 do
    reversed[#reversed + 1] = edits[k]
  end
  edits = reversed

  -- Step 3: Find change regions (contiguous non-keep edits)
  local change_regions = {}
  local region_start = nil
  for idx, e in ipairs(edits) do
    if e.type ~= "keep" then
      if not region_start then
        region_start = idx
      end
    else
      if region_start then
        change_regions[#change_regions + 1] = { start = region_start, end_ = idx - 1 }
        region_start = nil
      end
    end
  end
  if region_start then
    change_regions[#change_regions + 1] = { start = region_start, end_ = #edits }
  end

  if #change_regions == 0 then
    return { hunks = {}, added = 0, removed = 0, unchanged = true }
  end

  -- Step 4: Merge adjacent regions with small gaps (<= 2*context_lines)
  local merged = {}
  for _, cr in ipairs(change_regions) do
    if #merged > 0 then
      local prev = merged[#merged]
      local keep_count = 0
      for k = prev.end_ + 1, cr.start - 1 do
        if k >= 1 and k <= #edits and edits[k].type == "keep" then
          keep_count = keep_count + 1
        end
      end
      if keep_count <= context_lines * 2 then
        prev.end_ = cr.end_
      else
        merged[#merged + 1] = cr
      end
    else
      merged[#merged + 1] = cr
    end
  end

  -- Step 5: Build output hunks with context
  local hunks = {}
  local total_added = 0
  local total_removed = 0

  for _, cr in ipairs(merged) do
    local hunk_start_idx = math.max(1, cr.start - context_lines)
    local hunk_end_idx = math.min(#edits, cr.end_ + context_lines)

    local old_start = nil
    local old_count = 0
    local new_start = nil
    local new_count = 0
    local lines = {}

    for idx = hunk_start_idx, hunk_end_idx do
      local e = edits[idx]
      if e.type == "keep" then
        if not old_start then old_start = e.old_idx end
        if not new_start then new_start = e.new_idx end
        old_count = old_count + 1
        new_count = new_count + 1
        lines[#lines + 1] = " " .. e.line
      elseif e.type == "del" then
        if not old_start then old_start = e.old_idx end
        old_count = old_count + 1
        total_removed = total_removed + 1
        lines[#lines + 1] = "-" .. e.line
      elseif e.type == "add" then
        if not new_start then new_start = e.new_idx end
        new_count = new_count + 1
        total_added = total_added + 1
        lines[#lines + 1] = "+" .. e.line
      end
    end

    -- Provide default start values for add-only or del-only hunks
    if not old_start then
      old_start = hunk_start_idx > 0 and edits[hunk_start_idx].old_idx or 1
    end
    if not new_start then
      new_start = hunk_start_idx > 0 and edits[hunk_start_idx].new_idx or 1
    end

    hunks[#hunks + 1] = {
      header = string.format("@@ -%d,%d +%d,%d @@", old_start, old_count, new_start, new_count),
      lines = lines,
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
    }
  end

  return {
    hunks = hunks,
    added = total_added,
    removed = total_removed,
  }
end

return M
