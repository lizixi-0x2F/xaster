--- xaster/llm.lua
--- ============================================================================
--- LLM API client -- OpenAI-compatible function calling + SSE streaming.
--- v3: Pure OpenAI format. No Anthropic, no provider detection, no prompt-based.
--- ============================================================================

local log = require("xaster.log").for_module("llm")
local errors = require("xaster.errors")
local compat = require("xaster.compat")

-- Track the currently active request handle (original or retry).
-- M.stop() kills this regardless of which attempt is in-flight.
local active_job = nil
local active_timer = nil

local M = {}

-- ============================================================================
-- Configuration
-- ============================================================================

local config = {
  api_key = nil,
  api_url = nil,
  model = nil,
  max_tokens = 8192,
  timeout_sec = 300,
  max_retries = 3,
  retry_delays = { 1, 4, 15 },
}

function M.configure(opts)
  if not opts then return end
  if opts.api_key and opts.api_key ~= "" then config.api_key = opts.api_key end
  if opts.model then config.model = opts.model end
  if opts.max_tokens then config.max_tokens = opts.max_tokens end
  if opts.api_url then config.api_url = opts.api_url end
  if opts.timeout_sec then config.timeout_sec = opts.timeout_sec end
  if opts.max_retries then config.max_retries = opts.max_retries end
end

function M.is_configured()
  return M.get_api_key() ~= nil
end

function M.get_api_key()
  if vim.env.ANTHROPIC_AUTH_TOKEN and vim.env.ANTHROPIC_AUTH_TOKEN ~= "" then
    return vim.env.ANTHROPIC_AUTH_TOKEN
  end
  if vim.env.ANTHROPIC_API_KEY and vim.env.ANTHROPIC_API_KEY ~= "" then
    return vim.env.ANTHROPIC_API_KEY
  end
  if config.api_key and config.api_key ~= "" then
    return config.api_key
  end
  return nil
end

function M.get_api_url()
  local base = vim.env.ANTHROPIC_BASE_URL
  if base and base ~= "" then
    base = base:gsub("/+$", "")
    -- If already a chat/completions endpoint, use as-is
    if base:match("/chat/completions$") then return base end
    -- Strip /anthropic or /v1/messages suffix, replace with /v1/chat/completions
    base = base:gsub("/anthropic", ""):gsub("/v1/messages$", "")
    return base .. "/v1/chat/completions"
  end
  if config.api_url and config.api_url ~= "" then
    local url = config.api_url:gsub("/+$", "")
    if url:match("/chat/completions$") then return url end
    url = url:gsub("/anthropic", ""):gsub("/v1/messages$", "")
    return url .. "/v1/chat/completions"
  end
  return "https://api.openai.com/v1/chat/completions"
end

function M.get_model()
  local model = nil
  if vim.env.ANTHROPIC_MODEL and vim.env.ANTHROPIC_MODEL ~= "" then
    model = vim.env.ANTHROPIC_MODEL
  elseif vim.env.ANTHROPIC_DEFAULT_SONNET_MODEL and vim.env.ANTHROPIC_DEFAULT_SONNET_MODEL ~= "" then
    model = vim.env.ANTHROPIC_DEFAULT_SONNET_MODEL
  elseif config.model and config.model ~= "" then
    model = config.model
  end
  -- Strip Claude Code suffixes like "[1m]"
  if model then
    model = model:gsub("%[%d+m%]", ""):gsub("%s+", "")
  end
  return model or "gpt-4"
end

function M.uses_native_tools()
  return true  -- always structured tool calling
end

function M.get_provider()
  return "openai"
end

function M.set_api_key(key)
  config.api_key = key
end

-- ============================================================================
-- Token Counting
-- ============================================================================

function M.estimate_tokens(text)
  if type(text) ~= "string" then return 0 end
  if #text == 0 then return 0 end
  local tokens = 0
  for word in text:gmatch("%S+") do
    tokens = tokens + 1
    local _, punct_count = word:gsub("[%p]", "")
    tokens = tokens + punct_count
    if #word > 10 then tokens = tokens + math.floor((#word - 10) / 10) end
  end
  return math.max(1, math.ceil(tokens * 1.1))
end

function M.count_message_tokens(msg)
  if not msg then return 0 end
  local count = 1
  if type(msg.content) == "string" then
    count = count + M.estimate_tokens(msg.content)
  elseif type(msg.content) == "table" then
    for _, block in ipairs(msg.content) do
      if block.type == "text" then
        count = count + M.estimate_tokens(block.text)
      elseif block.type == "function" then
        count = count + M.estimate_tokens(block["function"].name or "")
        count = count + M.estimate_tokens(block["function"].arguments or "")
      elseif type(block.content) == "string" then
        count = count + M.estimate_tokens(block.content:sub(1, 100000))
      end
    end
  end
  return math.max(1, count)
end

function M.count_context_tokens(messages, system_prompt)
  local total = 0
  if system_prompt then
    if type(system_prompt) == "string" then total = total + M.estimate_tokens(system_prompt)
    elseif type(system_prompt) == "table" then
      for _, b in ipairs(system_prompt) do total = total + M.estimate_tokens(b.text or "") end
    end
  end
  if messages then
    for _, msg in ipairs(messages) do total = total + M.count_message_tokens(msg) end
  end
  return total
end

local MODEL_LIMITS = {
  ["gpt-4"] = 128000, ["gpt-4-turbo"] = 128000, ["gpt-3.5-turbo"] = 16385,
  ["deepseek"] = 128000, ["claude"] = 200000,
}

function M.get_context_limit()
  local model = M.get_model()
  for pattern, limit in pairs(MODEL_LIMITS) do
    if model:find(pattern, 1, true) then return limit end
  end
  return 100000
end

-- ============================================================================
-- Error Classification
-- ============================================================================

local function classify_error(http_status, error_body, curl_exit_code)
  if curl_exit_code and curl_exit_code ~= 0 then
    local msgs = { [6] = "DNS failed", [7] = "Connect failed", [28] = "Timeout", [35] = "TLS failed", [52] = "No response", [56] = "Network error" }
    local msg = msgs[curl_exit_code] or ("curl error " .. curl_exit_code)
    return errors.ErrorCode.NETWORK_ERROR, true, msg
  end
  if http_status == 429 then return errors.ErrorCode.RATE_LIMITED, true, "Rate limited"
  elseif http_status == 401 or http_status == 403 then return errors.ErrorCode.AUTH_ERROR, false, "Auth failed"
  elseif http_status and http_status >= 500 then return errors.ErrorCode.MODEL_ERROR, true, "Server error " .. http_status
  elseif http_status and http_status >= 400 then return errors.ErrorCode.INVALID_REQUEST, false, "Bad request " .. http_status
  end
  return errors.ErrorCode.INTERNAL_ERROR, false, error_body or "Unknown error"
end

-- ============================================================================
-- SSE Parser (OpenAI format only)
-- ============================================================================

local function create_sse_parser(callbacks)
  callbacks = callbacks or {}
  local buffer = ""
  local state = { id = nil, model = nil, content = {}, stop_reason = nil, usage = {} }

  local function finalize()
    -- Parse any remaining partial tool inputs.
    -- _partial_args may already be valid JSON (from table-encoded initial args
    -- via the type-check fix) or assembled JSON from streaming string chunks.
    for _, block in ipairs(state.content) do
      if block._partial_args then
        local ok, parsed = pcall(vim.json.decode, block._partial_args)
        if ok and type(parsed) == "table" then
          block["function"].arguments = vim.json.encode(parsed)
        elseif not ok and block["function"].arguments == "" then
          -- Decode failed (partial/invalid JSON). If arguments is empty, use
          -- the raw _partial_args as a fallback rather than losing the data.
          block["function"].arguments = block._partial_args
        end
        block._partial_args = nil
      end
    end
    if callbacks.on_complete then
      callbacks.on_complete({
        id = state.id, model = state.model,
        content = state.content,
        stop_reason = state.stop_reason,
        usage = state.usage,
      })
    end
  end

  local function process(event)
    state.id = event.id or state.id
    state.model = event.model or state.model

    if event.usage then
      state.usage.input_tokens = event.usage.prompt_tokens or 0
      state.usage.output_tokens = event.usage.completion_tokens or 0
    end

    local choices = event.choices
    if not choices or #choices == 0 then return end

    for _, choice in ipairs(choices) do
      local delta = choice.delta
      if not delta then goto next_choice end

      -- Text (filter vim.NIL from json null)
      local text = delta.content
      if text and text ~= vim.NIL and callbacks.on_text then
        callbacks.on_text(tostring(text))
      end

      -- Thinking/reasoning
      local reasoning = delta.reasoning_content
      if reasoning and reasoning ~= vim.NIL and callbacks.on_thinking then
        callbacks.on_thinking(tostring(reasoning))
      end

      -- Tool calls
      if delta.tool_calls then
        for _, tc in ipairs(delta.tool_calls) do
          local idx = (tc.index or 0) + 1
          local fn = tc["function"]
          local tc_id = tc.id
          if tc_id and tc_id ~= vim.NIL and fn and fn.name and fn.name ~= vim.NIL then
            state.content[idx] = {
              type = "function",
              id = tostring(tc_id),
              ["function"] = { name = tostring(fn.name), arguments = type(fn.arguments) == "table" and vim.json.encode(fn.arguments) or tostring(fn.arguments or "") },
              _partial_args = type(fn.arguments) == "table" and vim.json.encode(fn.arguments) or tostring(fn.arguments or ""),
            }
            if callbacks.on_tool_start then
              callbacks.on_tool_start(tostring(tc_id), tostring(fn.name))
            end
          elseif fn and fn.arguments and fn.arguments ~= vim.NIL then
            local block = state.content[idx]
            if block then
              local args_str = type(fn.arguments) == "table" and vim.json.encode(fn.arguments) or tostring(fn.arguments)
              block._partial_args = (block._partial_args or "") .. args_str
            end
          end
        end
      end

      -- Finish: only on actual non-null finish_reason
      local reason = choice.finish_reason
      if reason and reason ~= vim.NIL and reason ~= "" then
        state.stop_reason = reason == "tool_calls" and "tool_use" or tostring(reason)
        finalize()
      end
      ::next_choice::
    end
  end

  local function feed(chunk)
    if not chunk or #chunk == 0 then return end
    chunk = chunk:gsub("\r\n", "\n"):gsub("\r", "\n")
    buffer = buffer .. chunk

    while true do
      local e_start, e_end = buffer:find("\n\n", 1, true)
      if not e_start then break end
      local event_text = buffer:sub(1, e_start - 1)
      buffer = buffer:sub(e_end + 1)

      for line in event_text:gmatch("[^\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:sub(1, 6) == "data: " then
          local data_str = trimmed:sub(7)
          if data_str == "[DONE]" then break end
          local ok, event = pcall(vim.json.decode, data_str)
          if ok and event and type(event) == "table" then
            process(event)
          end
        end
      end
    end
  end

  return feed
end

-- ============================================================================
-- Request Building (OpenAI format)
-- ============================================================================

local function build_request(system_prompt, messages, tools)
  local body = {
    model = M.get_model(),
    max_tokens = config.max_tokens,
    stream = true,
    messages = {},
  }

  -- System message
  if system_prompt then
    local text = system_prompt
    if type(system_prompt) == "table" then
      local parts = {}
      for _, b in ipairs(system_prompt) do
        if b.type == "text" then parts[#parts + 1] = b.text or "" end
      end
      text = table.concat(parts, "\n")
    end
    if #text > 0 then body.messages[#body.messages + 1] = { role = "system", content = text } end
  end

  -- Messages (convert from internal format to OpenAI API format).
  -- DeepSeek's API is fully OpenAI-compatible for tool calling, including
  -- role:"tool" with tool_call_id. See: https://api-docs.deepseek.com/guides/tool_calls
  for _, msg in ipairs(messages or {}) do
    if msg.role == "tool" then
      local tm = { role = "tool", content = msg.content or "" }
      if msg.tool_call_id then tm.tool_call_id = msg.tool_call_id end
      body.messages[#body.messages + 1] = tm

    elseif msg.role == "assistant" and msg.tool_calls then
      -- Assistant with tool_calls (new format): content + tool_calls separate.
      local am = { role = "assistant" }
      if msg.content then am.content = msg.content end
      am.tool_calls = msg.tool_calls
      body.messages[#body.messages + 1] = am

    elseif type(msg.content) == "string" then
      -- Simple string content
      body.messages[#body.messages + 1] = { role = msg.role, content = msg.content }

    elseif type(msg.content) == "table" then
      -- Legacy format: content is an array of blocks. Extract text and tool calls.
      local converted = { role = msg.role }
      local text_parts = {}
      local tool_calls = {}

      for _, block in ipairs(msg.content) do
        if block.type == "text" then
          text_parts[#text_parts + 1] = block.text or ""
        elseif block.type == "function" then
          -- Ensure block has proper id/type/function structure
          local tc = {
            id = block.id and tostring(block.id) or ("call_" .. tostring(#tool_calls + 1)),
            type = "function",
            ["function"] = {
              name = block["function"] and block["function"].name or "?",
              arguments = block["function"] and block["function"].arguments or "{}",
            },
          }
          tool_calls[#tool_calls + 1] = tc
        end
      end

      if msg.role == "assistant" and #tool_calls > 0 then
        converted.tool_calls = tool_calls
      end
      if #text_parts > 0 then
        converted.content = table.concat(text_parts, "\n")
      end
      body.messages[#body.messages + 1] = converted
    end
  end

  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end

  return body
end

local function build_curl_args(body)
  local api_url = M.get_api_url()
  local api_key = M.get_api_key()

  -- Recursively sanitize all strings before encoding.
  compat.sanitize_table_utf8(body)

  -- json_encode with pcall + retry: if the first attempt fails despite
  -- sanitization, do a second pass of sanitization and try again.
  -- This catches edge cases where sanitize_table_utf8 missed something.
  local ok, body_json = pcall(vim.fn.json_encode, body)
  if not ok then
    log.warn("json_encode failed on first attempt, re-sanitizing", { error = tostring(body_json) })
    compat.sanitize_table_utf8(body)
    ok, body_json = pcall(vim.fn.json_encode, body)
    if not ok then
      log.error("json_encode failed after re-sanitization", { error = tostring(body_json) })
      error("json_encode: " .. tostring(body_json))
    end
  end

  -- Use --data-binary @- to read the request body from stdin instead of
  -- passing it as a -d argument. The body can exceed ARG_MAX (256KB on
  -- macOS) with multi-turn history + large tool results.
  local args = { "curl", "-s", "-X", "POST", api_url, "--data-binary", "@-",
    "-H", "content-type: application/json",
    "-H", "Authorization: Bearer " .. (api_key or ""),
  }

  return args, body_json
end

-- ============================================================================
-- Send Message
-- ============================================================================

function M.send_message(opts, callbacks, retry_count)
  callbacks = callbacks or {}
  retry_count = retry_count or 0

  local api_key = M.get_api_key()
  if not api_key then
    vim.schedule(function()
      if callbacks.on_error then
        callbacks.on_error(errors.ErrorCode.AUTH_ERROR, "No API key. Set ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY.", false)
      end
    end)
    return { kill = function() end }
  end

  local body = build_request(opts.system, opts.messages, opts.tools)
  local curl_args, body_json = build_curl_args(body)
  local raw_buffer = ""
  local full_response = nil
  local response_received = false
  local killed = false
  local timeout_timer = nil
  local curl_job = nil

  local sse_feed = create_sse_parser({
    on_text = function(chunk)
      if callbacks.on_text then callbacks.on_text(chunk) end
    end,
    on_thinking = function(chunk)
      if callbacks.on_thinking then callbacks.on_thinking(chunk) end
    end,
    on_tool_start = function(id, name)
      if callbacks.on_tool_start then callbacks.on_tool_start(id, name) end
    end,
    on_complete = function(response)
      full_response = response
      response_received = true
      if timeout_timer and not timeout_timer:is_closing() then
        timeout_timer:stop(); timeout_timer:close(); timeout_timer = nil
      end
      if callbacks.on_complete then callbacks.on_complete(response) end
    end,
    on_error = function(code, msg)
      if callbacks.on_error then callbacks.on_error(code, msg, false) end
    end,
  })

  -- Pipe the request body through stdin to avoid ARG_MAX overflow on large
  -- conversation histories (--data-binary @- reads from stdin).
  local job = vim.system(curl_args, {
    text = true,
    stdin = body_json,
    timeout = config.timeout_sec * 1000,
    stdout = function(_, data)
      if killed then return end
      if data then raw_buffer = raw_buffer .. data end
    end,
  }, function(obj)
    if killed then return end
    if timeout_timer and not timeout_timer:is_closing() then
      timeout_timer:stop(); timeout_timer:close(); timeout_timer = nil
    end

    vim.schedule(function()
      if obj.code ~= 0 then
        local code, retryable, msg = classify_error(nil, raw_buffer, obj.code)
        log.error("curl failed", { exit_code = obj.code, msg = msg })
        if retryable and retry_count < config.max_retries then
          local delay = config.retry_delays[retry_count + 1] or 15
          vim.defer_fn(function() M.send_message(opts, callbacks, retry_count + 1) end, delay * 1000)
        elseif callbacks.on_error then
          callbacks.on_error(code, msg, retryable)
        end
        return
      end

      -- curl OK: feed to SSE parser
      if #raw_buffer > 0 then sse_feed(raw_buffer) end

      -- Fallback: try JSON parse (error or non-streaming response).
      -- Non-streaming responses have a different shape (choices[].message with
      -- optional tool_calls). Normalize to the same format as the SSE parser so
      -- downstream consumers (agent.on_complete) see a consistent structure.
      if not response_received then
        local ok_j, response = pcall(vim.json.decode, raw_buffer)
        if ok_j and response then
          if response.error then
            if callbacks.on_error then
              callbacks.on_error(errors.ErrorCode.MODEL_ERROR, response.error.message or "API error", false)
            end
          elseif callbacks.on_complete then
            -- Normalize non-streaming response to SSE-parser format
            local message = response.choices and response.choices[1] and response.choices[1].message
            if message then
              local content = {}
              -- Text content
              if message.content and message.content ~= "" then
                content[#content + 1] = { type = "text", text = message.content }
              end
              -- Tool calls
              if message.tool_calls then
                for _, tc in ipairs(message.tool_calls) do
                  local fn = tc["function"] or {}
                  local args = fn.arguments
                  -- Normalize arguments: table -> JSON string, string -> pass through
                  if type(args) == "table" then
                    args = vim.json.encode(args)
                  elseif type(args) ~= "string" then
                    args = "{}"
                  end
                  content[#content + 1] = {
                    type = "function",
                    id = tostring(tc.id or ""),
                    ["function"] = { name = tostring(fn.name or "?"), arguments = args },
                  }
                end
              end
              callbacks.on_complete({
                id = response.id,
                model = response.model,
                content = content,
                stop_reason = (response.choices[1].finish_reason == "tool_calls" and "tool_use")
                  or tostring(response.choices[1].finish_reason or "stop"),
                usage = {
                  input_tokens = response.usage and response.usage.prompt_tokens or 0,
                  output_tokens = response.usage and response.usage.completion_tokens or 0,
                },
              })
            else
              -- Empty or unrecognized shape -- pass through as-is
              callbacks.on_complete(response)
            end
          end
        elseif callbacks.on_error then
          callbacks.on_error(errors.ErrorCode.PARSE_ERROR, "Empty or unparseable response", false)
        end
      end
    end)
  end)

  curl_job = job

  timeout_timer = vim.loop.new_timer()
  if timeout_timer then
    timeout_timer:start(config.timeout_sec * 1000, 0, vim.schedule_wrap(function()
      if killed or response_received then return end
      killed = true
      if job and not job:is_closing() then pcall(job.kill, job, 9) end
      if retry_count < config.max_retries then
        local delay = config.retry_delays[retry_count + 1] or 15
        vim.defer_fn(function() M.send_message(opts, callbacks, retry_count + 1) end, delay * 1000)
      elseif callbacks.on_error then
        callbacks.on_error(errors.ErrorCode.TIMEOUT, "Request timed out", false)
      end
    end))
  end

  -- Register this request as the active one (original or retry)
  active_job = job
  active_timer = timeout_timer

  local function kill()
    killed = true
    if timeout_timer and not timeout_timer:is_closing() then
      timeout_timer:stop(); timeout_timer:close(); timeout_timer = nil
    end
    if curl_job and not curl_job:is_closing() then
      pcall(curl_job.kill, curl_job, 9)
    end
    -- Clear module-level tracking
    if active_timer == timeout_timer then active_timer = nil end
    if active_job == curl_job then active_job = nil end
  end

  return { kill = kill, job = curl_job }
end

-- ============================================================================
-- Observation
-- ============================================================================

function M.observe()
  return {
    configured = M.is_configured(),
    model = M.get_model(),
    provider = "openai",
    api_url = M.get_api_url(),
    max_tokens = config.max_tokens,
    timeout_sec = config.timeout_sec,
    max_retries = config.max_retries,
    context_limit = M.get_context_limit(),
  }
end

--- Kill the currently active request (original or retry).
--- Safe to call at any time — handles nil timers/jobs gracefully.
function M.stop()
  if active_timer and not active_timer:is_closing() then
    active_timer:stop()
    active_timer:close()
    active_timer = nil
  end
  if active_job and not active_job:is_closing() then
    pcall(active_job.kill, active_job, 9)
    active_job = nil
  end
end

function M.cleanup() M.stop() end

return M
