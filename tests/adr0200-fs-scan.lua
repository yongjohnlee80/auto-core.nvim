-- tests/adr0200-fs-scan.lua — ADR-0200 §4.1 / §4.4 / §4.6: auto-core.fs.scan, the fs.watch dirty signal,
-- and git.status's porcelain-v2 parser + single-flight async read.
--
-- Run: nvim --headless -u NONE -l tests/adr0200-fs-scan.lua   (on VM43, per vm43-layout)
--
-- Every cell asserts the property in its own terms (reads counted, subprocesses counted, callbacks
-- observed), and the counters it relies on are first shown to move (positive controls), so a cell cannot
-- pass because the instrument is blind.

-- ── sandbox BEFORE any module load (tests-never-touch-the-developer-environment) ─────────────────────
local SANDBOX = vim.fn.tempname() .. "-adr0200-xdg"
for _, k in ipairs({ "CONFIG", "DATA", "STATE", "CACHE" }) do
  vim.env["XDG_" .. k .. "_HOME"] = SANDBOX .. "/" .. k:lower()
  vim.fn.mkdir(SANDBOX .. "/" .. k:lower(), "p")
end

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail ~= nil and ("  — " .. tostring(detail)) or ""))
  io.stdout:write((line:gsub("[\r\n]+", " ")), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end
local function section(title) io.stdout:write("\n" .. title .. "\n") end

section("[0] test isolation")
for _, which in ipairs({ "config", "data", "state", "cache" }) do
  ok("stdpath('" .. which .. "') is inside the sandbox",
    vim.startswith(vim.fn.stdpath(which), SANDBOX), vim.fn.stdpath(which))
end
ok("the loaded auto-core is this worktree's",
  vim.startswith(vim.api.nvim_get_runtime_file("lua/auto-core/fs/scan.lua", false)[1] or "", plugin_root),
  vim.api.nvim_get_runtime_file("lua/auto-core/fs/scan.lua", false)[1])

local scan = require("auto-core.fs.scan")
local events = require("auto-core.events")

local ROOT = vim.fn.tempname() .. "-adr0200"
vim.fn.mkdir(ROOT, "p")
local function mkdir(rel) vim.fn.mkdir(ROOT .. "/" .. rel, "p"); return ROOT .. "/" .. rel end
local function touch(abs) vim.fn.writefile({ "x" }, abs) end
local function names(res)
  local t = {}
  for _, e in ipairs(res.entries) do t[#t + 1] = e.name end
  table.sort(t)
  return t
end
local function wait(pred, ms) return vim.wait(ms or 3000, pred, 5) end

-- A wide directory makes a read span several main-loop ticks (BATCH = 512 per tick).
local WIDE = mkdir("wide")
for i = 1, 20000 do vim.uv.fs_close(vim.uv.fs_open(WIDE .. "/f" .. i, "w", 420)) end

-- ── [1] single-flight ────────────────────────────────────────────────────────────────────────────
section("[1] single-flight: concurrent callers share one read")
scan._reset_for_tests()
do
  local d = mkdir("sf")
  touch(d .. "/a"); touch(d .. "/b")
  local got, owners = 0, {}
  for i = 1, 50 do
    owners[i] = {}
    scan.read_dir(d, owners[i], nil, function(res)
      if #res.entries == 2 then got = got + 1 end
    end)
  end
  wait(function() return got == 50 end)
  ok("all 50 callers delivered the listing", got == 50, got)
  ok("exactly one read ran", scan.stats().reads == 1, scan.stats().reads)
  ok("49 requests counted as coalesced", scan.stats().coalesced == 49, scan.stats().coalesced)
  wait(function() return scan.stats().slots == 0 end, 500)
  ok("no slot left behind", scan.stats().slots == 0, scan.stats().slots)
end

-- ── [2] fresh rerun ──────────────────────────────────────────────────────────────────────────────
section("[2] fresh request during a read gets exactly one follow-up read that sees the change")
scan._reset_for_tests()
do
  local plain_res, fresh_hits, fresh_saw = nil, 0, 0
  scan.read_dir(WIDE, {}, nil, function(res) plain_res = res end)
  -- Wait until the read is genuinely in progress (entries examined but not finished).
  wait(function() return scan.stats().entries > 0 end)
  ok("precondition: the read is in flight", scan.stats().inflight == 1 and plain_res == nil,
    vim.inspect(scan.stats()))
  touch(WIDE .. "/zz-created-mid-read")
  for _ = 1, 10 do
    scan.read_dir(WIDE, {}, { fresh = true }, function(res)
      fresh_hits = fresh_hits + 1
      for _, e in ipairs(res.entries) do
        if e.name == "zz-created-mid-read" then fresh_saw = fresh_saw + 1; break end
      end
    end)
  end
  wait(function() return fresh_hits == 10 end, 10000)
  ok("plain waiter delivered", plain_res ~= nil)
  ok("all 10 fresh waiters delivered", fresh_hits == 10, fresh_hits)
  ok("every fresh result contains the entry created after the first read began", fresh_saw == 10, fresh_saw)
  ok("10 fresh requests produced exactly one rerun (2 reads total)", scan.stats().reads == 2,
    scan.stats().reads)
  vim.fn.delete(WIDE .. "/zz-created-mid-read")
end

-- ── [3] interval: deferred, never dropped, bounded rate ──────────────────────────────────────────
section("[3] MIN_INTERVAL_MS: a repeat inside the window is deferred and coalesced, never dropped")
scan._reset_for_tests()
do
  local d = mkdir("interval")
  touch(d .. "/a")
  local t0, first = vim.uv.now(), nil
  scan.read_dir(d, {}, nil, function() first = vim.uv.now() end)
  wait(function() return first ~= nil end)
  local delivered, second_at = 0, nil
  local burst_start = vim.uv.now()
  -- 200 requests over ~100 ms, from distinct owners (each is a real caller that must be served).
  for i = 1, 200 do
    scan.read_dir(d, {}, nil, function() delivered = delivered + 1; second_at = second_at or vim.uv.now() end)
    if i % 20 == 0 then vim.wait(10) end
  end
  local burst_ms = vim.uv.now() - burst_start
  wait(function() return delivered == 200 end, 3000)
  ok("all 200 burst callers delivered (none dropped)", delivered == 200, delivered)
  ok("the burst was deferred at least once", scan.stats().deferred >= 1, scan.stats().deferred)
  local bound = math.ceil((burst_ms + scan.MIN_INTERVAL_MS) / scan.MIN_INTERVAL_MS) + 1
  ok(("reads bounded by the interval (reads=%d, bound=%d, burst=%dms)"):format(scan.stats().reads, bound, burst_ms),
    scan.stats().reads <= bound and scan.stats().reads >= 2)
  ok("no read of the path inside the window after the first",
    second_at ~= nil and (second_at - first) >= scan.MIN_INTERVAL_MS - 5,
    tostring(second_at and (second_at - first)))
  local _ = t0
end

-- ── [4] owner dedupe bounds the tables ───────────────────────────────────────────────────────────
section("[4] one waiter per (owner, path): 1,000 requests over 20 paths keep ≤ 20 slots")
scan._reset_for_tests()
do
  local owner, paths, calls = {}, {}, {}
  for i = 1, 20 do paths[i] = mkdir("dedupe/d" .. i) end
  local peak = 0
  for n = 1, 1000 do
    local p = paths[(n % 20) + 1]
    scan.read_dir(p, owner, nil, function() calls[p] = (calls[p] or 0) + 1 end)
    peak = math.max(peak, scan.stats().slots)
  end
  wait(function() return scan.stats().slots == 0 end, 5000)
  local total = 0
  for _, c in pairs(calls) do total = total + c end
  ok("peak slots ≤ 20", peak <= 20, peak)
  ok("one delivery per path for the single owner (replaced, not stacked)", total == 20, total)
  ok("at most one read per path", scan.stats().reads <= 20, scan.stats().reads)
end

-- ── [5] cancel ───────────────────────────────────────────────────────────────────────────────────
section("[5] cancel(owner): identity, queued, reading, rerun")
scan._reset_for_tests()
do
  -- Two owners on one path; cancel one while reading.
  local a, b = {}, {}
  local a_got, b_got = false, false
  scan.read_dir(WIDE, a, nil, function() a_got = true end)
  scan.read_dir(WIDE, b, nil, function() b_got = true end)
  wait(function() return scan.stats().entries > 0 end)
  scan.cancel(a)
  wait(function() return b_got end, 10000)
  ok("the other owner is still delivered", b_got)
  ok("the cancelled owner is not", a_got == false)
  -- Owners are compared by identity: two tables with equal contents are different owners.
  local c1, c2 = { gen = 1 }, { gen = 1 }
  local c1_got, c2_got = false, false
  local d = mkdir("cancel-identity")
  scan.read_dir(d, c1, nil, function() c1_got = true end)
  scan.read_dir(d, c2, nil, function() c2_got = true end)
  scan.cancel(c1)
  wait(function() return c2_got end)
  ok("equal-looking owners are distinct: cancelling one keeps the other", c2_got and not c1_got)
  -- Cancelling a fresh rerun waiter: the rerun never runs.
  wait(function() return scan.stats().slots == 0 end, 3000)
  scan._reset_for_tests()
  local r = {}
  scan.read_dir(WIDE, {}, nil, function() end)
  wait(function() return scan.stats().entries > 0 end)
  scan.read_dir(WIDE, r, { fresh = true }, function() end)
  scan.cancel(r)
  wait(function() return scan.stats().slots == 0 end, 10000)
  vim.wait(scan.MIN_INTERVAL_MS + 100)
  ok("a cancelled fresh waiter's rerun never ran", scan.stats().reads == 1, scan.stats().reads)
  -- Cancelling a queued slot removes it from the queue.
  scan._reset_for_tests()
  local q = {}
  local qp = mkdir("queued")
  scan.read_dir(qp, {}, nil, function() end)
  wait(function() return scan.stats().slots == 0 end)
  scan.read_dir(qp, q, nil, function() end) -- inside the interval → deferred
  ok("precondition: the second request is deferred", scan.stats().deferred == 1, scan.stats().deferred)
  scan.cancel(q)
  ok("cancel removes a deferred slot at once", scan.stats().slots == 0 and scan.stats().queued == 0,
    vim.inspect(scan.stats()))
  vim.wait(scan.MIN_INTERVAL_MS + 100)
  ok("the cancelled deferred read never ran", scan.stats().reads == 1, scan.stats().reads)
end

-- ── [6] batching yields the main loop ────────────────────────────────────────────────────────────
section("[6] a 20,000-entry read yields to the main loop between batches")
scan._reset_for_tests()
do
  local order = {}
  scan.read_dir(WIDE, {}, nil, function(res)
    order[#order + 1] = "read:" .. #res.entries
  end)
  -- Scheduled AFTER the read started: with batching it must run before the read completes.
  wait(function() return scan.stats().entries > 0 end)
  vim.schedule(function() order[#order + 1] = "timer" end)
  wait(function() return #order == 2 end, 10000)
  ok("the read saw every entry", order[#order] == "read:20000" or order[1] == "read:20000", vim.inspect(order))
  ok("a callback scheduled mid-read ran before the read completed", order[1] == "timer", vim.inspect(order))
end

-- ── [7] MAX_INFLIGHT ─────────────────────────────────────────────────────────────────────────────
section("[7] at most MAX_INFLIGHT reads at once")
scan._reset_for_tests()
do
  local peak, done = 0, 0
  for i = 1, 20 do
    local d = mkdir("inflight/d" .. i)
    for j = 1, 600 do touch(d .. "/f" .. j) end
    scan.read_dir(d, {}, nil, function() done = done + 1 end)
    peak = math.max(peak, scan.stats().inflight)
  end
  local t = vim.uv.new_timer()
  t:start(0, 1, vim.schedule_wrap(function() peak = math.max(peak, scan.stats().inflight) end))
  wait(function() return done == 20 end, 10000)
  t:stop(); t:close()
  ok("all 20 reads delivered", done == 20, done)
  ok(("peak in-flight ≤ MAX_INFLIGHT (%d ≤ %d)"):format(peak, scan.MAX_INFLIGHT), peak <= scan.MAX_INFLIGHT)
  ok("positive control: reads did overlap (peak > 1)", peak > 1, peak)
end

-- ── [8] contract: owner type, entry types ────────────────────────────────────────────────────────
section("[8] contract: owners must be tables; entry and link types")
scan._reset_for_tests()
do
  local okn = pcall(scan.read_dir, ROOT, 1, nil, function() end)
  ok("a number owner is refused loudly", okn == false)
  local d = mkdir("types")
  touch(d .. "/file")
  mkdir("types/sub")
  vim.uv.fs_symlink(d .. "/sub", d .. "/link-dir")
  vim.uv.fs_symlink(d .. "/file", d .. "/link-file")
  vim.uv.fs_symlink(d .. "/missing", d .. "/dangling")
  local res
  scan.read_dir(d, {}, nil, function(r) res = r end)
  wait(function() return res ~= nil end)
  local by = {}
  for _, e in ipairs(res.entries) do by[e.name] = e end
  ok("file entry", by.file and by.file.type == "file")
  ok("directory entry", by.sub and by.sub.type == "directory")
  ok("link to a directory resolves its target type",
    by["link-dir"] and by["link-dir"].type == "link" and by["link-dir"].target_type == "directory",
    vim.inspect(by["link-dir"]))
  ok("link to a file resolves its target type",
    by["link-file"] and by["link-file"].target_type == "file", vim.inspect(by["link-file"]))
  ok("dangling link has no target type", by.dangling and by.dangling.target_type == nil,
    vim.inspect(by.dangling))
  local missing
  scan.read_dir(ROOT .. "/does-not-exist", {}, nil, function(r) missing = r end)
  wait(function() return missing ~= nil end)
  ok("an unreadable directory reports err and no entries", missing.err ~= nil and #missing.entries == 0,
    vim.inspect(missing))
end

-- ── [9] fs.watch: nameless and error events publish core.fs.dir:dirty ────────────────────────────
section("[9] fs.watch publishes core.fs.dir:dirty instead of dropping nameless/error events")
do
  local watch = require("auto-core.fs.watch")
  local d = mkdir("watched")
  local h = watch.start(d, { recursive = false, self_extend = false })
  ok("precondition: a non-recursive watch opened exactly one handle", h and #h.fs_events == 1,
    h and #h.fs_events)
  local seen = {}
  local sub = events.subscribe("core.fs.dir:dirty", function(p) seen[#seen + 1] = p end)
  local created = {}
  local sub2 = events.subscribe("core.file:created", function(p) created[#created + 1] = p.path end)
  -- positive control: a real event through the real handle
  touch(d .. "/real")
  wait(function() return #created > 0 end)
  ok("positive control: a real create publishes core.file:created", created[1] == d .. "/real",
    vim.inspect(created))
  watch._on_fs_event(h, d, nil, nil, {})
  wait(function() return #seen >= 1 end, 500)
  ok("a nameless event publishes dir:dirty for the watched dir",
    seen[1] and seen[1].path == d and seen[1].reason == "unnamed", vim.inspect(seen))
  watch._on_fs_event(h, d, nil, nil, {})
  vim.wait(50)
  ok("a second nameless event inside the debounce window is coalesced", #seen == 1, #seen)
  vim.wait(h.opts.debounce_ms + 20)
  watch._on_fs_event(h, d, "EIO", "anything", {})
  wait(function() return #seen >= 2 end, 500)
  ok("a handle error publishes dir:dirty with reason 'error'",
    seen[2] and seen[2].reason == "error" and seen[2].err == "EIO", vim.inspect(seen[2]))
  events.unsubscribe(sub); events.unsubscribe(sub2)
  watch.stop(h)
end

-- ── [10] git.status: porcelain v2 -z parser ──────────────────────────────────────────────────────
section("[10] git.status porcelain v2 -z parser (real git output)")
local status = require("auto-core.git.status")
local GR = mkdir("repo")
local function git(...)
  local r = vim.system({ "git", "-C", GR, ... }, { text = true }):wait()
  return r.code == 0, r.stdout, r.stderr
end
git("init", "-q", "-b", "main")
git("config", "user.email", "t@example.invalid"); git("config", "user.name", "t")
vim.fn.writefile({ "*.log", "build/" }, GR .. "/.gitignore")
touch(GR .. "/tracked.txt"); touch(GR .. "/old name.md"); touch(GR .. "/keep.txt")
git("add", "-A"); git("commit", "-q", "-m", "init")
vim.fn.writefile({ "changed" }, GR .. "/tracked.txt")         -- worktree M
git("mv", "old name.md", "new name.md")                       -- staged rename, spaces
touch(GR .. "/staged.txt"); git("add", "staged.txt")          -- staged A
touch(GR .. "/ünïcode file.txt")                              -- untracked, needs quoting in v1
mkdir("repo/untracked_dir"); touch(GR .. "/untracked_dir/inner.txt")
touch(GR .. "/debug.log"); mkdir("repo/build"); touch(GR .. "/build/out.bin")
do
  status._reset_for_tests()
  local entries = status.get(GR, { ignored = true })
  local by = {}
  for _, e in ipairs(entries or {}) do by[e.path] = e end
  ok("worktree modification: X=' ' Y='M'", by["tracked.txt"] and by["tracked.txt"].status_x == " "
    and by["tracked.txt"].status_y == "M", vim.inspect(by["tracked.txt"]))
  ok("rename with spaces keeps both paths", by["new name.md"] and by["new name.md"].status_x == "R"
    and by["new name.md"].orig_path == "old name.md", vim.inspect(by["new name.md"]))
  ok("staged add: X='A'", by["staged.txt"] and by["staged.txt"].status_x == "A")
  ok("unicode untracked path arrives unquoted", by["ünïcode file.txt"] and by["ünïcode file.txt"].status_y == "?",
    vim.inspect(vim.tbl_keys(by)))
  ok("untracked directory arrives as one 'dir/' record", by["untracked_dir/"] and by["untracked_dir/"].status_x == "?",
    vim.inspect(vim.tbl_keys(by)))
  ok("ignored file and ignored directory arrive as '!' records",
    by["debug.log"] and by["debug.log"].status_x == "!" and by["build/"] and by["build/"].status_x == "!",
    vim.inspect(vim.tbl_keys(by)))
  local plain = status.get(GR)
  local has_ignored = false
  for _, e in ipairs(plain or {}) do if e.status_x == "!" then has_ignored = true end end
  ok("without opts.ignored no '!' records (the two forms are cached separately)", not has_ignored)
end

-- ── [11] git.status.get_async: shared, rerun on invalidation, no index write ──────────────────────
section("[11] git.status.get_async: single-flight, rerun after invalidation, --no-optional-locks")
do
  local spawns, ok_flag = 0, false
  local real_system = vim.system
  vim.system = function(cmd, ...)
    if type(cmd) == "table" and cmd[1] == "git" and vim.tbl_contains(cmd, "status") then
      spawns = spawns + 1
      ok_flag = vim.tbl_contains(cmd, "--no-optional-locks")
    end
    return real_system(cmd, ...)
  end
  status._reset_for_tests()
  local got = 0
  for _ = 1, 5 do status.get_async(GR, nil, function(e) if e then got = got + 1 end end) end
  wait(function() return got == 5 end)
  ok("5 concurrent callers delivered", got == 5, got)
  ok("one subprocess served all 5", spawns == 1, spawns)
  ok("the read carries --no-optional-locks", ok_flag == true)
  ok("the result is cached", status.is_cached(GR))
  -- A cached result is served without a new subprocess.
  local cached_hit = false
  status.get_async(GR, nil, function(e) cached_hit = e ~= nil end)
  wait(function() return cached_hit end)
  ok("a cache hit spawns nothing", spawns == 1, spawns)
  -- Invalidation while a read is running: the running read must not be cached, and a caller after the
  -- invalidation gets one follow-up read that sees the change.
  status.invalidate(GR)
  local first, second
  status.get_async(GR, nil, function(e) first = e end)
  vim.fn.writefile({ "late" }, GR .. "/late.txt")
  events.publish("core.git.state:changed", { repo_root = GR })
  status.get_async(GR, nil, function(e) second = e end)
  wait(function() return first ~= nil and second ~= nil end)
  local saw_late = false
  for _, e in ipairs(second or {}) do if e.path == "late.txt" then saw_late = true end end
  ok("the caller after the invalidation got a follow-up read that sees the change", saw_late)
  ok("exactly one follow-up subprocess (3 total)", spawns == 3, spawns)
  -- Agreement: async equals sync for the same state.
  status.invalidate(GR)
  local async_res
  status.get_async(GR, nil, function(e) async_res = e end)
  wait(function() return async_res ~= nil end)
  status.invalidate(GR)
  local sync_res = status.get(GR)
  local function key_of(list)
    local t = {}
    for _, e in ipairs(list) do t[#t + 1] = e.status_x .. e.status_y .. " " .. e.path .. " " .. (e.orig_path or "") end
    table.sort(t)
    return table.concat(t, "\n")
  end
  ok("get_async agrees with get", key_of(async_res) == key_of(sync_res))
  vim.system = real_system
  -- The index is not rewritten by the status read (it cannot re-trigger core.git.state:changed).
  local idx = GR .. "/.git/index"
  local before = vim.uv.fs_stat(idx).mtime
  vim.wait(1100) -- a rewrite would land in a later second
  status.invalidate(GR)
  local done
  status.get_async(GR, nil, function() done = true end)
  wait(function() return done end)
  local after = vim.uv.fs_stat(idx).mtime
  ok("the index file was not rewritten by the read",
    before.sec == after.sec and before.nsec == after.nsec, vim.inspect({ before, after }))
end

vim.fn.delete(ROOT, "rf")
vim.fn.delete(SANDBOX, "rf")
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
