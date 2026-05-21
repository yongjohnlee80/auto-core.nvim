---libuv fs watcher with debounce + ignore filter, publishing
---`core.file:created/modified/deleted` events on the auto-core bus.
---
---Replaces the ad-hoc per-plugin fs watching that auto-finder, neo-tree's
---fs_scan, and worktree.nvim each carry independently. Phase 4b per
---ADR 0006 + auto-core-todos.
---
---Public surface:
---
---  watch.start(path, opts?)  → handle, err?
---  watch.stop(handle)
---  watch.stop_all()
---  watch.list()              → handle[]
---
---Default opts:
---  recursive    = true                    -- walk + watch each subdir
---  debounce_ms  = 100                     -- per-path coalescing window
---  ignore       = DEFAULT_IGNORE          -- Lua patterns
---  max_handles  = 131072                  -- session-wide safety cap
---
---Implementation notes:
---  - libuv's `fs_event` is NOT recursive on Linux. We walk the tree
---    once at start time and open one handle per subdir (skipping
---    ignored ones). Subdirs created AFTER the watch starts are NOT
---    auto-watched in this baseline — a Phase 5+ refinement can add
---    "self-extending" recursion by listening for our own
---    `core.file:created` and starting a new handle when the path is
---    a directory.
---  - **Darwin uses a separate handler** (`_darwin_start` below) that
---    opens one root fs_event with `{ recursive = true }`. macOS's
---    per-process fd ceiling exhausts the walked approach around
---    ~7000 dirs, at which point `vim.uv.new_fs_event` returns nil
---    and the watcher silently has no coverage. The Darwin handler
---    is fully segregated from the Linux walker so changes to one
---    cannot perturb the other — `M.start` short-circuits into it
---    on macOS before any walked code runs.
---  - Events fire on the libuv thread; we always publish via
---    `vim.schedule` so subscribers run on the main loop.
---  - `should_ignore` runs on every event and is the hot path — keep
---    the ignore-list small and well-anchored (e.g. `/%.git/` not
---    `%.git`). Anchors prevent false matches on filenames like
---    `myproject.git.lua`.
---@module 'auto-core.fs.watch'

local events  = require("auto-core.events")
local path_mod = require("auto-core.fs.path")

local M = {}

-- ── defaults ──────────────────────────────────────────────────

-- Patterns matched against the FULL path. Anchored to `/` to prevent
-- e.g. "config" from also matching "/config/" (which would over-block).
local DEFAULT_IGNORE = {
  "/%.git/",            -- git plumbing subtree
  "/%.bare/",           -- bare-repo plumbing subtree
  "/node_modules/",     -- canonical js dependency dir
  "/%.svn/",            -- legacy
  -- Build / bundler output. Ecosystem-standard names; consumers
  -- who genuinely want these watched can pass an explicit
  -- `ignore` to override.
  "/dist/",             -- rollup/webpack/vite/tsc output
  "/build/",            -- generic build output (tsc, cmake, gradle, …)
  "/coverage/",         -- jest/istanbul/etc. coverage reports
  "/target/",           -- rust/java/maven build dir
  "/%.next/",           -- next.js build artifacts
  "/%.cache/",          -- gatsby/parcel/generic cache
  "/%.turbo/",          -- turborepo cache
  "/%.parcel%-cache/",  -- parcel
  -- Python ecosystem.
  "/__pycache__/",      -- bytecode cache
  "/%.venv/",           -- pep 405 venv
  "/venv/",             -- common venv (no dot)
  "/%.pytest_cache/",
  "/%.mypy_cache/",
  "/%.ruff_cache/",
  "/%.tox/",
  -- IDE metadata directories.
  "/%.idea/",           -- jetbrains
  "/%.vscode/",         -- vscode workspace settings
  "%.swp$",             -- vim swap file
  "%.swo$",             -- vim secondary swap
  "~$",                 -- vim backup file
  "/4913$",             -- vim's "is the dir writable" probe
}

local DEFAULT_DEBOUNCE_MS = 100
-- Session-wide safety cap. Sized as a "catch a runaway bug"
-- belt (e.g. `watch.start("/")`), not a real budget — legitimate
-- large bare-repo parents with many worktrees can sit well above
-- the original 1024. 131072 = ¼ of Linux's
-- `fs.inotify.max_user_watches` default (524288), leaving the
-- other ¾ for everything else under the user's uid (JetBrains,
-- other nvims, file managers). Callers can still pin a smaller
-- cap per `watch.start`.
local DEFAULT_MAX_HANDLES = 131072

-- `debounce_check` prune knobs (see the function for the why). The
-- threshold + TTL multiplier together bound `state._debounce`
-- memory at "what was touched in the last
-- `DEBOUNCE_PRUNE_TTL_MULT × debounce_ms` ms" once we've crossed
-- the threshold at least once.
local DEBOUNCE_PRUNE_THRESHOLD = 4096
local DEBOUNCE_PRUNE_TTL_MULT  = 100

-- Platform probe — computed once at module load so the dispatcher
-- in `M.start` doesn't spend a syscall per invocation.
local IS_DARWIN = (function()
  local ok, uname = pcall(vim.uv.os_uname)
  return ok and uname and uname.sysname == "Darwin" or false
end)()

-- ── module state ─────────────────────────────────────────────

---@type table<integer, AutoCoreWatchHandle>
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

---@param p string
---@param ignore string[]
---@return boolean
local function should_ignore(p, ignore)
  for _, pat in ipairs(ignore) do
    if p:find(pat) then return true end
  end
  return false
end

-- Walk `root` collecting the root + all (non-ignored) subdirectory
-- paths. Iterative to avoid deep-stack risk on large trees.
---@param root string
---@param ignore string[]
---@return string[]
local function collect_dirs(root, ignore)
  local out  = { root }
  local todo = { root }
  while #todo > 0 do
    local cur = table.remove(todo)
    local sd, _ = vim.uv.fs_scandir(cur)
    if sd then
      while true do
        local name, type_ = vim.uv.fs_scandir_next(sd)
        if not name then break end
        if type_ == "directory" then
          local sub = cur .. "/" .. name
          -- Trailing slash so anchored patterns like "/%.git/" match.
          if not should_ignore(sub .. "/", ignore) then
            out[#out + 1]  = sub
            todo[#todo + 1] = sub
          end
        end
      end
    end
  end
  return out
end

-- Decide whether the change is a create, modify, or delete based on
-- libuv's events bitmap-as-table + a fs_stat probe.
---@param full_path string
---@param uv_events { change: boolean?, rename: boolean? }
---@return "created"|"modified"|"deleted"
local function classify(full_path, uv_events)
  local stat = vim.uv.fs_stat(full_path)
  if not stat then return "deleted" end
  if uv_events and uv_events.rename then return "created" end
  return "modified"
end

-- Per-state debounce: collapses repeat events on the same path within
-- `debounce_ms`. The first event in a window goes through; subsequent
-- ones reset the window without firing.
--
-- Opportunistic prune: every unique `full_path` adds an entry to
-- `state._debounce` that would otherwise stay forever. On long-running
-- nvim sessions — especially under the Darwin native-recursive
-- handler where every file event under the subtree visits this map —
-- the table grows without bound. When the live entry count crosses
-- `DEBOUNCE_PRUNE_THRESHOLD`, sweep entries older than
-- `DEBOUNCE_PRUNE_TTL_MULT × debounce_ms` and reset the size counter.
-- Cost is paid only on the "new entry" branch.
---@param state AutoCoreWatchHandle
---@param full_path string
---@return boolean fire
local function debounce_check(state, full_path)
  local now    = vim.uv.now()
  local window = state.opts.debounce_ms
  local last   = state._debounce[full_path]
  if last and (now - last) < window then
    state._debounce[full_path] = now  -- slide the window
    return false
  end
  if last == nil then
    state._debounce_size = state._debounce_size + 1
    if state._debounce_size > DEBOUNCE_PRUNE_THRESHOLD then
      local cutoff = now - (window * DEBOUNCE_PRUNE_TTL_MULT)
      local kept = 0
      for p, ts in pairs(state._debounce) do
        if ts < cutoff then
          state._debounce[p] = nil
        else
          kept = kept + 1
        end
      end
      state._debounce_size = kept
    end
  end
  state._debounce[full_path] = now
  return true
end

local function publish_event(full_path, change_kind)
  local topic = "core.file:" .. change_kind
  events.publish(topic, {
    path   = full_path,
    change = change_kind,
  })
end

-- Start a single fs_event handle on one directory. Wires it to the
-- shared state's debounce + ignore + classification logic.
---@param dir string
---@param state AutoCoreWatchHandle
---@return userdata? handle, string? err
local function start_one_dir(dir, state)
  local fs_event = vim.uv.new_fs_event()
  if not fs_event then return nil end
  local ok, err = pcall(function()
    fs_event:start(dir, {}, function(uv_err, filename, uv_events)
      if uv_err or not filename then return end
      local full = dir .. "/" .. filename
      if should_ignore(full, state.opts.ignore) then return end
      local kind = classify(full, uv_events)
      if not debounce_check(state, full) then return end
      -- Hop to the main loop before publishing — events.publish
      -- runs subscriber callbacks synchronously and many of them
      -- will touch nvim API.
      vim.schedule(function() publish_event(full, kind) end)
    end)
  end)
  if not ok then
    pcall(fs_event.close, fs_event)
    return nil, err
  end
  return fs_event
end

-- ── darwin: native recursive handler ─────────────────────────
--
-- macOS exposes FSEvents-backed recursive `fs_event` watching:
-- one root handle covers the entire subtree, no per-directory
-- walk, no per-directory fd. The walked Linux path (see
-- `start_one_dir` above) cannot be reused on macOS because the
-- process fd ceiling tops out around ~7000 dirs — past which
-- `vim.uv.new_fs_event` returns nil and the watcher silently
-- loses coverage on large workspaces.
--
-- This section is fully segregated from the Linux walker.
-- Updates here MUST NOT touch `start_one_dir` or the Linux
-- branch of `M.start`. `M.start` short-circuits into
-- `_darwin_start` before any walked code runs.
--
-- Behavior differences worth knowing:
--   - Subdirs created AFTER `watch.start` ARE auto-watched here
--     (FSEvents covers the subtree). The Linux walker does NOT
--     auto-watch them — that asymmetry is intentional, not a bug.
--   - Ignore patterns are applied at callback time rather than at
--     walk time (there is no walk). The hot path runs on every
--     event under the subtree, including events in subtrees we
--     would have skipped on Linux. FSEvents coalesces at the OS
--     layer so this is bounded, but consumers benchmarking on
--     macOS should expect more callback churn than on Linux.

-- FSEvents callbacks deliver ABSOLUTE filenames; inotify (Linux)
-- delivers relative names. Normalize to one shape so subscribers
-- see the same payload on both platforms.
local function _darwin_join_event_path(root, filename)
  if filename:sub(1, 1) == "/" then return filename end
  return root .. "/" .. filename
end

-- Start the single recursive fs_event on `root`. Wires it to the
-- shared debounce + ignore + classification helpers, same as
-- `start_one_dir` does for the Linux walker, but with the
-- recursive opt set and the absolute-path handling above.
local function _darwin_start_one(root, state)
  local fs_event = vim.uv.new_fs_event()
  if not fs_event then return nil end
  local ok, err = pcall(function()
    fs_event:start(root, { recursive = true }, function(uv_err, filename, uv_events)
      if uv_err or not filename then return end
      local full = _darwin_join_event_path(root, filename)
      if should_ignore(full, state.opts.ignore) then return end
      local kind = classify(full, uv_events)
      if not debounce_check(state, full) then return end
      vim.schedule(function() publish_event(full, kind) end)
    end)
  end)
  if not ok then
    pcall(fs_event.close, fs_event)
    return nil, err
  end
  return fs_event
end

-- Darwin entry point invoked by `M.start` when recursive watching
-- is requested on macOS. Mirrors the Linux flow in shape (cap
-- check → state alloc → start → register) but only ever opens
-- one handle.
local function _darwin_start(root, opts)
  if _count_active_handles() + 1 > opts.max_handles then
    return nil, string.format(
      "auto-core.fs.watch: would exceed max_handles cap (%d active + %d new > %d)",
      _count_active_handles(), 1, opts.max_handles)
  end

  _next_id = _next_id + 1
  local state = {
    id             = _next_id,
    root           = root,
    opts           = opts,
    fs_events      = {},
    _debounce      = {},
    _debounce_size = 0,
  }

  local h = _darwin_start_one(root, state)
  if h then state.fs_events[#state.fs_events + 1] = h end

  if #state.fs_events == 0 then
    return nil, "auto-core.fs.watch: failed to open any fs_event handle"
  end

  _handles[state.id] = state
  return state
end

-- ── public API ───────────────────────────────────────────────

---@class AutoCoreWatchOpts
---@field recursive   boolean?    -- default true
---@field debounce_ms integer?    -- default 100
---@field ignore      string[]?   -- default DEFAULT_IGNORE
---@field max_handles integer?    -- default 131072

---@class AutoCoreWatchHandle
---@field id             integer
---@field root           string
---@field opts           AutoCoreWatchOpts
---@field fs_events      userdata[]
---@field _debounce      table<string, integer>
---@field _debounce_size integer

---Start watching `path`. Returns a handle (used with `stop`) or nil
---and an error string.
---@param path string
---@param opts AutoCoreWatchOpts?
---@return AutoCoreWatchHandle? handle, string? err
function M.start(path, opts)
  opts = opts or {}
  if opts.recursive   == nil then opts.recursive   = true end
  if opts.debounce_ms == nil then opts.debounce_ms = DEFAULT_DEBOUNCE_MS end
  if opts.ignore      == nil then opts.ignore      = DEFAULT_IGNORE end
  if opts.max_handles == nil then opts.max_handles = DEFAULT_MAX_HANDLES end

  local root = path_mod.normalize(path)
  if not path_mod.is_dir(root) then
    return nil, "auto-core.fs.watch: not a directory: " .. tostring(root)
  end

  -- Platform dispatch. Recursive watching on macOS goes through
  -- the segregated FSEvents handler above; non-recursive Darwin
  -- and every other platform fall through to the walker below.
  if IS_DARWIN and opts.recursive then
    return _darwin_start(root, opts)
  end

  local dirs = opts.recursive and collect_dirs(root, opts.ignore) or { root }
  if _count_active_handles() + #dirs > opts.max_handles then
    return nil, string.format(
      "auto-core.fs.watch: would exceed max_handles cap (%d active + %d new > %d)",
      _count_active_handles(), #dirs, opts.max_handles)
  end

  _next_id = _next_id + 1
  local state = {
    id             = _next_id,
    root           = root,
    opts           = opts,
    fs_events      = {},
    _debounce      = {},
    _debounce_size = 0,
  }

  for _, d in ipairs(dirs) do
    local h = start_one_dir(d, state)
    if h then state.fs_events[#state.fs_events + 1] = h end
  end

  if #state.fs_events == 0 then
    return nil, "auto-core.fs.watch: failed to open any fs_event handle"
  end

  _handles[state.id] = state
  return state
end

---Stop a single watcher (closes every fs_event handle it owns).
---@param handle AutoCoreWatchHandle?
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
---@return AutoCoreWatchHandle[]
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
M.DEFAULT_IGNORE      = DEFAULT_IGNORE
M.DEFAULT_DEBOUNCE_MS = DEFAULT_DEBOUNCE_MS
M.DEFAULT_MAX_HANDLES = DEFAULT_MAX_HANDLES

return M
