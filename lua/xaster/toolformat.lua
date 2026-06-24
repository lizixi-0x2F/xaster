--- xaster/toolformat.lua
--- ============================================================================
--- Tool formatting -- OpenAI function calling format.
--- v3: Pure OpenAI. No more Anthropic, no prompt-based tools.
--- ============================================================================

local tools = require("xaster.tools")
local log = require("xaster.log").for_module("toolformat")
local compat = require("xaster.compat")

local M = {}

-- Tool name: dots -> underscores (OpenAI requires ^[a-zA-Z0-9_-]+$)
local function to_api_name(name) return name:gsub("%.", "_") end
local function from_api_name(name) return name:gsub("_", ".") end

-- Cached (keyed by strict mode so switching models invalidates correctly)
local cached_tools = nil
local cached_is_deepseek = nil

local EXCLUDED = {
  ["tools.list"] = true, ["history.list"] = true, ["history.get"] = true,
  ["history.clear"] = true, ["history.stats"] = true, ["history.observe"] = true,
  ["state.observe"] = true, ["ping"] = true, ["log.dump"] = true,
}

--- Ensure empty tables serialize as {} (object), not [] (array).
--- vim.fn.json_encode serializes {} as [] by default; only vim.empty_dict()
--- forces an empty JSON object. Walk the schema tree and convert.
local function enforce_json_objects(t)
  if type(t) ~= "table" then return t end
  -- If table has no array-like keys, and is empty, mark as dict
  local has_string_key = false
  for k in pairs(t) do
    if type(k) == "string" then has_string_key = true; break end
  end
  if not has_string_key and next(t) == nil then
    return vim.empty_dict()
  end
  -- Recurse into subtables
  local result = {}
  for k, v in pairs(t) do
    result[k] = enforce_json_objects(v)
  end
  return result
end

--- Recursively set additionalProperties=false on all object nodes in a JSON Schema.
--- Required by DeepSeek strict mode: https://api-docs.deepseek.com/guides/tool_calls
---@param t table  Schema node
---@return table
local function make_strict_schema(t)
  if type(t) ~= "table" then return t end
  if t.type == "object" then
    t.additionalProperties = false
  end
  -- Recurse into nested schemas
  for k, v in pairs(t) do
    if type(v) == "table" and k ~= "enum" then
      t[k] = make_strict_schema(v)
    end
  end
  return t
end

--- Get all tools in OpenAI function-calling format.
--- DeepSeek requires strict:true + additionalProperties:false for reliable
--- tool calling. Without strict mode, the model may silently ignore tool
--- calls or produce malformed arguments. See: https://api-docs.deepseek.com/guides/tool_calls
---@return table[]  [{type: "function", function: {name, description, parameters}}]
function M.get_tools()
  local ok_llm, llm = pcall(require, "xaster.llm")
  local is_deepseek = ok_llm and llm.get_model and llm.get_model():find("deepseek")

  -- Cache keyed by strict mode: switching between DeepSeek/non-DeepSeek
  -- models must rebuild tools with the correct format.
  if cached_tools and cached_is_deepseek == is_deepseek then return cached_tools end

  local registry = tools.list()
  local result = {}

  for name, def in pairs(registry) do
    if not EXCLUDED[name] then
      local params = def.parameters or { type = "object", properties = {} }
      params = enforce_json_objects(params)

      if is_deepseek then
        params = make_strict_schema(params)
      end

      local fn_def = {
        name = to_api_name(name),
        description = (def.description or ""):gsub("\n", " "),
        parameters = params,
      }

      if is_deepseek then
        fn_def.strict = true
      end

      result[#result + 1] = {
        type = "function",
        ["function"] = fn_def,
      }
    end
  end

  table.sort(result, function(a, b) return a["function"].name < b["function"].name end)
  cached_tools = result
  cached_is_deepseek = is_deepseek
  log.info("built tool list", { count = #result, strict = is_deepseek or false })
  return result
end

--- Get tools filtered to essential subset (for limited-context providers).
---@param names string[] API-safe tool names to keep
---@return table[]
function M.get_tools_filtered(names)
  local all = M.get_tools()
  local keep = {}
  for _, n in ipairs(names) do keep[n] = true end
  local result = {}
  for _, t in ipairs(all) do
    if keep[t["function"].name] then result[#result + 1] = t end
  end
  return result
end

--- Execute a tool call (OpenAI format).
--- Input: {id, type: "function", function: {name, arguments: string|table}}
---@param tool_call table
---@return table {content: string, is_error: boolean}
function M.execute_tool_call(tool_call)
  local fn = tool_call["function"] or {}
  local api_name = fn.name
  if not api_name then
    return { content = '{"ok":false,"error":"missing function name"}', is_error = true }
  end

  -- Parse arguments (string or table)
  local input = fn.arguments
  if type(input) == "string" and input ~= "" then
    local ok, parsed = pcall(vim.json.decode, input)
    if ok and type(parsed) == "table" then
      input = parsed
    else
      log.warn("failed to parse tool arguments", { tool = api_name })
      input = {}
    end
  elseif type(input) ~= "table" then
    input = {}
  end

  local name = from_api_name(api_name)
  local result, err_code, err_msg = tools.dispatch(name, input)

  if err_code then
    -- Try alternate naming
    local alt = name:find("%.") and name:gsub("%.", "_") or name:gsub("_", ".")
    if alt ~= name then
      result, err_code, err_msg = tools.dispatch(alt, input)
    end
  end

  if err_code then
    log.error("tool dispatch failed", { tool = name, code = err_code })
    return { content = vim.fn.json_encode({ ok = false, error = err_msg or "failed" }), is_error = true }
  end

  local formatted
  if type(result) == "table" then
    local ok, encoded = pcall(vim.fn.json_encode, result)
    formatted = ok and encoded or vim.inspect(result):sub(1, 100000)
  elseif result == nil then
    formatted = "null"
  else
    local ok, encoded = pcall(vim.fn.json_encode, result)
    formatted = ok and encoded or tostring(result)
  end

  if #formatted > 1000000 then
    formatted = formatted:sub(1, 1000000) .. "\n... [truncated]"
  end

  -- Strip invalid UTF-8 bytes from tool results. Binary data from
  -- bash / file.read would otherwise crash vim.fn.json_encode later.
  formatted = compat.sanitize_utf8(formatted)

  return { content = formatted, is_error = false }
end

-- Backward compat
function M.get_anthropic_tools() return M.get_tools() end
function M.execute_tool_use(tool_use) return M.execute_tool_call(tool_use) end

return M
