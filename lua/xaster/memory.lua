--- xaster/memory.lua
--- Fast/Slow Dual-Layer Agent Memory.
---
--- Architecture:
---
---   FAST LAYER (volatile, high-frequency)
---   - Scratchpad for the current task: findings, intermediate values, file paths
---   - TTL-based expiration: entries auto-expire in seconds to minutes
---   - Updated on every observation, tool call, and edit
---   - The agent's "working set" -- what it's thinking about RIGHT NOW
---   API: remember / recall / forget / has / append / incr
---
---   SLOW LAYER (persistent, low-frequency)
---   - Accumulated knowledge: project structure, conventions, lessons learned
---   - No TTL: persists for the session lifetime (survives context compression)
---   - Updated deliberately: when the agent discovers a fact worth keeping
---   - Guides the fast layer: recall falls back to slow on fast miss
---   API: learn / know / query / promote / demote
---
---   RECURSIVE INTERFACE
---   - recall: fast first -> slow fallback (fast trusts slow)
---   - promote: fast -> slow (important fact, keep it)
---   - demote: slow -> fast (this was transient after all)
---   - guide: slow provides relevant context for the current situation
---   - absorb: extract patterns from fast observations into slow knowledge
---
--- This is a recursive state model: fast acts, slow watches; fast queries
--- slow for guidance; slow learns from fast's outcomes at lower frequency.
--- Each cycle refines both layers.

local compat = require("xaster.compat")

local M = {}

-- ============================================================================
-- Fast Layer Storage (volatile, high-frequency)
-- ============================================================================

---@class FastEntry
---@field value any        The stored value
---@field time number      Unix timestamp when stored
---@field ttl number|nil   Optional TTL in seconds (nil = session lifetime)
---@field source string|nil  Which tool/round stored this

local fast_store = {}
local slow_store = {}   -- forward-declared: used by recall() before slow section

-- ============================================================================
-- Fast Layer: Core operations (unchanged API, backward compatible)
-- ============================================================================

--- Store a fact in fast memory. This is the high-frequency scratchpad.
---@param key string
---@param value any
---@param opts table|nil  { ttl: number (seconds), source: string }
function M.remember(key, value, opts)
  opts = opts or {}
  fast_store[key] = {
    value = value,
    time = os.time(),
    ttl = opts.ttl,
    source = opts.source,
  }
end

--- Retrieve a fact. Fast layer first, slow layer as fallback.
--- If a fast entry exists and is unexpired, return it.
--- If no fast entry (or expired), check slow layer.
--- Returns nil if neither layer has it.
---@param key string
---@return any|nil
function M.recall(key)
  -- Fast layer (primary)
  local entry = fast_store[key]
  if entry then
    if entry.ttl and (os.time() - entry.time) > entry.ttl then
      fast_store[key] = nil  -- expired, fall through to slow
    else
      return entry.value
    end
  end

  -- Slow layer (fallback)
  local slow_entry = slow_store[key]
  if slow_entry then
    -- Touch: record that fast consulted slow (for absorb/promotion heuristics)
    slow_entry.last_accessed = os.time()
    slow_entry.access_count = (slow_entry.access_count or 0) + 1
    return slow_entry.value
  end

  return nil
end

--- Delete a fact from fast memory. Slow memory is NOT affected
--- (slow knowledge is deliberately retained unless explicitly demoted).
---@param key string
---@return boolean existed
function M.forget(key)
  local existed = fast_store[key] ~= nil
  fast_store[key] = nil
  return existed
end

--- Check if a key exists in either layer (fast unexpired, or slow).
---@param key string
---@return boolean
function M.has(key)
  return M.recall(key) ~= nil
end

--- Append to a list stored at key. Creates in fast layer if missing.
---@param key string
---@param item any
function M.append(key, item)
  local list = M.recall(key)
  if type(list) ~= "table" then list = {} end
  list[#list + 1] = item
  M.remember(key, list)
end

--- Increment a counter stored at key (fast layer).
---@param key string
---@param delta number|nil  Default 1
---@return number new_value
function M.incr(key, delta)
  local v = tonumber(M.recall(key)) or 0
  v = v + (delta or 1)
  M.remember(key, v)
  return v
end

-- ============================================================================
-- Slow Layer Storage (persistent, low-frequency knowledge)
-- ============================================================================
-- Each slow entry represents knowledge the agent has verified or learned
-- across multiple observations. Higher confidence = more reliable.

---@class SlowEntry
---@field value any             The knowledge (string, table, etc.)
---@field learned_at number     os.time() when first learned
---@field last_updated number   os.time() when last reinforced
---@field last_accessed number  os.time() when last queried
---@field access_count integer  How many times consulted by fast layer
---@field confidence number     0.0 to 1.0 (how sure we are)
---@field evidence integer      Number of confirmations (fast -> slow reinforces)
---@field type string|nil       "fact" | "convention" | "structure" | "strategy" | "pattern"
---@field tags string[]|nil     Searchable tags
---@field source string|nil     Where this knowledge came from

local SLOW_MAX_ENTRIES = 200

-- ============================================================================
-- Slow Layer: Operations
-- ============================================================================

--- Deliberately learn a fact into slow memory.
--- This is for things the agent has confirmed and wants to persist.
---@param key string
---@param value any
---@param opts table|nil  { confidence: number (0-1), type: string, tags: string[], source: string }
---@return table  { ok, key, confidence }
function M.learn(key, value, opts)
  if not key or key == "" then
    return { ok = false, error = "key required" }
  end
  opts = opts or {}

  local existing = slow_store[key]
  local now = os.time()

  if existing then
    -- Reinforce: increase confidence and evidence
    existing.value = value  -- update with latest
    existing.last_updated = now
    existing.evidence = (existing.evidence or 0) + 1
    -- Confidence approaches 1.0 asymptotically with more evidence
    existing.confidence = math.min(1.0, (existing.confidence or 0.5) + (1.0 - (existing.confidence or 0.5)) * 0.3)
    if opts.type then existing.type = opts.type end
    if opts.tags then existing.tags = opts.tags end
    if opts.source then existing.source = opts.source end
  else
    -- New knowledge
    slow_store[key] = {
      value = value,
      learned_at = now,
      last_updated = now,
      confidence = opts.confidence or 0.5,  -- start at 0.5 (uncertain but noted)
      evidence = 1,
      type = opts.type,
      tags = opts.tags,
      source = opts.source,
      access_count = 0,
    }
  end

  -- Trim if over limit (remove lowest-confidence entries)
  local count = 0
  for _ in pairs(slow_store) do count = count + 1 end
  if count > SLOW_MAX_ENTRIES then
    -- Collect entries, sort by confidence ascending, remove N lowest
    local entries = {}
    for k, e in pairs(slow_store) do
      entries[#entries + 1] = { key = k, confidence = e.confidence or 0, evidence = e.evidence or 0 }
    end
    table.sort(entries, function(a, b)
      -- Sort by confidence first, then by evidence (fewer = less reliable)
      if a.confidence ~= b.confidence then return a.confidence < b.confidence end
      return a.evidence < b.evidence
    end)
    local to_remove = count - SLOW_MAX_ENTRIES
    for i = 1, to_remove do
      slow_store[entries[i].key] = nil
    end
  end

  return {
    ok = true,
    key = key,
    confidence = slow_store[key].confidence,
    is_reinforcement = existing ~= nil,
  }
end

--- Read directly from slow memory (skip fast layer).
---@param key string
---@return any|nil
function M.know(key)
  local entry = slow_store[key]
  if not entry then return nil end
  entry.last_accessed = os.time()
  entry.access_count = (entry.access_count or 0) + 1
  return entry.value
end

--- Query slow memory for entries matching a pattern.
--- Searches: key substring, type, tags.
---@param pattern string   Search term (matches key substring or tag)
---@param opts table|nil   { type: string, min_confidence: number, limit: integer }
---@return table[]  Array of {key, value, confidence, evidence, type, tags}
function M.query(pattern, opts)
  opts = opts or {}
  local results = {}
  local pattern_lower = pattern and pattern:lower() or nil

  for key, entry in pairs(slow_store) do
    -- Filter by type
    if not opts.type or entry.type == opts.type then
      -- Filter by confidence
      if not opts.min_confidence or (entry.confidence or 0) >= opts.min_confidence then
        -- Match against key or tags
        local matched = false
        if not pattern_lower or pattern_lower == "" then
          matched = true
        elseif key:lower():find(pattern_lower, 1, true) then
          matched = true
        elseif entry.tags then
          for _, tag in ipairs(entry.tags) do
            if tag:lower():find(pattern_lower, 1, true) then
              matched = true; break
            end
          end
        end

        if matched then
          results[#results + 1] = {
            key = key,
            value = type(entry.value) == "string" and entry.value or
                    type(entry.value) == "table" and ("[table:" .. compat.tbl_count(entry.value) .. " keys]") or
                    tostring(entry.value):sub(1, 200),
            confidence = entry.confidence,
            evidence = entry.evidence,
            type = entry.type,
            tags = entry.tags,
          }
        end
      end
    end
  end

  -- Sort by confidence descending
  table.sort(results, function(a, b) return a.confidence > b.confidence end)

  local limit = opts.limit or 20
  if #results > limit then
    local trimmed = {}
    for i = 1, limit do trimmed[i] = results[i] end
    results = trimmed
  end
  return results
end

--- Promote a fact from fast memory to slow memory.
--- The fast value becomes slow knowledge with initial confidence.
---@param key string
---@param opts table|nil  { type: string, tags: string[], confidence: number }
---@return table  { ok, key, confidence }
function M.promote(key, opts)
  local fast_val = M.recall(key)
  if fast_val == nil then
    return { ok = false, error = "no fast entry for key: " .. key }
  end

  opts = opts or {}
  return M.learn(key, fast_val, {
    confidence = opts.confidence or 0.4,  -- promoted facts start at lower confidence
    type = opts.type,
    tags = opts.tags,
    source = "promoted from fast memory",
  })
end

--- Demote slow knowledge back to fast memory.
--- Useful when something learned turns out to be transient or context-specific.
---@param key string
---@return table  { ok, key }
function M.demote(key)
  local entry = slow_store[key]
  if not entry then
    return { ok = false, error = "no slow entry for key: " .. key }
  end

  -- Move to fast with a TTL (it was slow, now treat as transient)
  M.remember(key, entry.value, { ttl = 300, source = "demoted from slow memory" })
  slow_store[key] = nil
  return { ok = true, key = key }
end

-- ============================================================================
-- Cross-Layer: Recursive interface (slow guides fast)
-- ============================================================================

--- Guide: slow memory provides relevant context for the current situation.
--- Returns the highest-confidence knowledge entries, ordered by relevance.
--- This is the "slow guides fast" direction of the recursive loop.
---@param context string|nil  Optional: filter by context (e.g. "editing", "refactoring")
---@param limit integer|nil   Max entries to return (default 16)
---@return table[]  Array of {key, value, confidence, type}
function M.guide(context, limit)
  limit = limit or 16
  local results = {}

  for key, entry in pairs(slow_store) do
    -- Only include entries with reasonable confidence
    if (entry.confidence or 0) >= 0.3 then
      local value_preview
      if type(entry.value) == "string" then
        value_preview = entry.value:sub(1, 200)
      elseif type(entry.value) == "table" then
        local ok, j = pcall(vim.fn.json_encode, entry.value)
        value_preview = ok and j:sub(1, 200) or vim.inspect(entry.value):sub(1, 200)
      else
        value_preview = tostring(entry.value):sub(1, 200)
      end

      results[#results + 1] = {
        key = key,
        value = value_preview,
        confidence = entry.confidence,
        type = entry.type,
        evidence = entry.evidence,
        score = (entry.confidence or 0) * 0.7 + math.min(1.0, (entry.access_count or 0) / 10) * 0.3,
      }
    end
  end

  -- Sort by combined score (confidence + access frequency)
  table.sort(results, function(a, b) return a.score > b.score end)

  if #results > limit then
    local trimmed = {}
    for i = 1, limit do trimmed[i] = results[i] end
    results = trimmed
  end
  return results
end

--- Absorb: scan fast memory for patterns worth promoting to slow.
--- Looks for:
---   - Frequently-accessed fast keys (promote to slow)
---   - Fast entries with structure patterns (conventions)
---   - Location clusters (files frequently visited together)
--- This is called periodically by the agent loop to distill fast into slow.
---@return table  { promoted: integer, new_learnings: integer }
function M.absorb()
  local result = { promoted = 0, new_learnings = 0 }

  -- Heuristic 1: fast entries with double-underscore prefix are "sticky",
  -- meaning the framework already treats them as important (tasks, plans).
  -- We don't auto-promote __ keys -- those stay in fast as active state.

  -- Heuristic 2: check if any fast entry has been updated 3+ times
  -- (via append/incr) -- suggests it's accumulating useful data.
  -- We don't auto-promote, but we make it available for explicit promotion.

  -- Heuristic 3: detect file relationship patterns
  -- If "target_file" or similar keys appear, learn project structure.
  local file_keys = {}
  for key, entry in pairs(fast_store) do
    if type(entry.value) == "string" and entry.value:match("%.lua$") then
      file_keys[#file_keys + 1] = { key = key, file = entry.value }
    end
  end
  if #file_keys >= 2 then
    -- Learn that these files are relevant to the current task
    local file_list = {}
    for _, fk in ipairs(file_keys) do
      file_list[#file_list + 1] = fk.file
    end
    M.learn("__absorbed_files__", file_list, {
      confidence = 0.4,
      type = "structure",
      tags = { "files", "project" },
      source = "absorb",
    })
    result.new_learnings = result.new_learnings + 1
  end

  return result
end

--- Get slow memory statistics.
---@return table  { total, avg_confidence, by_type }
function M.slow_stats()
  local stats = { total = 0, avg_confidence = 0.0, by_type = {} }
  local conf_sum = 0

  for _, entry in pairs(slow_store) do
    stats.total = stats.total + 1
    conf_sum = conf_sum + (entry.confidence or 0)
    local t = entry.type or "unknown"
    stats.by_type[t] = (stats.by_type[t] or 0) + 1
  end

  if stats.total > 0 then
    stats.avg_confidence = math.floor(conf_sum / stats.total * 100 + 0.5) / 100
  end
  return stats
end

-- ============================================================================
-- Task tracking
-- ============================================================================

--- Task tracking is a convention on top of remember/recall.
--- The Agent stores a task list at key "__tasks__" as an array of:
---   { id: string, title: string, status: "pending"|"in_progress"|"done"|"blocked" }

local function find_task(tasks, id)
  for _, t in ipairs(tasks) do
    if t.id == id then return t end
  end
  return nil
end

--- Initialize a task list for the current session.
--- Each task: { id, title, [status], [depends_on: string[]] }
--- Dependencies are auto-linked: if task A depends on B, B's blocked_by gets A.
---@param tasks table[]  Array of { id, title, [depends_on] }
function M.tasks_init(tasks)
  local list = {}
  -- First pass: create tasks with their depends_on lists
  for _, t in ipairs(tasks or {}) do
    local deps = {}
    if t.depends_on then
      for _, dep_id in ipairs(t.depends_on) do
        deps[#deps + 1] = dep_id
      end
    end
    list[#list + 1] = {
      id = t.id or tostring(#list + 1),
      title = t.title,
      status = "pending",
      depends_on = deps,
      blocked_by = {},
    }
  end
  -- Second pass: auto-compute blocked_by (reverse edges)
  for _, t in ipairs(list) do
    for _, dep_id in ipairs(t.depends_on) do
      local dep = find_task(list, dep_id)
      if dep then
        dep.blocked_by[#dep.blocked_by + 1] = t.id
      end
    end
  end
  M.remember("__tasks__", list)
end

--- Update a task's status with dependency validation.
--- Cannot mark a task "in_progress" if its dependencies are not "done".
--- When a task is marked "done", unblock all tasks waiting on it.
---@param id string
---@param status string  "pending"|"in_progress"|"done"|"blocked"
---@return table  { ok, [error], [unblocked] }
function M.task_update(id, status)
  local tasks = M.recall("__tasks__") or {}
  local task = find_task(tasks, id)
  if not task then
    return { ok = false, error = "no task with id: " .. id }
  end

  -- Dependency check: cannot start a task whose dependencies aren't done
  if status == "in_progress" then
    local blocking = {}
    for _, dep_id in ipairs(task.depends_on) do
      local dep = find_task(tasks, dep_id)
      if dep and dep.status ~= "done" then
        blocking[#blocking + 1] = dep_id
      end
    end
    if #blocking > 0 then
      return { ok = false, error = "blocked by unfinished tasks: " .. table.concat(blocking, ", ") }
    end
  end

  -- When marked done, check if we unblock downstream tasks
  local unblocked = {}
  if status == "done" then
    for _, blocked_id in ipairs(task.blocked_by) do
      local bt = find_task(tasks, blocked_id)
      if bt and bt.status == "blocked" then
        -- Check if ALL dependencies of the blocked task are now done
        local all_deps_done = true
        for _, bdep_id in ipairs(bt.depends_on) do
          local bdep = find_task(tasks, bdep_id)
          if bdep and bdep.status ~= "done" then
            all_deps_done = false
            break
          end
        end
        if all_deps_done then
          bt.status = "pending"
          unblocked[#unblocked + 1] = blocked_id
        end
      end
    end
  end

  task.status = status
  M.remember("__tasks__", tasks)
  return { ok = true, unblocked = #unblocked > 0 and unblocked or nil }
end

--- Get task progress summary.
---@return table  { total, done, in_progress, pending, blocked, tasks }
function M.task_progress()
  local tasks = M.recall("__tasks__") or {}
  local summary = { total = #tasks, done = 0, in_progress = 0, pending = 0, blocked = 0, tasks = tasks }
  for _, t in ipairs(tasks) do
    local s = t.status or "pending"
    if s == "done" then summary.done = summary.done + 1
    elseif s == "in_progress" then summary.in_progress = summary.in_progress + 1
    elseif s == "blocked" then summary.blocked = summary.blocked + 1
    else summary.pending = summary.pending + 1 end
  end
  return summary
end

-- ============================================================================
-- Serialization for system prompt
-- ============================================================================

--- Dump fast memory as a formatted string for inclusion in the system prompt.
--- Only includes active (fast) memory -- what the agent is working on NOW.
---@return string
function M.dump()
  local keys = {}
  for k, _ in pairs(fast_store) do
    keys[#keys + 1] = k
  end
  table.sort(keys)

  if #keys == 0 then return "" end

  local lines = { "Fast memory:" }
  for _, k in ipairs(keys) do
    local entry = fast_store[k]
    if not entry.ttl or (os.time() - entry.time) <= entry.ttl then
      local v = entry.value
      local vs
      if type(v) == "table" then
        local ok, j = pcall(vim.fn.json_encode, v)
        vs = ok and j or vim.inspect(v)
      else
        vs = tostring(v)
      end
      if #vs > 300 then vs = vs:sub(1, 300) .. "...[truncated]" end
      lines[#lines + 1] = string.format("  %s: %s", k, vs)
    end
  end
  return table.concat(lines, "\n")
end

--- Dump slow memory: the accumulated knowledge base.
--- Highlight-confidence entries first; low-confidence ones are terse.
---@return string
function M.dump_slow()
  if not next(slow_store) then return "" end

  local entries = {}
  for k, e in pairs(slow_store) do
    entries[#entries + 1] = { key = k, entry = e }
  end
  table.sort(entries, function(a, b)
    return (a.entry.confidence or 0) > (b.entry.confidence or 0)
  end)

  local lines = { "Slow memory (accumulated knowledge):" }
  local shown = 0
  for _, item in ipairs(entries) do
    if shown >= 30 then
      lines[#lines + 1] = string.format("  ... and %d more (low-confidence)", #entries - 30)
      break
    end
    shown = shown + 1

    local e = item.entry
    local conf_icon = e.confidence >= 0.8 and "[high]" or (e.confidence >= 0.5 and "[med]" or "[low]")
    local v = e.value
    local vs
    if type(v) == "string" then
      vs = v:sub(1, 200)
    elseif type(v) == "table" then
      local ok, j = pcall(vim.fn.json_encode, v)
      vs = ok and j:sub(1, 200) or vim.inspect(v):sub(1, 200)
    else
      vs = tostring(v):sub(1, 200)
    end
    if #vs >= 200 then vs = vs .. "..." end
    local type_tag = e.type and (" [" .. e.type .. "]") or ""
    local ev_tag = e.evidence > 1 and (" x" .. e.evidence) or ""
    lines[#lines + 1] = string.format("  %s %s%s%s: %s",
      conf_icon, item.key, type_tag, ev_tag, vs)
  end
  return table.concat(lines, "\n")
end

--- Dump task progress as a formatted string.
---@return string
function M.dump_tasks()
  local progress = M.task_progress()
  if progress.total == 0 then return "" end

  local lines = { "", "Task progress:" }
  local icons = { done = "[x]", in_progress = "[>]", pending = "[ ]", blocked = "[!]" }
  for _, t in ipairs(progress.tasks) do
    local icon = icons[t.status] or "?"
    lines[#lines + 1] = string.format("  %s %s: %s", icon, t.id, t.title)
  end
  lines[#lines + 1] = string.format("  -- %d/%d done", progress.done, progress.total)
  return table.concat(lines, "\n")
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

--- Get the full memory state (for debugging).
---@return table
function M.observe()
  local fast_entries = {}
  for k, v in pairs(fast_store) do
    fast_entries[#fast_entries + 1] = { key = k, value = v.value, time = v.time, ttl = v.ttl }
  end
  local slow_entries = {}
  for k, v in pairs(slow_store) do
    slow_entries[#slow_entries + 1] = {
      key = k, value = v.value, confidence = v.confidence,
      evidence = v.evidence, type = v.type, tags = v.tags,
    }
  end
  return {
    fast = { entries = fast_entries, count = #fast_entries },
    slow = { entries = slow_entries, count = #slow_entries, stats = M.slow_stats() },
  }
end

-- ============================================================================
-- ============================================================================
-- Two-Layer Memory: Lua facts + Vim marks (file positions)
-- ============================================================================
-- Layer 1 (Lua): facts, plans, task state -- accessed via remember/recall
-- Layer 2 (Vim marks): file positions -- accessed via mark.set/mark.get
-- memory.mark bridges both: stores a fact AND sets a Vim mark atomically

--- Track which mark letters are in use (a-z).
local used_marks = {}

--- Store current file position in BOTH Lua memory and as a Vim mark.
--- Returns the mark letter used so the agent can reference it.
---@param key string     Memory key (e.g. "target", "bug_A")
---@param label string|nil  Optional mark letter (a-z). Auto-assigned if nil.
---@return table  {ok, mark, buf, row, col, filename, key}
function M.mark_location(key, label)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local filename = vim.api.nvim_buf_get_name(buf)

  -- Auto-assign mark letter if not provided
  local mark_letter = label
  if not mark_letter or #mark_letter ~= 1 then
    for i = 97, 122 do  -- a-z
      local ch = string.char(i)
      if not used_marks[ch] then
        mark_letter = ch; break
      end
    end
    if not mark_letter then mark_letter = 'a' end  -- fallback: recycle
  end
  used_marks[mark_letter] = { key = key, time = os.time() }

  -- Set Vim mark
  pcall(vim.fn.setpos, "'" .. mark_letter, { buf, cursor[1], cursor[2], 0 })

  -- Store full location in Lua memory
  local location = {
    filename = filename,
    buf = buf,
    row = cursor[1],
    col = cursor[2],
    mark = mark_letter,
  }
  M.remember(key, location)

  return {
    ok = true,
    mark = mark_letter,
    buf = buf,
    row = cursor[1],
    col = cursor[2],
    filename = filename,
    key = key,
  }
end

--- Recall a stored location and jump to it.
--- Pushes current position to Vim's jumplist before jumping,
--- so the user can <C-o> back. Also pushes to agent jump stack
--- if an intent is provided.
---@param key string  Memory key to recall and jump to
---@param intent string|nil  Optional: why we're jumping (for jump stack)
---@return table|nil  {ok, filename, row, col, buf} or nil if not found
function M.jump_to(key, intent)
  local loc = M.recall(key)
  if not loc or type(loc) ~= "table" then return nil end

  local filename = loc.filename
  local row = loc.row
  local col = loc.col or 0

  if filename and filename ~= "" then
    local ok_open, editor = pcall(require, "xaster.editor")
    if ok_open then
      -- Push current position to agent jump stack if intent provided
      if intent then
        M.jump_push(intent)
      end

      -- Push current position to Vim's jumplist before jumping.
      -- We set the "previous context" mark, then use the 'G' command
      -- (which IS a Vim jump) to force a jumplist entry.
      local cur_buf = vim.api.nvim_get_current_buf()
      local cur_cursor = vim.api.nvim_win_get_cursor(0)
      pcall(vim.fn.setpos, "''", { cur_buf, cur_cursor[1], cur_cursor[2], 0 })

      local buf = editor.file_ensure_open(filename, { focus = true })
      if buf then
        -- Use G command instead of cursor_set to trigger Vim jumplist push
        pcall(vim.api.nvim_command, "normal! " .. row .. "G")
        if col > 0 then
          pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
        end
        vim.cmd("redraw!")
        return {
          ok = true,
          filename = filename,
          row = row,
          col = col,
          buf = buf,
        }
      end
    end
  end

  return nil
end

--- Release a mark letter for reuse.
---@param mark_letter string
function M.release_mark(mark_letter)
  used_marks[mark_letter] = nil
end

--- Dump all remembered locations (for system prompt).
--- Scans fast memory for location entries (tables with filename field).
---@return string
function M.dump_locations()
  local keys = {}
  for k, _ in pairs(fast_store) do
    keys[#keys + 1] = k
  end
  table.sort(keys)

  local lines = {}
  for _, k in ipairs(keys) do
    local v = fast_store[k]
    if type(v.value) == "table" and v.value.filename then
      local loc = v.value
      local fname = loc.filename:match("[^/]+$") or loc.filename
      lines[#lines + 1] = string.format("  %s -> %s:%d (mark '%s')",
        k, fname, loc.row or 0, loc.mark or '?')
    end
  end

  if #lines == 0 then return "" end
  return "Location marks:\n" .. table.concat(lines, "\n")
end

-- ============================================================================
-- Three-Layer Memory: Agent Jump Stack (semantic navigation)
-- ============================================================================
-- Layer 3: The agent maintains its own LIFO navigation stack with intent
-- annotations. Unlike Vim's mechanical jumplist (every jump is equal),
-- this stack records WHY the agent went somewhere, enabling semantic
-- backtracking: "go back to where I was before understanding imports."
--
-- Each entry: {file, row, col, intent, timestamp, mark}
-- Operations: jump_push (record), jump_pop (back), jump_forward, jump_backward
-- Integration: every memory.jump_to with an intent auto-pushes.
-- Vim jumplist: also set so <C-o>/<C-i> work for the user.

---@class JumpStackEntry
---@field file string       Absolute file path
---@field row integer       1-indexed row
---@field col integer       0-indexed column
---@field intent string     Why the agent went here
---@field timestamp number  os.time()
---@field mark string|nil   Associated Vim mark letter

local agent_jump_stack = {}
local agent_jump_index = 0   -- current position in stack (0 = bottom/to traverse forward)
local MAX_JUMP_STACK = 64

--- Push current editor position onto the agent jump stack with an intent.
--- Also pushes to Vim's jumplist so <C-o> works.
---@param intent string  Why we're marking this position
---@return table  { ok, index, total }
function M.jump_push(intent)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local filename = vim.api.nvim_buf_get_name(buf)

  -- Push to Vim jumplist (set previous context mark)
  pcall(vim.fn.setpos, "''", { buf, cursor[1], cursor[2], 0 })

  local entry = {
    file = filename ~= "" and filename or ("[buffer " .. buf .. "]"),
    row = cursor[1],
    col = cursor[2],
    intent = intent or "marked",
    timestamp = os.time(),
    mark = nil,
  }

  -- If we're not at the top (we went back and are now branching),
  -- truncate the forward entries
  if agent_jump_index < #agent_jump_stack then
    for i = #agent_jump_stack, agent_jump_index + 1, -1 do
      table.remove(agent_jump_stack, i)
    end
  end

  table.insert(agent_jump_stack, entry)
  agent_jump_index = #agent_jump_stack

  -- Trim old entries
  while #agent_jump_stack > MAX_JUMP_STACK do
    table.remove(agent_jump_stack, 1)
    agent_jump_index = math.max(0, agent_jump_index - 1)
  end

  return { ok = true, index = agent_jump_index, total = #agent_jump_stack }
end

--- Pop the agent jump stack: jump back to the previous position.
--- Moves cursor to the previous stack entry's file:row:col.
--- Does NOT remove the entry; we can jump_forward() to come back.
--- Analogous to Vim's <C-o> but with semantic awareness.
---@return table|nil  { ok, file, row, col, intent, index, total }
function M.jump_pop()
  if #agent_jump_stack == 0 then
    return nil
  end

  -- Save current position before going back (so we can jump_forward)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cur_file = vim.api.nvim_buf_get_name(buf)

  -- Save current position temporarily for the "forward" direction
  -- (already handled by the push-before-pop pattern in jump_push)

  agent_jump_index = math.max(1, agent_jump_index - 1)
  local entry = agent_jump_stack[agent_jump_index]

  if not entry then return nil end

  -- Open file and jump
  local ok_open, editor = pcall(require, "xaster.editor")
  if not ok_open then return nil end

  local resolved = vim.fn.resolve(vim.fn.expand(entry.file))
  local buf_target, err = editor.file_ensure_open(resolved, { focus = true })
  if not buf_target then return nil end

  -- Push to Vim jumplist for <C-o> consistency
  pcall(vim.fn.setpos, "''", { buf, cursor[1], cursor[2], 0 })

  -- Jump using G command (triggers Vim jumplist)
  pcall(vim.api.nvim_command, "normal! " .. entry.row .. "G")
  if entry.col > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { entry.row, entry.col })
  end
  vim.cmd("redraw!")

  return {
    ok = true,
    file = resolved,
    row = entry.row,
    col = entry.col,
    intent = entry.intent,
    index = agent_jump_index,
    total = #agent_jump_stack,
  }
end

--- Jump forward in the agent jump stack (analogous to Vim's <C-i>).
---@return table|nil  { ok, file, row, col, intent, index, total }
function M.jump_forward()
  if #agent_jump_stack == 0 then return nil end
  if agent_jump_index >= #agent_jump_stack then
    return nil  -- already at newest
  end

  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)

  agent_jump_index = agent_jump_index + 1
  local entry = agent_jump_stack[agent_jump_index]
  if not entry then return nil end

  local ok_open, editor = pcall(require, "xaster.editor")
  if not ok_open then return nil end

  local resolved = vim.fn.resolve(vim.fn.expand(entry.file))
  local buf_target, err = editor.file_ensure_open(resolved, { focus = true })
  if not buf_target then return nil end

  -- Push to Vim jumplist
  pcall(vim.fn.setpos, "''", { buf, cursor[1], cursor[2], 0 })
  pcall(vim.api.nvim_command, "normal! " .. entry.row .. "G")
  if entry.col > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { entry.row, entry.col })
  end
  vim.cmd("redraw!")

  return {
    ok = true,
    file = resolved,
    row = entry.row,
    col = entry.col,
    intent = entry.intent,
    index = agent_jump_index,
    total = #agent_jump_stack,
  }
end

--- Jump backward (alias for jump_pop, more explicit name).
---@return table|nil
function M.jump_backward()
  return M.jump_pop()
end

--- Peek at the agent jump stack without moving.
---@param n integer|nil  Number of entries from the top (nil = all)
---@return table[]  Array of {file, row, col, intent, is_current}
function M.jump_peek(n)
  n = n or #agent_jump_stack
  local results = {}
  local start = math.max(1, #agent_jump_stack - n + 1)
  for i = #agent_jump_stack, start, -1 do
    local e = agent_jump_stack[i]
    if e then
      results[#results + 1] = {
        file = e.file:match("[^/]+$") or e.file,
        row = e.row,
        col = e.col,
        intent = e.intent,
        is_current = (i == agent_jump_index),
      }
    end
  end
  return results
end

--- Get info about the jump stack.
---@return table  { total, current_index, can_back, can_forward }
function M.jump_info()
  return {
    total = #agent_jump_stack,
    current_index = agent_jump_index,
    can_back = agent_jump_index > 1,
    can_forward = agent_jump_index < #agent_jump_stack,
  }
end

--- Dump the jump stack for the system prompt.
---@return string
function M.jump_dump()
  if #agent_jump_stack == 0 then return "" end

  local lines = { "Jump stack (newest first):" }
  for i = #agent_jump_stack, 1, -1 do
    local e = agent_jump_stack[i]
    local marker = i == agent_jump_index and " >" or "  "
    local fname = e.file:match("[^/]+$") or e.file
    lines[#lines + 1] = string.format("%s %d. %s:%d -- %s",
      marker, #agent_jump_stack - i + 1, fname, e.row, e.intent)
  end
  return table.concat(lines, "\n")
end

-- ============================================================================
-- Four-Layer Memory: StateNode -- lightweight snapshots for rewind/compare
-- ============================================================================
-- Layer 4: Named snapshots of editor state. Unlike checkpoints (disk-based,
-- whole-session), these are in-memory and capture a specific moment:
--   - Buffer content (for small buffers) or changedtick (for large ones)
--   - Cursor position + current file
--   - Named register values (a-z, A-Z)
--   - Named marks (a-z)
--   - Optional metadata (label, parent snapshot)
--
-- Use before risky edits: snapshot.create("before_refactor"), edit, then
-- snapshot.restore("before_refactor") if something goes wrong.
-- snapshot.diff("before", "after") shows what changed.

---@class StateNode
---@field name string
---@field time number
---@field file string|nil
---@field buf integer|nil
---@field cursor table  {row, col}
---@field changedtick integer|nil
---@field buffer_lines table|nil  nil if buffer was too large
---@field registers table  { [reg]: {value, type} }
---@field marks table  { [mark]: {buf, row, col, filename} }
---@field label string|nil

local snapshots = {}
local MAX_SNAPSHOTS = 20
local SNAPSHOT_MAX_LINES = 500  -- max lines to capture per snapshot

--- Create a named snapshot of the current editor state.
--- Captures: current file, cursor position, buffer content (if small),
--- named register values, named marks.
---@param name string   Snapshot name (e.g. "before_refactor", "step_3")
---@param label string|nil  Optional description
---@return table  { ok, name, file, captured_registers, captured_marks, buffer_lines }
function M.snapshot_create(name, label)
  if not name or name == "" then
    return { ok = false, error = "snapshot name required" }
  end

  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local filename = vim.api.nvim_buf_get_name(buf)
  local total_lines = vim.api.nvim_buf_line_count(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)

  -- Capture buffer content if small enough
  local buffer_lines = nil
  if total_lines <= SNAPSHOT_MAX_LINES and filename ~= "" then
    buffer_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  -- Capture named registers (a-z, A-Z)
  local registers = {}
  for ch = 97, 122 do  -- a-z
    local reg = string.char(ch)
    local ok_v, val = pcall(vim.fn.getreg, reg)
    if ok_v and val and val ~= "" then
      local ok_t, rtype = pcall(vim.fn.getregtype, reg)
      registers[reg] = { value = val, type = ok_t and rtype or "v" }
    end
  end
  -- Uppercase A-Z (append registers -- less commonly set but available)
  for ch = 65, 90 do
    local reg = string.char(ch)
    local ok_v, val = pcall(vim.fn.getreg, reg)
    if ok_v and val and val ~= "" then
      local ok_t, rtype = pcall(vim.fn.getregtype, reg)
      registers[reg] = { value = val, type = ok_t and rtype or "v" }
    end
  end

  -- Capture marks (a-z, plus some specials)
  local marks = {}
  for ch = 97, 122 do
    local mark = string.char(ch)
    local ok_p, pos = pcall(vim.fn.getpos, "'" .. mark)
    if ok_p and pos and #pos >= 4 and pos[1] > 0 then
      local mbuf = pos[1]
      local mrow = pos[2]
      local mcol = pos[3]
      marks[mark] = {
        buf = mbuf,
        row = mrow,
        col = mcol,
        filename = vim.api.nvim_buf_is_valid(mbuf) and vim.api.nvim_buf_get_name(mbuf) or nil,
      }
    end
  end

  -- Prune old snapshots
  if #snapshots >= MAX_SNAPSHOTS then
    local oldest = nil
    for i, s in ipairs(snapshots) do
      if not oldest or s.time < oldest.time then oldest = i end
    end
    if oldest then table.remove(snapshots, oldest) end
  end

  local snapshot = {
    name = name,
    time = os.time(),
    file = filename ~= "" and filename or nil,
    buf = buf,
    cursor = { row = cursor[1], col = cursor[2] },
    changedtick = tick,
    buffer_lines = buffer_lines,
    registers = registers,
    marks = marks,
    label = label,
  }
  table.insert(snapshots, snapshot)

  return {
    ok = true,
    name = name,
    file = snapshot.file,
    captured_registers = compat.tbl_count(registers),
    captured_marks = compat.tbl_count(marks),
    buffer_lines = buffer_lines and #buffer_lines or nil,
  }
end

--- Restore the editor to a previously saved snapshot state.
--- Restores: file (opens it), cursor, buffer content (if captured), registers, marks.
---@param name string  Snapshot name
---@return table  { ok, name, restored }
function M.snapshot_restore(name)
  local snapshot = nil
  for _, s in ipairs(snapshots) do
    if s.name == name then snapshot = s; break end
  end
  if not snapshot then
    return { ok = false, error = "no snapshot named: " .. name }
  end

  local restored = {}

  -- Open file and set cursor
  if snapshot.file and snapshot.file ~= "" then
    local ok_ed, editor = pcall(require, "xaster.editor")
    if ok_ed then
      local buf = editor.file_ensure_open(snapshot.file, { focus = true })
      if buf then
        restored.file = snapshot.file

        -- Restore buffer content if we captured lines
        if snapshot.buffer_lines then
          -- Bypass editor lock (if active) so snapshot restore succeeds
          local ok_lock, lock = pcall(require, "xaster.lock")
          if ok_lock and lock.bypass_for_edit then
            lock.bypass_for_edit(buf)
          end
          pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, snapshot.buffer_lines)
          if ok_lock and lock.restore_after_edit then
            lock.restore_after_edit(buf)
          end
          restored.buffer_lines = #snapshot.buffer_lines
        end

        -- Restore cursor
        pcall(vim.api.nvim_win_set_cursor, 0, snapshot.cursor)
        restored.cursor = snapshot.cursor
      end
    end
  end

  -- Restore registers
  for reg, info in pairs(snapshot.registers) do
    pcall(vim.fn.setreg, reg, info.value, info.type)
  end
  restored.registers = compat.tbl_count(snapshot.registers)

  -- Restore marks
  for mark, info in pairs(snapshot.marks) do
    pcall(vim.fn.setpos, "'" .. mark, { info.buf, info.row, info.col, 0 })
  end
  restored.marks = compat.tbl_count(snapshot.marks)

  vim.cmd("redraw!")

  return { ok = true, name = name, restored = restored }
end

--- Diff two snapshots: compare buffer content, registers, and cursor.
--- Returns a structured diff showing what changed between a and b.
---@param a_name string  First snapshot name
---@param b_name string  Second snapshot name
---@return table  { ok, diff }
function M.snapshot_diff(a_name, b_name)
  local a, b = nil, nil
  for _, s in ipairs(snapshots) do
    if s.name == a_name then a = s end
    if s.name == b_name then b = s end
  end
  if not a then return { ok = false, error = "no snapshot named: " .. a_name } end
  if not b then return { ok = false, error = "no snapshot named: " .. b_name } end

  local diff = {}

  -- Compare file
  if a.file ~= b.file then
    diff.file = { from = a.file, to = b.file }
  end

  -- Compare cursor
  if a.cursor.row ~= b.cursor.row or a.cursor.col ~= b.cursor.col then
    diff.cursor = { from = a.cursor, to = b.cursor }
  end

  -- Compare buffer lines (if both captured)
  if a.buffer_lines and b.buffer_lines then
    local added, removed, changed = 0, 0, 0
    local max_i = math.max(#a.buffer_lines, #b.buffer_lines)
    for i = 1, max_i do
      local la = a.buffer_lines[i]
      local lb = b.buffer_lines[i]
      if not la and lb then
        added = added + 1
      elseif la and not lb then
        removed = removed + 1
      elseif la ~= lb then
        changed = changed + 1
      end
    end
    if added > 0 or removed > 0 or changed > 0 then
      diff.lines = { added = added, removed = removed, changed = changed }
    end
  elseif a.changedtick ~= b.changedtick then
    diff.changedtick = { from = a.changedtick, to = b.changedtick }
  end

  -- Compare registers
  local reg_diff = {}
  local all_regs = {}
  for reg, _ in pairs(a.registers) do all_regs[reg] = true end
  for reg, _ in pairs(b.registers) do all_regs[reg] = true end
  for reg, _ in pairs(all_regs) do
    local va = a.registers[reg]
    local vb = b.registers[reg]
    if not va and vb then
      reg_diff[reg] = { from = nil, to = vb.value:sub(1, 80) }
    elseif va and not vb then
      reg_diff[reg] = { from = va.value:sub(1, 80), to = nil }
    elseif va and vb and va.value ~= vb.value then
      reg_diff[reg] = { from = va.value:sub(1, 80), to = vb.value:sub(1, 80) }
    end
  end
  if next(reg_diff) then diff.registers = reg_diff end

  -- Compare marks
  local mark_diff = {}
  local all_marks = {}
  for m, _ in pairs(a.marks) do all_marks[m] = true end
  for m, _ in pairs(b.marks) do all_marks[m] = true end
  for m, _ in pairs(all_marks) do
    local ma = a.marks[m]
    local mb = b.marks[m]
    if not ma and mb then
      mark_diff[m] = { from = nil, to = string.format("%s:%d", mb.filename or "?", mb.row) }
    elseif ma and not mb then
      mark_diff[m] = { from = string.format("%s:%d", ma.filename or "?", ma.row), to = nil }
    elseif ma and mb and (ma.row ~= mb.row or ma.buf ~= mb.buf) then
      mark_diff[m] = {
        from = string.format("%s:%d", ma.filename or "?", ma.row),
        to = string.format("%s:%d", mb.filename or "?", mb.row),
      }
    end
  end
  if next(mark_diff) then diff.marks = mark_diff end

  return {
    ok = true,
    diff = diff,
    a = { name = a_name, time = a.time, label = a.label },
    b = { name = b_name, time = b.time, label = b.label },
  }
end

--- List all snapshots with metadata.
---@return table[]  Array of {name, time, file, label, has_buffer, registers, marks}
function M.snapshot_list()
  local results = {}
  for _, s in ipairs(snapshots) do
    results[#results + 1] = {
      name = s.name,
      time = s.time,
      file = s.file and s.file:match("[^/]+$") or nil,
      label = s.label,
      has_buffer = s.buffer_lines ~= nil,
      registers = compat.tbl_count(s.registers),
      marks = compat.tbl_count(s.marks),
    }
  end
  return results
end

--- Delete a snapshot by name.
---@param name string
---@return boolean existed
function M.snapshot_delete(name)
  for i, s in ipairs(snapshots) do
    if s.name == name then
      table.remove(snapshots, i)
      return true
    end
  end
  return false
end

--- Dump snapshot info for the system prompt.
---@return string
function M.snapshot_dump()
  local list = M.snapshot_list()
  if #list == 0 then return "" end

  local lines = { "Snapshots:" }
  for _, s in ipairs(list) do
    local desc = s.label or ""
    if s.file then desc = s.file .. (desc ~= "" and " -- " .. desc or "") end
    lines[#lines + 1] = string.format("  %s: %s", s.name, desc:sub(1, 80))
  end
  return table.concat(lines, "\n")
end

--- Clear all memory: fast, slow, jump stack, snapshots, marks.
--- Slow memory is intentionally cleared -- this is a full reset.
function M.clear()
  fast_store = {}
  slow_store = {}
  used_marks = {}
  agent_jump_stack = {}
  agent_jump_index = 0
  snapshots = {}
end

return M
