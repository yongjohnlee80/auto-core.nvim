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
---**A bare assignee is its own project's agent** (ADR 1791532020 r15 §2.5a). Every
---Neovim reads the one change log, so an assignment carries its assigner's scope
---(`auto-core.todo.scope`, set by the host), and a bare `agent:<name>` is
---delivered only by a Neovim of that scope; one with no scope (a legacy change, a
---hand edit, an unscoped `--call`) by none. A full `agent:<name>:<instance>` is
---delivered by its instance alone, as before.
---
---**A recipient not registered here yet is HELD** for a grace window counted from
---this process's notifier start (`GRACE_MS`, 10 min): agents spawn after Neovim
---starts, and the catch-up must reach them (ADR §2.5). The cursor is acked only up
---to the change before the first held one; later changes are still delivered, and
---re-reading them on the next poll writes nothing twice (the sender's duplicate
---check). A new mailbox registration polls at once. Past the window a recipient
---still not registered is skipped and acked, with one audit line: an assignment
---notice is best-effort per instance, and the task file is the record. `user` and
---`autodoc:*` are skipped at once. The watermark only ever passes handled changes.
---
---**Where a new consumer starts.** The instance id is per process, so every
---Neovim start is a new consumer, and the daemon starts a new consumer at the
---beginning of its retained log. Replaying that log would assign every retained
---task again. So the first poll of a process delivers only changes after the
---highest seq any Neovim on this machine handled (the watermark: one file per
---process under `stdpath("state")/auto-core/todo_notifier/`, each written only by
---its own process, the maximum across them read): the catch-up at Neovim start
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
-- While a change is held, the cursor cannot pass it, so a poll reads one page
-- from it; the page bounds how many later changes are delivered meanwhile.
M.PAGE = 200
-- NOTE: deadline. A change whose recipient is not registered in this instance
-- is HELD this long, counted from this process's notifier start, so an agent
-- spawned after Neovim started still gets the catch-up (ADR §2.5: an assignment
-- made while Neovim was closed is still delivered). Past it, the change is
-- skipped and acked (one audit line). Configurable: set M.GRACE_MS before the
-- notifier starts.
M.GRACE_MS = 10 * 60 * 1000
-- NOTE: backoff. Reconnecting to a daemon that went away: 5 s, doubling to 60 s.
M.BACKOFF_MS = { first = 5000, max = 60000 }

local _cfg = {}          -- test overrides: poll_ms, watermark_dir, ensure, page, grace_ms, after_list, before_write
local _running = false
local _subs = {}
local _timer, _retry = nil, nil
local _backoff = nil
local _polling, _again = false, false
local _floors = {}       -- store id → the seq this process starts after
local _applied = {}      -- store id → the highest seq whose effects were applied
local _audited = {}      -- message id → true once its skip was logged
local _started_at = nil  -- ms (hrtime) when this process's notifier started

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
--
-- One file per process: <dir>/<instance_id>.json, { store id → seq }. A process
-- writes ONLY its own file (temp + rename), from its own map in memory, so no
-- process ever reads, modifies and writes another's: two Neovims cannot lose each
-- other's updates (one shared file did: A and B both read 100, B wrote 102, A
-- wrote 101, and a new Neovim started at 101 and replayed 102). A new process
-- starts each store after the MAXIMUM over every file.
--
-- Pruning. A file whose process is gone (its pid is not alive) or that has not
-- been written for the daemon's 90-day consumer silence is removed; this
-- process's own file never is. Before removing anything, the pruner writes the
-- maximum it read, for every store, into its own file: pruning never lowers the
-- maximum, which matters most when every Neovim was closed and the files of dead
-- processes are the only record (the catch-up at start).
--
-- Reading. A directory listing is not a snapshot: a pruner's create-then-remove
-- can happen during one listing, which then shows neither file, and a listed file
-- can be pruned before it is read. So a read is accepted only when the listing
-- taken after reading every file equals the one taken before; otherwise it reads
-- again (a pruner writes its own file before it removes any, so the next round
-- sees the maximum there).

local SILENCE_S = 90 * 24 * 3600 -- the daemon's consumer silence (ADR 1791532020 §2.5)
local SCAN_ROUNDS = 20           -- each extra round follows a concurrent create or remove

local _own = {}          -- instance id → { store id → seq }: what that instance wrote
local _prepared = false  -- this process pruned (once, before its first floor)

local function watermark_dir()
  return _cfg.watermark_dir or (vim.fn.stdpath("state") .. "/auto-core/todo_notifier")
end

local function own_instance() return require("auto-core.mailbox.path").get_instance_id() end

---read_json is a file's map, {} when it does not parse, nil when it is gone.
local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json.decode, text)
  return (ok and type(t) == "table") and t or {}
end

local function list_names(dir)
  local names = {}
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return names end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if name:match("^[^.].*%.json$") then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

---scan reads every process's file: name → { map, path, mtime }.
---@return table<string, { map: table, path: string, mtime: integer }>
local function scan()
  local dir = watermark_dir()
  local out = {}
  for _ = 1, SCAN_ROUNDS do
    out = {}
    local before = list_names(dir)
    if _cfg.after_list then _cfg.after_list(before) end -- test seam: a pruner runs here
    for _, name in ipairs(before) do
      local path = dir .. "/" .. name
      local map = read_json(path) -- nil: pruned meanwhile, so the listing changed
      local st = vim.uv.fs_stat(path)
      if map then out[name] = { map = map, path = path, mtime = st and st.mtime.sec or os.time() } end
    end
    if table.concat(list_names(dir), "\n") == table.concat(before, "\n") then return out end
  end
  warn("watermark", "the watermark directory kept changing while it was read")
  return out
end

---maximum is the highest seq per store across the files read.
local function maximum(files)
  local max = {}
  for _, f in pairs(files) do
    for store_id, seq in pairs(f.map) do
      local n = tonumber(seq)
      if n and n > (max[store_id] or -1) then max[store_id] = n end
    end
  end
  return max
end

---watermark is the highest seq any Neovim here handled for a store, or nil:
---where a new consumer starts.
function M.watermark(store_id)
  return maximum(scan())[store_id]
end

---write_own raises an instance's own seqs to `seqs` (store id → seq), never
---lowering one, and writes that instance's file. Only that instance writes it.
local function write_own(inst, seqs)
  local path = watermark_dir() .. "/" .. inst .. ".json"
  -- Its own file seeds the map once (the same instance after a restart): only
  -- this instance writes it, so reading it is no read-modify-write of another's.
  local w = vim.deepcopy(_own[inst] or read_json(path) or {})
  local grew = false
  for store_id, seq in pairs(seqs) do
    if (tonumber(w[store_id]) or -1) < seq then w[store_id] = seq; grew = true end
  end
  if not grew then return true end
  if _cfg.before_write then _cfg.before_write(inst, seqs) end -- test seam: another writer runs here
  local ok, err = require("auto-core.fs.atomic").write(path, vim.json.encode(w), { mkdir = true })
  if not ok then
    warn("watermark", "could not save the watermark: " .. tostring(err))
    return false
  end
  _own[inst] = w
  return true
end

local function alive(pid)
  local r, _, name = vim.uv.kill(pid, 0)
  return r == 0 or name == "EPERM"
end

---prunable is whether another process's file may go: its process is gone, or it
---was not written for the consumer silence. A name that carries no pid ages out.
local function prunable(name, f, own_name)
  if name == own_name then return false end
  if os.time() - f.mtime > SILENCE_S then return true end
  local pid = tonumber(name:match("^%d+%-(%d+)%.json$"))
  return pid ~= nil and not alive(pid)
end

---prune removes the files of processes that are gone, after writing the maximum
---it read into `inst`'s own file. Returns the names it removed.
local function prune(inst)
  local files = scan()
  local own_name = inst .. ".json"
  local doomed = {}
  for name, f in pairs(files) do
    if prunable(name, f, own_name) then doomed[#doomed + 1] = f.path end
  end
  if #doomed == 0 then return {} end
  if not write_own(inst, maximum(files)) then return {} end -- carry the maximum first
  local removed = {}
  for _, p in ipairs(doomed) do
    if os.remove(p) then removed[#removed + 1] = vim.fn.fnamemodify(p, ":t") end
  end
  return removed
end

local function prepare_once()
  if _prepared then return end
  _prepared = true
  prune(own_instance())
end

local function bump_watermark(store_id, seq)
  write_own(own_instance(), { [store_id] = seq })
end

-- Test seams: write or prune as another process would.
M._watermark_write = write_own
M._watermark_prune = prune

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

local function now_ms() return vim.uv.hrtime() / 1e6 end

local _unscoped_said = false -- the below-protocol-30 notice, once per process

---audit logs a skipped assignment once per message id.
local function audit(mid, to, why)
  if _audited[mid] then return end
  _audited[mid] = true
  pcall(function() log().info(LOG_COMPONENT, "assignment " .. mid .. " to " .. to .. " skipped: " .. why) end)
end

---route decides an assign change: "deliver" (with the recipient's record),
---"hold" (not registered here, inside the grace window) or "skip" (nobody to
---tell: cleared, `user`, `autodoc:*`, another project's, or past the window).
---
---A bare assignee is this project's agent (ADR 1791532020 r15 §2.5a): it is
---delivered only when the change's scope is this Neovim's, and one with no
---scope (a legacy assignment, a hand edit, an unscoped `--call`) by no Neovim.
---A full `agent:<name>:<instance>` names its instance, whatever the scope.
---Against an AutoDoc below protocol 30, which keeps no scope, the v0.5.0 rule
---stands: a bare name, by this instance's registry.
---@param scope any the change's scope; nil, vim.NIL or "" for none
---@return "deliver"|"hold"|"skip", table?
local function route(mid, to, scope)
  if type(to) ~= "string" or to == "" or to == "user" or to:match("^autodoc:") then
    return "skip"
  end
  local sc = require("auto-core.todo.scope")
  if sc.bare(to) then
    if not sc.scoped() then
      if not _unscoped_said then
        _unscoped_said = true
        pcall(function() log().info(LOG_COMPONENT, "AutoDoc is below protocol " .. sc.PROTOCOL
          .. ": assignments carry no scope, so a bare assignee is delivered by every Neovim with that agent") end)
      end
    else
      local own = sc.get()
      if type(scope) ~= "string" or scope == "" then
        audit(mid, to, "it records no scope (a legacy assignment, a hand edit, or an unscoped call): "
          .. "a bare assignee reaches only its own project's agent")
        return "skip"
      elseif scope ~= own then
        audit(mid, to, "it was made in " .. scope .. ", and this Neovim's scope is " .. tostring(own))
        return "skip"
      end
    end
  end
  local rec = M.local_recipient(to)
  if rec then return "deliver", rec end
  local grace = _cfg.grace_ms
  if grace == nil then grace = M.GRACE_MS end
  if _started_at and now_ms() - _started_at < grace then return "hold" end
  audit(mid, to, "no such agent registered in this Neovim within the grace window")
  return "skip"
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
  if floor == nil then prepare_once() end
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
      local held = false
      for _, row in ipairs(daemon.list_of(page.snapshot)) do
        local mid = string.format("todo-%s-r%d-%s", store.id, cursor, tostring(row.id))
        local verdict, rec = route(mid, row.assignee, row.scope)
        if verdict == "hold" then
          held = true
        elseif verdict == "deliver" and send(at, store, rec, mid, { id = row.id,
          note = "Sent again after a resync: the original reason was lost." }) == "retry" then
          return -- not acked: the next poll resyncs again
        end
      end
      if held then return end -- not acked: delivered rows are not written twice
      if ack(at, cursor) then bump_watermark(store.id, cursor) end
      _floors[store.id] = cursor
      return
    end
    if floor == nil then floor = cursor end -- no watermark yet: start at the head
    _floors[store.id] = floor
    local changes = daemon.list_of(page.changes)
    -- acked: the last change of the handled prefix (delivered, or skipped for
    -- good). A held change stops the prefix; later changes are still delivered,
    -- and the next poll reads them again from the held one, which writes nothing
    -- twice (the sender's duplicate check).
    local acked, held, stopped, any = nil, false, false, false
    for _, c in ipairs(changes) do
      local seq = tonumber(c.seq) or 0
      local handled = true
      if seq > floor then
        if c.kind == "assign" then
          local mid = M.message_id(store.id, seq)
          local verdict, rec = route(mid, c.to, c.scope)
          if verdict == "hold" then
            handled = false
          elseif verdict == "deliver" and send(at, store, rec, mid,
            { id = c.id, from = c.from, reason = c.reason }) == "retry" then
            stopped = true
            break
          end
        end
        if seq > (_applied[store.id] or 0) then
          _applied[store.id] = seq
          effects(store, c)
          any = true
        end
      end
      if not handled then held = true end
      if handled and not held then acked = seq end
    end
    if any then
      pcall(function()
        require("auto-core.events").publish("core.todo:changed", { kind = "changes", store = store.id })
      end)
    end
    if acked then
      if ack(at, acked) then bump_watermark(store.id, acked) end
    end
    if stopped or held or #changes < page_size then return end
  end
end

local _waiters = {} -- done callbacks of the requests the running poll answers

---poll_all polls every claimed store, one poll at a time; a request during a poll
---runs one more after it. done (optional) runs once the poll that covers this
---request has finished.
function M.poll_all(done)
  if done then _waiters[#_waiters + 1] = done end
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
      return M.poll_all()
    end
    local waiters = _waiters
    _waiters = {}
    for _, w in ipairs(waiters) do pcall(w) end
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
  _started_at = now_ms()
  local ok, events = pcall(require, "auto-core.events")
  if ok then
    _subs = {
      events.subscribe("autodoc.session:connected", function() vim.schedule(on_connected) end),
      events.subscribe("autodoc.session:disconnected", function() vim.schedule(on_disconnected) end),
      -- A mailbox just registered (an agent spawned): poll at once, so a held
      -- assignment for it is delivered now rather than at the next tick.
      events.subscribe("core.mailbox:registered", function()
        vim.schedule(function() if _running then M.poll_all() end end)
      end),
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

---Test seam: { poll_ms, watermark_dir, ensure, page, grace_ms, after_list,
---before_write }. after_list(names) runs between a scan's listing and its reads;
---before_write(inst, seqs) between an instance's update of its map and its write.
function M._configure(cfg) _cfg = cfg or {} end

function M._reset_for_tests()
  M.stop()
  _cfg, _floors, _backoff, _polling, _again, _waiters = {}, {}, nil, false, false, {}
  _applied, _audited, _started_at = {}, {}, nil
  _own, _prepared, _unscoped_said = {}, false, false
end

return M
