--- xaster/errors.lua
--- Error codes and value sanitization.
--- Extracted from protocol.lua so tools.lua doesn't need the full JSON-RPC module.

local M = {}

-- JSON-RPC 2.0 standard error codes
M.ErrorCode = {
  PARSE_ERROR      = -32700,
  INVALID_REQUEST  = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS   = -32602,
  INTERNAL_ERROR   = -32603,
  -- xaster custom error codes (-32000 to -32099 reserved for implementation)
  BUFFER_NOT_FOUND = -32001,
  WINDOW_NOT_FOUND = -32002,
  INVALID_RANGE    = -32003,
  LSP_NOT_READY    = -32004,
  EDITOR_BUSY      = -32005,
  UNAUTHORIZED     = -32006,
  -- LLM/Network error codes (-32010 to -32019)
  NETWORK_ERROR    = -32010,  -- curl failed, DNS resolution failed
  TIMEOUT          = -32011,  -- request exceeded timeout
  RATE_LIMITED     = -32012,  -- 429 response
  AUTH_ERROR       = -32013,  -- 401/403 response
  MODEL_ERROR      = -32014,  -- model returned error response
  PARSE_ERROR      = -32015,  -- failed to parse SSE stream or response
  MAX_RETRIES      = -32016,  -- retry budget exhausted
}

--- Sanitize a value for safe handling after tool execution.
--- Converts vim.NIL to nil, function/userdata to string representation.
--- Used by tools.lua dispatch to clean results before returning.
---@param v any
---@return any
function M.sanitize(v)
  if v == nil or v == vim.NIL then
    return vim.NIL
  end
  local t = type(v)
  if t == "table" then
    if vim.islist(v) then
      local result = {}
      for i, item in ipairs(v) do
        result[i] = M.sanitize(item)
      end
      return result
    else
      local result = {}
      for k, item in pairs(v) do
        result[k] = M.sanitize(item)
      end
      return result
    end
  elseif t == "function" or t == "userdata" or t == "thread" then
    return tostring(v)
  end
  return v
end

return M
