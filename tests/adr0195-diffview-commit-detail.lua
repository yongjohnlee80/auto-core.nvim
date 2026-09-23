-- ADR 0195 D1 — a commit row in the multi-commit diff view shows the COMMIT.
--
-- Invocation (runner contract): nvim --headless -u NONE -l tests/adr0195-diffview-commit-detail.lua
--
-- What this proves (ADR-0195 §2.1 / D1, OQ-1, SF1):
--   * a commit-group HEADER row is distinguished from its first file row
--     (`commit_at_line`), so the cursor follower can branch on it;
--   * a cursor on a header renders the commit via the shared
--     `auto-core.git.graph.show_stat` (called with the repo's common_dir + the
--     commit sha) into the PREVIEW pane, with the MIDDLE pane blanked (OQ-1:
--     geometry stays put);
--   * a move back onto a file restores that file's diff;
--   * a slow/stale commit-detail callback CANNOT repaint over a file diff the
--     cursor moved to (SF1 — the generation guard);
--   * without `common_dir` the whole branch is inert — a header behaves exactly
--     as before (shows the first file's diff), so the change is backward-compatible.
--
-- Falsification (a reversal): collapse the header's `commit_at_line` entry (or
-- drop the CursorMoved commit branch) and cell [2] goes red; remove the async
-- generation guard and cell [SF1] goes red.

local src = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(src, ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.columns, vim.o.lines = 160, 45
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("\n=== ADR 0195 D1 — diff view commit-row detail ===\n"); io.stdout:flush()

local D  = require("auto-core.git.diff")
local DV = require("auto-core.ui.diffview")
local GG = require("auto-core.git.graph")

-- ── fixture: two files, one per commit ──────────────────────────────────
local function one_file_patch(path)
  return table.concat({
    "diff --git a/" .. path .. " b/" .. path,
    "--- a/" .. path,
    "+++ b/" .. path,
    "@@ -1,2 +1,2 @@",
    " keep",
    "-old " .. path,
    "+new " .. path,
  }, "\n") .. "\n"
end
local SHA_A, SHA_B = string.rep("a", 40), string.rep("b", 40)
local function build_files()
  local fA = D.parse(one_file_patch("alpha.lua"))[1]
  local fB = D.parse(one_file_patch("beta.lua"))[1]
  fA.commit_sha, fA.commit_short, fA.commit_subject = SHA_A, "aaaaaaa", "first commit subject"
  fB.commit_sha, fB.commit_short, fB.commit_subject = SHA_B, "bbbbbbb", "second commit subject"
  return { fA, fB }
end
local function reader(side, path)
  return { "keep", (side == "before") and ("old " .. path) or ("new " .. path) }
end

-- ── stub the commit-detail renderer: deterministic, no real git needed. This
-- is diffview's CONSUMER boundary; show_stat's real behaviour is git.graph's
-- own suite. `mode="defer"` captures the callback for the SF1 race test.
local orig_stat = GG.show_stat_async
local stat_calls, defer_cb, mode = {}, nil, "sync"
GG.show_stat_async = function(common_dir, hash, cb)
  stat_calls[#stat_calls + 1] = { common_dir = common_dir, hash = hash }
  local lines = {
    "commit " .. hash, "Author: Tester <t@example.com>", "AuthorDate: now",
    "", "    subject for " .. hash:sub(1, 7), "", " file | 2 +-",
  }
  if mode == "defer" then defer_cb = function() cb(lines) end else cb(lines) end
end

-- Put the cursor on `line` in the LEFT pane and fire the CursorMoved event the
-- cursor-follower hangs off. Headless `-l` has no UI redraw cycle, so neither a
-- `normal!` motion nor feedkeys drives CursorMoved on their own; positioning the
-- cursor and emitting the exact event the UI produces tests the callback for real.
local function move_to(float, line)
  local w = float:winid("left")
  vim.api.nvim_set_current_win(w)
  vim.api.nvim_win_set_cursor(w, { line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = float:bufnr("left") })
  vim.wait(30)
end
local function lines_of(float, pane) return vim.api.nvim_buf_get_lines(float:bufnr(pane), 0, -1, false) end
local function has(lines, needle)
  for _, l in ipairs(lines) do if l:find(needle, 1, true) then return true end end
  return false
end
local function feedk(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(20)
end
local function focus(float, pane) vim.api.nvim_set_current_win(float:winid(pane)) end

-- Consumer/annotation capture: the interaction cells prove commit mode cannot
-- reach any of these for the previously-selected file (lector PR#51 P1).
local add_calls, remove_calls, consumer_calls = {}, {}, {}
local ANNOTATE = {
  on_add    = function(a) add_calls[#add_calls + 1] = a end,
  on_remove = function(a) remove_calls[#remove_calls + 1] = a end,
  pending   = function() return {} end,
}
local KEYMAPS = { { key = "s", fn = function(file) consumer_calls[#consumer_calls + 1] = file end, desc = "submit" } }

-- [1] open with common_dir; the header discriminator is populated
io.stdout:write("\n[1] open + commit_at_line discriminator\n")
local float = DV.open({ files = build_files(), common_dir = "/repo/.git", read_file = reader, context = "hunk",
  annotate = ANNOTATE, keymaps = KEYMAPS })
ok("diffview opened", float ~= nil)
local left = lines_of(float, "left")
ok("left pane renders commit A header", has(left, "▼ Commit aaaaaaa"))
ok("left pane renders commit B header", has(left, "▼ Commit bbbbbbb"))
do
  local st = DV._state_for_tests()
  ok("commit_at_line maps header rows to their commits",
    st and st.commit_at_line and st.commit_at_line[1] and st.commit_at_line[1].sha == SHA_A
      and st.commit_at_line[3] and st.commit_at_line[3].sha == SHA_B,
    st and vim.inspect(st.commit_at_line))
  ok("a FILE row is NOT a commit row", st and st.commit_at_line[2] == nil and st.commit_at_line[4] == nil)
  ok("common_dir stored on state", st and st.common_dir == "/repo/.git")
end

-- [2] cursor on a commit header → the COMMIT renders (not the first file's diff)
io.stdout:write("\n[2] cursor on a commit header shows the commit\n")
move_to(float, 3) -- line 3 = "▼ Commit bbbbbbb …"
local last = stat_calls[#stat_calls]
ok("show_stat_async called for the commit under the cursor",
  last ~= nil and last.hash == SHA_B, last and last.hash or "no call")
ok("…with the repo's common_dir", last ~= nil and last.common_dir == "/repo/.git")
ok("preview pane shows the commit detail (author/message), not a file diff",
  has(lines_of(float, "preview"), "Author: Tester"))
ok("preview is NOT showing beta.lua's diff", not has(lines_of(float, "preview"), "new beta.lua"))
ok("middle pane is blanked/titled for the commit (OQ-1: geometry stays)",
  has(lines_of(float, "middle"), "── commit ──"))
ok("state records the shown commit", DV._state_for_tests().commit_shown == SHA_B)

-- [3] moving back onto a file restores that file's diff
io.stdout:write("\n[3] moving onto a file restores the file diff\n")
move_to(float, 4) -- line 4 = "    beta.lua"
ok("commit_shown cleared on a move to a file", DV._state_for_tests().commit_shown == nil)
ok("preview restored to the file's b/ side", has(lines_of(float, "preview"), "new beta.lua"))
ok("middle no longer shows the commit blank", not has(lines_of(float, "middle"), "── commit ──"))

-- [SF1] a stale commit-detail callback must not repaint over a file diff
io.stdout:write("\n[SF1] stale async commit-detail cannot repaint the file diff\n")
mode = "defer"
move_to(float, 1)          -- header A → _show_commit(A); its cb is captured, not run
local pending = defer_cb
move_to(float, 4)          -- move to a FILE (beta.lua) → commit_shown cleared, file re-rendered
if pending then pending() end  -- NOW fire the stale commit-A callback
vim.wait(20)
ok("stale callback did NOT paint the commit over the file",
  not has(lines_of(float, "preview"), "Author: Tester"))
ok("the file diff is still shown", has(lines_of(float, "preview"), "new beta.lua"))
mode, defer_cb = "sync", nil

-- [P1] commit mode fails file-only actions closed (lector PR#51 P1) — real dispatch
io.stdout:write("\n[P1] commit mode fails file-only actions closed\n")
-- CONTROL: on a FILE the consumer key fires (so a dead key in commit mode is the
-- GUARD, not a broken binding).
move_to(float, 4) -- beta.lua (a file row)
focus(float, "preview")
consumer_calls = {}
feedk("s")
ok("[P1 control] on a FILE, the consumer key fires WITH the file",
  #consumer_calls == 1 and consumer_calls[1] ~= nil, #consumer_calls)

-- On a COMMIT header the same interactions must fail closed.
move_to(float, 1) -- header A → commit mode
ok("current_file() is nil on a commit row", DV.current_file() == nil)
do
  local a, reason = DV._anchor_for_tests(false)
  ok("_anchor_here fails closed on a commit row (c/x cannot anchor)",
    a == nil and tostring(reason):find("commit", 1, true) ~= nil, reason)
end
focus(float, "preview")
consumer_calls, remove_calls = {}, {}
feedk("s") -- consumer submit key
feedk("x") -- drop-annotation key
ok("[P1] the consumer key does NOT fire on a commit row", #consumer_calls == 0, #consumer_calls)
ok("[P1] x does NOT reach on_remove on a commit row", #remove_calls == 0, #remove_calls)
ok("[P1] the footer reflects commit mode (no file actions)",
  has(lines_of(float, "footer"), "no file actions on a commit"))
do
  local before = vim.api.nvim_win_get_cursor(float:winid("preview"))[1]
  feedk("]h")
  ok("[P1] ]h does not jump by stale hunk rows on a commit row",
    vim.api.nvim_win_get_cursor(float:winid("preview"))[1] == before)
end

-- [P2] the commit preview is filetype=git; a file restores its own filetype
io.stdout:write("\n[P2] commit preview is filetype=git; file restores its filetype\n")
ok("[P2] preview filetype is 'git' on a commit row",
  vim.bo[float:bufnr("preview")].filetype == "git", vim.bo[float:bufnr("preview")].filetype)
move_to(float, 4) -- back to beta.lua
ok("[P2] moving to a file restores its filetype (not git)",
  vim.bo[float:bufnr("preview")].filetype ~= "git", vim.bo[float:bufnr("preview")].filetype)
ok("[P2] the file footer is restored (the commit hint is gone)",
  not has(lines_of(float, "footer"), "no file actions on a commit"))

-- [P3] T (toggle context) is refused on a commit row, so it cannot render the
-- file while the guards still say commit, and a pending callback then repaints
-- the COMMIT — never over a file T just drew (lector PR#51 r1).
io.stdout:write("\n[P3] T is refused on a commit row (+ deferred callback)\n")
mode = "defer"
move_to(float, 1) -- header A → commit mode; the show_stat callback is captured
local pendingT = defer_cb
focus(float, "preview")
feedk("T")
ok("[P3] T does NOT leave commit mode", DV._state_for_tests().commit_shown == SHA_A,
  DV._state_for_tests().commit_shown)
ok("[P3] T did NOT render a file (no file b/ side in the preview)",
  not has(lines_of(float, "preview"), "new alpha.lua")
    and not has(lines_of(float, "preview"), "new beta.lua"))
if pendingT then pendingT() end
vim.wait(20)
ok("[P3] the pending callback repaints the COMMIT, not a file",
  has(lines_of(float, "preview"), "Author: Tester"))
mode, defer_cb = "sync", nil

-- [P4] the content row maps are cleared on a commit row so the statuscolumn draws
-- no stale source line numbers; `_show` rebuilds them on the way back to a file.
io.stdout:write("\n[P4] statuscolumn row maps: blank on a commit, rebuilt on a file\n")
ok("[P4] the preview row map is CLEARED on a commit row",
  DV._rowmap[float:bufnr("preview")] == nil)
ok("[P4] the middle row map is CLEARED on a commit row",
  DV._rowmap[float:bufnr("middle")] == nil)
move_to(float, 4) -- file → _show rebuilds the maps
ok("[P4] the preview row map is REBUILT on a file", DV._rowmap[float:bufnr("preview")] ~= nil)

-- [4] backward compatibility: no common_dir → the branch is inert
io.stdout:write("\n[4] no common_dir → header behaves as before (backward-compatible)\n")
DV.close()
stat_calls = {}
local float2 = DV.open({ files = build_files(), read_file = reader, context = "hunk" }) -- NO common_dir
move_to(float2, 3) -- header B row
ok("no common_dir → show_stat_async is NOT called", #stat_calls == 0, #stat_calls)
ok("no common_dir → the header still shows the first file's diff (old behavior)",
  has(lines_of(float2, "preview"), "new beta.lua"))
ok("no common_dir → commit_shown stays nil", DV._state_for_tests().commit_shown == nil)
DV.close()

GG.show_stat_async = orig_stat

ok("assertion floor reached (>= 34)", (pass + fail) >= 34, pass + fail)

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail)); io.stdout:flush()
vim.cmd(fail > 0 and "cq!" or "qa!")
