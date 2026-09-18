-- tests/adr0191-hunk-nav.lua — ]h / [h hunk motion in the diff view.
--
-- The gap this closes: `X` toggled whole-file context, and there was no way to
-- reach the next change without scrolling for it.
--
-- Two things this suite is built to actually observe, rather than appear to:
--
--   1. Keys are fed with `nvim_feedkeys(..., "x", ...)` so the mapping is
--      RESOLVED, not called. A previous suite asserted `]f`/`[f` by invoking
--      the keymap callback directly; both handlers were correct and the keys
--      still did nothing in the real UI, because the binding never resolved.
--      A bracket mapping is the same risk class.
--   2. Both context modes are exercised. Hunk boundaries are marked by `gap`
--      rows in "hunk" context and by NOTHING in "full" context, so an
--      implementation that scans for gaps works in one mode and silently does
--      nothing in the other — and "full" is exactly where `X` lands you.
--
-- Scroll synchronisation is NOT tested here: `WinScrolled` never fires
-- headlessly, so an assertion on it would pass while observing nothing. It
-- lives in tests/ui/diffview_scroll_sync.lua, under a pty.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines = 160, 45
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("ADR-0191 — ]h / [h hunk motion, real dispatch, both contexts\n")
io.stdout:flush()

local D = require("auto-core.git.diff")
local DV = require("auto-core.ui.diffview")

-- Far enough apart that 3-line context cannot bridge them: in "hunk" context
-- the two hunks are separated by a gap, and in "full" they are separated by
-- ~30 unchanged lines. Both modes therefore have something to move between.
local N = 40
local function numbered(change)
  local out = {}
  for i = 1, N do out[i] = (change and change[i]) or ("line " .. i) end
  return out
end
local BEFORE = numbered(nil)
local AFTER = numbered({ [2] = "line 2 CHANGED", [38] = "line 38 CHANGED" })

local patch = table.concat({
  "diff --git a/wide.lua b/wide.lua",
  "--- a/wide.lua",
  "+++ b/wide.lua",
  "@@ -1,4 +1,4 @@",
  " line 1",
  "-line 2",
  "+line 2 CHANGED",
  " line 3",
  " line 4",
  "@@ -36,4 +36,4 @@",
  " line 36",
  " line 37",
  "-line 38",
  "+line 38 CHANGED",
  " line 39",
}, "\n") .. "\n"

local files = D.parse(patch)
ok("fixture parses to one file with two hunks",
  files[1] and #(files[1].hunks or {}) == 2,
  files[1] and #(files[1].hunks or {}) or "no file")

local float = DV.open({
  files = D.parse(patch),
  read_file = function(side, path)
    if path ~= "wide.lua" then return nil end
    return side == "before" and BEFORE or AFTER
  end,
  context = "hunk",
})
ok("diffview opened", float ~= nil)

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function cursor_row(pane)
  local w = float:winid(pane)
  return w and vim.api.nvim_win_get_cursor(w)[1]
end

-- ── 1. bound on ALL THREE panes, like f/F/T and unlike c/x/s ─────────
-- Hunk motion is navigation, not authoring, so it means the same thing from
-- the file list as from a content pane.
for _, pane in ipairs({ "left", "middle", "preview" }) do
  local b = float:bufnr(pane)
  local have = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do have[m.lhs] = true end
  ok(("]h and [h are bound on the %s pane"):format(pane),
    have["]h"] and have["[h"],
    ("]h=%s [h=%s"):format(tostring(have["]h"]), tostring(have["[h"])))
end

-- ── 2. ]c / [c are deliberately NOT claimed ─────────────────────────
-- They are Vim's native diff-hunk motions, dormant here only because this
-- renderer never sets 'diff'. Binding them would read as native behaviour
-- while being an approximation of it.
do
  local have = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(float:bufnr("preview"), "n")) do
    have[m.lhs] = true
  end
  ok("]c and [c are left unbound", not have["]c"] and not have["[c"],
    ("]c=%s [c=%s"):format(tostring(have["]c"]), tostring(have["[c"])))
end

-- ── 3. the motion MOVES, through real dispatch, in HUNK context ─────
local st = DV._state_for_tests and DV._state_for_tests()
ok("hunk rows were recorded for the shown file",
  st and st.hunk_rows and #st.hunk_rows == 2,
  st and st.hunk_rows and vim.inspect(st.hunk_rows) or "none")

-- Snapshot the VALUE, not the state reference. `_state_for_tests()` hands back
-- the live table, so holding `st` and reading `st.hunk_rows` after a re-render
-- reads the NEW rows — and the comparison below would silently be a value
-- against itself, which is how it first "passed" nothing.
local hunk_ctx_rows = vim.deepcopy((st or {}).hunk_rows or {})

vim.api.nvim_set_current_win(float:winid("preview"))
vim.api.nvim_win_set_cursor(float:winid("preview"), { 1, 0 })
local start_row = cursor_row("preview")
feed("]h")
local after_next = cursor_row("preview")
ok("]h moves the cursor forward in hunk context",
  after_next and start_row and after_next > start_row,
  ("%s -> %s"):format(tostring(start_row), tostring(after_next)))

feed("[h")
local after_prev = cursor_row("preview")
ok("[h moves back", after_prev and after_next and after_prev < after_next,
  ("%s -> %s"):format(tostring(after_next), tostring(after_prev)))

-- ── 4. the ends are DEFINED, not a keypress that appears to hang ────
-- Park on the last hunk and press on: the cursor must stay put rather than
-- wrap, error, or leave the buffer.
do
  local rows = (DV._state_for_tests and DV._state_for_tests() or {}).hunk_rows or {}
  local last = rows[#rows] or 1
  vim.api.nvim_win_set_cursor(float:winid("preview"), { last, 0 })
  feed("]h")
  ok("]h at the last hunk holds position", cursor_row("preview") == last,
    ("%s vs %s"):format(tostring(cursor_row("preview")), tostring(last)))
  vim.api.nvim_win_set_cursor(float:winid("preview"), { 1, 0 })
  feed("[h")
  ok("[h before the first hunk holds position", cursor_row("preview") == 1,
    tostring(cursor_row("preview")))
end

-- ── 5. FULL context — the mode a gap-scan would silently fail in ────
feed("X")
local st_full = DV._state_for_tests and DV._state_for_tests()
ok("X reached full context", st_full and st_full.context == "full",
  st_full and st_full.context)
ok("hunk rows survive the context change",
  st_full and st_full.hunk_rows and #st_full.hunk_rows == 2,
  st_full and st_full.hunk_rows and vim.inspect(st_full.hunk_rows) or "none")

-- The rows must be DIFFERENT from the hunk-context ones: full context renders
-- every line, so a boundary that was row 5 is now much further down. Identical
-- rows would mean the recompute never happened.
ok("full-context hunk rows differ from hunk-context rows",
  st_full and st_full.hunk_rows and hunk_ctx_rows[2]
    and st_full.hunk_rows[2] ~= hunk_ctx_rows[2],
  ("hunk=%s full=%s"):format(
    tostring(hunk_ctx_rows[2]),
    st_full and st_full.hunk_rows and tostring(st_full.hunk_rows[2])))

vim.api.nvim_set_current_win(float:winid("preview"))
vim.api.nvim_win_set_cursor(float:winid("preview"), { 1, 0 })
local f_start = cursor_row("preview")
feed("]h")
local f_next = cursor_row("preview")
ok("]h moves the cursor forward in FULL context",
  f_next and f_start and f_next > f_start,
  ("%s -> %s"):format(tostring(f_start), tostring(f_next)))
ok("]h in full context lands on a recorded hunk row",
  st_full and vim.tbl_contains(st_full.hunk_rows or {}, f_next),
  ("row %s not in %s"):format(tostring(f_next),
    st_full and vim.inspect(st_full.hunk_rows) or "none"))

-- ── 6. it works from the FILE LIST too, not only a content pane ─────
vim.api.nvim_set_current_win(float:winid("left"))
vim.api.nvim_win_set_cursor(float:winid("preview"), { 1, 0 })
feed("]h")
ok("]h from the file list still moves the content pane",
  (cursor_row("preview") or 1) > 1, tostring(cursor_row("preview")))

-- ── 7. the scroll synchroniser is disposed with the float ───────────
-- The WinScrolled autocmd is matched against a WINDOW, so unlike the
-- buffer-local CursorMoved autocmds it does not die with the buffers. Left
-- behind it would keep firing against windows this float no longer owns.
-- (Whether it MIRRORS correctly needs a UI and is asserted in
-- tests/ui/diffview_scroll_sync.lua; that it exists and is cleaned up does
-- not, so it is checked here where it is cheap.)
local function sync_autocmds()
  local got = vim.api.nvim_get_autocmds({ group = "AutoCoreDiffviewScrollSync" })
  return #got
end
ok("the synchroniser is registered while the view is open", sync_autocmds() > 0,
  tostring(sync_autocmds()))

DV.close()
local after = (pcall(sync_autocmds) and sync_autocmds()) or 0
ok("and it is gone once the view closes", after == 0, tostring(after))

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail)); io.stdout:flush()
vim.cmd(fail > 0 and "cq!" or "qa!")
