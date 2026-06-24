--- xaster/tools.lua
--- Tool registry: each tool has a name, JSON Schema parameters definition,
--- and a handler function. The server dispatches incoming JSON-RPC method
--- calls against this registry.

local editor = require("xaster.editor")
local errors = require("xaster.errors")
local history_mod = require("xaster.history")
local memory_mod = require("xaster.memory")
local vcursor_mod = require("xaster.vcursor")
local lock_mod = require("xaster.lock")

local M = {}

-- ============================================================================
-- Tool Registry
-- ============================================================================

---@class ToolDefinition
---@field name string
---@field description string
---@field parameters table  JSON Schema for parameters
---@field handler fun(params: table): any

local registry = {}

--- Register a tool.
---@param def ToolDefinition
local function register(def)
  registry[def.name] = def
end

--- Get all tool definitions (for schema introspection).
---@return table<string, ToolDefinition>
function M.list()
  return registry
end

--- Get a single tool definition.
---@param name string
---@return ToolDefinition|nil
function M.get(name)
  return registry[name]
end

--- Dispatch a tool call by name through the history/hooks middleware.
--- Returns result (success) or nil + error_code + error_message (failure).
--- Every call is intercepted by history.lua for recording, hooks, and events.
---@param name string
---@param params table
---@return any result
---@return integer|nil err_code
---@return string|nil err_message
function M.dispatch(name, params)
  local tool = registry[name]
  if not tool then
    return nil, errors.ErrorCode.METHOD_NOT_FOUND, "unknown tool: " .. name
  end

  -- Run through history middleware (pre-hooks -> handler -> post-hooks -> record)
  if history_mod.intercept then
    local intercepted = history_mod.intercept(name, params or {}, tool.handler)
    if not intercepted.ok then
      return nil, errors.ErrorCode.INTERNAL_ERROR, intercepted.error or "tool '" .. name .. "' failed"
    end
    return errors.sanitize(intercepted.data)
  end

  -- Fallback: direct call without middleware.
  -- Capture all return values: handlers use "return nil, err" for soft errors,
  -- which pcall returns as (true, nil, err) -- a two-value capture drops the error.
  local pcall_results = { pcall(tool.handler, params or {}) }
  local ok = pcall_results[1]
  local result = pcall_results[2]
  local soft_err = pcall_results[3]
  if not ok then
    return nil, errors.ErrorCode.INTERNAL_ERROR, "tool '" .. name .. "' failed: " .. tostring(result)
  end
  if result == nil and soft_err ~= nil then
    return nil, errors.ErrorCode.INTERNAL_ERROR, tostring(soft_err)
  end
  return errors.sanitize(result)
end

-- ============================================================================
-- Parameter helpers
-- ============================================================================

--- Validate that a required parameter exists.
---@param params table
---@param key string
---@return any value
---@return string|nil error
local function required(params, key)
  local v = params[key]
  if v == nil then
    return nil, "missing required parameter: " .. key
  end
  return v
end

--- Get an optional parameter with default.
---@param params table
---@param key string
---@param default any
---@return any
local function optional(params, key, default)
  local v = params[key]
  if v == nil then
    return default
  end
  return v
end

-- ============================================================================
-- Tool Definitions
-- ============================================================================

-- -- Buffer tools ----------------------------------------------------------

register {
  name = "buffer.list",
  description = "List all open buffers with metadata (id, name, filetype, modified, line_count).",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return editor.buffer_list()
  end,
}

register {
  name = "buffer.get",
  description = "Read lines from a buffer. Returns array of strings.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      start = { type = "integer", description = "Start line, 0-indexed inclusive (default 0)." },
      end_ = { type = "integer", description = "End line, 0-indexed exclusive (default -1 = end)." },
    },
  },
  handler = function(params)
    local lines, err = editor.buffer_get(params.buf, params.start, params.end_)
    if err then return nil, err end
    return { lines = lines, count = #lines }
  end,
}

register {
  name = "buffer.set",
  description = "Replace a range of lines in a buffer. Creates an undo point.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      start = { type = "integer", description = "Start line, 0-indexed inclusive." },
      end_ = { type = "integer", description = "End line, 0-indexed exclusive." },
      lines = { type = "array", items = { type = "string" }, description = "New lines to insert." },
    },
  },
  handler = function(params)
    local lines, err = required(params, "lines")
    if not lines then return nil, err end
    -- Accept both "lines" (string[]) or "text" (string with \n)
    local line_array
    if type(lines) == "string" then
      line_array = vim.split(lines, "\n", { plain = true })
    else
      line_array = lines
    end
    local ok, err = editor.buffer_set(params.buf, params.start, params.end_, line_array)
    if not ok then return nil, err end
    return { ok = true, lines_written = #line_array }
  end,
}

register {
  name = "buffer.edit",
  description = "Precise character-level text edit. Unlike buffer.set which replaces whole lines, this replaces exact character ranges.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      start_row = { type = "integer", description = "Start row, 0-indexed." },
      start_col = { type = "integer", description = "Start column, 0-indexed." },
      end_row = { type = "integer", description = "End row, 0-indexed." },
      end_col = { type = "integer", description = "End column, 0-indexed exclusive." },
      text = { type = "string", description = "Replacement text. Use \\n for newlines." },
    },
  },
  handler = function(params)
    local text, err = required(params, "text")
    if not text then return nil, err end
    local replacement = vim.split(text, "\n", { plain = true })
    local ok, err = editor.buffer_edit(
      params.buf,
      params.start_row, params.start_col,
      params.end_row, params.end_col,
      replacement
    )
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "buffer.create",
  description = "Create a new buffer, optionally with content and filetype.",
  parameters = {
    type = "object",
    properties = {
      lines = { type = "array", items = { type = "string" }, description = "Initial content." },
      name = { type = "string", description = "Buffer name (displayed in tabline)." },
      filetype = { type = "string", description = "Filetype for syntax highlighting." },
      listed = { type = "boolean", description = "Whether buffer appears in buffer list (default true)." },
    },
  },
  handler = function(params)
    local buf = editor.buffer_create(params.lines, params.name, {
      listed = params.listed,
      filetype = params.filetype,
    })
    return { buf = buf }
  end,
}

register {
  name = "buffer.delete",
  description = "Delete a buffer. Use force=true to discard unsaved changes.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id." },
      force = { type = "boolean", description = "Force delete even if modified (default false)." },
    },
  },
  handler = function(params)
    local ok, err = editor.buffer_delete(params.buf, params.force)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "buffer.save",
  description = "Save a buffer to disk.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
    },
  },
  handler = function(params)
    local ok, err = editor.buffer_save(params.buf)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "buffer.reload",
  description = "Force-reload a buffer from disk, discarding unsaved changes.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
    },
  },
  handler = function(params)
    local ok, err = editor.buffer_reload(params.buf)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "buffer.info",
  description = "Get detailed metadata about a buffer: path, directory, filetype, modified state, changedtick.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
    },
  },
  handler = function(params)
    return editor.buffer_info(params.buf)
  end,
}

-- -- Window tools ----------------------------------------------------------

register {
  name = "window.list",
  description = "List all windows with position, size, and associated buffer info.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return editor.window_list()
  end,
}

register {
  name = "window.focus",
  description = "Focus (activate) a specific window.",
  parameters = {
    type = "object",
    properties = {
      win = { type = "integer", description = "Window id." },
    },
  },
  handler = function(params)
    local ok, err = editor.window_focus(params.win)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "window.split",
  description = "Create a new split window. Optionally opens a file or buffer in it.",
  parameters = {
    type = "object",
    properties = {
      direction = { type = "string", enum = { "horizontal", "vertical", "above", "below", "left", "right" }, description = "Split direction (default 'below')." },
      file = { type = "string", description = "File path or buffer id (as string) to open." },
      size = { type = "integer", description = "Size in lines/columns." },
    },
  },
  handler = function(params)
    local win, err = editor.window_split(params.direction, params.file, params.size)
    if not win then return nil, err end
    return { win = win }
  end,
}

register {
  name = "window.close",
  description = "Close a window (will not close the last window).",
  parameters = {
    type = "object",
    properties = {
      win = { type = "integer", description = "Window id." },
      force = { type = "boolean", description = "Force close (default false)." },
    },
  },
  handler = function(params)
    local ok, err = editor.window_close(params.win, params.force)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "window.config",
  description = "Set window configuration (position, size, border).",
  parameters = {
    type = "object",
    properties = {
      win = { type = "integer", description = "Window id." },
      config = { type = "object", description = "Window config dict (see nvim_open_win config)." },
    },
  },
  handler = function(params)
    local ok, err = editor.window_config(params.win, params.config)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

-- -- Cursor tools ----------------------------------------------------------

register {
  name = "cursor.get",
  description = "Get cursor position (1-indexed row, 0-indexed column).",
  parameters = {
    type = "object",
    properties = {
      win = { type = "integer", description = "Window id (0 = current)." },
    },
  },
  handler = function(params)
    local row, col = editor.cursor_get(params.win)
    return { row = row, col = col }
  end,
}

register {
  name = "cursor.set",
  description = "Set cursor position. The window this cursor is in will be focused.",
  parameters = {
    type = "object",
    properties = {
      win = { type = "integer", description = "Window id (0 = current)." },
      row = { type = "integer", description = "Row (1-indexed)." },
      col = { type = "integer", description = "Column (0-indexed, default 0)." },
    },
  },
  handler = function(params)
    local ok, err = editor.cursor_set(params.win, params.row, params.col)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "window.scroll",
  description = "Scroll a window up or down by N lines.",
  parameters = {
    type = "object",
    properties = {
      win = { type = "integer", description = "Window id (0 = current)." },
      amount = { type = "integer", description = "Lines to scroll (positive=down, negative=up)." },
    },
  },
  handler = function(params)
    local ok, err = editor.window_scroll(params.win, params.amount)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

-- -- Editor / Mode tools ---------------------------------------------------

register {
  name = "mode.get",
  description = "Get the current editor mode (normal, insert, visual, etc.) and blocking status.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local m = editor.mode_get()
    return { mode = m.mode, blocking = m.blocking }
  end,
}

register {
  name = "command",
  description = "Execute an Ex/Vim command (e.g. 'write', 'edit file.lua', '%s/foo/bar/g'). Powerful escape hatch.",
  parameters = {
    type = "object",
    properties = {
      cmd = { type = "string", description = "Ex command to execute." },
    },
  },
  handler = function(params)
    local cmd, err = required(params, "cmd")
    if not cmd then return nil, err end

    -- Capture Ex command output via :redir to suppress Vim cmdline messages.
    -- Output is returned to the model but NOT displayed in the chat UI.
    local saved_reg_x = vim.fn.getreg("x")
    local saved_regtype_x = vim.fn.getregtype("x")
    local output = ""
    local redir_ok = pcall(function()
      vim.cmd("redir @x")
      vim.cmd("silent! " .. cmd)
      vim.cmd("redir END")
      output = vim.fn.getreg("x"):gsub("^%s+", ""):gsub("%s+$", "")
    end)
    pcall(vim.fn.setreg, "x", saved_reg_x, saved_regtype_x)
    if not redir_ok then
      local ok2, err3 = editor.command_execute(cmd)
      if not ok2 then return nil, err3 end
      return { ok = true }
    end
    return { ok = true, output = output }
  end,
}

register {
  name = "feedkeys",
  description = "Feed keys to Neovim as if the user typed them. Use for complex navigation or mode switching.",
  parameters = {
    type = "object",
    properties = {
      keys = { type = "string", description = "Key sequence (e.g. 'gg', '3j', 'ciw', '<C-o>')." },
      mode = { type = "string", enum = { "n", "i", "v", "x", "t", "c" }, description = "Mode flag (default 't' = interpret)." },
    },
  },
  handler = function(params)
    local keys, err = required(params, "keys")
    if not keys then return nil, err end
    local ok, err2 = editor.feedkeys(keys, params.mode)
    if not ok then return nil, err2 end
    return { ok = true }
  end,
}

register {
  name = "eval",
  description = "Evaluate a Vim expression and return the result.",
  parameters = {
    type = "object",
    properties = {
      expr = { type = "string", description = "Vim expression (e.g. 'expand(\"%\")', 'line(\"$\")')." },
    },
  },
  handler = function(params)
    local expr, err = required(params, "expr")
    if not expr then return nil, err end
    local result, err2 = editor.vim_eval(expr)
    if not result and err2 then return nil, err2 end
    return { value = result }
  end,
}

register {
  name = "lua",
  description = "Execute arbitrary Lua code in Neovim's context. Full access to vim.* APIs. Use carefully.",
  parameters = {
    type = "object",
    properties = {
      code = { type = "string", description = "Lua code to execute." },
    },
  },
  handler = function(params)
    local code, err = required(params, "code")
    if not code then return nil, err end
    local result, err2 = editor.exec_lua(code)
    if not result and err2 then return nil, err2 end
    return { value = result }
  end,
}

register {
  name = "bash",
  description = "Execute a shell command and return stdout + stderr + exit code. Vim's :! passthrough -- the Agent's terminal. Use for: running tests, git, npm/pip, build commands, file system ops. Caution: blocking, prefer quick commands.",
  parameters = {
    type = "object",
    properties = {
      cmd = { type = "string", description = "Shell command to execute." },
      cwd = { type = "string", description = "Working directory (default: current file's directory)." },
      timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 30000)." },
    },
    required = { "cmd" },
  },
  handler = function(params)
    local cmd, err = required(params, "cmd")
    if not cmd then return nil, err end
    local cwd = params.cwd
    local timeout = params.timeout_ms or 30000

    -- Resolve cwd: use provided, or current file's directory, or Neovim's cwd
    if not cwd then
      local buf = vim.api.nvim_get_current_buf()
      local fname = vim.api.nvim_buf_get_name(buf)
      if fname ~= "" then
        cwd = vim.fn.fnamemodify(fname, ":h")
      else
        cwd = vim.fn.getcwd()
      end
    end

    -- Use vim.fn.system with timeout via systemlist + timeout command wrapper
    local shell_cmd
    if vim.fn.has("mac") == 1 or vim.fn.has("unix") == 1 then
      -- Use timeout (macOS: gtimeout or perl fallback)
      local has_timeout = vim.fn.executable("timeout") == 1 or vim.fn.executable("gtimeout") == 1
      if has_timeout then
        local tcmd = vim.fn.executable("gtimeout") == 1 and "gtimeout" or "timeout"
        shell_cmd = string.format("cd %s && %s %d %s", vim.fn.shellescape(cwd), tcmd, math.floor(timeout / 1000), cmd)
      else
        shell_cmd = string.format("cd %s && %s", vim.fn.shellescape(cwd), cmd)
      end
    else
      shell_cmd = string.format("cd /d %s && %s", vim.fn.shellescape(cwd), cmd)
    end

    local stdout = vim.fn.system(shell_cmd)
    local exit_code = vim.v.shell_error

    -- Trim trailing newline
    stdout = stdout:gsub("\n$", "")

    -- Truncate if too large
    if #stdout > 50000 then
      stdout = stdout:sub(1, 50000) .. "\n... [truncated, " .. (#stdout - 50000) .. " more bytes]"
    end

    return {
      stdout = stdout,
      stderr = "",  -- system() combines both; stderr goes to stdout
      exit_code = exit_code,
      cwd = cwd,
    }
  end,
}

register {
  name = "visual.get",
  description = "Get the current visual selection range and content.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local sel, err = editor.get_visual_selection()
    if not sel then return nil, err end
    return sel
  end,
}

-- -- Highlight tools -------------------------------------------------------

register {
  name = "highlight.add",
  description = "Highlight a region in a buffer using extmarks. The Agent uses this to mark code regions for the user.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      start_row = { type = "integer", description = "Start row, 0-indexed." },
      start_col = { type = "integer", description = "Start column, 0-indexed (default 0)." },
      end_row = { type = "integer", description = "End row, 0-indexed." },
      end_col = { type = "integer", description = "End column, 0-indexed exclusive." },
      hl_group = { type = "string", description = "Highlight group (e.g. 'Visual', 'Search', 'ErrorMsg', 'DiffAdd', 'DiffDelete'). Default 'Visual'." },
    },
  },
  handler = function(params)
    local id, err = editor.highlight_add(
      params.buf,
      params.start_row, params.start_col or 0,
      params.end_row, params.end_col or 0,
      params.hl_group
    )
    if not id then return nil, err end
    return { extmark_id = id }
  end,
}

register {
  name = "highlight.del",
  description = "Remove a specific highlight extmark.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      id = { type = "integer", description = "Extmark id returned by highlight.add." },
    },
  },
  handler = function(params)
    local ok, err = editor.highlight_del(params.buf, params.id)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "highlight.clear",
  description = "Clear all xaster highlights from a buffer.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
    },
  },
  handler = function(params)
    local count = editor.highlight_clear(params.buf)
    return { cleared = count }
  end,
}

register {
  name = "virtual_text.show",
  description = "Display virtual text (inline annotation) at a buffer position. Good for inline hints.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      row = { type = "integer", description = "Row, 0-indexed." },
      col = { type = "integer", description = "Column, 0-indexed." },
      text = { type = "string", description = "Text to display." },
      hl_group = { type = "string", description = "Highlight group (default 'Comment')." },
    },
  },
  handler = function(params)
    local id, err = editor.virtual_text_set(params.buf, params.row, params.col, params.text, params.hl_group)
    if not id then return nil, err end
    return { extmark_id = id }
  end,
}

-- -- LSP tools -------------------------------------------------------------

register {
  name = "lsp.hover",
  description = "Get hover/documentation information at the current cursor position.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local result, err = editor.lsp_hover()
    if not result then return nil, err end
    return { contents = result }
  end,
}

register {
  name = "lsp.definition",
  description = "Go to / get the definition of the symbol under cursor.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local result, err = editor.lsp_definition()
    if not result then return nil, err end
    return { locations = result }
  end,
}

register {
  name = "lsp.references",
  description = "Find all references of the symbol under cursor.",
  parameters = {
    type = "object",
    properties = {
      include_declaration = { type = "boolean", description = "Include declaration (default true)." },
    },
  },
  handler = function(params)
    local result, err = editor.lsp_references(params.include_declaration)
    if not result then return nil, err end
    return { locations = result }
  end,
}

register {
  name = "lsp.diagnostics",
  description = "Get LSP diagnostics for a buffer or all buffers.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (omit for all buffers)." },
    },
  },
  handler = function(params)
    return editor.lsp_diagnostics(params.buf)
  end,
}

register {
  name = "lsp.code_actions",
  description = "List or execute code actions at cursor position.",
  parameters = {
    type = "object",
    properties = {
      execute = { type = "integer", description = "If provided, execute the action at this index." },
    },
  },
  handler = function(params)
    local result, err = editor.lsp_code_actions(params.execute)
    if not result then return nil, err end
    return { actions = result }
  end,
}

register {
  name = "lsp.document_symbols",
  description = "Get document symbols (outline/structure) for a buffer.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
    },
  },
  handler = function(params)
    return editor.lsp_document_symbols(params.buf)
  end,
}

register {
  name = "lsp.workspace_symbols",
  description = "Search for symbols across the entire workspace.",
  parameters = {
    type = "object",
    properties = {
      query = { type = "string", description = "Symbol name or pattern to search." },
    },
  },
  handler = function(params)
    return editor.lsp_workspace_symbols(params.query or "")
  end,
}

-- -- Register / Mark tools -------------------------------------------------
-- Register operations with stack semantics, type awareness,
-- expression evaluation, and register-driven navigation.

register {
  name = "register.get",
  description = "Get the contents of a register. For named registers (a-z) with a stack, returns the top value.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name (e.g. '\"', 'a', '+', '*', '0')." },
    },
  },
  handler = function(params)
    local result, err = editor.register_get(params.name)
    if not result then return nil, err end
    return { content = result }
  end,
}

register {
  name = "register.get_type",
  description = "Get the type of a register: 'v' (characterwise), 'V' (linewise), or '^V' (blockwise). Determines paste behavior.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name." },
    },
  },
  handler = function(params)
    local rtype = editor.register_get_type(params.name)
    return { type = rtype }
  end,
}

register {
  name = "register.set",
  description = "Set the contents of a register with optional type.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name." },
      value = { type = "string", description = "Content to store." },
      type = { type = "string", description = "Register type: 'v' (characterwise, default), 'V' (linewise), '^V' (blockwise)." },
    },
  },
  handler = function(params)
    local ok, err = editor.register_set(params.name, params.value, params.type)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

register {
  name = "register.push",
  description = "Push a value onto the register's internal stack. The Vim register is updated to the new top. Named registers a-z/A-Z maintain a history stack (max 20 entries). Use to save intermediate editing states.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name (a-z, A-Z)." },
      value = { type = "string", description = "Content to push." },
      type = { type = "string", description = "Register type: 'v', 'V', '^V' (default 'v')." },
    },
    required = { "name", "value" },
  },
  handler = function(params)
    local result = editor.register_push(params.name, params.value, params.type)
    if not result.ok then return nil, result.error end
    return result
  end,
}

register {
  name = "register.pop",
  description = "Pop the top value from a register's internal stack. Returns the popped value and updates the Vim register to the new top. Useful for undo-like workflows: push before editing, pop to restore.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name (a-z, A-Z)." },
    },
    required = { "name" },
  },
  handler = function(params)
    local result = editor.register_pop(params.name)
    if not result.ok then return nil, result.error end
    return result
  end,
}

register {
  name = "register.peek",
  description = "Peek at the register's internal stack without modifying it. Returns entries newest-first. Use depth=1 for just the top value's metadata.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name (a-z, A-Z)." },
      depth = { type = "integer", description = "How many entries from the top to return (1 = top only, omit = entire stack)." },
    },
    required = { "name" },
  },
  handler = function(params)
    local result = editor.register_peek(params.name, params.depth)
    if not result.ok then return nil, result.error end
    return result
  end,
}

register {
  name = "register.rotate",
  description = "Rotate the register stack: direction=1 moves top to bottom (like Vim numbered registers), direction=-1 moves bottom to top. Updates Vim register to new top.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name (a-z, A-Z)." },
      direction = { type = "integer", description = "1 = top->bottom, -1 = bottom->top (default 1)." },
    },
    required = { "name" },
  },
  handler = function(params)
    local result = editor.register_rotate(params.name, params.direction or 1)
    if not result.ok then return nil, result.error end
    return result
  end,
}

register {
  name = "register.eval",
  description = "Evaluate a register: if it has an attached Lua expression, re-evaluate it live. Otherwise behaves like register.get. Use after register.set_expression to get a live-computed value.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name (a-z, A-Z)." },
    },
    required = { "name" },
  },
  handler = function(params)
    local result = editor.register_eval(params.name)
    return { content = result }
  end,
}

register {
  name = "register.set_expression",
  description = "Attach a Lua expression to a register. Every time register.eval is called on it, the expression is re-evaluated and the result becomes the register value. Use for dynamic computed registers (e.g. 'vim.fn.line(\"$\")' for total lines).",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name (a-z, A-Z)." },
      expr = { type = "string", description = "Lua expression (e.g. 'vim.fn.line(\"$\")', 'vim.fn.expand(\"%\")')." },
    },
    required = { "name", "expr" },
  },
  handler = function(params)
    local result = editor.register_set_expression(params.name, params.expr)
    if not result.ok then return nil, result.error end
    return result
  end,
}

register {
  name = "register.jump_to",
  description = "Parse a register's content as a file:line[:col] location and jump to it. Opens the file and moves cursor to the specified position. Use with register.set to store navigable locations.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Register name whose content is 'file:line' or 'file:line:col'." },
    },
    required = { "name" },
  },
  handler = function(params)
    local result = editor.register_jump_to(params.name)
    if not result then return nil, "register content is not a 'file:line' location" end
    return result
  end,
}

register {
  name = "register.list",
  description = "List all non-empty registers with their type, truncated content, and stack depth (if > 1).",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return editor.register_list()
  end,
}

register {
  name = "mark.get",
  description = "Get the position of a named mark.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Mark name (a-z, ., ', \", ^, etc.)." },
    },
  },
  handler = function(params)
    local result, err = editor.mark_get(params.name)
    if not result then return nil, err end
    return result
  end,
}

register {
  name = "mark.set",
  description = "Set a mark at the cursor position or a specified position.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Mark name (a-z)." },
      row = { type = "integer", description = "Row (1-indexed, uses cursor if omitted)." },
      col = { type = "integer", description = "Column (0-indexed)." },
    },
  },
  handler = function(params)
    local ok, err = editor.mark_set(params.name, params.row, params.col)
    if not ok then return nil, err end
    return { ok = true }
  end,
}

-- -- Undo / Redo tools -----------------------------------------------------

register {
  name = "undo.savepoint",
  description = "Create an undo breakpoint. Subsequent edits from the Agent will be a single undo block.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local ok = editor.undo_savepoint()
    return { ok = ok }
  end,
}

register {
  name = "undo",
  description = "Undo one or more changes.",
  parameters = {
    type = "object",
    properties = {
      count = { type = "integer", description = "Number of undo steps (default 1)." },
    },
  },
  handler = function(params)
    local ok = editor.undo(params.count)
    return { ok = ok }
  end,
}

register {
  name = "redo",
  description = "Redo one or more undone changes.",
  parameters = {
    type = "object",
    properties = {
      count = { type = "integer", description = "Number of redo steps (default 1)." },
    },
  },
  handler = function(params)
    local ok = editor.redo(params.count)
    return { ok = ok }
  end,
}

register {
  name = "undo.tree",
  description = "Get the undo tree for a buffer (sequence numbers, save points, branch information).",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
    },
  },
  handler = function(params)
    local result, err = editor.undo_tree(params.buf)
    if not result then return nil, err end
    return result
  end,
}

-- -- Tab tools -------------------------------------------------------------

register {
  name = "tab.list",
  description = "List all tabpages with their windows.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return editor.tab_list()
  end,
}

-- -- Quickfix tools --------------------------------------------------------

register {
  name = "quickfix.list",
  description = "Get the current quickfix list items.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return editor.quickfix_list()
  end,
}

register {
  name = "quickfix.set",
  description = "Set the quickfix list and optionally open the quickfix window.",
  parameters = {
    type = "object",
    properties = {
      items = { type = "array", items = { type = "object" }, description = "Array of {filename, lnum, col, text, type}." },
      open = { type = "boolean", description = "Open the quickfix window (default false)." },
    },
  },
  handler = function(params)
    local ok = editor.quickfix_set(params.items or {}, params.open and "open" or nil)
    return { ok = ok }
  end,
}

-- -- Meta / Observer tools -------------------------------------------------

register {
  name = "observe",
  description = "Take a complete snapshot of the editor state: current file, visible content, all buffers, windows, tabs, diagnostics. This is the primary way the Agent perceives the editor state.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return editor.observe()
  end,
}

register {
  name = "ping",
  description = "Check if the xaster server is alive. Returns with server info.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return {
      pong = true,
      version = "0.1.0",
      nvim_version = vim.fn.has("nvim-0.10") == 1 and "0.10+" or vim.api.nvim_call_function("execute", { "version" }),
      timestamp = os.time(),
    }
  end,
}

register {
  name = "tools.list",
  description = "List all available xaster tools with their descriptions and parameter schemas.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local tools = {}
    for name, def in pairs(registry) do
      table.insert(tools, {
        name = name,
        description = def.description,
        parameters = def.parameters,
      })
    end
    table.sort(tools, function(a, b) return a.name < b.name end)
    return tools
  end,
}

-- ============================================================================
-- Virtual Cursor Tools (Agent's position indicator)
-- vcursor.set now directly moves the user's cursor to where the agent is working.
-- vcursor.flash still uses extmarks for brief visual pulses.
-- ============================================================================

register {
  name = "vcursor.set",
  description = "Move the cursor in a buffer to show where the Agent is working. This moves the user's real cursor so they can follow the Agent's actions. The window showing the target buffer will be focused.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      row = { type = "integer", description = "Row, 0-indexed." },
      col = { type = "integer", description = "Column, 0-indexed (default 0)." },
      mode = { type = "string", enum = { "reading", "editing" }, description = "Cursor mode: 'reading' or 'editing' (editing mode also flashes). Default 'reading'." },
    },
  },
  handler = function(params)
    local buf = params.buf or vim.api.nvim_get_current_buf()
    if buf == 0 then buf = vim.api.nvim_get_current_buf() end
    if not vim.api.nvim_buf_is_valid(buf) then
      return { ok = false, error = "buffer not found: " .. tostring(buf) }
    end

    local row = (params.row or 0) + 1  -- 0-indexed -> 1-indexed
    local col = params.col or 0

    -- Find a window showing this buffer, or use current window
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
      vim.api.nvim_set_current_win(target_win)
      pcall(vim.api.nvim_win_set_cursor, target_win, { row, col })
    else
      -- Switch current window to show this buffer
      vim.api.nvim_win_set_buf(current_win, buf)
      pcall(vim.api.nvim_win_set_cursor, current_win, { row, col })
    end

    -- Flash if editing mode
    if params.mode == "editing" then
      vcursor_mod.flash(buf, params.row or 0, col)
    end

    return { ok = true, buf = buf, row = params.row or 0, col = col, mode = params.mode or "reading" }
  end,
}

register {
  name = "vcursor.get",
  description = "Query the current position of the Agent's virtual cursor(s). Returns nil if no virtual cursor is set for the buffer.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (omit for all cursors)." },
    },
  },
  handler = function(params)
    local result = vcursor_mod.get(params.buf)
    return result or { cursors = {}, count = 0 }
  end,
}

register {
  name = "vcursor.clear",
  description = "Remove the Agent's virtual cursor from a buffer (or all buffers).",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (omit to clear all)." },
    },
  },
  handler = function(params)
    
    local count = vcursor_mod.clear(params.buf)
    return { cleared = count }
  end,
}

register {
  name = "vcursor.flash",
  description = "Briefly flash a location to draw the user's attention. Creates a temporary highlight that disappears after ~400ms.",
  parameters = {
    type = "object",
    properties = {
      buf = { type = "integer", description = "Buffer id (0 = current)." },
      row = { type = "integer", description = "Row, 0-indexed." },
      col = { type = "integer", description = "Column, 0-indexed (default 0)." },
    },
  },
  handler = function(params)
    
    vcursor_mod.flash(params.buf, params.row or 0, params.col or 0)
    return { ok = true }
  end,
}

-- ============================================================================
-- History / Audit Tools (Agent's self-audit trail)
-- ============================================================================

register {
  name = "history.list",
  description = "List recent tool call history. The operation log of everything the Agent (or other clients) has done through xaster. Supports filtering by tool name, buffer, and time.",
  parameters = {
    type = "object",
    properties = {
      n = { type = "integer", description = "Number of recent entries to return (default 50)." },
      tool = { type = "string", description = "Filter by tool name (e.g. 'buffer.edit', 'cursor.set')." },
      buf = { type = "integer", description = "Filter by buffer id." },
      since = { type = "integer", description = "Unix timestamp -- only return entries after this time." },
    },
  },
  handler = function(params)
    
    return history_mod.list({
      n = params.n,
      tool = params.tool,
      buf = params.buf,
      since = params.since,
    })
  end,
}

register {
  name = "history.get",
  description = "Get a specific history entry by its sequence number.",
  parameters = {
    type = "object",
    properties = {
      seq = { type = "integer", description = "Sequence number of the history entry." },
    },
  },
  handler = function(params)
    
    local entry = history_mod.get(params.seq)
    if not entry then
      return nil, "no history entry with seq=" .. tostring(params.seq)
    end
    return entry
  end,
}

register {
  name = "history.clear",
  description = "Clear all operation history. Note: this is auditable -- the clear operation itself is recorded as the last entry.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    
    local count = history_mod.clear()
    return { erased = count }
  end,
}

register {
  name = "history.stats",
  description = "Get statistics about tool usage: total calls, calls per tool, error rate, average execution time.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    
    return history_mod.stats()
  end,
}

register {
  name = "history.observe",
  description = "Get the full state machine snapshot of the history system: total entries, max entries, hooks count, stats.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    
    return history_mod.observe()
  end,
}

-- ============================================================================
-- Editor Lock (batch operation isolation)
-- ============================================================================

register {
  name = "lock.set",
  description = "Enable or disable the batch operation lock. When locked, the user cannot edit any buffer (only navigate/scroll/yank/observe) while the Agent's tools bypass the lock transparently. Use before complex multi-step edits to prevent accidental user interference.",
  parameters = {
    type = "object",
    properties = {
      locked = { type = "boolean", description = "true = lock (Agent-only edit), false = unlock (user can edit)." },
    },
  },
  handler = function(params)
    local ok, lock = pcall(require, "xaster.lock")
    if not ok then
      return nil, "lock module not available"
    end
    if params.locked == false then
      return lock.disable()
    else
      return lock.enable({ by = "agent" })
    end
  end,
}

register {
  name = "lock.get",
  description = "Query the current lock state: whether locked, when locked, who locked it, and how many edits have been bypassed.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local ok, lock = pcall(require, "xaster.lock")
    if not ok then
      return { locked = false, available = false }
    end
    return lock.observe()
  end,
}

-- ============================================================================
-- Combined state observation
-- ============================================================================

register {
  name = "state.observe",
  description = "Full xaster state machine snapshot: editor state + virtual cursors + operation history + connection status. The most comprehensive view of the entire system.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    return {
      editor = editor.observe(),
      vcursors = vcursor_mod.observe(),
      history = history_mod.observe(),
      lock = lock_mod.observe(),
    }
  end,
}

-- ============================================================================
-- Log Introspection (Agent can read its own logs)
-- ============================================================================

register {
  name = "log.dump",
  description = "Read the xaster internal log (ring buffer). The agent can introspect its own operation history, error traces, and performance data. Useful for debugging why a tool failed or understanding what happened in previous rounds.",
  parameters = {
    type = "object",
    properties = {
      n = { type = "integer", description = "Number of recent entries (default 50)." },
      level = { type = "string", enum = { "DEBUG", "INFO", "WARN", "ERROR" }, description = "Filter by log level." },
      module = { type = "string", description = "Filter by module name (e.g. 'agent', 'llm', 'tools')." },
    },
  },
  handler = function(params)
    local ok, log_mod = pcall(require, "xaster.log")
    if not ok then
      return nil, "log module not available"
    end
    local dump = log_mod.dump({
      n = params.n or 50,
      level = params.level,
      module = params.module,
    })
    return { log = dump }
  end,
}

register {
  name = "log.observe",
  description = "Get log system statistics: total entries, ring buffer size, file logging status.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local ok, log_mod = pcall(require, "xaster.log")
    if not ok then
      return nil, "log module not available"
    end
    return log_mod.observe()
  end,
}

register {
  name = "agent.observe",
  description = "Get current agent state: round number, token usage, circuit breaker status, running status. The agent can introspect its own execution state.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    local ok, agent = pcall(require, "xaster.agent")
    if not ok then
      return nil, "agent module not available"
    end
    return agent.observe()
  end,
}

-- ============================================================================
-- File Operations -- write through Neovim, not filesystem
-- ============================================================================
-- These are thin wrappers: open file in Vim, edit in Vim, Vim saves to disk.
-- The Agent uses Vim as its editor, not the filesystem.

register {
  name = "file.read",
  description = "Read a file through Neovim. Opens the file in Neovim if not already open, focuses its window, reads content, returns in cat -n format with line numbers.",
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "Absolute or relative file path to read." },
      start = { type = "integer", description = "Start line (0-indexed inclusive, default 0)." },
      end_ = { type = "integer", description = "End line (0-indexed exclusive, default -1 = all)." },
      focus = { type = "boolean", description = "Whether to focus the file in Neovim (default true)." },
    },
    required = { "filepath" },
  },
  handler = function(params)
    local result, err = editor.file_read(params.filepath, {
      start = params.start,
      end_ = params.end_,
      focus = params.focus,
    })
    if not result then
      return nil, err
    end
    return result
  end,
}

register {
  name = "file.write",
  description = "Write to a file through Neovim. Opens the file, applies edits with undo.savepoint, saves to disk, checks diagnostics. Supports full content replace via 'content' (string), or precise edits via 'edits' array of {start_row, start_col, end_row, end_col, text}. Instant mode by default; set animated=true for cosmetic streaming.",
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "File path to write to." },
      content = { type = "string", description = "Full new content (string with \\n, replaces entire file). Use for new files or full rewrites." },
      edits = {
        type = "array",
        items = {
          type = "object",
          properties = {
            start_row = { type = "integer", description = "Start row, 0-indexed." },
            start_col = { type = "integer", description = "Start column, 0-indexed (default 0)." },
            end_row = { type = "integer", description = "End row, 0-indexed." },
            end_col = { type = "integer", description = "End column, 0-indexed exclusive." },
            text = { type = "string", description = "Replacement text. Use \\n for newlines." },
          },
        },
        description = "Array of precise edits. For modifying existing files -- only changes the specified ranges.",
      },
      animated = { type = "boolean", description = "Enable cosmetic streaming typewriter effect (default false)." },
      chunk_delay_ms = { type = "integer", description = "Milliseconds between each line in streaming mode (default 15, min 8)." },
    },
    required = { "filepath" },
  },
  handler = function(params)
    local result, err = editor.file_write(params.filepath, {
      content = params.content,
      edits = params.edits,
      animated = params.animated,
      chunk_delay_ms = params.chunk_delay_ms,
    })
    if not result then
      return nil, err
    end
    return result
  end,
}

register {
  name = "file.ensure_open",
  description = "Ensure a file is open in Neovim. Returns the buffer id. If already open, focuses its window. If not open, opens it with :edit. Useful before doing other buffer operations on a file.",
  parameters = {
    type = "object",
    properties = {
      filepath = { type = "string", description = "File path to ensure open." },
      focus = { type = "boolean", description = "Whether to focus the window (default true)." },
    },
    required = { "filepath" },
  },
  handler = function(params)
    local buf, err = editor.file_ensure_open(params.filepath, {
      focus = params.focus,
    })
    if not buf then
      return nil, err
    end
    return {
      buf = buf,
      filepath = vim.api.nvim_buf_get_name(buf),
      filetype = vim.api.nvim_get_option_value("filetype", { buf = buf }),
      line_count = vim.api.nvim_buf_line_count(buf),
    }
  end,
}

register {
  name = "file.watch",
  description = "Enable/disable file watching. When enabled, Neovim automatically reloads buffers when files change on disk from external tools (e.g. git checkout, build artifacts). The Agent normally edits through Vim directly, so file watching is for catching external changes.",
  parameters = {
    type = "object",
    properties = {
      enabled = { type = "boolean", description = "Enable or disable file watching (default true)." },
      interval_ms = { type = "integer", description = "Check interval in milliseconds (default 2000)." },
    },
  },
  handler = function(params)
    if params.enabled == false then
      -- Disable file sync
      local augroup = vim.api.nvim_create_augroup("xaster_file_sync", {})
      vim.api.nvim_del_augroup_by_id(augroup)
      return { ok = true, enabled = false }
    end

    local sync = editor.file_sync_setup({
      checktime_interval_ms = params.interval_ms or 2000,
      auto_reload = true,
    })

    return {
      ok = true,
      enabled = true,
      interval_ms = params.interval_ms or 2000,
    }
  end,
}

-- ============================================================================
-- Working Memory Tools (Agent's scratchpad)
-- ============================================================================

register {
  name = "memory.remember",
  description = "Store a fact in working memory. Use to track task progress, file paths, search results, or intermediate state. Memory persists across conversation rounds. Keys with __ prefix are reserved for framework use.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Memory key (e.g. 'target_file', 'plan', 'bug_locations')." },
      value = { type = "string", description = "Value to store (string or JSON)." },
    },
    required = { "key", "value" },
  },
  handler = function(params)
    
    memory_mod.remember(params.key, params.value, { source = "agent" })
    return { ok = true, key = params.key }
  end,
}

register {
  name = "memory.recall",
  description = "Retrieve a fact from working memory.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Memory key to retrieve." },
    },
    required = { "key" },
  },
  handler = function(params)
    
    local value = memory_mod.recall(params.key)
    return { key = params.key, value = value, found = value ~= nil }
  end,
}

register {
  name = "memory.forget",
  description = "Delete a fact from working memory.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Memory key to forget." },
    },
    required = { "key" },
  },
  handler = function(params)
    
    local existed = memory_mod.forget(params.key)
    return { ok = true, existed = existed }
  end,
}

register {
  name = "memory.tasks_init",
  description = "Initialize a task list for the current session. Each task can declare dependencies (depends_on) which block it until the dependency is done. Auto-computes blocked_by reverse edges.",
  parameters = {
    type = "object",
    properties = {
      tasks = {
        type = "array",
        items = {
          type = "object",
          properties = {
            id = { type = "string", description = "Task id (e.g. '1', 'read-files')." },
            title = { type = "string", description = "Short task description." },
            depends_on = {
              type = "array",
              items = { type = "string" },
              description = "Task IDs this task depends on. Cannot start until all dependencies are 'done'.",
            },
          },
        },
        description = "Array of {id, title, [depends_on]} tasks.",
      },
    },
    required = { "tasks" },
  },
  handler = function(params)

    memory_mod.tasks_init(params.tasks)
    local progress = memory_mod.task_progress()
    return { ok = true, total = progress.total }
  end,
}

register {
  name = "memory.task_update",
  description = "Update a task's status.",
  parameters = {
    type = "object",
    properties = {
      id = { type = "string", description = "Task id to update." },
      status = { type = "string", enum = { "pending", "in_progress", "done", "blocked" }, description = "New status." },
    },
    required = { "id", "status" },
  },
  handler = function(params)
    
    memory_mod.task_update(params.id, params.status)
    local progress = memory_mod.task_progress()
    return { ok = true, progress = string.format("%d/%d done", progress.done, progress.total) }
  end,
}

register {
  name = "memory.task_progress",
  description = "Get overall task progress.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)
    
    return memory_mod.task_progress()
  end,
}

register {
  name = "memory.clear",
  description = "Clear ALL memory (fast, slow, snapshots, jump stack, marks). Full reset. Use when starting a completely new task.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    memory_mod.clear()
    return { ok = true }
  end,
}

-- -- Slow Memory (persistent knowledge layer) ------------------------------
-- Slow memory persists across conversation rounds and context compression.
-- It accumulates confirmed knowledge: project structure, conventions,
-- patterns, strategies. Fast memory consults slow as a fallback on recall.
-- The recursive loop: fast acts -> slow learns -> slow guides fast.

register {
  name = "memory.learn",
  description = "Learn a fact into slow memory. Use for knowledge you've confirmed and want to persist across rounds: project structure insights, coding conventions discovered, successful strategies, bug signatures. Each call to the same key reinforces confidence (0.5 -> 0.85 -> 0.95 -> ...). Includes type tagging ('fact','convention','structure','strategy','pattern') for later querying.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Knowledge key (e.g. 'project_entry_points', 'convention_error_handling', 'structure_module_graph')." },
      value = { type = "string", description = "The knowledge (string or JSON)." },
      type = { type = "string", description = "Knowledge type: 'fact', 'convention', 'structure', 'strategy', 'pattern'." },
      tags = { type = "array", items = { type = "string" }, description = "Searchable tags (e.g. ['lua', 'neovim', 'api'])." },
      confidence = { type = "number", description = "Initial confidence 0.0-1.0 (default 0.5). Higher = more certain." },
    },
    required = { "key", "value" },
  },
  handler = function(params)

    return memory_mod.learn(params.key, params.value, {
      confidence = params.confidence,
      type = params.type,
      tags = params.tags,
      source = "agent",
    })
  end,
}

register {
  name = "memory.know",
  description = "Directly read from slow memory, bypassing the fast layer. Use to check if something is already known without polluting fast memory.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Knowledge key to retrieve." },
    },
    required = { "key" },
  },
  handler = function(params)

    local value = memory_mod.know(params.key)
    return { key = params.key, value = value, known = value ~= nil }
  end,
}

register {
  name = "memory.query",
  description = "Search slow memory for knowledge matching a pattern. Searches key names, tags, and optionally filters by type and minimum confidence. Returns results sorted by confidence (highest first). Use to find relevant past learnings without knowing exact keys.",
  parameters = {
    type = "object",
    properties = {
      query = { type = "string", description = "Search term (matches key substring or tag). Omit to list all." },
      type = { type = "string", description = "Filter by knowledge type: 'fact', 'convention', 'structure', 'strategy', 'pattern'." },
      min_confidence = { type = "number", description = "Minimum confidence 0.0-1.0 (default: no filter)." },
      limit = { type = "integer", description = "Max results (default 20)." },
    },
  },
  handler = function(params)

    return memory_mod.query(params.query, {
      type = params.type,
      min_confidence = params.min_confidence,
      limit = params.limit,
    })
  end,
}

register {
  name = "memory.promote",
  description = "Promote a fact from fast memory to slow memory. The fast value becomes slow knowledge with initial confidence 0.4. Use when a fast-memory finding proves important and worth persisting.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Fast memory key to promote." },
      type = { type = "string", description = "Knowledge type for the slow entry." },
      tags = { type = "array", items = { type = "string" }, description = "Tags for future querying." },
    },
    required = { "key" },
  },
  handler = function(params)

    return memory_mod.promote(params.key, {
      type = params.type,
      tags = params.tags,
    })
  end,
}

register {
  name = "memory.demote",
  description = "Demote slow knowledge back to fast memory (with a 5-minute TTL). Use when something learned turns out to be transient or context-specific rather than general knowledge.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Slow memory key to demote." },
    },
    required = { "key" },
  },
  handler = function(params)

    return memory_mod.demote(params.key)
  end,
}

register {
  name = "memory.guide",
  description = "Ask slow memory to provide guidance relevant to the current situation. Returns the highest-confidence, most-accessed knowledge entries. This is the 'slow guides fast' direction of the recursive memory loop.",
  parameters = {
    type = "object",
    properties = {
      limit = { type = "integer", description = "Max guidance entries (default 16)." },
    },
  },
  handler = function(params)

    return memory_mod.guide(nil, params.limit)
  end,
}

register {
  name = "memory.absorb",
  description = "Scan fast memory for patterns worth promoting to slow knowledge. Detects file relationships, frequently-accessed keys, and structural conventions. Called periodically to distill fast observations into slow knowledge.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    return memory_mod.absorb()
  end,
}

register {
  name = "memory.slow_stats",
  description = "Get slow memory statistics: total entries, average confidence, breakdown by knowledge type.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    return memory_mod.slow_stats()
  end,
}

-- ============================================================================
-- Vim-Native Grammar Tools -- operator + motion/text-object
-- ============================================================================
-- These tools expose Vim's composable grammar to the Agent.
-- Instead of raw row/col edits, the Agent operates in Vim's native language.

register {
  name = "vim.edit",
  description = "Execute a Vim operator on a motion or text-object. This is Vim's native text manipulation language. Examples: ciw (change inner word), da} (delete around braces), >ap (indent paragraph), yiw (yank inner word), guw (lowercase word). For operators c/!/s/R that need replacement text, provide the text parameter. For operators d/y/>/</gu/gU/g~ that don't need text, omit it.",
  parameters = {
    type = "object",
    properties = {
      op = { type = "string", enum = { "c", "d", "y", ">", "<", "gu", "gU", "g~", "!", "s", "R" }, description = "Vim operator." },
      target = { type = "string", description = "Motion or text-object. Examples: 'iw', 'ap', 'i(', 'a{', 'i\"', '3j', 'w', 'b', 'f)', '/pattern', 'gg', 'G', '10G', '%', 't,', 'ip', 'it'." },
      text = { type = "string", description = "Replacement text for c/!/s/R operators. Use \\n for newlines. Omit for d/y/>/</gu/gU/g~." },
      count = { type = "integer", description = "Repeat count (default 1)." },
      row = { type = "integer", description = "Move cursor to this row first (1-indexed). Omit to use current position." },
      col = { type = "integer", description = "Move cursor to this col first (0-indexed). Omit to use current position." },
    },
    required = { "op", "target" },
  },
  handler = function(params)
    local op, err = required(params, "op")
    if not op then return nil, err end
    local target, err2 = required(params, "target")
    if not target then return nil, err2 end
    local text = params.text
    local count = params.count or 1

    -- Move cursor first if position specified
    if params.row then
      local ok_move = editor.cursor_set(0, params.row, params.col or 0)
      if not ok_move then
        return nil, "failed to move cursor to row " .. tostring(params.row)
      end
    end

    -- Build the key sequence: [count]operator[target][text<Esc>]
    local keys = ""
    if count > 1 then keys = keys .. tostring(count) end
    keys = keys .. op .. target

    if text and #text > 0 then
      -- For operators that take input (c, !, s, R): feed replacement then <Esc>
      -- Don't use feedkeys for multi-line replacement; use buffer.edit instead
      if text:find("\n") then
        keys = keys .. text:gsub("\n", "<CR>") .. "<Esc>"
      else
        keys = keys .. text .. "<Esc>"
      end
    end

    -- Execute in normal mode
    local ok_exec = editor.feedkeys(keys, "n")
    if not ok_exec then
      return nil, "vim.edit failed for " .. op .. target
    end

    return { ok = true, op = op, target = target }
  end,
}

register {
  name = "vim.search",
  description = "Execute a Vim search (/pattern or ?pattern) and optionally populate the quickfix list with all matches. Returns match count and first match position. Use action='quickfix' to populate the quickfix list for :cnext/:cprev navigation.",
  parameters = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Search pattern (Vim regex syntax)." },
      direction = { type = "string", enum = { "forward", "backward" }, description = "Search direction (default 'forward')." },
      action = { type = "string", enum = { "cursor", "quickfix" }, description = "'cursor' = move cursor to first match (default). 'quickfix' = populate quickfix list with all matches." },
      range_start = { type = "integer", description = "Start line for search range (1-indexed, default 1)." },
      range_end = { type = "integer", description = "End line for search range (1-indexed, default $)." },
    },
    required = { "pattern" },
  },
  handler = function(params)
    local pattern, err = required(params, "pattern")
    if not pattern then return nil, err end
    local direction = params.direction or "forward"
    local action = params.action or "cursor"
    local buf = vim.api.nvim_get_current_buf()

    -- Escape pattern for Ex command
    local escaped = pattern:gsub("/", "\\/")

    if action == "quickfix" then
      -- Use :vimgrep to populate quickfix
      local range = "%"
      if params.range_start and params.range_end then
        range = string.format("%d,%d", params.range_start, params.range_end)
      end
      local cmd = string.format("%svimgrep /%s/ %s", range, escaped, vim.fn.bufname(buf))
      pcall(vim.api.nvim_command, cmd)
      local qflist = vim.fn.getqflist()
      return { ok = true, matches = #qflist, action = "quickfix" }
    end

    -- cursor action: search and move
    local flag = direction == "backward" and "b" or ""
    local search_cmd = direction == "backward" and "?" or "/"
    editor.feedkeys(search_cmd .. escaped .. "<CR>", "n")

    local cursor = vim.api.nvim_win_get_cursor(0)
    return {
      ok = true,
      pattern = pattern,
      direction = direction,
      cursor = { row = cursor[1], col = cursor[2] },
    }
  end,
}

register {
  name = "vim.substitute",
  description = "Execute Vim's :substitute command on a range. Vim's native find-and-replace. Supports regex, backreferences, confirm flag, and all :s flags (g, i, c, n). Much more powerful than manual buffer.edit for pattern-based changes.",
  parameters = {
    type = "object",
    properties = {
      range = { type = "string", description = "Line range: % = entire file, 1,10 = lines 1-10, '<,'> = visual selection, .+1,$ = from next line to end." },
      pattern = { type = "string", description = "Search pattern (Vim regex)." },
      replacement = { type = "string", description = "Replacement text. Use \\1, \\2 for capture groups. Use \\r for newline." },
      flags = { type = "string", description = "Flags: 'g' = all occurrences on line, 'i' = ignore case, 'c' = confirm each, 'n' = count only (no replace). Default 'g'." },
    },
    required = { "pattern", "replacement" },
  },
  handler = function(params)
    local pattern, err = required(params, "pattern")
    if not pattern then return nil, err end
    local replacement, err2 = required(params, "replacement")
    if not replacement then return nil, err2 end
    local range = params.range or "%"
    local flags = params.flags or "g"

    -- Build :s command
    local cmd = string.format("%ss/%s/%s/%s", range, pattern, replacement, flags)
    editor.undo_savepoint()
    local ok, err = editor.command_execute(cmd)
    if not ok then
      return nil, "substitute failed: " .. tostring(err)
    end
    return { ok = true, cmd = cmd }
  end,
}

register {
  name = "vim.normal",
  description = "Execute a sequence of Vim normal mode commands. More structured than feedkeys -- specifically for normal mode operations. Use for complex Vim-native workflows: macros, window navigation, quickfix navigation, folding, etc.",
  parameters = {
    type = "object",
    properties = {
      keys = { type = "string", description = "Normal mode key sequence. Examples: 'gg=G' (reindent file), '>>' (indent line), 'za' (toggle fold), ':cnext<CR>' (next quickfix item), 'ggdG' (delete all)." },
    },
    required = { "keys" },
  },
  handler = function(params)
    local keys, err = required(params, "keys")
    if not keys then return nil, err end
    local ok = editor.feedkeys(keys, "n")
    if not ok then
      return nil, "vim.normal failed"
    end
    return { ok = true }
  end,
}

-- ============================================================================
-- Two-Layer Memory: Lua facts + Vim marks
-- ============================================================================
-- memory.mark stores a location in BOTH Lua memory (recallable by key)
-- AND as a Vim mark (jumpable with 'a-'z). This bridges the two memory layers.
-- memory.jump recalls a location from memory and jumps to it in the editor.

register {
  name = "memory.mark",
  description = "Store current file position in BOTH Lua memory AND as a Vim mark. Two-layer memory: the key lets you recall what's there, the mark letter lets you jump back instantly with '{letter}. Use for remembering important locations across files.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Memory key describing this location (e.g. 'main_entry', 'bug_site', 'refactor_target')." },
      mark = { type = "string", description = "Optional Vim mark letter (a-z). Auto-assigned if not provided." },
    },
    required = { "key" },
  },
  handler = function(params)
    
    local result = memory_mod.mark_location(params.key, params.mark)
    return result
  end,
}

register {
  name = "memory.jump",
  description = "Recall a stored location by key and jump to it in the editor. Opens the file if needed, moves cursor to the saved position. Optionally record the jump with an intent on the agent's semantic jump stack (for later backtracking with memory.jump_back). Pushes to Vim's jumplist so <C-o> works for the user.",
  parameters = {
    type = "object",
    properties = {
      key = { type = "string", description = "Memory key to recall and jump to." },
      intent = { type = "string", description = "Optional: why you're jumping (e.g. 'fix_bug_A', 'understand_imports'). Records in the semantic jump stack." },
    },
    required = { "key" },
  },
  handler = function(params)

    local loc = memory_mod.jump_to(params.key, params.intent)
    if not loc then
      return nil, "no location stored for key: " .. params.key
    end
    return loc
  end,
}

register {
  name = "memory.locations",
  description = "List all remembered locations (keys with stored file positions). Shows what the agent has marked across the project.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    local dump = memory_mod.dump_locations()
    return { locations = dump ~= "" and dump or "(no locations stored)" }
  end,
}

-- -- Semantic Jump Stack tools ------------------------------------------------
-- The agent maintains a LIFO navigation stack with intent annotations.
-- Unlike Vim's mechanical jumplist, each entry records WHY the agent went there,
-- enabling semantic backtracking through complex multi-step tasks.

register {
  name = "memory.jump_push",
  description = "Push current editor position onto the semantic jump stack with an intent label. Use before starting a sub-task that will navigate away, so you can jump_back later. Also pushes to Vim's jumplist for <C-o> support.",
  parameters = {
    type = "object",
    properties = {
      intent = { type = "string", description = "Why you're marking this position (e.g. 'start_refactor', 'before_exploring', 'entry_point')." },
    },
    required = { "intent" },
  },
  handler = function(params)

    local result = memory_mod.jump_push(params.intent)
    return result
  end,
}

register {
  name = "memory.jump_back",
  description = "Jump back to the previous position on the semantic jump stack. Like Vim's <C-o> but with intent awareness: you see WHY you were there. Opens the file and moves cursor. Does NOT remove the entry -- use jump_forward to go forward again.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    local result = memory_mod.jump_pop()
    if not result then
      return nil, "jump stack is empty (no previous positions)"
    end
    return result
  end,
}

register {
  name = "memory.jump_forward",
  description = "Jump forward in the semantic jump stack. Like Vim's <C-i> -- after using jump_back, use this to return to where you were before going back.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    local result = memory_mod.jump_forward()
    if not result then
      return nil, "already at newest position (cannot jump forward)"
    end
    return result
  end,
}

register {
  name = "memory.jump_peek",
  description = "Peek at the semantic jump stack without moving. Returns entries newest-first with file, row, intent, and whether each is the current position.",
  parameters = {
    type = "object",
    properties = {
      n = { type = "integer", description = "Number of recent entries to return (default: all)." },
    },
  },
  handler = function(params)

    local entries = memory_mod.jump_peek(params.n)
    local info = memory_mod.jump_info()
    return { entries = entries, total = info.total, current_index = info.current_index }
  end,
}

register {
  name = "memory.jump_info",
  description = "Get metadata about the semantic jump stack: total entries, current position, whether can jump back/forward.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    return memory_mod.jump_info()
  end,
}

-- -- StateNode Snapshot tools ------------------------------------------------
-- Named in-memory snapshots of editor state. Lighter than checkpoints:
-- capture buffer content (small files), cursor, registers, marks at a
-- specific moment. Use before risky multi-step edits to create a rewind point.

register {
  name = "memory.snapshot_create",
  description = "Create a named snapshot of the current editor state. Captures: current file + cursor, buffer content (if <500 lines), all named register values (a-z, A-Z), all named marks (a-z). Use before risky edits so you can snapshot_restore if something goes wrong or snapshot_diff to compare before/after.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Snapshot name (e.g. 'before_refactor', 'step_3', 'pre_merge')." },
      label = { type = "string", description = "Optional human-readable description." },
    },
    required = { "name" },
  },
  handler = function(params)

    return memory_mod.snapshot_create(params.name, params.label)
  end,
}

register {
  name = "memory.snapshot_restore",
  description = "Restore the editor to a previously saved snapshot. Restores file, buffer content (if captured), cursor position, register values, and marks. Use to rewind to a known-good state after a failed edit attempt.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Snapshot name to restore." },
    },
    required = { "name" },
  },
  handler = function(params)

    return memory_mod.snapshot_restore(params.name)
  end,
}

register {
  name = "memory.snapshot_diff",
  description = "Compare two snapshots and show what changed: file, cursor position, buffer lines (added/removed/changed), register values, mark positions. Use to understand exactly what your edits did between two states.",
  parameters = {
    type = "object",
    properties = {
      a = { type = "string", description = "First snapshot name (the 'before')." },
      b = { type = "string", description = "Second snapshot name (the 'after')." },
    },
    required = { "a", "b" },
  },
  handler = function(params)

    return memory_mod.snapshot_diff(params.a, params.b)
  end,
}

register {
  name = "memory.snapshot_list",
  description = "List all saved snapshots with metadata: name, time, file, label, whether buffer was captured, register/mark counts.",
  parameters = {
    type = "object",
    properties = {},
  },
  handler = function(_)

    return memory_mod.snapshot_list()
  end,
}

register {
  name = "memory.snapshot_delete",
  description = "Delete a snapshot by name. Use to clean up old snapshots you no longer need.",
  parameters = {
    type = "object",
    properties = {
      name = { type = "string", description = "Snapshot name to delete." },
    },
    required = { "name" },
  },
  handler = function(params)

    return { ok = memory_mod.snapshot_delete(params.name) }
  end,
}

return M
