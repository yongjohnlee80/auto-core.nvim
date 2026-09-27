---auto-core.fs.scan — bounded, single-flight, asynchronous reads of ONE directory (ADR-0200 §4.1).
---
---The only way auto-family views read directory listings. Every guarantee a caller relies on lives here,
---not in the caller:
---
---  * one read per path at a time — concurrent callers share it (single-flight);
---  * a request marked `fresh` during a read is served by exactly one follow-up read (rerun), because the
---    read in flight may predate the change that prompted the request;
---  * a path is never read twice inside `MIN_INTERVAL_MS`; a request inside the window is DEFERRED to its
---    end and coalesced, never dropped — so a storm of requests becomes a bounded read rate;
---  * at most `MAX_INFLIGHT` reads run at once; the rest wait in a FIFO of paths;
---  * the main loop is never held for more than `BATCH` entries of one directory (the drain resumes from a
---    libuv timer, so pending input and timers run between batches);
---  * one waiter per (owner, path): the waiter tables and the queue are bounded by the number of distinct
---    directories the live owners asked for.
---
---Owners are TABLES compared by identity (rawequal). The module is global, so a number (a view's local
---generation counter) could equal another view's; a table cannot.
---
---Public surface:
---
---  scan.read_dir(path, owner, opts?, cb)  -- cb(res) on the main loop; res = { path, entries, err? }
---  scan.cancel(owner)                     -- drop every waiter of owner; its reruns never run
---  scan.stats()                           -- examined-work counters (tests, benchmark)
---@module 'auto-core.fs.scan'

local path_mod = require("auto-core.fs.path")

local M = {}

M.MIN_INTERVAL_MS = 250
M.MAX_INFLIGHT    = 8
M.BATCH           = 512

---@class AutoCoreScanEntry
---@field name string
---@field type "file"|"directory"|"link"|"other"
---@field target_type "file"|"directory"|nil  -- for links: the resolved target's type (nil = dangling)

---@class AutoCoreScanResult
---@field path    string
---@field entries AutoCoreScanEntry[]  -- unsorted; consumers own ordering
---@field err     string?

---@class (private) AutoCoreScanSlot
---@field state         "queued"|"deferred"|"reading"
---@field waiters       table<table, fun(res: AutoCoreScanResult)>
---@field rerun_waiters table<table, fun(res: AutoCoreScanResult)>
---@field timer         uv.uv_timer_t?

---@type table<string, AutoCoreScanSlot>
local _slots = {}
---@type string[]
local _queue = {}
---@type table<string, integer>
local _last = {}
local _inflight = 0
-- Bumped by _reset_for_tests: a read started before a reset must not touch the state that replaced it.
local _epoch = 0
local _stats = { reads = 0, entries = 0, coalesced = 0, deferred = 0, cancelled = 0 }

local start_read -- forward

local function is_empty(t) return next(t) == nil end

local function pump()
  while _inflight < M.MAX_INFLIGHT and #_queue > 0 do
    local path = table.remove(_queue, 1)
    local slot = _slots[path]
    if slot and slot.state == "queued" then start_read(path, slot) end
  end
end

-- Place a slot that has waiters but no read yet: deferred while inside the interval, else queued.
local function schedule(path, slot)
  local last = _last[path]
  local wait = last and (M.MIN_INTERVAL_MS - (vim.uv.now() - last)) or 0
  if wait > 0 then
    slot.state = "deferred"
    _stats.deferred = _stats.deferred + 1
    local timer = vim.uv.new_timer()
    slot.timer = timer
    timer:start(wait, 0, vim.schedule_wrap(function()
      timer:stop()
      timer:close()
      if _slots[path] ~= slot or slot.timer ~= timer then return end
      slot.timer = nil
      slot.state = "queued"
      _queue[#_queue + 1] = path
      pump()
    end))
    return
  end
  slot.state = "queued"
  _queue[#_queue + 1] = path
  pump()
end

local function finish(path, slot, res, epoch)
  if epoch ~= _epoch then return end
  _inflight = _inflight - 1
  _last[path] = vim.uv.now()
  local waiters = slot.waiters
  slot.waiters = {}
  for _, cb in pairs(waiters) do
    local ok, err = pcall(cb, res)
    if not ok then
      pcall(function()
        require("auto-core.log").error("fs.scan", "read_dir callback failed: " .. tostring(err),
          { fields = { path = path } })
      end)
    end
  end
  if is_empty(slot.rerun_waiters) then
    if is_empty(slot.waiters) then
      _slots[path] = nil
    else
      schedule(path, slot)  -- a non-fresh request arrived during delivery
    end
  else
    slot.waiters, slot.rerun_waiters = slot.rerun_waiters, {}
    schedule(path, slot)
  end
  pump()
end

-- Resolve link targets asynchronously, then finish. `pending` counts outstanding stats.
local function resolve_links(path, slot, entries, links, epoch)
  if #links == 0 then
    return finish(path, slot, { path = path, entries = entries }, epoch)
  end
  local pending = #links
  for _, e in ipairs(links) do
    vim.uv.fs_stat(path .. "/" .. e.name, function(_, st)
      vim.schedule(function()
        if st then
          local t = st.type == "directory" and "directory" or "file"
          if e.type == "link" then e.target_type = t else e.type = t end
        end
        pending = pending - 1
        if pending == 0 then finish(path, slot, { path = path, entries = entries }, epoch) end
      end)
    end)
  end
end

start_read = function(path, slot)
  slot.state = "reading"
  _inflight = _inflight + 1
  _stats.reads = _stats.reads + 1
  local epoch = _epoch
  vim.uv.fs_scandir(path, function(err, handle)
    vim.schedule(function()
      if err or not handle then
        return finish(path, slot, { path = path, entries = {}, err = tostring(err) }, epoch)
      end
      local entries, links = {}, {}
      local function drain()
        for _ = 1, M.BATCH do
          local name, typ = vim.uv.fs_scandir_next(handle)
          if not name then return resolve_links(path, slot, entries, links, epoch) end
          _stats.entries = _stats.entries + 1
          local e = { name = name }
          if typ == "file" or typ == "directory" then
            e.type = typ
          elseif typ == "link" or typ == nil or typ == "unknown" then
            -- `unknown` comes from filesystems whose readdir carries no d_type; stat decides.
            e.type = typ == "link" and "link" or "other"
            links[#links + 1] = e
          else
            e.type = "other"
          end
          entries[#entries + 1] = e
        end
        if epoch ~= _epoch then return end
        -- Yield THROUGH libuv, not via vim.schedule: nvim drains callbacks scheduled from a scheduled
        -- callback in the same pass, so a vim.schedule chain never lets input or timers in. A 0 ms timer
        -- fires only after the loop has polled for I/O.
        local t = vim.uv.new_timer()
        t:start(0, 0, function()
          t:close()
          vim.schedule(drain)
        end)
      end
      drain()
    end)
  end)
end

---Read one directory. See the module header for the guarantees.
---@param path  string
---@param owner table   compared by identity; one waiter per (owner, path)
---@param opts  { fresh: boolean? }?
---@param cb    fun(res: AutoCoreScanResult)
function M.read_dir(path, owner, opts, cb)
  assert(type(owner) == "table", "auto-core.fs.scan.read_dir: owner must be a table (compared by identity)")
  assert(type(cb) == "function", "auto-core.fs.scan.read_dir: cb must be a function")
  path = path_mod.normalize(path)
  local fresh = opts and opts.fresh == true
  local slot = _slots[path]
  if not slot then
    slot = { waiters = { [owner] = cb }, rerun_waiters = {} }
    _slots[path] = slot
    schedule(path, slot)
    return
  end
  _stats.coalesced = _stats.coalesced + 1
  if slot.state == "reading" and fresh then
    slot.waiters[owner] = nil
    slot.rerun_waiters[owner] = cb
  elseif slot.state == "reading" and slot.rerun_waiters[owner] then
    slot.rerun_waiters[owner] = cb  -- already owed a fresh result; keep it fresh
  else
    -- queued/deferred: the read has not started, so it already postdates any change.
    slot.waiters[owner] = cb
  end
end

---Drop every waiter of `owner`. A read already running completes (libuv cannot abort it) but delivers
---nothing to `owner`; a slot left with no waiters is removed and its rerun never runs.
---@param owner table
function M.cancel(owner)
  if type(owner) ~= "table" then return end
  for path, slot in pairs(_slots) do
    local had = slot.waiters[owner] ~= nil or slot.rerun_waiters[owner] ~= nil
    slot.waiters[owner] = nil
    slot.rerun_waiters[owner] = nil
    if had then _stats.cancelled = _stats.cancelled + 1 end
    if slot.state ~= "reading" and is_empty(slot.waiters) and is_empty(slot.rerun_waiters) then
      if slot.timer then
        pcall(slot.timer.stop, slot.timer)
        pcall(slot.timer.close, slot.timer)
        slot.timer = nil
      end
      _slots[path] = nil
      for i = #_queue, 1, -1 do
        if _queue[i] == path then table.remove(_queue, i) end
      end
    end
  end
end

---@return { reads: integer, entries: integer, coalesced: integer, deferred: integer, cancelled: integer,
---          inflight: integer, queued: integer, slots: integer }
function M.stats()
  local slots = 0
  for _ in pairs(_slots) do slots = slots + 1 end
  return {
    reads = _stats.reads, entries = _stats.entries, coalesced = _stats.coalesced,
    deferred = _stats.deferred, cancelled = _stats.cancelled,
    inflight = _inflight, queued = #_queue, slots = slots,
  }
end

---Test-only: forget every slot and counter. Timers of deferred slots are stopped.
function M._reset_for_tests()
  for _, slot in pairs(_slots) do
    if slot.timer then pcall(slot.timer.stop, slot.timer); pcall(slot.timer.close, slot.timer) end
  end
  _slots, _queue, _last, _inflight = {}, {}, {}, 0
  _epoch = _epoch + 1
  _stats = { reads = 0, entries = 0, coalesced = 0, deferred = 0, cancelled = 0 }
end

return M
