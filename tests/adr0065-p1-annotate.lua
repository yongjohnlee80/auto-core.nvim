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
-- ADR-0065 §2.4 binds c/x/s on middle and preview ONLY. An earlier version
-- also put consumer keymaps on Files, arguing a submit key is not
-- row-anchored — a reasonable UX case, but one a code comment cannot make
-- against an accepted ADR. Restricted, and asserted so it stays that way.
ok("*** consumer keymaps are NOT on the Files pane either (§2.4) ***",
  keys_on("left")["s"] == nil, vim.inspect(vim.tbl_keys(keys_on("left"))))

io.stdout:write("\n[4d] C-h / C-l cycle panes on every pane, like Tab / S-Tab\n")
-- The family convention (`worktree.graph`, `log.viewer`) binds C-h/C-l to pane
-- navigation; the diff view had only Tab/S-Tab, so a reader used to h/l had no
-- directional move. Bound on ALL THREE panes because pane navigation is not
-- content-anchored -- unlike c/x/s, which live on middle/preview only.
-- Neovim canonicalises a control-key lhs to upper case in the keymap listing
-- (`<C-l>` is reported as `<C-L>`), so the assertion has to read the canonical
-- form -- checking the lower-case string would fail against a correct binding.
for _, pane in ipairs({ "left", "middle", "preview" }) do
  local kk = keys_on(pane)
  ok(("*** <C-l> is bound on the %s pane ***"):format(pane), kk["<C-L>"] == true,
    vim.inspect(vim.tbl_keys(kk)))
  ok(("*** <C-h> is bound on the %s pane ***"):format(pane), kk["<C-H>"] == true)
end
dv.close()

io.stdout:write("\n[4e] the current file is a public accessor, and consumer keys receive it\n")
-- `o open this file` cannot be written by the consumer unless it can learn WHICH
-- file the view is showing at press time -- the file changes under j/k, so an
-- open-time capture is stale. The accessor is the seam.
dv.close()
local seen = {}
dv.open({ files = files,
  keymaps = { { key = "o", desc = "open file", fn = function(f) seen[#seen + 1] = f end } } })
local cf = dv.current_file()
ok("*** current_file() returns the file at the current index ***",
  cf ~= nil and cf.path == files[1].path, cf and cf.path)
-- Drive the consumer key and confirm it was handed the same file.
local st = dv._state_for_tests()
for _, pane in ipairs({ "middle", "preview" }) do
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(st.float:bufnr(pane), "n")) do
    if m.lhs == "o" and m.callback then m.callback(); break end
  end
  break
end
ok("*** the consumer key is handed the current file ***",
  #seen >= 1 and seen[1] ~= nil and seen[1].path == files[1].path,
  seen[1] and seen[1].path)
ok("current_file() is nil when the view is closed", (function()
  dv.close(); return dv.current_file() == nil end)())

-- [4b] below reads the live view, so leave one open exactly as the section
-- order did before [4d]/[4e] were inserted here.
dv.open({ files = files })

io.stdout:write("\n[4b] a normal-mode anchor ignores STALE visual marks\n")
do
  -- The regression: `'<`/`'>` are ambient and outlive visual mode, so a plain
  -- `c` with the cursor merely inside an old selection emitted a multi-line
  -- range the user never asked for (observed: start_line=10, line=12).
  local win = dv._state_for_tests().float:winid("preview")
  vim.api.nvim_set_current_win(win)
  vim.fn.setpos("'<", { 0, 1, 1, 0 })
  vim.fn.setpos("'>", { 0, 3, 1, 0 })
  vim.api.nvim_win_set_cursor(win, { 2, 0 })

  local a = dv._anchor_for_tests(false)
  ok("*** normal mode yields a SINGLE line despite stale '< '> ***",
    a ~= nil and a.start_line == nil, vim.inspect(a))
  ok("and it is the CURSOR's line, not the stale selection's start",
    a ~= nil and a.line == (function()
      local col = gitdiff.sides(files[1]).after
      return col[2] and col[2].lineno
    end)(), vim.inspect(a))
  ok("the stale marks really were set (positive control)",
    vim.fn.getpos("'<")[2] == 1 and vim.fn.getpos("'>")[2] == 3)

  -- And a REAL visual selection still produces the range it names.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("normal! Vj")
  local v = dv._anchor_for_tests(true)
  vim.cmd("normal! \27")
  ok("*** a LIVE visual selection still yields a range ***",
    v ~= nil and v.start_line ~= nil and v.line ~= v.start_line, vim.inspect(v))
  ok("with both sides set for GitHub", v ~= nil and v.side == "RIGHT"
    and v.start_side == "RIGHT", vim.inspect(v))
end

io.stdout:write("\n[4c] row maps are released on EVERY close path\n")
do
  local paths = {
    ["q"] = function(st, b)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
        if m.lhs == "q" and m.callback then m.callback() end
      end
    end,
    ["<Esc>"] = function(st, b)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
        if m.lhs == "<Esc>" and m.callback then m.callback() end
      end
    end,
    ["pane-lost"] = function(st, b)
      pcall(vim.api.nvim_win_close, st.float:winid("preview"), true)
      vim.wait(50, function() return not dv.is_open() end)
    end,
    ["dispose"] = function(st) st.float:dispose() end,
    ["M.close"] = function() dv.close() end,
  }
  for name, how in pairs(paths) do
    dv.close()
    dv.open({ files = files })
    local st2 = dv._state_for_tests()
    local b1, b2 = st2.float:bufnr("middle"), st2.float:bufnr("preview")
    local populated = dv._rowmap[b1] ~= nil and dv._rowmap[b2] ~= nil
    how(st2, b2)
    vim.wait(50, function() return not dv.is_open() end)
    ok(("*** %s releases both row maps ***"):format(name),
      populated and dv._rowmap[b1] == nil and dv._rowmap[b2] == nil,
      ("populated=%s left=%s/%s"):format(tostring(populated),
        tostring(dv._rowmap[b1] ~= nil), tostring(dv._rowmap[b2] ~= nil)))
  end
end

io.stdout:write("\n[5] pending annotations paint, and the footer counts them\n")
dv.close()
dv.open({ files = files, annotate = {
    on_add = function(a) added[#added + 1] = a end,
    on_remove = function() end,
    pending = function() return added end,
  } })
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

io.stdout:write("\n[6] a consumer keymap is ADVERTISED, not just bound\n")
-- A key that writes the review and appears nowhere on screen is a key nobody
-- finds. `opts.keymaps` was bound on the content panes and then never named,
-- so `s submit` existed only in the source.
dv.close()
dv.open({ files = files,
  annotate = {
    on_add = function() end, on_remove = function() end,
    pending = function() return {} end,
  },
  keymaps = { { key = "s", desc = "submit review", fn = function() end } } })
local st6 = dv._state_for_tests()
local foot6 = table.concat(vim.api.nvim_buf_get_lines(st6.float:bufnr("footer"), 0, -1, false), "")
ok("*** the footer names the consumer's key ***", foot6:find("s submit", 1, true) ~= nil, foot6)
ok("alongside the keys the view owns", foot6:find("c annotate", 1, true) ~= nil, foot6)
ok("and the close key stays last", foot6:find("q close", 1, true) ~= nil, foot6)

-- A footer that overflows its pane loses its TAIL, and the tail is where the
-- pending count lives — so a narrow view must shed prose, not signal.
local width = vim.api.nvim_win_get_width(st6.float:winid("footer"))
ok("the assembled line fits the pane", vim.fn.strdisplaywidth(foot6) <= width,
  ("%d > %d: %q"):format(vim.fn.strdisplaywidth(foot6), width, foot6))
dv.close()

io.stdout:write("\n[7] a narrow footer keeps the keys and drops the prose\n")
local many = {}
for i = 1, 6 do
  many[i] = { key = tostring(i), desc = "action number " .. i, fn = function() end }
end
dv.close()
dv.open({ files = files,
  annotate = { on_add = function() end, on_remove = function() end,
               pending = function() return { { path = "foo.lua", line = 11 } } end },
  keymaps = many })
local st7 = dv._state_for_tests()
local foot7 = table.concat(vim.api.nvim_buf_get_lines(st7.float:bufnr("footer"), 0, -1, false), "")
local w7 = vim.api.nvim_win_get_width(st7.float:winid("footer"))
ok("*** an overlong footer is still within its pane ***",
  vim.fn.strdisplaywidth(foot7) <= w7,
  ("%d > %d: %q"):format(vim.fn.strdisplaywidth(foot7), w7, foot7))
ok("*** and the pending count survives the trim ***",
  foot7:find("1 pending", 1, true) ~= nil, foot7)
dv.close()

io.stdout:write("\n[8] the last position is captured on close and reopenable\n")
do
  -- Requirement 6: navigate away (open a file, check something) and recall the
  -- diff where you left it. auto-core owns the position -- which file, which
  -- line -- and the consumer owns the identity of the diff. So the seam is:
  -- last_position() on close, and opts.initial to reopen there.
  local rfiles = gitdiff.parse({
    "diff --git a/one.lua b/one.lua",
    "--- a/one.lua",
    "+++ b/one.lua",
    "@@ -1,3 +1,3 @@",
    " a1",
    "-b1",
    "+B1",
    " c1",
    "diff --git a/two.lua b/two.lua",
    "--- a/two.lua",
    "+++ b/two.lua",
    "@@ -1,3 +1,3 @@",
    " a2",
    "-b2",
    "+B2",
    " c2",
  })
  ok("resume fixture has two files", #rfiles == 2, tostring(#rfiles))

  dv.close()
  dv.open({ files = rfiles })
  local st = dv._state_for_tests()
  local win = st.float:winid("left")
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 2, 0 })       -- select file #2
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.float:bufnr("left") })
  local prev = st.float:winid("preview")
  vim.api.nvim_set_current_win(prev)
  vim.api.nvim_win_set_cursor(prev, { 2, 0 })      -- second rendered row
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.float:bufnr("preview") })

  local want_path = rfiles[2].new_path or rfiles[2].path
  dv.close()
  local pos = dv.last_position()
  ok("*** last_position() records the file that was shown ***",
    pos ~= nil and pos.path == want_path, vim.inspect(pos))
  ok("*** and the cursor line within it ***", pos ~= nil and pos.lnum == 2, vim.inspect(pos))

  dv.open({ files = rfiles, initial = pos })
  local st2 = dv._state_for_tests()
  ok("*** opts.initial reopens on the remembered file ***",
    dv.current_file() ~= nil and (dv.current_file().new_path or dv.current_file().path) == want_path,
    dv.current_file() and dv.current_file().path)
  local pw = st2.float:winid("preview")
  ok("*** and restores the cursor line ***",
    vim.api.nvim_win_get_cursor(pw)[1] == 2,
    tostring(vim.api.nvim_win_get_cursor(pw)[1]))
  dv.close()

  dv.open({ files = rfiles, initial = { path = "does/not/exist.lua", lnum = 3 } })
  ok("*** an unknown initial path falls back to the first file ***",
    dv.current_file() ~= nil and dv.current_file().path == rfiles[1].path,
    dv.current_file() and dv.current_file().path)
  dv.close()

  local handed
  dv.open({ files = rfiles, on_close = function(p) handed = p end })
  local st3 = dv._state_for_tests()
  local w3 = st3.float:winid("left")
  vim.api.nvim_set_current_win(w3); vim.api.nvim_win_set_cursor(w3, { 1, 0 })
  dv.close()
  ok("*** on_close(pos) receives the captured position ***",
    handed ~= nil and handed.path ~= nil, vim.inspect(handed))
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
