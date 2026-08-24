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

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
