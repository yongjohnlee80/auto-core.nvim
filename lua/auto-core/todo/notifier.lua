---auto-core.todo.notifier — AutoDoc's assignment changes reach this Neovim's agents.
---
---ADR 1791532020 §2.5: auto-core turns the daemon's `assign` changes into notices
---for the assignee. The daemon keeps each consumer's cursor: `todos.changes`
---answers what came after it, `todos.ack` moves it.
---
---**How a notice reaches the agent** (v0.6.0: no file mailbox, ADR 1793271500
---phase 5). The host's crew hook (`set_crew_recipient`) sends it through AutoDoc's
---crew. One the crew doesn't take goes to the host's fallback (`set_fallback`),
---which types it into the agent's terminal. With neither set, it is dropped with
---one log line: nothing is ever written to a file.
---
---**A consumer per Neovim** (Johno, 2026-10-13): the consumer is
---`auto-core:<instance_id>` (`auto-core.instance`). Each Neovim tells only the
---agents it runs, and acks its own cursor.
---
---**A bare assignee is its own project's agent** (ADR 1791532020 r15 §2.5a). Every
---Neovim reads the one change log, so an assignment carries its assigner's scope
---(`auto-core.todo.scope`, set by the host), and a bare `agent:<name>` is
---delivered only by a Neovim of that scope; one with no scope (a legacy change, a
---hand edit, an unscoped `--call`) by none. A full `agent:<name>:<instance>` is
---delivered by its instance alone, as before.
---
---**A recipient the fallback can't type to yet is HELD** for a grace window counted
---from this process's notifier start (`GRACE_MS`, 10 min): agents spawn after Neovim
---starts, and the catch-up must reach them (ADR §2.5). The cursor is acked only up
---to the change before the first held one; later changes are still delivered, and
---re-reading them on the next poll types nothing twice (this process remembers what
---it typed). A spawn asks for a poll at once (`poll_soon`). Past the window a
---recipient still not reached is skipped and acked, with one audit line: an
---assignment notice is best-effort per instance, and the task file is the record.
---`user` and `autodoc:*` are skipped at once. The watermark only ever passes
---handled changes.
---
---**Where a new consumer starts.** The instance id is per process, so every
---Neovim start is a new consumer, and the daemon starts a new consumer at the
---beginning of its retained log. Replaying that log would assign every retained
---task again. So the first poll of a process delivers only changes after the
---highest seq any Neovim on this machine handled (the watermark: one file per
---process under `stdpath("state")/auto-core/todo_notifier/`, each written only by
---its own process, the maximum across them read): the catch-up at Neovim start
---covers what changed while every Neovim was closed, and nothing older. With no
---watermark for a store yet (a new project's store, or one no Neovim here ever
---acked), its history from before this notifier started is skipped by each
---change's time (`at`, less START_SKEW_MS), and every change made since is
---delivered: an assignment written between Neovim's start and its first poll of
---the store is never lost. A change that carries no time falls back to the log's
---head, as before, with one warning.
---
---Delivery is at-least-once: the notice is sent BEFORE the ack, keyed by its id,
---`todo-<store_id>-<seq>`, the same on every retry. The crew keys its send by it,
---and the fallback (auto-agents' handler keeps the keys it typed) answers a key it
---has already typed without typing it again. A resync (the consumer was away past
---the daemon's silence limit) notifies each currently assigned task once, then
---acks the page's cursor.
---@module 'auto-core.todo.notifier'

local daemon  = require("auto-core.todo.daemon")

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
-- NOTE: deadline. A change whose recipient the fallback can't type to yet (no
-- agent of that name runs here) is HELD this long, counted from this process's notifier start, so an agent
-- spawned after Neovim started still gets the catch-up (ADR §2.5: an assignment
-- made while Neovim was closed is still delivered). Past it, the change is
-- skipped and acked (one audit line). Configurable: set M.GRACE_MS before the
-- notifier starts.
M.GRACE_MS = 10 * 60 * 1000
-- START_SKEW_MS: with no watermark, a change at least this much older than the
-- notifier's start is history (skipped); anything later is delivered. Configurable
-- (`skew_ms`) for tests.
M.START_SKEW_MS = 2000
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
local _unsure = {}       -- message id → ms (hrtime) the crew's send first had no outcome
-- _crew_recipient, when a host sets it (set_crew_recipient), sends an assignment to an agent the
-- crew delivers to, through AutoDoc's crew (ADR 1793489028 §4.7), keyed by its message id: once the
-- crew accepts it, the fallback is never asked. Unset, every assignment goes to the fallback.
local _crew_recipient = nil
-- _fallback, when a host sets it (set_fallback), types an assignment the crew didn't take into the
-- agent's terminal. _typed holds the message ids it typed in this process; _no_fallback_said, that
-- the missing fallback was logged.
local _fallback = nil
local _typed = {}
local _no_fallback_said = false
local _started_at = nil  -- ms (hrtime) when this process's notifier started
local _started_wall = nil -- s (Unix, whole) when this process's notifier started
local _timed = {}        -- store id → true while its history, with no watermark, is skipped by time

local function log() return require("auto-core.log") end

local function warn(key, msg)
  pcall(function() log().warn_throttled("notifier:" .. key, 60000, LOG_COMPONENT, msg) end)
end

---consumer is this Neovim's consumer name.
---@return string
function M.consumer()
  return "auto-core:" .. require("auto-core.instance").id()
end

---message_id is the key of an assign change's notice: the same on every retry.
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

local function own_instance() return require("auto-core.instance").id() end

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

-- ─── the notice ──────────────────────────────────────────────

---ASSIGNED heads every assignment message: it states the assignment, not who made it (the user in
---Neovim or AutoDoc, or a peer managing an epic's workload: the store doesn't know which).
M.ASSIGNED = "You've been assigned a new task."

---body is the assignment message's text: it states the assignment (M.ASSIGNED), names the task and
---its previous assignee (p.from), and quotes p.reason line by line as the task's note, so a reason
---that reads as an instruction never stands as the message's own words. It names no assigner.
function M.body(p)
  local lines = {
    M.ASSIGNED,
    "",
    string.format("  id        : %s", tostring(p.id)),
    string.format("  title     : %s", tostring(p.title or "(untitled)")),
    string.format("  file_path : %s", tostring(p.file_path or "(unknown)")),
  }
  if type(p.from) == "string" and p.from ~= "" then
    lines[#lines + 1] = string.format("  previous  : %s", p.from)
  end
  if type(p.note) == "string" and p.note ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = p.note
  end
  if type(p.reason) == "string" and p.reason ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Note:"
    for line in (p.reason:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = "  > " .. line:gsub("\r", "")
    end
  end
  return table.concat(lines, "\n")
end

---describe fills p's title and file path from the task, once. Runs inside daemon.run.
local function describe(at, store, p)
  if p.described then return end
  p.described = true
  local task = daemon.rpc("todos.get", { at, p.id })
  if type(task) == "table" then
    p.title = task.title
    if type(task.path) == "string" then p.file_path = store.path .. "/" .. task.path end
  end
end

---subject is the assignment message's subject. A notice, never "Task: …": the crew sends it as the
---user, and a request from the user with that subject is the user's own instruction to its agent,
---while this assignment may be a peer's (a bare `todos.add`), whose reason says who made it.
local function subject(p) return "[todos] task assigned to you: " .. tostring(p.title or p.id) end

local function now_ms() return vim.uv.hrtime() / 1e6 end

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

---unix_of is a change's time (`at`: RFC 3339, any offset, or Unix seconds or ms)
---in whole Unix seconds, truncated; nil when it carries none.
function M.unix_of(at)
  if type(at) == "number" then
    if at > 1e12 then at = at / 1000 end
    return math.floor(at)
  end
  if type(at) ~= "string" then return nil end
  local y, mo, d, h, mi, sec, rest = at:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
  if not y then return nil end
  rest = rest:gsub("^%.%d+", "")
  local off
  if rest == "Z" or rest == "z" then
    off = 0
  else
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then return nil end
    off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  -- days from 1970-01-01 to y-mo-d, proleptic Gregorian (H. Hinnant's days_from_civil)
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec) - off
end

---history is whether a change, for a store with no watermark, is older than this
---notifier's start by START_SKEW_MS (true), made since (false), or carries no time
---(nil). Whole seconds: a change's truncated second before the start's, less the
---skew, happened before the start whatever its fraction.
local function history(c)
  local at = M.unix_of(c.at)
  if not at or not _started_wall then return nil end
  local skew = _cfg.skew_ms
  if skew == nil then skew = M.START_SKEW_MS end
  return at < _started_wall - math.ceil(skew / 1000)
end

local _unscoped_said = false -- the below-protocol-30 notice, once per process

---audit logs a skipped assignment once per message id.
local function audit(mid, to, why)
  if _audited[mid] then return end
  _audited[mid] = true
  pcall(function() log().info(LOG_COMPONENT, "assignment " .. mid .. " to " .. to .. " skipped: " .. why) end)
end

local function grace_ms()
  local grace = _cfg.grace_ms
  if grace == nil then grace = M.GRACE_MS end
  return grace
end

---deliver hands one assignment to the host's fallback, which types it into the agent's terminal.
---Runs inside daemon.run. A key it typed in this process is never offered again. Not typed (no
---agent of that name runs here yet, another Neovim's agent, the terminal refused, or the fallback
---raised): held inside the grace window, so a later poll asks again; past it, skipped with one audit
---line. No fallback set: skipped, said once.
---@return "done"|"hold"|"skip"
local function deliver(at, store, to, mid, p)
  if _typed[mid] then return "done" end
  if not _fallback then
    if not _no_fallback_said then
      _no_fallback_said = true
      pcall(function() log().warn(LOG_COMPONENT, "no fallback is set: an assignment the crew doesn't take "
        .. "reaches no agent (auto-agents v0.4.0 or later sets it)") end)
    end
    audit(mid, to, "the host set no fallback")
    return "skip"
  end
  describe(at, store, p)
  local recipient = to:find(":", 1, true) and to or ("agent:" .. to)
  local ok, done, why = pcall(_fallback, { recipient = recipient, key = mid, subject = subject(p), body = M.body(p) })
  if ok and done == true then
    _typed[mid] = true
    return "done"
  end
  if not ok then why = done end
  if _started_at and now_ms() - _started_at < grace_ms() then return "hold" end
  audit(mid, to, "the fallback didn't reach it within the grace window: " .. tostring(why or "no reason given"))
  return "skip"
end


---set_crew_recipient sets the host's crew send (or clears it: nil). fn(name, mid, msg, how) is asked
---for every assignment routed here, with the assignee's name (the `agent:` prefix and any instance
---stripped), its message id, msg = { kind, subject, body } and how = { unscoped = boolean }: an
---unscoped change (a legacy assignment, a hand edit, a bare --call) was made by no project, so a
---host that resolves names in its own scope first must not send it by the bare name (whichever
---Neovim sent first would pick the recipient): it sends only to the one live profile of that name,
---by name@scope, or answers not sent. It sends msg through AutoDoc's crew
---to an agent the crew delivers to, keyed by mid, so a repeat (a later poll, another Neovim with
---the same message) is the same send, and answers:
---  - true: the crew accepted it (rang, or its host carries it). The change is skipped and acked,
---    with one audit line: the fallback would tell it twice.
---  - "retry": its outcome is unknown. The change isn't acked; the next poll asks again, same mid,
---    for up to the grace window (GRACE_MS) from the first such answer. Past it, it goes to the
---    fallback, with one audit line: a possible duplicate beats a lost assignment.
---  - anything else, or an error: not the crew's, or refused for certain. It goes to the fallback.
---    A key the daemon refuses as reused (another Neovim sent the same mid with other content) is
---    refused for certain, so it goes to the fallback too.
---It runs inside the notifier's daemon.run, so it may call daemon.rpc synchronously.
---An AutoDoc window's assignment (`autodoc:<codename>`) is skipped before fn is asked: the window
---hands it over itself, so it is never sent twice.
---@param fn fun(name: string, mid: string, msg: table, how: table): boolean|string|nil
function M.set_crew_recipient(fn)
  if fn ~= nil and type(fn) ~= "function" then error("auto-core.todo.notifier.set_crew_recipient: fn must be a function or nil") end
  _crew_recipient = fn
end

---set_fallback sets the host's fallback (or clears it: nil): fn(delivery) types an assignment the crew
---didn't take into the agent's terminal, where delivery = { recipient = "agent:<name>[:<instance>]",
---key = <message id, the same on every retry>, subject, body }. It answers true once typed, or
---false, why: no agent of that name runs here yet, another Neovim's agent (the instance differs),
---or the terminal refused. A key it answered true for is never offered again in this process;
---after false (or an error) it is asked again on later polls inside the grace window, and the
---assignment is skipped past it. auto-agents (v0.4.0) sets it. With none set, an assignment the
---crew doesn't take is dropped with one log line: never an error, never a file.
---It runs inside the notifier's daemon.run.
---@param fn fun(delivery: table): boolean, string?
function M.set_fallback(fn)
  if fn ~= nil and type(fn) ~= "function" then error("auto-core.todo.notifier.set_fallback: fn must be a function or nil") end
  _fallback = fn
end

---route decides an assign change: "deliver" (to the fallback: an agent of this
---Neovim's the crew didn't take), "skip" (nobody to tell: cleared, `user`,
---`autodoc:*`, sent through the crew, another project's, another instance's) or
---"retry" (the crew's send has no outcome yet).
---
---A bare assignee is this project's agent (ADR 1791532020 r15 §2.5a): it is
---delivered only when the change's scope is this Neovim's, and one with no
---scope (a legacy assignment, a hand edit, an unscoped `--call`) by no Neovim.
---A full `agent:<name>:<instance>` names its instance, whatever the scope. An
---instance scope, `@<instance>` (a full id given at assign: its task keeps only
---the name), is delivered by that instance alone.
---Against an AutoDoc below protocol 30, which keeps no scope, the v0.5.0 rule
---stands: a bare name is told by every Neovim that runs that agent.
---@param scope any the change's scope; nil, vim.NIL or "" for none
---@param p table the message's fields (id, from, reason, note), described here for the crew's send
---@return "deliver"|"skip"|"retry"
local function route(mid, to, scope, at, store, p)
  -- `autodoc:<codename>` is an AutoDoc window's assignment, which the window hands over itself. It is
  -- skipped here, before the crew hook (and the hook below asks only for a bare name or this
  -- instance's full `agent:` id): that is what keeps the window and this notifier from sending it
  -- twice, since the window keys its send by a fresh secret, not by mid. If the window ever writes
  -- another assignee form, it must key its send by the change's mid first.
  if type(to) ~= "string" or to == "" or to == "user" or to:match("^autodoc:") then
    return "skip"
  end
  local grace = grace_ms()
  -- The scope decides first, the crew second: the hook sends under this Neovim's claim, and the
  -- daemon resolves a bare name in that scope first, so asking it for another project's assignment
  -- would hand that project's task to this project's agent of the same name.
  local sc = require("auto-core.todo.scope")
  local inst = sc.instance_of(scope)
  local unscoped = false
  local ask = true
  if inst then
    -- an instance scope routes one delivery: a full id given at assign, whose task keeps the name
    if inst ~= own_instance() then
      audit(mid, to, "it was routed to instance " .. inst .. ", not this one")
      return "skip"
    end
  elseif sc.bare(to) then
    if not sc.scoped() then
      if not _unscoped_said then
        _unscoped_said = true
        pcall(function() log().info(LOG_COMPONENT, "AutoDoc is below protocol " .. sc.PROTOCOL
          .. ": assignments carry no scope, so a bare assignee is delivered by every Neovim with that agent") end)
      end
    else
      local own = sc.get()
      if type(scope) ~= "string" or scope == "" then
        -- no project made it (a legacy assignment, a hand edit, a bare --call): the crew is asked
        -- by name, which the daemon resolves only when one live profile has it (else mail.ambiguous)
        unscoped = true
      elseif scope ~= own then
        audit(mid, to, "it was made in " .. scope .. ", and this Neovim's scope is " .. tostring(own))
        return "skip"
      end
    end
  else
    -- a full id names its instance: only that instance's Neovim asks the crew
    ask = to:match("^agent:[^:]+:(.+)$") == own_instance()
  end
  local crew = _crew_recipient
  if crew and ask then
    local name = to:gsub("^agent:", ""):gsub(":.*$", "")
    describe(at, store, p)
    local ok, sent = pcall(crew, name, mid, { kind = "message", subject = subject(p), body = M.body(p) },
      { unscoped = unscoped })
    if ok and sent == "retry" then
      local first = _unsure[mid] or now_ms()
      _unsure[mid] = first
      if now_ms() - first < grace then
        warn("crew", "assignment " .. mid .. " to " .. to .. ": the crew's send has no outcome yet")
        return "retry"
      end
      audit(mid, to, "the crew's send had no outcome within the grace window: handed to the fallback")
    end
    _unsure[mid] = nil
    if ok and sent == true then
      audit(mid, to, "sent through the crew")
      return "skip"
    end
  end
  if unscoped then
    audit(mid, to, "it records no scope (a legacy assignment, a hand edit, or an unscoped call): "
      .. "a bare assignee reaches only its own project's agent")
    return "skip"
  end
  if not ask then
    audit(mid, to, "it names another Neovim's agent")
    return "skip"
  end
  return "deliver"
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
    local params = { at, M.consumer(), page_size }
    -- say this reader honours scopes, so the daemon gives it scoped assignees (protocol 33)
    if require("auto-core.todo.scope").reads_scoped() then params[4] = true end
    local page, err = daemon.rpc("todos.changes", params)
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
        local p = { id = row.id, scope = row.scope, note = "Sent again after a resync: the original reason was lost." }
        local verdict = route(mid, row.assignee, row.scope, at, store, p)
        if verdict == "retry" then
          return -- not acked: the next poll resyncs again
        elseif verdict == "deliver" and deliver(at, store, row.assignee, mid, p) == "hold" then
          held = true
        end
      end
      if held then return end -- not acked: delivered rows are not typed twice
      if ack(at, cursor) then bump_watermark(store.id, cursor) end
      _floors[store.id] = cursor
      return
    end
    local changes = daemon.list_of(page.changes)
    if floor == nil then -- no watermark yet: this notifier's start splits history from news
      floor, _timed[store.id] = 0, true
    end
    if _timed[store.id] then
      for _, c in ipairs(changes) do
        local seq = tonumber(c.seq) or 0
        if seq > floor then
          local old = history(c)
          if old == true then
            floor = seq
          else
            _timed[store.id] = nil
            if old == nil then
              warn("time", "a change of store " .. tostring(store.id) .. " carries no time: its history is skipped to the log's head")
              floor = math.max(floor, cursor)
            end
            break
          end
        end
      end
      if #changes < page_size then _timed[store.id] = nil end -- at the head: what follows is news
    end
    _floors[store.id] = floor
    -- acked: the last change of the handled prefix (delivered, or skipped for
    -- good). A held change stops the prefix; later changes are still delivered,
    -- and the next poll reads them again from the held one, which types nothing
    -- twice (_typed).
    local acked, held, stopped, any = nil, false, false, false
    for _, c in ipairs(changes) do
      local seq = tonumber(c.seq) or 0
      local handled = true
      if seq > floor then
        if c.kind == "assign" then
          local mid = M.message_id(store.id, seq)
          local p = { id = c.id, from = c.from, reason = c.reason, scope = c.scope }
          local verdict = route(mid, c.to, c.scope, at, store, p)
          if verdict == "retry" then
            stopped = true
            break
          elseif verdict == "deliver" and deliver(at, store, c.to, mid, p) == "hold" then
            handled = false
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

---poll_soon polls now: after an assignment this Neovim made, or an agent's spawn (a
---held assignment for it is typed now, not at the next tick). A no-op while the
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
---auto-core's setup; `vim.g.auto_core_todo_notifier = false` turns it off.
---Idempotent.
function M.start()
  if _running or vim.g.auto_core_todo_notifier == false then return end
  _running = true
  _started_at = now_ms()
  _started_wall = os.time()
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

---Test seam: { poll_ms, watermark_dir, ensure, page, grace_ms, after_list,
---before_write }. after_list(names) runs between a scan's listing and its reads;
---before_write(inst, seqs) between an instance's update of its map and its write.
function M._configure(cfg) _cfg = cfg or {} end

function M._reset_for_tests()
  M.stop()
  _cfg, _floors, _backoff, _polling, _again, _waiters = {}, {}, nil, false, false, {}
  _applied, _audited, _started_at, _unsure = {}, {}, nil, {}
  _started_wall, _timed = nil, {}
  _own, _prepared, _unscoped_said = {}, false, false
  _crew_recipient = nil
  _fallback, _typed, _no_fallback_said = nil, {}, false
end

return M
