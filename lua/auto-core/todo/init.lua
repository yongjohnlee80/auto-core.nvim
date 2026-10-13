---auto-core.todo — a forwarding shim to AutoDoc's todo system (ADR 1791532020).
---
---AutoDoc's daemon owns the todo format, its rules and every write. From
---auto-core v0.3.4 this module keeps its public functions and their synchronous
---shape, so auto-agents' mailbox verbs and auto-finder keep working, but each
---call goes to the daemon's `todos.*` verbs (protocol 20) and waits for the
---answer, bounded (`auto-core.todo.daemon`). Lua's own write path is deleted, not
---bypassed: there is no Lua fallback, so without AutoDoc every call answers
---"AutoDoc required". The shim itself goes at v0.4.0 (ADR §3 step 5).
---
---  M.add(spec)               create a task; returns its id (raises on error)
---  M.get(id)                 one task, or (nil, err)
---  M.list(opts)              tasks, filtered ({status, tag, assignee, priority, has_errors})
---  M.scan() / M.scan_async   tasks and malformed files
---  M.update(id, patch)       hand-editable fields (not status, not assignee)
---  M.status(id, new) / M.archive(id)
---  M.assign(id, who, reason) assigning an open task makes it in-progress (D1)
---  M.remove(id)
---  M.remove_malformed(path)  delete one malformed file
---  M.move_store(dir)         move the store directory; its claim moves with it
---  M.refresh()               reconcile the active buckets
---  M.set_todo_dir / get_todo_dir / known_dirs
---  M.claim() / M.release()   the cutover's claim and its rollback
---
---Tasks come back with the daemon's fields (the same YAML names) plus `rev` (the
---SHA-256 the daemon checks writes against), `path` (store-relative) and
---`file_path` (absolute). The first call for a store claims it
---(`auto-core.todo.where`). Assignment notices are the notifier's
---(`auto-core.todo.notifier`); `core.todo.assignee:changed` is no longer
---published, so an older subscriber cannot deliver a second copy.
---@module 'auto-core.todo'

local daemon  = require("auto-core.todo.daemon")
local where   = require("auto-core.todo.where")
local buffers = require("auto-core.todo.buffers")
local fs_path = require("auto-core.fs.path")

-- The component axis for this module's log records (an axis, not a prefix:
-- log.warn(component, msg) takes the component first).
local LOG_COMPONENT = "auto-core.todo"

local M = {}

M.AUTOMATION_REMOVED = "automation was removed (ADR 1791532020)"

-- The daemon's statuses; `automated` went with automation.
local STATUSES = {
  open = true, ["in-progress"] = true, deferred = true, completed = true, archived = true,
}

-- The fields add accepts from a spec (the daemon's Spec).
local SPEC_FIELDS = {
  "id", "title", "description", "status", "due", "priority", "assignee",
  "tags", "adr", "review", "blocked",
}

-- ─── helpers ──────────────────────────────────────────────────

local function publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events and type(events.publish) == "function" then
    pcall(events.publish, topic, payload)
  end
end

---report tells the user once per session when AutoDoc is unreachable; other
---errors are only returned.
---@param err string
local function report(err)
  err = tostring(err)
  if err:find("AutoDoc required", 1, true) then
    where.warn_once("required", err)
  elseif err:find("did not answer", 1, true) or err:find("older than protocol 20", 1, true) then
    where.warn_once("unreachable", "auto-core.todo: " .. err)
  end
end

---op runs fn(ctx) for the session's store, inside the daemon coroutine, and
---waits. Returns (true, ...) or (false, err).
---@param fn fun(ctx: table): ...
local function op(fn)
  local res = { daemon.sync(function()
    return fn(where.ensure(where.root()))
  end) }
  if not res[1] then report(res[2]) end
  return unpack(res)
end

---Current wall-clock as ISO 8601 with its local offset, e.g.
---`"2026-05-25T14:32:00-07:00"`.
---@return string
function M._now_iso()
  local s = os.date("%Y-%m-%dT%H:%M:%S%z", os.time())
  if type(s) ~= "string" then
    return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()))
  end
  s = s:gsub("([+%-]%d%d)(%d%d)$", "%1:%2")
  if not s:match("[Z+%-]%d?%d?:?%d?%d?$") then s = s .. "Z" end
  return s
end

---decorate adds the absolute file_path to a daemon task.
local function decorate(ctx, t)
  if type(t) == "table" and type(t.path) == "string" and type(ctx.store) == "string" then
    t.file_path = ctx.store .. "/" .. t.path
  end
  return t
end

---absolute_refs resolves `$VAR/…` in adr/review with Lua's vars: callers build
---refs with Neovim's meaning of a var, and the daemon symbolizes an absolute path
---its own way (design note §3, "refs cross the wire absolute"). An unresolved
---var and a bare relative ref pass through.
---@param t table spec or patch (modified in place)
local function absolute_refs(t)
  local ok, vars = pcall(require, "auto-core.todo.vars")
  if not ok then return end
  for _, field in ipairs({ "adr", "review" }) do
    local v = t[field]
    if type(v) == "string" then v = { v }; t[field] = v end
    if type(v) == "table" then
      for i, p in ipairs(v) do
        if type(p) == "string" and p:sub(1, 1) == "$" then
          local r = vars.resolve_path(p)
          if r and r.ok and type(r.path) == "string" and r.path:sub(1, 1) == "/" then
            v[i] = r.path
          end
        end
      end
    end
  end
end

---get_task reads one task inside the coroutine; raises on error.
local function get_task(ctx, id)
  local t, err = daemon.rpc("todos.get", { ctx.at, id })
  if err then daemon.fail(err) end
  return decorate(ctx, t)
end

local function list_page(ctx, opts)
  local params = { ctx.at }
  if opts and next(opts) ~= nil then params[2] = opts end
  local l, err = daemon.rpc("todos.list", params)
  if err then daemon.fail(err) end
  return l or {}
end

local function filters_of(opts)
  local f = {}
  if type(opts) == "table" then
    if type(opts.tag) == "string" then f.tag = opts.tag end
    if type(opts.assignee) == "string" then f.assignee = opts.assignee end
    if type(opts.priority) == "string" then f.priority = opts.priority end
    if opts.has_errors then f.has_errors = true end
  end
  return f
end

local function with(f, buckets)
  local o = vim.deepcopy(f)
  if buckets then o.buckets = buckets end
  return o
end

local function malformed_entry(ctx, m)
  local rel = tostring(m.path or "")
  return {
    file_path = (ctx.store or "") .. "/" .. rel,
    bucket    = rel:match("^([^/]+)/") or "",
    filename  = fs_path.basename(rel),
    err       = tostring(m.reason or "malformed"),
  }
end

---collect lists into out: the active buckets (or one status) and, when asked,
---the archive month by month. Runs inside the coroutine.
---@param ctx table
---@param out { tasks: table[], malformed: table[] }
---@param status string? one status, or nil for every bucket
---@param f table filters
---@param part "active"|"archive"|"all"
local function collect(ctx, out, status, f, part)
  local function add(listing)
    for _, t in ipairs(daemon.list_of(listing.tasks)) do
      out.tasks[#out.tasks + 1] = decorate(ctx, t)
    end
    for _, m in ipairs(daemon.list_of(listing.malformed)) do
      out.malformed[#out.malformed + 1] = malformed_entry(ctx, m)
    end
  end
  if status and status ~= "archived" then
    add(list_page(ctx, with(f, { status })))
    return
  end
  if not status and part ~= "archive" then
    add(list_page(ctx, f))
  end
  if part == "active" and not status then return end
  local months = list_page(ctx, { buckets = { "archived" } })
  for _, p in ipairs(daemon.list_of(months.partitions)) do
    if type(p) == "table" and type(p.month) == "string" then
      add(list_page(ctx, with(f, { "archived/" .. p.month })))
    end
  end
end

-- ─── public: add / get / list / scan ─────────────────────────

---Create a task. `spec.title` is required. Returns the id; raises on error, as
---it always did. With an assignee it is an assignment: an open task becomes
---in-progress and the assignee is told (D1, ADR §2.3).
---@param spec table
---@param internal table? no longer accepted (it carried automation's origin)
---@return string id
function M.add(spec, internal)
  if type(spec) ~= "table" then
    error("auto-core.todo.add: spec must be a table, got " .. type(spec))
  end
  if type(spec.title) ~= "string" or spec.title == "" then
    error("auto-core.todo.add: spec.title is required (non-empty string)")
  end
  if spec.status == "automated" or (type(internal) == "table" and internal.origin ~= nil) then
    error("auto-core.todo.add: " .. M.AUTOMATION_REMOVED)
  end
  local s = {}
  for _, k in ipairs(SPEC_FIELDS) do
    if spec[k] ~= nil and spec[k] ~= vim.NIL then s[k] = vim.deepcopy(spec[k]) end
  end
  absolute_refs(s)
  local ok, t = op(function(ctx)
    local task, err = daemon.rpc("todos.add", { ctx.at, s })
    if err and err.code == daemon.NOT_A_STORE then
      -- a new project's store: register (done), claim (done), then scaffold
      local _, serr = daemon.rpc("todos.scaffold", { ctx.at })
      if serr then daemon.fail(serr) end
      task, err = daemon.rpc("todos.add", { ctx.at, s })
    end
    if err then daemon.fail(err) end
    return decorate(ctx, task)
  end)
  if not ok then error("auto-core.todo.add: " .. tostring(t), 0) end
  publish("core.todo:changed", { kind = "add", id = t.id })
  if type(t.assignee) == "string" and t.assignee ~= "" then
    M._poke_notifier()
  end
  return t.id
end

---One task by id: `(task)` or `(nil, err)`.
---@param id string
---@return table? task, string? err
function M.get(id)
  if type(id) ~= "string" or id == "" then
    return nil, "auto-core.todo.get: id must be a non-empty string"
  end
  local ok, t = op(function(ctx) return get_task(ctx, id) end)
  if not ok then return nil, t end
  return t
end

---List tasks. `opts` (all optional): `status` (one bucket; none lists every
---bucket, the archive included, as before), `tag`, `assignee`, `priority`,
---`has_errors`. Raises when the daemon cannot be asked.
---@param opts table?
---@return table[]
function M.list(opts)
  opts = opts or {}
  if opts.status ~= nil and not STATUSES[opts.status] then return {} end
  local ok, out = op(function(ctx)
    local o = { tasks = {}, malformed = {} }
    collect(ctx, o, opts.status, filters_of(opts), "all")
    return o.tasks
  end)
  if not ok then error("auto-core.todo.list: " .. tostring(out), 0) end
  return out
end

---Every task and every malformed file, archive included:
---`{ tasks, malformed = { {file_path, bucket, filename, err} } }`.
---@return { tasks: table[], malformed: table[] }
function M.scan()
  local ok, out = op(function(ctx)
    local o = { tasks = {}, malformed = {} }
    collect(ctx, o, nil, {}, "all")
    return o
  end)
  if not ok then error("auto-core.todo.scan: " .. tostring(out), 0) end
  return out
end

---scan for UI consumers, asynchronous: nothing is asked before it returns. The
---active buckets arrive first (`done = false`), then the archive (`done = true`),
---accumulated in one table. Cancel drops every later reply.
---@param callback fun(result: table?, done: boolean, err: string?)
---@return fun() cancel
function M.scan_async(callback)
  local cancelled = false
  local root = where.root()
  local result = { tasks = {}, malformed = {} }
  local function fail(err)
    if cancelled then return end
    cancelled = true
    report(err)
    callback(nil, true, tostring(err))
  end
  vim.schedule(function()
    if cancelled then return end
    daemon.run(function()
      collect(where.ensure(root), result, nil, {}, "active")
    end, function(ok, err)
      if cancelled then return end
      if not ok then return fail(err) end
      callback(result, false)
      if cancelled then return end
      daemon.run(function()
        collect(where.ensure(root), result, nil, {}, "archive")
      end, function(ok2, err2)
        if cancelled then return end
        if not ok2 then return fail(err2) end
        callback(result, true)
      end)
    end)
  end)
  return function() cancelled = true end
end

-- ─── public: update / status / archive / assign / remove ─────

---Change hand-editable fields: title, description, due, priority, tags, adr,
---review, blocked. `status` goes through M.status and `assignee` through
---M.assign (the daemon's rule: an assignment goes only through todos.assign).
---@param id string
---@param patch table
---@return table? task, string? err
function M.update(id, patch)
  if type(id) ~= "string" or id == "" then
    return nil, "auto-core.todo.update: id must be a non-empty string"
  end
  if type(patch) ~= "table" then
    return nil, "auto-core.todo.update: patch must be a table"
  end
  if patch.status ~= nil then
    return nil, "auto-core.todo.update: status changes belong on M.status(id, new); refusing patch"
  end
  if patch.assignee ~= nil then
    return nil, "auto-core.todo.update: an assignment goes through M.assign(id, assignee, reason) "
      .. "(todos.assign); refusing patch"
  end
  local p = vim.deepcopy(patch)
  absolute_refs(p)
  local ok, t = op(function(ctx)
    local cur = get_task(ctx, id)
    local task, err = daemon.rpc("todos.update", { ctx.at, id, cur.rev, p })
    if err then daemon.fail(err) end
    return decorate(ctx, task)
  end)
  if not ok then return nil, t end
  buffers.reload(t.file_path)
  publish("core.todo:changed", { kind = "update", id = id })
  return t
end

---move_effects keeps buffers on a task the daemon moved or rewrote, and tells
---the panel when its status changed.
local function move_effects(before, after)
  if type(before.file_path) == "string" and type(after.file_path) == "string" then
    if before.file_path ~= after.file_path then
      buffers.retarget(before.file_path, after.file_path)
    else
      buffers.reload(after.file_path)
    end
  end
  if before.status ~= after.status then
    publish("core.todo.status:changed", {
      id = after.id, from = before.status, to = after.status, at = M._now_iso(),
    })
  end
end

---Move a task to another status, with the daemon's timestamps, into its bucket.
---The same status is a no-op.
---@param id string
---@param new string open, in-progress, deferred, completed or archived
---@return table? task, string? err
function M.status(id, new)
  if type(id) ~= "string" or id == "" then
    return nil, "auto-core.todo.status: id must be a non-empty string"
  end
  if new == "automated" then
    return nil, "auto-core.todo.status: " .. M.AUTOMATION_REMOVED
  end
  if type(new) ~= "string" or not STATUSES[new] then
    return nil, "auto-core.todo.status: new status must be one of "
      .. "{open,in-progress,completed,deferred,archived}; got " .. tostring(new)
  end
  local ok, before, after = op(function(ctx)
    local cur = get_task(ctx, id)
    if cur.status == new then return cur, cur end
    local task, err = daemon.rpc("todos.status", { ctx.at, id, cur.rev, new })
    if err then daemon.fail(err) end
    return cur, decorate(ctx, task)
  end)
  if not ok then return nil, before end
  move_effects(before, after)
  return after
end

---`status(id, "archived")`.
---@param id string
---@return table? task, string? err
function M.archive(id)
  return M.status(id, "archived")
end

---Assign a task (`nil`, `""` or `vim.NIL` clears it). Assigning an open task
---makes it in-progress in the same write (D1). Assigning again, even to the same
---assignee, is a new assignment: the notifier delivers it again. A direct
---`assignee:` edit in the file stays metadata-only and notifies nobody.
---@param id string
---@param assignee string?
---@param reason string?
---@return table? task, string? err
function M.assign(id, assignee, reason)
  if type(id) ~= "string" or id == "" then
    return nil, "auto-core.todo.assign: id must be a non-empty string"
  end
  if assignee == nil or assignee == vim.NIL then assignee = "" end
  if type(assignee) ~= "string" then
    return nil, "auto-core.todo.assign: assignee must be a non-empty string or nil"
  end
  if reason ~= nil and type(reason) ~= "string" then
    return nil, "auto-core.todo.assign: reason must be a string when provided"
  end
  local ok, before, after = op(function(ctx)
    local cur = get_task(ctx, id)
    local params = { ctx.at, id, cur.rev, assignee }
    if reason and reason ~= "" then params[5] = reason end
    local task, err = daemon.rpc("todos.assign", params)
    if err then daemon.fail(err) end
    return cur, decorate(ctx, task)
  end)
  if not ok then return nil, before end
  move_effects(before, after)
  publish("core.todo:changed", { kind = "assign", id = id })
  if assignee ~= "" then M._poke_notifier() end
  return after
end

---Delete a task: `(true)` or `(false, err)`.
---@param id string
---@return boolean ok, string? err
function M.remove(id)
  if type(id) ~= "string" or id == "" then
    return false, "auto-core.todo.remove: id must be a non-empty string"
  end
  local ok, file = op(function(ctx)
    local cur = get_task(ctx, id)
    local _, err = daemon.rpc("todos.remove", { ctx.at, id, cur.rev })
    if err then daemon.fail(err) end
    return cur.file_path
  end)
  if not ok then return false, file end
  local ok_log, log = pcall(require, "auto-core.log")
  if ok_log and log and type(log.info) == "function" then
    pcall(log.info, LOG_COMPONENT, string.format("removed task '%s' (was at %s)", id, tostring(file)))
  end
  publish("core.todo:changed", { kind = "remove", id = id })
  return true
end

---Delete one malformed file of the store (an absolute path, or store-relative).
---The daemon refuses a valid task (use M.remove) and a file using the removed
---automation fields. `(true)` or `(false, err)`.
---@param file_path string
---@return boolean ok, string? err
function M.remove_malformed(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return false, "auto-core.todo.remove_malformed: a path is required"
  end
  local ok, err = op(function(ctx)
    local rel = file_path
    if rel:sub(1, 1) == "/" then
      local store = tostring(ctx.store)
      if rel:sub(1, #store + 1) ~= store .. "/" then
        daemon.fail("auto-core.todo.remove_malformed: " .. file_path .. " is not in the store " .. store)
      end
      rel = rel:sub(#store + 2)
    end
    local _, e = daemon.rpc("todos.remove_malformed", { ctx.at, rel })
    if e then daemon.fail(e) end
    return true
  end)
  if not ok then return false, err end
  publish("core.todo:changed", { kind = "remove_malformed", path = file_path })
  return true
end

-- ─── public: refresh ─────────────────────────────────────────

local function refresh_body(ctx)
  local s, err = daemon.rpc("todos.refresh", { ctx.at })
  if err then daemon.fail(err) end
  s = s or {}
  return {
    scanned    = tonumber(s.scanned) or 0,
    moved      = tonumber(s.moved) or 0,
    archived   = tonumber(s.archived) or 0,
    errors_set = tonumber(s.errors_set) or 0,
    rewritten  = tonumber(s.rewritten) or 0,
    malformed  = tonumber(s.malformed) or 0,
    skipped    = tonumber(s.malformed) or 0, -- Lua's name for the same count
  }
end

---Reconcile the active buckets (the daemon's refresh: misplaced files, errors[],
---the 28-day archive; it never reads the archive). Returns the summary; raises
---when the daemon cannot be asked.
---@return table summary
function M.refresh()
  local ok, s = op(refresh_body)
  if not ok then error("auto-core.todo.refresh: " .. tostring(s), 0) end
  publish("core.todo:refreshed", { summary = s, at = M._now_iso() })
  return s
end

---refresh without waiting (the save hook): never blocks the editor.
function M._refresh_async()
  local root = where.root()
  daemon.run(function() return refresh_body(where.ensure(root)) end, function(ok, s)
    if ok then
      publish("core.todo:refreshed", { summary = s, at = M._now_iso() })
    else
      report(s)
    end
  end)
end

-- ─── public: the store's location ────────────────────────────

---Point this project at another store directory (it must exist), or back at
---<root>/.todo-list with nil or "". Raises on error.
---@param path string?
function M.set_todo_dir(path)
  if path ~= nil and type(path) ~= "string" then
    error("auto-core.todo.set_todo_dir: path must be a string or nil, got " .. type(path))
  end
  local root = where.root()
  local dir = ""
  if path and path ~= "" then dir = fs_path.normalize(vim.fn.expand(path)) end
  local ok, err = daemon.sync(function()
    local _, e = daemon.rpc("todos.set_dir", { { root = root }, dir })
    if e then daemon.fail(e) end
    return true
  end)
  if not ok then
    report(err)
    error("auto-core.todo.set_todo_dir: " .. tostring(err), 0)
  end
  where.set_override(root, dir ~= "" and dir or nil)
  where.reset(root)
  op(function() return true end) -- resolve (and claim) the new store now
  publish("core.todo:changed", { kind = "set_dir", dir = dir })
end

---The store directory for this project. It never waits: before the daemon has
---answered once it is the directory Lua resolves (the override, else
---<root>/.todo-list), and the first resolution (and claim) starts in the
---background.
---@return string
function M.get_todo_dir()
  local root = where.root()
  local c = where.cached(root)
  if c and type(c.store) == "string" then return c.store end
  M._kick(root)
  return where.local_dir(root)
end

M._todo_dir = M.get_todo_dir

local _kicking = {}
---_kick resolves (and claims) a root's store in the background, once at a time.
function M._kick(root)
  if _kicking[root] or not daemon.available() then return end
  _kicking[root] = true
  vim.schedule(function()
    daemon.run(function() return where.ensure(root) end, function(ok, err)
      _kicking[root] = nil
      if not ok then report(err) end
    end)
  end)
end

---Move the store directory to new_path (nothing may be there yet; its parent
---must exist). The store keeps its claim, its change log and its consumers'
---cursors. Returns the new store path; raises on error.
---@param new_path string
---@return string
function M.move_store(new_path)
  if type(new_path) ~= "string" or new_path == "" then
    error("auto-core.todo.move_store: a path is required")
  end
  local to = fs_path.normalize(vim.fn.expand(new_path))
  local root = where.root()
  local ok, r = op(function(ctx)
    local res, err = daemon.rpc("todos.move_store", { ctx.at, to })
    if err then daemon.fail(err) end
    return res
  end)
  if not ok then error("auto-core.todo.move_store: " .. tostring(r), 0) end
  where.set_override(root, r.store)
  where.reset()
  publish("core.todo:changed", { kind = "move_store", dir = r.store })
  return r.store
end

---The stores the daemon knows: `{ todo_dir, workspace_roots, last_touched }`,
---sorted by todo_dir. Raises when the daemon cannot be asked.
---@return table[]
function M.known_dirs()
  local ok, list = daemon.sync(function()
    local l, err = daemon.rpc("todos.stores", {})
    if err then daemon.fail(err) end
    return l
  end)
  if not ok then
    report(list)
    error("auto-core.todo.known_dirs: " .. tostring(list), 0)
  end
  local out = {}
  for _, s in ipairs(daemon.list_of(list)) do
    out[#out + 1] = {
      todo_dir        = s.path,
      workspace_roots = daemon.list_of(s.roots),
      last_touched    = s.last_use,
      claimed         = s.claimed == true,
      store_id        = s.id,
    }
  end
  table.sort(out, function(a, b) return tostring(a.todo_dir) < tostring(b.todo_dir) end)
  return out
end

---No-op: the daemon keeps the store records now.
function M._upsert_known() end

-- ─── public: the cutover ─────────────────────────────────────

---Claim this project's store again after a rollback released it
---(:AutoCoreTodoClaim). Returns (true) or (false, err).
---@return boolean ok, string? err
function M.claim()
  local root = where.root()
  local ok, c = op(function(ctx) return ctx end)
  if not ok then return false, c end
  if c.claimed then return true end
  where.forget_release(c.store_id)
  local ok2, c2 = op(function(ctx) return ctx end)
  if not ok2 then return false, c2 end
  where.reset(root)
  return c2.claimed and true or false, (not c2.claimed) and "the store is still not claimed" or nil
end

---Release this project's store: the daemon only reads it again (the rollback,
---ADR §3 step 3). Run it only after the previous auto-core is installed. The
---rollback guard keeps this Neovim from claiming it again.
---@return boolean ok, string? err
function M.release()
  local ok, err = op(function(ctx)
    local _, e = daemon.rpc("todos.release", { ctx.at })
    if e then daemon.fail(e) end
    return true
  end)
  where.reset()
  if not ok then return false, err end
  return true
end

-- ─── public: import (dropped) ────────────────────────────────

---Import was dropped (ADR 1791532020 D3); the KB migration it served is done.
function M.import()
  error("auto-core.todo.import: import was dropped (ADR 1791532020 D3)", 0)
end

-- ─── the notifier ────────────────────────────────────────────

---_poke_notifier asks the assignment notifier to poll now (after an assignment
---this Neovim made).
function M._poke_notifier()
  pcall(function() require("auto-core.todo.notifier").poll_soon() end)
end

-- ─── public: vars submodule (v0.1.40) ─────────────────────────

---`$VAR/…` resolution and the user's vars (`auto-core.todo.vars`), re-exposed.
M.vars = setmetatable({}, {
  __index = function(_, k)
    return require("auto-core.todo.vars")[k]
  end,
})

return M
