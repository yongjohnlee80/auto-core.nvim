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
  ok("[1] mtime is comparable, and nil for an absent path",
    type(ds.mtime(sb .. "/l/a.json")) == "number" and ds.mtime(sb .. "/nope") == nil)

  ok("[1] with_lock runs the body and releases the lock", (function()
    local ran = false
    local okl = ds.with_lock(sb .. "/d/f.txt", function() ran = true; return 7 end)
    return okl and ran and not ds.exists(sb .. "/d/f.txt.lock")
  end)())
  ok("[1] *** with_lock releases even when the body RAISES ***", (function()
    local okl, err = ds.with_lock(sb .. "/d/f.txt", function() error("boom") end)
    -- A lock leaked by a raising callback would wedge the store for the session.
    return okl == false and tostring(err):find("boom", 1, true)
      and not ds.exists(sb .. "/d/f.txt.lock")
  end)())
end

io.stdout:write("\n[2] CONTROL: a NON-REVIEW consumer drives the allocator (MF2)\n")
-- The proof that revisioned identity generalises. No review vocabulary, no
-- review filename grammar: an opaque key and an opaque suffix chosen to look
-- nothing like a review. If this passes, the allocator is domain-agnostic in
-- fact and not merely in its comments.
do
  local dir = sb .. "/widgets"
  ds.ensure_dir(dir)
  local KEY, SUFFIX = "tenant-42:widget", ".widget.yaml"

  ok("[2] nothing recorded yet", rv.max_recorded(dir, KEY, SUFFIX) == 0)

  -- The CRASHED-WRITER fence, on its own key: a number that is reserved but was
  -- never committed is still spent. Without this the matrix showed dropping the
  -- reservation match from `max_recorded` changed nothing — the property was
  -- untested, and a crashed writer's revision would be handed to the next one.
  do
    local CKEY = "tenant-1:crashed"
    local cr = rv.claim_next(dir, CKEY, SUFFIX)
    ok("[2] fixture: r1 is claimed and deliberately never committed",
      cr == 1 and ds.exists(rv.reserve_path(dir, CKEY, cr))
      and not ds.exists(rv.record_path(dir, CKEY, cr, SUFFIX)))
    ok("[2] *** a RESERVED-only number counts toward the maximum ***",
      rv.max_recorded(dir, CKEY, SUFFIX) == cr,
      tostring(rv.max_recorded(dir, CKEY, SUFFIX)))
    ok("[2] *** so the next writer gets r2, not the crashed writer's r1 ***",
      select(1, rv.claim_next(dir, CKEY, SUFFIX)) == cr + 1)
  end
  local r1, t1, e1 = rv.claim_next(dir, KEY, SUFFIX)
  ok("[2] *** claim_next allocates r1 and returns a token ***",
    r1 == 1 and type(t1) == "string" and t1 ~= "" and e1 == nil, tostring(e1))
  ok("[2] the claim is a real reservation record on disk",
    ds.exists(rv.reserve_path(dir, KEY, r1)))
  ok("[2] and the holder owns it", rv.owns(dir, KEY, r1, t1) == true)
  ok("[2] a different token does NOT own it", rv.owns(dir, KEY, r1, "someone-else") == false)

  -- A second claimant cannot take the same number.
  ok("[2] *** an already-claimed revision is refused, not overwritten ***",
    select(1, rv.claim(dir, KEY, r1, "other")) == false)

  -- Commit the record with the CALLER's suffix, release, then the next claim
  -- must move past it.
  ds.write(rv.record_path(dir, KEY, r1, SUFFIX), "committed: true\n")
  rv.release(dir, KEY, r1, t1)
  ok("[2] releasing our own reservation removes it",
    not ds.exists(rv.reserve_path(dir, KEY, r1)))
  ok("[2] *** a committed record still counts toward the maximum ***",
    rv.max_recorded(dir, KEY, SUFFIX) == 1)
  local r2, t2 = rv.claim_next(dir, KEY, SUFFIX)
  ok("[2] *** so the next claim is r2, never a reused r1 ***", r2 == 2, tostring(r2))

  -- Retirement fences a number permanently.
  ok("[2] retire tombstones the revision",
    select(1, rv.retire(dir, KEY, r2, t2)) == true
    and ds.exists(rv.tombstone_path(dir, KEY, r2)))
  ok("[2] and releases the retiring holder's own reservation",
    not ds.exists(rv.reserve_path(dir, KEY, r2)))
  ok("[2] *** a tombstoned number is NEVER handed out again ***",
    rv.max_recorded(dir, KEY, SUFFIX) >= r2
    and select(1, rv.claim_next(dir, KEY, SUFFIX)) > r2)
  ok("[2] a tombstoned revision cannot be claimed directly either",
    select(1, rv.claim(dir, KEY, r2, "anyone")) == false)
  ok("[2] and its former owner no longer owns it", rv.owns(dir, KEY, r2, t2) == false)

  -- CONTROL for the fence, on its OWN key so nothing else holds the maximum.
  -- Remove the tombstone — the state a plain delete would leave — and the number
  -- comes back. Without this the assertion above would also pass if
  -- max_recorded simply always grew. (My first attempt ran this on the shared
  -- key, where a later claim already held the maximum, so it could not drop.)
  do
    local FKEY = "tenant-9:fence"
    local fr, ft = rv.claim_next(dir, FKEY, SUFFIX)
    rv.retire(dir, FKEY, fr, ft)
    local fenced = rv.max_recorded(dir, FKEY, SUFFIX)
    ok("[2] fixture: the tombstone alone holds the maximum", fenced == fr, tostring(fenced))
    ds.delete(rv.tombstone_path(dir, FKEY, fr))
    ok("[2] *** CONTROL: without the tombstone the maximum DROPS ***",
      rv.max_recorded(dir, FKEY, SUFFIX) < fenced,
      ("%d vs %d"):format(rv.max_recorded(dir, FKEY, SUFFIX), fenced))
  end

  -- cleanup reaps only EXPIRED, uncommitted claims.
  local r3, t3 = rv.claim_next(dir, KEY, SUFFIX)
  ok("[2] a live claim is NOT reaped", rv.cleanup(dir, KEY, SUFFIX) == 0
    and rv.owns(dir, KEY, r3, t3) == true)
  -- Expire it by rewriting the lease into the past.
  ds.write_json(rv.reserve_path(dir, KEY, r3),
    { owner = t3, created_at = 0, lease_until = 1 })
  ok("[2] *** an EXPIRED, uncommitted claim is reaped ***",
    rv.cleanup(dir, KEY, SUFFIX) == 1 and ds.exists(rv.tombstone_path(dir, KEY, r3)))
  -- Idempotent: a second pass has nothing left to fence. `retire` with no token
  -- leaves the reservation behind as its fallback fence, so without an
  -- already-tombstoned check cleanup re-counts it forever.
  ok("[2] *** and a second pass reaps NOTHING — the count means newly fenced ***",
    rv.cleanup(dir, KEY, SUFFIX) == 0)
  -- A committed record is never tombstoned by cleanup, however old its lease.
  local r4, t4 = rv.claim_next(dir, KEY, SUFFIX)
  ds.write(rv.record_path(dir, KEY, r4, SUFFIX), "committed\n")
  ds.write_json(rv.reserve_path(dir, KEY, r4),
    { owner = t4, created_at = 0, lease_until = 1 })
  ok("[2] *** a COMMITTED revision is never reaped, however stale its lease ***",
    rv.cleanup(dir, KEY, SUFFIX) == 0
    and not ds.exists(rv.tombstone_path(dir, KEY, r4)))

  -- Keys are independent: one key's numbering says nothing about another's.
  local OTHER = "tenant-7:gadget"
  ok("[2] a different key allocates from its own zero",
    rv.max_recorded(dir, OTHER, SUFFIX) == 0
    and select(1, rv.claim_next(dir, OTHER, SUFFIX)) == 1)

  -- And the record naming is the CALLER's, which is what makes an existing
  -- store movable behind this module with no migration (§3.1).
  ok("[2] *** record paths are composed from the caller's key and suffix ***",
    rv.record_path(dir, "own__repo@abc1234", 3, ".review.json")
      == dir .. "/own__repo@abc1234.r3.review.json",
    rv.record_path(dir, "own__repo@abc1234", 3, ".review.json"))
  ok("[2] as are the two control records",
    rv.reserve_path(dir, "own__repo@abc1234", 3) == dir .. "/own__repo@abc1234.r3.reserve"
    and rv.tombstone_path(dir, "own__repo@abc1234", 3)
      == dir .. "/own__repo@abc1234.r3.tombstone")
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
  -- Work can live in meta alone — a summary with no items is still work.
  ok("[3] *** meta-only content counts as dirty ***", (function()
    dr.get("s:meta").meta.summary = "a finding with no line"
    return dr.dirty("s:meta") == true
  end)())
  ok("[3] blank meta strings do not count", (function()
    dr.get("s:blank").meta.summary = "   "
    return dr.dirty("s:blank") == false
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

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
