--- xaster/chat.lua
--- ============================================================================
--- Streaming Chat UI with markdown rendering and interactive elements.
--- ============================================================================
--- Features:
---   - Real-time streaming text display (nvim_buf_set_text for in-place updates)
---   - Treesitter markdown highlighting with code block syntax injection
---   - Interactive elements: copy code, show diff, retry on error
---   - Tool status grouping with expandable details
---   - Message folding for history
---   - Diff viewer integration for edits
---   - Scrollback with auto-scroll-to-bottom toggle
--- ============================================================================

local M = {}

-- ============================================================================
-- State
-- ============================================================================

local chat_buf = nil
local input_buf = nil
local chat_win = nil
local input_win = nil
local cmd_buf = nil          -- command buffer: tool execution status (read-only)
local cmd_win = nil          -- command window: between chat and input
local is_open = false

local config = {
  height_ratio = 0.50,
  min_chat_height = 8,
  cmd_height = 8,            -- height of the command box
  input_height = 1,
  max_messages = 500,        -- soft cap before folding old messages
  fold_old_count = 100,      -- how many to fold when cap is exceeded
}

local stream_active = false
local submit_callback = nil

-- Highlight namespace
local hl_ns = nil

-- Message tracking: extmarks for each message in the chat buffer
-- { start_row, end_row, role, id }
local messages = {}
local message_id_counter = 0

-- Current streaming message state
local stream_state = {
  active = false,
  start_row = nil,         -- shared: first row of the entire stream block
  current_row = nil,       -- shared: last row of the entire stream block
  -- Text region (agent response)
  text_start_row = nil,
  text_current_row = nil,
  text_accumulated = "",
  -- Thinking region (reasoning/tool thought)
  think_start_row = nil,
  think_current_row = nil,
  thinking_accumulated = "",
  thinking_written = false,
}

-- Tool status tracking
local tool_status = {
  active = false,
  start_row = nil,
  end_row = nil,
  calls = {},           -- { name, params, ok, error }
}

-- ============================================================================
-- Highlight Groups
-- ============================================================================

local function define_highlights()
  if hl_ns then return end
  hl_ns = vim.api.nvim_create_namespace("xaster_chat")

  local hl_groups = {
    XasterAgent       = { fg = "#87ceeb", default = true },
    XasterThink       = { fg = "#808080", default = true },
    XasterUser        = { fg = "#98fb98", default = true },
    XasterTool        = { fg = "#d4a040", default = true },
    XasterError       = { fg = "#d75f5f", default = true },
    XasterToolSuccess = { fg = "#a6e3a1", default = true },
    XasterToolPending = { fg = "#f9e2af", default = true },
    XasterDiffAdd     = { bg = "#1a3a1a", fg = "#a6e3a1", default = true },
    XasterDiffDel     = { bg = "#3a1a1a", fg = "#f38ba8", default = true },
    XasterDiffHunk    = { fg = "#89b4fa", bold = true, default = true },
    XasterCodeBlock   = { bg = "#1e1e2e", default = true },
    XasterInlineButton = { fg = "#89b4fa", underline = true, default = true },
  }

  for name, opts in pairs(hl_groups) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

-- ============================================================================
-- Configuration
-- ============================================================================

function M.configure(opts)
  if not opts then return end
  if opts.height_ratio then config.height_ratio = opts.height_ratio end
  if opts.min_chat_height then config.min_chat_height = opts.min_chat_height end
  if opts.cmd_height then config.cmd_height = opts.cmd_height end
  if opts.max_messages then config.max_messages = opts.max_messages end
end

function M.set_submit_callback(cb)
  submit_callback = cb
end

-- ============================================================================
-- Buffer Utilities
-- ============================================================================

local function buf_valid(b) return b and vim.api.nvim_buf_is_valid(b) end
local function win_valid(w) return w and vim.api.nvim_win_is_valid(w) end

local function make_writable()
  if buf_valid(chat_buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = chat_buf })
  end
end

local function make_readonly()
  if buf_valid(chat_buf) then
    vim.api.nvim_set_option_value("modifiable", false, { buf = chat_buf })
  end
end

local function chat_line_count()
  if not buf_valid(chat_buf) then return 0 end
  return vim.api.nvim_buf_line_count(chat_buf)
end

--- Scroll chat window to bottom if user hasn't scrolled up.
--- During active Agent streaming, always auto-scroll so the user sees output in real time.
--- When not streaming, only scroll if cursor is near the bottom (respects manual scroll-up).
local function scroll_to_bottom_if_following()
  if not win_valid(chat_win) then return end
  local lc = chat_line_count()
  if lc == 0 then return end
  -- During streaming: always follow the output
  if stream_active then
    pcall(vim.api.nvim_win_set_cursor, chat_win, { lc, 0 })
    return
  end
  -- Idle: only scroll if user is already near the bottom
  local cursor = vim.api.nvim_win_get_cursor(chat_win)
  if cursor[1] >= lc - 3 then
    pcall(vim.api.nvim_win_set_cursor, chat_win, { lc, 0 })
  end
end

-- ============================================================================
-- Command Buffer Utilities
-- ============================================================================

local function cmd_buf_valid()
  return cmd_buf and vim.api.nvim_buf_is_valid(cmd_buf)
end

local function cmd_win_valid()
  return cmd_win and vim.api.nvim_win_is_valid(cmd_win)
end

local function cmd_make_writable()
  if cmd_buf_valid() then
    vim.api.nvim_set_option_value("modifiable", true, { buf = cmd_buf })
  end
end

local function cmd_make_readonly()
  if cmd_buf_valid() then
    vim.api.nvim_set_option_value("modifiable", false, { buf = cmd_buf })
  end
end

local function cmd_line_count()
  if not cmd_buf_valid() then return 0 end
  return vim.api.nvim_buf_line_count(cmd_buf)
end

--- Scroll command window to bottom if user hasn't scrolled up.
local function cmd_scroll_to_bottom_if_following()
  if not cmd_win_valid() then return end
  local lc = cmd_line_count()
  if lc == 0 then return end
  local cursor = vim.api.nvim_win_get_cursor(cmd_win)
  if cursor[1] >= lc - 3 then
    pcall(vim.api.nvim_win_set_cursor, cmd_win, { lc, 0 })
  end
end

--- Append lines to end of command buffer with optional highlight.
---@param lines string[]
---@param hl_group string|nil
---@return integer start_row  First line inserted
---@return integer end_row    Last line + 1 (exclusive)
local function cmd_append_lines(lines, hl_group)
  if not cmd_buf_valid() then return 0, 0 end

  cmd_make_writable()
  local sr = cmd_line_count()
  vim.api.nvim_buf_set_lines(cmd_buf, sr, sr, false, lines)
  local er = cmd_line_count()
  cmd_make_readonly()

  if hl_group and er > sr then
    pcall(vim.api.nvim_buf_set_extmark, cmd_buf, hl_ns, sr, 0, {
      end_row = er,
      hl_group = hl_group,
      priority = 10,
    })
  end

  cmd_scroll_to_bottom_if_following()
  return sr, er
end

--- Append text to end of command buffer (single line).
---@param text string
---@param hl_group string|nil
---@return integer start_row
---@return integer end_row
local function cmd_append_text(text, hl_group)
  return cmd_append_lines({ text }, hl_group)
end

-- ============================================================================
-- Public Command Buffer API (called by tools.lua / agent.lua)
-- ============================================================================

--- Append execution output to the command buffer.
--- Use this from tool handlers to show Vim command messages, shell output, etc.
---@param text string  Single line or multi-line text (split on \n)
---@param hl_group string|nil  Highlight group (default nil = plain)
function M.append_cmd(text, hl_group)
  if not text or text == "" then return end
  if not cmd_buf_valid() then return end
  local lines = vim.split(text, "\n", { plain = true })
  cmd_append_lines(lines, hl_group)
end

--- Clear the command buffer content.
function M.clear_cmd()
  if not cmd_buf_valid() then return end
  cmd_make_writable()
  vim.api.nvim_buf_set_lines(cmd_buf, 0, -1, false, {})
  cmd_make_readonly()
end

--- Append lines to end of chat buffer with optional highlight.
---@param lines string[]
---@param hl_group string|nil
---@return integer start_row  First line inserted
---@return integer end_row    Last line + 1 (exclusive)
local function append_lines(lines, hl_group)
  if not buf_valid(chat_buf) then
    -- Fallback: notify
    local text = table.concat(lines, " "):gsub("%s+", " "):sub(1, 200)
    if text ~= "" then
      vim.schedule(function() vim.notify("[xaster] " .. text) end)
    end
    return 0, 0
  end

  make_writable()
  local sr = chat_line_count()
  vim.api.nvim_buf_set_lines(chat_buf, sr, sr, false, lines)
  local er = chat_line_count()
  make_readonly()

  if hl_group and er > sr then
    pcall(vim.api.nvim_buf_set_extmark, chat_buf, hl_ns, sr, 0, {
      end_row = er,
      hl_group = hl_group,
      priority = 10,
    })
  end

  scroll_to_bottom_if_following()
  return sr, er
end

--- Append text to end of chat buffer (single line).
---@param text string
---@param hl_group string|nil
---@return integer start_row
---@return integer end_row
local function append_text(text, hl_group)
  return append_lines({ text }, hl_group)
end

-- ============================================================================
-- Open / Close
-- ============================================================================

function M.open()
  if is_open then M.focus_input(); return end

  define_highlights()

  local pw = math.max(30, math.floor(vim.o.columns * config.height_ratio))
  local tl = vim.o.lines - vim.o.cmdheight - 1
  -- Clamp cmd_height so chat always has at least min_chat_height rows
  local cmd_h = math.min(config.cmd_height, math.max(3, tl - config.input_height - config.min_chat_height))

  -- === Chat buffer ===
  chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = chat_buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = chat_buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = chat_buf })

  -- Enable treesitter markdown if available
  local ok_ts, ts = pcall(require, "vim.treesitter")
  if ok_ts then
    pcall(function()
      ts.start(chat_buf, "markdown")
    end)
  end

  -- Header
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
    "# xaster",
    "",
    "*Agent ready. Type a message and press Enter.*",
    "",
  })

  -- Lock chat buffer for append-only access
  make_readonly()

  -- === Command buffer (NEW) ===
  cmd_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = cmd_buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = cmd_buf })
  -- modifiable stays false at rest; toggled only during writes
  cmd_make_readonly()

  -- === Input buffer ===
  input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = input_buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = input_buf })
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  -- === Window layout ===

  -- 1. Chat window (right sidebar)
  vim.api.nvim_command("botright " .. pw .. "vsplit")
  chat_win = vim.api.nvim_get_current_win()
  vim.wo[chat_win].winfixwidth = true
  vim.wo[chat_win].number = false
  vim.wo[chat_win].relativenumber = false
  vim.wo[chat_win].signcolumn = "no"
  vim.wo[chat_win].cursorline = false
  vim.wo[chat_win].wrap = true
  vim.wo[chat_win].linebreak = true
  vim.wo[chat_win].conceallevel = 2
  vim.api.nvim_win_set_buf(chat_win, chat_buf)

  -- 2. Input window (bottom of sidebar)
  vim.api.nvim_command("botright 1split")
  input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input_win, input_buf)
  vim.wo[input_win].winfixheight = true
  vim.wo[input_win].number = false
  vim.wo[input_win].relativenumber = false
  vim.wo[input_win].signcolumn = "no"
  vim.wo[input_win].cursorline = false

  -- 3. Command window (between chat and input)
  --    Go back to chat_win, then split below it. "belowright" places the new
  --    window immediately under chat_win, which inserts it above input_win.
  vim.api.nvim_set_current_win(chat_win)
  -- Temporarily disable winfixheight on chat_win so the split respects cmd_h
  vim.wo[chat_win].winfixheight = false
  vim.api.nvim_command("belowright " .. cmd_h .. "split")
  cmd_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(cmd_win, cmd_buf)
  vim.wo[cmd_win].winfixheight = true
  vim.wo[cmd_win].number = false
  vim.wo[cmd_win].relativenumber = false
  vim.wo[cmd_win].signcolumn = "no"
  vim.wo[cmd_win].cursorline = false
  vim.wo[cmd_win].wrap = true
  vim.wo[cmd_win].linebreak = true

  -- === Keymaps ===

  -- Input buffer keymaps
  local iopts = { buffer = input_buf, nowait = true }
  vim.keymap.set("i", "<CR>", function() M.submit() end, iopts)
  vim.keymap.set("n", "<CR>", function()
    vim.cmd("startinsert")
    vim.schedule(M.submit)
  end, iopts)
  vim.keymap.set("i", "<Esc>", function() vim.cmd("stopinsert") end, iopts)
  vim.keymap.set("i", "<C-k>", function()
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(chat_win)
  end, iopts)

  -- Chat buffer: 'i' -> focus input, '<C-c>' -> stop agent
  vim.keymap.set("n", "i", function()
    vim.api.nvim_set_current_win(input_win)
    vim.cmd("startinsert")
  end, { buffer = chat_buf })
  vim.keymap.set("n", "<C-c>", function()
    vim.notify("[xaster] Agent interrupted by user", vim.log.levels.WARN)
    local ok, agent = pcall(require, "xaster.agent")
    if ok then agent.stop() end
  end, { buffer = chat_buf, desc = "Stop Agent" })

  -- Command buffer: 'i' -> focus input, '<C-k>' -> focus chat, '<C-c>' -> stop agent
  vim.keymap.set("n", "i", function()
    vim.api.nvim_set_current_win(input_win)
    vim.cmd("startinsert")
  end, { buffer = cmd_buf })
  vim.keymap.set("n", "<C-k>", function()
    vim.api.nvim_set_current_win(chat_win)
  end, { buffer = cmd_buf })
  vim.keymap.set("n", "<C-c>", function()
    vim.notify("[xaster] Agent interrupted by user", vim.log.levels.WARN)
    local ok, agent = pcall(require, "xaster.agent")
    if ok then agent.stop() end
  end, { buffer = cmd_buf, desc = "Stop Agent" })

  is_open = true
  messages = {}
  M.focus_input()
end

function M.close()
  if not is_open then return end
  stream_active = false
  stream_state.active = false

  for _, w in ipairs({ input_win, cmd_win, chat_win }) do
    if win_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  for _, b in ipairs({ input_buf, cmd_buf, chat_buf }) do
    if buf_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end

  chat_buf, input_buf, cmd_buf = nil, nil, nil
  chat_win, input_win, cmd_win = nil, nil, nil
  messages = {}
  is_open = false
end

function M.toggle()
  if is_open then M.close() else M.open() end
end

function M.is_open() return is_open end

function M.focus_input()
  if win_valid(input_win) then
    vim.api.nvim_set_current_win(input_win)
    vim.cmd("startinsert!")
  end
end

-- ============================================================================
-- Submit
-- ============================================================================

function M.submit()
  if not buf_valid(input_buf) then return end
  local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if text:match("^%s*$") then return end

  -- Clear input
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  M.add_message("user", text)

  if submit_callback then
    vim.schedule(function() submit_callback(text) end)
  end
end

-- ============================================================================
-- Message Display
-- ============================================================================

--- Add a user/error message to the chat.
---@param role string  "user" | "error"
---@param content string
function M.add_message(role, content)
  if role == "user" then
    append_text("", nil)  -- blank line
    local sr, er = append_text("> " .. content:gsub("\n", "\n> "):sub(1, 5000), "XasterUser")
    append_text("", nil)  -- blank line

    message_id_counter = message_id_counter + 1
    messages[#messages + 1] = {
      id = message_id_counter,
      role = "user",
      start_row = sr,
      end_row = er,
    }
  elseif role == "error" then
    append_text("[X] " .. content:gsub("\n", " "):sub(1, 500), "XasterError")
  end

  -- Check message cap
  if #messages > config.max_messages then
    M._fold_old_messages()
  end
end

-- ============================================================================
-- Streaming Display
-- ============================================================================

--- Start a new streaming message.
--- Called before first text/thinking chunk or by show_thinking.
function M.start_stream()
  if not buf_valid(chat_buf) then return end
  M.clear_tool_status()

  stream_state = {
    active = true,
    start_row = nil,
    current_row = nil,
    text_start_row = nil,
    text_current_row = nil,
    text_accumulated = "",
    think_start_row = nil,
    think_current_row = nil,
    thinking_accumulated = "",
    thinking_written = false,
  }
  stream_active = true
end

--- Append streaming text. Uses its own region (text_start_row/text_current_row)
--- so interleaved thinking chunks don't overwrite the text content.
---@param text string  Text chunk to append
function M.append_stream_text(text)
  if not buf_valid(chat_buf) then return end
  if not text or #text == 0 then return end

  if not stream_state.active then M.start_stream() end
  if not stream_state.active then return end

  stream_state.text_accumulated = stream_state.text_accumulated .. text
  local all_lines = vim.split(stream_state.text_accumulated, "\n", { plain = true })

  make_writable()

  -- Determine where to write text: after thinking if thinking was written first,
  -- otherwise at the bottom of the buffer.
  local start
  local end_
  if stream_state.text_start_row then
    -- We've written text before: replace the previous text region
    start = stream_state.text_start_row
    end_ = stream_state.text_current_row
  elseif stream_state.think_current_row then
    -- Thinking was already written: append text AFTER thinking + blank line
    start = stream_state.think_current_row + 1
    end_ = start
  else
    -- Neither written yet: start at buffer bottom
    start = chat_line_count()
    end_ = start
  end

  if end_ > start then
    vim.api.nvim_buf_set_lines(chat_buf, start, end_, false, all_lines)
  else
    vim.api.nvim_buf_set_lines(chat_buf, start, start, false, all_lines)
  end

  stream_state.text_start_row = start
  stream_state.text_current_row = start + #all_lines
  -- Update shared state to span the entire stream block
  stream_state.start_row = stream_state.start_row or start
  stream_state.current_row = stream_state.text_current_row
  make_readonly()

  -- Highlight agent text
  if stream_state.text_current_row > stream_state.text_start_row then
    pcall(vim.api.nvim_buf_set_extmark, chat_buf, hl_ns, stream_state.text_start_row, 0, {
      end_row = stream_state.text_current_row,
      hl_group = "XasterAgent",
      priority = 10,
    })
  end
  scroll_to_bottom_if_following()
end

--- Append thinking text (dimmed). Uses its own region (think_start_row/think_current_row)
--- so interleaved text chunks don't overwrite the thinking content.
---@param text string
function M.append_think_text(text)
  if not buf_valid(chat_buf) then return end
  if not text or #text == 0 then return end

  if not stream_state.active then M.start_stream() end
  if not stream_state.active then return end

  stream_state.thinking_accumulated = stream_state.thinking_accumulated .. text
  local think_lines = vim.split(stream_state.thinking_accumulated, "\n", { plain = true })

  make_writable()

  -- Determine where to write thinking: before text if text was written first,
  -- otherwise at the bottom of the buffer.
  local start
  local end_
  if stream_state.think_start_row then
    -- We've written thinking before: replace the previous thinking region
    start = stream_state.think_start_row
    end_ = stream_state.think_current_row
  else
    -- Thinking always goes before text. Append at buffer bottom if text
    -- hasn't been written yet, otherwise we need to insert BEFORE text.
    if stream_state.text_start_row then
      -- Text was already written: insert thinking BEFORE text
      start = stream_state.text_start_row
      end_ = start
    else
      -- Nothing written yet: start at buffer bottom
      start = chat_line_count()
      end_ = start
    end
  end

  if end_ > start then
    vim.api.nvim_buf_set_lines(chat_buf, start, end_, false, think_lines)
  else
    vim.api.nvim_buf_set_lines(chat_buf, start, start, false, think_lines)
  end

  local new_end = start + #think_lines
  stream_state.think_start_row = start
  stream_state.think_current_row = new_end
  stream_state.thinking_written = true

  -- If we inserted thinking before text, shift the text region down
  if stream_state.text_start_row and stream_state.text_start_row == start then
    local shift = new_end - end_
    stream_state.text_start_row = stream_state.text_start_row + shift
    stream_state.text_current_row = stream_state.text_current_row + shift
  end

  -- Update shared state
  stream_state.start_row = stream_state.start_row or start
  stream_state.current_row = math.max(
    stream_state.current_row or new_end,
    stream_state.text_current_row or 0,
    new_end
  )
  make_readonly()

  -- Dimmed highlight (highlight only the thinking region, not the shared current_row)
  pcall(vim.api.nvim_buf_set_extmark, chat_buf, hl_ns, stream_state.think_start_row, 0, {
    end_row = stream_state.think_current_row,
    hl_group = "XasterThink",
    priority = 9,
  })
  scroll_to_bottom_if_following()
end

--- End the current streaming message.
function M.end_stream()
  stream_state.active = false
  stream_state = {
    active = false,
    start_row = nil, current_row = nil,
    text_start_row = nil, text_current_row = nil,
    text_accumulated = "",
    think_start_row = nil, think_current_row = nil,
    thinking_accumulated = "", thinking_written = false,
  }
  if buf_valid(chat_buf) then append_text("", nil) end
  -- Record message
  message_id_counter = message_id_counter + 1
  messages[#messages + 1] = {
    id = message_id_counter, role = "assistant",
    start_row = chat_line_count(), end_row = chat_line_count(),
  }
  stream_active = false
end

-- ============================================================================
-- Thinking Indicator
-- ============================================================================

function M.show_thinking()
  if not buf_valid(chat_buf) then return end
  -- Enter streaming mode so hide_thinking has correct state to clean up
  M.start_stream()
  -- Write the placeholder inside the stream region
  make_writable()
  local sr = chat_line_count()
  vim.api.nvim_buf_set_lines(chat_buf, sr, sr, false, { "  *thinking...*" })
  make_readonly()
  pcall(vim.api.nvim_buf_set_extmark, chat_buf, hl_ns, sr, 0, {
    end_row = sr + 1, hl_group = "XasterThink", priority = 9,
  })
  stream_state.start_row = sr
  stream_state.current_row = sr + 1
  scroll_to_bottom_if_following()
end

function M.hide_thinking()
  if not buf_valid(chat_buf) then return end
  local tsr = stream_state.think_start_row
  local ter = stream_state.think_current_row
  if not tsr or not ter or ter <= tsr then return end

  make_writable()
  local lines = vim.api.nvim_buf_get_lines(chat_buf, tsr, ter, false)
  local cleaned = {}
  for _, line in ipairs(lines) do
    -- Skip placeholder lines and empty-metadata thinking markers
    if not line:match("thinking%.%.%.") and not line:match("^%s*$") then
      cleaned[#cleaned + 1] = line
    end
  end
  if #cleaned ~= #lines then
    if #cleaned == 0 then
      -- All thinking lines removed — delete the entire region
      vim.api.nvim_buf_set_lines(chat_buf, tsr, ter, false, {})
      local removed = ter - tsr
      -- Shift text region up if it's below the removed thinking region
      if stream_state.text_start_row and stream_state.text_start_row >= ter then
        stream_state.text_start_row = stream_state.text_start_row - removed
        stream_state.text_current_row = stream_state.text_current_row - removed
      end
      stream_state.think_current_row = tsr
      stream_state.current_row = stream_state.current_row - removed
    else
      vim.api.nvim_buf_set_lines(chat_buf, tsr, ter, false, cleaned)
      stream_state.think_current_row = tsr + #cleaned
      stream_state.current_row = stream_state.think_current_row
    end
  end
  make_readonly()
end

-- ============================================================================
-- Tool Status Display
-- ============================================================================

--- Show compact tool execution status with per-tool lines.
--- Written to the command buffer (cmd_buf), not the chat buffer.
---@param calls table[]  Array of {name, params} tool calls
function M.show_tool_status(calls)
  if not cmd_buf_valid() then return end
  M.clear_tool_status()

  tool_status.calls = {}
  local lines = {}

  for _, tc in ipairs(calls) do
    -- Support both OpenAI format {type, id, function: {name, arguments}}
    -- and legacy flat format {name, params}
    local fn_block = tc["function"] or {}
    local tc_name = fn_block.name or tc.name or "?"
    local tc_args = fn_block.arguments or tc.params
    -- Parse arguments if they come as a JSON string
    if type(tc_args) == "string" and #tc_args > 0 then
      local ok, parsed = pcall(vim.json.decode, tc_args)
      if ok and type(parsed) == "table" then tc_args = parsed end
    end
    if type(tc_args) ~= "table" then tc_args = {} end

    local label = tc_name
    -- Extract informative param
    if tc_args.filepath then
      label = label .. " " .. (tc_args.filepath:match("[^/]+$") or tc_args.filepath):sub(1, 30)
    elseif tc_args.cmd then
      label = label .. " " .. tc_args.cmd:sub(1, 40)
    elseif tc_args.pattern then
      label = label .. " /" .. tc_args.pattern:sub(1, 25)
    elseif tc_args.op and tc_args.target then
      label = label .. " " .. tc_args.op .. tc_args.target
    elseif tc_args.key then
      label = label .. " " .. tc_args.key:sub(1, 25)
    end
    lines[#lines + 1] = "  PENDING " .. label
    tool_status.calls[#tool_status.calls + 1] = { name = tc_name, label = label, ok = nil }
  end

  local sr, er = cmd_append_lines(lines, "XasterToolPending")
  tool_status.start_row = sr
  tool_status.end_row = er
  tool_status.active = true
end

--- Clear tool status, replacing with completion marks.
--- Operates on the command buffer (cmd_buf), not the chat buffer.
function M.clear_tool_status()
  if not cmd_buf_valid() then return end
  if not tool_status.active then return end

  local sr = tool_status.start_row
  local er = tool_status.end_row
  if not sr or not er then
    tool_status.active = false
    return
  end

  cmd_make_writable()
  -- Replace each tool line with success/failure indicator
  local current_lines = vim.api.nvim_buf_get_lines(cmd_buf, sr, er, false)
  local new_lines = {}
  for i, line in ipairs(current_lines) do
    local tc = tool_status.calls[i]
    if tc then
      if tc.ok == false then
        new_lines[#new_lines + 1] = line:gsub("PENDING", "[X]", 1)
      else
        new_lines[#new_lines + 1] = line:gsub("PENDING", "[OK]", 1)
      end
    else
      new_lines[#new_lines + 1] = line
    end
  end
  vim.api.nvim_buf_set_lines(cmd_buf, sr, er, false, new_lines)
  cmd_make_readonly()

  -- Re-highlight
  for i, tc in ipairs(tool_status.calls) do
    local row = sr + i - 1
    local hl = tc.ok == false and "XasterError" or "XasterToolSuccess"
    pcall(vim.api.nvim_buf_set_extmark, cmd_buf, hl_ns, row, 0, {
      end_row = row + 1,
      hl_group = hl,
      priority = 10,
    })
  end

  tool_status.active = false
  cmd_scroll_to_bottom_if_following()
end

--- Mark a specific tool as failed.
---@param index integer  1-indexed tool in the batch
---@param error_msg string
function M.mark_tool_error(index, error_msg)
  if not tool_status.active then return end
  if tool_status.calls[index] then
    tool_status.calls[index].ok = false
    tool_status.calls[index].error = error_msg
  end
end

--- Mark a specific tool as successful.
---@param index integer
function M.mark_tool_ok(index)
  if not tool_status.active then return end
  if tool_status.calls[index] then
    tool_status.calls[index].ok = true
  end
end

-- ============================================================================
-- Error Display
-- ============================================================================

--- Show an error message in chat.
---@param msg string
function M.show_error(msg)
  append_text("[X] Error: " .. msg:gsub("\n", " "):sub(1, 500), "XasterError")
  M.end_stream()
end

--- Show a tool error with retry suggestion.
---@param msg string
function M.show_tool_error(msg)
  M.clear_tool_status()
  local sr, er = append_text("[X] " .. msg:gsub("\n", " "):sub(1, 200), "XasterError")

  -- Add retry hint as virtual text
  if sr and buf_valid(chat_buf) then
    pcall(vim.api.nvim_buf_set_extmark, chat_buf, hl_ns, sr, 0, {
      virt_text = { { " [retry?]", "XasterInlineButton" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end

  scroll_to_bottom_if_following()
end

-- ============================================================================
-- Diff Viewer
-- ============================================================================

--- Show a diff between old and new content in a floating window.
---@param filepath string
---@param old_content string[]  Lines before edit
---@param new_content string[]  Lines after edit
---@param opts table|nil  { title: string }
function M.show_diff(filepath, old_content, new_content, opts)
  opts = opts or {}
  local title = opts.title or ("Diff: " .. (filepath:match("[^/]+$") or filepath))

  -- Build unified diff
  local diff_lines = { "# " .. title, "" }

  -- Simple line-by-line diff
  local max_lines = math.max(#old_content, #new_content)
  local old_i, new_i = 1, 1
  local context_lines = 3

  -- Collect changed ranges
  local changes = {}
  while old_i <= #old_content or new_i <= #new_content do
    local old_line = old_content[old_i]
    local new_line = new_content[new_i]
    if old_line == new_line then
      old_i = old_i + 1
      new_i = new_i + 1
    else
      -- Find the extent of the change
      local change_start = math.max(1, old_i - context_lines)
      local old_end = math.min(#old_content, old_i + 5)
      local new_end = math.min(#new_content, new_i + 5)

      -- Try to align
      local found = false
      for scan_o = old_i, math.min(#old_content, old_i + 5) do
        for scan_n = new_i, math.min(#new_content, new_i + 5) do
          if old_content[scan_o] == new_content[scan_n] then
            old_end = scan_o
            new_end = scan_n
            found = true
            break
          end
        end
        if found then break end
      end

      changes[#changes + 1] = {
        old_start = old_i,
        old_end = found and old_end or math.min(#old_content, old_i + 5),
        new_start = new_i,
        new_end = found and new_end or math.min(#new_content, new_i + 5),
      }

      old_i = found and old_end or (old_i + 6)
      new_i = found and new_end or (new_i + 6)
    end
  end

  -- Render changes
  for _, ch in ipairs(changes) do
    diff_lines[#diff_lines + 1] = string.format("```diff")
    diff_lines[#diff_lines + 1] = string.format("@@ -%d,%d +%d,%d @@",
      ch.old_start, ch.old_end - ch.old_start,
      ch.new_start, ch.new_end - ch.new_start)

    for i = ch.old_start, ch.old_end - 1 do
      if old_content[i] then
        diff_lines[#diff_lines + 1] = "- " .. old_content[i]
      end
    end
    for i = ch.new_start, ch.new_end - 1 do
      if new_content[i] then
        diff_lines[#diff_lines + 1] = "+ " .. new_content[i]
      end
    end
    diff_lines[#diff_lines + 1] = "```"
    diff_lines[#diff_lines + 1] = ""
  end

  -- Show in floating window
  local width = math.floor(vim.o.columns * 0.65)
  local height = math.floor(vim.o.lines * 0.6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

  -- Enable treesitter for syntax highlighting
  local ok_ts, ts = pcall(require, "vim.treesitter")
  if ok_ts then
    pcall(function() ts.start(buf, "markdown") end)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    zindex = 150,
  })

  vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })  -- no wrap for diff

  -- Close on q/Esc
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })

  return win, buf
end

--- Show edit confirmation dialog with unified diffs for one or more files.
--- Creates a floating window with highlighted + (add, green) / - (del, red) lines.
--- Waits for user input: y = accept all edits, n/q/Esc = reject (undo).
---@param diffs table[]  Array of {filepath, hunks, added, removed, unchanged, file_too_large}
---   where hunks is from editor.compute_unified_diff
---@param callback fun(accepted: boolean)  Called with user decision
function M.confirm_edits(diffs, callback)
  if not diffs or #diffs == 0 then
    if callback then callback(true) end
    return
  end

  define_highlights()

  -- Build display lines
  local total_added = 0
  local total_removed = 0
  local files_changed = 0

  local display_lines = {}
  display_lines[#display_lines + 1] = "# Edit Confirmation"
  display_lines[#display_lines + 1] = ""

  for _, d in ipairs(diffs) do
    local shortname = d.filepath and d.filepath:match("[^/]+$") or "(unknown)"
    total_added = total_added + (d.added or 0)
    total_removed = total_removed + (d.removed or 0)
    files_changed = files_changed + 1

    if d.unchanged then
      display_lines[#display_lines + 1] = "## " .. shortname .. " *(no changes)*"
    elseif d.file_too_large then
      display_lines[#display_lines + 1] = string.format("## %s  +%d -%d *(file too large, summary only)*",
        shortname, d.added or 0, d.removed or 0)
    else
      display_lines[#display_lines + 1] = string.format("## %s  +%d -%d", shortname, d.added or 0, d.removed or 0)
    end
    display_lines[#display_lines + 1] = ""

    if d.hunks and #d.hunks > 0 then
      for _, hunk in ipairs(d.hunks) do
        -- Hunk header
        display_lines[#display_lines + 1] = hunk.header
        -- Diff lines with +/-/space prefix
        for _, line in ipairs(hunk.lines) do
          display_lines[#display_lines + 1] = line
        end
        display_lines[#display_lines + 1] = ""
      end
    end
  end

  -- Summary line
  local summary = string.format("%d file(s) changed, +%d -%d lines", files_changed, total_added, total_removed)
  display_lines[#display_lines + 1] = "---"
  display_lines[#display_lines + 1] = summary
  display_lines[#display_lines + 1] = ""
  display_lines[#display_lines + 1] = "[y] Accept    [n] Reject    [C-c] Abort & Stop Agent"

  -- Create floating window
  local width = math.floor(vim.o.columns * 0.70)
  local height = math.floor(vim.o.lines * 0.65)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
  vim.api.nvim_set_option_value("filetype", "diff", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Apply extmark highlights: green for + lines, red for - lines, blue for @@ headers
  local ns = vim.api.nvim_create_namespace("xaster_diff_confirm")
  for i, line in ipairs(display_lines) do
    local first_char = line:sub(1, 1)
    local row_idx = i - 1  -- 0-indexed
    if first_char == "+" then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row_idx, 0, {
        end_row = row_idx + 1,
        hl_group = "XasterDiffAdd",
        priority = 10,
      })
    elseif first_char == "-" then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row_idx, 0, {
        end_row = row_idx + 1,
        hl_group = "XasterDiffDel",
        priority = 10,
      })
    elseif line:match("^@@") then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row_idx, 0, {
        end_row = row_idx + 1,
        hl_group = "XasterDiffHunk",
        priority = 10,
      })
    end
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Confirm Edits ",
    title_pos = "center",
    zindex = 200,
  })

  vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })

  -- Track whether callback has been invoked (prevent double-fire)
  local decided = false

  ---@param result string  "accept" | "reject" | "abort"
  local function close_and_resolve(result)
    if decided then return end
    decided = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if callback then
      vim.schedule(function() callback(result) end)
    end
  end

  -- Keymaps: y = accept, n/q/Esc = reject, C-c = abort (stop agent entirely)
  vim.keymap.set("n", "y", function() close_and_resolve("accept") end,
    { buffer = buf, nowait = true, desc = "Accept edits" })
  vim.keymap.set("n", "n", function() close_and_resolve("reject") end,
    { buffer = buf, nowait = true, desc = "Reject edits" })
  vim.keymap.set("n", "q", function() close_and_resolve("reject") end,
    { buffer = buf, nowait = true, desc = "Reject edits" })
  vim.keymap.set("n", "<Esc>", function() close_and_resolve("reject") end,
    { buffer = buf, nowait = true, desc = "Reject edits" })
  vim.keymap.set("n", "<C-c>", function() close_and_resolve("abort") end,
    { buffer = buf, nowait = true, desc = "Abort agent and stop" })

  -- Scroll to top
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

-- ============================================================================
-- Message Folding
-- ============================================================================

--- Fold the oldest messages to keep the buffer manageable.
--- Replaces old messages with a collapsible "[... N earlier messages]" line.
function M._fold_old_messages()
  if #messages <= config.fold_old_count then return end

  local fold_count = #messages - config.fold_old_count + 50  -- keep some margin
  if fold_count <= 0 then return end

  -- Remove the oldest messages from buffer
  -- (This is a simple implementation -- a full collapsible fold needs extmarks)
  make_writable()
  local first_visible = messages[fold_count + 1]
  if first_visible and first_visible.start_row then
    if first_visible.start_row > 1 then
      vim.api.nvim_buf_set_lines(chat_buf, 0, first_visible.start_row - 1, false, {
        "---",
        string.format("*... %d earlier messages folded*", fold_count),
        "---",
        "",
      })
      -- Adjust message row offsets
      local offset = first_visible.start_row - 3
      for i = fold_count + 1, #messages do
        if messages[i].start_row then
          messages[i].start_row = messages[i].start_row - offset
          messages[i].end_row = messages[i].end_row - offset
        end
      end
    end
  end
  make_readonly()

  -- Trim message tracking
  local new_messages = {}
  for i = fold_count + 1, #messages do
    new_messages[#new_messages + 1] = messages[i]
  end
  messages = new_messages
end

-- ============================================================================
-- Focus Editor
-- ============================================================================

function M.focus_editor()
  local best, best_w = nil, 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= chat_win and win ~= cmd_win and win ~= input_win then
      local bt = vim.api.nvim_get_option_value("buftype", {
        buf = vim.api.nvim_win_get_buf(win)
      })
      if bt == "" or bt == "acwrite" then
        local w = vim.api.nvim_win_get_width(win)
        if w > best_w then best, best_w = win, w end
      end
    end
  end
  if best then vim.api.nvim_set_current_win(best) end
end

-- ============================================================================
-- Clear & Cleanup
-- ============================================================================

function M.clear()
  if not buf_valid(chat_buf) then return end
  stream_active = false
  stream_state.active = false
  tool_status.active = false
  tool_status.calls = {}
  messages = {}

  make_writable()
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
    "# xaster",
    "",
    "*Chat cleared.*",
    "",
  })
  make_readonly()

  -- Clear command buffer too
  if cmd_buf_valid() then
    cmd_make_writable()
    vim.api.nvim_buf_set_lines(cmd_buf, 0, -1, false, {})
    cmd_make_readonly()
  end
end

function M.cleanup()
  M.close()
end

return M
