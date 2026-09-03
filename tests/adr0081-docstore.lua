-- auto-core — ADR-0081 P1/P2/P3: document persistence, revisioned identity,
-- and the draft store.
--
-- Run headless:
--   nvim --headless -u NONE -l tests/adr0081-docstore.lua
--
-- The load-bearing test here is [2], the NON-REVIEW CONSUMER control. auto-core
-- may own allocation only if allocation is genuinely domain-agnostic, and a
-- negative word-grep cannot prove that (lector, ADR-0081 MF2). So the allocator
-- is driven end to end by a consumer with no reviews in it at all — an opaque
-- key, an opaque suffix, no filename assumptions.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end

local ds = require("auto-core.docstore")
local rv = require("auto-core.docstore.revisions")
local dr = require("auto-core.drafts")

local sb = vim.fn.tempname() .. "-adr0081"
ds.ensure_dir(sb)

io.stdout:write("\n[1] the document store — bytes in, bytes out, atomically\n")
do
  ok("[1] ensure_dir creates, and is idempotent",
    ds.ensure_dir(sb .. "/d") and ds.ensure_dir(sb .. "/d") and ds.exists(sb .. "/d"))
  ok("[1] write then read round-trips exactly",
    select(1, ds.write(sb .. "/d/f.txt", "hello\nthere")) == true
    and ds.read(sb .. "/d/f.txt") == "hello\nthere")
  ok("[1] write creates missing parent directories",
    select(1, ds.write(sb .. "/deep/er/still/f", "x")) == true
    and ds.read(sb .. "/deep/er/still/f") == "x")
  -- Absent vs unreadable must be distinguishable, or a caller cannot tell a
  -- fresh store from a broken one.
  local c, e = ds.read(sb .. "/d/missing")
  ok("[1] *** an ABSENT document is nil with NO error ***", c == nil and e == nil)
  ok("[1] read guards an empty path", select(2, ds.read("")) ~= nil)

  ok("[1] write_json round-trips through read_json",
    select(1, ds.write_json(sb .. "/d/a.json", { b = 2, a = "x" })) == true
    and (ds.read_json(sb .. "/d/a.json") or {}).a == "x")
  -- Pretty and STABLE: a document a human opens, and a history that diffs.
  local raw = ds.read(sb .. "/d/a.json") or ""
  ok("[1] *** persisted JSON is multi-line, not minified ***",
    raw:find("\n", 1, true) ~= nil, raw)
  -- Sorted keys, tested over TEN of them and by comparing the whole emitted
  -- order. A two-key fixture is not a test of this: LuaJIT's `pairs` order for
  -- string keys varies BETWEEN PROCESSES (measured: 1 run in 6 emitted the two
  -- keys already ascending), so the assertion passed ~17% of the time with
  -- `table.sort` deleted. The mutation matrix and a hand-run disagreed on this
  -- cell, which is what exposed it. With ten keys an accidental pass needs all
  -- ten to land ascending by chance.
  ok("[1] *** and its keys are sorted, so rewrites diff cleanly ***", (function()
    local wide = { revision = 1, repo = "r", path = "p", note = "n", line = 2,
                   kind = "k", id = "i", hash = "h", file = "f", date = "d" }
    local emitted = {}
    for k in ds.encode_pretty(wide):gmatch('\n  "([%w_]+)":') do
      emitted[#emitted + 1] = k
    end
    local want = {}
    for k in pairs(wide) do want[#want + 1] = k end
    table.sort(want)
    return #emitted == 10
      and table.concat(emitted, ",") == table.concat(want, ",")
  end)(), ds.encode_pretty({ b = 2, a = "x" }))
  ok("[1] two-space indent", raw:find('\n  "a"', 1, true) ~= nil, raw)
  ok("[1] and it ends with a newline", raw:sub(-1) == "\n")
  -- Encoder shapes.
  ok("[1] arrays keep their order", ds.encode_pretty({ 3, 1, 2 }):find("3.*1.*2"))
  ok("[1] an empty table encodes as []", ds.encode_pretty({}) == "[]")
  ok("[1] nested structures round-trip", (function()
    local v = { outer = { inner = { 1, { k = "v" } } } }
    local d2 = vim.json.decode(ds.encode_pretty(v))
    return d2.outer.inner[2].k == "v"
  end)())
  ok("[1] a malformed document reads as nil WITH an error", (function()
    ds.write(sb .. "/d/bad.json", "{ not json")
    local v, err = ds.read_json(sb .. "/d/bad.json")
    return v == nil and err ~= nil
  end)())

  ok("[1] *** create_exclusive claims once and refuses the second ***", (function()
    local first = ds.create_exclusive(sb .. "/d/claim", "a")
    local second, err = ds.create_exclusive(sb .. "/d/claim", "b")
    -- Taken is (false, nil) — an ordinary answer, not a failure.
    return first == true and second == false and err == nil
      and ds.read(sb .. "/d/claim") == "a"
  end)())
  ok("[1] delete removes, and an absent path counts as deleted",
    ds.delete(sb .. "/d/claim") and not ds.exists(sb .. "/d/claim")
    and select(1, ds.delete(sb .. "/d/claim")) == true)
  ok("[1] list returns sorted NAMES, filtered by pattern", (function()
    ds.write(sb .. "/l/b.json", "{}"); ds.write(sb .. "/l/a.json", "{}")
    ds.write(sb .. "/l/c.txt", "x")
    local j = ds.list(sb .. "/l", "%.json$")
    return #j == 2 and j[1] == "a.json" and j[2] == "b.json"
  end)())
  ok("[1] list of a missing directory is empty, not an error",
    #ds.list(sb .. "/nope") == 0)
  ok("[1] glob finds files, sorted, and never directories", (function()
    ds.write(sb .. "/g/a/one.md", "1")
    ds.write(sb .. "/g/b/two.md", "2")
    ds.ensure_dir(sb .. "/g/c/three.md")   -- a DIRECTORY that matches
    local hits = ds.glob(sb .. "/g/*/*.md")
    return #hits == 2 and hits[1]:find("one%.md$") and hits[2]:find("two%.md$")
  end)(), vim.inspect(ds.glob(sb .. "/g/*/*.md")))
  ok("[1] glob guards an empty pattern", (function()
    local hits, err = ds.glob("")
    return #hits == 0 and err ~= nil
  end)())
  ok("[1] *** glob: READABLE-EMPTY establishes absence (no error) ***",
    (function()
      -- The traversal root exists and can be scanned; nothing matches. That is
      -- a real answer, and a caller may act on it.
      ds.ensure_dir(sb .. "/g/empty")
      local hits, err = ds.glob(sb .. "/g/empty/*.md")
      return #hits == 0 and err == nil
    end)())
  ok("[1] glob: a root that does not EXIST is also absence, not an error",
    (function()
      local hits, err = ds.glob(sb .. "/g/never-created/*.md")
      return #hits == 0 and err == nil
    end)())
  ok("[1] *** glob: RESOLVABLE-BUT-UNREADABLE is an ERROR, not absence ***",
    (function()
      -- lector's r4 probe, as a control: the root resolves and exists, but
      -- cannot be traversed. `vim.fn.glob` reports no error, so this returned
      -- exactly what "nothing matched" returns -- and a caller deciding whether
      -- a paired document still exists read it as "nothing there".
      local locked = sb .. "/g/locked"
      ds.write(locked .. "/agents/a/reviews/x-r1-review.md", "prose")
      vim.fn.system({ "chmod", "000", locked .. "/agents" })
      local hits, err = ds.glob(locked .. "/agents/*/reviews/*-r1-review.md")
      vim.fn.system({ "chmod", "755", locked .. "/agents" })
      return #hits == 0 and err ~= nil
        and tostring(err):find("could not be traversed", 1, true) ~= nil
    end)())
  ok("[1] CONTROL: with the same root READABLE, the document is found",
    (function()
      local locked = sb .. "/g/locked"
      local hits, err = ds.glob(locked .. "/agents/*/reviews/*-r1-review.md")
      return #hits == 1 and err == nil
    end)())
  ok("[1] *** glob: a match whose KIND cannot be read is an error, not a skip ***",
    (function()
      -- INJECTED, because the two guards cannot be separated by permissions
      -- alone: any directory unreadable enough to break `stat` on a match also
      -- stops `glob` from listing it, so the traversal check fires first and
      -- this branch never runs. Injection isolates it -- the entry we cannot
      -- classify may be exactly the one the caller asked about, so the whole
      -- result is untrustworthy rather than one entry being skipped.
      local uvx = vim.uv or vim.loop
      local d = sb .. "/g/kindfail"
      ds.write(d .. "/a.md", "x")
      local target = d .. "/a.md"
      local real_stat = uvx.fs_stat
      uvx.fs_stat = function(path, ...)
        if path == target then return nil, "forced permission failure", "EACCES" end
        return real_stat(path, ...)
      end
      local hits, err = ds.glob(d .. "/*.md")
      uvx.fs_stat = real_stat
      return #hits == 0 and err ~= nil
        and tostring(err):find("could not be read", 1, true) ~= nil
    end)())
  ok("[1] kind names what is at a path, and nil means ABSENT", (function()
    ds.write(sb .. "/k/f.txt", "x")
    ds.ensure_dir(sb .. "/k/d")
    return ds.kind(sb .. "/k/f.txt") == "file"
      and ds.kind(sb .. "/k/d") == "directory"
      and select(1, ds.kind(sb .. "/k/nope")) == nil
      and select(2, ds.kind(sb .. "/k/nope")) == nil
  end)())
  ok("[1] *** and a PRESENT but unreadable path is an error, not absence ***",
    (function()
      -- The same ENOENT discipline as read and delete: a caller asking "is a
      -- directory in the way?" must not be told "nothing is there".
      local hidden = sb .. "/k/hidden/f.txt"
      ds.write(hidden, "x")
      vim.fn.system({ "chmod", "000", sb .. "/k/hidden" })
      local kind, err = ds.kind(hidden)
      vim.fn.system({ "chmod", "755", sb .. "/k/hidden" })
      return kind == nil and err ~= nil
    end)())
  ok("[1] mtime is comparable, and nil for an absent path",
    type(ds.mtime(sb .. "/l/a.json")) == "number" and ds.mtime(sb .. "/nope") == nil)

  -- with_lock returns (value, err) -- worktree.store's convention, so P4a is a
  -- pass-through rather than a translation layer that could invert a failure
  -- into a success.
  ok("[1] with_lock runs the body, returns its value, and releases the lock",
    (function()
      local ran = false
      local v, err = ds.with_lock(sb .. "/d/f.txt", function() ran = true; return 7 end)
      return v == 7 and err == nil and ran and not ds.exists(sb .. "/d/f.txt.lock")
    end)())
  ok("[1] *** with_lock releases even when the body RAISES ***", (function()
    local v, err = ds.with_lock(sb .. "/d/f.txt", function() error("boom") end)
    -- A lock leaked by a raising callback would wedge the store for the session.
    return v == nil and tostring(err):find("boom", 1, true)
      and not ds.exists(sb .. "/d/f.txt.lock")
  end)())
  ok("[1] with_lock passes the body's own (value, err) back", (function()
    local v, err = ds.with_lock(sb .. "/d/f.txt", function() return nil, "inner" end)
    return v == nil and err == "inner"
  end)())
end

-- ---------------------------------------------------------------------------
print("\n[1b] the lock's DIAGNOSIS -- ported from worktree.store, not reinvented")
-- Every assertion here covers a property the first draft of this store did not
-- have. auto-core replacing worktree's lock with a 500ms pathname-unlinking
-- one would have deleted six review rounds of hardening and called it a
-- refactor; the migration gate (ADR-0081 s3.1) caught it before delegation.
do
  local lk = require("auto-core.docstore.lock")
  ok("[1b] the contention window is 10s, driving its own retry loop",
    ds.LOCK_WAIT_MS == 10000 and ds.LOCK_POLL_MS == 10
    and lk.LOCK_WAIT_MS == ds.LOCK_WAIT_MS,
    tostring(ds.LOCK_WAIT_MS) .. "/" .. tostring(ds.LOCK_POLL_MS))

  -- THE CONSTANT DRIVES THE LOOP -- measured, not read off the source. The
  -- original advertised 10000ms while looping a hard-coded 50 iterations of
  -- 10ms, a real 505ms (r5 should-fix 1). Shrinking the window and timing the
  -- refusal proves the coupling in both directions, and it is why every
  -- contention assertion below runs in milliseconds instead of waiting out the
  -- production window three times over.
  local real_wait = lk.LOCK_WAIT_MS
  ok("[1b] *** a refusal takes as long as the window says, no longer ***",
    (function()
      lk.LOCK_WAIT_MS = 300
      local guarded = sb .. "/lk/timed.txt"
      ds.write(guarded .. ".lock", '{"pid":999998,"host":"elsewhere"}')
      local t0 = vim.uv and vim.uv.hrtime() or vim.loop.hrtime()
      local v, err = ds.with_lock(guarded, function() return "STOLEN" end)
      local elapsed_ms = ((vim.uv or vim.loop).hrtime() - t0) / 1e6
      ds.delete(guarded .. ".lock")
      lk.LOCK_WAIT_MS = real_wait
      -- Waited at least the window (so it really retried) and nothing like the
      -- production 10s (so the loop is not hard-coded).
      return v == nil and err ~= nil
        and elapsed_ms >= 280 and elapsed_ms < 3000
    end)())
  -- Every contention assertion from here runs inside a short window.
  lk.LOCK_WAIT_MS = 60

  -- The lock CARRIES its owner. A lock nobody can identify is a lock nobody
  -- can diagnose, and the refusal below is built entirely out of this record.
  local guarded = sb .. "/lk/target.txt"
  ok("[1b] *** the lock records pid, host and process start time ***", (function()
    local seen
    ds.with_lock(guarded, function()
      seen = select(1, ds.read_json(guarded .. ".lock"))
      return true
    end)
    return type(seen) == "table"
      and seen.pid == (vim.uv or vim.loop).os_getpid()
      and type(seen.host) == "string" and seen.host ~= ""
      and type(seen.start) == "number"
  end)())

  -- A contended lock is REPORTED, never broken. Held by US, so it is provably
  -- alive: the refusal must say so and must NOT offer repair.
  ok("[1b] *** a lock held by a LIVE process is refused, not taken ***", (function()
    local inner_v, inner_err
    ds.with_lock(guarded, function()
      -- Re-entering from the same process: the lock file is already there.
      inner_v, inner_err = ds.with_lock(guarded, function() return "STOLEN" end)
      return true
    end)
    return inner_v == nil and inner_err ~= nil
      and tostring(inner_err):find("STILL RUNNING", 1, true) ~= nil
  end)())
  ok("[1b] *** and offers NO repair instructions while the holder is alive ***",
    (function()
      local inner_err
      ds.with_lock(guarded, function()
        inner_err = select(2, ds.with_lock(guarded, function() return true end))
        return true
      end)
      -- Advertising "remove this lock" for a LIVE holder invites a lost update.
      return inner_err ~= nil
        and tostring(inner_err):find("QUIT EVERY", 1, true) == nil
    end)())
  ok("[1b] the refusal names WHO holds it", (function()
    local inner_err
    ds.with_lock(guarded, function()
      inner_err = select(2, ds.with_lock(guarded, function() return true end))
      return true
    end)
    return tostring(inner_err):find("pid " .. (vim.uv or vim.loop).os_getpid(), 1, true) ~= nil
  end)())

  -- An owner record this version cannot read is UNKNOWN, never dead.
  ok("[1b] an unreadable owner record is UNKNOWN liveness, and may be repaired",
    (function()
      local t = sb .. "/lk/legacy.txt"
      ds.write(t .. ".lock", "not json at all")
      local v, err = ds.with_lock(t, function() return "STOLEN" end)
      ds.delete(t .. ".lock")
      return v == nil and tostring(err):find("UNKNOWN", 1, true)
        and tostring(err):find("QUIT EVERY", 1, true)
    end)())

  -- Liveness is decided by an ENUM and the prose derives from it. Asserting the
  -- DECISION rather than the sentence is deliberate: control flow once keyed off
  -- `status:find("STILL RUNNING")`, so rewording a sentence could start
  -- advertising repair for a live holder.
  local dead = lk._owner_dead_for_tests
  local mypid = (vim.uv or vim.loop).os_getpid()
  ok("[1b] *** OUR OWN pid is never judged dead (re-entry) ***",
    dead({ pid = mypid, host = (vim.uv or vim.loop).os_gethostname(),
           start = lk._proc_start(mypid) }) == false)
  ok("[1b] *** another HOST's lock is never judged dead ***", (function()
    -- The pid must be one that is genuinely ABSENT here, or the assertion
    -- passes for the wrong reason: pid 1 answers EPERM (alive, unsignalable),
    -- which every branch already refuses to call dead. With an absent pid, only
    -- the host guard stands between a foreign lock and a "stale" verdict.
    local uv2 = vim.uv or vim.loop
    for cand = 4194300, 4194200, -1 do
      if uv2.kill(cand, 0) ~= 0 then
        return dead({ pid = cand, host = "some-other-host-entirely" }) == false
          -- fixture: locally, that same pid IS judged dead
          and dead({ pid = cand, host = uv2.os_gethostname() }) == true
      end
    end
    return false
  end)())
  ok("[1b] a record with no pid is never judged dead",
    dead({ host = "x" }) == false and dead(nil) == false and dead("nope") == false)
  ok("[1b] *** a pid that does not exist IS dead (ESRCH) ***", (function()
    -- Find a pid that is genuinely absent rather than assuming one.
    local uv = vim.uv or vim.loop
    local host = uv.os_gethostname()
    for cand = 4194300, 4194200, -1 do
      if uv.kill(cand, 0) ~= 0 then
        return dead({ pid = cand, host = host }) == true
      end
    end
    return false -- no absent pid found; the assertion could not be made
  end)())
  ok("[1b] *** a REUSED pid is dead: same pid, different start time ***",
    (function()
      -- Needs a live pid that is OURS TO SIGNAL but not our own process: the
      -- re-entry guard returns early for our pid, and pid 1 answers EPERM
      -- (alive but not signalable), which returns early too. So spawn a child.
      local job = vim.fn.jobstart({ "sleep", "30" })
      if job <= 0 then return false end
      local pid = vim.fn.jobpid(job)
      local host = (vim.uv or vim.loop).os_gethostname()
      local real = lk._proc_start(pid)
      -- Fixture guard: the child must be alive and readable, or the assertion
      -- below would be proving nothing.
      local live = (vim.uv or vim.loop).kill(pid, 0) == 0 and type(real) == "number"
      local verdict_same = dead({ pid = pid, host = host, start = real })
      local verdict_reused = dead({ pid = pid, host = host, start = real + 1 })
      vim.fn.jobstop(job)
      return live and verdict_same == false and verdict_reused == true
    end)())

  -- /proc/<pid>/stat parsing. The fields after `comm` begin at the LAST ")",
  -- because a comm may contain spaces AND parentheses. Taking the FIRST made a
  -- live holder read as start time 0 -> "pid reused" -> dead.
  -- `state` is field 3 and the FIRST word after the comm, so field 22 is the
  -- 20th word of the tail: "S" plus 19 more, the last being the start time.
  local function stat_line(comm, starttime)
    local fields = { "S" }                       -- field 3
    for i = 4, 21 do fields[#fields + 1] = tostring(i) end
    fields[#fields + 1] = tostring(starttime)    -- field 22
    return "42 " .. comm .. " " .. table.concat(fields, " ")
  end
  ok("[1b] fixture: an ordinary /proc stat line parses to its start time",
    lk._parse_proc_stat(stat_line("(nvim)", 111)) == 111,
    lk._parse_proc_stat(stat_line("(nvim)", 111)))
  ok("[1b] *** proc-stat parsing survives a comm containing ') ' ***",
    -- A comm of `nvim) shifted` puts an EARLIER ") " on the line. Matching the
    -- first one read field 4 as the start time, so a live holder's start time
    -- came back wrong and `_owner_dead` called pid reuse on a running process.
    lk._parse_proc_stat(stat_line("(nvim) shifted)", 987654)) == 987654,
    lk._parse_proc_stat(stat_line("(nvim) shifted)", 987654)))
  ok("[1b] and a comm containing only spaces",
    lk._parse_proc_stat(stat_line("(my editor)", 222)) == 222)
  ok("[1b] proc-stat parsing refuses garbage instead of guessing",
    lk._parse_proc_stat("") == nil and lk._parse_proc_stat("no parens here") == nil
    and lk._parse_proc_stat(nil) == nil)

  -- The release is inode-guarded: we unlink the lock only while the pathname
  -- still names the file we created.
  ok("[1b] *** a lock REPLACED under us is not unlinked by our release ***",
    (function()
      local t = sb .. "/lk/swapped.txt"
      ds.with_lock(t, function()
        -- Simulate the pathname coming to name a different file mid-section.
        (vim.uv or vim.loop).fs_unlink(t .. ".lock")
        ds.write(t .. ".lock", '{"pid":999999,"host":"successor"}')
        return true
      end)
      -- The successor's lock must SURVIVE: deleting it is how an already-stale
      -- decision removes a live holder's lock.
      local still = select(1, ds.read_json(t .. ".lock"))
      local survived = type(still) == "table" and still.pid == 999999
      ds.delete(t .. ".lock")
      return survived
    end)())

  lk.LOCK_WAIT_MS = real_wait
  ok("[1b] the production contention window is restored after these controls",
    ds.LOCK_WAIT_MS == 10000 and lk.LOCK_WAIT_MS == 10000)
end

io.stdout:write("\n[2] CONTROL: a NON-REVIEW consumer drives the allocator\n")
-- The proof that revisioned identity generalises. No review vocabulary, no
-- review filename grammar: an opaque key and an opaque suffix chosen to look
-- nothing like a review. If this passes, the allocator is domain-agnostic in
-- fact and not merely in its comments.
--
-- Driven through a validated HANDLE. The first draft took (dir, key, suffix) on
-- every call, which is string concatenation rather than a boundary, and three
-- defects followed from it -- a `../` escape, a suffix change re-issuing r1, and
-- a caller suffix of `.reserve` colliding with its own control record. Section
-- [4] holds a control for each.
do
  local dir = sb .. "/widgets"
  ds.ensure_dir(dir)
  local KEY, SUFFIX = "tenant-42.widget", ".widget.yaml"
  local h, herr = rv.open({ dir = dir, key = KEY, suffix = SUFFIX })
  ok("[2] a handle opens over an opaque dir/key/suffix", h ~= nil and herr == nil, herr)

  ok("[2] nothing recorded yet", h:max_recorded() == 0)

  -- The CRASHED-WRITER fence, on its own key: a number that is reserved but was
  -- never committed is still spent. Without this the matrix showed dropping the
  -- reservation match from `max_recorded` changed nothing -- the property was
  -- untested, and a crashed writer's revision would be handed to the next one.
  do
    local ch = rv.open({ dir = dir, key = "tenant-1.crashed", suffix = SUFFIX })
    local cr = ch:claim_next()
    ok("[2] fixture: r1 is claimed and deliberately never committed",
      cr == 1 and ds.exists(ch:reserve_path(cr))
      and not ds.exists(ch:record_path(cr)))
    ok("[2] *** a RESERVED-only number counts toward the maximum ***",
      ch:max_recorded() == cr, tostring(ch:max_recorded()))
    ok("[2] *** so the next writer gets r2, not the crashed writer's r1 ***",
      select(1, ch:claim_next()) == cr + 1)
  end

  local r1, t1, e1 = h:claim_next()
  ok("[2] *** claim_next allocates r1 and returns a token ***",
    r1 == 1 and type(t1) == "string" and #t1 > 0 and e1 == nil, e1)
  ok("[2] the claim is a real reservation record on disk",
    ds.exists(h:reserve_path(1)))
  ok("[2] and the holder owns it", h:owns(1, t1) == true)
  ok("[2] a different token does NOT own it", h:owns(1, "someone-else") == false)
  ok("[2] *** an already-claimed revision is refused, not overwritten ***", (function()
    local claimed, err = h:claim(1, "second-writer")
    -- (false, nil) is "taken" -- an ordinary answer, not a failure.
    return claimed == false and err == nil and h:owns(1, t1) == true
  end)())
  ok("[2] releasing our own reservation removes it",
    h:release(1, t1) == true and not ds.exists(h:reserve_path(1)))

  -- A COMMITTED record spends its number even after the reservation is gone.
  ds.write(h:record_path(1), "widget: one\n")
  ok("[2] *** a committed record still counts toward the maximum ***",
    h:max_recorded() == 1)
  local r2, t2 = h:claim_next()
  ok("[2] *** so the next claim is r2, never a reused r1 ***", r2 == 2)

  -- RETIREMENT. A number handed back must never be handed out again.
  local tombstoned, terr, fenced = h:retire(2, t2)
  ok("[2] retire tombstones the revision",
    tombstoned == true and terr == nil and fenced == true
    and ds.exists(h:tombstone_path(2)), terr)
  ok("[2] and releases the retiring holder's own reservation",
    not ds.exists(h:reserve_path(2)))
  ok("[2] *** a tombstoned number is NEVER handed out again ***",
    select(1, h:claim_next()) == 3)
  ok("[2] a tombstoned revision cannot be claimed directly either",
    select(1, h:claim(2, "anyone")) == false)
  ok("[2] and its former owner no longer owns it", h:owns(2, t2) == false)

  -- A tombstone ALONE holds the maximum: this is the delete-then-reuse defect.
  do
    local th = rv.open({ dir = dir, key = "tenant-9.fence", suffix = SUFFIX })
    local fr, ft = th:claim_next()
    th:retire(fr, ft)
    ok("[2] fixture: the tombstone alone holds the maximum",
      ds.exists(th:tombstone_path(fr)) and not ds.exists(th:reserve_path(fr))
      and not ds.exists(th:record_path(fr)) and th:max_recorded() == fr)
    -- CONTROL: with the tombstone removed the maximum drops, which is exactly
    -- the number that would then be re-issued.
    ds.delete(th:tombstone_path(fr))
    ok("[2] *** CONTROL: without the tombstone the maximum DROPS ***",
      th:max_recorded() == 0)
  end

  -- THE LEASE. Only an expired lease is evidence of staleness.
  do
    local lh = rv.open({ dir = dir, key = "tenant-7.lease", suffix = SUFFIX })
    local lr, lt = lh:claim_next()
    local n, rep = lh:cleanup()
    ok("[2] a live claim is NOT reaped",
      n == 0 and ds.exists(lh:reserve_path(lr)) and lh:owns(lr, lt) == true
      and #rep.indeterminate == 0 and #rep.errors == 0)
    -- Expire it by rewriting the lease into the past.
    ds.write_json(lh:reserve_path(lr),
      { owner = lt, created_at = os.time() - 999, lease_until = os.time() - 1 })
    local n2 = lh:cleanup()
    ok("[2] *** an EXPIRED, uncommitted claim is reaped ***",
      n2 == 1 and ds.exists(lh:tombstone_path(lr)))
    ok("[2] *** and a second pass reaps NOTHING -- the count means newly fenced ***",
      select(1, lh:cleanup()) == 0)
    ok("[2] *** a COMMITTED revision is never reaped, however stale its lease ***",
      (function()
        local ch = rv.open({ dir = dir, key = "tenant-8.committed", suffix = SUFFIX })
        local cr, ct = ch:claim_next()
        ds.write(ch:record_path(cr), "widget: done\n")
        ds.write_json(ch:reserve_path(cr),
          { owner = ct, created_at = os.time() - 999, lease_until = os.time() - 1 })
        local cn = ch:cleanup()
        return cn == 0 and not ds.exists(ch:tombstone_path(cr))
      end)())
  end

  ok("[2] a different key allocates from its own zero", (function()
    local other = rv.open({ dir = dir, key = "tenant-99.widget", suffix = SUFFIX })
    return other:max_recorded() == 0 and select(1, other:claim_next()) == 1
  end)())

  -- Paths are composed from the CALLER's key and suffix, which is what lets an
  -- existing store move behind this module with no migration.
  ok("[2] *** record paths are composed from the caller's key and suffix ***",
    (function()
      local legacy = rv.open({ dir = dir, key = "own__repo@abc1234",
                               suffix = ".review.json" })
      return legacy:record_path(3) == dir .. "/own__repo@abc1234.r3.review.json"
        and legacy:reserve_path(3) == dir .. "/own__repo@abc1234.r3.reserve"
        and legacy:tombstone_path(3) == dir .. "/own__repo@abc1234.r3.tombstone"
    end)())
end

io.stdout:write("\n[3] the draft store — lifetime and clearing rules (SF2)\n")
do
  dr._reset_for_tests()
  ok("[3] peek does NOT create", dr.peek("s:1") == nil and #dr.scopes() == 0)
  local d = dr.get("s:1")
  ok("[3] get creates the empty shape",
    type(d) == "table" and #d.items == 0 and type(d.meta) == "table")
  ok("[3] *** get returns the LIVE table, so appends are seen by every holder ***",
    (function()
      table.insert(dr.get("s:1").items, { a = 1 })
      -- `peek` indexed directly would ABORT the whole suite when a mutation
      -- drops the draft, and an aborted run reports no failures at all — which
      -- is how the mutation matrix first scored this covered guard as untested.
      -- A nil-safe read fails this one assertion and lets the rest still run.
      local held = dr.peek("s:1")
      return dr.count("s:1") == 1 and held ~= nil and #held.items == 1
    end)())
  ok("[3] a scope must be a non-empty string",
    dr.get(nil) == nil and dr.get("") == nil and dr.get({}) == nil)

  ok("[3] dirty accepts a scope or a draft, and agrees",
    dr.dirty("s:1") == true and dr.dirty(dr.peek("s:1")) == true)
  ok("[3] an empty draft is not dirty", dr.get("s:empty") ~= nil and dr.dirty("s:empty") == false)
  -- CONTENT vs CONTEXT (lector MF4). `dirty` first treated any non-empty value
  -- in `meta` as content. But §2.5 REQUIRES a reviewer snapshot in `meta`, so a
  -- brand-new draft with zero items reported dirty the instant it recorded the
  -- identity it was told to record, and the close guard would offer to keep an
  -- empty draft. A domain-agnostic store cannot tell an identity snapshot from
  -- a typed summary, so it must not try: content is `items` plus an explicit
  -- bit, and nothing else.
  ok("[3] *** the REQUIRED reviewer snapshot alone does NOT make a draft dirty ***",
    (function()
      local d = dr.get("s:ctx")
      d.meta.reviewer = { display = "Alice", slug = "alice" }
      d.meta.repo = "owner__repo"
      d.meta.commit = "c2f104d"
      return #d.items == 0 and dr.dirty("s:ctx") == false
    end)())
  ok("[3] *** and content that is not an item is declared, via touch ***",
    (function()
      dr.get("s:sum").meta.reviewer = { slug = "alice" }
      local before = dr.dirty("s:sum")
      dr.touch("s:sum")
      return before == false and dr.dirty("s:sum") == true
    end)())
  ok("[3] touch can be cleared again, so an emptied field stops claiming work",
    (function()
      dr.touch("s:sum", false)
      return dr.dirty("s:sum") == false
    end)())
  ok("[3] an item still makes a draft dirty with no touch at all", (function()
    table.insert(dr.get("s:item").items, { line = 1 })
    return dr.dirty("s:item") == true and dr.get("s:item").touched == false
  end)())
  ok("[3] dirty on an unknown scope is false, not an error", dr.dirty("s:nope") == false)

  ok("[3] scopes lists holders, sorted", (function()
    local s = dr.scopes()
    for i = 2, #s do if s[i - 1] > s[i] then return false end end
    return #s >= 3
  end)())
  ok("[3] *** dirty_only hides scopes holding nothing ***", (function()
    local all, only = #dr.scopes(), #dr.scopes({ dirty_only = true })
    return only < all and vim.tbl_contains(dr.scopes({ dirty_only = true }), "s:1")
  end)())

  ok("[3] discard removes, and reports whether there was anything",
    dr.discard("s:1") == true and dr.peek("s:1") == nil and dr.discard("s:1") == false)
  ok("[3] clear is the successful-commit spelling of discard", (function()
    table.insert(dr.get("s:c").items, { x = 1 })
    return dr.clear("s:c") == true and dr.peek("s:c") == nil
  end)())
  -- The guarantee behind a "close and keep" answer: nothing but discard/clear
  -- may drop a draft. There is no close path in this module to call, which IS
  -- the property — the draft is not owned by any view.
  ok("[3] *** no other operation drops a draft ***", (function()
    table.insert(dr.get("s:keep").items, { x = 1 })
    -- Exercise every read-only operation, then verify through a DIFFERENT path
    -- than the ones just called. Asserting with `count` last let a `count` that
    -- cleared as a side effect still return 1 and pass — the matrix caught it.
    dr.peek("s:keep"); dr.dirty("s:keep"); dr.count("s:keep")
    dr.scopes(); dr.scopes({ dirty_only = true }); dr.get("s:keep")
    local held = dr._store["s:keep"]
    return held ~= nil and #held.items == 1
      and dr.dirty("s:keep") == true
      and vim.tbl_contains(dr.scopes(), "s:keep")
  end)())
  ok("[3] count is 0 for an absent scope, never nil", dr.count("s:none") == 0)
end

io.stdout:write("\n[4] CONTROLS for every r0 finding (lector PR #16 r0)\n")
-- One control per finding, each reproducing the reported failure BEFORE
-- asserting the fix. Fault injection patches the libuv table the store captured
-- at load time, so the production call site is the one that fails.
do
  local uv = vim.uv or vim.loop
  local dir = sb .. "/r1"
  ds.ensure_dir(dir)

  -- MF1 -- create_exclusive must not publish, or report, an incomplete record.
  do
    local target = dir .. "/mf1-eio.json"
    local real_write = uv.fs_write
    uv.fs_write = function() return nil, "forced write failure", "EIO" end
    local claimed, err = ds.create_exclusive(target, "the full content")
    uv.fs_write = real_write
    ok("[4] *** MF1: a libuv EIO on write is a FAILURE, not a claim ***",
      claimed == false and err ~= nil, tostring(err))
    ok("[4] *** MF1: and no partial record is left at the final path ***",
      ds.exists(target) == false,
      ds.exists(target) and ("bytes=" .. tostring(select(1, ds.read(target)))) or "absent")
    ok("[4] MF1: the sibling temp is cleaned up too",
      #ds.list(dir, "^mf1%-eio%.json%.claim%.") == 0)
  end
  do
    -- A SHORT write is the same defect with a subtler shape: libuv returns a
    -- number, just not all of them.
    local target = dir .. "/mf1-short.json"
    local real_write = uv.fs_write
    uv.fs_write = function(fd, content, off)
      return real_write(fd, tostring(content):sub(1, 3), off)
    end
    local claimed, err = ds.create_exclusive(target, "much longer than three")
    uv.fs_write = real_write
    ok("[4] *** MF1: a SHORT write is refused, not committed ***",
      claimed == false and err ~= nil and tostring(err):find("of %d+ bytes"),
      tostring(err))
    ok("[4] MF1: and leaves nothing behind", ds.exists(target) == false)
  end
  ok("[4] *** MF1: the final path does not exist until the bytes are complete ***",
    (function()
      -- The ordering property itself: a second reader must never observe the
      -- claim's name before its content. O_EXCL-then-write published the name
      -- first; write-then-link cannot.
      local target = dir .. "/mf1-order.json"
      local seen_early = nil
      local real_write = uv.fs_write
      uv.fs_write = function(fd, content, off)
        if seen_early == nil then seen_early = ds.exists(target) end
        return real_write(fd, content, off)
      end
      local claimed = ds.create_exclusive(target, "complete")
      uv.fs_write = real_write
      return claimed == true and seen_early == false
        and select(1, ds.read(target)) == "complete"
    end)())

  -- MF2 -- only ENOENT may mean absent.
  do
    local locked = dir .. "/mf2-locked.json"
    ds.write_json(locked, { a = 1 })
    vim.fn.system({ "chmod", "000", locked })
    local v, err = ds.read_json(locked)
    local raw_v, raw_err = ds.read(locked)
    local recoverable = vim.fn.system({ "chmod", "644", locked })
    ok("[4] *** MF2: a PRESENT but unopenable document is an ERROR, not absent ***",
      v == nil and err ~= nil and ds.exists(locked) == true, tostring(err))
    ok("[4] *** MF2: read() reports it too, rather than (nil, nil) ***",
      raw_v == nil and raw_err ~= nil, tostring(raw_err))
    ok("[4] MF2: while a genuinely missing document stays (nil, nil)",
      (function()
        local mv, merr = ds.read(dir .. "/mf2-not-here.json")
        return mv == nil and merr == nil
      end)())
    ok("[4] *** MF2: a stat that fails for EACCES is an error, not absence ***",
      (function()
        -- The mode-000 FILE above exercises the io.open branch: stat succeeds
        -- on a file whose own permissions are stripped. Only a locked PARENT
        -- exercises the stat branch, and without this the ENOENT check there
        -- could be deleted with no test noticing.
        local locked = dir .. "/mf2-locked-dir"
        ds.write(locked .. "/inside.json", "{}")
        vim.fn.system({ "chmod", "000", locked })
        local v2, e2 = ds.read(locked .. "/inside.json")
        local jv, je = ds.read_json(locked .. "/inside.json")
        vim.fn.system({ "chmod", "755", locked })
        return v2 == nil and e2 ~= nil and jv == nil and je ~= nil
      end)())
    ok("[4] MF2: and a readable document is unaffected",
      (ds.read_json(locked) or {}).a == 1, recoverable)
  end

  -- MF3 -- the identity boundary.
  ok("[4] *** MF3: a key containing `..` cannot escape its directory ***",
    (function()
      local h, err = rv.open({ dir = dir, key = "../outside", suffix = ".json" })
      -- The reported failure wrote `outside.r1.reserve` one level UP.
      return h == nil and err ~= nil and not ds.exists(sb .. "/outside.r1.reserve")
    end)())
  ok("[4] MF3: nor can a key with a path separator",
    select(1, rv.open({ dir = dir, key = "sub/deep", suffix = ".json" })) == nil)
  ok("[4] MF3: a relative store dir is refused (cwd moves under an editor)",
    select(1, rv.open({ dir = "relative/dir", key = "k", suffix = ".json" })) == nil)
  ok("[4] *** MF3: a suffix change does NOT re-issue a spent number ***",
    (function()
      local kdir = dir .. "/two-formats"
      ds.ensure_dir(kdir)
      local yaml = rv.open({ dir = kdir, key = "same-key", suffix = ".yaml" })
      local r, t = yaml:claim_next()
      ds.write(yaml:record_path(r), "committed as yaml\n")
      yaml:release(r, t)
      -- The reported failure: the same key with a different suffix returned r1
      -- again, so two documents both called themselves r1.
      local json = rv.open({ dir = kdir, key = "same-key", suffix = ".json" })
      return r == 1 and json:max_recorded() == 1
        and select(1, json:claim_next()) == 2
    end)())
  ok("[4] *** MF3: a `.reserve` suffix is refused, not aliased onto a control record ***",
    (function()
      local a = select(1, rv.open({ dir = dir, key = "k", suffix = ".reserve" }))
      local b = select(1, rv.open({ dir = dir, key = "k", suffix = ".tombstone" }))
      local c = select(1, rv.open({ dir = dir, key = "k", suffix = ".lock" }))
      return a == nil and b == nil and c == nil
    end)())
  ok("[4] *** MF3: the containment probe is a BACKSTOP, not decoration ***",
    (function()
      -- Widen the grammar so the pattern can no longer refuse, leaving the
      -- probe as the only thing between a key and a path escape. Without this
      -- the probe was untested: the pattern refused first, so deleting the
      -- probe changed no outcome.
      local saved = rv.KEY_PATTERN
      rv.KEY_PATTERN = "^.*$"
      local h, err = rv.open({ dir = dir, key = "../escaped", suffix = ".json" })
      rv.KEY_PATTERN = saved
      return h == nil and err ~= nil
        and tostring(err):find("outside", 1, true) ~= nil
    end)())
  ok("[4] *** a DIRECTORY named like a record is not a record ***", (function()
    -- A directory called `poison.r9.reserve` made `max_recorded` report r9 and
    -- burn nine revision numbers, because the listing did not distinguish a
    -- directory from a document.
    local pdir = dir .. "/poisoned"
    ds.ensure_dir(pdir)
    ds.ensure_dir(pdir .. "/poison.r9.reserve")
    local h = rv.open({ dir = pdir, key = "poison", suffix = ".json" })
    return h:max_recorded() == 0
      and not vim.tbl_contains(ds.list(pdir), "poison.r9.reserve")
      and select(1, h:claim_next()) == 1
  end)())
  ok("[4] MF3: a legitimate suffix is still accepted", (function()
    local h = rv.open({ dir = dir, key = "k", suffix = ".review.json" })
    return h ~= nil and h:record_path(1) == dir .. "/k.r1.review.json"
  end)())
  ok("[4] MF3: every refusal explains itself", (function()
    local _, err = rv.open({ dir = "rel", key = "../x", suffix = "nodot" })
    -- All three parts are reported together, not just the first one to fail:
    -- a caller fixing one at a time would otherwise need three round trips.
    -- Matched on the subject of each complaint rather than its exact wording,
    -- because `../x` legitimately trips either the separator or the `..` check
    -- depending on which is tested first, and both are correct refusals.
    return type(err) == "string"
      and err:find("dir must", 1, true) and err:find("key must", 1, true)
      and err:find("suffix must", 1, true)
  end)())

  -- MF5 -- a lock that could not be released is not a success.
  ok("[4] *** MF5: a failed release is REPORTED, with the body's value kept ***",
    (function()
      local guarded = dir .. "/mf5.txt"
      local lockpath = guarded .. ".lock"
      local real_unlink = uv.fs_unlink
      uv.fs_unlink = function(path, ...)
        if path == lockpath then return nil, "forced unlink failure" end
        return real_unlink(path, ...)
      end
      local value, err, completed = ds.with_lock(guarded, function() return 7 end)
      uv.fs_unlink = real_unlink
      local wedged = ds.exists(lockpath)
      ds.delete(lockpath)
      -- The r0 defect returned (7, nil) with the lock still on disk. The r1 fix
      -- returned (7, err), which the INHERITED consumer contract still reads as
      -- success. Both are wrong: nil first, error second, completed value third.
      return value == nil and err ~= nil
        and tostring(err):find("COULD NOT be released", 1, true) ~= nil
        and completed == 7 and wedged == true
    end)())

  -- SF1 -- the encoder must not silently change a value.
  ok("[4] *** SF1: a numeric-keyed object keeps its VALUE, not null ***",
    (function()
      local enc = ds.encode_pretty({ [2] = "x" })
      local back = vim.json.decode(enc)
      return enc:find("null", 1, true) == nil and back["2"] == "x"
    end)(), ds.encode_pretty({ [2] = "x" }))
  ok("[4] *** SF1: a MIXED numeric/string table keeps every value ***",
    (function()
      local enc = ds.encode_pretty({ [1] = "one", [3] = "three", name = "n" })
      local back = vim.json.decode(enc)
      return enc:find("null", 1, true) == nil
        and back["1"] == "one" and back["3"] == "three" and back.name == "n"
    end)(), ds.encode_pretty({ [1] = "one", [3] = "three", name = "n" }))
  ok("[4] SF1: a dense array is still an array, not a stringified object",
    ds.encode_pretty({ "a", "b" }):find("^%[") ~= nil)

  -- SF2 -- the fourth state: an indeterminate reservation.
  do
    local ih = rv.open({ dir = dir, key = "sf2.corrupt", suffix = ".json" })
    ds.write(ih:reserve_path(1), "{not json at all")
    local n, report = ih:cleanup()
    ok("[4] *** SF2: a corrupt reservation is NEVER reaped automatically ***",
      n == 0 and ds.exists(ih:reserve_path(1))
      and not ds.exists(ih:tombstone_path(1)))
    ok("[4] *** SF2: and it is REPORTED, not silently skipped ***",
      vim.tbl_contains(report.indeterminate, 1) and #report.errors > 0,
      vim.inspect(report):gsub("%s+", " "))
    ok("[4] SF2: it still fences the number it holds", ih:max_recorded() == 1)
    ok("[4] SF2: a reservation with no numeric lease is indeterminate too",
      (function()
        local nh = rv.open({ dir = dir, key = "sf2.nolease", suffix = ".json" })
        ds.write_json(nh:reserve_path(1), { owner = "x", lease_until = "soon" })
        local m, rep = nh:cleanup()
        return m == 0 and vim.tbl_contains(rep.indeterminate, 1)
          and ds.exists(nh:reserve_path(1))
      end)())
    ok("[4] SF2: a clean pass reports no problems at all", (function()
      local ch = rv.open({ dir = dir, key = "sf2.clean", suffix = ".json" })
      ch:claim_next()
      local m, rep = ch:cleanup()
      return m == 0 and #rep.indeterminate == 0 and #rep.errors == 0
        and #rep.fenced == 0
    end)())
  end

  -- Lector answer 2: retire reports "tombstoned" and "fenced" separately.
  ok("[4] *** retire that cannot tombstone still reports whether it is FENCED ***",
    (function()
      local rh = rv.open({ dir = dir, key = "fence.split", suffix = ".json" })
      local r, t = rh:claim_next()
      local real_link = uv.fs_link
      uv.fs_link = function() return nil, "forced link failure" end
      local tombstoned, err, fenced = rh:retire(r, t)
      uv.fs_link = real_link
      -- The tombstone failed, but the reservation is still there and still
      -- counts toward the maximum -- so the number is out of circulation, and
      -- the caller is told both facts rather than one.
      return tombstoned == false and err ~= nil and fenced == true
        and ds.exists(rh:reserve_path(r)) and rh:max_recorded() == r
    end)())
  ok("[4] *** and reports fenced=FALSE when NOTHING holds the number ***",
    (function()
      -- The other half of the same contract. Asserting only the true case let a
      -- hard-coded `fenced = true` pass -- the matrix caught it. Here the
      -- reservation is released first, so a failed tombstone leaves no fence at
      -- all, and the caller must be told that rather than reassured.
      local rh = rv.open({ dir = dir, key = "fence.lost", suffix = ".json" })
      local r, t = rh:claim_next()
      rh:release(r, t)
      local real_link = uv.fs_link
      uv.fs_link = function() return nil, "forced link failure" end
      local tombstoned, err, fenced = rh:retire(r, t)
      uv.fs_link = real_link
      return tombstoned == false and err ~= nil and fenced == false
        and not ds.exists(rh:reserve_path(r))
    end)())
end

io.stdout:write("\n[5] CONTROLS for r1 (lector PR #16 r1)\n")
do
  local uv = vim.uv or vim.loop
  local dir = sb .. "/r2"
  ds.ensure_dir(dir)

  -- MF1 -- the grammar must be INJECTIVE, and the handle must be fixed.
  ok("[5] *** MF1: two handles can no longer name the SAME file ***", (function()
    -- The reported collision: {alpha, ".beta.r2.json"} at r1 and
    -- {alpha.r1.beta, ".json"} at r2 both compose alpha.r1.beta.r2.json.
    local a, aerr = rv.open({ dir = dir, key = "alpha", suffix = ".beta.r2.json" })
    local b, berr = rv.open({ dir = dir, key = "alpha.r1.beta", suffix = ".json" })
    return a == nil and b == nil
      and tostring(aerr):find("revision marker", 1, true)
      and tostring(berr):find("revision marker", 1, true)
  end)())
  ok("[5] *** MF1: a longer key can no longer poison a shorter key's maximum ***",
    (function()
      -- After a record for `tenant.r9000.payload`, max_recorded() for `tenant`
      -- returned 9000 -- the longer key's embedded marker read as the shorter
      -- key's revision, burning nine thousand numbers.
      local refused = select(1, rv.open({ dir = dir, key = "tenant.r9000.payload",
                                          suffix = ".json" }))
      -- And even if such a file already exists on disk, it is not ours.
      local pdir = dir .. "/poison"
      ds.ensure_dir(pdir)
      ds.write(pdir .. "/tenant.r9000.payload.r1.json", "{}")
      local h = rv.open({ dir = pdir, key = "tenant", suffix = ".json" })
      return refused == nil and h ~= nil and h:max_recorded() == 0
        and select(1, h:claim_next()) == 1
    end)())
  ok("[5] *** MF1: a handle cannot be rewritten after construction ***",
    (function()
      local h = rv.open({ dir = dir, key = "fixed", suffix = ".json" })
      -- `h.key = "../escaped"` bypassed every check and reached a thrown mkdir.
      local wrote = pcall(function() h.key = "../escaped" end)
      local dir_wrote = pcall(function() h.dir = "/etc" end)
      return wrote == false and dir_wrote == false
        and h.key == "fixed" and h:record_path(1) == dir .. "/fixed.r1.json"
    end)())
  ok("[5] MF1: its validated values stay readable", (function()
    local h = rv.open({ dir = dir, key = "readable", suffix = ".json" })
    return h.key == "readable" and h.suffix == ".json" and h.dir == dir
  end)())
  ok("[5] MF1: a legacy key and suffix are still accepted", (function()
    local h = rv.open({ dir = dir, key = "owner__repo@abc1234",
                        suffix = ".review.json" })
    return h ~= nil
      and h:record_path(2) == dir .. "/owner__repo@abc1234.r2.review.json"
  end)())

  -- MF2 -- cleanup must not tombstone a revision committed under another suffix.
  ok("[5] *** MF2: a revision committed as .yaml is not reaped by a .json handle ***",
    (function()
      local cdir = dir .. "/cross"
      ds.ensure_dir(cdir)
      local yaml = rv.open({ dir = cdir, key = "same", suffix = ".yaml" })
      local json = rv.open({ dir = cdir, key = "same", suffix = ".json" })
      -- r1 is COMMITTED as yaml, with an expired reservation left beside it.
      ds.write(yaml:record_path(1), "committed: yes\n")
      ds.write_json(yaml:reserve_path(1),
        { owner = "old", created_at = os.time() - 999, lease_until = os.time() - 1 })
      local n, report = json:cleanup()
      -- The reported failure returned retired=1 and wrote same.r1.tombstone
      -- over a committed record, because `committed` was decided with the
      -- CALLING handle's suffix.
      return n == 0 and not ds.exists(json:tombstone_path(1))
        and ds.exists(yaml:record_path(1)) and #report.errors == 0
    end)())
  ok("[5] *** MF2: committedness is suffix-independent, like spentness ***",
    (function()
      local cdir = dir .. "/cross2"
      ds.ensure_dir(cdir)
      local yaml = rv.open({ dir = cdir, key = "same", suffix = ".yaml" })
      local json = rv.open({ dir = cdir, key = "same", suffix = ".json" })
      ds.write(yaml:record_path(3), "committed: yes\n")
      return json:committed(3) == true and yaml:committed(3) == true
        and json:committed(2) == false and json:max_recorded() == 3
    end)())
  ok("[5] MF2: one classifier names every record kind", (function()
      local h = rv.open({ dir = dir, key = "kinds", suffix = ".review.json" })
      local function kind(n) return select(2, h:classify(n)) end
      return kind("kinds.r1.review.json") == "committed"
        and kind("kinds.r1.reserve") == "reserve"
        and kind("kinds.r1.tombstone") == "tombstone"
        and kind("kinds.r1.review.json.claim.4242") == "transient"
        and kind("kinds.r1.review.json.lock") == "lock"
        and kind("kinds.r1x.review.json") == nil
        and kind("other.r1.review.json") == nil
    end)())

  -- MF3 -- a release anomaly must be FALSY to the callers that will inherit it.
  ok("[5] *** MF3: a CONSUMER branching on the first slot sees FAILURE ***",
    (function()
      -- Shaped exactly like worktree.watch.set: bind (ok, err), branch on
      -- `if not ok`, publish otherwise. Under the r1 contract this published
      -- the change and dropped the error.
      local guarded = dir .. "/mf3.txt"
      local lockpath = guarded .. ".lock"
      local published = false
      local real_unlink = uv.fs_unlink
      uv.fs_unlink = function(path, ...)
        if path == lockpath then return nil, "forced unlink failure" end
        return real_unlink(path, ...)
      end
      local okc, errc = ds.with_lock(guarded, function() return true end)
      if okc then published = true end
      uv.fs_unlink = real_unlink
      ds.delete(lockpath)
      return published == false and errc ~= nil
    end)())
  ok("[5] *** MF3: a REPLACED lock is an anomaly, and the successor survives ***",
    (function()
      local guarded = dir .. "/mf3-replaced.txt"
      local lockpath = guarded .. ".lock"
      local v, err, completed = ds.with_lock(guarded, function()
        -- The pathname comes to name a different file mid-section.
        uv.fs_unlink(lockpath)
        ds.write(lockpath, '{"pid":424242,"host":"successor"}')
        return 7
      end)
      local successor = select(1, ds.read_json(lockpath))
      ds.delete(lockpath)
      -- r1 returned (7, nil) here: it preserved the successor correctly but
      -- claimed success, though it can no longer prove exclusion held.
      return v == nil and err ~= nil and completed == 7
        and tostring(err):find("REPLACED", 1, true)
        and type(successor) == "table" and successor.pid == 424242
    end)())
  ok("[5] *** MF3: a VANISHED lock is an anomaly too ***", (function()
    local guarded = dir .. "/mf3-vanished.txt"
    local v, err, completed = ds.with_lock(guarded, function()
      uv.fs_unlink(guarded .. ".lock")
      return 9
    end)
    return v == nil and err ~= nil and completed == 9
      and tostring(err):find("VANISHED", 1, true)
  end)())
  ok("[5] MF3: an ordinary run is untouched by all of that", (function()
    local v, err, completed = ds.with_lock(dir .. "/mf3-clean.txt",
      function() return "fine" end)
    return v == "fine" and err == nil and completed == nil
  end)())

  -- MF4 -- rendered-key collisions must be refused, not silently resolved.
  ok("[5] *** MF4: two keys rendering to ONE name is an ERROR, not a lost value ***",
    (function()
      -- r1 emitted two members called "2" and decoding kept one.
      local okc, err = pcall(ds.encode_pretty, { [2] = "numeric", ["2"] = "string" })
      return okc == false and tostring(err):find("both render as", 1, true)
    end)())
  ok("[5] MF4: write_json reports it instead of persisting a lossy document",
    (function()
      local okw, err = ds.write_json(dir .. "/mf4.json",
        { [2] = "numeric", ["2"] = "string" })
      return okw == false and tostring(err):find("encode failed", 1, true)
        and not ds.exists(dir .. "/mf4.json")
    end)())
  ok("[5] MF4: an unrenderable key type is refused", (function()
    local okb = pcall(ds.encode_pretty, { [true] = "x" })
    local okt = pcall(ds.encode_pretty, { [{}] = "x" })
    return okb == false and okt == false
  end)())
  ok("[5] MF4: distinct numeric and string keys still round-trip", (function()
    local enc = ds.encode_pretty({ [2] = "numeric", three = "string" })
    local back = vim.json.decode(enc)
    return back["2"] == "numeric" and back.three == "string"
  end)())

  -- MF5 -- delete's absent/error distinction.
  ok("[5] *** MF5: a stat failure is NOT successful absence ***", (function()
    local target = dir .. "/mf5.json"
    ds.write(target, "{}")
    local real_stat = uv.fs_stat
    uv.fs_stat = function(path, ...)
      if path == target then return nil, "forced permission failure", "EACCES" end
      return real_stat(path, ...)
    end
    local okd, err = ds.delete(target)
    uv.fs_stat = real_stat
    local still_there = ds.exists(target)
    -- The reported failure returned ok=true, err=nil with the file still there,
    -- which in P4c would mean reporting a pair deleted that is not.
    return okd == false and err ~= nil and still_there == true
  end)())
  ok("[5] MF5: a genuinely absent document is still deleted successfully",
    (function()
      local okd, err = ds.delete(dir .. "/never-existed.json")
      return okd == true and err == nil
    end)())
  ok("[5] *** MF5: losing the race to another deleter is still success ***",
    (function()
      -- Stat says present, unlink says ENOENT: someone else removed it in
      -- between. The caller asked for it to be gone, and it is gone.
      local target = dir .. "/mf5-race.json"
      ds.write(target, "{}")
      local real_unlink = uv.fs_unlink
      uv.fs_unlink = function(path, ...)
        if path == target then
          real_unlink(path)
          return nil, "ENOENT: no such file or directory", "ENOENT"
        end
        return real_unlink(path, ...)
      end
      local okd, err = ds.delete(target)
      uv.fs_unlink = real_unlink
      return okd == true and err == nil and not ds.exists(target)
    end)())
  ok("[5] MF5: and a real unlink failure is still a failure", (function()
    local target = dir .. "/mf5-hard.json"
    ds.write(target, "{}")
    local real_unlink = uv.fs_unlink
    uv.fs_unlink = function(path, ...)
      if path == target then return nil, "forced io failure", "EIO" end
      return real_unlink(path, ...)
    end
    local okd, err = ds.delete(target)
    uv.fs_unlink = real_unlink
    return okd == false and err ~= nil
  end)())
end

io.stdout:write("\n[6] CONTROLS for r2 (lector final review)\n")
do
  local uv = vim.uv or vim.loop
  local dir = sb .. "/r3"
  ds.ensure_dir(dir)

  -- MF1 -- the revision is validated at the PUBLIC boundary, in every verb.
  local h = rv.open({ dir = dir, key = "safe", suffix = ".json" })
  local BAD = { false, true, "garbage", 0, -1, 1.5, 0/0, math.huge, nil, {}, "" }
  ok("[6] *** MF1: no bad revision ALIASES to r1 through any verb ***",
    (function()
      -- `tonumber(revision) or 1` made claim(false) and claim("garbage") both
      -- take r1, and 0/-1 created key.r0/key.r-1 -- names outside the namespace
      -- `_scan` tracks, so the allocator could create claims it could neither
      -- count nor retire.
      for _, bad in ipairs({ false, true, "garbage", 0, -1, 1.5, math.huge }) do
        if h:record_path(bad) ~= nil then return false, "record_path " .. tostring(bad) end
        if h:reserve_path(bad) ~= nil then return false, "reserve_path " .. tostring(bad) end
        if h:tombstone_path(bad) ~= nil then return false, "tombstone_path " .. tostring(bad) end
        if h:committed(bad) ~= false then return false, "committed " .. tostring(bad) end
        if h:owns(bad, "t") ~= false then return false, "owns " .. tostring(bad) end
        if h:release(bad, "t") ~= false then return false, "release " .. tostring(bad) end
        local c, cerr = h:claim(bad, "t")
        if c ~= false or cerr ~= rv.REVISION_ERR then return false, "claim " .. tostring(bad) end
        local t, terr, f = h:retire(bad, "t")
        if t ~= false or terr ~= rv.REVISION_ERR or f ~= false then
          return false, "retire " .. tostring(bad)
        end
      end
      return true
    end)())
  ok("[6] *** MF1: and NO record is created for any of them ***",
    #ds.list(dir, "^safe%.") == 0, vim.inspect(ds.list(dir)))
  ok("[6] MF1: nan and the infinities are refused too", (function()
    local nan = 0 / 0
    return h:record_path(nan) == nil and h:record_path(math.huge) == nil
      and h:record_path(-math.huge) == nil
  end)())
  ok("[6] MF1: a VALID revision still works, and a numeric string is accepted",
    h:record_path(3) == dir .. "/safe.r3.json"
    and h:record_path("3") == dir .. "/safe.r3.json")
  ok("[6] MF1: nil is refused rather than defaulting", h:record_path(nil) == nil)
  ok("[6] CONTROL: after all that, the allocator still starts at r1",
    select(1, h:claim_next()) == 1)

  -- MF2 -- a raising body AND a failed release: both facts, one error.
  ok("[6] *** MF2: a throw plus a failed unlink reports BOTH ***", (function()
    local guarded = dir .. "/mf2.txt"
    local lockpath = guarded .. ".lock"
    local real_unlink = uv.fs_unlink
    uv.fs_unlink = function(path, ...)
      if path == lockpath then return nil, "forced unlink failure" end
      return real_unlink(path, ...)
    end
    local v, err = ds.with_lock(guarded, function() error("body exploded") end)
    uv.fs_unlink = real_unlink
    local wedged = ds.exists(lockpath)
    ds.delete(lockpath)
    -- r2 reported only "body exploded" while the lock stayed on disk, so the
    -- caller was never told the store was wedged. The conjunction is the
    -- dangerous case, and each failure alone was already covered.
    return v == nil and err ~= nil
      and tostring(err):find("body exploded", 1, true) ~= nil
      and tostring(err):find("COULD NOT be released", 1, true) ~= nil
      and wedged == true
  end)())
  ok("[6] MF2: a throw with a CLEAN release still reports just the throw",
    (function()
      local v, err = ds.with_lock(dir .. "/mf2b.txt", function() error("just me") end)
      return v == nil and tostring(err):find("just me", 1, true)
        and tostring(err):find("COULD NOT be released", 1, true) == nil
    end)())
end

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
