---auto-core.ui.diffview — a three-column diff view with inline annotations.
---
---ADR-0060 §2.5. Composition, not new machinery: `ui.float.multi` supplies the
---three simultaneous panes, `git.diff` supplies the structure, `ui.marks`
---supplies the colouring and the `virt_lines` annotations. It lives in
---auto-core rather than in the consumer because nothing here knows about
---repos, worktrees or reviews — it takes parsed diff files and a list of
---annotations, so a TUI or any other frontend can render the same thing.
---
---    ┌─ files ──┬─ a/foo.lua ──────┬─ b/foo.lua ──────┐
---    │ foo.lua  │  12 │ old line   │  12 │ new line   │
---    │ bar.lua  │     │            │  13 │ added      │
---    └──────────┴──────────────────┴──────────────────┘
---
---The two content panes are titled `a/<path>` and `b/<path>` — git's own
---vocabulary from the `--- a/file` / `+++ b/file` diff header, and the same
---sides the review JSON's LEFT/RIGHT name. "before/after" would have been a
---second vocabulary for a thing git already names.
---
---A panel cannot do this: auto-core's panel model is one docked window with N
---swappable buffers, so three simultaneous columns must be a float.
---@module 'auto-core.ui.diffview'

local multi = require("auto-core.ui.float.multi")
local marks = require("auto-core.ui.marks")
local gitdiff = require("auto-core.git.diff")
local highlights = require("auto-core.ui.highlights")

local M = {}

---MIN_COLUMNS is the width below which this view refuses to open.
---
---`float.multi` degrades by DROPPING the preview pane, which for a diff means
---silently showing only the BEFORE side — worse than not opening, because the
---user would read a half-diff as the whole truth. `panel.lua` already sets the
---precedent of refusing with an explanation, so this does the same (ADR-0060
---§4's stated risk).
M.MIN_COLUMNS = 100

local NAME = "auto-core-diffview"

local _state = nil

---_fmt renders one side column into display lines, keeping a parallel row map.
---Line numbers are shown because a review comment is anchored to one, and a
---reader has to be able to find it.
local function _fmt(column)
  local lines = {}
  for _, e in ipairs(column or {}) do
    if e.kind == "gap" then
      lines[#lines + 1] = "      ⋯"
    elseif e.kind == "pad" then
      -- The absent side of an unequal replacement block (ADR-0060 r1 MF4). A
      -- blank row, deliberately WITHOUT the `│` gutter, so it reads as "nothing
      -- here" opposite the added/removed line rather than an empty file line.
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = string.format("%5s │ %s",
        e.lineno and tostring(e.lineno) or "", e.text or "")
    end
  end
  if #lines == 0 then lines = { "      (no lines on this side)" } end
  return lines
end

---_paint colours a rendered side and lays its annotations over it.
---
---`git.diff.row_for` resolves a comment's 1-based FILE line to a 0-based row —
---the conversion the review-JSON convention deliberately defers to render time
---so the file on disk stays GitHub-uploadable.
local function _paint(bufnr, column, annotations, side)
  local ns = marks.ns("diffview")
  marks.clear(bufnr, ns)
  marks.paint_diff_column(bufnr, ns, column)
  local placed = 0
  for _, a in ipairs(annotations or {}) do
    -- LEFT is the `a/` side, RIGHT the `b/` side — GitHub's names for git's.
    -- A comment with no side defaults to RIGHT, matching GitHub.
    local want = (a.side or "RIGHT") == "LEFT" and "a" or "b"
    if want == side then
      local row = gitdiff.row_for(column, a.line)
      if row then
        -- A RANGE is rendered as a range (ADR-0060 r1 MF5). `line` is
        -- documented as the END of a span, so drawing 128-134 under 134 with no
        -- span and no label made it indistinguishable from a single-line
        -- finding — silently discarding the reviewer's stated scope.
        --
        -- `start_side` defaults to `side`, as GitHub does. A range whose start
        -- lies outside the rendered diff still gets its LABEL, so the scope
        -- survives even when the span itself cannot be drawn.
        local range_label, start_row = nil, nil
        if a.start_line and a.start_line ~= a.line then
          local scol = column
          if a.start_side and a.start_side ~= (a.side or "RIGHT") then
            scol = nil -- a span across both sides cannot be drawn in one pane
          end
          start_row = scol and gitdiff.row_for(scol, a.start_line) or nil
          range_label = ("L%d-%d"):format(
            math.min(a.start_line, a.line), math.max(a.start_line, a.line))
          if start_row and start_row <= row then
            local span_hl = a.resolved and "AutoCoreReviewResolved"
              or (marks.SEVERITY_HL[tostring(a.severity or "comment")]
                  or "AutoCoreReviewFrame")
            -- One mark per covered row: `line` gives the whole row the span
            -- colour, which reads as a block rather than a character range.
            for r = start_row, row do
              marks.line(bufnr, ns, r, span_hl, { priority = 90 })
            end
          end
        end
        marks.annotate(bufnr, ns, row, {
          severity = a.severity, author = a.author or a.reviewer,
          body = a.body, resolved = a.resolved, range = range_label,
        }, { width = 70 })
        placed = placed + 1
      end
      -- A comment whose line is not IN the diff is silently unplaceable; the
      -- caller is told via the return so it can report rather than lose it.
    end
  end
  return placed
end

---_file_rows renders the left column: path plus its +/- counts.
local function _file_rows(files)
  local lines = {}
  for _, f in ipairs(files) do
    local st = gitdiff.stats(f)
    local tag = f.kind == "modified" and "" or (" [" .. f.kind .. "]")
    lines[#lines + 1] = string.format("%s  +%d -%d%s",
      f.path, st.added, st.removed, tag)
  end
  if #lines == 0 then lines = { "(no files)" } end
  return lines
end

---_pane_title retitles a live pane. `float.multi` sets titles at creation, so
---this reaches for nvim_win_set_config; a failure only costs the label.
local function _pane_title(pane, title)
  if not _state then return end
  local win = _state.float:winid(pane)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if not ok or not cfg then return end
  cfg.title, cfg.title_pos = title, cfg.title_pos or "center"
  pcall(vim.api.nvim_win_set_config, win, cfg)
end

---_show renders the file at `idx` into the a/ and b/ panes.
local function _show(idx)
  if not _state then return end
  local f = _state.files[idx]
  if not f then return end
  _state.idx = idx

  -- git's own header vocabulary: `a/<old>` and `b/<new>`, with /dev/null for a
  -- side that does not exist, exactly as `git diff` prints it.
  _pane_title("middle", " " .. (f.old_path and ("a/" .. f.old_path) or "/dev/null") .. " ")
  _pane_title("preview", " " .. (f.new_path and ("b/" .. f.new_path) or "/dev/null") .. " ")

  local before_buf = _state.float:bufnr("middle")   -- the a/ side
  local after_buf = _state.float:bufnr("preview")   -- the b/ side
  local sides = gitdiff.sides(f)
  local anns = (_state.annotations or {})[f.path]
    or (f.new_path and (_state.annotations or {})[f.new_path])
    or (f.old_path and (_state.annotations or {})[f.old_path])
    or {}

  for _, spec in ipairs({
    { buf = before_buf, col = sides.before, side = "a" },
    { buf = after_buf, col = sides.after, side = "b" },
  }) do
    if spec.buf and vim.api.nvim_buf_is_valid(spec.buf) then
      vim.bo[spec.buf].modifiable = true
      vim.api.nvim_buf_set_lines(spec.buf, 0, -1, false, _fmt(spec.col))
      vim.bo[spec.buf].modifiable = false
      _paint(spec.buf, spec.col, anns, spec.side)
    end
  end

  -- Binary files have no sides; say so rather than showing two empty panes.
  if f.binary and before_buf and vim.api.nvim_buf_is_valid(before_buf) then
    vim.bo[before_buf].modifiable = true
    vim.api.nvim_buf_set_lines(before_buf, 0, -1, false,
      { "", "  (binary file — no textual diff)" })
    vim.bo[before_buf].modifiable = false
  end

  -- Mark the selected file in the left pane.
  local left = _state.float:bufnr("left")
  if left and vim.api.nvim_buf_is_valid(left) then
    local ns = marks.ns("diffview-sel")
    marks.clear(left, ns)
    marks.line(left, ns, idx - 1, "AutoCoreSectionActive")
  end
end

---open renders `files` with optional `annotations`.
---@param opts { files: table[], annotations: table<string, table[]>?, title: string?, on_close: function? }
---@return table? handle, string? err
function M.open(opts)
  opts = opts or {}
  local files = opts.files or {}
  if #files == 0 then return nil, "diffview: nothing to show" end
  if vim.o.columns < M.MIN_COLUMNS then
    -- Refuse rather than degrade: dropping the AFTER pane would show half a
    -- diff as if it were the whole one.
    return nil, string.format(
      "diffview: needs at least %d columns (this window has %d)",
      M.MIN_COLUMNS, vim.o.columns)
  end
  highlights.ensure()

  M.close()

  local float = multi.new({
    name = NAME,
    outer = {
      width_pct = 0.94, height_pct = 0.88,
      title = opts.title or " diff ",
    },
    panes = {
      left = { width = 34, title = " Files ", cursorline = true },
      middle = { title = " a/ " },
      preview = { width = 0.5, min_width = 30, min_middle = 30, title = " b/ " },
      footer = { height = 1 },
    },
    initial_focus = "left",
    on_close = function()
      _state = nil
      if opts.on_close then pcall(opts.on_close) end
    end,
  })

  _state = { float = float, files = files, annotations = opts.annotations, idx = 1 }
  float:open()

  local left = float:bufnr("left")
  if left and vim.api.nvim_buf_is_valid(left) then
    vim.bo[left].modifiable = true
    vim.api.nvim_buf_set_lines(left, 0, -1, false, _file_rows(files))
    vim.bo[left].modifiable = false
  end

  local foot = float:bufnr("footer")
  if foot and vim.api.nvim_buf_is_valid(foot) then
    vim.bo[foot].modifiable = true
    vim.api.nvim_buf_set_lines(foot, 0, -1, false, {
      "  j/k file   <Tab> pane   a/ = old, b/ = new   q close",
    })
    vim.bo[foot].modifiable = false
  end

  -- Follow the cursor in the file list, the same wiring autodb's history modal
  -- uses. One autocmd on the left buffer, disposed with the float.
  if left then
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = left,
      callback = function()
        if not _state then return true end
        local win = _state.float:winid("left")
        if not (win and vim.api.nvim_win_is_valid(win)) then return end
        local row = vim.api.nvim_win_get_cursor(win)[1]
        if row ~= _state.idx then _show(row) end
      end,
    })
  end

  -- `<Tab>` cycles panes. `float.multi` has always had the method and never a
  -- default binding, so every consumer had to add it; do it here.
  for _, pane in ipairs({ "left", "middle", "preview" }) do
    local b = float:bufnr(pane)
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.keymap.set, "n", "<Tab>", function()
        if _state then _state.float:cycle("forward") end
      end, { buffer = b, silent = true, nowait = true, desc = "auto-core.diffview: next pane" })
      pcall(vim.keymap.set, "n", "<S-Tab>", function()
        if _state then _state.float:cycle("backward") end
      end, { buffer = b, silent = true, nowait = true, desc = "auto-core.diffview: prev pane" })
    end
  end

  _show(1)
  return float, nil
end

---close disposes the view if it is open. Idempotent.
function M.close()
  if _state and _state.float then pcall(function() _state.float:dispose() end) end
  _state = nil
  pcall(multi.dispose, NAME)
end

---is_open reports whether the view is showing.
---@return boolean
function M.is_open()
  return _state ~= nil and _state.float ~= nil and _state.float:is_open()
end

---_state_for_tests exposes the live state so a suite can assert on pane
---contents without synthesising keypresses.
function M._state_for_tests() return _state end

---unplaced_for reports annotations the rendered diff cannot fully show — a
---comment on an unchanged line, on a file the diff does not carry, or a RANGE
---with an endpoint outside the diff. A caller should surface these rather than
---let feedback vanish.
---
---Three outcomes, because two of them used to be wrong (ADR-0060 r1 MF5). This
---keyed off `a.line` alone, so a range whose START was off-diff was reported as
---fully placed — silent partial loss — while a range whose END was off-diff was
---reported as wholly lost even though its start was renderable.
---
---An entry with `partial = true` IS drawn, but not over its whole span; one
---without it is not drawn at all.
---@param files table[]
---@param annotations table<string, table[]>
---@return table[] unplaced  each { path, line, body, partial: boolean? }
function M.unplaced_for(files, annotations)
  local out = {}
  for path, list in pairs(annotations or {}) do
    local f = gitdiff.find(files, path)
    local sides = f and gitdiff.sides(f) or nil
    for _, a in ipairs(list) do
      -- LEFT -> the a/ side, RIGHT -> the b/ side.
      local col = sides and ((a.side or "RIGHT") == "LEFT" and sides.before or sides.after)
      local end_row = col and gitdiff.row_for(col, a.line) or nil
      local has_range = a.start_line ~= nil and a.start_line ~= a.line
      local start_row
      if has_range and col then
        local scol = col
        if a.start_side and a.start_side ~= (a.side or "RIGHT") then
          scol = (a.start_side == "LEFT") and (sides and sides.before)
            or (sides and sides.after)
        end
        start_row = scol and gitdiff.row_for(scol, a.start_line) or nil
      end

      if not end_row and not (has_range and start_row) then
        -- Neither endpoint is in the diff: nothing of this comment is drawn.
        out[#out + 1] = { path = path, line = a.line, body = a.body }
      elseif has_range and not (end_row and start_row) then
        -- One endpoint renders and the other does not: the comment appears, but
        -- its stated span is not fully shown. Report it as partial.
        out[#out + 1] = { path = path, line = a.line, body = a.body, partial = true }
      end
    end
  end
  return out
end

return M
