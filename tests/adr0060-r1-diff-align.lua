-- tests/adr0060-r1-diff-align.lua — ADR-0060 r1 MF4.
--
-- Run:  nvim --headless -u NONE -l tests/adr0060-r1-diff-align.lua
--
-- A standalone suite rather than a smoke.lua [gitdiff] section: smoke.lua is
-- the 12k-line per-iteration gate and this is a focused pure-function pin, so it
-- runs cheaply on its own and is wired into tests/run-all.sh alongside the
-- others.
--
-- MF4 — git.diff.sides() built the BEFORE and AFTER columns independently: a
-- `del` appended only to before, an `add` only to after, with no filler on the
-- short side. So any hunk whose delete and add counts differ shifted every
-- later context line, placing UNRELATED code on the same visual row in the two
-- panes — and with two or more hunks the ⋯ divider itself landed on different
-- rows, so the one cue that says "the file is not contiguous here" lied in one
-- pane. Both panes are drawn at the same screen row (float.multi middle/preview
-- share row+height), so the skew is visible the instant the view opens, no
-- scrolling required.
--
-- The invariant: for every file, #before == #after, and a shared context line
-- occupies the SAME index in both columns.

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

io.stdout:write("ADR-0060 r1 — diff side-by-side alignment (MF4)\n"); io.stdout:flush()

local D = require("auto-core.git.diff")

---Build a unified diff for one file from a compact hunk spec. Each line is
---{ "context"|"del"|"add", text }. Header line numbers are computed so the
---parser accepts it.
local function make_diff(lines_spec)
  local old_n, new_n = 0, 0
  for _, l in ipairs(lines_spec) do
    if l[1] == "context" then old_n, new_n = old_n + 1, new_n + 1
    elseif l[1] == "del" then old_n = old_n + 1
    elseif l[1] == "add" then new_n = new_n + 1 end
  end
  local out = {
    "diff --git a/f.txt b/f.txt",
    "--- a/f.txt",
    "+++ b/f.txt",
    string.format("@@ -1,%d +1,%d @@", old_n, new_n),
  }
  for _, l in ipairs(lines_spec) do
    local m = l[1] == "del" and "-" or l[1] == "add" and "+" or " "
    out[#out + 1] = m .. l[2]
  end
  return table.concat(out, "\n") .. "\n"
end

---Report the first index at which a shared-context line differs between panes,
---or nil if every context line lines up. Uses text identity: a context line has
---the same text on both sides.
local function context_misaligned(before, after)
  local n = math.max(#before, #after)
  for i = 1, n do
    local b, a = before[i], after[i]
    local bctx = b and b.kind == "context"
    local actx = a and a.kind == "context"
    if bctx ~= actx then return i, (b and b.text), (a and a.text) end
    if bctx and actx and b.text ~= a.text then return i, b.text, a.text end
  end
  return nil
end

-- ── [1] the failing shape from the review: 1 delete, 2 adds ──
;(function()
  local files = D.parse(make_diff({
    { "context", "one" },
    { "del", "two" },
    { "add", "two-edited" },
    { "add", "inserted" },
    { "context", "three" },
    { "context", "four" },
  }))
  local s = D.sides(files[1])
  ok("[1] equal column heights (#before == #after)",
    #s.before == #s.after, ("#before=%d #after=%d"):format(#s.before, #s.after))
  local idx, bt, at = context_misaligned(s.before, s.after)
  ok("[1] *** shared context 'three'/'four' lands on the SAME row in both panes ***",
    idx == nil, idx and ("row " .. idx .. ": before=" .. tostring(bt) .. " after=" .. tostring(at)))
  -- The add-only line must have a pad opposite it, not borrow a context row.
  local three_before = D.row_for(s.before, 3)  -- 'three' is old line 3 / new line 4
  local three_after  = D.row_for(s.after, 4)
  ok("[1] row_for resolves 'three' to the SAME row on both sides",
    three_before ~= nil and three_before == three_after,
    ("before=%s after=%s"):format(tostring(three_before), tostring(three_after)))
end)()

-- ── [2] the mirror: 2 deletes, 1 add ──
;(function()
  local files = D.parse(make_diff({
    { "context", "one" },
    { "del", "two" },
    { "del", "three" },
    { "add", "merged" },
    { "context", "four" },
    { "context", "five" },
  }))
  local s = D.sides(files[1])
  ok("[2] equal column heights", #s.before == #s.after,
    ("#before=%d #after=%d"):format(#s.before, #s.after))
  local idx, bt, at = context_misaligned(s.before, s.after)
  ok("[2] *** shared context resumes aligned after a 2-del/1-add block ***",
    idx == nil, idx and ("row " .. idx .. ": " .. tostring(bt) .. " vs " .. tostring(at)))
end)()

-- ── [3] the ⋯ divider stays on the same row across two hunks ──
;(function()
  -- Two hunks, the first unequal, so a naive builder would put the between-hunk
  -- gap on different rows in the two panes.
  local diff = table.concat({
    "diff --git a/f.txt b/f.txt",
    "--- a/f.txt",
    "+++ b/f.txt",
    "@@ -1,3 +1,4 @@",
    " a",
    "-b",
    "+b1",
    "+b2",
    " c",
    "@@ -20,2 +21,2 @@",
    " x",
    "-y",
    "+y1",
  }, "\n") .. "\n"
  local s = D.sides(D.parse(diff)[1])
  ok("[3] equal column heights across two hunks", #s.before == #s.after,
    ("#before=%d #after=%d"):format(#s.before, #s.after))
  local gap_b, gap_a
  for i, e in ipairs(s.before) do if e.kind == "gap" then gap_b = i break end end
  for i, e in ipairs(s.after) do if e.kind == "gap" then gap_a = i break end end
  ok("[3] *** the ⋯ divider is on the SAME row in both panes ***",
    gap_b ~= nil and gap_b == gap_a,
    ("before gap@%s after gap@%s"):format(tostring(gap_b), tostring(gap_a)))
end)()

-- ── [4] CONTROLS — shapes that already aligned must still align ──
;(function()
  local eq = D.sides(D.parse(make_diff({
    { "context", "a" }, { "del", "b" }, { "add", "b2" }, { "context", "c" },
  }))[1])
  ok("[4] CONTROL — a 1-del/1-add hunk is aligned (was always fine)",
    #eq.before == #eq.after and context_misaligned(eq.before, eq.after) == nil)

  local ctxonly = D.sides(D.parse(make_diff({
    { "context", "a" }, { "context", "b" }, { "context", "c" },
  }))[1])
  ok("[4] CONTROL — a context-only hunk is aligned",
    #ctxonly.before == #ctxonly.after and context_misaligned(ctxonly.before, ctxonly.after) == nil)

  -- The instrument must be able to SEE misalignment, or [1]-[3] prove nothing.
  -- Hand-build a deliberately skewed pair and confirm the detector fires.
  local skew_b = { { kind = "context", text = "a" }, { kind = "del", text = "b" }, { kind = "context", text = "c" } }
  local skew_a = { { kind = "context", text = "a" }, { kind = "context", text = "c" } }
  ok("[4] CONTROL — the misalignment detector FIRES on a known-skewed pair",
    context_misaligned(skew_b, skew_a) ~= nil)
end)()

-- ── [5] pads are inert for review anchoring ──
;(function()
  local s = D.sides(D.parse(make_diff({
    { "del", "gone" }, { "add", "new1" }, { "add", "new2" }, { "context", "tail" },
  }))[1])
  -- Whatever pad entries exist must carry no lineno, so row_for skips them and a
  -- comment can never anchor to a filler row.
  local pads, bad = 0, 0
  for _, col in ipairs({ s.before, s.after }) do
    for _, e in ipairs(col) do
      if e.kind == "pad" then pads = pads + 1; if e.lineno ~= nil then bad = bad + 1 end end
    end
  end
  ok("[5] the imbalance produced at least one pad", pads >= 1, "pads=" .. pads)
  ok("[5] every pad has lineno=nil (inert for row_for / anchoring)", bad == 0, "bad=" .. bad)
end)()

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
