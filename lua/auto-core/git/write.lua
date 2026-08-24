---auto-core.git.write — the MUTATING git surface.
---
---Per ADR 0060 (repos panel git actions). This module exists so the family has
---exactly ONE owner for git writes. Before it there were two: auto-core's own
---`fetch` / `pull` / `repo.checkout` / `repo` remote-branch delete, and a
---separate set inside the vendored neo-tree fork
---(`auto-finder/neotree/sources/common/commands.lua`) which ran `git add`,
---`git commit` and `git push` with its own local async helper. Two owners means
---two places to harden, and they had already drifted: ADR-0040 Batch C moved
---that fork's commit/push off the UI thread but left `git add -A` on a
---blocking `vim.fn.system`.
---
---Public surface:
---
---  stage(cwd, paths, on_done?)      -- git add -- <paths>
---  unstage(cwd, paths, on_done?)    -- git restore --staged -- <paths>
---  stage_all(cwd, on_done?)         -- git add -A
---  commit(cwd, msg, opts?, on_done?)-- git commit -m <msg>
---  push(cwd, opts?, on_done?)       -- git push
---  reset_soft(cwd, ref?, on_done?)  -- git reset --soft (soft ONLY)
---  restore_worktree(cwd, paths, on_done?) -- discard working-tree changes
---  has_staged(cwd)                  -- sync probe: is anything staged?
---
---`on_done(ok, err)` always runs on the main loop.
---
---**These deliberately do NOT carry `--no-optional-locks`.** Every git READ in
---this family is hardened with it so the UI can never write the index (see
---`git/status.lua` and `git/log.lua`). On a write that flag is meaningless at
---best: taking the index lock is the entire point. `has_staged` is a read, so
---it keeps the hardening — the distinction is the reason this is stated rather
---than left to be inferred.
---
---Topics, following the existing granularity in `events/topics.lua` — a
---`:started`/`:completed` pair for network-bound work, a single past-tense
---topic for a fast local mutation:
---
---  core.git.index:changed     { cwd, action = 'stage'|'unstage'|'stage_all'|'reset_soft'|'restore', paths, ok, stderr? }
---  core.git.commit:completed  { cwd, ok, stderr? }
---  core.git.push:started      { cwd, label }
---  core.git.push:completed    { cwd, label, ok, stderr? }
---
---Note what is NOT published: `core.git.state:changed`. That topic is
---documented as *external* mutation observed by the fs watcher, and faking it
---from in-process code would make the one signal that means "something changed
---behind our back" untrustworthy. A watched repo refreshes anyway, because
---these writes touch `git_dir/index` and `HEAD` and the watcher sees that.
---@module 'auto-core.git.write'

local events = require("auto-core.events")

local M = {}

local DEFAULT_TIMEOUT_MS = 30000
-- Push crosses the network. fetch uses 30s; a push of a large history to a slow
-- remote legitimately takes longer, and a timeout mid-push is worse than a wait.
local PUSH_TIMEOUT_MS = 120000

---Normalize a path argument into a list.
---@param paths string|string[]|nil
---@return string[]
local function as_paths(paths)
  if paths == nil then return {} end
  if type(paths) == "string" then return { paths } end
  local out = {}
  for _, p in ipairs(paths) do
    if type(p) == "string" and p ~= "" then out[#out + 1] = p end
  end
  return out
end

---Run one git argv in `cwd`, async, callback on the main loop.
---
---`GIT_EDITOR=true` is set on every write: a `commit.template`, a hook, or a
---`commit -m` that git decides to reopen must never try to spawn an editor. The
---panel cannot host one, and the failure mode without this is a subprocess
---hanging forever on a terminal nobody can see.
---@param cwd string
---@param args string[]
---@param opts { timeout_ms: integer? }?
---@param on_done fun(ok: boolean, err: string?)?
local function run(cwd, args, opts, on_done)
  opts = opts or {}
  if type(cwd) ~= "string" or cwd == "" then
    if on_done then vim.schedule(function() on_done(false, "write: cwd required") end) end
    return
  end
  local env = vim.tbl_extend("force", vim.fn.environ(), {
    GIT_EDITOR = "true",
    GIT_TERMINAL_PROMPT = "0",  -- never block waiting for credentials
  })
  vim.system(args, {
    cwd = cwd,
    text = true,
    env = env,
    timeout = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
  }, vim.schedule_wrap(function(result)
    local ok = result.code == 0
    local err = vim.trim((result.stderr or "") .. (ok and "" or ("\n" .. (result.stdout or ""))))
    if err == "" then err = nil end
    if on_done then on_done(ok, ok and nil or err) end
  end))
end

M._run = run  -- test hook

---has_staged reports whether the index holds anything to commit.
---
---A READ, so it keeps `--no-optional-locks`. `git diff --cached --quiet` exits
---1 when there ARE staged changes and 0 when there are none, which is the
---inverse of the intuitive reading and the reason this is a named function
---rather than an inline call at each site.
---@param cwd string
---@return boolean
function M.has_staged(cwd)
  if type(cwd) ~= "string" or cwd == "" then return false end
  local r = vim.system(
    { "git", "--no-optional-locks", "-C", cwd, "diff", "--cached", "--quiet" },
    { text = true }
  ):wait()
  return r.code ~= 0
end

---has_head reports whether the repo has any commit yet.
---
---A READ, so it keeps the hardening. It exists because `unstage` has to choose
---its spelling: see the note there.
---@param cwd string
---@return boolean
function M.has_head(cwd)
  if type(cwd) ~= "string" or cwd == "" then return false end
  local r = vim.system(
    { "git", "--no-optional-locks", "-C", cwd, "rev-parse", "--verify", "--quiet", "HEAD" },
    { text = true }
  ):wait()
  return r.code == 0
end

---@param cwd string
---@param paths string|string[]
---@param on_done fun(ok: boolean, err: string?)?
function M.stage(cwd, paths, on_done)
  local list = as_paths(paths)
  if #list == 0 then
    if on_done then vim.schedule(function() on_done(false, "stage: no paths") end) end
    return
  end
  local args = { "git", "add", "--" }
  vim.list_extend(args, list)
  run(cwd, args, nil, function(ok, err)
    events.publish("core.git.index:changed",
      { cwd = cwd, action = "stage", paths = list, ok = ok, stderr = err })
    if on_done then on_done(ok, err) end
  end)
end

---unstage prefers `restore --staged`, and falls back to `reset` before the
---first commit.
---
---`restore --staged` is the better spelling: `git reset -- <path>` is overloaded,
---since the same verb moves HEAD in other forms, so a typo'd call site is a
---destructive one. But `restore --staged` restores FROM a source that defaults
---to HEAD, so in a repo with no commits it fails outright with
---`fatal: could not resolve 'HEAD'` — and "stage the first few files, then
---unstage one" is a completely ordinary thing to do while making an initial
---commit. `reset` has no such requirement.
---
---So the choice is made from whether HEAD exists, rather than picking one
---spelling and being wrong at one end. Found by a test against a fresh repo;
---the first implementation used `restore --staged` unconditionally and broke
---exactly that case.
---@param cwd string
---@param paths string|string[]
---@param on_done fun(ok: boolean, err: string?)?
function M.unstage(cwd, paths, on_done)
  local list = as_paths(paths)
  if #list == 0 then
    if on_done then vim.schedule(function() on_done(false, "unstage: no paths") end) end
    return
  end
  local args
  if M.has_head(cwd) then
    args = { "git", "restore", "--staged", "--" }
  else
    -- No commit yet: `reset` is the only spelling that works, and with an
    -- explicit `--` it cannot be read as a ref.
    args = { "git", "reset", "-q", "--" }
  end
  vim.list_extend(args, list)
  run(cwd, args, nil, function(ok, err)
    events.publish("core.git.index:changed",
      { cwd = cwd, action = "unstage", paths = list, ok = ok, stderr = err })
    if on_done then on_done(ok, err) end
  end)
end

---@param cwd string
---@param on_done fun(ok: boolean, err: string?)?
function M.stage_all(cwd, on_done)
  run(cwd, { "git", "add", "-A" }, nil, function(ok, err)
    events.publish("core.git.index:changed",
      { cwd = cwd, action = "stage_all", paths = {}, ok = ok, stderr = err })
    if on_done then on_done(ok, err) end
  end)
end

---commit refuses when nothing is staged.
---
---That refusal is the point rather than a convenience: with an empty index
---`git commit` would either fail with its own message or, depending on config,
---try to open an editor — and a panel cannot host one. Refusing early turns
---that into a caller-visible reason.
---@param cwd string
---@param msg string
---@param opts { allow_empty: boolean?, timeout_ms: integer? }?
---@param on_done fun(ok: boolean, err: string?)?
function M.commit(cwd, msg, opts, on_done)
  opts = opts or {}
  if type(msg) ~= "string" or vim.trim(msg) == "" then
    if on_done then vim.schedule(function() on_done(false, "commit: message required") end) end
    return
  end
  if not opts.allow_empty and not M.has_staged(cwd) then
    if on_done then
      vim.schedule(function() on_done(false, "commit: nothing staged") end)
    end
    return
  end
  run(cwd, { "git", "commit", "-m", msg }, { timeout_ms = opts.timeout_ms },
    function(ok, err)
      events.publish("core.git.commit:completed",
        { cwd = cwd, ok = ok, stderr = err })
      if on_done then on_done(ok, err) end
    end)
end

---reset_soft moves HEAD back, keeping the index and working tree.
---
---`--soft` only: the destructive spellings (`--hard`, `--mixed` losing the
---index) are deliberately not reachable through this surface. A panel key that
---can discard work is a different kind of feature and should have to be written
---on purpose, not reached by passing a flag through.
---@param cwd string
---@param ref string?  default "HEAD~1"
---@param on_done fun(ok: boolean, err: string?)?
function M.reset_soft(cwd, ref, on_done)
  if not M.has_head(cwd) then
    if on_done then
      vim.schedule(function() on_done(false, "reset_soft: no commit to undo") end)
    end
    return
  end
  run(cwd, { "git", "reset", "--soft", ref or "HEAD~1" }, nil, function(ok, err)
    events.publish("core.git.index:changed",
      { cwd = cwd, action = "reset_soft", paths = {}, ok = ok, stderr = err })
    if on_done then on_done(ok, err) end
  end)
end

---restore_worktree discards working-tree changes to `paths`, restoring from HEAD.
---
---`restore --source=HEAD` rather than `checkout HEAD --`: `checkout` is the most
---overloaded verb in git and the same word switches branches. This one cannot.
---
---**This destroys uncommitted work in those paths.** The confirmation belongs to
---the caller, for the same reason it does on `push`: only the surface with the
---user's attention can name what is about to be lost.
---@param cwd string
---@param paths string|string[]
---@param on_done fun(ok: boolean, err: string?)?
function M.restore_worktree(cwd, paths, on_done)
  local list = as_paths(paths)
  if #list == 0 then
    if on_done then vim.schedule(function() on_done(false, "restore: no paths") end) end
    return
  end
  if not M.has_head(cwd) then
    if on_done then
      vim.schedule(function() on_done(false, "restore: no commit to restore from") end)
    end
    return
  end
  local args = { "git", "restore", "--source=HEAD", "--" }
  vim.list_extend(args, list)
  run(cwd, args, nil, function(ok, err)
    events.publish("core.git.index:changed",
      { cwd = cwd, action = "restore", paths = list, ok = ok, stderr = err })
    if on_done then on_done(ok, err) end
  end)
end

---push publishes to a remote.
---
---Mechanical on purpose: it pushes when called, exactly as `fetch_one` fetches
---when called. The CONFIRMATION for an outward-facing action belongs to the
---surface that has the user's attention — a panel keypress must be confirmed
---there, where the repo being published can be named. Putting a prompt in here
---would make every programmatic caller fight a modal it cannot answer.
---@param cwd string
---@param opts { remote: string?, branch: string?, set_upstream: boolean?, timeout_ms: integer?, label: string? }?
---@param on_done fun(ok: boolean, err: string?)?
function M.push(cwd, opts, on_done)
  opts = opts or {}
  local label = opts.label or cwd
  local args = { "git", "push" }
  if opts.set_upstream then args[#args + 1] = "--set-upstream" end
  if opts.remote then args[#args + 1] = opts.remote end
  if opts.branch then args[#args + 1] = opts.branch end

  events.publish("core.git.push:started", { cwd = cwd, label = label })
  run(cwd, args, { timeout_ms = opts.timeout_ms or PUSH_TIMEOUT_MS },
    function(ok, err)
      events.publish("core.git.push:completed",
        { cwd = cwd, label = label, ok = ok, stderr = err })
      if on_done then on_done(ok, err) end
    end)
end

return M
