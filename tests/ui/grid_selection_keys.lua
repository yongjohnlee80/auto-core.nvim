-- UI-attached test for ADR-0066 criterion 17: the selection mode's keys are
-- REAL keymaps, and they do not shadow native motion.
--
-- This cannot be done by calling the handlers: calling `view:toggle_selection_mode()`
-- passes whether or not `s` is bound to it, and the interesting failure is a
-- key that is bound where it should not be — the grid claiming `f`, or a count,
-- or `/` — which no handler-level test can see. So every key here is FED to
-- Neovim and the assertion is made on the resulting cursor/mode.
--
-- r3 confirmed this shape is reachable in the pty harness (nvim_input/feedkeys
-- plus waits, asserting the real cursor/cell/mode afterwards).
--
-- Run under a pty:
--   script -qec "nvim --clean -u tests/ui/grid_selection_keys.lua" /dev/null
-- and read tests/ui/.grid_selection_keys.out. tests/ui/run.sh wraps both.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
vim.opt.rtp:prepend(plugin_root)

local out, pass, fail = {}, 0, 0
local function ok(name, cond, detail)
  if cond then
    pass = pass + 1
    out[#out + 1] = "  PASS  " .. name
  else
    fail = fail + 1
    out[#out + 1] = "  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or "")
  end
end

local function finish()
  out[#out + 1] = string.format("\n%d passed, %d failed", pass, fail)
  local f = io.open(plugin_root .. "/tests/ui/.grid_selection_keys.out", "w")
  f:write("[ui] ADR-0066 — selection mode keys vs native motion\n"
    .. table.concat(out, "\n") .. "\n")
  f:close()
  vim.cmd(fail > 0 and "cq!" or "qa!")
end

---Run `fn` once a UI has actually attached, polling rather than guessing a
---delay. A fixed `defer_fn(…, 400)` is load-sensitive: under a busy machine
---the callback fires before the pty's UI is up, every redraw-dependent
---assertion fails at once, and the run looks like a pile of regressions
---instead of a harness that started too early. Observed while control-testing
---this very file. If the UI never arrives, say THAT and nothing else — a
---missing UI invalidates the suite rather than failing it.
local function when_ui_ready(fn)
  local waited, step, limit = 0, 25, 5000
  local timer = vim.uv.new_timer()
  timer:start(0, step, vim.schedule_wrap(function()
    if #vim.api.nvim_list_uis() > 0 then
      timer:stop(); timer:close()
      return fn()
    end
    waited = waited + step
    if waited >= limit then
      timer:stop(); timer:close()
      out[#out + 1] = "  FAIL  [ui] no UI attached within "
        .. limit .. "ms — this suite cannot assert anything"
      fail = fail + 1
      return finish()
    end
  end))
end

---Feed keys as if typed, then let Neovim process them.
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local grid = require("auto-core.ui").grid

local model = grid.model({
  columns = { "alpha", "bravo", "charlie", "delta" },
  rows = {
    { "a1", "b1", "c1", "needle" },
    { "a2", "b2", "c2", "d2" },
    { "a3", "b3", "c3", "d3" },
    { "a4", "b4", "c4", "d4" },
  },
})

vim.cmd("only")
local win = vim.api.nvim_get_current_win()
local view = grid.attach(model, { win = win })

when_ui_ready(function()
  ok("[ui] a UI is attached (else this whole file is a false negative)",
    #vim.api.nvim_list_uis() > 0, #vim.api.nvim_list_uis())

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  -- ── `s` is really bound, and really toggles ──
  ok("[ui] starts in cell mode", view:selection_mode() == "cell")
  press("s")
  ok("[ui] pressing `s` toggles to row mode", view:selection_mode() == "row",
    view:selection_mode())
  press("s")
  ok("[ui] and back to cell", view:selection_mode() == "cell", view:selection_mode())

  -- ── native `/` still searches, in BOTH modes ──
  for _, mode in ipairs({ "cell", "row" }) do
    view:set_selection_mode(mode)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    press("/needle\r")
    local pos = vim.api.nvim_win_get_cursor(win)
    local line = vim.api.nvim_buf_get_lines(view:buf(), pos[1] - 1, pos[1], false)[1] or ""
    ok("[ui] `/` searches in " .. mode .. " mode",
      line:find("needle", 1, true) ~= nil and pos[2] > 0,
      string.format("mode=%s pos=%s line=%q", mode, vim.inspect(pos), line))
  end

  -- ── native counts still count, in BOTH modes ──
  for _, mode in ipairs({ "cell", "row" }) do
    view:set_selection_mode(mode)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    press("2j")
    ok("[ui] `2j` moves two lines in " .. mode .. " mode",
      vim.api.nvim_win_get_cursor(win)[1] == 3,
      string.format("mode=%s row=%d", mode, vim.api.nvim_win_get_cursor(win)[1]))
  end

  -- ── native `f` still finds, in BOTH modes ──
  for _, mode in ipairs({ "cell", "row" }) do
    view:set_selection_mode(mode)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    local before = vim.api.nvim_win_get_cursor(win)[2]
    press("fb")
    local after = vim.api.nvim_win_get_cursor(win)[2]
    local ch = (vim.api.nvim_get_current_line() or ""):sub(after + 1, after + 1)
    ok("[ui] `fb` moves to a `b` in " .. mode .. " mode",
      after > before and ch == "b",
      string.format("mode=%s %d -> %d char=%q", mode, before, after, ch))
  end

  -- ── the cell stays DERIVED from the cursor in row mode ──
  -- Row mode changes what `y`/`<CR>` act on; it must not stop tracking the
  -- column under the cursor, because that is what a drill-down uses.
  view:set_selection_mode("row")
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local first = view:cell()
  press("fb")
  local moved = view:cell()
  ok("[ui] row mode still tracks the column under the cursor",
    first and moved and moved.col > first.col,
    string.format("col %s -> %s", first and first.col, moved and moved.col))

  -- ── exactly one highlight, whichever mode ──
  local marks = vim.api.nvim_buf_get_extmarks(view:buf(), view._ns, 0, -1, {})
  ok("[ui] row mode paints exactly one extmark", #marks == 1, #marks)
  view:set_selection_mode("cell")
  marks = vim.api.nvim_buf_get_extmarks(view:buf(), view._ns, 0, -1, {})
  ok("[ui] cell mode paints exactly one extmark", #marks == 1, #marks)

  -- ── the winbar really carries the marker (needs a UI to be written) ──
  view:set_selection_mode("row")
  local wb = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
  ok("[ui] the winbar shows the ROW marker", wb:find("[ROW]", 1, true) ~= nil,
    vim.inspect(wb:sub(-40)))
  view:toggle_view()
  wb = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
  ok("[ui] and it is ABSENT in the JSON layout, not merely unlit",
    wb:find("[ROW]", 1, true) == nil and wb:find("[CELL]", 1, true) == nil,
    vim.inspect(wb))

  view:dispose()
  ok("[ui] dispose leaves the window alive", vim.api.nvim_win_is_valid(win))
  finish()
end)
