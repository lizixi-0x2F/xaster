--- tests/helpers/init.lua
--- Test helpers for xaster test suite.
--- Designed for plenary.nvim's test framework.
---
--- Run with:
---   nvim --headless -c "PlenaryBustedDirectory tests/xaster/ { minimal_init = 'tests/helpers/init.lua' }"

-- Set up minimal Neovim environment for testing
vim.cmd([[
  set rtp+=.
  set rtp+=../plenary.nvim
  runtime! plugin/plenary.vim
]])

-- Mock vim.notify to avoid noise during tests
local original_notify = vim.notify
vim.notify = function(msg, level, opts)
  -- Suppress during tests unless explicitly requested
  if vim.env.XASTER_TEST_VERBOSE then
    original_notify(msg, level, opts)
  end
end

-- Mock environment variables for LLM tests
if not vim.env.ANTHROPIC_API_KEY then
  vim.env.ANTHROPIC_API_KEY = "test-key-not-real"
end

-- Load xaster modules
local function safe_require(name)
  local ok, mod = pcall(require, name)
  if not ok then
    print("WARNING: failed to load " .. name .. ": " .. tostring(mod))
    return nil
  end
  return mod
end

-- Export helpers
local M = {}

--- Assert that a function call does not error.
---@param func function
---@param ... any Arguments to pass
---@return boolean ok
---@return any result
function M.pcall_ok(func, ...)
  local ok, result = pcall(func, ...)
  assert(ok, "Expected function to succeed, but got error: " .. tostring(result))
  return ok, result
end

--- Assert that two values are deeply equal.
---@param actual any
---@param expected any
---@param msg string|nil
function M.assert_eq(actual, expected, msg)
  if type(actual) == "table" and type(expected) == "table" then
    -- Deep compare
    local function deep_eq(a, b)
      if type(a) ~= type(b) then return false end
      if type(a) ~= "table" then return a == b end
      for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
      end
      for k, _ in pairs(b) do
        if a[k] == nil then return false end
      end
      return true
    end
    assert(deep_eq(actual, expected), msg or ("Expected " .. vim.inspect(expected) .. " but got " .. vim.inspect(actual)))
  else
    assert(actual == expected, msg or ("Expected " .. tostring(expected) .. " but got " .. tostring(actual)))
  end
end

--- Assert that a value is truthy.
---@param value any
---@param msg string|nil
function M.assert_ok(value, msg)
  assert(value, msg or "Expected truthy value")
end

--- Create a temporary buffer for testing.
---@param lines string[]
---@return integer buf_id
function M.create_test_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  return buf
end

return M
