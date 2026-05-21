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
---  recursive    = true                    -- native recursive on Darwin;
---                                      -- otherwise walk + watch subdirs
---  debounce_ms  = 100                     -- per-path coalescing window
---  ignore       = DEFAULT_IGNORE          -- Lua patterns
---  max_handles  = 131072                  -- session-wide safety cap
---
---Implementation notes:
---  - libuv's recursive fs_event support is platform-specific. On
---    Darwin we use one root watcher with `{ recursive = true }`
---    because FSEvents can cover the subtree without spending one fd
---    per directory. On platforms without native recursive support
---    (notably Linux), we walk the tree once at start time and open
---    one handle per subdir (skipping ignored ones). Subdirs created
---    AFTER a walked watch starts are NOT auto-watched in this
---    baseline — a Phase 5+ refinement can add "self-extending"
---    recursion by listening for our own `core.file:created` and
---    starting a new handle when the path is a directory.
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

local function is_darwin()
  local ok, uname = pcall(vim.uv.os_uname)
  return ok and uname and uname.sysname == "Darwin"
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

local function join_event_path(dir, filename)
  if filename:sub(1, 1) == "/" then return filename end
  return dir .. "/" .. filename
end

-- Start a single fs_event handle on one directory. Wires it to the
-- shared state's debounce + ignore + classification logic.
---@param dir string
---@param state AutoCoreWatchHandle
---@param recursive boolean?
---@return userdata? handle, string? err
local function start_one_dir(dir, state, recursive)
  local fs_event = vim.uv.new_fs_event()
  if not fs_event then return nil end
  local ok, err = pcall(function()
    fs_event:start(dir, { recursive = recursive == true }, function(uv_err, filename, uv_events)
      if uv_err or not filename then return end
      local full = join_event_path(dir, filename)
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

-- ── public API ───────────────────────────────────────────────

---@class AutoCoreWatchOpts
---@field recursive   boolean?    -- default true
---@field debounce_ms integer?    -- default 100
---@field ignore      string[]?   -- default DEFAULT_IGNORE
---@field max_handles integer?    -- default 131072

---@class AutoCoreWatchHandle
---@field id          integer
---@field root        string
---@field opts        AutoCoreWatchOpts
---@field fs_events   userdata[]
---@field _debounce   table<string, integer>

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

  local native_recursive = opts.recursive and is_darwin()
  local dirs = native_recursive and { root }
    or (opts.recursive and collect_dirs(root, opts.ignore) or { root })
  if _count_active_handles() + #dirs > opts.max_handles then
    return nil, string.format(
      "auto-core.fs.watch: would exceed max_handles cap (%d active + %d new > %d)",
      _count_active_handles(), #dirs, opts.max_handles)
  end

  _next_id = _next_id + 1
  local state = {
    id        = _next_id,
    root      = root,
    opts      = opts,
    fs_events = {},
    _debounce = {},
  }

  for _, d in ipairs(dirs) do
    local h = start_one_dir(d, state, native_recursive and d == root)
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
