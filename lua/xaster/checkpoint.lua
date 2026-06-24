--- xaster/checkpoint.lua
--- ============================================================================
--- Checkpoint and Restore -- survive crashes, recover interrupted sessions.
--- ============================================================================
--- After every N rounds (default: 3), the agent loop saves its state to disk.
--- If Neovim crashes or the agent is killed mid-task, the user can restore
--- the last checkpoint with :XasterRestoreLast.
---
--- Checkpoints are stored in:
---   ~/.local/share/nvim/xaster/checkpoints/
---
--- Each checkpoint is a JSON file with:
---   - messages (conversation history, last 20 rounds)
---   - memory (working memory store)
---   - tasks (task progress)
---   - files_modified (files changed in this session)
---   - round, timestamp, model
---
--- Keeps the last 5 checkpoints, deletes older ones.
--- ============================================================================

local M = {}

local log = require("xaster.log").for_module("checkpoint")
local compat = require("xaster.compat")

-- ============================================================================
-- Configuration
-- ============================================================================

local config = {
  max_checkpoints = 5,
  max_file_size = 1024 * 1024,  -- 1MB per checkpoint
}

-- ============================================================================
-- Path Management
-- ============================================================================

local function get_checkpoint_dir()
  local dir = vim.fn.stdpath("data") .. "/xaster/checkpoints"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function get_checkpoint_path(timestamp)
  return get_checkpoint_dir() .. "/checkpoint_" .. tostring(timestamp) .. ".json"
end

--- List all checkpoint files sorted by time (newest first).
---@return string[] paths
local function list_checkpoints()
  local dir = get_checkpoint_dir()
  local files = {}
  -- Use libuv scandir (works in headless mode, unlike vim.fn.glob)
  -- fs_scandir returns (req, err) -- err is nil on success
  local req, err = vim.loop.fs_scandir(dir)
  if err or not req then return files end
  while true do
    local name, entry_type = vim.loop.fs_scandir_next(req)
    if not name then break end
    if entry_type == "file" and name:match("^checkpoint_%d+%.json$") then
      files[#files + 1] = dir .. "/" .. name
    end
  end
  -- Sort by timestamp in filename (descending)
  table.sort(files, function(a, b)
    local ta = a:match("checkpoint_(%d+)%.json$")
    local tb = b:match("checkpoint_(%d+)%.json$")
    return (tonumber(ta) or 0) > (tonumber(tb) or 0)
  end)
  return files
end

--- Delete the oldest checkpoints exceeding max_checkpoints.
local function prune_old_checkpoints()
  local files = list_checkpoints()
  for i = config.max_checkpoints + 1, #files do
    local ok, err = os.remove(files[i])
    if ok then
      log.info("pruned old checkpoint", { file = files[i] })
    else
      -- Harmless: file may already be gone, or permissions changed.
      -- Not actionable for the user.
      log.info("could not prune checkpoint (non-critical)", { file = files[i] })
    end
  end
end

-- ============================================================================
-- Save
-- ============================================================================

--- Save the current agent state to a checkpoint file.
---@param state table  { round, messages, compressed_count, [files_modified] }
---@return string|nil checkpoint_path
---@return string|nil error_message
function M.save(state)
  if not state then
    return nil, "no state to save"
  end

  local timestamp = os.time()
  local path = get_checkpoint_path(timestamp)

  -- Capture current working memory + task state
  local ok_mem, memory = pcall(require, "xaster.memory")
  local memory_state = {}
  local task_state = {}

  if ok_mem then
    local obs = memory.observe()
    -- Collect fast memory entries
    local fast_entries = obs.entries or {}
    -- Also collect slow memory entries (project conventions, patterns, strategies)
    local slow_entries = {}
    if obs.slow and obs.slow.entries then
      for _, e in ipairs(obs.slow.entries) do
        slow_entries[#slow_entries + 1] = { key = e.key, value = e.value, type = e.type, confidence = e.confidence }
      end
    end
    memory_state = { fast = fast_entries, slow = slow_entries }

    local progress = memory.task_progress()
    task_state = progress
  end

  -- Capture list of modified files
  local files_modified = state.files_modified or {}
  if #files_modified == 0 then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local modified = vim.api.nvim_get_option_value("modified", { buf = buf })
        if modified then
          local name = vim.api.nvim_buf_get_name(buf)
          if name ~= "" then
            files_modified[#files_modified + 1] = name
          end
        end
      end
    end
  end

  -- Truncate messages to last 20 rounds if too large
  local messages_to_save = state.messages or {}
  local truncated = false

  if #messages_to_save > 40 then
    -- Keep first user message + last 38 messages (~19 rounds)
    local first_user = nil
    for i = 1, math.min(5, #messages_to_save) do
      if messages_to_save[i].role == "user" then
        first_user = i
        break
      end
    end
    local keep = math.min(38, #messages_to_save)
    local range_start = #messages_to_save - keep + 1
    local new_msgs = {}
    -- Only prepend first_user if it is not already within the last-38 range
    if first_user and first_user < range_start then
      new_msgs[#new_msgs + 1] = messages_to_save[first_user]
    end
    for i = range_start, #messages_to_save do
      new_msgs[#new_msgs + 1] = messages_to_save[i]
    end
    messages_to_save = new_msgs
    truncated = true
  end

  -- Build checkpoint
  local checkpoint = {
    version = 2,
    timestamp = timestamp,
    round = state.round or 0,
    compressed_count = state.compressed_count or 0,
    messages_truncated = truncated,
    messages = messages_to_save,
    memory = memory_state,
    tasks = task_state,
    files_modified = files_modified,
    model = (function()
      local ok_llm, llm = pcall(require, "xaster.llm")
      if ok_llm then return llm.get_model() end
      return "unknown"
    end)(),
    cwd = vim.fn.getcwd(),
  }

  -- Sanitize all strings before serialization (tool results may carry
  -- binary data from bash/file reads that crash vim.fn.json_encode).
  compat.sanitize_table_utf8(checkpoint)

  -- Serialize with pcall + retry
  local ok_json, json_str = pcall(vim.fn.json_encode, checkpoint)
  if not ok_json then
    log.warn("checkpoint json_encode failed, re-sanitizing", { error = tostring(json_str) })
    compat.sanitize_table_utf8(checkpoint)
    ok_json, json_str = pcall(vim.fn.json_encode, checkpoint)
    if not ok_json then
      log.error("failed to serialize checkpoint after retry", { error = tostring(json_str) })
      return nil, "failed to serialize checkpoint: " .. tostring(json_str)
    end
  end

  -- Truncate if too large
  if #json_str > config.max_file_size then
    -- Aggressively truncate messages
    checkpoint.messages = {
      { role = "user", content = "[Original context truncated -- checkpoint too large]" },
      checkpoint.messages[#checkpoint.messages] or { role = "assistant", content = "" },
    }
    checkpoint.messages_truncated = true
    local ok2, json2 = pcall(vim.fn.json_encode, checkpoint)
    if ok2 then json_str = json2 end
  end

  -- Ensure valid UTF-8 before writing (tool results may contain binary data)
  json_str = compat.sanitize_utf8(json_str)

  -- Write to file
  local file, err = io.open(path, "w")
  if not file then
    log.error("failed to open checkpoint file", { path = path, error = err })
    return nil, "failed to write checkpoint: " .. (err or "unknown")
  end

  file:write(json_str)
  file:close()

  -- Prune old
  vim.schedule(prune_old_checkpoints)

  log.info("checkpoint saved", {
    path = path,
    round = state.round,
    size = #json_str,
    truncated = truncated,
  })

  return path
end

-- ============================================================================
-- Load and Restore
-- ============================================================================

--- Load a checkpoint from a file path.
---@param path string
---@return table|nil checkpoint
---@return string|nil error_message
function M.load(path)
  if not path or path == "" then
    return nil, "no checkpoint path provided"
  end

  local file, err = io.open(path, "r")
  if not file then
    return nil, "failed to open checkpoint: " .. (err or "unknown")
  end

  local content = file:read("*a")
  file:close()

  local ok, checkpoint = pcall(vim.fn.json_decode, content)
  if not ok or not checkpoint then
    return nil, "failed to parse checkpoint JSON"
  end

  if type(checkpoint) ~= "table" then
    return nil, "invalid checkpoint format"
  end

  log.info("checkpoint loaded", {
    path = path,
    round = checkpoint.round or 0,
    version = checkpoint.version,
  })

  return checkpoint
end

--- Get the path to the most recent checkpoint.
---@return string|nil
function M.get_last_path()
  local files = list_checkpoints()
  if #files == 0 then return nil end
  return files[1]
end

--- Load the most recent checkpoint.
---@return table|nil checkpoint
---@return string|nil path
function M.load_last()
  local path = M.get_last_path()
  if not path then
    return nil, nil
  end
  local ck, err = M.load(path)
  return ck, path
end

--- Restore agent state from a checkpoint.
--- Clears current state and loads the checkpoint.
---@param checkpoint table
---@return boolean ok
---@return string|nil error_message
function M.restore(checkpoint)
  if not checkpoint then
    return false, "no checkpoint to restore"
  end

  -- Restore working memory (both fast and slow layers)
  local ok_mem, memory = pcall(require, "xaster.memory")
  if ok_mem and checkpoint.memory then
    memory.clear()
    -- Restore fast memory (TTL-based scratchpad)
    local fast = checkpoint.memory.fast or checkpoint.memory  -- backward compat
    if fast and not fast.fast then  -- old format: flat array
      for _, entry in ipairs(fast) do
        if entry.key and entry.value ~= nil then
          memory.remember(entry.key, entry.value, { source = "checkpoint_restore" })
        end
      end
    else
      for _, entry in ipairs(fast.fast or fast) do
        if entry.key and entry.value ~= nil then
          memory.remember(entry.key, entry.value, { source = "checkpoint_restore" })
        end
      end
    end
    -- Restore slow memory (confidence-scored knowledge)
    local slow = checkpoint.memory.slow
    if slow then
      for _, entry in ipairs(slow) do
        if entry.key and entry.value ~= nil then
          memory.learn(entry.type or "fact", entry.key, entry.value, entry.tags, entry.confidence)
        end
      end
    end
  end

  -- Restore tasks
  if ok_mem and checkpoint.tasks and checkpoint.tasks.tasks then
    memory.tasks_init(checkpoint.tasks.tasks)
    -- Restore task statuses
    for _, t in ipairs(checkpoint.tasks.tasks) do
      if t.status and t.status ~= "pending" then
        memory.task_update(t.id, t.status)
      end
    end
  end

  -- Restore messages to agent
  local ok_agent, agent = pcall(require, "xaster.agent")
  if ok_agent then
    -- Clear current state first
    agent.clear_history()

    -- The agent's messages are set internally; we provide a restore method:
    -- (The agent module exposes a _restore_state for this purpose)
    if agent._restore_state then
      agent._restore_state({
        messages = checkpoint.messages or {},
        round = checkpoint.round or 0,
        compressed_count = checkpoint.compressed_count or 0,
      })
    end
  end

  -- Notify user about restored files
  if checkpoint.files_modified and #checkpoint.files_modified > 0 then
    vim.schedule(function()
      vim.notify(
        string.format("[xaster] Checkpoint restored. %d files were modified in the previous session: %s",
          #checkpoint.files_modified,
          table.concat(vim.tbl_map(function(f) return f:match("[^/]+$") or f end, checkpoint.files_modified), ", ")
        ),
        vim.log.levels.INFO
      )
    end)
  end

  log.info("checkpoint restored", {
    round = checkpoint.round,
    messages = #(checkpoint.messages or {}),
    memory = #(checkpoint.memory or {}),
    tasks = checkpoint.tasks and checkpoint.tasks.total or 0,
  })

  return true
end

-- ============================================================================
-- List & Info
-- ============================================================================

--- Get metadata about all available checkpoints.
---@return table[] checkpoints_info
function M.list()
  local files = list_checkpoints()
  local result = {}

  for _, path in ipairs(files) do
    local info = {
      path = path,
      timestamp = tonumber(path:match("checkpoint_(%d+)%.json$") or "0"),
      size = 0,
      round = 0,
      model = "unknown",
    }

    -- Get file size
    local stat = vim.loop.fs_stat(path)
    if stat then
      info.size = stat.size
    end

    -- Quick scan for round/model (don't fully parse)
    local file, err = io.open(path, "r")
    if file then
      local first_line = file:read("*l")
      file:close()
      if first_line then
        info.round = tonumber(first_line:match('"round":(%d+)')) or 0
        info.model = first_line:match('"model":"([^"]+)"') or "unknown"
      end
    end

    result[#result + 1] = info
  end

  return result
end

-- ============================================================================
-- Cleanup
-- ============================================================================

--- Delete all checkpoints.
---@return integer deleted_count
function M.clear_all()
  local files = list_checkpoints()
  local count = 0
  for _, path in ipairs(files) do
    local ok = os.remove(path)
    if ok then count = count + 1 end
  end
  log.info("all checkpoints cleared", { count = count })
  return count
end

function M.cleanup()
  -- On normal exit, optionally save one last checkpoint
  -- (called by init.lua VimLeavePre)
  -- We don't auto-save on normal exit -- that's the agent loop's job
end

return M
