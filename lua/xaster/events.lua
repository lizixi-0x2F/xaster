--- xaster/events.lua
--- Lightweight event emitter for inter-module communication.
--- This module is a stub; the history module uses it when available
--- but degrades gracefully when events.lua is absent.

local M = {}

---@type table<number, function>  active listeners
M._listeners = {}

--- Subscribe to an event.
---@param event string  event name (e.g. "tool:executed", "agent:phase_changed")
---@param callback function  function(data) called when event fires
---@return number  listener id (for unlisten)
function M.listen(event, callback)
  local id = #M._listeners + 1
  M._listeners[id] = { event = event, callback = callback }
  return id
end

--- Unsubscribe a listener by id.
---@param id number
function M.unlisten(id)
  if M._listeners[id] then
    M._listeners[id] = nil
  end
end

--- Emit an event to all subscribed listeners.
--- Does nothing if no listeners are registered.
---@param event string
---@param data any
function M.emit(event, data)
  for _, entry in pairs(M._listeners) do
    if entry.event == event and type(entry.callback) == "function" then
      local ok, err = pcall(entry.callback, data)
      if not ok then
        vim.notify("[xaster] event handler error (" .. event .. "): " .. tostring(err), vim.log.levels.WARN)
      end
    end
  end
end

--- Remove all listeners.
function M.clear()
  M._listeners = {}
end

return M
