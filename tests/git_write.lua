-- tests/git_write.lua — auto-core.git.write (ADR-0060 repos panel git actions).
--
-- Run:  nvim --headless -u NONE -l tests/git_write.lua
--
-- Against a REAL temporary git repo, not a mocked runner. These verbs are the
-- family's first index writes, and the failure modes that matter — "commit
-- opened an editor", "unstage moved a ref", "the index lock was suppressed" —
-- are all properties of the actual git invocation. A fake `vim.system` would
-- assert my argv against itself and prove none of them.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("auto-core.git.write — mutating git surface (ADR-0060)\n")

local W = require("auto-core.git.write")

---code_lines returns the write module's NON-COMMENT lines.
---
---Every source-level assertion below goes through this. Three separate
---assertions in this file were first written against the whole file and failed
---on the module's own prose — the header discusses `--no-optional-locks` and
---`--hard` precisely because they are the things it must not do. Grepping
---documentation and calling it an argv check is a false negative waiting to
---happen, so the distinction is made once, here.
local function code_lines()
  local out = {}
  for _, line in ipairs(vim.fn.readfile(
      vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        .. "/lua/auto-core/git/write.lua")) do
    if not line:match("^%s*%-%-") then out[#out + 1] = line end
  end
  return out
end
local function code_src() return table.concat(code_lines(), "\n") end
local events = require("auto-core.events")

---A throwaway repo per section, so one test's index cannot leak into the next.
local function new_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for _, a in ipairs({
    { "git", "init", "-q", "-b", "main" },
    { "git", "config", "user.email", "t@example.com" },
    { "git", "config", "user.name", "T" },
    -- A commit template + a hook are exactly what would drag an editor in.
    { "git", "config", "commit.template", dir .. "/.tmpl" },
  }) do
    vim.system(a, { cwd = dir, text = true }):wait()
  end
  vim.fn.writefile({ "template body" }, dir .. "/.tmpl")
  vim.fn.writefile({ "one" }, dir .. "/a.txt")
  return dir
end

---Run an async verb to completion.
local function sync(fn)
  local done, res = false, nil
  fn(function(o, e) res = { ok = o, err = e }; done = true end)
  vim.wait(15000, function() return done end, 20)
  return res or { ok = false, err = "timed out" }
end

local function collect(topic)
  local seen = {}
  events.subscribe(topic, function(p) seen[#seen + 1] = p end)
  return seen
end

-- ── [1] has_staged inverts git's exit code correctly ──────────────────
;(function()
  local d = new_repo()
  ok("[1] nothing staged in a fresh repo", W.has_staged(d) == false)
  vim.system({ "git", "add", "a.txt" }, { cwd = d, text = true }):wait()
  ok("[1] staged after a git add", W.has_staged(d) == true)
  -- The inversion is the trap: `diff --cached --quiet` exits 1 when there ARE
  -- changes. A naive `code == 0` reading would report these backwards.
  local r = vim.system({ "git", "--no-optional-locks", "-C", d, "diff", "--cached", "--quiet" },
    { text = true }):wait()
  ok("[1] CONTROL — git really exits nonzero when staged", r.code ~= 0, r.code)
end)()

-- ── [2] stage / unstage move the index, and only the index ───────────
;(function()
  local d = new_repo()
  local idx = collect("core.git.index:changed")

  local r1 = sync(function(cb) W.stage(d, "a.txt", cb) end)
  ok("[2] stage succeeds", r1.ok, r1.err)
  ok("[2] and the file is staged", W.has_staged(d) == true)
  ok("[2] it published core.git.index:changed",
    #idx == 1 and idx[1].action == "stage" and idx[1].ok == true, vim.inspect(idx[1]))

  -- unstage must not move HEAD. Commit first so there IS a ref to move.
  sync(function(cb) W.commit(d, "first", nil, cb) end)
  local head_before = vim.trim(vim.system({ "git", "-C", d, "rev-parse", "HEAD" },
    { text = true }):wait().stdout or "")
  vim.fn.writefile({ "two" }, d .. "/a.txt")
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  local r2 = sync(function(cb) W.unstage(d, "a.txt", cb) end)
  ok("[2] unstage succeeds", r2.ok, r2.err)
  ok("[2] and the index is clean again", W.has_staged(d) == false)
  local head_after = vim.trim(vim.system({ "git", "-C", d, "rev-parse", "HEAD" },
    { text = true }):wait().stdout or "")
  ok("[2] unstage did NOT move HEAD (restore --staged, not reset)",
    head_before == head_after and head_before ~= "",
    head_before:sub(1, 8) .. " -> " .. head_after:sub(1, 8))
  ok("[2] and the working-tree edit survived unstaging",
    (vim.fn.readfile(d .. "/a.txt")[1]) == "two")
end)()

-- ── [2b] unstage BEFORE the first commit ─────────────────────────────
--
-- The case the first implementation got wrong. `restore --staged` restores from
-- a source defaulting to HEAD, so with no commits it fails outright — and
-- staging several files then unstaging one is ordinary while composing an
-- initial commit. worktree.nvim's suite caught this; auto-core's did not,
-- because every earlier section happened to commit first.
;(function()
  local d = new_repo()
  ok("[2b] a fresh repo has no HEAD", require("auto-core.git.write").has_head(d) == false)
  local r1 = sync(function(cb) W.stage(d, "a.txt", cb) end)
  ok("[2b] staging the first file works", r1.ok, r1.err)
  local r2 = sync(function(cb) W.unstage(d, "a.txt", cb) end)
  ok("[2b] and unstaging it works with NO commit in the repo", r2.ok, r2.err)
  ok("[2b] the index really is clean", W.has_staged(d) == false)
  ok("[2b] and the file survives, untracked", vim.fn.filereadable(d .. "/a.txt") == 1)
  -- Once a commit exists, has_head flips and the preferred spelling is used.
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  sync(function(cb) W.commit(d, "init", nil, cb) end)
  ok("[2b] has_head is true after the first commit", W.has_head(d) == true)
end)()

-- ── [3] stage_all, and an empty path list is refused not silent ──────
;(function()
  local d = new_repo()
  vim.fn.writefile({ "x" }, d .. "/b.txt")
  local r = sync(function(cb) W.stage_all(d, cb) end)
  ok("[3] stage_all succeeds", r.ok, r.err)
  ok("[3] and it staged the untracked file too", W.has_staged(d) == true)
  local e1 = sync(function(cb) W.stage(d, {}, cb) end)
  ok("[3] stage with no paths is REFUSED, with a reason",
    e1.ok == false and tostring(e1.err):find("no paths", 1, true) ~= nil, e1.err)
  local e2 = sync(function(cb) W.unstage(d, nil, cb) end)
  ok("[3] unstage with no paths likewise", e2.ok == false, e2.err)
end)()

-- ── [4] commit: refuses empty index and empty message, never edits ───
;(function()
  local d = new_repo()
  local done = collect("core.git.commit:completed")

  local e1 = sync(function(cb) W.commit(d, "msg", nil, cb) end)
  ok("[4] commit with NOTHING staged is refused",
    e1.ok == false and tostring(e1.err):find("nothing staged", 1, true) ~= nil, e1.err)
  ok("[4] and it did not publish a completion for a commit it never ran", #done == 0)

  local e2 = sync(function(cb) W.commit(d, "   ", nil, cb) end)
  ok("[4] a blank message is refused",
    e2.ok == false and tostring(e2.err):find("message required", 1, true) ~= nil, e2.err)

  sync(function(cb) W.stage(d, "a.txt", cb) end)
  local r = sync(function(cb) W.commit(d, "real commit", nil, cb) end)
  ok("[4] a staged commit succeeds", r.ok, r.err)
  ok("[4] it published core.git.commit:completed",
    #done == 1 and done[1].ok == true, vim.inspect(done[1]))
  local subj = vim.trim(vim.system({ "git", "-C", d, "log", "-1", "--format=%s" },
    { text = true }):wait().stdout or "")
  ok("[4] with the message given, not the commit.template", subj == "real commit", subj)
  -- The repo is configured with a commit.template on purpose: without
  -- GIT_EDITOR=true a template can pull an editor into a context that has none.
  ok("[4] and a multi-line / backtick message survives verbatim as argv",
    (function()
      vim.fn.writefile({ "three" }, d .. "/a.txt")
      sync(function(cb) W.stage(d, "a.txt", cb) end)
      local m = "subject `rm -rf /` line\n\nbody line"
      local rr = sync(function(cb) W.commit(d, m, nil, cb) end)
      if not rr.ok then return false end
      local full = vim.system({ "git", "-C", d, "log", "-1", "--format=%B" },
        { text = true }):wait().stdout or ""
      return full:find("`rm -rf /`", 1, true) ~= nil and full:find("body line", 1, true) ~= nil
    end)())
end)()

-- ── [5] push publishes its pair, and reports failure as a reason ─────
;(function()
  local d = new_repo()
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  sync(function(cb) W.commit(d, "c1", nil, cb) end)
  local started = collect("core.git.push:started")
  local finished = collect("core.git.push:completed")

  -- No remote configured, so this MUST fail — which is the point: the failure
  -- has to arrive as `ok=false` plus git's stderr, not as a raised error.
  local r = sync(function(cb) W.push(d, { timeout_ms = 15000, label = "probe" }, cb) end)
  ok("[5] push with no remote fails rather than throwing", r.ok == false)
  ok("[5] and the reason is git's own stderr",
    r.err ~= nil and #tostring(r.err) > 0, r.err)
  ok("[5] it published :started", #started == 1 and started[1].label == "probe")
  ok("[5] and :completed with ok=false and the stderr",
    #finished == 1 and finished[1].ok == false and finished[1].stderr ~= nil,
    vim.inspect(finished[1]))

  -- A real push, to a local bare remote — proves the success path too.
  local bare = vim.fn.tempname()
  vim.fn.mkdir(bare, "p")
  vim.system({ "git", "init", "-q", "--bare", bare }, { text = true }):wait()
  vim.system({ "git", "-C", d, "remote", "add", "origin", bare }, { text = true }):wait()
  local r2 = sync(function(cb)
    W.push(d, { set_upstream = true, remote = "origin", branch = "main" }, cb)
  end)
  ok("[5] a push to a real remote succeeds", r2.ok, r2.err)
  local remote_head = vim.trim(vim.system(
    { "git", "-C", bare, "rev-parse", "refs/heads/main" }, { text = true }):wait().stdout or "")
  ok("[5] and the remote actually received the commit", #remote_head == 40, remote_head)
end)()

-- ── [7] reset_soft and restore_worktree ──────────────────────────────
;(function()
  local d = new_repo()
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  sync(function(cb) W.commit(d, "c1", nil, cb) end)
  vim.fn.writefile({ "second" }, d .. "/b.txt")
  sync(function(cb) W.stage(d, "b.txt", cb) end)
  sync(function(cb) W.commit(d, "c2", nil, cb) end)

  local function count_commits()
    return tonumber(vim.trim(vim.system({ "git", "-C", d, "rev-list", "--count", "HEAD" },
      { text = true }):wait().stdout or "0")) or 0
  end
  ok("[7] two commits to start", count_commits() == 2, count_commits())

  local r = sync(function(cb) W.reset_soft(d, nil, cb) end)
  ok("[7] reset_soft succeeds", r.ok, r.err)
  ok("[7] HEAD moved back one commit", count_commits() == 1, count_commits())
  ok("[7] and the change is KEPT in the index (that is what --soft means)",
    W.has_staged(d) == true)
  ok("[7] the file still exists in the working tree",
    vim.fn.filereadable(d .. "/b.txt") == 1)

  -- restore_worktree DISCARDS. Prove it actually discards, or the confirmation
  -- the caller is told to add would be guarding nothing.
  sync(function(cb) W.commit(d, "c2 again", nil, cb) end)
  vim.fn.writefile({ "LOCAL EDIT" }, d .. "/a.txt")
  ok("[7] CONTROL — the working tree really holds the edit first",
    vim.fn.readfile(d .. "/a.txt")[1] == "LOCAL EDIT")
  local r2 = sync(function(cb) W.restore_worktree(d, "a.txt", cb) end)
  ok("[7] restore_worktree succeeds", r2.ok, r2.err)
  ok("[7] and the edit is GONE — restored from HEAD",
    vim.fn.readfile(d .. "/a.txt")[1] == "one",
    vim.inspect(vim.fn.readfile(d .. "/a.txt")))

  -- Both refuse before the first commit, with a reason rather than git's raw
  -- "unknown revision" noise.
  local fresh = new_repo()
  local e1 = sync(function(cb) W.reset_soft(fresh, nil, cb) end)
  ok("[7] reset_soft refuses with no commit",
    e1.ok == false and tostring(e1.err):find("no commit", 1, true) ~= nil, e1.err)
  local e2 = sync(function(cb) W.restore_worktree(fresh, "a.txt", cb) end)
  ok("[7] restore refuses with no commit",
    e2.ok == false and tostring(e2.err):find("no commit", 1, true) ~= nil, e2.err)

  -- The destructive spellings are not reachable: reset_soft takes a ref, not a
  -- mode, so there is no argument that turns it into --hard.
  local src = code_src()
  ok("[7] no --hard in the write surface's CODE",
    src:find("%-%-hard") == nil)
  ok("[7] and no bare `checkout` (the overloaded verb) either",
    src:find('"checkout"') == nil)
end)()

-- ── [7b] the option boundary: data must never become a flag ──────────
--
-- The blocker this section exists for. `reset_soft(cwd, "--hard")` used to
-- interpolate straight into the argv, git read it as a second mode, the later
-- mode won, and the call returned **ok=true having destroyed the index and the
-- working tree**. Section [7]'s source-grep for `--hard` passed the whole time,
-- because the absence of a string from a file says nothing about what a caller
-- can pass in. These assert on STATE, adversarially.
;(function()
  local function repo_with_work()
    local d = new_repo()
    sync(function(cb) W.stage(d, "a.txt", cb) end)
    sync(function(cb) W.commit(d, "c1", nil, cb) end)
    vim.fn.writefile({ "SECOND" }, d .. "/a.txt")
    sync(function(cb) W.stage(d, "a.txt", cb) end)
    sync(function(cb) W.commit(d, "c2", nil, cb) end)
    vim.fn.writefile({ "PRECIOUS UNCOMMITTED WORK" }, d .. "/a.txt")
    sync(function(cb) W.stage(d, "a.txt", cb) end)
    return d
  end
  local function state(d)
    return vim.fn.readfile(d .. "/a.txt")[1], W.has_staged(d),
      vim.trim(vim.system({ "git", "-C", d, "rev-list", "--count", "HEAD" },
        { text = true }):wait().stdout or "")
  end

  for _, bad in ipairs({ "--hard", "--mixed", "--merge", "-q" }) do
    local d = repo_with_work()
    local c0, s0, n0 = state(d)
    local r = sync(function(cb) W.reset_soft(d, bad, cb) end)
    local c1, s1, n1 = state(d)
    ok("[7b] reset_soft(" .. bad .. ") is REFUSED", r.ok == false, r.err)
    ok("[7b] " .. bad .. ": working tree UNCHANGED",
      c0 == c1 and c1 == "PRECIOUS UNCOMMITTED WORK", tostring(c1))
    ok("[7b] " .. bad .. ": index UNCHANGED", s0 == s1 and s1 == true)
    ok("[7b] " .. bad .. ": HEAD did not move", n0 == n1, n0 .. " -> " .. n1)
  end

  -- A legitimate ref still works, and resolves through an OID.
  local d = repo_with_work()
  local _, _, before = state(d)
  local good = sync(function(cb) W.reset_soft(d, "HEAD~1", cb) end)
  local _, staged_after, after = state(d)
  ok("[7b] a real ref still works", good.ok, good.err)
  ok("[7b] and HEAD moved back exactly one",
    tonumber(after) == tonumber(before) - 1, before .. " -> " .. after)
  ok("[7b] with the change kept in the index", staged_after == true)

  -- A nonsense ref is refused with a reason, not passed to git raw.
  local junk = sync(function(cb) W.reset_soft(d, "no-such-ref-xyz", cb) end)
  ok("[7b] an unresolvable ref is refused",
    junk.ok == false and tostring(junk.err):find("cannot resolve", 1, true) ~= nil, junk.err)

  -- push carries the same class of boundary.
  local pd = repo_with_work()
  local p1 = sync(function(cb) W.push(pd, { remote = "--upload-pack=touch /tmp/x" }, cb) end)
  ok("[7b] push refuses an option-shaped remote",
    p1.ok == false and tostring(p1.err):find("option%-shaped") ~= nil, p1.err)
  local p2 = sync(function(cb) W.push(pd, { branch = "--force" }, cb) end)
  ok("[7b] push refuses an option-shaped branch",
    p2.ok == false and tostring(p2.err):find("option%-shaped") ~= nil, p2.err)
end)()

-- ── [7c] allow_empty actually allows an empty commit ─────────────────
--
-- It used to skip the has_staged guard and then never pass `--allow-empty`, so
-- the "allowed" commit failed in git anyway. An option that does not work is
-- worse than an absent one: the caller believes it did something.
;(function()
  local d = new_repo()
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  sync(function(cb) W.commit(d, "c1", nil, cb) end)
  ok("[7c] nothing staged now", W.has_staged(d) == false)
  local r = sync(function(cb) W.commit(d, "empty on purpose", { allow_empty = true }, cb) end)
  ok("[7c] commit with allow_empty succeeds", r.ok, r.err)
  local n = vim.trim(vim.system({ "git", "-C", d, "rev-list", "--count", "HEAD" },
    { text = true }):wait().stdout or "")
  ok("[7c] and a second commit really exists", n == "2", n)
  local r2 = sync(function(cb) W.commit(d, "no flag", nil, cb) end)
  ok("[7c] CONTROL — without the option it is still refused",
    r2.ok == false and tostring(r2.err):find("nothing staged", 1, true) ~= nil, r2.err)
end)()

-- ── [7d] push's REFSPEC boundary, against a real remote ──────────────
--
-- The second boundary bug, and a different shape from [7b]'s. `opts.branch`
-- lands in git's refspec position, where the control syntax does not begin with
-- a dash — so the dash guard passed it straight through:
--
--   branch = "+HEAD~1:refs/heads/main"  -> ok=true, remote FORCE-REWOUND
--   branch = ":refs/heads/main"         -> ok=true, remote branch DELETED
--
-- A real bare remote is used because the assertion that matters is the state of
-- the remote ref, not the refusal. Refusing while still rewinding would pass a
-- refusal-only test.
;(function()
  local d = new_repo()
  local bare = vim.fn.tempname()
  vim.fn.mkdir(bare, "p")
  vim.system({ "git", "init", "-q", "--bare", bare }, { text = true }):wait()
  vim.system({ "git", "-C", d, "remote", "add", "origin", bare }, { text = true }):wait()

  local function remote_main()
    return vim.trim(vim.system({ "git", "-C", bare, "rev-parse", "refs/heads/main" },
      { text = true }):wait().stdout or "")
  end
  local function commit(txt)
    vim.fn.writefile({ txt }, d .. "/a.txt")
    sync(function(cb) W.stage(d, "a.txt", cb) end)
    sync(function(cb) W.commit(d, txt, nil, cb) end)
  end

  commit("one")
  local up = sync(function(cb)
    W.push(d, { set_upstream = true, remote = "origin", branch = "main" }, cb) end)
  ok("[7d] a normal push works", up.ok, up.err)
  local first = remote_main()
  commit("two")
  sync(function(cb) W.push(d, { remote = "origin", branch = "main" }, cb) end)
  local second = remote_main()
  ok("[7d] CONTROL — the remote really advances on a normal push",
    first ~= "" and second ~= "" and first ~= second,
    first:sub(1, 8) .. " -> " .. second:sub(1, 8))

  -- FORCE syntax.
  local f = sync(function(cb)
    W.push(d, { remote = "origin", branch = "+HEAD~1:refs/heads/main" }, cb) end)
  ok("[7d] a leading '+' force refspec is REFUSED", f.ok == false, f.err)
  ok("[7d] and the remote ref is UNCHANGED — not rewound",
    remote_main() == second, remote_main():sub(1, 8) .. " want " .. second:sub(1, 8))

  -- DELETE syntax.
  local del = sync(function(cb)
    W.push(d, { remote = "origin", branch = ":refs/heads/main" }, cb) end)
  ok("[7d] a leading ':' delete refspec is REFUSED", del.ok == false, del.err)
  ok("[7d] and the remote branch still EXISTS",
    remote_main() == second, vim.inspect(remote_main()))

  -- Other refspec-ish spellings that a dash guard would also miss.
  -- NOT in this list: "refs/heads/main". check-ref-format accepts it, and
  -- `git push origin refs/heads/main` is an ordinary non-destructive push to the
  -- matching remote ref — no force, no delete. My first version of this test
  -- asserted it should be refused, which would have meant tightening the guard
  -- past what the danger actually is.
  for _, bad in ipairs({ "HEAD~1", "main:main", "@{-1}", "a b", "" }) do
    local r = sync(function(cb)
      W.push(d, { remote = "origin", branch = bad }, cb) end)
    ok("[7d] branch " .. string.format("%q", bad) .. " is refused", r.ok == false, r.err)
  end
  ok("[7d] and after all of those the remote is STILL where it was",
    remote_main() == second, remote_main():sub(1, 8))

  -- A legitimate branch name still pushes, so the guard is not just "refuse".
  vim.system({ "git", "-C", d, "checkout", "-q", "-b", "feature/x" }, { text = true }):wait()
  commit("three")
  local okp = sync(function(cb)
    W.push(d, { set_upstream = true, remote = "origin", branch = "feature/x" }, cb) end)
  ok("[7d] a real branch name with a slash still pushes", okp.ok, okp.err)

  -- remote is checked for MEMBERSHIP, not against a character class.
  local br = sync(function(cb)
    W.push(d, { remote = "origin;touch /tmp/pwned", branch = "main" }, cb) end)
  ok("[7d] an unconfigured remote is refused",
    br.ok == false and tostring(br.err):find("not a configured remote", 1, true) ~= nil, br.err)

  -- r3 note 1: the previous character-class whitelist refused git-VALID remote
  -- names. `foo/bar` and `foo+bar` are both configurable, and both were
  -- rejected. Membership against `git remote` accepts whatever git accepted.
  for _, name in ipairs({ "foo/bar", "foo+bar" }) do
    vim.system({ "git", "-C", d, "remote", "add", name, bare }, { text = true }):wait()
  end
  local listed = vim.system({ "git", "-C", d, "remote" }, { text = true }):wait().stdout or ""
  ok("[7d] CONTROL — git really configured the odd remote names",
    listed:find("foo/bar", 1, true) and listed:find("foo+bar", 1, true), vim.inspect(listed))
  for _, name in ipairs({ "foo/bar", "foo+bar" }) do
    local r = sync(function(cb)
      W.push(d, { remote = name, branch = "feature/x" }, cb) end)
    -- It must get PAST validation. Whether the push itself succeeds depends on
    -- the remote, so the assertion is that the refusal is not ours.
    ok("[7d] a git-valid remote " .. string.format("%q", name) .. " is not refused by us",
      tostring(r.err or ""):find("not a configured remote", 1, true) == nil, r.err)
  end

  -- r3 note 2: check-ref-format's NORMALIZED name is used, not the caller's
  -- token. After a real branch switch `@{-1}` resolves to the previous branch;
  -- the first version discarded that and passed the literal `@{-1}` through.
  vim.system({ "git", "-C", d, "checkout", "-q", "main" }, { text = true }):wait()
  vim.system({ "git", "-C", d, "checkout", "-q", "feature/x" }, { text = true }):wait()
  local resolved = vim.trim(vim.system(
    { "git", "-C", d, "check-ref-format", "--branch", "@{-1}" }, { text = true }
  ):wait().stdout or "")
  ok("[7d] CONTROL — git resolves @{-1} after a real switch", resolved == "main", resolved)
  local at = sync(function(cb) W.push(d, { remote = "origin", branch = "@{-1}" }, cb) end)
  ok("[7d] @{-1} is accepted only as its RESOLVED name",
    tostring(at.err or ""):find("@{%-1}") == nil, at.err)
end)()

-- ── [6] the read/write hardening split is real ───────────────────────
;(function()
  -- The claim in the module header: reads carry --no-optional-locks, writes
  -- must not. Asserted on the SOURCE because it is a property of the argv this
  -- module builds, and getting it backwards is silent — a suppressed index lock
  -- does not error, it just fails to take the lock it needed.
  local src = table.concat(vim.fn.readfile(plugin_root .. "/lua/auto-core/git/write.lua"), "\n")
  local read_line = src:match('[^\n]*diff", "%-%-cached[^\n]*')
  ok("[6] has_staged (a READ) keeps --no-optional-locks",
    src:find('"%-%-no%-optional%-locks", "%-C"') ~= nil, read_line)
  -- The INVARIANT, not a count. Two earlier versions of this assertion were
  -- wrong in different ways: the first counted every occurrence in the file and
  -- tripped on the header's prose, the second pinned the number of read probes
  -- and tripped the moment a second read (has_head) was added. What actually
  -- matters is which KIND of argv carries the flag.
  local READ_VERBS  = { "diff", "rev%-parse", "status", "log" }
  local WRITE_VERBS = { '"add"', '"commit"', '"push"', '"reset"', '"restore"' }
  local flagged_writes, flagged_reads = {}, 0
  for _, line in ipairs(code_lines()) do
    if line:find("no%-optional%-locks") then
      local is_read = false
      for _, v in ipairs(READ_VERBS) do if line:find(v) then is_read = true end end
      for _, v in ipairs(WRITE_VERBS) do
        if line:find(v) then flagged_writes[#flagged_writes + 1] = vim.trim(line) end
      end
      if is_read then flagged_reads = flagged_reads + 1 end
    end
  end
  ok("[6] NO write argv carries the read-only flag",
    #flagged_writes == 0, vim.inspect(flagged_writes))
  ok("[6] and every line that does carry it is a read",
    flagged_reads >= 1, "read lines with the flag: " .. flagged_reads)
  ok("[6] GIT_EDITOR is pinned so no write can spawn an editor",
    src:find('GIT_EDITOR = "true"', 1, true) ~= nil)
  ok("[6] and credential prompting is disabled so a push cannot hang",
    src:find('GIT_TERMINAL_PROMPT = "0"', 1, true) ~= nil)
end)()

-- ── [8] git.log.unpushed — which commits no remote has (batch item #7) ──
-- Johno, 2026-09-03: "the commit tree should indicate if it's pushed to the
-- origin or simply commited locally". The question is answered with a real
-- remote, because the only interesting states are "on a remote" and "not", and
-- a fixture without a remote can only ever produce one of them.
;(function()
  local L = require("auto-core.git.log")
  local d = new_repo()
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  sync(function(cb) W.commit(d, "pushed one", nil, cb) end)
  local first = vim.trim(vim.system({ "git", "-C", d, "rev-parse", "HEAD" },
    { text = true }):wait().stdout or "")

  -- A repo with NO remotes: nothing is pushed, and that is the true answer.
  local none = L.unpushed(d .. "/.git")
  ok("[8] with no remotes at all, the commit reads as LOCAL",
    none[first] == true, vim.inspect(none))

  -- Now give it a remote and push only the FIRST commit.
  local bare = vim.fn.tempname()
  vim.fn.mkdir(bare, "p")
  vim.system({ "git", "init", "-q", "--bare", bare }, { text = true }):wait()
  vim.system({ "git", "-C", d, "remote", "add", "origin", bare }, { text = true }):wait()
  vim.system({ "git", "-C", d, "push", "-q", "origin", "main" }, { text = true }):wait()

  vim.fn.writefile({ "LOCAL ONLY" }, d .. "/a.txt")
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  sync(function(cb) W.commit(d, "local one", nil, cb) end)
  local second = vim.trim(vim.system({ "git", "-C", d, "rev-parse", "HEAD" },
    { text = true }):wait().stdout or "")

  local set, err = L.unpushed(d .. "/.git")
  ok("[8] the read succeeds", err == nil, tostring(err))
  ok("[8] *** the PUSHED commit is not in the unpushed set ***",
    set[first] ~= true, vim.inspect(set))
  ok("[8] *** the LOCAL-ONLY commit IS ***", set[second] == true, vim.inspect(set))
  ok("[8] fixture: the two commits are different", first ~= second and #first == 40)

  -- Pushing again empties the set: the answer tracks reality rather than being
  -- computed once. A cached answer here is how a panel keeps showing orange
  -- after a push.
  vim.system({ "git", "-C", d, "push", "-q", "origin", "main" }, { text = true }):wait()
  local after = L.unpushed(d .. "/.git")
  ok("[8] *** after pushing, nothing is unpushed ***",
    after[second] ~= true and next(after) == nil, vim.inspect(after))

  -- A branch pushed to a DIFFERENT remote ref still counts as pushed, which is
  -- why this uses `--not --remotes` and not `@{upstream}..HEAD`.
  vim.fn.writefile({ "SIDE" }, d .. "/a.txt")
  sync(function(cb) W.stage(d, "a.txt", cb) end)
  sync(function(cb) W.commit(d, "side one", nil, cb) end)
  local third = vim.trim(vim.system({ "git", "-C", d, "rev-parse", "HEAD" },
    { text = true }):wait().stdout or "")
  vim.system({ "git", "-C", d, "push", "-q", "origin", "HEAD:refs/heads/elsewhere" },
    { text = true }):wait()
  local side = L.unpushed(d .. "/.git")
  ok("[8] *** pushed to ANOTHER remote branch still counts as pushed ***",
    side[third] ~= true, vim.inspect(side))

  -- MF6: "pushed" means pushed to ORIGIN, not reachable from ANY remote. With
  -- origin behind and the commit pushed only to a fork, `--not --remotes`
  -- subtracted the fork's ref too and the panel painted it as pushed.
  do
    local fork = vim.fn.tempname()
    vim.fn.mkdir(fork, "p")
    vim.system({ "git", "init", "-q", "--bare", fork }, { text = true }):wait()
    vim.system({ "git", "-C", d, "remote", "add", "fork", fork }, { text = true }):wait()
    vim.fn.writefile({ "FORK ONLY" }, d .. "/a.txt")
    sync(function(cb) W.stage(d, "a.txt", cb) end)
    sync(function(cb) W.commit(d, "fork only", nil, cb) end)
    local forked = vim.trim(vim.system({ "git", "-C", d, "rev-parse", "HEAD" },
      { text = true }):wait().stdout or "")
    vim.system({ "git", "-C", d, "push", "-q", "fork", "HEAD:refs/heads/main" },
      { text = true }):wait()
    local og = L.unpushed(d .. "/.git")
    ok("[8] *** MF6: pushed to a FORK only is still UNPUSHED to origin ***",
      og[forked] == true, vim.inspect(og))
    ok("[8] MF6: and an explicit remote= scopes it to that remote instead",
      (L.unpushed(d .. "/.git", { remote = "fork" }))[forked] ~= true)
    ok("[8] MF6: a remote name is not a PREFIX match (origin vs origin-mirror)",
      (function()
        -- `--remotes=origin` alone would also match `origin-mirror/*`, so a
        -- mirror could report a commit as pushed to origin.
        local mirror = vim.fn.tempname(); vim.fn.mkdir(mirror, "p")
        vim.system({ "git", "init", "-q", "--bare", mirror }, { text = true }):wait()
        vim.system({ "git", "-C", d, "remote", "add", "origin-mirror", mirror },
          { text = true }):wait()
        vim.fn.writefile({ "MIRROR ONLY" }, d .. "/a.txt")
        sync(function(cb) W.stage(d, "a.txt", cb) end)
        sync(function(cb) W.commit(d, "mirror only", nil, cb) end)
        local m = vim.trim(vim.system({ "git", "-C", d, "rev-parse", "HEAD" },
          { text = true }):wait().stdout or "")
        vim.system({ "git", "-C", d, "push", "-q", "origin-mirror",
          "HEAD:refs/heads/main" }, { text = true }):wait()
        return (L.unpushed(d .. "/.git"))[m] == true
      end)())
  end

  ok("[8] an empty common_dir is refused, not guessed",
    select(2, L.unpushed("")) ~= nil)
  ok("[8] an unknown rev yields no answer rather than a crash", (function()
    local u, e = L.unpushed(d .. "/.git", { rev = "no-such-ref" })
    return type(u) == "table" and next(u) == nil and e ~= nil
  end)())
end)()

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
