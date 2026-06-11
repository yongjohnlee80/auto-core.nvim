---Filesystem-layout helpers for the auto-core todo task store.
---
---Per ADR-0031 §3.1, workspace resolution is auto-core's
---responsibility — callers of this module receive resolved absolute
---paths; they do not pass `workspace_root` or `cwd`. The override
---layer (state namespace `todo.dir_overrides`) wires in via the
---public API surface in `auto-core.todo` (task 9); functions here
---accept an optional explicit override so callers can short-circuit
---the state lookup when they already know the answer.
---@module 'auto-core.todo.paths'

local fs_path = require("auto-core.fs.path")

local M = {}

---Bucket directories per ADR-0031 §1 (`dir == status` invariant),
---extended by ADR-0035 with `in-progress` and `automated`. Indexed
---by status enum value. The directory name on disk equals the status
---string verbatim — including the hyphenated `in-progress/`.
M.BUCKETS = {
  open            = "open",
  ["in-progress"] = "in-progress",  -- ADR-0035 Phase 1
  automated       = "automated",    -- ADR-0035 Phase 1
  completed       = "completed",
  deferred        = "deferred",
  archived        = "archived",     -- nested by YYYY/MM under here
}

---Flat (non-archived) buckets in canonical scan order. Used by
---`auto-core.todo.init`'s `find_task_path` / `list` / `scan` /
---`walk_task_files` / `refresh` to avoid the prior pattern of
---hard-coding the bucket-name list at every call site. Order chosen
---to mirror auto-finder's panel ordering (open → in-progress →
---automated → deferred → completed) — purely cosmetic for callers
---that iterate, but keeps debug output / log lines aligned with how
---the user sees the buckets in the panel.
M.FLAT_BUCKETS = {
  "open",
  "in-progress",
  "automated",
  "deferred",
  "completed",
}

-- ── workspace resolution ──────────────────────────────────────

---Resolve the canonical workspace root for the current session. Order
---of resolution mirrors `auto-core.mailbox.path.workspace_mailbox_root`:
---  1. `auto-core.git.worktree.get_workspace_root()` — the explicit
---     auto-core-set workspace.
---  2. `auto-core.git.worktree.get_active()` — the active worktree
---     path (if a workspace_root isn't set but a worktree is).
---  3. `vim.fn.getcwd()` — last-resort fallback for early-boot or
---     test scenarios.
---@return string absolute path
function M.workspace_root()
  local ok, worktree = pcall(require, "auto-core.git.worktree")
  if ok and worktree then
    local ws = worktree.get_workspace_root()
    if ws and ws ~= "" then
      return fs_path.normalize(ws)
    end
    local active = worktree.get_active()
    if active and active ~= "" then
      return fs_path.normalize(active)
    end
  end
  return fs_path.normalize(vim.fn.getcwd())
end

-- ── todo-dir resolution ───────────────────────────────────────

---Default todo-dir path for a given workspace root.
---@param ws_root string
---@return string absolute path
function M.default_todo_dir(ws_root)
  return fs_path.normalize(fs_path.join(ws_root, ".todo-list"))
end

---INTERNAL — pure helper. **External callers MUST NOT use this to
---"get the active todo-dir".** Call `require("auto-core.todo")
---.get_todo_dir()` instead — it is the single override-aware
---resolver (the one source of truth) every component shares.
---
---Why this warning exists (2026-06-01 bug, see
---[[shared-resolver-single-source-of-truth]] convention): callers
---that did `resolve_todo_dir(nil)` got the `<workspace>/.todo-list`
---FALLBACK, silently ignoring the `todo.dir_overrides` state. On a
---KB-rooted store (override set via `set_todo_dir`) that points at
---a tree which doesn't hold the tasks — producing silent no-ops
---(auto-finder scaffold) and broken managed writes (automation
---`last_fired_at` debounce). This footgun bit twice.
---
---This function takes an EXPLICIT `override` and stays pure (no
---state access) precisely so it's testable; the stateful entry
---`auto-core.todo.get_todo_dir()` reads `dir_overrides` and
---delegates here with the resolved value. If you find yourself
---about to call `resolve_todo_dir(nil)`, you want `get_todo_dir()`.
---@param override string?  REQUIRED for external use; nil = workspace fallback (internal only)
---@return string absolute path
function M.resolve_todo_dir(override)
  if type(override) == "string" and override ~= "" then
    return fs_path.normalize(vim.fn.expand(override))
  end
  return M.default_todo_dir(M.workspace_root())
end

-- ── bucket helpers ────────────────────────────────────────────

---Directory the task file with this status should live in. For
---non-archived statuses this is `<todo_dir>/<bucket>`. For archived
---you must call `archive_bucket(todo_dir, archived_at)` instead
---because the archived bucket is partitioned by year + month.
---@param todo_dir string
---@param status string
---@return string
function M.bucket_dir(todo_dir, status)
  local b = M.BUCKETS[status]
  if not b then
    error("auto-core.todo.paths.bucket_dir: unknown status '" .. tostring(status) .. "'")
  end
  if status == "archived" then
    error("auto-core.todo.paths.bucket_dir: use archive_bucket(todo_dir, archived_at) for archived tasks")
  end
  return fs_path.normalize(fs_path.join(todo_dir, b))
end

---Directory for an archived task, partitioned by archived_at's
---year and month. The `archived_at` argument is an ISO 8601 datetime
---string (e.g. `"2026-06-17T10:00:00Z"` or `"2026-06-17T10:00:00-07:00"`).
---@param todo_dir string
---@param archived_at string
---@return string
function M.archive_bucket(todo_dir, archived_at)
  if type(archived_at) ~= "string" then
    error("auto-core.todo.paths.archive_bucket: archived_at must be an ISO string, got "
      .. type(archived_at))
  end
  local y, m = archived_at:match("^(%d%d%d%d)%-(%d%d)%-%d%d")
  if not y then
    error("auto-core.todo.paths.archive_bucket: archived_at '" .. archived_at
      .. "' is not in ISO YYYY-MM-DD… form")
  end
  return fs_path.normalize(fs_path.join(todo_dir, M.BUCKETS.archived, y, m))
end

---Absolute filesystem path for a task file given the resolved
---`todo_dir`, the task's `status`, and (only when archived) its
---`archived_at` ISO string. Includes the `.md` extension.
---@param todo_dir string
---@param id string
---@param status string
---@param archived_at string?
---@return string
function M.task_file_path(todo_dir, id, status, archived_at)
  local parent
  if status == "archived" then
    parent = M.archive_bucket(todo_dir, archived_at or "")
  else
    parent = M.bucket_dir(todo_dir, status)
  end
  return fs_path.normalize(fs_path.join(parent, id .. ".md"))
end

-- ── canonical bucket walk (ADR-0038 Batch C) ──────────────────

---Visit every task file under `td` in stable order — FLAT_BUCKETS
---order, then `archived/YYYY/MM` ascending, lexicographic within
---each leaf dir — invoking `on_file(file_path, bucket)` per `.md`
---file. This is THE walk implementation behind `todo.list` /
---`todo.scan` / refresh's file enumeration; the prior three
---hand-rolled copies in `todo/init.lua` drifted independently
---(and the same duplication class shipped the v0.1.47
---override-dir bug in automation's managed-field writer).
---
---`bucket_filter` narrows the walk: a flat status name visits only
---that bucket dir; `"archived"` visits only the archived tree; nil
---visits everything.
---@param td string                                  resolved todo dir
---@param on_file fun(file_path: string, bucket: string)
---@param bucket_filter string?
function M.walk(td, on_file, bucket_filter)
  local function scan_leaf(dir, bucket)
    if not fs_path.is_dir(dir) then return end
    local files = vim.fn.readdir(dir) or {}
    table.sort(files)
    for _, f in ipairs(files) do
      if f:match("%.md$") then
        on_file(fs_path.join(dir, f), bucket)
      end
    end
  end

  if bucket_filter and bucket_filter ~= "archived" then
    scan_leaf(fs_path.join(td, bucket_filter), bucket_filter)
    return
  end
  if not bucket_filter then
    for _, b in ipairs(M.FLAT_BUCKETS) do
      scan_leaf(fs_path.join(td, b), b)
    end
  end
  local a_dir = fs_path.join(td, M.BUCKETS.archived)
  if fs_path.is_dir(a_dir) then
    local years = vim.fn.readdir(a_dir) or {}
    table.sort(years)
    for _, y in ipairs(years) do
      local y_dir = fs_path.join(a_dir, y)
      if fs_path.is_dir(y_dir) then
        local months = vim.fn.readdir(y_dir) or {}
        table.sort(months)
        for _, m in ipairs(months) do
          scan_leaf(fs_path.join(y_dir, m), "archived")
        end
      end
    end
  end
end

---Absolute path of the on-disk file backing `id`, searching every
---bucket of `td` (flat buckets first, then archived YYYY/MM); nil
---when no bucket holds the file. Shared by `todo.init` and
---`todo.automation` — previously each carried its own copy
---(ADR-0038 Batch C).
---@param td string  resolved todo dir
---@param id string
---@return string?
function M.find_task_file(td, id)
  local fname = id .. ".md"
  for _, bucket in ipairs(M.FLAT_BUCKETS) do
    local candidate = fs_path.join(td, bucket, fname)
    if fs_path.is_file(candidate) then return candidate end
  end
  local archived = fs_path.join(td, M.BUCKETS.archived)
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

---Generate a stable task id from a creation timestamp + title slug,
---per ADR-0031 §2 ("Filename: `<YYYY-MM-DD>-<kebab-slug>`, frozen
---at creation"). The slug strips punctuation, lower-cases, and
---collapses whitespace into single dashes. Empty slug after
---normalization falls back to "untitled".
---@param created_iso string  ISO 8601 timestamp (only the leading YYYY-MM-DD is used)
---@param title string
---@return string id
function M.make_id(created_iso, title)
  local date_prefix = created_iso:match("^(%d%d%d%d%-%d%d%-%d%d)")
  if not date_prefix then
    error("auto-core.todo.paths.make_id: created must start with YYYY-MM-DD, got "
      .. tostring(created_iso))
  end
  local slug = (title or ""):lower()
    :gsub("[^%w%s%-]", "")     -- drop punctuation (keep word, whitespace, dash)
    :gsub("%s+", "-")          -- whitespace runs → single dash
    :gsub("%-+", "-")          -- coalesce multiple dashes
    :gsub("^%-", "")           -- trim leading dash
    :gsub("%-$", "")           -- trim trailing dash
  if slug == "" then slug = "untitled" end
  return date_prefix .. "-" .. slug
end

return M
