-- ADR 0195 — auto-core.ui.modal (title + body + select confirm modal).
--
-- Invocation (runner contract, lua-nvim-plugin-development §"runner contract"):
--   nvim --headless -u NONE -l tests/adr0195-ui-modal.lua
-- NEVER `-u <file> -c 'qa!'` (that swallows a mid-run throw and exits 0).
--
-- What this proves (ADR 0195 §2.3 / D3, and the r1/r2 acceptance):
--   * an `irreversible` modal orders its declining answer FIRST and parks the
--     cursor on it, so a bare <CR> fires the DECLINE, never the destructive
--     value — in the native float AND the vim.ui.select fallback;
--   * the affirmative is still reachable by number / mnemonic (positive control);
--   * a `reversible` modal honours a default (positive control);
--   * on_choice(value) / on_cancel fire exactly once;
--   * reversibility is a REQUIRED input and an irreversible modal REQUIRES a
--     cancel item (construction errors otherwise);
--   * the body renders untruncated;
--   * the legacy `ui.float.confirm` contract is unchanged — arbitrary items reach
--     on_choice(value), format_item is forwarded, cancellation is on_choice(nil).
--
-- Falsification (a reversal, not an insertion):
--   * delete the decline-first reorder in modal.prepare  → cell [4] red (bare <CR> deletes)
--   * delete the initial-cursor nvim_win_set_cursor call  → cell [4] red
--   * make on_choice fire for a cancel item as on_cancel   → cells [2]/[4] red
--   * map every float.confirm string to a role in modal    → cells [13]/[15] red

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

io.stdout:write("\n=== ADR 0195 ui.modal ===\n"); io.stdout:flush()

local core  = require("auto-core")
local modal = require("auto-core.ui.modal")
local float = require("auto-core.ui.float")

local function feed(keys)
  local codes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(codes, "x", false)
  vim.wait(20)
end

local function buf_lines(h) return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false) end
local function has_line(lines, s)
  for _, l in ipairs(lines) do if l == s then return true end end
  return false
end
local function line_of(lines, s)
  for i, l in ipairs(lines) do if l == s then return i end end
  return nil
end

-- [1] registration
io.stdout:write("\n[1] registration\n")
ok("require('auto-core').ui.modal.open is a function", type(core.ui.modal) == "table" and type(core.ui.modal.open) == "function")
ok("require('auto-core.ui.modal') is the same module", require("auto-core.ui.modal") == modal)

-- [2] float — reversible, choose by number
io.stdout:write("\n[2] float reversible, choose by number\n")
do
  local got, cancelled = "UNSET", false
  local h = modal.open({
    title = "Proceed?",
    body  = "a readable line of detail",
    items = { { label = "Yes", value = "yes" }, { label = "No", value = "no", role = "cancel" } },
    reversibility = "reversible",
    on_choice = function(v) got = v end,
    on_cancel = function() cancelled = true end,
  })
  local lines = buf_lines(h)
  ok("modal is open", h:is_open())
  ok("body renders in the buffer", has_line(lines, "a readable line of detail"))
  ok("option 1 is rendered", has_line(lines, "1. Yes"))
  ok("option 2 is rendered", has_line(lines, "2. No"))
  feed("2")
  ok("number key selects → on_choice('no')", got == "no", got)
  ok("on_cancel NOT called on a selection", cancelled == false)
  ok("modal closed after selection", not h:is_open())
end

-- [3] float — reversible default focuses; bare <CR> picks it (positive control)
io.stdout:write("\n[3] float reversible default, bare <CR> picks default\n")
do
  local got = "UNSET"
  local h = modal.open({
    title = "Save?",
    items = { { label = "Yes", value = true }, { label = "No", value = false, role = "cancel" } },
    reversibility = "reversible",
    default = true,
    on_choice = function(v) got = v end,
  })
  local cur = vim.api.nvim_win_get_cursor(h:win())[1]
  local lines = buf_lines(h)
  ok("cursor starts on the default option line", cur == line_of(lines, "1. Yes"), cur)
  feed("<CR>")
  ok("bare <CR> picks the default (true)", got == true, tostring(got))
end

-- [4] float — IRREVERSIBLE: decline ordered first, cursor on it, bare <CR> harmless
io.stdout:write("\n[4] float irreversible — bare <CR> is harmless (safety cell)\n")
do
  local got = "UNSET"
  -- Confirm item FIRST in input, and a `default` pointing at it: both must be
  -- overridden by the irreversible policy.
  local h = modal.open({
    title = "Delete review?",
    body  = "big-repo@a1b2c3d.r2.review.json — both files removed, cannot be undone",
    items = {
      { label = "Delete permanently", value = "delete", role = "confirm" },
      { label = "No, keep it",        value = "keep",   role = "cancel" },
    },
    reversibility = "irreversible",
    default = "delete",
    on_choice = function(v) got = v end,
  })
  local lines = buf_lines(h)
  local keep_ln, del_ln = line_of(lines, "1. No, keep it"), line_of(lines, "2. Delete permanently")
  ok("decline is ordered FIRST (1. No, keep it)", keep_ln ~= nil, vim.inspect(lines))
  ok("affirmative is ordered second (2. Delete permanently)", del_ln ~= nil)
  ok("decline before affirmative", keep_ln and del_ln and keep_ln < del_ln)
  ok("cursor starts on the decline line (not the affirmative)",
    vim.api.nvim_win_get_cursor(h:win())[1] == keep_ln)
  feed("<CR>")
  ok("bare <CR> resolves the DECLINE, never 'delete'", got == "keep", tostring(got))
  ok("modal closed", not h:is_open())
end

-- [5] float — irreversible: affirmative reachable by number (positive control)
io.stdout:write("\n[5] float irreversible — affirmative reachable by number\n")
do
  local got = "UNSET"
  local h = modal.open({
    title = "Delete?",
    items = {
      { label = "Delete", value = "delete", role = "confirm" },
      { label = "Cancel", value = "cancel", role = "cancel" },
    },
    reversibility = "irreversible",
    on_choice = function(v) got = v end,
  })
  -- rendered "1. Cancel" / "2. Delete" → number 2 is the affirmative
  feed("2")
  ok("number 2 reaches the affirmative ('delete')", got == "delete", tostring(got))
  ok("closed", not h:is_open())
end

-- [6] float — mnemonic selection
io.stdout:write("\n[6] float mnemonic\n")
do
  local got = "UNSET"
  local h = modal.open({
    items = {
      { label = "Keep",   value = "keep",   role = "cancel" },
      { label = "Replace", value = "replace", role = "confirm", mnemonic = "r" },
    },
    reversibility = "reversible",
    on_choice = function(v) got = v end,
  })
  feed("r")
  ok("mnemonic 'r' selects Replace", got == "replace", tostring(got))
  if h.is_open and h:is_open() then h:close() end
end

-- [7] float — Esc/q cancels → on_cancel once, on_choice never
io.stdout:write("\n[7] float cancel via q\n")
do
  local got, cancels = "UNSET", 0
  local h = modal.open({
    items = { { label = "Yes", value = "yes" }, { label = "No", value = "no", role = "cancel" } },
    reversibility = "reversible",
    on_choice = function(v) got = v end,
    on_cancel = function() cancels = cancels + 1 end,
  })
  feed("q")
  ok("q → on_cancel fired", cancels == 1, cancels)
  ok("q → on_choice NOT fired", got == "UNSET")
  ok("closed after cancel", not h:is_open())
  -- exactly-once: a second close must not re-fire
  if h.close then pcall(function() h:close() end) end
  ok("on_cancel is exactly-once", cancels == 1, cancels)
end

-- [8] irreversible requires a cancel item
io.stdout:write("\n[8] construction guards\n")
do
  local okc = pcall(modal.open, {
    items = { { label = "Delete", value = "d", role = "confirm" } },
    reversibility = "irreversible",
    backend = "select",
  })
  ok("irreversible with no cancel item ERRORS", not okc)
end

-- [9] reversibility is required
do
  local okc = pcall(modal.open, {
    items = { { label = "Yes", value = "y" } },
    backend = "select",
  })
  ok("missing reversibility ERRORS", not okc)
end

-- [10] select fallback — irreversible decline-first ordering + nil-cancel + choice
io.stdout:write("\n[10] select fallback (irreversible)\n")
do
  local orig = vim.ui.select
  local seen_items, cb
  vim.ui.select = function(items, _, on_choice) seen_items = items; cb = on_choice end

  local got, cancels = "UNSET", 0
  modal.open({
    title = "Delete?",
    items = {
      { label = "Delete", value = "delete", role = "confirm" },
      { label = "No",     value = "no",     role = "cancel" },
    },
    reversibility = "irreversible",
    backend = "select",
    on_choice = function(v) got = v end,
    on_cancel = function() cancels = cancels + 1 end,
  })
  ok("fallback lists the decline FIRST (as an item object)",
    seen_items and type(seen_items[1]) == "table" and seen_items[1].label == "No", vim.inspect(seen_items))
  cb(nil)
  ok("cancelled select → on_cancel", cancels == 1)
  ok("cancelled select does NOT choose", got == "UNSET")

  -- second modal to exercise a real choice through the fallback
  local got2 = "UNSET"
  vim.ui.select = function(items, _, on_choice) seen_items = items; cb = on_choice end
  modal.open({
    items = {
      { label = "Delete", value = "delete", role = "confirm" },
      { label = "No",     value = "no",     role = "cancel" },
    },
    reversibility = "irreversible",
    backend = "select",
    on_choice = function(v) got2 = v end,
  })
  cb(seen_items[2]) -- the affirmative object (decline "No" is first)
  ok("choosing the affirmative item → on_choice('delete')", got2 == "delete", tostring(got2))

  vim.ui.select = orig
end

-- [11] select fallback — reversible choice + nil cancel
io.stdout:write("\n[11] select fallback (reversible)\n")
do
  local orig = vim.ui.select
  local seen, cb
  vim.ui.select = function(items, _, on_choice) seen = items; cb = on_choice end
  local got, cancels = "UNSET", 0
  modal.open({
    items = { { label = "Yes", value = "yes" }, { label = "No", value = "no", role = "cancel" } },
    reversibility = "reversible",
    backend = "select",
    on_choice = function(v) got = v end,
    on_cancel = function() cancels = cancels + 1 end,
  })
  cb(seen[1]) -- the "Yes" item object (reversible keeps caller order)
  ok("reversible fallback choice → on_choice('yes')", got == "yes")
  ok("no cancel on a choice", cancels == 0)
  vim.ui.select = orig
end

-- [12] body renders untruncated (the whole point vs a single-line prompt)
io.stdout:write("\n[12] body renders untruncated\n")
do
  local longname = "some-very-long-owner__some-very-long-repo-name@0123abcd.r12.review.json"
  local h = modal.open({
    title = "Archive?",
    body  = longname,
    items = { { label = "Archive", value = "a" }, { label = "Cancel", value = "c", role = "cancel" } },
    reversibility = "reversible",
  })
  ok("the full long name is in the buffer, untruncated", has_line(buf_lines(h), longname))
  if h.close then pcall(function() h:close() end) end
end

-- [13][14][15] legacy ui.float.confirm contract is UNCHANGED (r2)
io.stdout:write("\n[13] legacy float.confirm — arbitrary items + format_item + nil-cancel\n")
do
  local orig = vim.ui.select
  local seen_items, seen_fmt, cb
  vim.ui.select = function(items, o, on_choice) seen_items = items; seen_fmt = o.format_item; cb = on_choice end

  -- three-way arbitrary items → the raw value reaches on_choice
  local got = "UNSET"
  float.confirm("Pick action:", {
    items = { "save", "discard", "abort" },
    format_item = function(x) return "» " .. x end,
    on_choice = function(c) got = c end,
  })
  ok("[13] arbitrary items are passed through", seen_items and #seen_items == 3 and seen_items[3] == "abort")
  ok("[14] format_item is forwarded", type(seen_fmt) == "function" and seen_fmt("abort") == "» abort")
  cb("abort")
  ok("[13] on_choice receives the raw selected value ('abort')", got == "abort", tostring(got))

  -- cancellation is on_choice(nil), NOT a separate callback
  local nilseen = "UNSET"
  vim.ui.select = function(_, _, on_choice) cb = on_choice end
  float.confirm("Delete?", { on_choice = function(c) nilseen = c end })
  cb(nil)
  ok("[15] cancellation delivers on_choice(nil)", nilseen == nil)

  vim.ui.select = orig
end

-- [16] P0 — a caller mnemonic must NOT be able to overwrite a structural key
io.stdout:write("\n[16] P0 — reserved-key mnemonic collisions refused at construction\n")
do
  local orig = vim.ui.select
  vim.ui.select = function() end -- keep any accepted positive-control off the real UI
  local function try(mn)
    return pcall(modal.open, {
      items = {
        { label = "Delete", value = "delete", role = "confirm", mnemonic = mn },
        { label = "Keep",   value = "keep",   role = "cancel" },
      },
      reversibility = "irreversible", backend = "select",
    })
  end
  ok("mnemonic '<CR>' refused (would overwrite the safety Enter)", not try("<CR>"))
  ok("mnemonic '<cr>' (lowercase) refused too", not try("<cr>"))
  ok("mnemonic '1' refused (a number-select key)", not try("1"))
  ok("mnemonic 'q' refused (a close key)", not try("q"))
  ok("mnemonic '<Esc>' refused (a close key)", not try("<Esc>"))
  ok("duplicate mnemonic refused", not pcall(modal.open, {
    items = {
      { label = "A", value = "a", role = "cancel",  mnemonic = "x" },
      { label = "B", value = "b", role = "confirm", mnemonic = "x" },
    },
    reversibility = "reversible", backend = "select",
  }))
  ok("a non-colliding mnemonic is still accepted", (pcall(modal.open, {
    items = {
      { label = "Keep",    value = "k", role = "cancel" },
      { label = "Replace", value = "r", role = "confirm", mnemonic = "r" },
    },
    reversibility = "reversible", backend = "select",
  })))
  vim.ui.select = orig
end

-- [17] P1 — fallback keeps item identity under duplicate labels
io.stdout:write("\n[17] P1 — fallback keeps item identity under duplicate labels\n")
do
  local orig = vim.ui.select
  local seen, cb
  vim.ui.select = function(items, _, on_choice) seen = items; cb = on_choice end
  local got = "UNSET"
  modal.open({
    items = {
      { label = "Review", value = "decline", role = "cancel" },
      { label = "Review", value = "affirm",  role = "confirm" }, -- SAME label
    },
    reversibility = "irreversible",
    backend = "select",
    on_choice = function(v) got = v end,
  })
  ok("[17] fallback receives item OBJECTS, decline first", type(seen[1]) == "table" and seen[1].value == "decline")
  cb(seen[1]) -- pick the first displayed row (the decline)
  ok("[17] first row resolves the DECLINE, not the duplicate-labelled affirmative", got == "decline", tostring(got))
  vim.ui.select = orig
end

-- [18] P1 — multiline body keeps the option-row map correct
io.stdout:write("\n[18] P1 — multiline body keeps the option-row map correct\n")
do
  local got = "UNSET"
  local h = modal.open({
    title = "Delete?",
    body  = "line one of detail\nline two of detail",
    items = {
      { label = "Delete", value = "delete", role = "confirm" },
      { label = "No",     value = "no",     role = "cancel" },
    },
    reversibility = "irreversible",
    on_choice = function(v) got = v end,
  })
  local lines = buf_lines(h)
  ok("[18] body line 1 is its own rendered row", has_line(lines, "line one of detail"))
  ok("[18] body line 2 is its own rendered row", has_line(lines, "line two of detail"))
  ok("[18] cursor is on the decline row despite the multiline body",
    vim.api.nvim_win_get_cursor(h:win())[1] == line_of(lines, "1. No"),
    vim.api.nvim_win_get_cursor(h:win())[1])
  feed("<CR>")
  ok("[18] bare <CR> still resolves the decline with a multiline body", got == "no", tostring(got))
end

-- [19] P1 — the primitive owns focus restoration to the invoking window
io.stdout:write("\n[19] P1 — focus returns to the invoking window\n")
do
  vim.cmd("new") -- a second window, so a focus move is observable
  local invoking = vim.api.nvim_get_current_win()
  local got = "UNSET"
  modal.open({ -- no `opener` → it must be captured
    items = { { label = "Yes", value = "y" }, { label = "No", value = "n", role = "cancel" } },
    reversibility = "reversible",
    on_choice = function(v) got = v end,
  })
  ok("[19] the modal took focus (a float window)", vim.api.nvim_get_current_win() ~= invoking)
  feed("q")
  ok("[19] focus restored to the invoking window after cancel",
    vim.api.nvim_get_current_win() == invoking, vim.api.nvim_get_current_win())
  pcall(vim.cmd, "close")
end

-- [20] P2 — enum validation
io.stdout:write("\n[20] P2 — role/backend enums validated\n")
do
  ok("unknown role refused", not pcall(modal.open, {
    items = { { label = "A", value = 1, role = "maybe" } },
    reversibility = "reversible", backend = "select",
  }))
  ok("unknown backend refused", not pcall(modal.open, {
    items = { { label = "A", value = 1 }, { label = "B", value = 2, role = "cancel" } },
    reversibility = "reversible", backend = "bogus",
  }))
end

-- [21] P2 — a REAL float-open failure falls back to select with no orphan buffer
io.stdout:write("\n[21] P2 — auto backend falls back on a real float failure, no orphan buffer\n")
do
  local orig_open, orig_sel = vim.api.nvim_open_win, vim.ui.select
  local sel_called = false
  vim.ui.select = function() sel_called = true end
  local before = #vim.api.nvim_list_bufs()
  vim.api.nvim_open_win = function() error("forced float-open failure") end
  local okc = pcall(modal.open, {
    title = "Delete?",
    body  = "target.review.json",
    items = { { label = "Delete", value = "d", role = "confirm" }, { label = "No", value = "n", role = "cancel" } },
    reversibility = "irreversible",
    backend = "auto",
  })
  vim.api.nvim_open_win = orig_open
  local after = #vim.api.nvim_list_bufs()
  ok("[21] auto backend did not throw when the float failed", okc)
  ok("[21] it fell back to vim.ui.select", sel_called)
  ok("[21] no orphan scratch buffer leaked", after == before, ("before=%d after=%d"):format(before, after))
  vim.ui.select = orig_sel
end

-- assertion floor (runner contract §5): a silently-skipped block must not pass quietly
ok("assertion floor reached (>= 55)", (pass + fail) >= 55, pass + fail)

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail)); io.stdout:flush()
vim.cmd(fail > 0 and "cq!" or "qa!")
