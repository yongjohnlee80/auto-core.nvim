-- tests/adr0083-diffview-nav.lua — ADR-0083 Phase 2:
-- Cross-pane file navigation ([f/]f), context toggle (X), and cursor map resumption.
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

io.stdout:write("ADR-0083 Phase 2 — diffview cross-pane nav and context toggle\n"); io.stdout:flush()

local D = require("auto-core.git.diff")
local DV = require("auto-core.ui.diffview")

-- 1. Unit test git.diff.sides context expansion
local raw_diff = table.concat({
  "diff --git a/pkg/mod.lua b/pkg/mod.lua",
  "--- a/pkg/mod.lua",
  "+++ b/pkg/mod.lua",
  "@@ -4,4 +4,4 @@",
  "-local old_val = 1",
  "+local new_val = 2",
  " local keep1 = true",
  " local keep2 = true",
  " local keep3 = true",
  "@@ -20,4 +20,4 @@",
  "-local old_end = 99",
  "+local new_end = 100",
  " return M",
}, "\n") .. "\n"

local files = D.parse(raw_diff)
ok("diff parse produces 1 file", #files == 1)
local file = files[1]

-- 1a. Standard hunk mode has gap marker
local hunk_sides = D.sides(file, { context = "hunk" })
local has_gap = false
for _, e in ipairs(hunk_sides.before) do
  if e.kind == "gap" then has_gap = true break end
end
ok("hunk mode has gap marker between separated hunks", has_gap)

-- 1b. Full context mode eliminates gaps and includes full context lines
local full_before = {
  "local M = {}",
  "-- header comment",
  "local version = '1.0'",
  "local old_val = 1",
  "local keep1 = true",
  "local keep2 = true",
  "local keep3 = true",
  "local padding1 = nil",
  "local padding2 = nil",
  "local padding3 = nil",
  "local padding4 = nil",
  "local padding5 = nil",
  "local padding6 = nil",
  "local padding7 = nil",
  "local padding8 = nil",
  "local padding9 = nil",
  "local padding10 = nil",
  "local padding11 = nil",
  "local padding12 = nil",
  "local old_end = 99",
  "return M",
}
local full_after = {
  "local M = {}",
  "-- header comment",
  "local version = '1.0'",
  "local new_val = 2",
  "local keep1 = true",
  "local keep2 = true",
  "local keep3 = true",
  "local padding1 = nil",
  "local padding2 = nil",
  "local padding3 = nil",
  "local padding4 = nil",
  "local padding5 = nil",
  "local padding6 = nil",
  "local padding7 = nil",
  "local padding8 = nil",
  "local padding9 = nil",
  "local padding10 = nil",
  "local padding11 = nil",
  "local padding12 = nil",
  "local new_end = 100",
  "return M",
}

local full_sides = D.sides(file, {
  context = "full",
  before_lines = full_before,
  after_lines = full_after,
})

ok("full mode keeps column alignment #before == #after", #full_sides.before == #full_sides.after)
local full_has_gap = false
for _, e in ipairs(full_sides.before) do
  if e.kind == "gap" then full_has_gap = true break end
end
ok("full mode eliminates gap markers", not full_has_gap)

-- Verify leading unchanged lines exist as context
ok("full mode includes line 1 context before first hunk",
  full_sides.before[1].kind == "context" and full_sides.before[1].lineno == 1
  and full_sides.before[1].text == "local M = {}")
-- Verify inter-hunk lines exist as context
local found_padding1 = false
for _, e in ipairs(full_sides.before) do
  if e.text == "local padding1 = nil" and e.kind == "context" and e.lineno == 8 then
    found_padding1 = true
    break
  end
end
ok("full mode includes inter-hunk lines as context", found_padding1)

-- 2. Interactive UI test: multi-file diff view navigation with [f and ]f
local diff_2files = table.concat({
  "diff --git a/a.lua b/a.lua",
  "--- a/a.lua",
  "+++ b/a.lua",
  "@@ -1,2 +1,2 @@",
  "-old_a",
  "+new_a",
  " line2",
  "diff --git a/b.lua b/b.lua",
  "--- a/b.lua",
  "+++ b/b.lua",
  "@@ -1,2 +1,2 @@",
  "-old_b",
  "+new_b",
  " line2_b",
}, "\n") .. "\n"

local parsed_files = D.parse(diff_2files)
local closed_pos = nil

local float, open_err = DV.open({
  files = parsed_files,
  on_close = function(pos) closed_pos = pos end,
  initial = {
    pane = "preview",
    file_positions = {
      ["b.lua"] = { pane = "preview", lnum = 2, col = 0 },
    },
  },
})

ok("diffview opened successfully", float ~= nil, open_err)

if float then
  -- Verify initial pane focus was applied
  local focused_win = vim.api.nvim_get_current_win()
  ok("initial.pane restored focus to preview window",
    focused_win == float:winid("preview"))

  -- Verify keymaps [f, ]f, and X are bound on preview pane
  local prev_b = float:bufnr("preview")
  local km_map = {}
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(prev_b, "n")) do
    km_map[km.lhs] = km
  end
  ok("]f keymap bound on preview pane", km_map["]f"] ~= nil)
  ok("[f keymap bound on preview pane", km_map["[f"] ~= nil)
  ok("X keymap bound on preview pane", km_map["X"] ~= nil)

  -- Execute ]f to move to second file (b.lua)
  km_map["]f"].callback()
  ok("current_file() updated to b.lua after ]f",
    DV.current_file() and DV.current_file().path == "b.lua")
  local left_w = float:winid("left")
  local left_c = vim.api.nvim_win_get_cursor(left_w)
  ok("left pane cursor moved to index 2", left_c[1] == 2)

  -- Verify cursor in preview was restored from initial.file_positions (lnum 2)
  local cur_w = vim.api.nvim_get_current_win()
  ok("focus remained in preview window after ]f", cur_w == float:winid("preview"))
  local cur_c = vim.api.nvim_win_get_cursor(cur_w)
  ok("cursor in b.lua preview pane restored to lnum 2", cur_c[1] == 2, cur_c[1])

  -- Execute [f to move back to first file (a.lua)
  km_map["[f"].callback()
  ok("current_file() returned to a.lua after [f",
    DV.current_file() and DV.current_file().path == "a.lua")

  -- Test context toggle with X
  local foot_buf = float:bufnr("footer")
  local function foot_text()
    return table.concat(vim.api.nvim_buf_get_lines(foot_buf, 0, -1, false), "\n")
  end
  ok("default footer contains [context: 3L]",
    foot_text():find("[context: 3L]", 1, true) ~= nil, foot_text())

  -- Trigger X toggle
  km_map["X"].callback()
  ok("after X toggle, footer shows [context: full]",
    foot_text():find("[context: full]", 1, true) ~= nil, foot_text())

  -- Trigger X toggle back
  km_map["X"].callback()
  ok("after second X toggle, footer returns to [context: 3L]",
    foot_text():find("[context: 3L]", 1, true) ~= nil, foot_text())

  -- Close view and verify snapshot
  DV.close()
  ok("on_close received position snapshot", closed_pos ~= nil)
  ok("closed snapshot contains file_positions map",
    closed_pos and closed_pos.file_positions ~= nil and closed_pos.file_positions["b.lua"] ~= nil)
  ok("closed snapshot contains pane focus",
    closed_pos and closed_pos.pane == "preview")
end

do
  local c1_file = vim.deepcopy(file)
  c1_file.path = "c1_file.lua"
  c1_file.commit_short = "931d6c5"
  c1_file.commit_subject = "first commit subject"
  c1_file.commit_sha = "931d6c5aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  local c2_file = vim.deepcopy(file)
  c2_file.path = "c2_file.lua"
  c2_file.commit_short = "8a02cc8"
  c2_file.commit_subject = "second commit subject"
  c2_file.commit_sha = "8a02cc8bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  local float, err = DV.open({
    files = { c1_file, c2_file },
    title = " Multi-Commit PR Diff ",
  })
  ok("multi-commit diffview opened", float ~= nil, err)
  local left_buf = float:bufnr("left")
  local lines = vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
  ok("left pane has commit 1 header", lines[1]:find("▼ Commit 931d6c5 first commit subject", 1, true) ~= nil, lines[1])
  ok("left pane indents c1_file", lines[2]:find("c1_file.lua", 1, true) ~= nil, lines[2])
  ok("left pane has commit 2 header", lines[3]:find("▼ Commit 8a02cc8 second commit subject", 1, true) ~= nil, lines[3])
  ok("left pane indents c2_file", lines[4]:find("c2_file.lua", 1, true) ~= nil, lines[4])
  DV.close()
end

print(string.format("%d passed, %d failed", pass, fail))
vim.cmd(fail > 0 and "cq" or "qa!")
