-- UI-attached test for auto-core.ui.grid's horizontal header tracking.
--
-- This CANNOT live in tests/smoke.lua: `WinScrolled` only fires when a UI
-- is attached, because with no UI there is no redraw to trigger it.
-- Headless, the event is silently never delivered — which produces a
-- false negative that looks exactly like a passing test.
--
-- Run under a pty:
--   script -qec "nvim --clean -u tests/ui/grid_scroll.lua" /dev/null
-- and read tests/ui/.grid_scroll.out. `make test-ui` wraps both.

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
  local f = io.open(plugin_root .. "/tests/ui/.grid_scroll.out", "w")
  f:write("[ui] auto-core.ui.grid — horizontal header tracking\n" .. table.concat(out, "\n") .. "\n")
  f:close()
  vim.cmd(fail > 0 and "cq!" or "qa!")
end

local grid = require("auto-core.ui").grid

-- Wide model: enough columns that the header must scroll.
local cols, row = {}, {}
for i = 1, 12 do
  cols[i] = string.format("column_%02d", i)
  row[i] = string.format("value_%02d", i)
end
local model = grid.model({ columns = cols, rows = { row, row, row } })

vim.cmd("only")
local win = vim.api.nvim_get_current_win()
-- Narrow the window so the header is far wider than the viewport and a
-- modest cursor move forces a real horizontal scroll.
vim.cmd("vsplit")
vim.cmd("wincmd l")
win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(win, 30)
local view = grid.attach(model, { win = win })

vim.defer_fn(function()
  ok("[ui] a UI is attached (else this whole file is a false negative)",
    #vim.api.nvim_list_uis() > 0, #vim.api.nvim_list_uis())

  local raw = view:header_text()
  local at0 = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
  -- Compare the OPTION VALUE, not nvim_eval_statusline's output: given a
  -- winid, eval fits the result to the window width and inserts `<`
  -- truncation markers, which is a different question from what the view
  -- wrote.
  ok("[ui] header starts unclipped at leftcol 0",
    at0 == grid.render_header(raw, 0), vim.inspect(at0:sub(1, 40)))

  -- Scroll horizontally. The cursor moves, so the row's first cells go
  -- off-screen to the left and the header must follow.
  -- Run the motion IN the target window. `normal!` applies to whatever
  -- window is current, which is not necessarily the one under test.
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal! 100|")
  end)
  vim.cmd("redraw")

  vim.defer_fn(function()
    local leftcol = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
    ok("[ui] the window actually scrolled horizontally", leftcol > 0,
      string.format("leftcol=%d win_width=%d current_win_is_target=%s cursor=%s line_len=%d wrap=%s",
        leftcol,
        vim.api.nvim_win_get_width(win),
        tostring(vim.api.nvim_get_current_win() == win),
        vim.inspect(vim.api.nvim_win_get_cursor(win)),
        #(vim.api.nvim_buf_get_lines(view:buf(), 0, 1, false)[1] or ""),
        tostring(vim.api.nvim_get_option_value("wrap", { win = win, scope = "local" }))))

    local now = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
    ok("[ui] WinScrolled refreshed the header (it changed)", now ~= at0,
      "before=" .. vim.inspect(at0:sub(1, 24)) .. " after=" .. vim.inspect(now:sub(1, 24)))

    -- The contract: the written header is the raw header with exactly
    -- `leftcol` display cells removed — the same shift the text
    -- underneath received — and then escaped.
    local expected = grid.render_header(raw, leftcol)
    ok("[ui] written header == raw header shifted by the window's real leftcol",
      now == expected,
      "leftcol=" .. leftcol .. "\n        written =" .. vim.inspect(now:sub(1, 40))
      .. "\n        expected=" .. vim.inspect(expected:sub(1, 40)))

    -- Alignment is the point of all of this: the header text at the
    -- cursor's screen column must name the column the cursor is in.
    -- Both are measured on the same clipped header, which is what the
    -- viewport shows.
    local cur = view:cell()
    local col_name = model:columns()[cur.col].name
    local clipped = grid.clip_header(raw, leftcol)
    -- wincol() reports the CURRENT window, which need not be the one
    -- under test — the same trap as `normal!` above.
    local screen_col = vim.api.nvim_win_call(win, vim.fn.wincol) -- 1-based; --clean has no gutter
    local under = clipped:sub(screen_col, screen_col + #col_name - 1)
    ok("[ui] the header above the cursor names the cursor's column",
      under == col_name,
      "cell col " .. cur.col .. " (" .. col_name .. ") at wincol " .. screen_col
      .. " but header shows " .. vim.inspect(under)
      .. "\n        clipped=" .. vim.inspect(clipped:sub(1, 40)))

    -- The case CursorMoved cannot see: the VIEWPORT moves while the
    -- cursor stays exactly where it is. (`zH` is not this case — it
    -- nudges the cursor to keep it on screen. Scrolling the viewport
    -- directly, to a leftcol that still contains the cursor, is.)
    local before_scroll = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
    local cursor_before = vim.api.nvim_win_get_cursor(win)
    local target_leftcol = math.max(leftcol - 5, 0)
    vim.api.nvim_win_call(win, function()
      local v = vim.fn.winsaveview()
      v.leftcol = target_leftcol
      vim.fn.winrestview(v)
    end)
    vim.cmd("redraw")

    vim.defer_fn(function()
      local after_scroll = vim.api.nvim_get_option_value("winbar", { win = win, scope = "local" })
      local moved_leftcol = vim.api.nvim_win_call(win,
        function() return vim.fn.winsaveview().leftcol end)
      ok("[ui] the viewport moved with the cursor untouched",
        moved_leftcol ~= leftcol
        and vim.deep_equal(cursor_before, vim.api.nvim_win_get_cursor(win)),
        string.format("leftcol %d -> %d, cursor %s -> %s", leftcol, moved_leftcol,
          vim.inspect(cursor_before), vim.inspect(vim.api.nvim_win_get_cursor(win))))
      ok("[ui] the header tracked it (CursorMoved alone would have missed it)",
        after_scroll ~= before_scroll,
        "before=" .. vim.inspect(before_scroll:sub(1, 24))
        .. " after=" .. vim.inspect(after_scroll:sub(1, 24)))
      ok("[ui] and it is still exactly the raw header shifted by leftcol",
        after_scroll == grid.render_header(raw, moved_leftcol),
        vim.inspect(after_scroll:sub(1, 40)))

      view:dispose()
      ok("[ui] dispose leaves the window alive", vim.api.nvim_win_is_valid(win))
      finish()
    end, 150)
  end, 250)
end, 400)
