---Cached `git status --porcelain=v2 -z` per repo, with auto-invalidation wired to `core.file:*` and
---`core.git.state:changed`.
---
---Replaces the ad-hoc porcelain parses scattered across worktree.nvim and gitsgraph. Phase 4b per
---ADR 0006; ADR-0200 §4.6 adds the async read and moves the parser to porcelain v2 `-z` (NUL-separated
---records: quoted paths and rename origins parse unambiguously).
---
---Public surface:
---
---  status.get(repo_root?, opts?)            → entries[], cached_at_ms | nil, err     (sync)
---  status.get_async(repo_root?, opts?, cb)  — cb(entries?, err?) on the main loop     (async)
---  status.invalidate(repo_root?)            — force-clear one repo's cache
---  status.invalidate_all()                  — clear every cached repo
---  status.is_cached(repo_root?, opts?)      → boolean
---
---`opts.ignored = true` adds `--ignored=matching`, so ignored paths arrive as `!!` entries. The two forms
---are cached separately.
---
---Each entry is `{ path, status_x, status_y, orig_path? }` where:
---  status_x  = staged-side flag (M, A, D, R, C, U, T, ' ', '?', '!')
---  status_y  = worktree-side flag (M, D, U, T, ' ', '?', '!')
---  path      = repo-relative path; a trailing "/" means a whole untracked or ignored directory
---  orig_path = rename/copy origin (R/C entries only)
---
---Output is read RAW (no `text = true`): text mode rewrites CRLF to LF, and git permits CRLF inside a
---filename, which the NUL-delimited protocol carries verbatim.
---
---`get_async` is single-flight per (root, ignored): concurrent callers share one subprocess. A call made
---after an invalidation that happened while a read was running is served by exactly one follow-up read,
---because the running read may predate the change. Callers that joined BEFORE the invalidation receive the
---running read's result: a snapshot from when they asked. The read passes `--no-optional-locks`, so it never
---rewrites the index and cannot re-trigger `core.git.state:changed` (ADR-0050 §2.1).
---@module 'auto-core.git.status'

local events   = require("auto-core.events")
local repo_mod = require("auto-core.git.repo")
local path_mod = require("auto-core.fs.path")

local M = {}

-- key(root, ignored) → { root = string, entries = Entry[], cached_at = ms }
local _cache = {}
local _wired = false
-- root → integer, bumped by every invalidation of that root. A read caches its result only if the epoch
-- it started under is still current; a caller that arrives under a newer epoch is owed a fresh read.
local _epoch = {}
-- key → { epoch = integer, waiters = cb[], rerun = cb[] }
local _inflight = {}

---@class AutoCoreGitStatusEntry
---@field path      string
---@field status_x  string   -- index/staged side
---@field status_y  string   -- worktree side
---@field orig_path string?  -- rename/copy origin

---@class AutoCoreGitStatusOpts
---@field ignored boolean?  -- include `!!` entries (`--ignored=matching`)

local function key(root, opts)
  return root .. ((opts and opts.ignored) and "\0ignored" or "")
end

local function flag(c)
  if c == "." then return " " end
  return c
end

---Parse `git status --porcelain=v2 -z` output. Records are NUL-terminated; a type-2 (rename/copy) record
---is followed by one more NUL-terminated field, the origin path.
---@param raw string
---@return AutoCoreGitStatusEntry[]
local function parse_porcelain_v2_z(raw)
  local out = {}
  local fields = vim.split(raw, "\0", { plain = true })
  local i = 1
  while i <= #fields do
    local rec = fields[i]
    i = i + 1
    local kind = rec:sub(1, 1)
    if kind == "1" then
      -- 1 XY sub mH mI mW hH hI path   (path may contain spaces: take everything after field 8)
      local xy, path = rec:match("^1 (..) %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then out[#out + 1] = { status_x = flag(xy:sub(1, 1)), status_y = flag(xy:sub(2, 2)), path = path } end
    elseif kind == "2" then
      -- 2 XY sub mH mI mW hH hI Xscore path  NUL  orig
      local xy, path = rec:match("^2 (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      local orig = fields[i]
      i = i + 1
      if xy then
        out[#out + 1] = { status_x = flag(xy:sub(1, 1)), status_y = flag(xy:sub(2, 2)), path = path, orig_path = orig }
      end
    elseif kind == "u" then
      -- u XY sub m1 m2 m3 mW h1 h2 h3 path
      local xy, path = rec:match("^u (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then out[#out + 1] = { status_x = flag(xy:sub(1, 1)), status_y = flag(xy:sub(2, 2)), path = path } end
    elseif kind == "?" or kind == "!" then
      local path = rec:sub(3)
      if path ~= "" then out[#out + 1] = { status_x = kind, status_y = kind, path = path } end
    end
  end
  return out
end
M._parse_porcelain_v2_z = parse_porcelain_v2_z

local function argv(root, opts)
  local a = { "git", "--no-optional-locks", "-C", root, "status", "--porcelain=v2", "-z" }
  if opts and opts.ignored then a[#a + 1] = "--ignored=matching" end
  return a
end

---@param root string
---@param opts AutoCoreGitStatusOpts?
---@return AutoCoreGitStatusEntry[]?, string?
local function shell_status(root, opts)
  -- `--no-optional-locks` (GIT_OPTIONAL_LOCKS=0) keeps `git status` from taking `index.lock` to rewrite
  -- the on-disk index stat cache; without it a status against a freshly checked-out worktree rewrites
  -- `git_dir/index`, which `git.watch` observes as an `index` mutation (ADR-0050 §2.1).
  local result = vim.system(argv(root, opts), {}):wait()
  if result.code ~= 0 then
    return nil, "git status failed: " .. tostring(result.stderr or "(no stderr)")
  end
  return parse_porcelain_v2_z(result.stdout or "")
end

---Resolve the repo root for `repo_root` (defaults to cwd's git root).
---Returns nil if not in a git repo.
---@param repo_root string?
---@return string?
local function resolve_root(repo_root)
  if repo_root then return path_mod.normalize(repo_root) end
  return repo_mod.root()
end

local function drop(root)
  _epoch[root] = (_epoch[root] or 0) + 1
  for k, hit in pairs(_cache) do
    if hit.root == root then _cache[k] = nil end
  end
end

-- Wire `core.file:*` + `core.git.state:changed` once. Runs at module load time. Two invalidation paths
-- because the two event sources are independent and cover disjoint mutations:
--
--   - `core.file:*` (auto-core.fs.watch) names a single working-tree path. Drop any cached repo whose
--     root contains it. Misses `.git/`-only mutations (commit/checkout/reset) because fs.watch's
--     DEFAULT_IGNORE excludes `/.git/` by design.
--   - `core.git.state:changed` (auto-core.git.watch, ADR 0025) names a repo_root directly. Covers the
--     .git/-side mutations the first subscriber misses.
local function ensure_wired()
  if _wired then return end
  _wired = true
  events.subscribe("core.file:*", function(payload, _topic)
    if type(payload) ~= "table" or type(payload.path) ~= "string" then
      return
    end
    local roots = {}
    for _, hit in pairs(_cache) do roots[hit.root] = true end
    for _, slot in pairs(_inflight) do roots[slot.root] = true end
    for root in pairs(roots) do
      if path_mod.is_under(payload.path, root) then drop(root) end
    end
  end)
  events.subscribe("core.git.state:changed", function(payload, _topic)
    if type(payload) ~= "table" or type(payload.repo_root) ~= "string" then
      return
    end
    drop(path_mod.normalize(payload.repo_root))
  end)
end

---Get the cached porcelain entries for `repo_root` (default: cwd's git root). On cache miss, runs
---`git status --porcelain=v2 -z` synchronously.
---On success: returns `(entries, cached_at_ms)`. On failure: returns `(nil, err_string)`.
---@param repo_root string?
---@param opts AutoCoreGitStatusOpts?
---@return AutoCoreGitStatusEntry[]? entries
---@return integer|string|nil cached_at_or_err
function M.get(repo_root, opts)
  local root = resolve_root(repo_root)
  if not root then return nil, "auto-core.git.status: not in a git repo" end
  local k = key(root, opts)
  local hit = _cache[k]
  if hit then return hit.entries, hit.cached_at end
  local entries, err = shell_status(root, opts)
  if not entries then return nil, err end
  _cache[k] = { root = root, entries = entries, cached_at = vim.uv.now() }
  return entries, _cache[k].cached_at
end

local function start_async(root, k, opts, slot)
  slot.epoch = _epoch[root] or 0
  vim.system(argv(root, opts), {}, function(result)
    vim.schedule(function()
      local entries, err
      if result.code ~= 0 then
        err = "git status failed: " .. tostring(result.stderr or "(no stderr)")
      else
        entries = parse_porcelain_v2_z(result.stdout or "")
        -- Cache only if nothing invalidated this root while the read ran.
        if (_epoch[root] or 0) == slot.epoch then
          _cache[k] = { root = root, entries = entries, cached_at = vim.uv.now() }
        end
      end
      local waiters = slot.waiters
      slot.waiters = {}
      for _, cb in ipairs(waiters) do pcall(cb, entries, err) end
      if #slot.rerun > 0 then
        slot.waiters, slot.rerun = slot.rerun, {}
        start_async(root, k, opts, slot)
      else
        _inflight[k] = nil
      end
    end)
  end)
end

---Asynchronous, shared, cached read. `cb(entries, nil)` or `cb(nil, err)`, always on the main loop and
---never synchronously inside this call.
---@param repo_root string?
---@param opts AutoCoreGitStatusOpts?
---@param cb fun(entries: AutoCoreGitStatusEntry[]?, err: string?)
function M.get_async(repo_root, opts, cb)
  assert(type(cb) == "function", "auto-core.git.status.get_async: cb must be a function")
  local root = resolve_root(repo_root)
  if not root then
    vim.schedule(function() cb(nil, "auto-core.git.status: not in a git repo") end)
    return
  end
  local k = key(root, opts)
  local hit = _cache[k]
  if hit then
    vim.schedule(function() cb(hit.entries, nil) end)
    return
  end
  local slot = _inflight[k]
  if slot then
    if (_epoch[root] or 0) ~= slot.epoch then
      slot.rerun[#slot.rerun + 1] = cb  -- invalidated since the running read began
    else
      slot.waiters[#slot.waiters + 1] = cb
    end
    return
  end
  slot = { root = root, waiters = { cb }, rerun = {} }
  _inflight[k] = slot
  start_async(root, k, opts, slot)
end

---Force-clear the cache for `repo_root` (default: cwd's git root).
---@param repo_root string?
function M.invalidate(repo_root)
  local root = resolve_root(repo_root)
  if root then drop(root) end
end

---Force-clear every cached repo's status.
function M.invalidate_all()
  local roots = {}
  for _, hit in pairs(_cache) do roots[hit.root] = true end
  for _, slot in pairs(_inflight) do roots[slot.root] = true end
  for root in pairs(roots) do drop(root) end
  _cache = {}
end

---True if `repo_root` (default: cwd's git root) has a live cache.
---@param repo_root string?
---@param opts AutoCoreGitStatusOpts?
---@return boolean
function M.is_cached(repo_root, opts)
  local root = resolve_root(repo_root)
  if not root then return false end
  return _cache[key(root, opts)] ~= nil
end

---Test-only.
function M._reset_for_tests()
  _cache = {}
  _epoch = {}
  _inflight = {}
  _wired = false
  ensure_wired()
end

ensure_wired()

return M
