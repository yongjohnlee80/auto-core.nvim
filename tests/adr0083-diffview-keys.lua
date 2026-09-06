-- tests/adr0083-diffview-keys.lua — ADR-0083 §2.3/§2.4, 2026-09-06 follow-up.
--
-- Two defects Johno reported that the existing suites could not see:
--
--   1. `]f` / `[f` did nothing in the real UI. Both were bound and both
--      handlers were correct — adr0083-diffview-nav.lua asserts so by invoking
--      `km_map["]f"].callback()`, and auto-finder's resumption suite by
--      `vim.cmd("normal ]f")`. Neither goes through interactive keystroke
--      dispatch, so neither observed what he was pressing. This suite feeds
--      keys with `nvim_feedkeys(..., "x", ...)` so the mapping is RESOLVED,
--      not called.
--   2. The keys were bound on `{ "middle", "preview" }` only, so the file
--      list — the pane whose job is picking a file — had none of them, while
--      the footer advertised them in every pane.
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

io.stdout:write("ADR-0083 — diffview f/F/T keys, every pane, real dispatch\n"); io.stdout:flush()

local D = require("auto-core.git.diff")
local DV = require("auto-core.ui.diffview")

-- A file long enough that a two-hunk diff leaves a gap 3-line context cannot
-- bridge; otherwise "full" and "hunk" render the same rows and every context
-- assertion below would pass while observing nothing.
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

local two_file_patch = patch .. table.concat({
  "diff --git a/second.lua b/second.lua",
  "--- a/second.lua",
  "+++ b/second.lua",
  "@@ -1,2 +1,2 @@",
  "-old_b",
  "+new_b",
  " tail",
}, "\n") .. "\n"

-- ── §1 sides(): degraded is reported, and absent when it can read ────
local one = D.parse(patch)
ok("fixture parsed one file", #one == 1, "#=" .. tostring(#one))
ok("fixture has two distant hunks", #(one[1].hunks or {}) == 2,
  "hunks=" .. tostring(#(one[1].hunks or {})))

local hunk = D.sides(one[1], { context = "hunk" })
local blind = D.sides(one[1], { context = "full" })
ok("full with no source reports degraded", type(blind.degraded) == "string",
  "degraded=" .. tostring(blind.degraded))
ok("degraded names what was missing", (blind.degraded or ""):find("dir=nil", 1, true) ~= nil,
  blind.degraded)
ok("degraded render still equals the hunk render", #blind.before == #hunk.before,
  ("%d vs %d"):format(#blind.before, #hunk.before))

local seeing = D.sides(one[1], {
  context = "full",
  read_file = function(side) return side == "before" and BEFORE or AFTER end,
})
ok("full with a readable source does NOT report degraded", seeing.degraded == nil,
  tostring(seeing.degraded))
ok("full with a readable source renders every line", #seeing.before >= N,
  "#=" .. tostring(#seeing.before))
ok("full render is strictly larger than hunk", #seeing.before > #hunk.before,
  ("%d vs %d"):format(#seeing.before, #hunk.before))

-- ── §2 keys are bound on ALL THREE panes ────────────────────────────
local float = DV.open({
  files = D.parse(two_file_patch),
  read_file = function(side, path)
    if path ~= "wide.lua" then return nil end
    return side == "before" and BEFORE or AFTER
  end,
  context = "hunk",
})
ok("diffview opened", float ~= nil)

local WANT = { "f", "F", "T", "]f", "[f", "X" }
for _, pane in ipairs({ "left", "middle", "preview" }) do
  local b = float:bufnr(pane)
  local have = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do have[m.lhs] = true end
  local missing = {}
  for _, k in ipairs(WANT) do if not have[k] then missing[#missing + 1] = k end end
  ok(("all nav/context keys bound on the %s pane"):format(pane), #missing == 0,
    "missing: " .. table.concat(missing, " "))
end

-- ── §3 the keys FIRE through real dispatch, from every pane ─────────
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

for _, pane in ipairs({ "left", "middle", "preview" }) do
  local w = float:winid(pane)
  vim.api.nvim_set_current_win(w)
  feed("f")
  ok(("f advances the file from the %s pane"):format(pane),
    DV.current_file() and DV.current_file().path == "second.lua",
    DV.current_file() and DV.current_file().path)
  feed("F")
  ok(("F goes back from the %s pane"):format(pane),
    DV.current_file() and DV.current_file().path == "wide.lua",
    DV.current_file() and DV.current_file().path)
end

-- ── §4 T toggles context, and the footer tells the truth ────────────
local st = DV._state_for_tests()
local function foot()
  local fb = float:bufnr("footer") or float:bufnr("foot")
  if not fb then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(fb, 0, -1, false), " ")
end

vim.api.nvim_set_current_win(float:winid("middle"))
local rows_hunk = vim.api.nvim_buf_line_count(float:bufnr("middle"))
feed("T")
ok("T flipped context to full", DV._state_for_tests().context == "full",
  DV._state_for_tests().context)
local rows_full = vim.api.nvim_buf_line_count(float:bufnr("middle"))
ok("T RENDERS full context, not just a label", rows_full > rows_hunk,
  ("full=%d hunk=%d"):format(rows_full, rows_hunk))
ok("footer does not mark it unavailable when it worked",
  foot():find("UNAVAILABLE", 1, true) == nil, foot())
feed("T")
ok("T toggles back to hunk", DV._state_for_tests().context == "hunk",
  DV._state_for_tests().context)

DV.close("test")

print(string.format("%d passed, %d failed", pass, fail))
vim.cmd(fail > 0 and "cq" or "qa!")
