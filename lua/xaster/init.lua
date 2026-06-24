local compat = require("xaster.compat")
--- xaster/init.lua
--- Plugin entry point. Exposes setup(), user commands, and keymaps.
---
--- Setup with lazy.nvim:
---   { "yourname/xaster.nvim", opts = { agent = { model = "claude-sonnet-4-20250514" } } }
---
--- Manual setup:
---   require("xaster").setup({ agent = { api_key = "sk-ant-..." } })

local ui = require("xaster.ui")
local editor = require("xaster.editor")
local tools = require("xaster.tools")

local M = {}

-- Plugin configuration with defaults
M.config = {
  agent = {
    api_key = "",
    model = "claude-sonnet-4-20250514",
    max_tokens = 8192,
    api_url = "https://api.anthropic.com/v1/messages",
    max_rounds = 1024,
    timeout_sec = 300,          -- per-request timeout
    max_retries = 3,            -- retry count for transient errors
    retry_delays = { 1, 4, 15 }, -- retry delay seconds
    ultracode = true,            -- exhaustive mode: deeper analysis, more thorough execution
  },
  chat = {
    height_ratio = 0.35,
    min_chat_height = 8,
    cmd_height = 8,             -- height of the tool status command box
    max_messages = 500,         -- soft cap before folding old messages
  },
  ui = {
    action = { enabled = true },
    toast = { enabled = true },
    statusline = { enabled = true },
    highlights = { enabled = true },
  },
  vcursor = {
    mode = "line",
    auto_hide_ms = 0,
    flash_duration_ms = 400,
    show_label = false,
  },
  history = {
    max_entries = 1000,
  },
  lock = {
    auto_lock_new_buffers = true,
    block_insert = true,
  },
  file_sync = {
    enabled = true,
    check_interval_ms = 2000,
    auto_reload = true,
  },
  log = {
    level = "INFO",              -- DEBUG | INFO | WARN | ERROR
    ring_size = 2000,            -- log entries in memory
    file_enabled = false,        -- set true for persistent logs
    notify_enabled = true,       -- vim.notify for WARN+ERROR
  },
  checkpoint = {
    max_checkpoints = 5,
    auto_save_on_exit = true,    -- save checkpoint on VimLeave
  },
  keymaps = {
    chat_toggle = "<leader>ac",
    agent_stop = "<leader>as",
    observe = "<leader>xo",
    history = "<leader>xh",
    action = "<leader>xa",
  },
}

-- ============================================================================
-- User Commands
-- ============================================================================

local function create_commands()
  -- -- Chat --------------------------------------------------------------
  vim.api.nvim_create_user_command("XasterChat", function()
    local chat = require("xaster.chat")
    chat.toggle()
  end, { nargs = 0, desc = "Toggle the xaster Agent chat panel" })

  vim.api.nvim_create_user_command("XasterChatOpen", function()
    local chat = require("xaster.chat")
    chat.open()
  end, { nargs = 0, desc = "Open the xaster Agent chat panel" })

  vim.api.nvim_create_user_command("XasterChatClose", function()
    local chat = require("xaster.chat")
    chat.close()
  end, { nargs = 0, desc = "Close the xaster Agent chat panel" })

  -- -- Agent control -----------------------------------------------------
  vim.api.nvim_create_user_command("XasterAgentStop", function()
    local agent = require("xaster.agent")
    agent.stop()
  end, { nargs = 0, desc = "Stop the currently running Agent request" })

  vim.api.nvim_create_user_command("XasterAgentClear", function()
    local agent = require("xaster.agent")
    agent.clear_history()
    vim.notify("[xaster] Conversation history cleared", vim.log.levels.INFO)
  end, { nargs = 0, desc = "Clear the Agent conversation history" })

  vim.api.nvim_create_user_command("XasterUltracode", function(args)
    local agent = require("xaster.agent")
    local state
    if args.args == "on" or args.args == "1" then
      state = agent.ultracode(true)
    elseif args.args == "off" or args.args == "0" then
      state = agent.ultracode(false)
    else
      state = agent.ultracode(nil)  -- toggle
    end
    local label = state and "ON (exhaustive)" or "OFF (normal)"
    vim.notify("[xaster] Ultracode " .. label, state and vim.log.levels.WARN or vim.log.levels.INFO)
  end, { nargs = "?", desc = "Toggle ultracode exhaustive mode: XasterUltracode [on|off]" })

  -- -- Phase ----------------------------------------------------------------
  vim.api.nvim_create_user_command("XasterPhase", function(args)
    local agent = require("xaster.agent")
    local phases = { "explore", "plan", "execute", "verify" }
    local target = args.args and args.args:lower()
    if target and vim.tbl_contains(phases, target) then
      agent.set_phase(target)
      vim.notify("[xaster] Phase -> " .. target:upper(), vim.log.levels.INFO)
    else
      local current = agent.get_phase()
      local labels = {}
      for _, p in ipairs(phases) do
        local marker = p == current and " [CURRENT]" or ""
        labels[#labels + 1] = "  " .. p:upper() .. marker
      end
      vim.notify("[xaster] Current phase: " .. current:upper() .. "\n" .. table.concat(labels, "\n"), vim.log.levels.INFO)
    end
  end, { nargs = "?", desc = "Show or set the agent phase. XasterPhase [explore|plan|execute|verify]" })

  -- -- Observe -----------------------------------------------------------
  vim.api.nvim_create_user_command("XasterObserve", function()
    local snapshot = editor.observe()
    local encoded = vim.fn.json_encode(snapshot)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(encoded, "\n"))
    vim.api.nvim_buf_set_option(buf, "filetype", "json")
    vim.api.nvim_set_current_buf(buf)
    vim.notify("[xaster] Full state snapshot loaded", vim.log.levels.INFO)
  end, { nargs = 0, desc = "Take a full editor state snapshot and show as JSON" })

  -- -- Tools -------------------------------------------------------------
  vim.api.nvim_create_user_command("XasterTools", function()
    local all_tools = tools.list()
    local lines = { "xaster Tools (" .. compat.tbl_count(all_tools) .. " total)", "==================", "" }
    for _, tool in ipairs(all_tools) do
      table.insert(lines, "  " .. tool.name)
      if tool.description then
        local desc = tool.description:gsub("\n", " ")
        while #desc > 0 do
          local chunk = desc:sub(1, 60)
          desc = desc:sub(61)
          table.insert(lines, "    " .. chunk)
        end
      end
      table.insert(lines, "")
    end
    ui.show_large_float("xaster Tools", lines, { width_ratio = 0.5, height_ratio = 0.7, filetype = "markdown" })
  end, { nargs = 0, desc = "List all available xaster Agent tools" })

  -- -- Toast -------------------------------------------------------------
  vim.api.nvim_create_user_command("XasterToast", function(args)
    ui.toast(args.args or "Hello from xaster!")
  end, { nargs = "?", desc = "Show a test toast notification" })

  -- -- History -----------------------------------------------------------
  vim.api.nvim_create_user_command("XasterHistory", function(args)
    local ok_hist, history = pcall(require, "xaster.history")
    if not ok_hist then
      vim.notify("[xaster] History module not available", vim.log.levels.ERROR)
      return
    end
    local n = tonumber(args.args) or 30
    local entries = history.list({ n = n })
    local lines = {
      "xaster Operation History (last " .. #entries .. " of " .. history.observe().total_entries .. " total)",
      "============================", "",
    }
    for _, entry in ipairs(entries) do
      local time_str = os.date("%H:%M:%S", entry.time)
      local status_icon = entry.ok and "OK" or "XX"
      table.insert(lines, string.format("  [%s] %s %s  (%dms)",
        time_str, status_icon, entry.tool, entry.elapsed_ms or 0))
      if entry.filename then
        table.insert(lines, "    -> " .. entry.filename)
      end
      if not entry.ok and entry.error then
        table.insert(lines, "    XX " .. tostring(entry.error.message or entry.error))
      end
    end
    ui.show_large_float("xaster History", lines, { width_ratio = 0.6, height_ratio = 0.8, filetype = "markdown" })
  end, { nargs = "?", desc = "Show xaster operation history. Optionally specify count: XasterHistory 50" })

  vim.api.nvim_create_user_command("XasterHistoryClear", function()
    local ok_hist, history = pcall(require, "xaster.history")
    if ok_hist then
      local count = history.clear()
      vim.notify("[xaster] Cleared " .. count .. " history entries", vim.log.levels.INFO)
    end
  end, { nargs = 0, desc = "Clear all xaster operation history" })

  -- -- Lock --------------------------------------------------------------
  vim.api.nvim_create_user_command("XasterLock", function()
    local ok_lock, lock = pcall(require, "xaster.lock")
    if not ok_lock then
      vim.notify("[xaster] Lock module not available", vim.log.levels.ERROR)
      return
    end
    local result = lock.enable({ by = "user" })
    if result.ok then
      vim.notify("[xaster] Editor locked -- Agent has exclusive edit access", vim.log.levels.INFO)
    end
  end, { nargs = 0, desc = "Lock the editor: Agent has exclusive edit access" })

  vim.api.nvim_create_user_command("XasterUnlock", function()
    local ok_lock, lock = pcall(require, "xaster.lock")
    if not ok_lock then
      vim.notify("[xaster] Lock module not available", vim.log.levels.ERROR)
      return
    end
    local result = lock.disable()
    if result.ok then
      vim.notify("[xaster] Editor unlocked -- user can edit again", vim.log.levels.INFO)
    end
  end, { nargs = 0, desc = "Unlock the editor: restore normal user edit access" })

  -- -- File sync ---------------------------------------------------------
  vim.api.nvim_create_user_command("XasterSync", function(args)
    if args.args == "off" then
      local augroup = vim.api.nvim_create_augroup("xaster_file_sync", {})
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
      vim.notify("[xaster] File sync disabled", vim.log.levels.INFO)
    else
      editor.file_sync_setup({
        checktime_interval_ms = M.config.file_sync.check_interval_ms or 2000,
        auto_reload = true,
      })
      vim.notify("[xaster] File sync enabled", vim.log.levels.INFO)
    end
  end, { nargs = "?", desc = "Toggle file sync: XasterSync [off]" })

  -- -- Checkpoint --------------------------------------------------------
  vim.api.nvim_create_user_command("XasterCheckpoints", function()
    local ok_cp, checkpoint = pcall(require, "xaster.checkpoint")
    if not ok_cp then
      vim.notify("[xaster] Checkpoint module not available", vim.log.levels.ERROR)
      return
    end
    local cps = checkpoint.list()
    local lines = { "xaster Checkpoints (" .. #cps .. " available)", "======================", "" }
    if #cps == 0 then
      lines[#lines + 1] = "  (no checkpoints found)"
    else
      for i, cp in ipairs(cps) do
        local time_str = os.date("%Y-%m-%d %H:%M:%S", cp.timestamp)
        local size_kb = math.floor(cp.size / 1024)
        table.insert(lines, string.format("  %d. %s  Round %d  %d KB  %s",
          i, time_str, cp.round, size_kb, cp.model))
      end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Use :XasterRestoreLast to restore the most recent checkpoint."
    ui.show_large_float("xaster Checkpoints", lines, { width_ratio = 0.6, height_ratio = 0.6, filetype = "markdown" })
  end, { nargs = 0, desc = "List available checkpoints" })

  vim.api.nvim_create_user_command("XasterRestoreLast", function()
    local ok_cp, checkpoint = pcall(require, "xaster.checkpoint")
    if not ok_cp then
      vim.notify("[xaster] Checkpoint module not available", vim.log.levels.ERROR)
      return
    end
    local ck, path = checkpoint.load_last()
    if not ck then
      vim.notify("[xaster] No checkpoints found", vim.log.levels.WARN)
      return
    end
    local ok, err = checkpoint.restore(ck)
    if ok then
      vim.notify(string.format("[xaster] Checkpoint restored (round %d, %s)",
        ck.round or 0, os.date("%Y-%m-%d %H:%M:%S", ck.timestamp)), vim.log.levels.INFO)
    else
      vim.notify("[xaster] Failed to restore checkpoint: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
  end, { nargs = 0, desc = "Restore the most recent checkpoint" })

  vim.api.nvim_create_user_command("XasterCheckpointClear", function()
    local ok_cp, checkpoint = pcall(require, "xaster.checkpoint")
    if not ok_cp then
      vim.notify("[xaster] Checkpoint module not available", vim.log.levels.ERROR)
      return
    end
    local count = checkpoint.clear_all()
    vim.notify("[xaster] Deleted " .. count .. " checkpoints", vim.log.levels.INFO)
  end, { nargs = 0, desc = "Delete all checkpoints" })

  -- -- Log ---------------------------------------------------------------
  vim.api.nvim_create_user_command("XasterLog", function(args)
    local ok_log, log_mod = pcall(require, "xaster.log")
    if not ok_log then
      vim.notify("[xaster] Log module not available", vim.log.levels.ERROR)
      return
    end
    local n = tonumber(args.args) or 50
    local dump = log_mod.dump({ n = n })
    local lines = vim.split(dump, "\n")
    ui.show_large_float("xaster Log", lines, { width_ratio = 0.7, height_ratio = 0.8, filetype = "markdown" })
  end, { nargs = "?", desc = "Show xaster internal log. Optionally specify count: XasterLog 100" })

  -- -- Agent status ------------------------------------------------------
  vim.api.nvim_create_user_command("XasterStatus", function()
    local ok_agent, agent = pcall(require, "xaster.agent")
    local ok_llm, llm_mod = pcall(require, "xaster.llm")
    local ok_log, log_mod = pcall(require, "xaster.log")

    local lines = { "# xaster Status", "" }

    if ok_llm then
      local llm_obs = llm_mod.observe()
      lines[#lines + 1] = "## LLM"
      lines[#lines + 1] = string.format("- Configured: %s", llm_obs.configured and "yes" or "no")
      lines[#lines + 1] = string.format("- Model: %s", llm_obs.model)
      lines[#lines + 1] = string.format("- Provider: %s (native tools: %s, streaming: %s)",
        llm_obs.provider, tostring(llm_obs.native_tools), tostring(llm_obs.streaming))
      lines[#lines + 1] = string.format("- Context limit: %d tokens", llm_obs.context_limit)
      lines[#lines + 1] = string.format("- Timeout: %ds, max retries: %d", llm_obs.timeout_sec, llm_obs.max_retries)
      lines[#lines + 1] = ""
    end

    if ok_agent then
      local agent_obs = agent.observe()
      lines[#lines + 1] = "## Agent"
      lines[#lines + 1] = string.format("- Running: %s", agent_obs.running and "yes" or "no")
      lines[#lines + 1] = string.format("- Phase: %s", agent_obs.phase and agent_obs.phase:upper() or "?")
      lines[#lines + 1] = string.format("- Round: %d/%d", agent_obs.round, agent_obs.max_rounds)
      lines[#lines + 1] = string.format("- Messages: %d", agent_obs.messages_count)
      lines[#lines + 1] = string.format("- Compressed: %d rounds", agent_obs.compressed_count)
      lines[#lines + 1] = string.format("- Est. tokens: %d / %d", agent_obs.est_tokens, agent_obs.token_limit)

      local broken = {}
      for tool, state in pairs(agent_obs.circuit_state or {}) do
        local failures = type(state) == "table" and (state.failures or 0) or (state or 0)
        if failures > 0 then
          broken[#broken + 1] = string.format("%s (%d failures)", tool, failures)
        end
      end
      if #broken > 0 then
        lines[#lines + 1] = string.format("- Circuit breakers: %s", table.concat(broken, ", "))
      end
      lines[#lines + 1] = ""
    end

    if ok_log then
      local log_obs = log_mod.observe()
      lines[#lines + 1] = "## Log"
      lines[#lines + 1] = string.format("- Entries: %d (ring size %d)", log_obs.total_entries, log_obs.ring_size)
      lines[#lines + 1] = string.format("- File logging: %s", log_obs.file_enabled and "enabled" or "disabled")
      lines[#lines + 1] = ""
    end

    ui.show_large_float("xaster Status", lines, { width_ratio = 0.5, height_ratio = 0.6, filetype = "markdown" })
  end, { nargs = 0, desc = "Show comprehensive xaster status" })
end

-- ============================================================================
-- Keymaps
-- ============================================================================

local function create_keymaps()
  local km = M.config.keymaps

  if km.chat_toggle then
    vim.keymap.set("n", km.chat_toggle, "<cmd>XasterChat<cr>",
      { desc = "Toggle xaster Agent chat", silent = true })
  end

  if km.agent_stop then
    vim.keymap.set("n", km.agent_stop, "<cmd>XasterAgentStop<cr>",
      { desc = "Stop xaster Agent", silent = true })
  end

  if km.observe then
    vim.keymap.set("n", km.observe, "<cmd>XasterObserve<cr>",
      { desc = "Xaster observe (state snapshot)", silent = true })
  end

  if km.history then
    vim.keymap.set("n", km.history, "<cmd>XasterHistory<cr>",
      { desc = "Xaster history", silent = true })
  end

  if km.action then
    vim.keymap.set("n", km.action, function()
      if ui.action_win then
        ui.action_hide()
      else
        ui.action_show("Agent is standing by...")
      end
    end, { desc = "Toggle xaster action indicator", silent = true })
  end
end

-- ============================================================================
-- Autocommands
-- ============================================================================

local function create_autocommands()
  vim.api.nvim_create_augroup("xaster_plugin", { clear = true })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = "xaster_plugin",
    callback = function()
      -- Save checkpoint if agent was running
      if M.config.checkpoint and M.config.checkpoint.auto_save_on_exit then
        local ok_agent, agent = pcall(require, "xaster.agent")
        if ok_agent and agent.is_running() then
          local ok_cp, checkpoint = pcall(require, "xaster.checkpoint")
          if ok_cp then
            local obs = agent.observe()
            checkpoint.save({
              round = obs.round,
              messages = {},  -- agent's internal messages aren't exposed directly
              compressed_count = obs.compressed_count,
            })
          end
        end
      end

      -- Cleanup
      local ok_agent, agent = pcall(require, "xaster.agent")
      if ok_agent then agent.cleanup() end
      local ok_chat, chat = pcall(require, "xaster.chat")
      if ok_chat then chat.cleanup() end
      local ok_log, log_mod = pcall(require, "xaster.log")
      if ok_log then log_mod.cleanup() end
      ui.cleanup()
    end,
    desc = "xaster: cleanup on exit",
  })

  -- Show notification if checkpoints exist on startup
  vim.api.nvim_create_autocmd("VimEnter", {
    group = "xaster_plugin",
    callback = function()
      local ok_cp, checkpoint = pcall(require, "xaster.checkpoint")
      if ok_cp then
        local cps = checkpoint.list()
        if #cps > 0 then
          vim.schedule(function()
            vim.notify(
              string.format("[xaster] %d checkpoint(s) from previous session. :XasterRestoreLast to recover.", #cps),
              vim.log.levels.INFO
            )
          end)
        end
      end
    end,
    desc = "xaster: notify about existing checkpoints",
    once = true,
  })
end

-- ============================================================================
-- Status Line Integration
-- ============================================================================

function M.statusline()
  return ui.statusline()
end

-- ============================================================================
-- Plugin Setup
-- ============================================================================

--- Initialize the xaster plugin.
---@param opts table|nil  Configuration options (merged with defaults)
function M.setup(opts)
  -- Deep merge user config with defaults
  if opts then
    M.config = compat.tbl_deep_extend("force", M.config, opts)
  end

  -- Check for curl (required for LLM API calls)
  if vim.fn.executable("curl") == 0 then
    vim.notify("[xaster] WARNING: 'curl' not found. LLM API calls will not work. Install curl to use the Agent.", vim.log.levels.WARN)
  end

  -- Check Neovim version (vim.system required)
  if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("[xaster] WARNING: Neovim >= 0.10 required (for vim.system). Some features may not work.", vim.log.levels.WARN)
  end

  -- Initialize structured logging first (other modules depend on it)
  local ok_log, log_mod = pcall(require, "xaster.log")
  if ok_log then
    log_mod.setup(M.config.log or {})
  end

  -- Initialize UI
  ui.setup(M.config)

  -- Configure LLM client
  local ok_llm, llm = pcall(require, "xaster.llm")
  if ok_llm and M.config.agent then
    llm.configure(M.config.agent)
  end

  -- Configure Agent
  local ok_agent, agent = pcall(require, "xaster.agent")
  if ok_agent and M.config.agent then
    agent.configure(M.config.agent)
  end

  -- Configure Chat UI
  local ok_chat, chat = pcall(require, "xaster.chat")
  if ok_chat then
    chat.configure(M.config.chat or {})
    -- Wire up chat submit -> agent
    if ok_agent then
      chat.set_submit_callback(function(text)
        agent.send_message(text)
      end)
    end
  end

  -- Initialize virtual cursor
  local ok_vc, vcursor = pcall(require, "xaster.vcursor")
  if ok_vc then
    vcursor.define_highlights()
    vcursor.update_config(M.config.vcursor or {})
  end

  -- Initialize history
  local ok_hist, history = pcall(require, "xaster.history")
  if ok_hist and M.config.history then
    if M.config.history.max_entries then
      history.set_max_entries(M.config.history.max_entries)
    end
  end

  -- Initialize lock module (passive)
  pcall(require, "xaster.lock")

  -- Initialize checkpoint module (passive)
  pcall(require, "xaster.checkpoint")

  -- Create user commands
  create_commands()

  -- Create keymaps
  create_keymaps()

  -- Create autocommands
  create_autocommands()

  -- File sync
  if M.config.file_sync and M.config.file_sync.enabled then
    editor.file_sync_setup({
      checktime_interval_ms = M.config.file_sync.check_interval_ms or 2000,
      auto_reload = M.config.file_sync.auto_reload ~= false,
    })
  end

  -- Ready notification
  vim.schedule(function()
    local llm_ok, llm_mod = pcall(require, "xaster.llm")
    local key_status = "no API key"
    if llm_ok and llm_mod.is_configured() then
      key_status = llm_mod.get_provider() .. ":" .. (llm_mod.get_model():match("[^/]+$") or llm_mod.get_model())
    end
    vim.notify(
      string.format("[xaster] Ready (%s) -- :XasterChat to open the Agent panel", key_status),
      vim.log.levels.INFO
    )
  end)
end

-- ============================================================================
-- Public API
-- ============================================================================

function M.chat_open()
  local ok, chat = pcall(require, "xaster.chat")
  if ok then chat.open() end
end

function M.chat_close()
  local ok, chat = pcall(require, "xaster.chat")
  if ok then chat.close() end
end

function M.chat_toggle()
  local ok, chat = pcall(require, "xaster.chat")
  if ok then chat.toggle() end
end

function M.send_message(text)
  local ok, agent = pcall(require, "xaster.agent")
  if ok then agent.send_message(text) end
end

function M.stop()
  local ok, agent = pcall(require, "xaster.agent")
  if ok then agent.stop() end
end

function M.observe()
  return editor.observe()
end

function M.get_tools()
  return tools.list()
end

function M.toast(message, level)
  ui.toast(message, level)
end

function M.eval(code)
  local fn, err = load(code)
  if not fn then return nil, err end
  return pcall(fn)
end

return M
