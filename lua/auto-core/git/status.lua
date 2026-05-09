---Cached `git status --porcelain=v1` per repo, with auto-invalidation
---wired to `core.file:*` events from `auto-core.fs.watch`.
---
---Replaces the ad-hoc porcelain parses scattered across worktree.nvim
---and gitsgraph. Phase 4b per ADR 0006 + auto-core-todos.
---
---Public surface:
---
---  status.get(repo_root?)        → entries[], cached_at_ms | nil, err
---  status.invalidate(repo_root?) — force-clear one repo's cache
---  status.invalidate_all()       — clear every cached repo
---  status.is_cached(repo_root?)  → boolean
---
---Each entry is `{ path, status_x, status_y }` where:
---  status_x = staged-side flag (M, A, D, R, C, U, ' ', '?')
---  status_y = worktree-side flag (M, D, U, ' ', '?')
---  path     = path from porcelain output
---
---Auto-invalidation:
---  On module load we subscribe to `core.file:*`. When a path under a
---  cached repo's root changes, that repo's cache is dropped. Subsequent
---  `get()` re-runs the shell-out. The subscription is cheap (one extra
---  pattern-check per file event) and guarantees consistency without
---  forcing every consumer to call `invalidate` manually.
---@module 'auto-core.git.status'

local events   = require("auto-core.events")
local repo_mod = require("auto-core.git.repo")
local path_mod = require("auto-core.fs.path")

local M = {}

-- repo_root → { entries = Entry[], cached_at = ms }
local _cache = {}
local _wired = false

---@class AutoCoreGitStatusEntry
---@field path     string
---@field status_x string   -- index/staged side
---@field status_y string   -- worktree side

---@param porcelain string
---@return AutoCoreGitStatusEntry[]
local function parse_porcelain(porcelain)
  local out = {}
  for line in porcelain:gmatch("([^\n]+)") do
    if #line >= 4 then
      out[#out + 1] = {
        status_x = line:sub(1, 1),
        status_y = line:sub(2, 2),
        path     = line:sub(4),
      }
    end
  end
  return out
end

---@param root string
---@return AutoCoreGitStatusEntry[]?, string?
local function shell_status(root)
  local result = vim.system(
    { "git", "-C", root, "status", "--porcelain=v1" },
    { text = true }
  ):wait()
  if result.code ~= 0 then
    return nil, "git status failed: " .. tostring(result.stderr or "(no stderr)")
  end
  return parse_porcelain(result.stdout or "")
end

---Resolve the repo root for `repo_root` (defaults to cwd's git root).
---Returns nil if not in a git repo.
---@param repo_root string?
---@return string?
local function resolve_root(repo_root)
  if repo_root then return path_mod.normalize(repo_root) end
  return repo_mod.root()
end

-- Wire `core.file:*` once. Runs at module load time. Each event
-- with a `path` payload checks every cached root; matches drop.
local function ensure_wired()
  if _wired then return end
  _wired = true
  events.subscribe("core.file:*", function(payload, _topic)
    if type(payload) ~= "table" or type(payload.path) ~= "string" then
      return
    end
    for root, _ in pairs(_cache) do
      if path_mod.is_under(payload.path, root) then
        _cache[root] = nil
      end
    end
  end)
end

---Get the cached porcelain entries for `repo_root` (default: cwd's
---git root). On cache miss, runs `git status --porcelain=v1`.
---On success: returns `(entries, cached_at_ms)`.
---On failure: returns `(nil, err_string)`.
---@param repo_root string?
---@return AutoCoreGitStatusEntry[]? entries
---@return integer|string|nil cached_at_or_err
function M.get(repo_root)
  local root = resolve_root(repo_root)
  if not root then return nil, "auto-core.git.status: not in a git repo" end
  local hit = _cache[root]
  if hit then return hit.entries, hit.cached_at end
  local entries, err = shell_status(root)
  if not entries then return nil, err end
  _cache[root] = { entries = entries, cached_at = vim.uv.now() }
  return entries, _cache[root].cached_at
end

---Force-clear the cache for `repo_root` (default: cwd's git root).
---@param repo_root string?
function M.invalidate(repo_root)
  local root = resolve_root(repo_root)
  if root then _cache[root] = nil end
end

---Force-clear every cached repo's status.
function M.invalidate_all()
  _cache = {}
end

---True if `repo_root` (default: cwd's git root) has a live cache.
---@param repo_root string?
---@return boolean
function M.is_cached(repo_root)
  local root = resolve_root(repo_root)
  if not root then return false end
  return _cache[root] ~= nil
end

---Test-only.
function M._reset_for_tests()
  _cache = {}
  _wired = false
  ensure_wired()
end

ensure_wired()

return M
