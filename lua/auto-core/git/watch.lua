---libuv fs_event watcher for a repo's `.git/` plumbing, publishing
---`core.git.state:changed` whenever HEAD / index / merge markers /
---reflog tip mutates. The narrow companion to `auto-core.fs.watch`,
---which deliberately ignores `/.git/` (its `DEFAULT_IGNORE` would
---otherwise drown subscribers in object/refs/reflog churn).
---
---Per [[shared/adrs/0025-files-panel-external-git-state-refresh]].
---
---Public surface (mirrors `auto-core.fs.watch`):
---
---  watch.start(repo_root, opts?)  → handle, err?
---  watch.stop(handle)
---  watch.stop_all()
---  watch.list()                   → handle[]
---
---Default opts:
---  debounce_ms = 200   -- longer than fs.watch's 100 ms; git ops
---                        tend to write several files in sequence
---                        and we want one publish per logical op.
---  max_handles = 64    -- session-wide safety cap; two handles per
---                        repo means 32 simultaneous watched repos.
---
---Watched files (the only ones whose mutation matters for UI):
---  git_dir/HEAD          → kind = "head"
---  git_dir/index         → kind = "index"
---  git_dir/ORIG_HEAD     → kind = "merge"
---  git_dir/MERGE_HEAD    → kind = "merge"
---  git_dir/logs/HEAD     → kind = "reflog"   (reflog tip — every
---                                             commit/checkout/reset
---                                             that moves HEAD appends
---                                             a line; non-recursive
---                                             alternative to walking
---                                             refs/heads/ which Linux
---                                             fs_event can't observe
---                                             recursively)
---
---Deliberately NOT watched:
---  git_dir/refs/remotes/, git_dir/FETCH_HEAD, git_dir/logs/refs/remotes/
---    — all written by `git fetch` and noisy without changing local
---    panel state. ADR 0007 `core.git.fetch:completed` covers that case.
---  git_dir/refs/heads/   — non-recursive fs_event can't observe
---    namespaced branches; `logs/HEAD` catches every HEAD movement
---    those produce.
---
---Linked-worktree note: `auto-core.git.repo.git_dir(repo_root)` returns
---`<common_dir>/worktrees/<name>/` for a linked worktree. HEAD, index,
---logs/HEAD all live PER-WORKTREE under that path, so the watcher
---naturally scopes to one worktree and doesn't cross-fire on siblings.
---@module 'auto-core.git.watch'

local events  = require("auto-core.events")
local repo_mod = require("auto-core.git.repo")
local path_mod = require("auto-core.fs.path")

local M = {}

-- ── defaults ──────────────────────────────────────────────────

local DEFAULT_DEBOUNCE_MS = 200
local DEFAULT_MAX_HANDLES = 64

-- Filename → kind. Anything not in this table that slips through a
-- handle (shouldn't, but be defensive) is classified "other".
local FILENAME_KINDS = {
  ["HEAD"]       = "head",
  ["index"]      = "index",
  ["ORIG_HEAD"]  = "merge",
  ["MERGE_HEAD"] = "merge",
}

-- ── module state ─────────────────────────────────────────────

---@type table<integer, AutoCoreGitWatchHandle>
local _handles = {}
local _next_id = 0

local function _count_active_handles()
  local n = 0
  for _, state in pairs(_handles) do
    n = n + #state.fs_events
  end
  return n
end

-- ── helpers ──────────────────────────────────────────────────

-- Drop intermediate `.lock` files git writes mid-operation
-- (`index.lock`, `HEAD.lock`, `MERGE_HEAD.lock`). The corresponding
-- non-lock filename event arrives ~ms later and is the one we care
-- about. Mirror upstream neo-tree git/watch.lua exclusion.
---@param filename string
---@return boolean
local function is_lock_file(filename)
  return vim.endswith(filename, ".lock")
end

-- Per-state debounce: collapses repeat events on the same path within
-- `debounce_ms`. First event in a window goes through; subsequent
-- ones slide the window without firing.
---@param state AutoCoreGitWatchHandle
---@param full_path string
---@return boolean fire
local function debounce_check(state, full_path)
  local now    = vim.uv.now()
  local window = state.opts.debounce_ms
  local last   = state._debounce[full_path]
  if last and (now - last) < window then
    state._debounce[full_path] = now
    return false
  end
  state._debounce[full_path] = now
  return true
end

local function publish_event(state, full_path, kind)
  events.publish("core.git.state:changed", {
    repo_root = state.repo_root,
    git_dir   = state.git_dir,
    kind      = kind,
    path      = full_path,
  })
end

-- Open one fs_event handle. `filter_fn(filename) → kind|nil` filters
-- inbound events: return a kind to publish, nil to drop.
---@param dir string
---@param filter_fn fun(filename: string): string|nil
---@param state AutoCoreGitWatchHandle
---@return userdata? handle, string? err
local function start_one_dir(dir, filter_fn, state)
  if not path_mod.is_dir(dir) then
    -- Soft-skip — the dir may legitimately not exist yet (e.g.
    -- `logs/` in a freshly-init'd repo). The caller continues with
    -- the handles that DID open; first git op that creates the dir
    -- will be missed until the next watcher restart, but that's
    -- preferable to refusing to start the watcher altogether.
    return nil, "dir does not exist: " .. dir
  end
  local fs_event = vim.uv.new_fs_event()
  if not fs_event then return nil, "vim.uv.new_fs_event() returned nil" end
  local ok, err = pcall(function()
    fs_event:start(dir, {}, function(uv_err, filename)
      if uv_err or not filename then return end
      if is_lock_file(filename) then return end
      local kind = filter_fn(filename)
      if not kind then return end
      local full = dir .. "/" .. filename
      if not debounce_check(state, full) then return end
      -- Hop to the main loop before publishing — subscribers run
      -- synchronously and most touch the nvim API.
      vim.schedule(function() publish_event(state, full, kind) end)
    end)
  end)
  if not ok then
    pcall(fs_event.close, fs_event)
    return nil, err
  end
  return fs_event
end

-- ── public API ───────────────────────────────────────────────

---@class AutoCoreGitWatchOpts
---@field debounce_ms integer?    -- default 200
---@field max_handles integer?    -- default 64

---@class AutoCoreGitWatchHandle
---@field id          integer
---@field repo_root   string
---@field git_dir     string
---@field opts        AutoCoreGitWatchOpts
---@field fs_events   userdata[]
---@field _debounce   table<string, integer>

---Start watching the `.git/` plumbing of the repo containing
---`repo_root`. Returns a handle (used with `stop`) or nil + error.
---@param repo_root string
---@param opts AutoCoreGitWatchOpts?
---@return AutoCoreGitWatchHandle? handle, string? err
function M.start(repo_root, opts)
  opts = opts or {}
  if opts.debounce_ms == nil then opts.debounce_ms = DEFAULT_DEBOUNCE_MS end
  if opts.max_handles == nil then opts.max_handles = DEFAULT_MAX_HANDLES end

  if type(repo_root) ~= "string" or repo_root == "" then
    return nil, "auto-core.git.watch: repo_root must be a non-empty string"
  end
  local root = path_mod.normalize(repo_root)
  local git_dir = repo_mod.git_dir(root)
  if not git_dir then
    return nil, "auto-core.git.watch: not a git repo: " .. tostring(root)
  end
  git_dir = path_mod.normalize(git_dir)

  -- Pre-flight the handle budget. Worst case 2 handles (git_dir/
  -- and git_dir/logs/); allow start to proceed even if logs/ is
  -- absent (single-handle outcome) but enforce the cap up front.
  if _count_active_handles() + 2 > opts.max_handles then
    return nil, string.format(
      "auto-core.git.watch: would exceed max_handles cap (%d active + 2 new > %d)",
      _count_active_handles(), opts.max_handles)
  end

  _next_id = _next_id + 1
  local state = {
    id        = _next_id,
    repo_root = root,
    git_dir   = git_dir,
    opts      = opts,
    fs_events = {},
    _debounce = {},
  }

  -- Handle 1: git_dir/ — HEAD, index, ORIG_HEAD, MERGE_HEAD.
  local h1 = start_one_dir(git_dir, function(filename)
    return FILENAME_KINDS[filename]
  end, state)
  if h1 then state.fs_events[#state.fs_events + 1] = h1 end

  -- Handle 2: git_dir/logs/ — reflog tip (filename "HEAD"). Catches
  -- every HEAD movement regardless of branch namespacing.
  local logs_dir = git_dir .. "/logs"
  local h2 = start_one_dir(logs_dir, function(filename)
    if filename == "HEAD" then return "reflog" end
    return nil
  end, state)
  if h2 then state.fs_events[#state.fs_events + 1] = h2 end

  if #state.fs_events == 0 then
    return nil, "auto-core.git.watch: failed to open any fs_event handle"
  end

  _handles[state.id] = state
  return state
end

---Stop a single watcher (closes every fs_event handle it owns).
---@param handle AutoCoreGitWatchHandle?
function M.stop(handle)
  if not handle or not handle.id then return end
  for _, h in ipairs(handle.fs_events) do
    pcall(h.stop, h)
    pcall(h.close, h)
  end
  handle.fs_events = {}
  _handles[handle.id] = nil
end

---Stop every active watcher. Used at shutdown / between tests.
function M.stop_all()
  for _, state in pairs(_handles) do
    for _, h in ipairs(state.fs_events) do
      pcall(h.stop, h)
      pcall(h.close, h)
    end
  end
  _handles = {}
end

---List all active watcher handles (informational).
---@return AutoCoreGitWatchHandle[]
function M.list()
  local out = {}
  for _, state in pairs(_handles) do out[#out + 1] = state end
  return out
end

---Test-only — production code never calls this.
function M._reset_for_tests()
  M.stop_all()
  _next_id = 0
end

-- Expose defaults so tests + consumers can introspect.
M.DEFAULT_DEBOUNCE_MS = DEFAULT_DEBOUNCE_MS
M.DEFAULT_MAX_HANDLES = DEFAULT_MAX_HANDLES
M.FILENAME_KINDS      = FILENAME_KINDS

return M
