-- tests/diffview-file-list-paths.lua — the Files pane reads as a path, and the
-- footer names the whole one (Johno, 2026-09-10).
--
-- Run:  nvim --headless -u NONE -l tests/diffview-file-list-paths.lua
--
-- THE DEFECT. The file list wrote the full repo-relative path into a fixed
-- 34-column pane and let Neovim clip the overflow. Clipping takes from the
-- RIGHT, so the reader lost the end of the path — the filename — on exactly the
-- rows where the path was long enough to be interesting:
--
--     M internal/dao/gold-artist-pos          ← is this the DAO or its test?
--     M docs/design-documents/2026-0          ← every docs row read identically
--
-- and the `+N -N` counts, written unconditionally after the path, were off the
-- edge on every one of those rows. The question the list exists to answer —
-- "docs, test, or implementation?" — lives in the part that was thrown away.
--
-- WHAT IS PINNED HERE:
--   §1 the pane width ramps 32→38 with the editor, and never leaves that range;
--   §2 every row fits its pane — the regression pair. On the old renderer the
--      rows are ~51 columns wide against a 32-column pane, so §2 fails before
--      the fix and passes after;
--   §3 what is shown is a SUFFIX of the real path, cut on a `/` boundary when
--      one fits, on a character boundary always (never mid-UTF-8-sequence);
--   §4 the counts are whole or absent, never half over the edge;
--   §5 the footer carries the full worktree-relative path, right-aligned, and
--      YIELDS to the key hints rather than pushing one off the line.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines = 200, 50
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("diffview file list — paths a reader can identify\n"); io.stdout:flush()

local D = require("auto-core.git.diff")
local DV = require("auto-core.ui.diffview")

local W = function(s) return vim.fn.strdisplaywidth(s) end

-- The paths are the real ones from Johno's screenshot, which is the point: they
-- are ordinary Go/docs paths, not contrived lengths.
local PATHS = {
  "internal/dao/gold-artist-positions.go",
  "internal/dao/gold-artist-renderable.go",
  "cmd/gold-http/route-artist.go",
  "docs/design-documents/2026-09-05-gold-artist-renderable-guard.md",
  "x.go",
}

---one_file_patch renders a minimal one-hunk unified diff for `path`.
local function one_file_patch(path)
  return table.concat({
    "diff --git a/" .. path .. " b/" .. path,
    "--- a/" .. path,
    "+++ b/" .. path,
    "@@ -1,2 +1,2 @@",
    "-old",
    "+new",
    " tail",
  }, "\n") .. "\n"
end

local function parse_all(paths)
  local patch = {}
  for _, p in ipairs(paths) do patch[#patch + 1] = one_file_patch(p) end
  return D.parse(table.concat(patch))
end

-- ── §1 the pane width ramps with the editor and stays in range ──────
io.stdout:write("\n[1] Files pane width: 32 by default, up to 38 on a wide editor\n")
do
  local w100 = DV._files_pane_width_for_tests(100)
  local w200 = DV._files_pane_width_for_tests(200)
  local w400 = DV._files_pane_width_for_tests(400)
  ok("[1] *** a narrow editor gets the 32-column floor ***", w100 == 32, tostring(w100))
  ok("[1] *** a wide editor spends more than the floor ***", w200 > 32, tostring(w200))
  ok("[1] *** and never more than 38 ***", w400 == 38, tostring(w400))
  ok("[1] the ramp is monotonic", w100 <= w200 and w200 <= w400,
    ("%d %d %d"):format(w100, w200, w400))
  -- A range, asserted over the range: a clamp that only holds at the three
  -- probes above would pass those and still hand a 3-column pane to some
  -- editor size in between.
  local out_of_range
  for cols = 60, 600 do
    local w = DV._files_pane_width_for_tests(cols)
    if w < 32 or w > 38 then out_of_range = ("cols=%d → %d"):format(cols, w); break end
  end
  ok("[1] every editor width from 60 to 600 lands in [32, 38]",
    out_of_range == nil, out_of_range)
end

-- ── §2 every row fits its pane — the regression pair ────────────────
io.stdout:write("\n[2] no row overflows the pane it is drawn in\n")
do
  local files = parse_all(PATHS)
  ok("[2] fixture parsed every file", #files == #PATHS, "#=" .. tostring(#files))

  for _, width in ipairs({ 32, 34, 38 }) do
    local lines = DV._file_rows_for_tests(files, width)
    local worst, worst_line = 0, nil
    for _, l in ipairs(lines) do
      if W(l) > worst then worst, worst_line = W(l), l end
    end
    ok(("[2] *** at %d columns every row fits (widest %d) ***"):format(width, worst),
      worst <= width, ("%q is %d wide"):format(tostring(worst_line), worst))
  end

  -- The counts-bearing rows are the ones the old renderer overflowed, so pin
  -- that the fixture actually CONTAINS a path too long for the pane. Without
  -- this the assertions above would pass on a fixture of `x.go` rows while
  -- observing nothing.
  local longest = 0
  for _, p in ipairs(PATHS) do longest = math.max(longest, #p) end
  ok("[2] the fixture holds a path far wider than the pane", longest > 38 + 10,
    "longest=" .. tostring(longest))
end

-- ── §3 what is shown is the END of the path ─────────────────────────
io.stdout:write("\n[3] the elision keeps the filename and cuts the redundant head\n")
do
  local E = DV._elide_path_for_tests
  local P = "internal/dao/gold-artist-positions.go"

  ok("[3] a path that fits is untouched", E(P, 80) == P, E(P, 80))
  ok("[3] *** the cut lands on a / boundary when one fits ***",
    E(P, 32) == "…/dao/gold-artist-positions.go", E(P, 32))
  ok("[3] *** and takes the LONGEST fitting suffix, not the shortest ***",
    E("a/b/c/d/name.go", 14) == "…/c/d/name.go", E("a/b/c/d/name.go", 14))
  -- 20 columns cannot hold `…/gold-artist-positions.go` (26), so the basename
  -- itself is cut — to exactly the budget, from the left, tail kept.
  ok("[3] *** the filename survives even when no boundary fits ***",
    E(P, 20) == "…artist-positions.go" and W(E(P, 20)) == 20, E(P, 20))
  ok("[3] a filename cut still shows the extension",
    E(P, 12):sub(-3) == ".go", E(P, 12))

  -- Property, over every fixture path at every budget the UI can produce: the
  -- result fits, and it is a real suffix of the real path. A renderer that
  -- silently kept a PREFIX would satisfy "fits" and fail this.
  local bad_width, bad_suffix
  for _, p in ipairs(PATHS) do
    for budget = 5, 70 do
      local got = E(p, budget)
      if W(got) > budget then
        bad_width = ("%q @%d → %q (%d)"):format(p, budget, got, W(got)); break
      end
      local tail = got:sub(1, #"…") == "…" and got:sub(#"…" + 1) or got
      if p:sub(- #tail) ~= tail then
        bad_suffix = ("%q @%d → %q"):format(p, budget, got); break
      end
    end
  end
  ok("[3] *** every elision fits its budget ***", bad_width == nil, bad_width)
  ok("[3] *** every elision is a suffix of the path it stands for ***",
    bad_suffix == nil, bad_suffix)

  -- Multibyte: cutting bytes instead of characters leaves a partial UTF-8
  -- sequence, which the pane draws as garbage. Asserted by CHARACTER position,
  -- which a byte-wise cut cannot satisfy.
  local MB = "docs/デザイン/アーティスト-guard.md"
  local got = E(MB, 20)
  local n = vim.fn.strchars(got) - 1
  local want = "…" .. vim.fn.strcharpart(MB, vim.fn.strchars(MB) - n)
  ok("[3] *** a multibyte path is cut on a character boundary ***", got == want,
    ("%q vs %q"):format(got, want))
  ok("[3] a multibyte elision respects the DISPLAY width, not the byte count",
    W(got) <= 20, ("%q is %d wide"):format(got, W(got)))
end

-- ── §4 the counts are whole or absent ──────────────────────────────
io.stdout:write("\n[4] +N -N is never drawn half over the edge\n")
do
  local files = parse_all(PATHS)
  local lines = DV._file_rows_for_tests(files, 32)
  local partial, with_counts = nil, 0
  for _, l in ipairs(lines) do
    if l:match("  %+%d+ %-%d+$") then
      with_counts = with_counts + 1
    elseif l:match("%+%d") then
      partial = l
    end
  end
  ok("[4] *** no row carries a fragment of its counts ***", partial == nil, partial)
  ok("[4] a row short enough still carries them whole", with_counts > 0,
    "with_counts=" .. tostring(with_counts))
  -- And the path is what won the room: the longest path's row spends its
  -- columns on the path rather than on numbers.
  local long_row
  for _, l in ipairs(lines) do
    if l:find("renderable%-guard%.md") then long_row = l end
  end
  ok("[4] *** the long docs path keeps its filename instead of its counts ***",
    long_row ~= nil and not long_row:match("%+%d+ %-%d+$"), tostring(long_row))
end

-- ── §4b the commit header yields its subject, not its identity ─────
io.stdout:write("\n[4b] a commit group header fits, and keeps the sha\n")
do
  local files = parse_all({ PATHS[1] })
  files[1].commit_short = "bd275db"
  files[1].commit_subject =
    "fix(gold): widen the renderable guard so an empty tab cannot render"
  local lines = DV._file_rows_for_tests(files, 34)
  local hdr = lines[1]
  ok("[4b] the header is the first row", hdr:find("▼ Commit", 1, true) == 1, hdr)
  ok("[4b] *** it fits the pane ***", W(hdr) <= 34, ("%q is %d"):format(hdr, W(hdr)))
  ok("[4b] *** the sha is never what gets cut ***",
    hdr:find("bd275db", 1, true) ~= nil, hdr)
  ok("[4b] the cut subject says it was cut", hdr:sub(-3) == "…", hdr)
  ok("[4b] the file row underneath is still indented under its commit",
    lines[2]:find("^    [%+MDR%?] ") ~= nil, lines[2])
end

-- ── §5 the footer names the whole path, and never covers a hint ─────
io.stdout:write("\n[5] the footer carries the full worktree-relative path\n")
do
  local LONG = "docs/design-documents/2026-09-05-gold-artist-renderable-guard.md"
  local files = parse_all({ LONG, "cmd/gold-http/route-artist.go" })

  local function footer_line()
    local st = DV._state_for_tests()
    local b = st and st.float:bufnr("footer")
    return (b and vim.api.nvim_buf_is_valid(b))
      and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or nil
  end
  local function footer_width()
    local st = DV._state_for_tests()
    local w = st and st.float:winid("footer")
    return (w and vim.api.nvim_win_is_valid(w)) and vim.api.nvim_win_get_width(w) or nil
  end

  vim.o.columns = 200
  local float = DV.open({ files = files, context = "hunk" })
  ok("[5] diffview opened on a wide editor", float ~= nil)
  local line, fw = footer_line(), footer_width()
  ok("[5] *** the footer ends with the current file's full path ***",
    line ~= nil and line:sub(- #LONG) == LONG, tostring(line))
  ok("[5] *** it is right-aligned, not appended after the hints ***",
    line ~= nil and fw ~= nil and W(line) >= fw - 2 and W(line) <= fw,
    ("width %s of %s"):format(line and W(line), tostring(fw)))
  ok("[5] the hints are all still there", line ~= nil
    and line:find("j/k file", 1, true) and line:find("q close", 1, true), tostring(line))
  ok("[5] at least two columns separate the last hint from the path",
    line ~= nil and line:find("q close   ", 1, true) ~= nil, tostring(line))

  -- It FOLLOWS the file. A footer wired at the call sites instead of in the
  -- renderer names the previous file on whichever path was forgotten.
  vim.api.nvim_set_current_win(float:winid("left"))
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("f", true, false, true), "x", false)
  ok("[5] f advanced the file",
    DV.current_file() and DV.current_file().path == "cmd/gold-http/route-artist.go",
    DV.current_file() and DV.current_file().path)
  ok("[5] *** and the footer path advanced with it ***",
    (footer_line() or ""):sub(- #"cmd/gold-http/route-artist.go")
      == "cmd/gold-http/route-artist.go", tostring(footer_line()))
  DV.close()

  -- The hints win. On an editor narrow enough that the hint line already fills
  -- the footer, the path is DROPPED — the same fixture that showed a path above,
  -- which is what makes this a measurement and not a tautology.
  vim.o.columns = 110
  DV.open({ files = files, context = "hunk" })
  local narrow = footer_line() or ""
  local nfw = footer_width()
  ok("[5] *** a narrow footer keeps every hint ***",
    narrow:find("j/k file", 1, true) ~= nil and narrow:find("q close", 1, true) ~= nil,
    ("%q of %s"):format(narrow, tostring(nfw)))
  ok("[5] *** and the path yields rather than overflowing the line ***",
    nfw ~= nil and W(narrow) <= nfw, ("%d of %s"):format(W(narrow), tostring(nfw)))
  ok("[5] the dropped path is dropped WHOLE, not truncated to a stub",
    narrow:find("guard%.md") == nil, narrow)
  DV.close()
  vim.o.columns = 200
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
