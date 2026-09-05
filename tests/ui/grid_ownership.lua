-- UI-attached test: a grid view must stop touching its window the moment
-- another component owns the display — BEFORE dispose, not at dispose.
--
-- This needs a real UI because the failure rides on WinScrolled, which
-- never fires headlessly. The view's scroll/resize autocmds are GLOBAL
-- (a scroll in any window fires them), so without an ownership guard the
-- view keeps writing its winbar into whatever replaced it.
--
-- Run:  tests/ui/run.sh grid_ownership

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
  local f = io.open(plugin_root .. "/tests/ui/.grid_ownership.out", "w")
  f:write("[ui] auto-core.ui.grid — window ownership under real events\n"
    .. table.concat(out, "\n") .. "\n")
  f:close()
  vim.cmd(fail > 0 and "cq!" or "qa!")
end

local grid = require("auto-core.ui").grid

local cols, row = {}, {}
for i = 1, 12 do
  cols[i] = string.format("column_%02d", i)
  row[i] = string.format("value_%02d", i)
end
local model = grid.model({ columns = cols, rows = { row, row, row } })

vim.cmd("silent! only")
vim.cmd("vsplit")
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(win, 30)
local view = grid.attach(model, { win = win })

vim.defer_fn(function()
  ok("[ui] a UI is attached", #vim.api.nvim_list_uis() > 0)
  ok("[ui] the view owns its window to begin with", view:owns_window() == true)

  -- A third party takes the window: exactly what auto-finder's layout
  -- does when it repurposes a companion window.
  local intruder = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(intruder, 0, -1, false, { string.rep("z", 400) })
  vim.api.nvim_win_set_buf(win, intruder)
  vim.api.nvim_set_option_value("winbar", "THEIR-HEADER", { win = win, scope = "local" })
  vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })

  ok("[ui] ownership ends at the swap", view:owns_window() == false)

  -- Now drive a REAL horizontal scroll in that window. The view's global
  -- WinScrolled handler fires; it must not write into someone else's view.
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal! 200|")
  end)
  vim.cmd("redraw")

  vim.defer_fn(function()
    local leftcol = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
    ok("[ui] the window really scrolled (so WinScrolled really fired)", leftcol > 0, leftcol)

    local wb = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
    ok("[ui] the grid did NOT write its header into the replacement view",
      wb == "THEIR-HEADER", vim.inspect(wb))
    ok("[ui] losing the window disposed the view", view:disposed() == true)
    ok("[ui] the intruder's buffer is still displayed",
      vim.api.nvim_win_get_buf(win) == intruder)

    finish()
  end, 250)
end, 400)
