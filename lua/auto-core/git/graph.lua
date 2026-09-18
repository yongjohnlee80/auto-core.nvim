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
---  repo_at(dir?, root?)            → repo?     single-repo identity ("where am I")
---  repo_label(common_dir, root, is_bare, worktree_dir?) → string
---  show_stat(common_dir, hash)     → string[]  cursor-preview cache
---  show_diff(common_dir, hash)     → string[]  full-diff cache (a merge diffs
---                                              against its FIRST parent)
---  working_diff(worktree)          → string[]  UNCACHED working-tree diff
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

---@type table<string, function[]>              workspace_root -> waiting callbacks
---In-flight coalescing for `fan_out_async`, mirroring `_show_inflight`: two
---opens of the same workspace before the first resolves share one walk rather
---than each spawning its own fleet of git probes.
local _fan_out_inflight = {}

---@type table<string, integer>                 workspace_root -> generation
---Bumped by `invalidate_fan_out`. A walk that was already running when the
---cache was invalidated gathered its facts BEFORE the event that invalidated
---them, so it still answers its own waiters (they asked, and stale beats
---hanging) but must not write that answer into the cache as though it were
---fresh. Without this, a refresh during a walk installs the very state the
---refresh was asked to discard.
local _fan_out_gen = {}

---@type table<string, string[]>                "<common_dir>:<hash>" -> lines
local _stat_cache = {}

---@type table<string, string[]>                "<common_dir>:<hash>" -> lines
local _diff_cache = {}

local function _cache_key(common_dir, hash)
  return common_dir .. ":" .. hash
end

---_show_diff_argv is the ONE argv both `show_diff` and `show_diff_async` run,
---so the two cannot drift apart.
---
---`-m --first-parent` is load-bearing for MERGE commits. A plain `git show -p`
---on a merge prints a COMBINED diff (`--cc`): only the hunks that differ from
---EVERY parent, which for a clean merge is nothing at all. `diff.parse` then
---returned zero files and the repos panel said "no diff" for exactly the
---commits a PR workflow puts on `main` (auto-finder, 2026-09-02).
---`log.commit_files` already lists a merge's files with
---`diff-tree -m --first-parent`; the diff must answer for the SAME files, or
---the tree lists what the view cannot show. `-m` splits the merge into one
---diff per parent and `--first-parent` keeps the one against the branch it
---landed on — "what did this merge bring in". Both flags are no-ops on a
---single-parent commit, so every other diff is byte-identical to before.
---Needs git >= 2.31 (2021) for `--first-parent` to select the diff under
---`git show`; older gits emit a diff per parent instead.
local function _show_diff_argv(common_dir, hash)
  return {
    "git", "--git-dir=" .. common_dir,
    "show", "-p", "-m", "--first-parent", "--no-color", hash,
  }
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

---Derive a stable label for a discovered repo from three probed facts:
---the common-dir, whether the repo is bare, and the worktree it was
---discovered through. The label is always the PROJECT folder — never the
---git directory's location, which is storage topology, not identity.
---
---Three layouts, three anchors:
---  * `.git`/`.bare` **container** (`<project>/.git`, `<project>/.bare`):
---    the project is the dir above the container. Covers a regular repo's
---    main worktree and a bare repo in a `.bare` container.
---  * **bare-at-root** (`is_bare` and NO container — the common-dir IS the
---    folder, e.g. `auto-run.nvim`, discovered via its worktree's `.git`
---    file): the project is the common-dir itself.
---  * **non-bare, non-container** (`git init --separate-git-dir`, whose
---    common-dir is an arbitrary EXTERNAL metadata dir): the project is the
---    discovered worktree, NOT the metadata dir. Basename alone cannot tell
---    this apart from bare-at-root — `is_bare` is what distinguishes them.
---Public because two consumers outside this module need the SAME answer
---`fan_out` gives: auto-finder's panel heading and AutoVim's bufferline
---offset both name "the repo I am in", and a second derivation would
---disagree with the repos panel the moment a layout is unusual (Johno,
---2026-09-08).
---@param common_dir string
---@param root string?          workspace root; "" when unknown
---@param is_bare boolean
---@param worktree_dir string?   the working tree the repo was discovered through
---@return string
function M.repo_label(common_dir, root, is_bare, worktree_dir)
  root = (type(root) == "string" and root ~= "") and root:gsub("/+$", "") or ""
  local container = vim.fn.fnamemodify(common_dir, ":t")
  local project
  if container == ".git" or container == ".bare" then
    project = vim.fn.fnamemodify(common_dir, ":h")
  elseif is_bare then
    project = common_dir
  else
    project = worktree_dir or vim.fn.fnamemodify(common_dir, ":h")
  end
  if project == root then
    return vim.fn.fnamemodify(project, ":t")
  end
  if vim.startswith(project, root .. "/") then
    return project:sub(#root + 2)
  end
  return vim.fn.fnamemodify(project, ":~")
end

---Identify the repository containing `dir`, WITHOUT walking a workspace.
---
---`fan_out` answers "which repos are under this root"; this answers "which
---repo am I in", which is a different question with a much cheaper answer —
---two `git rev-parse` reads instead of a bounded directory walk. Callers that
---used `fan_out` for this had to scan a whole workspace and then match
---common-dirs by hand.
---
---`branch` is the CURRENT branch of `dir`, not the repo's default: the caller
---asking "where am I" wants the checkout it is standing in. `nil` when HEAD is
---detached — a detached HEAD has no branch, and inventing one ("HEAD") reads
---like a branch actually called that.
---@param dir string?            defaults to cwd
---@param root string?           workspace root, for label relativisation
---@return { common_dir: string, label: string, branch: string?, is_bare: boolean, worktree: string }?
function M.repo_at(dir, root)
  dir = (type(dir) == "string" and dir ~= "") and dir or vim.fn.getcwd()
  if vim.fn.isdirectory(dir) ~= 1 then return nil end

  local top = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then return nil end
  local worktree = (top[1] or ""):gsub("/+$", "")
  if worktree == "" then return nil end

  local info = _probe(worktree)
  if not info then return nil end

  local head = vim.fn.systemlist({ "git", "-C", worktree, "symbolic-ref", "--short", "HEAD" })
  local branch = (vim.v.shell_error == 0) and (head[1] or ""):gsub("%s+$", "") or ""

  return {
    common_dir = info.common_dir,
    label      = M.repo_label(info.common_dir, root, info.is_bare, worktree),
    branch     = branch ~= "" and branch or nil,
    is_bare    = info.is_bare,
    worktree   = worktree,
  }
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
---_record_into folds one probed directory into an accumulating result set.
---
---Shared by `fan_out` and `fan_out_async` deliberately: the two differ only in
---HOW they reach a probe result, and a second copy of this would be a second
---answer to "what did we discover" that could drift from the first.
---
---MUST run on the main loop — `M.repo_label` calls `vim.fn.fnamemodify`, which
---is not safe from a `vim.system` callback.
---@param results table[]
---@param seen table<string, integer>  common_dir -> index in results
---@param workspace_root string
---@param parent_dir string
---@param info { common_dir: string, is_bare: boolean, is_working_tree: boolean }
local function _record_into(results, seen, workspace_root, parent_dir, info)
  local idx = seen[info.common_dir]
  if idx then
    if info.is_working_tree and not results[idx].sample_worktree then
      results[idx].sample_worktree = parent_dir
    end
    return
  end
  results[#results + 1] = {
    common_dir      = info.common_dir,
    label           = M.repo_label(info.common_dir, workspace_root, info.is_bare, parent_dir),
    sample_worktree = info.is_working_tree and parent_dir or nil,
    is_bare         = info.is_bare,
  }
  seen[info.common_dir] = #results
end

---_probe_async is `_probe` without blocking the loop: the same two git calls,
---chained because the second needs the first's common-dir.
---
---`cb(info|nil)` may run OFF the main loop. Callers must not touch editor state
---from it without `vim.schedule`.
---@param dir string
---@param cb fun(info: table|nil)
local function _probe_async(dir, cb)
  vim.system({
    "git", "-C", dir, "rev-parse",
    "--path-format=absolute",
    "--git-common-dir",
    "--is-inside-work-tree",
  }, { text = true }, function(res)
    if res.code ~= 0 then return cb(nil) end
    local out = vim.split(res.stdout or "", "\n", { plain = true })
    if out[#out] == "" then table.remove(out) end
    if #out < 2 then return cb(nil) end
    local common = (out[1] or ""):gsub("/+$", "")
    vim.system({
      "git", "--git-dir=" .. common, "config",
      "--bool", "--default", "false", "core.bare",
    }, { text = true }, function(res2)
      local b = vim.split(res2.stdout or "", "\n", { plain = true })
      cb({
        common_dir      = common,
        is_bare         = (b[1] or "") == "true",
        is_working_tree = out[2] == "true",
      })
    end)
  end)
end

---_walk_async mirrors `fan_out`'s `walk`, with one structural difference that
---is the whole reason this cannot be "collect the dirs, then probe them all":
---**descent is gated on the probe result**. A non-bare repository stops the
---walk, so whether to recurse is not known until its probe returns.
---
---`done()` is called exactly once per invocation, on every path.
---@param dir string
---@param depth integer
---@param ctx { max_depth: integer, skip: table, found: table[] }
---@param done fun()
local function _walk_async(dir, depth, ctx, done)
  if depth > ctx.max_depth then return done() end
  local fd = vim.uv.fs_scandir(dir)
  if not fd then return done() end

  local subdirs, has_git = {}, false
  while true do
    local name, t = vim.uv.fs_scandir_next(fd)
    if not name then break end
    if name == ".git" or name == ".bare" then
      has_git = true
    elseif t == "directory"
        and not ctx.skip[name]
        and not name:match("^%.")
    then
      subdirs[#subdirs + 1] = name
    end
  end
  -- Sorted, and sorted in the SYNC walk too. `fs_scandir` order is
  -- filesystem-dependent, so an unsorted traversal makes "which directory was
  -- seen first" unstable — and that decides which `sample_worktree` a bare
  -- repo with several linked worktrees keeps. With both walks visiting
  -- children in name order, a depth-first pre-order visit is exactly
  -- lexicographic path order, which is what lets the async path replay its
  -- out-of-order completions by sorted path and land on the sync answer.
  table.sort(subdirs)

  local function descend()
    if #subdirs == 0 then return done() end
    local remaining = #subdirs
    for _, name in ipairs(subdirs) do
      _walk_async(dir .. "/" .. name, depth + 1, ctx, function()
        remaining = remaining - 1
        if remaining == 0 then done() end
      end)
    end
  end

  if not has_git then return descend() end

  _probe_async(dir, function(info)
    if info then
      ctx.found[#ctx.found + 1] = { dir = dir, info = info }
      -- A non-bare repository is a leaf: do not walk into someone's checkout.
      if not info.is_bare then return done() end
    end
    descend()
  end)
end

---fan_out_async is `fan_out` without blocking the UI thread.
---
---`fan_out` spawns two synchronous `git` processes per repository directory it
---finds — on a workspace of 70 such directories that is 140 serial spawns, all
---of them before the caller can paint anything. This runs the same discovery
---off the loop and hands the result back on it.
---
---Ordering: probe completions arrive in whatever order the processes finish, so
---discoveries are replayed in sorted PATH order before being recorded. Without
---that, which directory "wins" a duplicated common-dir — and therefore which
---`sample_worktree` is kept — would vary run to run.
---
---`cb(repos)` always runs on the main loop, including on a cache hit.
---@param workspace_root string
---@param opts { max_depth: integer?, skip_dirs: table? }?
---@param cb fun(repos: AutoCoreGraphRepo[])
function M.fan_out_async(workspace_root, opts, cb)
  if type(cb) ~= "function" then return end
  if type(workspace_root) ~= "string" or workspace_root == "" then
    return vim.schedule(function() cb({}) end)
  end
  workspace_root = (vim.fs.normalize(workspace_root) or workspace_root):gsub("/+$", "")

  local hit = _fan_out_cache[workspace_root]
  if hit then return vim.schedule(function() cb(hit) end) end

  -- A caller arriving AFTER an invalidation must not join a flight that
  -- started before it — the point of invalidating is that the earlier answer is
  -- no longer trusted, and a late joiner would be handed exactly that.
  --
  -- `invalidate_fan_out` enforces this by DEREGISTERING the flight, so any
  -- registration still present here belongs to the current generation by
  -- construction. That is the single mechanism; a generation comparison here
  -- as well would be a second one that can never fire, and an unexercised
  -- branch is an untested one.
  local gen = _fan_out_gen[workspace_root] or 0
  local flight = _fan_out_inflight[workspace_root]
  if flight then
    flight.cbs[#flight.cbs + 1] = cb
    return
  end

  -- `cbs` is held locally as well as in the table: an invalidation clears the
  -- registration so new callers start a fresh walk, and this flight must still
  -- be able to answer the callers it already accepted.
  local cbs = { cb }
  _fan_out_inflight[workspace_root] = { cbs = cbs }
  -- Test seam, mirroring `_async_spawn_count`: counts walks that actually run,
  -- so a cell can tell a real discovery from a cache hit. Whether the cache
  -- was served is otherwise unobservable from outside — both paths deliver
  -- through `vim.schedule`.
  M._fan_out_walk_count = (M._fan_out_walk_count or 0) + 1

  opts = opts or {}
  local ctx = {
    max_depth = opts.max_depth or 3,
    skip      = opts.skip_dirs or _DEFAULT_SKIP,
    found     = {},
  }

  _walk_async(workspace_root, 0, ctx, function()
    vim.schedule(function()
      table.sort(ctx.found, function(a, b) return a.dir < b.dir end)
      local results, seen = {}, {}
      for _, e in ipairs(ctx.found) do
        _record_into(results, seen, workspace_root, e.dir, e.info)
      end
      table.sort(results, function(a, b) return a.label < b.label end)

      -- Cache BEFORE the callbacks, so a cb that re-queries gets a hit rather
      -- than starting a second walk — but only if nothing invalidated this
      -- workspace while the walk was running.
      local current = (_fan_out_gen[workspace_root] or 0) == gen
      if current then
        _fan_out_cache[workspace_root] = results
      end
      -- Deregister only our OWN flight: an invalidation may already have
      -- cleared it, and a newer flight may already have taken the slot.
      local reg = _fan_out_inflight[workspace_root]
      if reg and reg.cbs == cbs then
        _fan_out_inflight[workspace_root] = nil
      end
      -- Answer the callers this flight accepted, current or not: they asked,
      -- and a stale list beats hanging forever. Only the CACHE is gated.
      for _, fn in ipairs(cbs) do pcall(fn, results) end
    end)
  end)
end

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
    _record_into(results, seen, workspace_root, parent_dir, info)
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
    -- See `_walk_async`: both walks visit children in name order so the two
    -- paths cannot disagree about which directory was seen first.
    table.sort(subdirs)
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
  local out = vim.fn.systemlist(_show_diff_argv(common_dir, hash))
  if vim.v.shell_error ~= 0 then
    lines = { "(auto-core.git.graph: git show -p failed)", "" }
    vim.list_extend(lines, out)
  else
    lines = out
  end
  _diff_cache[key] = lines
  return lines
end

---Uncached `git diff HEAD` for a WORKING TREE, plus each untracked file.
---
---Deliberately NOT cached, unlike `show_diff`. A commit's diff is immutable, so
---caching it by hash is free; the working tree changes under you between every
---keypress, and a cached answer there would show stale content with no way to
---know it was stale.
---
---Takes a WORKTREE path, not a common dir: there is no working tree to diff
---without one — the same asymmetry `git.log.working_changes` has.
---
---`diff HEAD` covers staged AND unstaged changes to tracked files in one pass.
---Untracked files are invisible to it, so each is appended as a `--no-index`
---diff against /dev/null. That matters here: the panel already LISTS untracked
---files under UNCOMMITTED, so omitting them would show a file in the tree whose
---diff came back empty.
---@param worktree string
---@return string[] lines
function M.working_diff(worktree)
  if not worktree or worktree == "" then return {} end
  local base = {
    "git", "-C", worktree,
    "--no-optional-locks", "-c", "core.quotepath=off", "-c", "color.diff=false",
  }

  local function run(extra)
    local argv = vim.deepcopy(base)
    vim.list_extend(argv, extra)
    local out = vim.fn.systemlist(argv)
    if vim.v.shell_error ~= 0 then
      return nil, out
    end
    return out
  end

  local lines, failed = run({ "diff", "--no-color", "HEAD" })
  if not lines then
    local msg = { "(auto-core.git.graph: git diff HEAD failed)", "" }
    vim.list_extend(msg, failed or {})
    return msg
  end

  -- Untracked, one `--no-index` diff each. `--no-index` exits 1 when the files
  -- differ (which they always do against /dev/null), so its output is taken
  -- regardless of status rather than treated as a failure.
  local untracked = run({ "ls-files", "--others", "--exclude-standard" }) or {}
  for _, rel in ipairs(untracked) do
    if rel ~= "" then
      local argv = vim.deepcopy(base)
      vim.list_extend(argv, { "diff", "--no-color", "--no-index", "/dev/null", rel })
      local out = vim.fn.systemlist(argv)
      for _, l in ipairs(out) do
        lines[#lines + 1] = l
      end
    end
  end
  return lines
end

-- ── async show (ADR-0038 Batch D1) ───────────────────────────
--
-- The sync show_stat/show_diff above block the UI thread on a cache
-- miss — 100-500ms for a large commit, felt as a hang when the
-- cursor lands on a new commit in a graph view. These ADDITIVE async
-- variants run the same git invocation via vim.system and deliver
-- the lines to `cb` on the main loop. Results land in the SAME
-- per-(common_dir, hash) caches, so any subsequent sync call is a
-- free hit. Concurrent requests for the same key coalesce into ONE
-- subprocess (rapid cursor moves re-previewing the same commit);
-- every caller's cb still fires. The sync functions are unchanged —
-- consumers migrate at their own pace (additive-only rule).

---@type table<string, fun(lines: string[])[]>  -- key → waiting callbacks
local _show_inflight = {}

---Test observability: subprocesses spawned by the async show paths.
M._async_spawn_count = 0

---Current cache table for `kind` — resolved at WRITE time so a
---clear_cache() that rebinds the module-local between spawn and
---completion doesn't resurrect results into an orphaned table.
---@param kind "stat"|"diff"
local function _cache_for(kind)
  if kind == "stat" then return _stat_cache end
  return _diff_cache
end

---@param kind "stat"|"diff"
---@param args string[]
---@param fail_banner string
---@param key string
---@param cb fun(lines: string[])
local function _show_async(kind, args, fail_banner, key, cb)
  local hit = _cache_for(kind)[key]
  if hit then
    vim.schedule(function() cb(hit) end)
    return
  end
  local waiters = _show_inflight[key]
  if waiters then
    waiters[#waiters + 1] = cb
    return
  end
  _show_inflight[key] = { cb }
  M._async_spawn_count = M._async_spawn_count + 1
  vim.system(args, { text = true }, function(res)
    local lines = vim.split(res.stdout or "", "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end  -- trailing-\n artifact
    if res.code ~= 0 then
      local out = lines
      lines = { fail_banner, "" }
      vim.list_extend(lines, out)
      for _, l in ipairs(vim.split(res.stderr or "", "\n", { plain = true })) do
        if l ~= "" then lines[#lines + 1] = l end
      end
    end
    vim.schedule(function()
      -- Cache BEFORE callbacks so a cb that re-queries (sync or
      -- async) gets an immediate hit.
      _cache_for(kind)[key] = lines
      local cbs = _show_inflight[key] or {}
      _show_inflight[key] = nil
      for _, fn in ipairs(cbs) do pcall(fn, lines) end
    end)
  end)
end

---Async `git show --stat` — same cache + line shape as `show_stat`,
---without blocking the UI thread on a cache miss. `cb(lines)` runs
---on the main loop (vim.schedule), including for immediate cache
---hits (consistent re-entrancy for the caller).
---@param common_dir string
---@param hash string
---@param cb fun(lines: string[])
function M.show_stat_async(common_dir, hash, cb)
  if type(cb) ~= "function" then return end
  if not common_dir or not hash or hash == "" then
    vim.schedule(function() cb({}) end)
    return
  end
  _show_async("stat", {
    "git", "--git-dir=" .. common_dir,
    "show", "--stat", "--no-color", "--format=fuller", hash,
  }, "(auto-core.git.graph: git show --stat failed)",
    _cache_key(common_dir, hash), cb)
end

---Async `git show -p` — same cache + line shape as `show_diff`,
---without blocking the UI thread on a cache miss. `cb(lines)` runs
---on the main loop.
---@param common_dir string
---@param hash string
---@param cb fun(lines: string[])
function M.show_diff_async(common_dir, hash, cb)
  if type(cb) ~= "function" then return end
  if not common_dir or not hash or hash == "" then
    vim.schedule(function() cb({}) end)
    return
  end
  _show_async("diff", _show_diff_argv(common_dir, hash),
    "(auto-core.git.graph: git show -p failed)",
    _cache_key(common_dir, hash), cb)
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
  ---_retire bumps one root's generation and drops its in-flight registration.
  ---
  ---Both halves are needed. The generation stops the running walk installing a
  ---result it gathered BEFORE this call. Dropping the registration stops a
  ---caller arriving after this call from joining that walk and being handed
  ---the very answer the invalidation discarded. The walk keeps its own
  ---reference to the callers it already accepted, so retiring it here strands
  ---nobody.
  local function _retire(root)
    _fan_out_cache[root] = nil
    _fan_out_gen[root] = (_fan_out_gen[root] or 0) + 1
    _fan_out_inflight[root] = nil
  end

  if workspace_root then
    _retire(workspace_root)
    return
  end

  -- All roots. Iterating `_fan_out_gen` alone is not enough: a root whose
  -- FIRST walk is still running has no generation entry yet (it captured an
  -- implicit 0), so it would be skipped and would then cache its stale result
  -- against an unchanged generation. The in-flight and cache tables name the
  -- roots that matter; take the union.
  local roots = {}
  for k in pairs(_fan_out_cache) do roots[k] = true end
  for k in pairs(_fan_out_gen) do roots[k] = true end
  for k in pairs(_fan_out_inflight) do roots[k] = true end
  for k in pairs(roots) do _retire(k) end
  _fan_out_cache = {}
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
