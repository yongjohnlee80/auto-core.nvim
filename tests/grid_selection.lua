-- tests/grid_selection.lua — ADR-0066: grid selection mode + content viewer.
--
-- Run:  nvim --headless -u NONE -l tests/grid_selection.lua
--
-- A standalone suite rather than a smoke.lua section, for the same reason
-- adr0060-r1-diff-align.lua is: smoke.lua is the big per-iteration gate and
-- this is a focused contract pin. Wired into tests/run-all.sh.
--
-- The two FLATTENING sections are the ones to read first. ADR-0066 had the
-- same defect found twice, on two different axes: a row-detail view renders
-- one line per column, so EVERY string that becomes part of that line has to
-- be flattened at the boundary. r1 caught unflattened VALUES; r2 caught
-- unflattened COLUMN NAMES one field over. Sections [1] and [2] are the
-- paired positive controls — each is written so that the design which had the
-- other bug still passes the general assertions and fails its own control.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("ADR-0066 — grid selection mode + content viewer\n"); io.stdout:flush()

local grid   = require("auto-core.ui.grid")
local model  = require("auto-core.ui.grid.model")
local viewer = require("auto-core.ui.float.viewer")

local NL, TAB = string.char(10), string.char(9)

---The viewer handle is METHOD-based. Sections that drive it check the shape
---FIRST, because if it ever regresses to bare `buf`/`win` fields then every
---`:buf()` raises "attempt to call a number value" and aborts the suite
---mid-run — real detection, but of the silent-truncation kind. This turns it
---into one legible failure per section with the rest still reported.
---@return boolean ok_to_continue
local function handle_shape_ok(tag)
  local h = viewer({ "probe" })
  local shaped = type(h.buf) == "function" and type(h.win) == "function"
  if shaped then h:close() else pcall(function() h.close() end) end
  ok(tag .. " the viewer handle exposes buf/win as METHODS", shaped)
  if not shaped then
    ok(tag .. " SKIPPING this section — the handle shape is wrong", false)
  end
  return shaped
end

---A fresh window each time, so one section's dispose cannot affect the next.
local function with_grid(m, opts, fn)
  vim.cmd("new")
  local win = vim.api.nvim_get_current_win()
  local view = grid.attach(m, vim.tbl_extend("force", { win = win }, opts or {}))
  local okrun, err = pcall(fn, view, win)
  if not view._disposed then pcall(function() view:dispose() end) end
  pcall(vim.api.nvim_win_close, win, true)
  if not okrun then error(err) end
end

-- ── [1] flattening axis A: the VALUE (criterion 6) ────────────────────
--
-- Rendered through model.row_detail_lines, NOT just inspected as data: the
-- defect is a RENDERER putting a multi-line string on a line-addressed list,
-- so asserting the entry table alone would prove nothing. Each section ends
-- with a BAD RENDERER built the way the rejected design worked, to show these
-- assertions actually observe the bug rather than restating the fix.
;(function()
  local m = model.new({
    columns = { "a", "b", "c" },
    rows = { { "x", "two" .. NL .. "line" .. NL .. "value", "z" } },
  })
  local e = m:row_entries(1)
  ok("[1] one entry per column", #e == 3, e and #e)
  ok("[1] the multiline value keeps its newlines in `value`",
    select(2, e[2].value:gsub(NL, "")) == 2, vim.inspect(e[2].value))
  ok("[1] but `text` — the half that renders — has none",
    not e[2].text:find(NL, 1, true), vim.inspect(e[2].text))

  local lines, map = model.row_detail_lines(e)
  ok("[1] ONE rendered line per column, despite the 3-line value",
    #lines == 3, #lines)
  ok("[1] no rendered line contains a newline",
    not table.concat(lines, ""):find(NL, 1, true))
  ok("[1] line 3 maps to column 3", map[3].col == 3 and map[3].name == "c",
    vim.inspect({ map[3].col, map[3].name }))

  -- The invariant that makes a line lookup safe at all.
  ok("[1] #lines == #map — a lookup cannot resolve past the end",
    #lines == #map, string.format("lines=%d map=%d", #lines, #map))
  -- And it holds even for hand-built entries that reach for the FAITHFUL
  -- halves, because row_detail_lines flattens structurally rather than
  -- trusting its caller. Without that, the buffer gets more lines than the
  -- map has entries and every lookup below the multiline one is wrong.
  local hand = { { col = 1, label = "a", text = "x" },
                 { col = 2, label = "b" .. NL .. "raw", text = "two" .. NL .. "line" },
                 { col = 3, label = "c", text = "z" } }
  local hl_, hm = model.row_detail_lines(hand)
  ok("[1] hand-built entries with raw newlines STILL give one line each",
    #hl_ == 3 and #hm == 3, string.format("lines=%d map=%d", #hl_, #hm))
  ok("[1] and none of those lines contains a newline",
    not table.concat(hl_, ""):find(NL, 1, true), vim.inspect(hl_))

  -- BAD RENDERER — the rejected `column: value` design, using the faithful
  -- halves. This is what the control is for.
  local bad = {}
  for _, entry in ipairs(e) do bad[#bad + 1] = entry.name .. " = " .. tostring(entry.value) end
  local bad_lines = vim.split(table.concat(bad, NL), NL, { plain = true })
  ok("[1] CONTROL — the bad renderer produces 5 lines for 3 columns",
    #bad_lines == 5, #bad_lines)
  ok("[1] CONTROL — so its line 3 is NOT column 3 (the mapping drifts)",
    bad_lines[3] ~= lines[3], vim.inspect(bad_lines[3]))
end)()

-- ── [2] flattening axis B: the COLUMN NAME (criterion 7) ──────────────
--
-- r3 confirmed this is constructible against the live model rather than a
-- theoretical hazard: a quoted DB column name may legally hold a newline, and
-- `normalize_columns` keeps `name` raw for exactly that reason.
;(function()
  local m = model.new({
    columns = { "line" .. NL .. "break", "tab" .. TAB .. "name", "plain" },
    rows = { { "v1", "v2", "v3" } },
  })
  local e = m:row_entries(1)
  ok("[2] raw `name` RETAINS the newline (identity is faithful)",
    e[1].name:find(NL, 1, true) ~= nil, vim.inspect(e[1].name))
  ok("[2] `label` — the half that renders — has no newline",
    not e[1].label:find(NL, 1, true), vim.inspect(e[1].label))
  ok("[2] `label` has no tab either",
    not e[2].label:find(TAB, 1, true), vim.inspect(e[2].label))

  local lines, map = model.row_detail_lines(e)
  ok("[2] ONE rendered line per column, despite the newline in a column NAME",
    #lines == 3, #lines)
  ok("[2] no rendered line contains a newline or a tab",
    not table.concat(lines, ""):find("[" .. NL .. TAB .. "]"))
  ok("[2] line 2 maps to column 2", map[2].col == 2, vim.inspect(map[2].col))
  ok("[2] line 3 maps to column 3", map[3].col == 3 and map[3].label == "plain",
    vim.inspect({ map[3].col, map[3].label }))

  -- BAD RENDERER — revision 2's `{col, name, value}` entry, which flattened
  -- the value and left the column name raw. It passes section [1] and fails
  -- here, which is the whole reason both controls exist.
  local bad = {}
  for _, entry in ipairs(e) do bad[#bad + 1] = entry.name .. " = " .. entry.text end
  local bad_lines = vim.split(table.concat(bad, NL), NL, { plain = true })
  ok("[2] CONTROL — rendering raw `name` yields 4 lines for 3 columns",
    #bad_lines == 4, #bad_lines)
  ok("[2] CONTROL — so the line that should be column 2 is not",
    bad_lines[2] ~= lines[2],
    "bad=" .. vim.inspect(bad_lines[2]) .. " good=" .. vim.inspect(lines[2]))
end)()

-- ── [3] NULL round-trip (criterion 8) ─────────────────────────────────
;(function()
  local m = model.new({ columns = { "a", "b" }, rows = { { nil, "x" } } })
  local e = m:row_entries(1)
  ok("[3] NULL entry is flagged", e[1].null == true)
  ok("[3] NULL DISPLAYS as NULL", e[1].text == "NULL", vim.inspect(e[1].text))
  ok("[3] NULL in CSV is an empty field", m:csv(1):match("^,") ~= nil, m:csv(1))
  ok("[3] NULL in JSON is null", m:json(1):find("null", 1, true) ~= nil, m:json(1))
  with_grid(m, { header = "line" }, function(view)
    vim.api.nvim_win_set_cursor(view:win(), { 2, 0 })
    ok("[3] and `y` on it yields the EMPTY string, not \"NULL\"",
      view:yank_cell() == "", vim.inspect(view:yank_cell()))
  end)
end)()

-- ── [4] mode default, seeding, and rejection (criterion 11) ───────────
;(function()
  local m = model.new({ columns = { "a" }, rows = { { "1" } } })
  with_grid(m, { header = "line" }, function(view)
    ok("[4] default mode is cell", view:selection_mode() == "cell")
    ok("[4] set to row reports a change", view:set_selection_mode("row") == true)
    ok("[4] and takes effect", view:selection_mode() == "row")
    ok("[4] setting the SAME mode is not a change",
      view:set_selection_mode("row") == false)
    ok("[4] an unknown mode is REJECTED, not coerced",
      view:set_selection_mode("banana") == false and view:selection_mode() == "row",
      view:selection_mode())
    ok("[4] toggle flips back", view:toggle_selection_mode() == "cell")
  end)
  with_grid(m, { header = "line", selection_mode = "row" }, function(view)
    ok("[4] opts.selection_mode is honoured at attach", view:selection_mode() == "row")
  end)
  -- attach REJECTS an invalid mode rather than coercing it. The earlier
  -- version silently fell back to `cell` and THIS TEST BLESSED IT — which
  -- contradicted the very rule the boundary exists for: a typo in a
  -- consumer's persisted mode must not quietly become a mode.
  vim.cmd("new")
  local w = vim.api.nvim_get_current_win()
  local threw = not pcall(grid.attach, m, { win = w, header = "line", selection_mode = "nonsense" })
  ok("[4] an invalid opts.selection_mode is REJECTED, not coerced", threw)
  local ok_nil = pcall(function()
    local v = grid.attach(m, { win = w, header = "line", selection_mode = nil })
    ok("[4] nil selection_mode selects the default", v:selection_mode() == "cell")
    v:dispose()
  end)
  ok("[4] and nil is accepted", ok_nil)
  pcall(vim.api.nvim_win_close, w, true)
end)()

-- ── [5] callback semantics (criterion 11) ─────────────────────────────
;(function()
  local m = model.new({ columns = { "a" }, rows = { { "1" } } })
  local seen = {}
  with_grid(m, {
    header = "line", selection_mode = "row",
    on_selection_mode = function(mode) seen[#seen + 1] = mode end,
  }, function(view)
    -- The point: autodb's own persisted value arrives via opts, so echoing
    -- it back out would make attach-order a source of spurious writes.
    ok("[5] no callback during initial attach", #seen == 0, vim.inspect(seen))
    view:set_selection_mode("row")
    ok("[5] no callback for a no-op set", #seen == 0, vim.inspect(seen))
    view:set_selection_mode("cell")
    ok("[5] callback on an effective change", #seen == 1 and seen[1] == "cell", vim.inspect(seen))
    view:set_selection_mode("bogus")
    ok("[5] no callback for a rejected mode", #seen == 1, vim.inspect(seen))
  end)
end)()

-- ── [6] inert where there is no cell (criterion 9) ────────────────────
;(function()
  local rows = model.new({ columns = { "a" }, rows = { { "1" } } })
  with_grid(rows, { header = "line" }, function(view)
    ok("[6] mode applies in the table layout", view:mode_applies() == true)
    view:set_selection_mode("row")
    view:toggle_view()
    ok("[6] JSON layout: cell() is nil", view:cell() == nil)
    ok("[6] JSON layout: mode does NOT apply", view:mode_applies() == false)
    ok("[6] JSON layout: the marker is ABSENT, not merely unlit",
      view:mode_marker() == "", vim.inspect(view:mode_marker()))
    local before = view:selection_mode()
    view:toggle_selection_mode()
    ok("[6] toggling in JSON layout does not change the stored mode",
      view:selection_mode() == before, view:selection_mode())
    view:toggle_view()
    ok("[6] and `J` back RESTORES the mode the reader chose",
      view:selection_mode() == "row", view:selection_mode())
    ok("[6] marker is back too", view:mode_marker() == "[ROW]", view:mode_marker())
  end)
  -- A non-`rows` model has no cells either — wider than JSON mode alone,
  -- which is why the rule is written against cell() rather than against JSON.
  local msg = model.new({ kind = "message", verb = "INSERT", affected = 3 })
  with_grid(msg, { header = "line" }, function(view)
    ok("[6] a message result: cell() is nil", view:cell() == nil)
    ok("[6] a message result: mode does NOT apply", view:mode_applies() == false)
    ok("[6] a message result: marker absent", view:mode_marker() == "")
  end)
end)()

-- ── [7] exactly one highlight, in the view's own namespace (12, 13) ───
;(function()
  local m = model.new({ columns = { "a", "b" }, rows = { { "1", "2" }, { "3", "4" } } })
  with_grid(m, { header = "line" }, function(view, win)
    local buf, ns = view:buf(), view._ns
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    view:_paint_cursor()
    local cell_marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    ok("[7] cell mode paints exactly ONE extmark", #cell_marks == 1, #cell_marks)
    view:set_selection_mode("row")
    local row_marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    ok("[7] row mode also paints exactly ONE — it REPLACES the cell mark",
      #row_marks == 1, #row_marks)
    ok("[7] cursorline stays false while attached (the mode rides extmarks)",
      vim.api.nvim_get_option_value("cursorline", { win = win, scope = "local" }) == false)
  end)
  -- prior cursorline is restored on dispose, mode or no mode
  vim.cmd("new")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("cursorline", true, { win = win, scope = "local" })
  local v = grid.attach(m, { win = win, header = "line", selection_mode = "row" })
  local during = vim.api.nvim_get_option_value("cursorline", { win = win, scope = "local" })
  v:dispose()
  local after = vim.api.nvim_get_option_value("cursorline", { win = win, scope = "local" })
  ok("[7] cursorline off during, and the caller's true RESTORED on dispose",
    during == false and after == true, string.format("during=%s after=%s", during, after))
  pcall(vim.api.nvim_win_close, win, true)
end)()

-- ── [8] `y` is the one mode-dependent key (criterion 3) ───────────────
;(function()
  local m = model.new({ columns = { "a", "b" }, rows = { { "1", "2" } } })
  with_grid(m, { header = "line" }, function(view, win)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    ok("[8] cell mode: y yanks the cell", view:yank_selection() == "1",
      vim.inspect(view:yank_selection()))
    view:set_selection_mode("row")
    ok("[8] row mode: y yanks the row as CSV", view:yank_selection() == "1,2",
      vim.inspect(view:yank_selection()))
    ok("[8] Y is absolute in row mode", view:yank_row("csv") == "1,2")
    ok("[8] gy is absolute in row mode",
      view:yank_row("json"):find('"a"', 1, true) ~= nil, view:yank_row("json"))
    view:set_selection_mode("cell")
    ok("[8] Y is absolute in cell mode too", view:yank_row("csv") == "1,2")
    ok("[8] and the explicit API still means what it says",
      view:yank_cell() == "1", vim.inspect(view:yank_cell()))
  end)
end)()

-- ── [9] inspect reports WHICH thing is selected (§2.4) ────────────────
;(function()
  local m = model.new({ columns = { "a" }, rows = { { "1" } } })
  local got
  with_grid(m, { header = "line", on_inspect = function(_, _, mode) got = mode end },
    function(view, win)
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      view:inspect()
      ok("[9] cell mode inspects a cell", got == "cell", tostring(got))
      view:set_selection_mode("row")
      view:inspect()
      ok("[9] row mode inspects a row", got == "row", tostring(got))
      view:toggle_view()
      got = nil
      view:inspect()
      ok("[9] JSON layout inspects nothing at all", got == nil, tostring(got))
    end)
end)()

-- ── [10] render_winbar composition (§2.5) ─────────────────────────────
;(function()
  local raw = "col_a  col_b"
  ok("[10] no marker → exactly the header", grid.render_winbar(raw, 0, "") ==
    grid.render_header(raw, 0))
  local with = grid.render_winbar(raw, 0, "[ROW]")
  ok("[10] a marker is appended, right-aligned", with:find("%%=") ~= nil, with)
  ok("[10] the header half is untouched by it",
    with:sub(1, #grid.render_header(raw, 0)) == grid.render_header(raw, 0), with)
  ok("[10] an empty header stays empty even with a marker",
    grid.render_winbar("", 0, "[ROW]") == "", vim.inspect(grid.render_winbar("", 0, "[ROW]")))
end)()

-- ── [11] viewer: it is NOT help_overlay (§2.1) ────────────────────────
;(function()
  if not handle_shape_ok("[11]") then return end
  local h = viewer({ "a", "b" })
  local maps = {}
  for _, mp in ipairs(vim.api.nvim_buf_get_keymap(h:buf(), "n")) do maps[mp.lhs] = true end
  ok("[11] <cr> does NOT dismiss the viewer", not maps["<CR>"], vim.inspect(vim.tbl_keys(maps)))
  ok("[11] q does", maps["q"] == true)
  ok("[11] lines are rendered as given, not formatted into key/desc columns",
    vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)[1] == "a")
  -- One calling convention. The handle used to expose `buf`/`win` as bare
  -- numbers alongside dot-closures, which let `h:set_lines({"x"})` pass the
  -- handle itself as `lines` and render a single blank line — silently.
  h:set_lines({ "b", "c" })
  ok("[11] h:set_lines works via `:` and replaces the content",
    vim.deep_equal(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), { "b", "c" }),
    vim.inspect(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)))
  ok("[11] and calling it with `.` is an ERROR, not a silent blank",
    not pcall(function() h.set_lines({ "z" }) end))
  h:close()

  local h2 = viewer("one" .. NL .. "two" .. NL .. "three")
  ok("[11] a multiline string is SPLIT across buffer lines, not an error",
    #vim.api.nvim_buf_get_lines(h2:buf(), 0, -1, false) == 3)
  h2:close()

  -- A lone CR is DATA and must survive; only a terminator splits. An earlier
  -- version stripped every \r and rendered "a\rb" as "ab".
  local CR = string.char(13)
  local h3 = viewer("a" .. CR .. "b")
  local got = vim.api.nvim_buf_get_lines(h3:buf(), 0, -1, false)
  ok("[11] a lone CR is PRESERVED, not deleted",
    #got == 1 and got[1] == "a" .. CR .. "b", vim.inspect(got))
  h3:close()
  local h4 = viewer("a" .. CR .. NL .. "b")
  ok("[11] but CRLF is a terminator, so it splits cleanly",
    vim.deep_equal(vim.api.nvim_buf_get_lines(h4:buf(), 0, -1, false), { "a", "b" }),
    vim.inspect(vim.api.nvim_buf_get_lines(h4:buf(), 0, -1, false)))
  h4:close()

  -- Bad input is REJECTED with a message, not coerced or dropped into an
  -- opaque ipairs failure (`viewer(12345)` used to throw from inside).
  ok("[11] a number is rejected with a clear error", not pcall(viewer, 12345))
  ok("[11] a list containing a non-string is rejected",
    not pcall(viewer, { "a", 7 }))
  ok("[11] a table with no array part is rejected (the accidental-self case)",
    not pcall(viewer, { title = "x", lines = { "y" } }))

  local custom = false
  local h5 = viewer({ "x" }, { keymaps = { ["y"] = function() custom = true end } })
  vim.api.nvim_buf_call(h5:buf(), function() vim.cmd("normal y") end)
  ok("[11] a consumer keymap runs INSIDE the viewer", custom)
  h5:close()
end)()

-- ── [12] viewer lifecycle: child return + parent cascade (15, 16) ─────
--
-- NOTE on the instrument: removing EITHER the WinClosed or the BufWipeout
-- autocmd leaves this section fully green, because the viewer's buffer is
-- `bufhidden = "wipe"` — closing the window implies wiping the buffer, so
-- each autocmd alone already covers this configuration. Removing BOTH drops
-- the three external-close assertions below. They are kept as belt-and-braces
-- for a consumer that passes a different `bufhidden`, NOT because each is
-- separately load-bearing here.
;(function()
  if not handle_shape_ok("[12]") then return end
  local n = 0
  local h = viewer({ "x" }, { on_close = function() n = n + 1 end })
  h:close(); h:close(); h:close()
  ok("[12] on_close fires exactly once however often close is called", n == 1, n)

  local n2 = 0
  local h2 = viewer({ "y" }, { on_close = function() n2 = n2 + 1 end })
  vim.api.nvim_win_close(h2:win(), true)
  ok("[12] on_close fires when the window dies EXTERNALLY", n2 == 1, n2)
  ok("[12] and the handle knows it is closed", not h2:is_open())

  vim.cmd("new")
  local base = vim.api.nvim_get_current_win()
  local h3 = viewer({ "z" }, { opener = base })
  local took = vim.api.nvim_get_current_win() == h3:win()
  h3:close()
  ok("[12] CHILD RETURN — focus goes back to a still-valid opener",
    took and vim.api.nvim_get_current_win() == base)

  -- The cascade, driven the two ways a parent can die.
  for _, how in ipairs({ "handle", "external" }) do
    local pc, cc, child = 0, 0, nil
    local parent = viewer({ "parent" }, { on_close = function()
      pc = pc + 1
      if child then child:close() end
    end })
    child = viewer({ "child" }, { opener = parent:win(), on_close = function() cc = cc + 1 end })
    if how == "handle" then parent:close() else vim.api.nvim_win_close(parent:win(), true) end
    ok("[12] PARENT CASCADE (" .. how .. ") — each on_close exactly once",
      pc == 1 and cc == 1, string.format("parent=%d child=%d", pc, cc))
    ok("[12] PARENT CASCADE (" .. how .. ") — no orphaned child float",
      not child:is_open())
  end
  pcall(vim.api.nvim_win_close, base, true)
end)()

-- ── [13] a 60-column row detail: reachable, scrollable, searchable ───
--
-- Criterion 14, which the first implementation pass shipped WITHOUT a test —
-- I reported "all 17 criteria covered" and this one was not. r3 answered the
-- design question (scroll and search all 60 columns, no pagination) and the
-- implementation review caught the missing fixture.
;(function()
  if not handle_shape_ok("[13]") then return end
  local cols, row = {}, {}
  for i = 1, 60 do
    cols[i] = string.format("col_%02d", i)
    row[i]  = string.format("v%02d", i)
  end
  local m = model.new({ columns = cols, rows = { row } })
  local e = m:row_entries(1)
  ok("[13] all 60 columns become entries", #e == 60, #e)

  local lines, map = model.row_detail_lines(e)
  ok("[13] 60 lines for 60 columns", #lines == 60, #lines)
  ok("[13] and the map covers every one of them", #map == 60, #map)
  ok("[13] the LAST entry is reachable and is column 60",
    map[60] ~= nil and map[60].col == 60 and map[60].label == "col_60",
    vim.inspect(map[60] and { map[60].col, map[60].label }))

  local h = viewer(lines, { title = "row 1" })
  local win, buf = h:win(), h:buf()
  ok("[13] the buffer holds all 60 lines",
    vim.api.nvim_buf_line_count(buf) == 60, vim.api.nvim_buf_line_count(buf))
  -- There must genuinely BE content past the fold, or "scrollable" is vacuous.
  local height = vim.api.nvim_win_get_height(win)
  ok("[13] the window is shorter than the content (so there IS a fold)",
    height < 60, string.format("height=%d lines=60", height))

  -- Search, with the real primitive, for a column BELOW the fold.
  local found = vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    return vim.fn.search("col_57", "W")
  end)
  ok("[13] `/` finds a column name below the fold", found == 57, found)
  ok("[13] and the cursor really moved there",
    vim.api.nvim_win_get_cursor(win)[1] == 57,
    vim.inspect(vim.api.nvim_win_get_cursor(win)))
  ok("[13] the line it landed on is that column's",
    (vim.api.nvim_buf_get_lines(buf, 56, 57, false)[1] or ""):find("col_57", 1, true) == 1)

  -- And scrolling to the very last line works, which is what "no pagination"
  -- has to mean in practice.
  vim.api.nvim_win_set_cursor(win, { 60, 0 })
  ok("[13] the last line is reachable by cursor",
    vim.api.nvim_win_get_cursor(win)[1] == 60)
  h:close()
end)()

-- ── [14] malformed entries fail LOUDLY (impl-review) ─────────────────
--
-- row_detail_lines flattens defensively, but a MISSING half is a different
-- thing from an unflattened one: substituting "" would render a line that
-- looks fine and names no column, so the reader cannot tell what they are
-- looking at.
;(function()
  ok("[14] an entry missing `label` is rejected",
    not pcall(model.row_detail_lines, { { col = 1, text = "x" } }))
  ok("[14] an entry missing `text` is rejected",
    not pcall(model.row_detail_lines, { { col = 1, label = "a" } }))
  ok("[14] a non-table entry is rejected",
    not pcall(model.row_detail_lines, { "not an entry" }))
  ok("[14] a non-string label is rejected",
    not pcall(model.row_detail_lines, { { col = 1, label = 7, text = "x" } }))
  ok("[14] and a well-formed entry still works",
    select(1, model.row_detail_lines({ { col = 1, label = "a", text = "x" } }))[1] == "a = x")
  -- The opener's cursor is left alone by a child's close (the auto-core half
  -- of criterion 15; autodb [17] asserts the row-detail line itself).
  if not handle_shape_ok("[14]") then return end
  vim.cmd("new")
  local base = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "l1", "l2", "l3" })
  vim.api.nvim_win_set_cursor(base, { 3, 0 })
  local child = viewer({ "v" }, { opener = base })
  child:close()
  ok("[14] closing a child restores the opener with its cursor untouched",
    vim.api.nvim_get_current_win() == base
      and vim.api.nvim_win_get_cursor(base)[1] == 3,
    vim.inspect(vim.api.nvim_win_get_cursor(base)))
  pcall(vim.api.nvim_win_close, base, true)
end)()

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
