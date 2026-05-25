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

---Bucket directories per ADR-0031 §1 (`dir == status` invariant).
---Indexed by status enum value.
M.BUCKETS = {
  open      = "open",
  completed = "completed",
  deferred  = "deferred",
  archived  = "archived",  -- nested by YYYY/MM under here
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

---Resolve the absolute todo-dir to use. If `override` is supplied
---and non-empty it wins (accepts `~`-prefixed). Otherwise falls back
---to `<workspace_root>/.todo-list/`.
---
---Callers of the public API layer (auto-core.todo) consult the state
---namespace `todo.dir_overrides[<ws_root>]` to obtain `override`. This
---function stays pure so it's trivially testable.
---@param override string?
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
---`archived_at` ISO string. Includes the `.yaml` extension.
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
  return fs_path.normalize(fs_path.join(parent, id .. ".yaml"))
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
