-- auto-core — ADR-0065 P2: syntax highlighting in the diff panes.
--
-- Run headless:
--   nvim --headless -u NONE -l tests/adr0065-p2-highlight.lua
--
-- P2 is a RELEASE GATE (ADR-0065 §3, D2), and its central claim — that the
-- diff's background and treesitter's foreground compose rather than compete —
-- was theme-dependent in an earlier revision. So the theme is part of the
-- fixture here, not an assumption: every assertion runs against a scheme whose
-- DiffAdd/DiffDelete carry BOTH a foreground and a background, which is the
-- case that used to break.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end

-- Wrap the real treesitter entry points BEFORE anything opens a view, so the
-- assertions below observe actual calls rather than self-reported ones.
local seen = { start = 0, stop = 0, last_ft = nil }
do
  local real_start, real_stop = vim.treesitter.start, vim.treesitter.stop
  vim.treesitter.start = function(b, ft)
    seen.start = seen.start + 1; seen.last_ft = ft
    return real_start(b, ft)
  end
  vim.treesitter.stop = function(b)
    seen.stop = seen.stop + 1
    return real_stop(b)
  end
end

local hl = require("auto-core.ui.highlights")
local gitdiff = require("auto-core.git.diff")
local dv = require("auto-core.ui.diffview")

io.stdout:write("\n[1] derived groups are background-only, under a fg+bg theme\n")
vim.api.nvim_set_hl(0, "DiffAdd",    { fg = "#00ff00", bg = "#003300" })
vim.api.nvim_set_hl(0, "DiffDelete", { fg = "#ff0000", bg = "#330000" })
hl._reset_for_tests(); hl.ensure()
local add = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffAddBg", link = false })
local del = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffDeleteBg", link = false })
ok("the theme's background is carried through", add.bg ~= nil and del.bg ~= nil, vim.inspect(add))
ok("*** and its FOREGROUND is not — nothing can compete with treesitter ***",
  add.fg == nil and del.fg == nil, vim.inspect({ add, del }))
ok("the source group really did carry a foreground (positive control)",
  vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false }).fg ~= nil)

io.stdout:write("\n[2] a theme with NO bg falls back rather than painting nothing\n")
vim.api.nvim_set_hl(0, "DiffAdd", { fg = "#00ff00" })
vim.api.nvim_set_hl(0, "DiffDelete", { fg = "#ff0000" })
hl.derive_bg_groups()
local fb = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffAddBg", link = false })
ok("*** an attribute-less group would read as 'the diff broke' — so we supply one ***",
  fb.bg ~= nil and fb.fg == nil, vim.inspect(fb))

io.stdout:write("\n[3] :colorscheme re-derives, but never clobbers an explicit override\n")
vim.api.nvim_set_hl(0, "DiffAdd", { fg = "#00ff00", bg = "#112233" })
hl.derive_bg_groups()
local before = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffAddBg", link = false }).bg
vim.api.nvim_set_hl(0, "DiffAdd", { fg = "#00ff00", bg = "#445566" })
hl.derive_bg_groups()
local after = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffAddBg", link = false }).bg
ok("*** a theme switch re-derives the background ***", before ~= after,
  ("%s -> %s"):format(tostring(before), tostring(after)))
hl.theme_override("AutoCoreDiffDeleteBg", { bg = "#abcdef" })
local pinned = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffDeleteBg", link = false }).bg
-- A REAL `:colorscheme`, not a direct derive_bg_groups() call. The distinction
-- is the whole finding: `:colorscheme` CLEARS every highlight group first, so a
-- derivation that merely declines to overwrite an override leaves it EMPTY.
-- Calling the deriver directly never exercises that clear, and the earlier
-- version of this test passed against code that erased the override.
vim.cmd("colorscheme default")
local after_scheme = vim.api.nvim_get_hl(0, { name = "AutoCoreDiffDeleteBg", link = false })
ok("*** an explicit theme_override survives a REAL :colorscheme ***",
  after_scheme.bg == pinned, vim.inspect(after_scheme) .. " vs " .. tostring(pinned))
ok("and the derived (non-overridden) group is still populated after it",
  vim.api.nvim_get_hl(0, { name = "AutoCoreDiffAddBg", link = false }).bg ~= nil)

io.stdout:write("\n[4] the buffer holds pure file text; numbers come from statuscolumn\n")
local PATCH = table.concat({
  "diff --git a/foo.lua b/foo.lua", "--- a/foo.lua", "+++ b/foo.lua",
  "@@ -10,3 +10,3 @@", " local x = 1", "-local y = 2", "+local y = 3", " return x",
}, "\n")
local files = gitdiff.parse(PATCH)
vim.o.columns, vim.o.lines = 200, 50
dv.open({ files = files })
local st = dv._state_for_tests()
local mid = st.float:bufnr("preview")
local text = vim.api.nvim_buf_get_lines(mid, 0, -1, false)
ok("*** no line-number gutter inside the buffer ***",
  text[1] == "local x = 1", vim.inspect(text))
ok("and no `│` separator in the text either",
  not table.concat(text, ""):find("│", 1, true), vim.inspect(text))

local w = st.float:winid("preview")
ok("the pane claims `number` back from style=minimal", vim.wo[w].number == true)
ok("and installs the statuscolumn",
  vim.wo[w].statuscolumn:find("diffview", 1, true) ~= nil, vim.wo[w].statuscolumn)

io.stdout:write("\n[5] statuscolumn resolves through the window being DRAWN\n")
vim.g.statusline_winid = w
vim.v.lnum = 1
ok("*** row 1 renders its FILE line, not the buffer row ***",
  dv.statuscolumn():find("10") ~= nil, dv.statuscolumn())
vim.v.lnum = 3
ok("row 3 too", dv.statuscolumn():find("12") ~= nil, dv.statuscolumn())
-- A row with no file line must render blank, never a synthetic number. The
-- first fixture is a clean 1:1 hunk and has no such row, so this needs a patch
-- that actually produces one — an unequal replacement block (pad) plus a second
-- hunk (gap). A vacuous skip here would assert nothing about criterion 17.
dv.close()
local GAPPY = table.concat({
  "diff --git a/foo.lua b/foo.lua", "--- a/foo.lua", "+++ b/foo.lua",
  "@@ -10,4 +10,4 @@", " local a = 1", "-local b = 2", "-local c = 3",
  "+local b = 9", " return a",
  "@@ -60,3 +60,3 @@", " local z = 1", "+local w = 2", " return z",
}, "\n")
local gfiles = gitdiff.parse(GAPPY)
dv.open({ files = gfiles })
st = dv._state_for_tests()
local gw = st.float:winid("preview")
local gcol = gitdiff.sides(gfiles[1]).after
local padrow, gaprow
for i, e in ipairs(gcol) do
  if e.kind == "pad" and not padrow then padrow = i end
  if e.kind == "gap" and not gaprow then gaprow = i end
end
ok("the fixture really produced a pad AND a gap (positive control)",
  padrow ~= nil and gaprow ~= nil, ("pad=%s gap=%s"):format(tostring(padrow), tostring(gaprow)))
vim.g.statusline_winid = gw
vim.v.lnum = padrow
ok("*** a PAD row renders EXACTLY empty (criterion 16) ***",
  dv.statuscolumn() == "", "[" .. dv.statuscolumn() .. "]")
vim.v.lnum = gaprow
ok("*** a GAP row renders EXACTLY empty too ***",
  dv.statuscolumn() == "", "[" .. dv.statuscolumn() .. "]")
-- and a real row in the SAME buffer still resolves, so "blank" is not "broken"
local realrow
for i, e in ipairs(gcol) do if e.lineno and not realrow then realrow = i end end
vim.v.lnum = realrow
ok("while a real row in the same buffer still resolves (negative control)",
  dv.statuscolumn():find("%d") ~= nil, "[" .. dv.statuscolumn() .. "]")

io.stdout:write("\n[6] filetype is per side and follows the file\n")
-- Section [5] reopened the view, so re-acquire the live buffer rather than
-- reusing the handle from [4] — which is now a wiped buffer.
local live_preview = st.float:bufnr("preview")
ok("the b/ side took the file's filetype",
  vim.bo[live_preview].filetype == "lua", vim.bo[live_preview].filetype)
local RENAME = table.concat({
  "diff --git a/old.lua b/new.go", "--- a/old.lua", "+++ b/new.go",
  "@@ -1,2 +1,2 @@", " package main", "-func a() {}", "+func b() {}",
}, "\n")
local rfiles = gitdiff.parse(RENAME)
-- Both files in ONE view, switched by moving the cursor in the Files pane —
-- the reuse path that actually happens. Closing and reopening gives fresh
-- buffers and proves nothing about restarting a parser on a reused one.
dv.close()
local both = { gfiles[1], rfiles[1] }
dv.open({ files = both })
st = dv._state_for_tests()
local mid_b, prev_b = st.float:bufnr("middle"), st.float:bufnr("preview")
local function ts_active(b)
  local okp, p2 = pcall(vim.treesitter.get_parser, b)
  return okp and p2 ~= nil
end
ok("file 1 (.lua) resolves both sides to lua",
  vim.bo[mid_b].filetype == "lua" and vim.bo[prev_b].filetype == "lua",
  ("a/=%s b/=%s"):format(vim.bo[mid_b].filetype, vim.bo[prev_b].filetype))
local had_parser = ts_active(prev_b)
-- switch to file 2 IN THE SAME buffers
local left_win = st.float:winid("left")
vim.api.nvim_win_set_cursor(left_win, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.float:bufnr("left") })
ok("*** switching file re-resolves the filetype PER SIDE in the SAME buffers ***",
  vim.bo[mid_b].filetype == "lua" and vim.bo[prev_b].filetype == "go",
  ("a/=%s b/=%s (bufs %d/%d unchanged)"):format(
    vim.bo[mid_b].filetype, vim.bo[prev_b].filetype, mid_b, prev_b))
ok("the buffers really were reused, not replaced (positive control)",
  st.float:bufnr("middle") == mid_b and st.float:bufnr("preview") == prev_b)
-- The parser claim, asserted against something a stub can move.
--
-- "is a parser attached OR is the filetype go" was vacuous: the filetype is
-- already asserted above, and a machine with no go grammar satisfies the
-- clause without either call ever happening. Stubbing start/stop to no-ops
-- left the suite green. The REQUEST counters are the observable.
-- Observed through the REAL API, not through the module's own report. A
-- counter the module increments proves what it INTENDED; wrapping
-- vim.treesitter.start/stop proves what it actually called. If diffview ever
-- stopped calling them but kept bookkeeping, only this catches it.
ok("*** the switch actually invoked treesitter stop AND start ***",
  seen.stop >= 2 and seen.start >= 2, vim.inspect(seen))
ok("and the last start asked for the NEW side's language",
  seen.last_ft == "go", vim.inspect(seen))
ok("the module's own bookkeeping agrees with the real calls (no drift)",
  dv._ts_calls and dv._ts_calls.start == seen.start
  and dv._ts_calls.stop == seen.stop, vim.inspect({ dv._ts_calls, seen }))
do
  -- Negative control: a path with no filetype must stop the old parser and NOT
  -- request a start, so "degrades without error" is a real branch and not an
  -- unexercised comment.
  local before = { stop = seen.stop, start = seen.start }
-- `README` matches `text`, so it is NOT filetype-less — the extension has to
  -- be one nvim genuinely cannot resolve, or this control asserts nothing.
  local NOFT = "diff --git a/x.zzzq b/x.zzzq\n--- a/x.zzzq\n+++ b/x.zzzq\n"
    .. "@@ -1,2 +1,2 @@\n one\n-two\n+three\n"
  dv.close()
  dv.open({ files = gitdiff.parse(NOFT) })
  ok("*** an unknown extension stops the old parser but requests no start ***",
    seen.stop > before.stop and seen.start == before.start,
    vim.inspect({ before = before, after = seen }))
  ok("and the view still renders its text (degrade, not fail)",
    #vim.api.nvim_buf_get_lines(dv._state_for_tests().float:bufnr("preview"), 0, -1, false) > 0)
  dv.close()
  dv.open({ files = both })
  st = dv._state_for_tests()
end
-- The row map is keyed by buffer and the buffers are reused, so a leak here
-- would be unbounded across a session.
local live = {}
for _, pane in ipairs({ "middle", "preview" }) do live[#live + 1] = st.float:bufnr(pane) end
ok("the row map is populated while open (positive control)",
  dv._rowmap[live[1]] ~= nil and dv._rowmap[live[2]] ~= nil,
  vim.inspect(vim.tbl_keys(dv._rowmap)))
dv.close()
ok("*** and released on close, so it cannot grow across a session ***",
  dv._rowmap[live[1]] == nil and dv._rowmap[live[2]] == nil,
  vim.inspect(vim.tbl_keys(dv._rowmap)))

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
