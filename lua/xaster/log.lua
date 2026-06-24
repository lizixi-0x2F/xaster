--- xaster/log.lua
--- Structured logging for the xaster agent harness.
---
--- Three sinks:
---   1. Ring buffer (memory, always on, 2000 entries) -- introspectable by Agent
---   2. File sink (JSON lines, off by default) -- for post-mortem debugging
---   3. vim.notify (WARN+ERROR only) -- user-visible
---
--- Usage:
---   local log = require("xaster.log").for_module("agent")
---   log.info("task started", { round = 5, tokens = 12400 })
---   log.warn("slow tool", { tool = "bash", elapsed_ms = 3500 })
---   log.error("api call failed", { error = err_msg, retry = 2 })
---
--- The Agent can introspect its own log via the "log.dump" tool.
--- Entries are plain Lua tables until serialized (lazy -- no string work
--- until a sink actually needs it).

local M = {}

-- ============================================================================
-- Configuration
-- ============================================================================

local config = {
  level = "INFO",          -- DEBUG | INFO | WARN | ERROR
  ring_size = 2000,        -- max entries in memory ring buffer
  file_enabled = false,    -- whether to write to disk
  file_path = nil,         -- nil = auto: ~/.local/share/nvim/xaster/logs/
  file_max_size_mb = 5,    -- rotate when file exceeds this
  notify_enabled = true,   -- vim.notify for WARN+ERROR
}

local LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local function level_met(entry_level)
  local cfg_level = LEVELS[config.level] or LEVELS.INFO
  local ent_level = LEVELS[entry_level] or LEVELS.INFO
  return ent_level >= cfg_level
end

-- ============================================================================
-- Ring Buffer
-- ============================================================================

local ring = {}       -- array of entries
local ring_head = 1   -- write position
local ring_count = 0
local ring_seq = 0    -- global sequence number

---@class LogEntry
---@field seq integer        Global sequence number
---@field time number        os.time() with millisecond precision
---@field level string       DEBUG|INFO|WARN|ERROR
---@field module string      Which module produced this
---@field message string     Human-readable message
---@field data table|nil     Structured metadata

local function ring_add(entry)
  ring_seq = ring_seq + 1
  entry.seq = ring_seq
  entry.time = os.time()

  ring[ring_head] = entry
  ring_head = (ring_head % config.ring_size) + 1
  if ring_count < config.ring_size then
    ring_count = ring_count + 1
  end
end

-- ============================================================================
-- File Sink
-- ============================================================================

local file_handle = nil
local file_path = nil
local file_bytes_written = 0

local function ensure_file_path()
  if file_path then return file_path end
  local data_dir = vim.fn.stdpath("data") .. "/xaster/logs"
  vim.fn.mkdir(data_dir, "p")
  file_path = data_dir .. "/xaster.log"
  return file_path
end

local function rotate_if_needed()
  if not file_handle then return end
  if file_bytes_written < config.file_max_size_mb * 1024 * 1024 then return end

  -- Close current, rename to .1, open new
  file_handle:close()
  local rotated = file_path .. "." .. os.date("%Y%m%d-%H%M%S")
  os.rename(file_path, rotated)
  file_handle = nil
  file_bytes_written = 0
end

local function file_write(entry)
  if not config.file_enabled then return end
  if not file_handle then
    local path = ensure_file_path()
    local ok, err = pcall(vim.loop.fs_open, path, "a", 438) -- 0666
    if not ok then
      file_handle = nil
      return
    end
    file_handle = err
  end

  rotate_if_needed()
  if not file_handle then return end

  -- Safe JSON serialization (no vim.fn.json_encode -- avoid stalling on bad data)
  local serialized
  local ok_s, encoded = pcall(vim.fn.json_encode, {
    seq = entry.seq,
    time = os.date("!%Y-%m-%dT%H:%M:%S", math.floor(entry.time / 1e9)),
    level = entry.level,
    module = entry.module,
    message = entry.message,
    data = entry.data,
  })
  if ok_s then
    serialized = encoded .. "\n"
  else
    -- Fallback: plain text
    serialized = string.format(
      '{"seq":%d,"time":"%s","level":"%s","module":"%s","message":"%s"}\n',
      entry.seq,
      os.date("!%Y-%m-%dT%H:%M:%S"),
      entry.level,
      entry.module,
      (entry.message or ""):gsub('"', '\\"'):gsub("\n", "\\n"):sub(1, 1000)
    )
  end

  pcall(vim.loop.fs_write, file_handle, serialized, 0)
  file_bytes_written = file_bytes_written + #serialized
end

-- ============================================================================
-- vim.notify Sink
-- ============================================================================

-- Only ERROR-level logs surface as user-visible notifications.
-- WARN is internal only (ring buffer + file sink). Most warnings
-- are harmless operational details, not actionable for the user.
local NOTIFY_LEVELS = {
  ERROR = vim.log.levels.ERROR,
}

local function notify(entry)
  if not config.notify_enabled then return end
  local vlevel = NOTIFY_LEVELS[entry.level]
  if not vlevel then return end

  local msg = string.format("[xaster/%s] %s", entry.module, entry.message)
  if entry.data then
    local ok_d, data_str = pcall(vim.inspect, entry.data)
    if ok_d then
      msg = msg .. " " .. data_str:gsub("\n", " "):sub(1, 200)
    end
  end
  vim.schedule(function()
    vim.notify(msg, vlevel)
  end)
end

-- ============================================================================
-- Core emit
-- ============================================================================

--- Emit a log entry to all configured sinks.
---@param level string
---@param module_name string
---@param message string
---@param data table|nil
local function emit(level, module_name, message, data)
  if not level_met(level) then return end

  local entry = {
    level = level,
    module = module_name,
    message = message,
    data = data,
  }

  ring_add(entry)

  -- File sink runs in the main loop via schedule
  vim.schedule(function()
    file_write(entry)
  end)

  -- Notify only for errors (WARN is silent — too noisy for user-facing)
  if level == "ERROR" then
    notify(entry)
  end
end

-- ============================================================================
-- Module Logger Factory
-- ============================================================================

--- Create a logger namespaced to a module.
--- Returns a table with debug/info/warn/error methods.
--- Each method accepts (message: string, data?: table).
---@param module_name string
---@return table logger
function M.for_module(module_name)
  return {
    debug = function(msg, data) emit("DEBUG", module_name, msg, data) end,
    info  = function(msg, data) emit("INFO",  module_name, msg, data) end,
    warn  = function(msg, data) emit("WARN",  module_name, msg, data) end,
    error = function(msg, data) emit("ERROR", module_name, msg, data) end,
  }
end

-- ============================================================================
-- Query API (for Agent introspection)
-- ============================================================================

--- Dump recent log entries as a string.
---@param opts table|nil  { n: integer, level: string, module: string, since: number }
---@return string
function M.dump(opts)
  opts = opts or {}
  local n = opts.n or 100
  local filter_level = opts.level
  local filter_module = opts.module
  local since = opts.since

  local entries = {}
  -- Collect entries in chronological order from ring buffer
  -- ring_head points to next write position (1-indexed)
  -- entries are at (ring_head - ring_count) through (ring_head - 1)
  for i = 1, ring_count do
    local idx = ((ring_head - ring_count + i - 2) % config.ring_size) + 1
    local entry = ring[idx]
    if entry then
      -- Apply filters
      if filter_level and LEVELS[entry.level] < (LEVELS[filter_level] or 0) then
        goto continue
      end
      if filter_module and entry.module ~= filter_module then
        goto continue
      end
      if since and entry.time < since then
        goto continue
      end
      entries[#entries + 1] = entry
      ::continue::
    end
  end

  -- Take last N
  if #entries > n then
    local start = #entries - n + 1
    local trimmed = {}
    for i = start, #entries do
      trimmed[#trimmed + 1] = entries[i]
    end
    entries = trimmed
  end

  -- Format
  local lines = { string.format("xaster log (last %d of %d entries)", #entries, ring_count) }
  for _, e in ipairs(entries) do
    local ts = os.date("%H:%M:%S", math.floor(e.time / 1e9))
    local data_str = ""
    if e.data then
      local ok_d, d = pcall(vim.fn.json_encode, e.data)
      if ok_d then data_str = " " .. d:sub(1, 200) end
    end
    lines[#lines + 1] = string.format("[%s] %-5s %-12s %s%s",
      ts, e.level, e.module, e.message, data_str)
  end
  return table.concat(lines, "\n")
end

--- Full state snapshot for state.observe and RPC.
---@return table
function M.observe()
  return {
    total_entries = ring_count,
    ring_size = config.ring_size,
    sequence = ring_seq,
    file_enabled = config.file_enabled,
    file_path = file_path,
    file_bytes = file_bytes_written,
  }
end

-- ============================================================================
-- Configuration
-- ============================================================================

--- Setup logging with user configuration.
---@param opts table|nil  { level, ring_size, file_enabled, file_path, file_max_size_mb, notify_enabled }
function M.setup(opts)
  if not opts then return end
  if opts.level then config.level = opts.level end
  if opts.ring_size then config.ring_size = math.max(100, math.min(10000, opts.ring_size)) end
  if opts.file_enabled ~= nil then config.file_enabled = opts.file_enabled end
  if opts.file_path then config.file_path = opts.file_path end
  if opts.file_max_size_mb then config.file_max_size_mb = opts.file_max_size_mb end
  if opts.notify_enabled ~= nil then config.notify_enabled = opts.notify_enabled end

  -- If file was just enabled, open it
  if config.file_enabled and not file_handle then
    ensure_file_path()
  end
end

--- Cleanup on exit.
function M.cleanup()
  if file_handle then
    pcall(vim.loop.fs_close, file_handle)
    file_handle = nil
  end
end

return M
