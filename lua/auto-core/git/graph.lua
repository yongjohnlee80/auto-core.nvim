---auto-core.git.graph — foundational queries for multi-repo graph
---views.
---
---Per ADR 0007 Phase 3 Step 3.1. Lifts the foundational pieces from
---gitsgraph.nvim's `repos.lua` + `preview.lua` + `diff.lua` into a
---reusable submodule under `auto-core.git`. The actual graph
---rendering (the character-art commit graph) is delegated by
---consumers to `isakbm/gitgraph.nvim` — that piece doesn't move
---into auto-core. Three things DO move:
---
---  fan_out(workspace_root, opts?)  → repos[]   multi-repo discovery
---  show_stat(common_dir, hash)     → string[]  cursor-preview cache
---  show_diff(common_dir, hash)     → string[]  full-diff cache
---
---Caching:
---  - fan_out: cached per workspace_root; invalidated on
---    `worktree:added` / `worktree:removed` / `worktree:switched`.
---  - show_stat / show_diff: cached per (common_dir, hash). Hashes
---    are immutable so the cache survives until clear_cache(). The
---    backend git invocation reads with `--git-dir=...`, so chdir
---    is unnecessary.
---@module 'auto-core.git.graph'

local events = require("auto-core.events")

local M = {}

-- ── caches ───────────────────────────────────────────────────

---@type table<string, AutoCoreGraphRepo[]>     workspace_root -> repos
local _fan_out_cache = {}

---@type table<string, string[]>                "<common_dir>:<hash>" -> lines
local _stat_cache = {}

---@type table<string, string[]>                "<common_dir>:<hash>" -> lines
local _diff_cache = {}

local function _cache_key(common_dir, hash)
  return common_dir .. ":" .. hash
end

-- ── fan_out: multi-repo discovery ────────────────────────────

---@class AutoCoreGraphRepo
---@field common_dir       string  absolute git common-dir (bare repo path or .git)
---@field label            string  human-readable label (basename or path-relative)
---@field sample_worktree  string? a working tree path under this repo (nil for pure bare)
---@field is_bare          boolean

---@class AutoCoreGraphFanOutOpts
---@field max_depth integer?              default 3
---@field skip_dirs table<string,true>?   default { node_modules, ... }

---Probe a single dir for git metadata (rev-parse common-dir +
---is-bare + is-inside-work-tree). Returns nil outside a repo or if
---git is unavailable.
---
---`is_bare` reflects the **underlying repo's** bareness (read from
---`<common_dir>/config:core.bare`), not the probed dir's. Probing
---from inside a linked worktree of a bare repo, `git -C <wt>
---rev-parse --is-bare-repository` returns "false" because the
---working tree itself is not bare — but consumers asking "is this a
---worktree-style project?" need a yes for that case. Reading the
---common-dir's config decouples the answer from cursor location.
---@param dir string  absolute path
---@return { common_dir: string, is_bare: boolean, is_working_tree: boolean }?
local function _probe(dir)
  local out = vim.fn.systemlist({
    "git", "-C", dir, "rev-parse",
    "--path-format=absolute",
    "--git-common-dir",
    "--is-inside-work-tree",
  })
  if vim.v.shell_error ~= 0 or #out < 2 then return nil end
  local common = (out[1] or ""):gsub("/+$", "")
  local bare_out = vim.fn.systemlist({
    "git", "--git-dir=" .. common, "config",
    "--bool", "--default", "false", "core.bare",
  })
  return {
    common_dir      = common,
    is_bare         = (bare_out[1] or "") == "true",
    is_working_tree = out[2] == "true",
  }
end

---Derive a stable label for a discovered repo. `.git` / `.bare`
---containers report common_dir = `<project>/{.git|.bare}`; the
---project is the dir above. Plain repo containers report
---common_dir = `<project>/.git`.
---@param common_dir string
---@param root string
---@return string
local function _derive_label(common_dir, root)
  local project = vim.fn.fnamemodify(common_dir, ":h")
  if project == root then
    return vim.fn.fnamemodify(project, ":t")
  end
  if vim.startswith(project, root .. "/") then
    return project:sub(#root + 2)
  end
  return vim.fn.fnamemodify(project, ":~")
end

---Default skip set: dirs that should never be probed for git metadata.
local _DEFAULT_SKIP = {
  ["node_modules"]  = true,
  ["target"]        = true,    -- rust
  ["dist"]          = true,
  ["build"]         = true,
  ["vendor"]        = true,
  [".venv"]         = true,
  ["__pycache__"]   = true,
}

---Discover git repositories under `workspace_root`. Walks at most
---`opts.max_depth` directories deep; deduplicates by canonical
---common-dir (bare + N linked worktrees collapse to one entry).
---Result is cached per workspace_root and invalidated on
---`worktree:added/removed/switched`.
---@param workspace_root string  absolute path
---@param opts AutoCoreGraphFanOutOpts?
---@return AutoCoreGraphRepo[]
function M.fan_out(workspace_root, opts)
  if type(workspace_root) ~= "string" or workspace_root == "" then
    return {}
  end
  workspace_root = (vim.fs.normalize(workspace_root) or workspace_root):gsub("/+$", "")
  if _fan_out_cache[workspace_root] then
    return _fan_out_cache[workspace_root]
  end

  opts = opts or {}
  local max_depth = opts.max_depth or 3
  local skip = opts.skip_dirs or _DEFAULT_SKIP

  local results = {}
  local seen = {}  -- common_dir -> index

  local function record(parent_dir, info)
    local idx = seen[info.common_dir]
    if idx then
      if info.is_working_tree and not results[idx].sample_worktree then
        results[idx].sample_worktree = parent_dir
      end
      return
    end
    results[#results + 1] = {
      common_dir      = info.common_dir,
      label           = _derive_label(info.common_dir, workspace_root),
      sample_worktree = info.is_working_tree and parent_dir or nil,
      is_bare         = info.is_bare,
    }
    seen[info.common_dir] = #results
  end

  local function walk(dir, depth)
    if depth > max_depth then return end
    local fd = vim.uv.fs_scandir(dir)
    if not fd then return end
    local subdirs, has_git = {}, false
    while true do
      local name, t = vim.uv.fs_scandir_next(fd)
      if not name then break end
      if name == ".git" or name == ".bare" then
        has_git = true
      elseif t == "directory"
          and not skip[name]
          and not name:match("^%.")
      then
        subdirs[#subdirs + 1] = name
      end
    end
    if has_git then
      local info = _probe(dir)
      if info then
        record(dir, info)
        if not info.is_bare then return end
      end
    end
    for _, name in ipairs(subdirs) do
      walk(dir .. "/" .. name, depth + 1)
    end
  end
  walk(workspace_root, 0)

  table.sort(results, function(a, b) return a.label < b.label end)
  _fan_out_cache[workspace_root] = results
  return results
end

-- ── show_stat / show_diff: per-commit caches ─────────────────

---Cached `git show --stat --no-color --format=fuller <hash>` for
---the cursor-preview pane in a commit-graph view.
---@param common_dir string
---@param hash string
---@return string[] lines
function M.show_stat(common_dir, hash)
  if not common_dir or not hash or hash == "" then return {} end
  local key = _cache_key(common_dir, hash)
  local lines = _stat_cache[key]
  if lines then return lines end
  local out = vim.fn.systemlist({
    "git", "--git-dir=" .. common_dir,
    "show", "--stat", "--no-color", "--format=fuller", hash,
  })
  if vim.v.shell_error ~= 0 then
    lines = { "(auto-core.git.graph: git show --stat failed)", "" }
    vim.list_extend(lines, out)
  else
    lines = out
  end
  _stat_cache[key] = lines
  return lines
end

---Cached `git show -p --no-color <hash>` for the full unified diff.
---Used by the consumer's `<CR>`-on-commit handler.
---@param common_dir string
---@param hash string
---@return string[] lines
function M.show_diff(common_dir, hash)
  if not common_dir or not hash or hash == "" then return {} end
  local key = _cache_key(common_dir, hash)
  local lines = _diff_cache[key]
  if lines then return lines end
  local out = vim.fn.systemlist({
    "git", "--git-dir=" .. common_dir,
    "show", "-p", "--no-color", hash,
  })
  if vim.v.shell_error ~= 0 then
    lines = { "(auto-core.git.graph: git show -p failed)", "" }
    vim.list_extend(lines, out)
  else
    lines = out
  end
  _diff_cache[key] = lines
  return lines
end

-- ── cache management ─────────────────────────────────────────

---Drop every cache. Use sparingly — typically the subscriber-driven
---invalidation below is enough.
function M.clear_cache()
  _fan_out_cache = {}
  _stat_cache    = {}
  _diff_cache    = {}
end

---Drop just the stat + diff caches for a single repo. Use after a
---branch reset / rebase that rewrote history (commit hashes are
---usually immutable, but force-pushed branches can change them).
---@param common_dir string?
function M.clear_repo_cache(common_dir)
  if not common_dir then return end
  for k in pairs(_stat_cache) do
    if k:sub(1, #common_dir + 1) == common_dir .. ":" then
      _stat_cache[k] = nil
    end
  end
  for k in pairs(_diff_cache) do
    if k:sub(1, #common_dir + 1) == common_dir .. ":" then
      _diff_cache[k] = nil
    end
  end
end

---Drop the fan-out cache for one workspace root (or all when nil).
---@param workspace_root string?
function M.invalidate_fan_out(workspace_root)
  if workspace_root then
    _fan_out_cache[workspace_root] = nil
  else
    _fan_out_cache = {}
  end
end

-- ── auto-invalidation via topic subscriptions ────────────────

local _subscribed = false
local function _subscribe()
  -- Worktree topology changed → fan-out is stale.
  events.subscribe("worktree:added",    function() M.invalidate_fan_out() end)
  events.subscribe("worktree:removed",  function() M.invalidate_fan_out() end)
  -- Switching the active worktree doesn't change the SET of repos under
  -- the workspace root, but consumers commonly want to refresh the
  -- repo list label/sort order for the new context. Cheap to drop.
  events.subscribe("worktree:switched", function() M.invalidate_fan_out() end)
end

local function _ensure_subscribed()
  if _subscribed then return end
  _subscribed = true
  _subscribe()
end

_ensure_subscribed()

-- ── test-only ────────────────────────────────────────────────

---Test-only: clear caches AND re-establish topic subscriptions.
---Smoke tests typically call `events._reset_for_tests()` between
---sections, which wipes our subscription; this re-arms it so the
---auto-invalidation behavior survives the reset.
function M._reset_for_tests()
  M.clear_cache()
  _subscribed = false
  _ensure_subscribed()
end

return M
