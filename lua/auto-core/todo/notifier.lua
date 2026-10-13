---auto-core.todo.notifier — AutoDoc's assignment changes become mailbox messages.
---
---ADR 1791532020 §2.5: AutoDoc never writes to a mailbox; auto-core turns the
---daemon's `assign` changes into messages. The daemon keeps each consumer's
---cursor: `todos.changes` answers what came after it, `todos.ack` moves it.
---
---**A consumer per Neovim** (Johno, 2026-10-13): the consumer is
---`auto-core:<instance_id>`, the same instance id the mailbox scopes its tree by.
---Each Neovim delivers only to the agents registered in its own instance, and acks
---its own cursor.
---
---**A recipient not registered here is skipped, and its change acked.** An
---assignment notice is best-effort, per instance; the task file is the record.
---Holding the cursor for an agent this Neovim does not host would stop every later
---delivery here, for an agent that may never start in it; the Neovim that hosts it
---delivers it from its own cursor.
---
---**Where a new consumer starts.** The instance id is per process, so every
---Neovim start is a new consumer, and the daemon starts a new consumer at the
---beginning of its retained log. Replaying that log would assign every retained
---task again. So the first poll of a process delivers only changes after the
---highest seq any Neovim on this machine handled (a watermark kept in
---`stdpath("state")/auto-core/todo_notifier.json`): the catch-up at Neovim start
---covers what changed while every Neovim was closed, and nothing older. With no
---watermark yet (the first poll after the cutover) it starts at the log's head.
---
---Delivery is at-least-once: the message is written (temp, fsync, rename) BEFORE
---the ack, and its id, `todo-<store_id>-<seq>`, is the same on every retry. A
---sender finding that id already in the recipient's inbox, processing or archive
---does not write it again. A resync (the consumer was away past the daemon's
---silence limit) notifies each currently assigned task once, then acks the
---page's cursor.
---@module 'auto-core.todo.notifier'

local daemon  = require("auto-core.todo.daemon")
local fs_path = require("auto-core.fs.path")

local LOG_COMPONENT = "auto-core.todo.notifier"

local M = {}

-- NOTE: can't announce. The daemon never pushes (autodoc rpc/server.go, ADR
-- §2.5): an assignment made outside this Neovim (AutoDoc's GUI, an agent's
-- `autodoc --call todos.assign`) is only seen by asking. The interval bounds that
-- delay; a tick is one todos.stores and one todos.changes per claimed store. It
-- runs only while the session is connected.
M.POLL_MS = 5000
M.PAGE = 100
-- NOTE: backoff. Reconnecting to a daemon that went away: 5 s, doubling to 60 s.
M.BACKOFF_MS = { first = 5000, max = 60000 }

local _cfg = {}          -- test overrides: poll_ms, watermark_path, ensure, page
local _running = false
local _subs = {}
local _timer, _retry = nil, nil
local _backoff = nil
local _polling, _again = false, false
local _floors = {}       -- store id → the seq this process starts after

local function log() return require("auto-core.log") end

local function warn(key, msg)
  pcall(function() log().warn_throttled("notifier:" .. key, 60000, LOG_COMPONENT, msg) end)
end

---consumer is this Neovim's consumer name.
---@return string
function M.consumer()
  return "auto-core:" .. require("auto-core.mailbox.path").get_instance_id()
end

---message_id is the mailbox id of an assign change: the same on every retry.
---@param store_id string
---@param seq integer
---@return string
function M.message_id(store_id, seq)
  return string.format("todo-%s-%d", tostring(store_id), tonumber(seq) or 0)
end

-- ─── the watermark ───────────────────────────────────────────

local function watermark_path()
  return _cfg.watermark_path or (vim.fn.stdpath("state") .. "/auto-core/todo_notifier.json")
end

local function watermarks()
  local f = io.open(watermark_path(), "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json.decode, text)
  return (ok and type(t) == "table") and t or {}
end

---watermark is the highest seq any Neovim here handled for a store, or nil.
function M.watermark(store_id)
  return tonumber(watermarks()[store_id])
end

local function bump_watermark(store_id, seq)
  local w = watermarks()
  if (tonumber(w[store_id]) or 0) >= seq then return end
  w[store_id] = seq
  local ok, err = require("auto-core.fs.atomic").write(watermark_path(), vim.json.encode(w), { mkdir = true })
  if not ok then warn("watermark", "could not save the watermark: " .. tostring(err)) end
end

-- ─── recipients ──────────────────────────────────────────────

---local_recipient is the mailbox record of an assignee registered in THIS
---instance, or nil. A bare name is tried as given, then as `agent:<name>`; a full
---id names its instance, so another Neovim's agent is never found here.
---@param assignee string
---@return table? record
function M.local_recipient(assignee)
  if type(assignee) ~= "string" or assignee == "" then return nil end
  if assignee == "user" or assignee:match("^autodoc:") then return nil end
  local registry = require("auto-core.mailbox.registry")
  local cands = { assignee }
  if not assignee:find(":", 1, true) then cands[2] = "agent:" .. assignee end
  for _, id in ipairs(cands) do
    local ok, rec = pcall(registry.get, id)
    if ok and type(rec) == "table" and rec.bare_id ~= "nvim" and rec.bare_id ~= "user" then
      return rec
    end
  end
  return nil
end

local function delivered(rec, mid)
  for _, sub in ipairs({ "inbox", "processing", "archive" }) do
    local dir = rec.subs and rec.subs[sub]
    if dir and fs_path.exists(dir .. "/" .. mid .. ".json") then return true end
  end
  return false
end

---body is the assignment message's text (moved from auto-agents' subscriber).
function M.body(p)
  local lines = {
    "You have been assigned a task.",
    "",
    string.format("  id        : %s", tostring(p.id)),
    string.format("  title     : %s", tostring(p.title or "(untitled)")),
    string.format("  file_path : %s", tostring(p.file_path or "(unknown)")),
  }
  if type(p.from) == "string" and p.from ~= "" then
    lines[#lines + 1] = string.format("  from      : %s", p.from)
  end
  if type(p.note) == "string" and p.note ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = p.note
  end
  if type(p.reason) == "string" and p.reason ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Reason: " .. p.reason
  end
  return table.concat(lines, "\n")
end

---send writes one assignment message. Runs inside daemon.run.
---@return "done"|"skip"|"retry"
local function send(at, store, rec, mid, p)
  if delivered(rec, mid) then return "done" end
  local task = daemon.rpc("todos.get", { at, p.id })
  if type(task) == "table" then
    p.title = task.title
    if type(task.path) == "string" then p.file_path = store.path .. "/" .. task.path end
  end
  local opts = {
    id = mid, to = rec.id, from = "nvim", kind = "message",
    subject = "[todos] task assigned to you: " .. tostring(p.title or p.id),
    body = M.body(p),
  }
  local built, berr = require("auto-core.mailbox.message").build(opts)
  if not built then
    -- refused for good: one bad message must not stop every later delivery
    pcall(function() log().error(LOG_COMPONENT, "assignment " .. mid .. " not sent: " .. tostring(berr)) end)
    return "skip"
  end
  local res, err = require("auto-core.mailbox").send(opts)
  if res then return "done" end
  warn("send", "assignment " .. mid .. " to " .. rec.id .. " not sent yet: " .. tostring(err))
  return "retry"
end

---effects keeps open buffers on files another client moved, and tells the panel.
local function effects(store, c)
  local function abs(p)
    if type(p) ~= "string" or p == "" then return nil end
    if p:sub(1, 1) == "/" then return p end
    return store.path .. "/" .. p
  end
  local from, to = abs(c.from_path), abs(c.to_path)
  local buffers = require("auto-core.todo.buffers")
  if not c.hand then
    if c.op == "move" and from and to and from ~= to then
      buffers.retarget(from, to)
    elseif c.op == "in-place" and (to or from) then
      buffers.reload(to or from)
    end
  end
  if c.kind == "status" or c.kind == "archive" then
    pcall(function()
      require("auto-core.events").publish("core.todo.status:changed",
        { id = c.id, from = c.from, to = c.to, at = c.at, store = store.id })
    end)
  end
end

local function ack(at, seq)
  local _, err = daemon.rpc("todos.ack", { at, M.consumer(), seq })
  if err then warn("ack", "todos.ack failed: " .. daemon.format(err)) end
  return err == nil
end

---poll_store reads one store's changes and delivers its assignments. Runs
---inside daemon.run.
local function poll_store(store)
  local roots = daemon.list_of(store.roots)
  if type(roots[1]) ~= "string" or type(store.id) ~= "string" then return end
  local at = { root = roots[1] }
  local page_size = _cfg.page or M.PAGE
  local floor = _floors[store.id]
  if floor == nil then floor = M.watermark(store.id) end
  while true do
    local page, err = daemon.rpc("todos.changes", { at, M.consumer(), page_size })
    if err then
      warn("changes", "todos.changes failed for " .. tostring(store.path) .. ": " .. daemon.format(err))
      return
    end
    page = page or {}
    local cursor = tonumber(page.cursor) or 0
    if page.resync then
      -- Away past the daemon's silence limit: the log was dropped for us.
      for _, row in ipairs(daemon.list_of(page.snapshot)) do
        local rec = M.local_recipient(row.assignee)
        if rec then
          local mid = string.format("todo-%s-r%d-%s", store.id, cursor, tostring(row.id))
          if send(at, store, rec, mid, { id = row.id,
            note = "Sent again after a resync: the original reason was lost." }) == "retry" then
            return -- not acked: the next poll resyncs again
          end
        end
      end
      if ack(at, cursor) then bump_watermark(store.id, cursor) end
      _floors[store.id] = cursor
      return
    end
    if floor == nil then floor = cursor end -- no watermark yet: start at the head
    _floors[store.id] = floor
    local changes = daemon.list_of(page.changes)
    local last, stopped, any = nil, false, false
    for _, c in ipairs(changes) do
      local seq = tonumber(c.seq) or 0
      if seq > floor then
        if c.kind == "assign" then
          local rec = M.local_recipient(c.to)
          if rec and send(at, store, rec, M.message_id(store.id, seq),
            { id = c.id, from = c.from, reason = c.reason }) == "retry" then
            stopped = true
            break
          end
        end
        effects(store, c)
        any = true
      end
      last = seq
    end
    if any then
      pcall(function()
        require("auto-core.events").publish("core.todo:changed", { kind = "changes", store = store.id })
      end)
    end
    if last then
      if ack(at, last) then bump_watermark(store.id, last) end
    end
    if stopped or #changes < page_size then return end
  end
end

---poll_all polls every claimed store, one poll at a time; a request during a poll
---runs one more after it.
function M.poll_all(done)
  if _polling then
    _again = true
    return
  end
  _polling = true
  daemon.run(function()
    local list, err = daemon.rpc("todos.stores", {})
    if err then
      warn("stores", "todos.stores failed: " .. daemon.format(err))
      return
    end
    for _, s in ipairs(daemon.list_of(list)) do
      if type(s) == "table" and s.claimed == true then poll_store(s) end
    end
  end, function(ok, err)
    _polling = false
    if not ok then warn("poll", "poll failed: " .. tostring(err)) end
    if _again then
      _again = false
      return M.poll_all(done)
    end
    if done then done() end
  end)
end

---poll_soon polls now (after an assignment this Neovim made). A no-op while the
---notifier is not running.
function M.poll_soon()
  if _running then M.poll_all() end
end

-- ─── lifecycle ───────────────────────────────────────────────

local function stop_timer(t)
  if t then pcall(function() t:stop(); t:close() end) end
end

local function start_timer()
  local ms = _cfg.poll_ms
  if ms == nil then ms = M.POLL_MS end
  if _timer or not ms or ms <= 0 then return end
  _timer = vim.uv.new_timer()
  _timer:start(ms, ms, vim.schedule_wrap(function()
    if _running then M.poll_all() end
  end))
end

local connect

local function on_connected()
  if not _running then return end
  _backoff = nil
  stop_timer(_retry); _retry = nil
  start_timer()
  M.poll_all() -- the catch-up: the cursor is the daemon's
end

local function schedule_reconnect()
  if not _running or _retry then return end
  _backoff = _backoff and math.min(_backoff * 2, M.BACKOFF_MS.max) or M.BACKOFF_MS.first
  _retry = vim.uv.new_timer()
  _retry:start(_backoff, 0, vim.schedule_wrap(function()
    stop_timer(_retry); _retry = nil
    connect()
  end))
end

local function on_disconnected()
  stop_timer(_timer); _timer = nil
  schedule_reconnect()
end

connect = function()
  if not _running then return end
  local ensure = _cfg.ensure
  if not ensure then
    if not daemon.available() then
      pcall(function() log().debug(LOG_COMPONENT, "AutoDoc is not installed: no assignment notices") end)
      return
    end
    local ok, session = pcall(require, "autodoc.session")
    if not ok or type(session.ensure) ~= "function" then return end
    ensure = session.ensure
  end
  ensure(function(c, err)
    if c then return on_connected() end
    warn("connect", "AutoDoc is not reachable: " .. tostring(err))
    schedule_reconnect()
  end)
end

---start runs the notifier: on Neovim start (once VimEnter has fired) it
---connects, catches up, and polls every POLL_MS while connected. Started by
---the mailbox router's start; `vim.g.auto_core_todo_notifier = false` turns it
---off. Idempotent.
function M.start()
  if _running or vim.g.auto_core_todo_notifier == false then return end
  _running = true
  local ok, events = pcall(require, "auto-core.events")
  if ok then
    _subs = {
      events.subscribe("autodoc.session:connected", function() vim.schedule(on_connected) end),
      events.subscribe("autodoc.session:disconnected", function() vim.schedule(on_disconnected) end),
    }
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(connect)
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function() vim.schedule(connect) end,
    })
  end
end

---stop stops polling and reconnecting. Idempotent.
function M.stop()
  _running = false
  stop_timer(_timer); _timer = nil
  stop_timer(_retry); _retry = nil
  local ok, events = pcall(require, "auto-core.events")
  if ok then
    for _, h in ipairs(_subs) do pcall(events.unsubscribe, h) end
  end
  _subs = {}
end

function M.is_running() return _running end

-- Test seam: connect now (headless tests never see VimEnter).
function M._connect() connect() end

---Test seam: { poll_ms, watermark_path, ensure, page }.
function M._configure(cfg) _cfg = cfg or {} end

function M._reset_for_tests()
  M.stop()
  _cfg, _floors, _backoff, _polling, _again = {}, {}, nil, false, false
end

return M
