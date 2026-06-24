--- xaster/compat.lua
--- Zero-dependency compatibility shims for deprecated Neovim APIs.
--- All other xaster modules require this.

local M = {}

function M.tbl_count(t)
  if not t then return 0 end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function M.list_contains(t, v)
  if not t then return false end
  for _, item in ipairs(t) do
    if item == v then return true end
  end
  return false
end

function M.tbl_filter(t, pred)
  local result = {}
  for _, item in ipairs(t) do
    if pred(item) then table.insert(result, item) end
  end
  return result
end

function M.tbl_keys(t)
  local keys = {}
  for k in pairs(t) do
    table.insert(keys, k)
  end
  return keys
end

-- Direct passthrough for non-deprecated APIs
M.tbl_deep_extend = vim.tbl_deep_extend
M.tbl_islist = vim.islist or vim.tbl_islist  -- 0.10+ uses vim.islist

--- Recursively sanitize all string values in a table (in-place).
--- Prevents vim.fn.json_encode from throwing E474 when any nested string
--- contains invalid UTF-8 bytes.
---@param t table
---@return table  The same table, mutated in-place
function M.sanitize_table_utf8(t)
  if type(t) ~= "table" then return t end
  for k, v in pairs(t) do
    if type(v) == "string" then
      t[k] = M.sanitize_utf8(v)
    elseif type(v) == "table" then
      M.sanitize_table_utf8(v)
    end
  end
  return t
end

--- Sanitize a string to valid UTF-8. Invalid byte sequences are replaced
--- with U+FFFD (the Unicode replacement character). This prevents
--- vim.fn.json_encode from throwing E474 on binary data in tool results.
---@param s string
---@return string
function M.sanitize_utf8(s)
  if type(s) ~= "string" then return s or "" end
  local result = {}
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    if not b then break end
    if b < 0x80 then
      -- ASCII: pass through
      result[#result + 1] = s:sub(i, i)
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      -- 2-byte sequence (U+0080 - U+07FF)
      local b2 = s:byte(i + 1)
      if b2 and b2 >= 0x80 and b2 <= 0xBF then
        result[#result + 1] = s:sub(i, i + 1)
        i = i + 2
      else
        result[#result + 1] = "\239\191\189" -- U+FFFD
        i = i + 1
      end
    elseif b >= 0xE0 and b <= 0xEF then
      -- 3-byte sequence (U+0800 - U+FFFF, excl. surrogates)
      local b2, b3 = s:byte(i + 1), s:byte(i + 2)
      if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
        if b == 0xE0 and b2 < 0xA0 then
          result[#result + 1] = "\239\191\189" -- overlong
        elseif b == 0xED and b2 > 0x9F then
          result[#result + 1] = "\239\191\189" -- surrogate
        else
          result[#result + 1] = s:sub(i, i + 2)
        end
        i = i + 3
      else
        result[#result + 1] = "\239\191\189"
        i = i + 1
      end
    elseif b >= 0xF0 and b <= 0xF4 then
      -- 4-byte sequence (U+10000 - U+10FFFF)
      local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
      if b2 and b3 and b4
        and b2 >= 0x80 and b2 <= 0xBF
        and b3 >= 0x80 and b3 <= 0xBF
        and b4 >= 0x80 and b4 <= 0xBF then
        if b == 0xF0 and b2 < 0x90 then
          result[#result + 1] = "\239\191\189" -- overlong
        elseif b == 0xF4 and b2 > 0x8F then
          result[#result + 1] = "\239\191\189" -- out of range
        else
          result[#result + 1] = s:sub(i, i + 3)
        end
        i = i + 4
      else
        result[#result + 1] = "\239\191\189"
        i = i + 1
      end
    else
      -- Invalid: lone continuation byte, 0xFE/0xFF, overlong 0xC0/0xC1
      result[#result + 1] = "\239\191\189"
      i = i + 1
    end
  end
  return table.concat(result)
end

return M
