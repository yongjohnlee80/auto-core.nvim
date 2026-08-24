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
---is_option_shaped reports whether a value would be parsed by git as a FLAG
---rather than as data.
---
---This is the guard that was missing. `reset_soft(cwd, "--hard")` interpolated
---straight into the argv, git read it as a second mode, the later mode won, and
---the call returned ok=true having destroyed both the index and the working
---tree. The module claimed "--hard is not reachable" and a source-grep test
---asserted the string's absence from the file — which says nothing at all about
---what a caller may pass in. Every data argument that reaches an argv position
---goes through here now.
---@param v any
---@return boolean
local function is_option_shaped(v)
  return type(v) == "string" and v:sub(1, 1) == "-"
end

---resolve_commit turns a ref into a verified OID, or nil plus a reason.
---
---Resolving rather than passing the caller's string through is the belt to that
---brace: an OID cannot be re-read as a flag, a path, or anything else, so even
---a ref this guard failed to anticipate arrives at git as 40 hex characters.
---@param cwd string
---@param ref string
---@return string|nil oid, string|nil err
local function resolve_commit(cwd, ref)
  if is_option_shaped(ref) then
    return nil, ("refusing option-shaped ref %q — pass a ref, not a flag"):format(ref)
  end
  local r = vim.system(
    { "git", "--no-optional-locks", "-C", cwd, "rev-parse", "--verify", "--quiet",
      ref .. "^{commit}" },
    { text = true }
  ):wait()
  local oid = vim.trim(r.stdout or "")
  if r.code ~= 0 or not oid:match("^%x+$") then
    return nil, ("cannot resolve ref %q"):format(tostring(ref))
  end
  return oid, nil
end

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

---validate_branch checks that `branch` really is a branch NAME.
---
---A dash-prefix guard is the wrong shape for this field, and that was the second
---boundary bug here. `opts.branch` lands in git's REFSPEC position, where the
---control syntax does not begin with a dash at all:
---
---    branch = "+HEAD~1:refs/heads/main"   -- force-rewinds the remote
---    branch = ":refs/heads/main"          -- DELETES the remote branch
---
---Both were accepted and both worked, returning ok=true; a probe rewound a bare
---remote and then deleted its `main`. The panel's confirmation names only the
---repository, so neither was anything the user agreed to.
---
---`git check-ref-format --branch` is the authority rather than a hand-rolled
---pattern: it accepts `main` and `feature/x` and rejects `+a:b`, `:b`, `HEAD~1`,
---`--force`, embedded spaces, the empty string and `@{-1}`. Writing that
---character class myself is how the next spelling gets missed.
---Returns git's NORMALIZED branch name, or nil plus a reason.
---
---The normalization is consumed rather than discarded, which is the same
---principle as resolving a ref to an OID: whatever git accepts arrives at the
---argv as a concrete branch name. The first version threw the stdout away and
---passed the caller's original token, so `@{-1}` — which check-ref-format
---resolves to the previous branch after a real switch — reached git as the
---literal `@{-1}`. It could not force or delete anything, but a branch-only
---field should not pass through checkout-stack syntax unresolved.
---@param cwd string
---@param branch string
---@return string|nil name, string|nil err
local function resolve_branch(cwd, branch)
  local r = vim.system(
    { "git", "--no-optional-locks", "-C", cwd, "check-ref-format", "--branch", branch },
    { text = true }
  ):wait()
  local name = vim.trim(r.stdout or "")
  if r.code ~= 0 or name == "" then
    return nil, ("push: %q is not a valid branch name — this field takes a branch, "
      .. "not a refspec (no leading '+' force, no leading ':' delete)"):format(
        tostring(branch))
  end
  return name, nil
end

---validate_remote requires `remote` to be one this repo actually has.
---
---Membership, not a character class. The first version used
---`^[%w._%-]+$`, which refuses git-VALID remote names — `foo/bar` and `foo+bar`
---are both configurable and both were rejected. That is the third time in this
---module that hand-writing a piece of git's grammar was wrong, so it stops:
---`git remote` is enumerated through a hardened read and the requested name has
---to match one of them exactly.
---
---It also gives a strictly better interpretation boundary than any pattern
---could. A name that is not a configured remote is refused whatever characters
---it contains, so there is nothing left to smuggle through.
---@param cwd string
---@param remote string
---@return string|nil err
local function validate_remote(cwd, remote)
  local r = vim.system(
    { "git", "--no-optional-locks", "-C", cwd, "remote" }, { text = true }
  ):wait()
  if r.code ~= 0 then
    return ("push: cannot list remotes in %s"):format(tostring(cwd))
  end
  for line in (r.stdout or ""):gmatch("[^\r\n]+") do
    if vim.trim(line) == remote then return nil end
  end
  return ("push: %q is not a configured remote of this repository"):format(
    tostring(remote))
end

---reject_option_args returns an error string when any value is flag-shaped.
---@param label string
---@param values table
---@return string|nil
local function reject_option_args(label, values)
  for k, v in pairs(values) do
    if is_option_shaped(v) then
      return ("%s: refusing option-shaped %s %q"):format(label, tostring(k), tostring(v))
    end
  end
  return nil
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
  local cargs = { "git", "commit" }
  -- allow_empty used to skip the has_staged guard and then never pass the flag,
  -- so the "allowed" empty commit failed anyway in git. Either it works or it
  -- should not be in the signature.
  if opts.allow_empty then cargs[#cargs + 1] = "--allow-empty" end
  cargs[#cargs + 1] = "-m"
  cargs[#cargs + 1] = msg
  run(cwd, cargs, { timeout_ms = opts.timeout_ms },
    function(ok, err)
      events.publish("core.git.commit:completed",
        { cwd = cwd, ok = ok, stderr = err })
      if on_done then on_done(ok, err) end
    end)
end

---reset_soft moves HEAD back, keeping the index and working tree.
---
---`--soft` only, and now enforced rather than asserted: `ref` is resolved to a
---verified OID first, so it cannot arrive as another mode. The first version
---interpolated the caller's string and `reset_soft(cwd, "--hard")` was a
---working hard reset that reported success.
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
  -- Resolve to an OID before it reaches the argv. Passing the caller's string
  -- through is how `reset_soft(cwd, "--hard")` became a working hard reset.
  local oid, rerr = resolve_commit(cwd, ref or "HEAD~1")
  if not oid then
    if on_done then
      vim.schedule(function() on_done(false, "reset_soft: " .. tostring(rerr)) end)
    end
    return
  end
  run(cwd, { "git", "reset", "--soft", oid }, nil, function(ok, err)
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
---`branch` is a branch NAME, not a refspec — force and delete syntax are
---refused. If an arbitrary refspec is ever needed, that belongs in an explicit
---`refspec`/`force` API whose caller confirms what it is about to rewrite,
---rather than smuggled through a field documented as a branch.
---@param opts { remote: string?, branch: string?, set_upstream: boolean?, timeout_ms: integer?, label: string? }?
---@param on_done fun(ok: boolean, err: string?)?
function M.push(cwd, opts, on_done)
  opts = opts or {}
  local label = opts.label or cwd
  -- Two distinct boundaries, both checked BEFORE argv construction.
  --
  -- The dash guard catches a flag in either position. It is NOT sufficient for
  -- `branch`, which git reads as a refspec: `+a:b` forces and `:b` deletes, and
  -- neither starts with a dash. So `branch` is additionally validated as a real
  -- branch name, and `remote` as a plain remote name.
  local oerr = reject_option_args("push", { remote = opts.remote, branch = opts.branch })
  if not oerr and opts.remote then oerr = validate_remote(cwd, opts.remote) end
  local branch_name
  if not oerr and opts.branch then
    branch_name, oerr = resolve_branch(cwd, opts.branch)
  end
  if oerr then
    if on_done then vim.schedule(function() on_done(false, oerr) end) end
    return
  end
  local args = { "git", "push" }
  if opts.set_upstream then args[#args + 1] = "--set-upstream" end
  if opts.remote then args[#args + 1] = opts.remote end
  -- The RESOLVED name, never the caller's token.
  if branch_name then args[#args + 1] = branch_name end

  events.publish("core.git.push:started", { cwd = cwd, label = label })
  run(cwd, args, { timeout_ms = opts.timeout_ms or PUSH_TIMEOUT_MS },
    function(ok, err)
      events.publish("core.git.push:completed",
        { cwd = cwd, label = label, ok = ok, stderr = err })
      if on_done then on_done(ok, err) end
    end)
end

return M
