-- tests/adr0193-fanout-async.lua — auto-core.git.graph.fan_out_async.
--
-- `fan_out` spawns two synchronous git processes per repository directory it
-- finds, all of them before a caller can paint anything. `fan_out_async` runs
-- the same discovery off the loop.
--
-- The assertion that matters is AGREEMENT: the async path must return exactly
-- what the sync path returns for the same tree. A faster answer that is a
-- different answer is not the same feature.
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

io.stdout:write("ADR-0193 — fan_out_async agrees with fan_out, off the loop\n")
io.stdout:flush()

local G = require("auto-core.git.graph")

-- ── fixture: a workspace with three shapes ──────────────────────────
-- a normal repo, a bare repo with a linked worktree, and a nested repo that
-- must NOT be descended into (a non-bare repo is a leaf).
local root = vim.fn.tempname() .. "-adr0193"
vim.fn.mkdir(root, "p")
local function sh(cmd) return vim.fn.system(cmd) end

local function mk_normal(name)
  local d = root .. "/" .. name
  vim.fn.mkdir(d, "p")
  sh({ "git", "-C", d, "init", "-q" })
  vim.fn.writefile({ "x" }, d .. "/f.txt")
  sh({ "git", "-C", d, "add", "-A" })
  sh({ "git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t",
       "commit", "-qm", "init" })
  return d
end

local normal = mk_normal("plain")
-- a repo nested INSIDE a normal repo: the walk must stop at the parent
mk_normal("plain/nested")

-- bare + linked worktree
local barep = root .. "/barerepo/.bare"
vim.fn.mkdir(root .. "/barerepo", "p")
sh({ "git", "init", "-q", "--bare", barep })
local seed = mk_normal("seed")
sh({ "git", "-C", seed, "remote", "add", "origin", barep })
sh({ "git", "-C", seed, "push", "-q", "origin", "HEAD:refs/heads/main" })
sh({ "git", "--git-dir=" .. barep, "worktree", "add", "-q",
     root .. "/barerepo/main", "main" })

ok("fixture built", vim.fn.isdirectory(root) == 1, root)

-- ── 1. the sync answer, as the reference ────────────────────────────
G.invalidate_fan_out()
local sync_res = G.fan_out(root, { max_depth = 4 })
ok("sync fan_out found repos", #sync_res > 0, ("%d"):format(#sync_res))

local function shape(list)
  local out = {}
  for _, r in ipairs(list) do
    out[#out + 1] = table.concat({
      r.label or "?", r.common_dir or "?",
      tostring(r.is_bare), tostring(r.sample_worktree),
    }, "|")
  end
  table.sort(out)
  return table.concat(out, "\n")
end
local sync_shape = shape(sync_res)

-- ── 2. the async answer must be IDENTICAL ───────────────────────────
G.invalidate_fan_out()
local async_res, called = nil, 0
G.fan_out_async(root, { max_depth = 4 }, function(r) async_res = r; called = called + 1 end)

ok("fan_out_async returns immediately (did not block the caller)",
  async_res == nil, "callback ran synchronously")

local done = vim.wait(20000, function() return async_res ~= nil end, 25)
ok("async completed", done and async_res ~= nil)
ok("the callback ran exactly once", called == 1, tostring(called))
ok("async result AGREES with sync, field for field",
  async_res and shape(async_res) == sync_shape,
  ("\n--- sync ---\n%s\n--- async ---\n%s"):format(
    sync_shape, async_res and shape(async_res) or "nil"))

-- ── 3. a non-bare repo is a leaf (the descent gate) ─────────────────
-- If the async walk descended into `plain`, it would have found `plain/nested`
-- and the shapes above would already differ — but assert it by name so the
-- reason a regression fails is legible.
local found_nested = false
for _, r in ipairs(async_res or {}) do
  if (r.common_dir or ""):find("plain/nested", 1, true) then found_nested = true end
end
ok("the walk did not descend into a non-bare repo", not found_nested,
  "plain/nested was discovered")

-- ── 4. cache hit still calls back, and on the main loop ─────────────
local hit, hit_called = nil, 0
G.fan_out_async(root, { max_depth = 4 }, function(r) hit = r; hit_called = hit_called + 1 end)
ok("a cache hit does NOT call back synchronously", hit == nil,
  "callback ran inline — callers cannot rely on ordering")
vim.wait(5000, function() return hit ~= nil end, 10)
ok("cache hit delivers the cached value", hit ~= nil and shape(hit) == sync_shape)
ok("cache-hit callback ran exactly once", hit_called == 1, tostring(hit_called))

-- ── 5. in-flight coalescing ─────────────────────────────────────────
G.invalidate_fan_out()
local n = 0
for _ = 1, 3 do
  G.fan_out_async(root, { max_depth = 4 }, function() n = n + 1 end)
end
vim.wait(20000, function() return n >= 3 end, 25)
ok("three concurrent callers all get answered", n == 3, tostring(n))

-- ── 6. invalidation during a walk must not install stale state ──────
-- The walk below gathers its facts before the invalidation, so it may answer
-- its own caller but must not leave that answer in the cache as if fresh.
G.invalidate_fan_out()
local raced = nil
G.fan_out_async(root, { max_depth = 4 }, function(r) raced = r end)
G.invalidate_fan_out(root)  -- while the walk is still running
vim.wait(20000, function() return raced ~= nil end, 25)
ok("a walk raced by invalidation still answers its caller", raced ~= nil)

-- The next call must do real work rather than serve the raced result.
local after = nil
G.fan_out_async(root, { max_depth = 4 }, function(r) after = r end)
vim.wait(20000, function() return after ~= nil end, 25)
ok("and the invalidated cache was not poisoned by it",
  after ~= nil and shape(after) == sync_shape)

-- ── 6b. ALL-ROOT invalidation during a FIRST walk ───────────────────
-- The case a per-root generation sweep misses: a root whose first walk is
-- still running has no generation entry yet, so iterating only the generation
-- table skips it and it caches its stale result against an unchanged
-- generation. Found by agent:zen on PR #49 r0.
-- MUST use a root this process has never walked or invalidated. An earlier
-- invalidation would have created the generation entry whose ABSENCE is the
-- defect, and the cell would pass against the broken sweep too — verified: it
-- did, until this was split onto a fresh root.
local root2 = vim.fn.tempname() .. "-adr0193-fresh"
vim.fn.mkdir(root2 .. "/solo", "p")
sh({ "git", "-C", root2 .. "/solo", "init", "-q" })
vim.fn.writefile({ "y" }, root2 .. "/solo/f.txt")
sh({ "git", "-C", root2 .. "/solo", "add", "-A" })
sh({ "git", "-C", root2 .. "/solo", "-c", "user.email=t@t", "-c", "user.name=t",
     "commit", "-qm", "init" })

local first = nil
G.fan_out_async(root2, { max_depth = 4 }, function(r) first = r end)
G.invalidate_fan_out()            -- ALL-root, while root2's FIRST walk runs
vim.wait(20000, function() return first ~= nil end, 25)
ok("a first walk raced by an ALL-root invalidation still answers", first ~= nil)

-- The observable: the cache must be EMPTY for root2, so the next call performs
-- a real walk rather than being served. Whether the cache was served is
-- otherwise invisible — both paths deliver through vim.schedule — so this
-- counts walks. A sweep that iterates only the generation table never bumped
-- root2 (it had no entry), leaving the stale result cached and this count flat.
local walks_before = G._fan_out_walk_count or 0
local cached_after = nil
G.fan_out_async(root2, { max_depth = 4 }, function(r) cached_after = r end)
vim.wait(20000, function() return cached_after ~= nil end, 25)
ok("and it did not cache its stale result — the next call had to re-walk",
  (G._fan_out_walk_count or 0) > walks_before,
  ("walk count %d -> %d (unchanged means the cache was poisoned and served)")
    :format(walks_before, G._fan_out_walk_count or 0))

-- ── 6c. a caller arriving AFTER invalidation must not join the old flight ──
-- Generation gating only blocks CACHING; without retiring the registration a
-- late joiner is handed exactly the answer the invalidation discarded.
-- The discriminator is the WALK COUNT, not the content. Both flights walk the
-- same unchanged tree, so both produce sync_shape — asserting on the result
-- passes whether the late caller owned a second walk or silently joined the
-- retired one. Only "a second walk began" separates the two.
G.invalidate_fan_out()
local early, late = nil, nil
G.fan_out_async(root, { max_depth = 4 }, function(r) early = r end)
local walks_after_early = G._fan_out_walk_count or 0

G.invalidate_fan_out(root)        -- the early flight is now distrusted
G.fan_out_async(root, { max_depth = 4 }, function(r) late = r end)
local walks_after_late = G._fan_out_walk_count or 0

vim.wait(20000, function() return early ~= nil and late ~= nil end, 25)
ok("both the early and the post-invalidation caller are answered",
  early ~= nil and late ~= nil,
  ("early=%s late=%s"):format(tostring(early ~= nil), tostring(late ~= nil)))
ok("the late caller owned a SECOND walk rather than joining the retired flight",
  walks_after_late > walks_after_early,
  ("walk count %d -> %d (unchanged means it joined the flight the invalidation retired)")
    :format(walks_after_early, walks_after_late))
ok("and the late caller's result is well-formed",
  late ~= nil and shape(late) == sync_shape)

-- ── 6d. a bare repo with TWO linked worktrees ───────────────────────
-- Both worktrees probe to the same common_dir, so whichever is recorded FIRST
-- supplies sample_worktree — the one order-sensitive decision in the walk.
--
-- HONEST LIMIT OF THIS CELL: it cannot force the adverse case. `fs_scandir`
-- order is filesystem-dependent and not controllable from a test, and on this
-- filesystem it already returns name order — so removing the sort does NOT make
-- this cell fail (verified by mutation). What it pins is the OUTCOME: the
-- two paths agree, and sample_worktree is the name-order-first worktree. The
-- sort is what makes that outcome independent of scandir order rather than
-- coincident with it, which is a property this cell asserts but cannot
-- falsify on its own.
sh({ "git", "--git-dir=" .. barep, "worktree", "add", "-q",
     root .. "/barerepo/aaa-second", "-b", "second", "main" })

G.invalidate_fan_out()
local two_sync = G.fan_out(root, { max_depth = 4 })
G.invalidate_fan_out()
local two_async = nil
G.fan_out_async(root, { max_depth = 4 }, function(r) two_async = r end)
vim.wait(20000, function() return two_async ~= nil end, 25)
ok("two linked worktrees: async still agrees with sync",
  two_async ~= nil and shape(two_async) == shape(two_sync),
  ("\n--- sync ---\n%s\n--- async ---\n%s"):format(
    shape(two_sync), two_async and shape(two_async) or "nil"))

local picked = nil
for _, r in ipairs(two_async or {}) do
  if r.is_bare and (r.common_dir or ""):find("barerepo", 1, true) then
    picked = r.sample_worktree
  end
end
ok("and the sample_worktree is the name-order-first one",
  picked ~= nil and picked:find("aaa-second", 1, true) ~= nil,
  tostring(picked))

-- ── 7. degenerate inputs ────────────────────────────────────────────
local empty = nil
G.fan_out_async("", nil, function(r) empty = r end)
vim.wait(2000, function() return empty ~= nil end, 10)
ok("an empty root yields an empty list, on the loop", empty ~= nil and #empty == 0)

vim.fn.delete(root, "rf")
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail)); io.stdout:flush()
vim.cmd(fail > 0 and "cq!" or "qa!")
