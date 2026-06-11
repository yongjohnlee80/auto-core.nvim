---Namespaced state store for the AutoVim plugin family.
---
---Each plugin claims a namespace once via `state.namespace(name, opts)`
---and reads/writes through the returned object. Namespaces are
---isolated: `auto-agents`'s `panel.slot_count` and `auto-finder`'s
---`panel.user_width` live under different namespaces and never
---collide.
---
---API per ADR 0006 §2:
---
---  M.namespace(name, opts) → Namespace
---    opts = {
---      defaults = table?,           -- merged below set values on read
---      persist  = "ephemeral"|"json"|"toml"  -- backend (default "json")
---    }
---
---  Namespace:
---    :get(key)              dot-path read; falls through to defaults
---    :set(key, value)       dot-path write; auto-publishes a change event
---    :get_all()             entire namespace as a nested table snapshot
---    :watch(key, fn)        sugar over events.subscribe; returns handle
---    :unwatch(handle)       sugar over events.unsubscribe
---    :clear(key?)           delete key (or whole namespace if key omitted)
---    :persist_now()         force a synchronous flush; otherwise writes are
---                            coalesced via vim.schedule + 100ms debounce
---
---Auto-published topics on every set:
---  state.<namespace>:<key>:changed  payload = { namespace, key, new, old }
---
---Hard rule from ADR 0006 §1 carries over: the state module never
---`require`s a family plugin. Family plugins read/write through us;
---we don't reach back to them.
---@module 'auto-core.state'

local persist = require("auto-core.state.persist")

-- ── events access (ADR-0038 Batch E) ───────────────────────────
-- One memoized resolver replaces the four inline
-- `require("auto-core").events` round-trips through the auto-core
-- facade (the historical circular-require workaround). Resolved on
-- FIRST USE, not at module load — `auto-core.events` is a leaf with
-- no dependency back onto state, but keeping the resolution lazy
-- means this module stays loadable in any order regardless of what
-- events grows later.
local _events
local function events()
  if not _events then _events = require("auto-core.events") end
  return _events
end

local M = {}

-- ── module config (set by setup) ───────────────────────────────
local _persist_dir_override = nil

---@param opts { persist_dir: string? }?
function M.configure(opts)
  opts = opts or {}
  if opts.persist_dir ~= nil then _persist_dir_override = opts.persist_dir end
end

-- ── namespace registry ─────────────────────────────────────────
-- Keyed by name; second call to namespace(name) returns the same
-- instance (idempotent — different consumers can ask for the same
-- handle without triggering a re-load of disk state).
---@type table<string, AutoCoreNamespace>
local _registry = {}

-- ── helpers: dot-path traversal ────────────────────────────────

---Walk a dot-path from a table and return the leaf value (or nil).
---Empty path returns the root table itself.
---@param t table
---@param path string
---@return any
local function dget(t, path)
  if path == nil or path == "" then return t end
  local cur = t
  for segment in path:gmatch("[^%.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[segment]
    if cur == nil then return nil end
  end
  return cur
end

---Set a dot-path on a table, creating intermediate sub-tables as
---needed. Returns the OLD value at that path.
---@param t table
---@param path string
---@param value any
---@return any old_value
local function dset(t, path, value)
  if path == nil or path == "" then
    error("auto-core.state: dset requires a non-empty key path")
  end
  local segments = {}
  for segment in path:gmatch("[^%.]+") do segments[#segments + 1] = segment end
  local cur = t
  for i = 1, #segments - 1 do
    local k = segments[i]
    if type(cur[k]) ~= "table" then cur[k] = {} end
    cur = cur[k]
  end
  local last = segments[#segments]
  local old = cur[last]
  cur[last] = value
  return old
end

---Delete a dot-path from a table. Returns the OLD value.
---@param t table
---@param path string
---@return any old_value
local function ddel(t, path)
  if path == nil or path == "" then return nil end
  local segments = {}
  for segment in path:gmatch("[^%.]+") do segments[#segments + 1] = segment end
  local cur = t
  for i = 1, #segments - 1 do
    if type(cur[segments[i]]) ~= "table" then return nil end
    cur = cur[segments[i]]
  end
  local last = segments[#segments]
  local old = cur[last]
  cur[last] = nil
  return old
end

---Deep-merge `src` over `dst`, returning `dst`. Used for layering
---defaults under user-set values: `merge(defaults, user_data)` returns
---the effective view.
local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      deep_merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

-- ── Namespace class ─────────────────────────────────────────────

---@class AutoCoreNamespace
---@field name string
---@field _defaults table
---@field _data table
---@field _backend string
---@field _path string?
---@field _backend_impl table
---@field _dirty boolean
---@field _flush_scheduled boolean
local Namespace = {}
Namespace.__index = Namespace

---@private
function Namespace:_topic(key)
  return "state." .. self.name .. ":" .. key .. ":changed"
end

---@private
function Namespace:_schedule_flush()
  if self._backend == "ephemeral" or self._flush_scheduled or not self._path then
    return
  end
  self._flush_scheduled = true
  -- Coalesce writes: subsequent sets within the debounce window
  -- piggyback on the same flush. 100ms target per ADR §"Performance
  -- budgets" (state writes coalesce within 100ms).
  vim.defer_fn(function()
    self._flush_scheduled = false
    if self._dirty then
      self._dirty = false
      self._backend_impl.save(self._path, self._data)
    end
  end, 100)
end

---Read a dot-path. Falls through to defaults when the namespace
---doesn't have an explicit value yet. Returns nil if neither source
---has it.
---@param key string
---@return any
function Namespace:get(key)
  local v = dget(self._data, key)
  if v ~= nil then return v end
  return dget(self._defaults, key)
end

---Read the entire namespace as a nested-table snapshot, layering
---defaults under user-set values.
---@return table
function Namespace:get_all()
  local out = vim.deepcopy(self._defaults)
  deep_merge(out, vim.deepcopy(self._data))
  return out
end

---Write a dot-path. If the new value differs from the previous
---effective value, publishes `state.<ns>:<key>:changed` with
---`{ namespace, key, new, old }` payload AND schedules a deferred
---disk flush (unless backend is "ephemeral").
---@param key string
---@param value any
function Namespace:set(key, value)
  -- "Effective old" is what `:get(key)` would return BEFORE the
  -- write — i.e. the user-set value if any, otherwise the default.
  -- This matches the watcher's mental model: subscribers care about
  -- effective-value transitions, not internal-table diffs.
  local old = self:get(key)
  dset(self._data, key, value)
  if not self:_values_equal(old, value) then
    self._dirty = true
    self:_schedule_flush()
    events().publish(self:_topic(key), {
      namespace = self.name,
      key       = key,
      new       = value,
      old       = old,
    })
  end
end

---Compare two values for change-detection. Tables compared by deep
---equality so nested-table sets only fire events when content
---actually differs.
---@private
function Namespace:_values_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return vim.deep_equal(a, b)
end

---Delete a dot-path (or the entire namespace if key omitted).
---Publishes a change event with `new = nil` for each removed leaf.
---@param key string?
function Namespace:clear(key)
  if key == nil then
    -- Clear all by listing the keys we held + emit one event per top-level.
    local keys = {}
    for k in pairs(self._data) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do self:set(k, nil) end
    self._data = {}
    self._dirty = true
    self:_schedule_flush()
    return
  end
  local old = self:get(key)
  ddel(self._data, key)
  if old ~= nil then
    self._dirty = true
    self:_schedule_flush()
    events().publish(self:_topic(key), {
      namespace = self.name,
      key       = key,
      new       = nil,
      old       = old,
    })
  end
end

---Subscribe to changes for a specific dot-path. Wildcard-keys (`*`)
---are honored via the underlying events bus, so `:watch("panel.*")`
---fires for any change under `panel.*`.
---@param key string
---@param callback fun(payload: { namespace: string, key: string, new: any, old: any })
---@return AutoCoreSubHandle
function Namespace:watch(key, callback)
  return events().subscribe(self:_topic(key), callback)
end

---@param handle AutoCoreSubHandle
function Namespace:unwatch(handle)
  events().unsubscribe(handle)
end

---Force a synchronous disk flush. Normally writes are coalesced via
---vim.schedule; call this before triggering a hard external read
---(e.g. another process spawning to read the file).
---@return boolean ok
function Namespace:persist_now()
  if self._backend == "ephemeral" or not self._path then return true end
  self._dirty = false
  self._flush_scheduled = false
  return self._backend_impl.save(self._path, self._data)
end

-- ── public: namespace claim ────────────────────────────────────

---Claim a namespace. First call performs initial load from disk
---(merging persisted user values over defaults). Subsequent calls
---with the same name return the same singleton instance, optionally
---merging additional defaults — useful when two consumers within
---the same plugin both call namespace() during setup.
---
---@param name string
---@param opts { defaults: table?, persist: string? }?
---@return AutoCoreNamespace
function M.namespace(name, opts)
  assert(type(name) == "string" and #name > 0,
    "auto-core.state.namespace: name must be a non-empty string")
  opts = opts or {}
  local backend_name = opts.persist or "json"
  local defaults = opts.defaults or {}

  if _registry[name] then
    -- Idempotent: merge any additional defaults non-destructively.
    deep_merge(_registry[name]._defaults, defaults)
    return _registry[name]
  end

  local backend = persist.get(backend_name)
  local path = nil
  if backend_name ~= "ephemeral" then
    local root = persist.resolve_root(_persist_dir_override)
    path = persist.path_for(root, name, backend_name)
  end

  local data = {}
  if path then
    data = backend.load(path) or {}
  end

  local ns = setmetatable({
    name             = name,
    _defaults        = defaults,
    _data            = data,
    _backend         = backend_name,
    _backend_impl    = backend,
    _path            = path,
    _dirty           = false,
    _flush_scheduled = false,
  }, Namespace)

  _registry[name] = ns
  return ns
end

-- Flush every registered namespace synchronously on `VimLeavePre`.
-- Without this, deferred persist writes (vim.defer_fn 100ms debounce
-- per ADR §"Performance budgets") can die when nvim exits before
-- the timer fires. md-harpoon's per-project pin set on quit was
-- the surfacing case; equally affects worktree's set_workspace_root
-- and any other write within ~100ms of :qa.
--
-- Registered ONCE at module load (not per-namespace.new) so we
-- don't accumulate handlers when consumers re-claim the same
-- namespace name.
local _leave_group = vim.api.nvim_create_augroup(
  "AutoCoreStateFlush", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = _leave_group,
  callback = function()
    for _, ns in pairs(_registry) do
      pcall(function() ns:persist_now() end)
    end
  end,
})

---Test-only: blow away the registry. Production code never calls
---this. Smoke tests use it for isolation between cases.
function M._reset_for_tests()
  -- Flush any pending writes before discarding so we don't strand
  -- bytes in the filesystem.
  for _, ns in pairs(_registry) do
    pcall(ns.persist_now, ns)
  end
  _registry = {}
end

---Inspect the registry — used by `:checkhealth` and tests.
---@return table<string, { backend: string, path: string?, key_count: integer }>
function M._inspect()
  local out = {}
  for name, ns in pairs(_registry) do
    local n = 0
    for _ in pairs(ns._data) do n = n + 1 end
    out[name] = { backend = ns._backend, path = ns._path, key_count = n }
  end
  return out
end

return M
