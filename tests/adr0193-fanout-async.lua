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

-- ── 7. degenerate inputs ────────────────────────────────────────────
local empty = nil
G.fan_out_async("", nil, function(r) empty = r end)
vim.wait(2000, function() return empty ~= nil end, 10)
ok("an empty root yields an empty list, on the loop", empty ~= nil and #empty == 0)

vim.fn.delete(root, "rf")
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail)); io.stdout:flush()
vim.cmd(fail > 0 and "cq!" or "qa!")
