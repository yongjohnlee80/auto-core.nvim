---auto-core.todo — per-project task store (ADR-0031).
---
---This module is the canonical write path for tasks. Family plugins
---(auto-finder, auto-agents) and host scripts should call into here
---rather than touching YAML files directly.
---
---Phase 1 surface (task 4 — Core CRUD):
---  M.add(spec)               create a new task; returns its id
---  M.get(id)                 read + validate one task by id
---  M.list(opts)              filter tasks; returns array
---  M.update(id, patch)       update hand-editable content fields
---  M.remove(id)              hard-delete a task
---
---Coming in later phases: status / archive / refresh / set_todo_dir /
---known_dirs / import — see ADR-0031 §3.2 for the full surface.
---@module 'auto-core.todo'

local yaml   = require("auto-core.todo.yaml")
local schema = require("auto-core.todo.schema")
local paths  = require("auto-core.todo.paths")
local header = require("auto-core.todo.header")
local fs_path = require("auto-core.fs.path")

local M = {}

-- ─── Field-policy catalog (kept in sync with schema.lua) ──────

---Top-level fields a hand-editor (or `update()` caller) may modify.
---Anything outside this set is system-managed and refused by update().
---@type table<string, true>
local HAND_EDITABLE = {
  title       = true,
  description = true,
  notes       = true,
  priority    = true,
  assignee    = true,
  tags        = true,
  adr         = true,
  wip         = true,
  pr          = true,
  review      = true,
  links       = true,
  blocked     = true,
  -- Note: `status` IS hand-editable per ADR §2 (direct edits honored,
  -- side effects API-gated). But status changes have lifecycle-
  -- timestamp side effects (completed_at, archived_at) that are
  -- owned by the upcoming `M.status()` function (task 5). So
  -- `update()` rejects status patches and asks the caller to use
  -- `M.status(id, new)` instead. Direct YAML edits remain free.
}

-- ─── time helpers ─────────────────────────────────────────────

---Current wall-clock as ISO 8601 with explicit local offset, e.g.
---`"2026-05-25T14:32:00-07:00"`. Falls back to UTC `"Z"` if the host
---libc can't produce a `%z` offset.
---@return string
function M._now_iso()
  local s = os.date("%Y-%m-%dT%H:%M:%S%z", os.time())
  if type(s) ~= "string" then
    -- os.date() with `*t` returns a table — the absence of a leading `*`
    -- in the format above means we should always get a string, but
    -- defensively handle the API's loose typing.
    return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()))
  end
  -- Convert "+0700" / "-0700" → "+07:00" / "-07:00" for strict ISO.
  s = s:gsub("([+%-]%d%d)(%d%d)$", "%1:%2")
  -- Some libcs return empty offset; normalize to "Z" (UTC).
  if not s:match("[Z+%-]%d?%d?:?%d?%d?$") then
    s = s .. "Z"
  end
  return s
end

-- ─── filesystem helpers ───────────────────────────────────────

---Atomic write — temp file in target dir + fsync + rename. Mirror of
---`auto-core.mailbox.transport.atomic_write`. Returns `(ok, err?)`.
---Creates the parent directory if missing.
---@param final_path string
---@param text string
---@return boolean ok, string? err
local function atomic_write(final_path, text)
  local dir = fs_path.parent(final_path)
  if not fs_path.is_dir(dir) then
    local mkok, mkerr = pcall(vim.fn.mkdir, dir, "p")
    if not mkok then
      return false, "mkdir: " .. tostring(mkerr)
    end
  end
  local tmp = dir .. "/.tmp-" .. tostring(vim.uv.hrtime())
    .. "-" .. tostring(math.random(1, 1e9))
  local fd, open_err = vim.uv.fs_open(tmp, "w", 420) -- 0644
  if not fd then return false, "fs_open: " .. tostring(open_err) end
  local _, write_err = vim.uv.fs_write(fd, text, 0)
  if write_err then
    pcall(vim.uv.fs_close, fd)
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_write: " .. tostring(write_err)
  end
  pcall(vim.uv.fs_fsync, fd)
  local _, close_err = vim.uv.fs_close(fd)
  if close_err then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_close: " .. tostring(close_err)
  end
  local rok, rename_err = vim.uv.fs_rename(tmp, final_path)
  if not rok then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_rename: " .. tostring(rename_err)
  end
  return true
end

---Read a UTF-8 file into a string. Returns `(text, nil)` on success,
---`(nil, err)` otherwise.
---@param path string
---@return string? text, string? err
local function read_file(path)
  local fd, open_err = vim.uv.fs_open(path, "r", 0)
  if not fd then return nil, "fs_open: " .. tostring(open_err) end
  local stat, stat_err = vim.uv.fs_fstat(fd)
  if not stat then
    pcall(vim.uv.fs_close, fd)
    return nil, "fs_fstat: " .. tostring(stat_err)
  end
  local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
  pcall(vim.uv.fs_close, fd)
  if not data then return nil, "fs_read: " .. tostring(read_err) end
  return data
end

-- ─── current todo-dir (state integration is task 8/9) ─────────

-- For task 4, we resolve the dir purely from `paths.workspace_root()`
-- with no override. Task 9 will replace this with a state-namespace
-- lookup.
---@return string
function M._todo_dir()
  return paths.resolve_todo_dir(nil)
end

-- ─── render: validate + encode + header ───────────────────────

---Validate the task and emit the canonical YAML representation
---(header comment + body, terminated by a final newline).
---@param t table
---@return string text, string? err
local function render_task(t)
  local v = schema.validate(t)
  if not v.ok then
    return "", "schema: " .. tostring(v.err)
  end
  local body = yaml.encode(t)
  return header.emit() .. "\n\n" .. body, nil
end

-- ─── id resolution: walk buckets to find a task file ──────────

---Returns the absolute path of the on-disk file backing `id` if one
---exists in any bucket of the current todo dir; `nil` otherwise.
---@param td string  resolved todo dir
---@param id string
---@return string?
local function find_task_path(td, id)
  local fname = id .. ".yaml"
  -- Flat buckets first (cheap):
  for _, bucket in ipairs({ "open", "completed", "deferred" }) do
    local candidate = fs_path.join(td, bucket, fname)
    if fs_path.is_file(candidate) then return candidate end
  end
  -- Archived bucket is partitioned by YYYY/MM — scan two levels.
  local archived = fs_path.join(td, "archived")
  if fs_path.is_dir(archived) then
    local years = vim.fn.readdir(archived) or {}
    for _, y in ipairs(years) do
      local y_dir = fs_path.join(archived, y)
      if fs_path.is_dir(y_dir) then
        local months = vim.fn.readdir(y_dir) or {}
        for _, m in ipairs(months) do
          local candidate = fs_path.join(y_dir, m, fname)
          if fs_path.is_file(candidate) then return candidate end
        end
      end
    end
  end
  return nil
end

-- ─── public: add ──────────────────────────────────────────────

---Create a new task. `spec` is a partial that must at minimum
---provide `title`; everything else takes sensible defaults.
---
---Returns the generated id on success. Errors loudly on validation
---or write failure.
---@param spec table
---@return string id
function M.add(spec)
  if type(spec) ~= "table" then
    error("auto-core.todo.add: spec must be a table, got " .. type(spec))
  end
  if type(spec.title) ~= "string" or spec.title == "" then
    error("auto-core.todo.add: spec.title is required (non-empty string)")
  end

  local now = M._now_iso()
  local id  = spec.id or paths.make_id(now, spec.title)

  local task = schema.blank({
    id             = id,
    created        = now,
    updated        = now,
    status_changed = now,
    status         = spec.status or "open",
    title          = spec.title,
    description    = spec.description or "",
  })

  -- Copy any other hand-editable fields the caller supplied.
  for k, v in pairs(spec) do
    if HAND_EDITABLE[k] then task[k] = v end
  end

  -- Lifecycle-timestamp sanity for explicit non-open spawn (rare):
  -- callers may pass status="completed" + completed_at, or
  -- status="archived" + archived_at. We don't auto-derive these in
  -- add() — caller is responsible for supplying coherent state, and
  -- schema.validate() will reject inconsistencies.
  if spec.status == "completed" then
    task.completed_at = spec.completed_at or now
  elseif spec.status == "archived" then
    task.archived_at  = spec.archived_at  or now
    task.completed_at = spec.completed_at  -- may be nil; that's OK
  end

  local td   = M._todo_dir()
  local file = paths.task_file_path(td, id, task.status, task.archived_at)

  -- Refuse to clobber an existing task with the same id.
  if fs_path.exists(file) then
    error("auto-core.todo.add: task '" .. id .. "' already exists at " .. file)
  end
  -- Also refuse if any bucket carries the same id (rare, but possible
  -- if a manual move left a stray copy).
  local stray = find_task_path(td, id)
  if stray then
    error("auto-core.todo.add: task '" .. id .. "' already exists at " .. stray)
  end

  local text, render_err = render_task(task)
  if render_err then error("auto-core.todo.add: " .. render_err) end

  local ok, err = atomic_write(file, text)
  if not ok then error("auto-core.todo.add: write failed: " .. tostring(err)) end

  return id
end

-- ─── public: get ──────────────────────────────────────────────

---Read + validate one task by id. Returns `(task, nil)` on success,
---`(nil, err)` if the file isn't found or fails validation.
---@param id string
---@return table? task, string? err
function M.get(id)
  if type(id) ~= "string" or id == "" then
    return nil, "auto-core.todo.get: id must be a non-empty string"
  end
  local td   = M._todo_dir()
  local file = find_task_path(td, id)
  if not file then
    return nil, "task '" .. id .. "' not found in " .. td
  end
  local text, read_err = read_file(file)
  if not text then return nil, read_err end
  local dec = yaml.decode(text)
  if not dec.ok then return nil, "yaml.decode: " .. tostring(dec.err) end
  local v = schema.validate(dec.value)
  if not v.ok then return nil, "schema: " .. tostring(v.err) end
  return dec.value
end

-- ─── public: list ─────────────────────────────────────────────

---List tasks, optionally filtered. `opts` keys (all optional):
---  status     - one of the four enum values, or nil for all buckets
---  tag        - returns only tasks whose tags[] contains the value
---  assignee   - exact-match filter
---  priority   - exact-match enum filter
---  has_errors - boolean; true → only with non-empty errors[]
---
---Order: lexicographic by filename within each bucket, buckets in
---fixed order open → deferred → completed → archived (then YYYY/MM
---ascending). The 1-based index assigned by the auto-agents admin
---panel is the position in this exact ordering for the OPEN bucket.
---@param opts table?
---@return table[]
function M.list(opts)
  opts = opts or {}
  local td  = M._todo_dir()
  local out = {}

  ---@param file_path string
  ---@return table?
  local function load_and_filter(file_path)
    local text = read_file(file_path)
    if not text then return nil end
    local dec = yaml.decode(text)
    if not dec.ok then return nil end
    local task = dec.value
    if type(task) ~= "table" then return nil end
    -- Schema-validate during list as well so a corrupt file doesn't
    -- silently corrupt a result set. Invalid files are skipped (a
    -- future refresh-time validation surface will report them).
    if not schema.validate(task).ok then return nil end

    if opts.status and task.status ~= opts.status then return nil end
    if opts.assignee and task.assignee ~= opts.assignee then return nil end
    if opts.priority and task.priority ~= opts.priority then return nil end
    if opts.tag then
      local hit = false
      for _, t in ipairs(task.tags or {}) do
        if t == opts.tag then hit = true; break end
      end
      if not hit then return nil end
    end
    if opts.has_errors then
      local has = type(task.errors) == "table" and #task.errors > 0
      if not has then return nil end
    end
    return task
  end

  local function scan_flat(bucket)
    local b_dir = fs_path.join(td, bucket)
    if not fs_path.is_dir(b_dir) then return end
    local files = vim.fn.readdir(b_dir) or {}
    table.sort(files)
    for _, f in ipairs(files) do
      if f:match("%.yaml$") then
        local t = load_and_filter(fs_path.join(b_dir, f))
        if t then out[#out + 1] = t end
      end
    end
  end

  local function scan_archived()
    local a_dir = fs_path.join(td, "archived")
    if not fs_path.is_dir(a_dir) then return end
    local years = vim.fn.readdir(a_dir) or {}
    table.sort(years)
    for _, y in ipairs(years) do
      local y_dir = fs_path.join(a_dir, y)
      if fs_path.is_dir(y_dir) then
        local months = vim.fn.readdir(y_dir) or {}
        table.sort(months)
        for _, m in ipairs(months) do
          local m_dir = fs_path.join(y_dir, m)
          local files = vim.fn.readdir(m_dir) or {}
          table.sort(files)
          for _, f in ipairs(files) do
            if f:match("%.yaml$") then
              local t = load_and_filter(fs_path.join(m_dir, f))
              if t then out[#out + 1] = t end
            end
          end
        end
      end
    end
  end

  -- Status filter short-circuit: skip buckets we don't care about.
  if opts.status then
    if opts.status == "archived" then
      scan_archived()
    else
      scan_flat(opts.status)
    end
  else
    scan_flat("open")
    scan_flat("deferred")
    scan_flat("completed")
    scan_archived()
  end

  return out
end

-- ─── public: update ───────────────────────────────────────────

---Update one or more content fields on an existing task. `patch` may
---contain any of the hand-editable fields EXCEPT `status` (status
---transitions live on `M.status()`, coming in task 5). Bumps
---`updated`. Re-validates the resulting task before writing.
---@param id string
---@param patch table
---@return table? updated_task, string? err
function M.update(id, patch)
  if type(id) ~= "string" or id == "" then
    return nil, "auto-core.todo.update: id must be a non-empty string"
  end
  if type(patch) ~= "table" then
    return nil, "auto-core.todo.update: patch must be a table"
  end

  -- Refuse patches that touch managed or status fields. The caller
  -- should use `M.status(id, new)` for status changes (task 5).
  for k in pairs(patch) do
    if k == "status" then
      return nil, "auto-core.todo.update: status changes belong on M.status(id, new); refusing patch"
    end
    if not HAND_EDITABLE[k] then
      return nil, "auto-core.todo.update: field '" .. tostring(k)
        .. "' is not hand-editable (or unknown)"
    end
  end

  local td   = M._todo_dir()
  local file = find_task_path(td, id)
  if not file then return nil, "task '" .. id .. "' not found in " .. td end

  local text, read_err = read_file(file)
  if not text then return nil, read_err end
  local dec = yaml.decode(text)
  if not dec.ok then return nil, "yaml.decode: " .. tostring(dec.err) end
  local task = dec.value
  if type(task) ~= "table" then
    return nil, "task '" .. id .. "' decoded to non-table"
  end

  for k, v in pairs(patch) do task[k] = v end
  task.updated = M._now_iso()

  local v = schema.validate(task)
  if not v.ok then return nil, "schema: " .. tostring(v.err) end

  local rendered, render_err = render_task(task)
  if render_err then return nil, render_err end
  local ok, err = atomic_write(file, rendered)
  if not ok then return nil, "write: " .. tostring(err) end
  return task
end

-- ─── refresh helpers ─────────────────────────────────────────

---Approximate "older than 28 days" check on an ISO 8601 timestamp.
---Timezone-naive: extracts the YYYY-MM-DD prefix from both `iso_ts`
---and `now`, treats each as midnight in os.time's local frame, and
---compares the difference. Accuracy is within ~1 day at the edges —
---ample for a 28-day archive window. Returns false on malformed
---input (defensive — refresh shouldn't crash on garbage data).
---@param iso_ts string
---@param now_iso string
---@return boolean
local function older_than_28_days(iso_ts, now_iso)
  if type(iso_ts) ~= "string" or type(now_iso) ~= "string" then return false end
  local function date_secs(s)
    local y, mo, d = s:match("^(%d+)%-(%d+)%-(%d+)")
    if not y then return nil end
    local yn, mon, dn = tonumber(y), tonumber(mo), tonumber(d)
    if not (yn and mon and dn) then return nil end
    return os.time({
      year = yn, month = mon, day = dn,
      hour = 0, min = 0, sec = 0,
    })
  end
  local a, b = date_secs(iso_ts), date_secs(now_iso)
  if not a or not b then return false end
  return (b - a) > 28 * 86400
end

---Walk every YAML task file under `td`. Returns the list of absolute
---paths, in stable order (open → deferred → completed → archived
---YYYY/MM ascending, lexicographic within each leaf dir). Files that
---can't be statted are silently skipped.
---@param td string
---@return string[]
local function walk_task_files(td)
  local out = {}
  local function scan_flat_dir(dir)
    if not fs_path.is_dir(dir) then return end
    local files = vim.fn.readdir(dir) or {}
    table.sort(files)
    for _, f in ipairs(files) do
      if f:match("%.yaml$") then
        out[#out + 1] = fs_path.join(dir, f)
      end
    end
  end
  scan_flat_dir(fs_path.join(td, "open"))
  scan_flat_dir(fs_path.join(td, "deferred"))
  scan_flat_dir(fs_path.join(td, "completed"))
  local a_dir = fs_path.join(td, "archived")
  if fs_path.is_dir(a_dir) then
    local years = vim.fn.readdir(a_dir) or {}
    table.sort(years)
    for _, y in ipairs(years) do
      local y_dir = fs_path.join(a_dir, y)
      if fs_path.is_dir(y_dir) then
        local months = vim.fn.readdir(y_dir) or {}
        table.sort(months)
        for _, m in ipairs(months) do
          scan_flat_dir(fs_path.join(y_dir, m))
        end
      end
    end
  end
  return out
end

---Move a task file from `from_path` to `to_path` atomically. The
---write-new-then-unlink-old order matches M.status() so a crash mid-
---move leaves a duplicate that refresh can recover from on the next
---run.
---@param from_path string
---@param to_path string
---@param text string
---@return boolean ok, string? err
local function move_task(from_path, to_path, text)
  if from_path == to_path then
    -- In-place rewrite (errors:[] etc. — task 7).
    return atomic_write(from_path, text)
  end
  local wok, werr = atomic_write(to_path, text)
  if not wok then return false, werr end
  local _, uerr = vim.uv.fs_unlink(from_path)
  if uerr then
    local ok_log, log = pcall(require, "auto-core.log")
    if ok_log and log and type(log.warn) == "function" then
      pcall(log.warn, string.format(
        "[auto-core.todo.refresh] moved %s → %s but failed to unlink old: %s",
        from_path, to_path, tostring(uerr)))
    end
  end
  return true
end

-- ─── public: refresh ─────────────────────────────────────────

---Reconcile the todo directory: every readable task file is checked
---against its status (and lifecycle timestamps); if its current
---directory disagrees with the status-derived bucket, the file is
---moved. Auto-archive rule: any `status:completed` task whose
---`completed_at` is older than 28 days is transitioned to archived
---(via the same path M.status uses) — bumps `status_changed`, sets
---`archived_at`, preserves `completed_at`, moves the file.
---
---Returns a summary table:
---  {
---    scanned   = <int>,    -- total YAML files walked
---    moved     = <int>,    -- files relocated to a different bucket
---    archived  = <int>,    -- completed→archived via the 28-day rule
---    skipped   = <int>,    -- files that couldn't be parsed/validated
---  }
---
---NOTE: reference validation + errors:[] maintenance lands in task 7.
---@return table summary
function M.refresh()
  local td  = M._todo_dir()
  local now = M._now_iso()

  local summary = { scanned = 0, moved = 0, archived = 0, skipped = 0 }

  if not fs_path.is_dir(td) then return summary end

  for _, file in ipairs(walk_task_files(td)) do
    summary.scanned = summary.scanned + 1

    local text, _read_err = read_file(file)
    if not text then
      summary.skipped = summary.skipped + 1
    else
      local dec = yaml.decode(text)
      if not dec.ok or type(dec.value) ~= "table" then
        summary.skipped = summary.skipped + 1
      else
        local task = dec.value
        if not schema.validate(task).ok then
          summary.skipped = summary.skipped + 1
        else
          local needs_write = false

          -- 1. Auto-archive rule: completed → archived if completed_at
          --    is older than 28 days. The rule fires regardless of
          --    where the file currently sits on disk (a misplaced
          --    completed file STILL ages out).
          if task.status == "completed"
              and type(task.completed_at) == "string"
              and older_than_28_days(task.completed_at, now)
          then
            task.status         = "archived"
            task.status_changed = now
            task.archived_at    = now
            -- completed_at preserved (we're coming from completed).
            needs_write = true
            summary.archived = summary.archived + 1
          end

          -- 2. Compute the bucket the file SHOULD be in now.
          local target_path
          if task.status == "archived" then
            target_path = paths.task_file_path(td, task.id, "archived", task.archived_at)
          else
            target_path = paths.task_file_path(td, task.id, task.status, nil)
          end

          if needs_write or target_path ~= file then
            -- Re-validate after any auto-archive mutation so a corrupt
            -- transition doesn't slip through.
            local v = schema.validate(task)
            if not v.ok then
              summary.skipped = summary.skipped + 1
            else
              local rendered, render_err = render_task(task)
              if render_err then
                summary.skipped = summary.skipped + 1
              else
                local mok, _merr = move_task(file, target_path, rendered)
                if mok and target_path ~= file then
                  summary.moved = summary.moved + 1
                end
              end
            end
          end
        end
      end
    end
  end

  -- Best-effort event publish so consumers know to refresh their
  -- views (auto-finder panel, auto-agents admin panel).
  local ok_ev, events = pcall(require, "auto-core.events")
  if ok_ev and events and type(events.publish) == "function" then
    pcall(events.publish, "core.todo:refreshed", { summary = summary, at = now })
  end

  return summary
end

-- ─── public: status / archive — lifecycle transitions ────────

---Transition a task to a new status. Per ADR-0031 §3.2, this is the
---API path that fires side-effect events (mailbox notifications etc.
---land in task 5+ as events emit). Direct YAML `status:` edits remain
---supported but skip the event surface — by design.
---
---Lifecycle-timestamp side effects:
---  → completed: sets completed_at = now, clears archived_at
---  → archived:  sets archived_at  = now; preserves completed_at if
---               coming from completed, otherwise leaves it nil
---  → open:      clears both completed_at and archived_at
---  → deferred:  clears both completed_at and archived_at
---
---Also bumps `status_changed` to now. `updated` is NOT bumped (it
---tracks content mutations only, per the schema separation).
---
---The file is physically moved to the bucket matching the new status.
---No-op when `new` equals current status (idempotent).
---@param id string
---@param new string   one of {open, completed, deferred, archived}
---@return table? updated_task, string? err
function M.status(id, new)
  if type(id) ~= "string" or id == "" then
    return nil, "auto-core.todo.status: id must be a non-empty string"
  end
  if type(new) ~= "string" or not schema.VALID_STATUS[new] then
    return nil, "auto-core.todo.status: new status must be one of "
      .. "{open,completed,deferred,archived}; got " .. tostring(new)
  end

  local td   = M._todo_dir()
  local file = find_task_path(td, id)
  if not file then return nil, "task '" .. id .. "' not found in " .. td end

  local text, read_err = read_file(file)
  if not text then return nil, read_err end
  local dec = yaml.decode(text)
  if not dec.ok then return nil, "yaml.decode: " .. tostring(dec.err) end
  local task = dec.value
  if type(task) ~= "table" then
    return nil, "task '" .. id .. "' decoded to non-table"
  end

  local old = task.status

  -- Idempotent no-op.
  if old == new then return task end

  local now = M._now_iso()
  task.status         = new
  task.status_changed = now

  -- Lifecycle-timestamp maintenance per the rules above.
  if new == "open" or new == "deferred" then
    task.completed_at = nil
    task.archived_at  = nil
  elseif new == "completed" then
    task.completed_at = now
    task.archived_at  = nil
  elseif new == "archived" then
    task.archived_at = now
    -- completed_at preserved iff coming FROM completed (preserves
    -- "when was this done → when was this archived" history).
    if old ~= "completed" then
      task.completed_at = nil
    end
  end

  local v = schema.validate(task)
  if not v.ok then return nil, "schema: " .. tostring(v.err) end

  -- Compute new file path and atomically write + remove the old file.
  -- We write the new file FIRST, then unlink the old — so a crash
  -- between the two leaves a duplicate (recoverable by refresh) rather
  -- than a lost file.
  local new_file = paths.task_file_path(td, id, new, task.archived_at)
  local rendered, render_err = render_task(task)
  if render_err then return nil, render_err end
  local ok, err = atomic_write(new_file, rendered)
  if not ok then return nil, "write: " .. tostring(err) end

  if new_file ~= file then
    local _, unlink_err = vim.uv.fs_unlink(file)
    if unlink_err then
      -- Best-effort cleanup; the new file is the source of truth and a
      -- subsequent refresh() will reconcile a stray old file.
      local ok_log, log = pcall(require, "auto-core.log")
      if ok_log and log and type(log.warn) == "function" then
        pcall(log.warn, string.format(
          "[auto-core.todo] status(%s, %s) wrote new file but failed to unlink old: %s",
          id, new, tostring(unlink_err)))
      end
    end
  end

  -- Best-effort event publish so consumers (auto-finder panel,
  -- auto-agents admin panel) can react in-process without polling.
  local ok_ev, events = pcall(require, "auto-core.events")
  if ok_ev and events and type(events.publish) == "function" then
    pcall(events.publish, "core.todo.status:changed", {
      id   = id,
      from = old,
      to   = new,
      at   = now,
    })
  end

  return task
end

---Shorthand: `status(id, "archived")`. Irrespective of age; the
---28-day auto-archive rule lives in `refresh()` (task 6).
---@param id string
---@return table? updated_task, string? err
function M.archive(id)
  return M.status(id, "archived")
end

-- ─── public: remove ───────────────────────────────────────────

---Hard-delete a task. Returns `(true, nil)` on success or
---`(false, err)` on failure. Per ADR §3.2, deletions are auditable —
---we emit a single log line via auto-core.log (best-effort).
---@param id string
---@return boolean ok, string? err
function M.remove(id)
  if type(id) ~= "string" or id == "" then
    return false, "auto-core.todo.remove: id must be a non-empty string"
  end
  local td   = M._todo_dir()
  local file = find_task_path(td, id)
  if not file then return false, "task '" .. id .. "' not found in " .. td end

  local rok, rerr = vim.uv.fs_unlink(file)
  if not rok then return false, "fs_unlink: " .. tostring(rerr) end

  -- Best-effort audit line.
  local ok_log, log = pcall(require, "auto-core.log")
  if ok_log and log and type(log.info) == "function" then
    pcall(log.info, string.format("[auto-core.todo] removed task '%s' (was at %s)", id, file))
  end
  return true
end

return M
