-- auto-core — ADR-0065 P1: anchor resolution and the annotate surface.
--
-- Run headless:
--   nvim --headless -u NONE -l tests/adr0065-p1-annotate.lua
--
-- The anchor half is pure (a sides() column in, a line or a refusal out) and
-- needs no window. The surface half asserts what is BOUND rather than what
-- happens when pressed, because the three capability states differ precisely
-- in which keys exist.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end

local gitdiff = require("auto-core.git.diff")
local dv = require("auto-core.ui.diffview")

-- Two hunks, and an unequal replacement block, so gap AND pad both appear.
local PATCH = table.concat({
  "diff --git a/foo.lua b/foo.lua",
  "--- a/foo.lua",
  "+++ b/foo.lua",
  "@@ -10,4 +10,4 @@",
  " ctx10",
  "-old11",
  "-old12",
  "+new11",
  " ctx13",
  "@@ -60,3 +60,3 @@",
  " ctx60",
  "+add61",
  " ctx62",
}, "\n")

local files = gitdiff.parse(PATCH)
ok("fixture parses to one file", #files == 1, tostring(#files))
local sides = gitdiff.sides(files[1])
local before, after = sides.before, sides.after

local function kinds(col)
  local out = {}
  for _, e in ipairs(col) do out[#out + 1] = e.kind .. "(" .. tostring(e.lineno) .. ")" end
  return table.concat(out, " ")
end
io.stdout:write("  before: " .. kinds(before) .. "\n")
io.stdout:write("  after : " .. kinds(after) .. "\n")

io.stdout:write("\n[1] anchor\n")
ok("a context row anchors to its file line", gitdiff.anchor(after, 0) == 10, tostring(gitdiff.anchor(after, 0)))
ok("a row past the end refuses", select(1, gitdiff.anchor(after, 999)) == nil)
do
  local gi, pi
  for i, e in ipairs(after) do
    if e.kind == "gap" and not gi then gi = i - 1 end
    if e.kind == "pad" and not pi then pi = i - 1 end
  end
  ok("the fixture produced a gap and a pad on the after side", gi and pi, ("gap=%s pad=%s"):format(tostring(gi), tostring(pi)))
  local _, gr = gitdiff.anchor(after, gi)
  ok("*** a gap refuses, with a reason ***", select(1, gitdiff.anchor(after, gi)) == nil and gr ~= nil, tostring(gr))
  local _, pr = gitdiff.anchor(after, pi)
  ok("*** a pad refuses, with a reason ***", select(1, gitdiff.anchor(after, pi)) == nil and pr ~= nil, tostring(pr))
end

io.stdout:write("\n[2] range — the whole selection is scanned\n")
do
  -- Rows 0..3 on the after side are ctx(10), add(11), PAD, ctx(12). The pad
  -- sits opposite a deleted line, so it consumes no line on this side and the
  -- numbers either side of it still differ by 1 — which is exactly why it is
  -- permitted while a gap is not.
  local span, err = gitdiff.range(after, 0, 3)
  ok("*** an interior PAD is accepted (it consumes no file line) ***",
    span ~= nil and span.start_line == 10 and span.line == 12,
    tostring(err) .. " " .. vim.inspect(span))

  -- across the hunk gap
  local gi
  for i, e in ipairs(after) do if e.kind == "gap" then gi = i - 1 end end
  local s2, e2 = gitdiff.range(after, 0, #after - 1)
  ok("*** a selection crossing a hunk GAP is refused ***", s2 == nil and e2 ~= nil, tostring(e2))
  ok("and the refusal names the boundary", (e2 or ""):find("hunk boundary", 1, true) ~= nil, tostring(e2))

  -- trailing gap: this is the case an endpoint-only rule silently TRIMMED
  local s3, e3 = gitdiff.range(after, 0, gi)
  ok("*** a selection ENDING on a gap is refused, not trimmed ***", s3 == nil and e3 ~= nil, tostring(e3))
  local s4, e4 = gitdiff.range(after, gi, #after - 1)
  ok("*** a selection STARTING on a gap is refused too ***", s4 == nil and e4 ~= nil, tostring(e4))

  local s5 = gitdiff.range(after, 3, 0)
  ok("an inverted selection is normalised", s5 ~= nil and s5.start_line == 10 and s5.line == 12,
    vim.inspect(s5))
  local s6 = gitdiff.range(after, 0, 0)
  ok("a single-row selection is a degenerate span", s6 ~= nil and s6.start_line == s6.line)
end

io.stdout:write("\n[3] pad at an endpoint is refused\n")
do
  local pi
  for i, e in ipairs(after) do if e.kind == "pad" then pi = i - 1 end end
  local s, e = gitdiff.range(after, pi, #after - 1)
  ok("*** a selection starting on a pad is refused ***", s == nil and e ~= nil, tostring(e))
end

io.stdout:write("\n[4] the three capability states differ by what is BOUND\n")
vim.o.columns, vim.o.lines = 200, 50
local function keys_on(pane, mode)
  local st = dv._state_for_tests()
  local b = st and st.float:bufnr(pane)
  local out = {}
  if b then
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, mode or "n")) do out[m.lhs] = true end
  end
  return out
end

dv.open({ files = files })
ok("absent annotate: view still opens", dv.is_open())
local k = keys_on("middle")
ok("*** absent annotate binds NO authoring key ***", not k["c"] and not k["x"], vim.inspect(vim.tbl_keys(k)))
dv.close()

dv.open({ files = files, annotate = { disabled_reason = "no commit", on_add = function() end,
  on_remove = function() end, pending = function() return {} end } })
k = keys_on("middle")
ok("*** disabled: c IS bound (it must explain) ***", k["c"] == true)
ok("*** disabled: x is NOT bound (nothing implies a draft) ***", not k["x"], vim.inspect(vim.tbl_keys(k)))
ok("disabled: neither is bound on the preview pane's x either",
  keys_on("preview")["x"] == nil, vim.inspect(vim.tbl_keys(keys_on("preview"))))
dv.close()

local added = {}
dv.open({ files = files, annotate = {
    on_add = function(a) added[#added + 1] = a end,
    on_remove = function() end,
    pending = function() return added end,
  }, keymaps = { { key = "s", desc = "submit", fn = function() end } } })
k = keys_on("middle")
local kp = keys_on("preview")
ok("enabled: c bound on BOTH content panes",
  k["c"] == true and kp["c"] == true, vim.inspect({ vim.tbl_keys(k), vim.tbl_keys(kp) }))
ok("enabled: x bound on both", k["x"] == true and kp["x"] == true)
-- MF2: the mode is the intent, so the range mapping is a SEPARATE visual one.
local kx = keys_on("middle", "x")
ok("*** `c` is bound in VISUAL mode as its own mapping ***", kx["c"] == true,
  vim.inspect(vim.tbl_keys(kx)))
ok("*** and the authoring keys are NOT on the Files pane ***",
  keys_on("left")["c"] == nil and keys_on("left")["x"] == nil,
  vim.inspect(vim.tbl_keys(keys_on("left"))))
ok("a consumer keymap reaches the content panes",
  k["s"] == true and kp["s"] == true, vim.inspect(vim.tbl_keys(k)))
-- Consumer keymaps are deliberately bound on Files too: `s` submits a review
-- and the file list is a legitimate place to press it, unlike an anchor key.
ok("and a consumer keymap IS available from Files (submit is not row-anchored)",
  keys_on("left")["s"] == true, vim.inspect(vim.tbl_keys(keys_on("left"))))

io.stdout:write("\n[5] pending annotations paint, and the footer counts them\n")
added[#added + 1] = { path = "foo.lua", line = 11, side = "RIGHT", severity = "nit", body = "pending one" }
dv._render_footer()
local st = dv._state_for_tests()
local foot = table.concat(vim.api.nvim_buf_get_lines(st.float:bufnr("footer"), 0, -1, false), "")
ok("*** the footer shows the pending count ***", foot:find("1 pending", 1, true) ~= nil, foot)
local got = dv._pending_for(files[1])
ok("pending is fetched from the consumer, per file", #got == 1, tostring(#got))
ok("*** and is tagged so the painter can tell it apart ***", got[1].author == "pending", tostring(got[1].author))
ok("without mutating the consumer's own table", added[1].author == nil, tostring(added[1].author))
dv.close()

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
