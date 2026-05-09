---Canonical worktree implementation for the AutoVim family.
---
---**REVERSED dependency direction per ADR 0006 §"worktree.nvim
---migration plan".** The bulk of worktree-related logic that used
---to live in `worktree.nvim/git.lua` moves here:
---
---  - porcelain parser
---  - per-repo + workspace-wide worktree listing
---  - branch listing / lookup helpers
---  - workspace memory (active worktree + workspace root) backed by
---    `auto-core.state` so it survives nvim restarts
---  - canonical events: `worktree:added`, `worktree:removed`,
---    `core.active_worktree:changed`, `core.workspace_root:changed`
---
---`worktree.nvim` becomes a thin wrapper: its public API surface
---(`set_root` / `get_root` / `pick` / `add` / `home` / `clone` /
---etc.) is preserved, but every data-layer call routes through
---this module. External consumers of `worktree.nvim` keep working;
---internal AutoVim consumers can migrate to require this module
---directly.
---
---Public surface — pure parsers + queries (no state, no events):
---
---  M.parse_porcelain(lines)               → entry[]
---  M.list(repo_path?)                     → entry[]?, err
---  M.collect(workspace_dir?)              → entry[]?, err
---  M.list_child_repos(dir?)               → repo[]
---  M.list_branches(repo_path?)            → branch[]
---  M.find_remote_branches(repo_path,name) → match[]
---  M.worktree_for_branch(repo_path,br)    → string?
---  M.local_branch_exists(repo_path,name)  → boolean
---  M.default_branch(repo_path?)           → string
---  M.repo_name_from_url(url)              → string
---  M.repo_container(common_dir)           → string
---
---Public surface — workspace memory (uses `auto-core.state`):
---
---  M.set_active(path)                     -- → publishes core.active_worktree:changed
---  M.get_active()                         → string?
---  M.set_workspace_root(path)             -- → publishes core.workspace_root:changed
---  M.get_workspace_root()                 → string?
---
---State persistence:
---  Namespace `core` (json backend) carries:
---    active_worktree: string?    -- the wt the user is currently inside
---    workspace_root:  string?    -- the parent dir of the active worktree
---    cwd:             string?    -- last-seen cwd (unrelated, by core itself)
---@module 'auto-core.git.worktree'

local events    = require("auto-core.events")
local state_mod = require("auto-core.state")
local path_mod  = require("auto-core.fs.path")

local M = {}

-- Lazy-init the core state namespace. We can't claim it at module
-- load because state_mod.namespace runs file IO; deferring keeps
-- `require` cheap. claim_state() is idempotent.
local _ns = nil
local function claim_state()
  if _ns then return _ns end
  _ns = state_mod.namespace("core", {
    defaults = {
      active_worktree = nil,
      workspace_root  = nil,
    },
    persist = "json",
  })
  return _ns
end

-- ── pure data layer (verbatim port from worktree.nvim/git.lua) ──

---Parse `git worktree list --porcelain` output (already split into
---lines) into a list of `{ path, branch?, head?, bare?, detached? }`
---records. Pure function — no IO, no shell.
---@param lines string[]
---@return AutoCoreWorktreeEntry[]
function M.parse_porcelain(lines)
  local out, cur = {}, nil
  local function flush()
    if cur and cur.path then table.insert(out, cur) end
    cur = nil
  end
  for _, line in ipairs(lines) do
    if line:match("^worktree ") then
      flush()
      cur = { path = line:sub(10) }
    elseif cur then
      local branch = line:match("^branch (.+)$")
      if branch then
        cur.branch = branch:gsub("^refs/heads/", "")
      elseif line:match("^HEAD ") then
        cur.head = line:sub(6, 13)
      elseif line == "bare" then
        cur.bare = true
      elseif line == "detached" then
        cur.detached = true
      end
    end
  end
  flush()
  return out
end

---@class AutoCoreWorktreeEntry
---@field path     string         -- absolute path
---@field branch   string?        -- short branch name; nil if detached
---@field head     string?        -- 7-char short HEAD
---@field bare     boolean?       -- true for the bare-repo entry itself
---@field detached boolean?

---Run `git -C <repo_path> worktree list --porcelain` and parse it.
---Returns nil + err when the shell call fails.
---@param repo_path string?       -- defaults to cwd
---@return AutoCoreWorktreeEntry[]?, string?
function M.list(repo_path)
  local cwd = repo_path or vim.fn.getcwd()
  local result = vim.system(
    { "git", "-C", cwd, "worktree", "list", "--porcelain" },
    { text = true }
  ):wait()
  if result.code ~= 0 then
    return nil, "git worktree list failed: " ..
      tostring(result.stderr or "(no stderr)")
  end
  local lines = {}
  for line in (result.stdout or ""):gmatch("([^\n]+)") do
    lines[#lines + 1] = line
  end
  return M.parse_porcelain(lines)
end

---Walk `dir`'s immediate children, run `git worktree list --porcelain`
---against each git-managed child, dedupe paths, drop bare entries.
---Returns the union of every child repo's worktrees, sorted by path.
---@param workspace_dir string?  -- defaults to cwd
---@return AutoCoreWorktreeEntry[]?, string?
function M.collect(workspace_dir)
  local dir = workspace_dir or vim.fn.getcwd()
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return nil, "auto-core.git.worktree.collect: cannot scandir " .. dir
  end
  local seen, out = {}, {}
  while true do
    local name, t = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if (t == "directory" or t == "link") and not name:match("^%.") then
      local full = dir .. "/" .. name
      if path_mod.exists(full .. "/.git") then
        local entries = M.list(full)
        if entries then
          for _, wt in ipairs(entries) do
            if not wt.bare then
              wt.path = path_mod.normalize(wt.path)
              if not seen[wt.path] then
                seen[wt.path] = true
                table.insert(out, wt)
              end
            end
          end
        else
          -- Repo dir but `git worktree list` failed (corrupt? bare
          -- container?) — include the path so the workspace listing
          -- still surfaces it, but without metadata.
          local p = path_mod.normalize(full)
          if not seen[p] then
            seen[p] = true
            table.insert(out, { path = p })
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end

---List immediate child directories of `dir` that are git-managed.
---Sorted by name. Useful for building a "registered repos" picker.
---@param dir string?     -- defaults to cwd
---@return { name: string, path: string }[]
function M.list_child_repos(dir)
  local repos = {}
  local cwd = dir or vim.fn.getcwd()
  local handle = vim.uv.fs_scandir(cwd)
  if not handle then return repos end
  while true do
    local name, t = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if (t == "directory" or t == "link") and not name:match("^%.") then
      local full = cwd .. "/" .. name
      if path_mod.exists(full .. "/.git") then
        repos[#repos + 1] = { name = name, path = path_mod.normalize(full) }
      end
    end
  end
  table.sort(repos, function(a, b) return a.name < b.name end)
  return repos
end

---List local branches in `repo_path`, sorted with `main`/`master`
---floated to the top so the first option is usually right.
---@param repo_path string?
---@return string[]
function M.list_branches(repo_path)
  local cwd = repo_path or vim.fn.getcwd()
  local result = vim.system(
    { "git", "-C", cwd, "for-each-ref",
      "--format=%(refname:short)", "refs/heads" },
    { text = true }
  ):wait()
  if result.code ~= 0 then return {} end
  local lines = {}
  for line in (result.stdout or ""):gmatch("([^\n]+)") do
    lines[#lines + 1] = line
  end
  table.sort(lines, function(a, b)
    local function rank(s)
      if s == "main"   then return 0 end
      if s == "master" then return 1 end
      return 2
    end
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return lines
end

---Returns true if `repo_path` has a local branch named `name`.
---@param repo_path string
---@param name      string
---@return boolean
function M.local_branch_exists(repo_path, name)
  local result = vim.system(
    { "git", "-C", repo_path, "rev-parse", "--verify", "--quiet",
      "refs/heads/" .. name },
    { text = true }
  ):wait()
  return result.code == 0
end

---Path of the worktree currently checking out `branch` in `repo_path`,
---or nil if no worktree has it. Git refuses to check out the same
---branch in two worktrees, so this tells callers when "use existing
---local branch" is actually available.
---@param repo_path string
---@param branch    string
---@return string?
function M.worktree_for_branch(repo_path, branch)
  local entries = M.list(repo_path)
  if not entries then return nil end
  for _, wt in ipairs(entries) do
    if wt.branch == branch then return wt.path end
  end
  return nil
end

---Find every remote-tracking branch whose short name equals `name`.
---Returns `{ { remote = string, ref = "remote/branch" }, ... }`.
---@param repo_path string
---@param name      string
---@return { remote: string, ref: string }[]
function M.find_remote_branches(repo_path, name)
  local result = vim.system(
    { "git", "-C", repo_path, "for-each-ref",
      "--format=%(refname:short)", "refs/remotes/" },
    { text = true }
  ):wait()
  if result.code ~= 0 then return {} end
  local matches = {}
  for line in (result.stdout or ""):gmatch("([^\n]+)") do
    -- Remote names contain no `/`; branch names may. Anchor remote
    -- at `[^/]+` and let branch consume everything after the first /.
    local remote, branch = line:match("^([^/]+)/(.+)$")
    if remote and branch == name and not line:match("/HEAD$") then
      matches[#matches + 1] = { remote = remote, ref = line }
    end
  end
  return matches
end

---Symbolic HEAD (short form) for `repo_path`. Falls back to "main"
---if HEAD isn't resolvable (e.g. a freshly-init'd repo with no
---commits). Defaults to cwd.
---@param repo_path string?
---@return string
function M.default_branch(repo_path)
  local cwd = repo_path or vim.fn.getcwd()
  local result = vim.system(
    { "git", "-C", cwd, "symbolic-ref", "--short", "HEAD" },
    { text = true }
  ):wait()
  if result.code == 0 then
    local head = (result.stdout or ""):gsub("\n+$", "")
    if head ~= "" then return head end
  end
  return "main"
end

---Derive a repo name from a git URL or local path.
---  git@github.com:foo/bar.git     → bar
---  https://github.com/foo/bar.git → bar
---  https://github.com/foo/bar     → bar
---  /path/to/myrepo                → myrepo
---@param url string
---@return string
function M.repo_name_from_url(url)
  local s = url:gsub("/+$", "")
  local name = s:match("[^/:]+$") or s
  return (name:gsub("%.git$", ""))
end

---Container directory for new worktrees: parent of `common_dir`.
---  /foo/repo/.bare → /foo/repo
---  /foo/repo/.git  → /foo/repo
---  /foo/repo.git   → /foo
---@param common_dir string
---@return string
function M.repo_container(common_dir)
  return vim.fn.fnamemodify(common_dir, ":h")
end

-- ── workspace memory (state-backed, event-publishing) ────────

---Set the currently-active worktree path. Persists to state, then
---publishes `core.active_worktree:changed` with `{ from, to, cwd }`.
---@param path string?
function M.set_active(path)
  local ns = claim_state()
  local from = ns:get("active_worktree")
  -- Don't use `(cond) and nil or X` — Lua's ternary breaks when the
  -- "true" branch is nil (a falsy value); it falls through to X. Use
  -- explicit if/else instead.
  local to = nil
  if path ~= nil then to = path_mod.normalize(path) end
  if from == to then return end
  ns:set("active_worktree", to)
  events.publish("core.active_worktree:changed", {
    from = from,
    to   = to,
    cwd  = vim.fn.getcwd(),
  })
end

---Currently-active worktree path (last value passed to set_active).
---@return string?
function M.get_active()
  return claim_state():get("active_worktree")
end

---Set the workspace root (the directory whose immediate children are
---worktree-bearing repos). Persists, publishes
---`core.workspace_root:changed` with `{ from, to }`.
---@param path string?
function M.set_workspace_root(path)
  local ns = claim_state()
  local from = ns:get("workspace_root")
  local to = nil
  if path ~= nil then to = path_mod.normalize(path) end
  if from == to then return end
  ns:set("workspace_root", to)
  events.publish("core.workspace_root:changed", { from = from, to = to })
end

---Currently-set workspace root.
---@return string?
function M.get_workspace_root()
  return claim_state():get("workspace_root")
end

---Test-only — clears the state namespace so smoke tests start clean.
function M._reset_for_tests()
  if _ns then
    pcall(function() _ns:set("active_worktree", nil) end)
    pcall(function() _ns:set("workspace_root", nil) end)
  end
  _ns = nil
end

return M
