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
---
---AUTHORING (ADR-0065). `opts.annotate` turns the view from read-only into a
---place a reader can originate an anchored annotation. The surface is
---deliberately GENERIC: it speaks of annotations, severities, rows and sides,
---and knows nothing about reviews, repos, commits or files on disk. The
---consumer owns the draft and the persistence — which is also what makes the
---float safe to close, since work the float never held is work it cannot
---destroy.
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

---SEVERITIES is the normative order for the composer's picker.
---
---NOT derived from `marks.SEVERITY_HL`, which is a hash: `pairs()` would give
---the user a different order on different runs. The values match the review
---ladder the painter already colours; the ORDER is this list.
M.SEVERITIES = { "must-fix", "should-fix", "nit", "question" }

local _state = nil

---_fmt renders one side column into display lines, keeping a parallel row map.
---Line numbers are shown because a review comment is anchored to one, and a
---reader has to be able to find it.
local function _fmt(column)
  local lines = {}
  for _, e in ipairs(column or {}) do
    if e.kind == "gap" then
      lines[#lines + 1] = "⋯"
    elseif e.kind == "pad" then
      -- The absent side of an unequal replacement block (ADR-0060 r1 MF4). A
      -- genuinely EMPTY line, so it reads as "nothing here" opposite the
      -- added/removed line — and so it does not perturb the treesitter parse.
      lines[#lines + 1] = ""
    else
      -- PURE FILE TEXT (ADR-0065 §2.9). The line number used to live here, in
      -- the buffer, as a `%5s │ ` prefix — which is why treesitter could not be
      -- switched on: it would have parsed the gutter as code. Numbers now come
      -- from `statuscolumn`, which is where Neovim already puts gutters.
      lines[#lines + 1] = e.text or ""
    end
  end
  if #lines == 0 then lines = { "(no lines on this side)" } end
  return lines
end

-- Row maps, keyed by BUFFER. The two content buffers are reused as the
-- selected file changes, so the gutter has to be re-derived on every `_show`
-- or it shows the previous file's numbering.
M._rowmap = {}

---statuscolumn resolves the FILE line for the row being drawn.
---
---Two things make this more than `%l`. Buffer row *n* is NOT file line *n* —
---the column carries `gap` and `pad` rows that hold no file line at all — so a
---plain `%l` would print synthetic buffer numbers beside real code. And the
---lookup MUST use the window being drawn (`vim.g.statusline_winid`), not the
---current buffer: both content panes are redrawn while the FILES pane holds
---focus, so a current-buffer lookup would render every pane's gutter from the
---focused buffer's map.
---@return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local buf = win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) or nil
  local map = buf and M._rowmap[buf]
  local n = map and map[vim.v.lnum]
  -- EXACTLY empty for a row that carries no file line (ADR-0065 §2.9,
  -- criterion 16). A padded blank would still draw the separator, which reads
  -- as "a line whose number we could not determine" rather than "not a line" —
  -- and a gap/pad row is not a line at all.
  if not n then return "" end
  return string.format("%5d │ ", n)
end

---_apply_filetype sets the buffer's filetype from the path this SIDE shows and
---restarts the parser.
---
---Per side, because a rename can change the extension: the `a/` side may be a
---`.lua` file while `b/` is `.go`. Per switch, because the two scratch buffers
---are reused — leaving the old parser attached would highlight the new file
---with the previous file's grammar.
local function _apply_filetype(bufnr, path)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  local ft
  if path then
    local ok, m = pcall(vim.filetype.match, { filename = path })
    if ok then ft = m end
  end
  -- Stop before the filetype changes, start after — the two calls the suite
  -- observes by wrapping `vim.treesitter` itself.
  --
  -- There is deliberately no counter here. An earlier version kept one so a
  -- test could assert the calls happened, but a number this module increments
  -- records what it INTENDED, not what it invoked: with `treesitter.start`
  -- stubbed to a no-op the counter still advanced and the assertion still
  -- passed. Wrapping the real function is the only version that fails when the
  -- call goes missing, which leaves nothing for production code to carry.
  pcall(vim.treesitter.stop, bufnr)
  vim.bo[bufnr].filetype = ft or ""
  if ft and ft ~= "" then
    -- A missing parser is the common case, not an error: degrade to unhighlighted
    -- text rather than surfacing a stack trace over a diff.
    pcall(vim.treesitter.start, bufnr, ft)
  end
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
            -- The span is drawn in the SIGN COLUMN, not as a line highlight
            -- (ADR-0060 r2 SF2). A `line_hl_group` span competed with
            -- `paint_diff_column`'s own line highlight on the same attribute,
            -- and at priority 90 against its default 100 the diff won — so the
            -- span vanished on exactly the added/deleted rows a reviewer most
            -- needs marked. Raising the priority instead would have inverted
            -- the loss: added/deleted rows inside a range would stop looking
            -- added or deleted, which is information the reviewer needs just as
            -- much. `sign_text`/`sign_hl_group` is a DIFFERENT attribute, so
            -- both signals coexist and neither can be overridden at any
            -- priority — a severity-coloured rail down the flagged rows beside
            -- the untouched diff colouring.
            --
            -- Pad rows are skipped deliberately: they are the blank filler
            -- opposite an unequal replacement block, and marking "nothing here"
            -- as part of a reviewer's span would be a claim about absent code.
            for r = start_row, row do
              local entry = column[r + 1]
              if not (entry and entry.kind == "pad") then
                marks.gutter(bufnr, ns, r, "▎", span_hl)
              end
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

  -- Pending (unsaved) annotations are the CONSUMER's, fetched fresh on every
  -- render rather than mirrored here: the draft has exactly one owner, and a
  -- copy in the view would be a second one that could disagree.
  --
  -- They paint through the same path stored ones do, so what you see before
  -- submitting is what the file will render after. `author = "pending"` is what
  -- distinguishes them — `marks.annotate` already prints the author in the
  -- block header, so this needs no change there.
  local pending = M._pending_for(f)
  if #pending > 0 then
    local merged = {}
    for _, a in ipairs(anns) do merged[#merged + 1] = a end
    for _, a in ipairs(pending) do merged[#merged + 1] = a end
    anns = merged
  end

  for _, spec in ipairs({
    { buf = before_buf, col = sides.before, side = "a" },
    { buf = after_buf, col = sides.after, side = "b" },
  }) do
    if spec.buf and vim.api.nvim_buf_is_valid(spec.buf) then
      vim.bo[spec.buf].modifiable = true
      vim.api.nvim_buf_set_lines(spec.buf, 0, -1, false, _fmt(spec.col))
      vim.bo[spec.buf].modifiable = false

      -- Rebuild this buffer's gutter map for the file now shown. 1-based, to
      -- match `v:lnum`; rows with no file line are simply absent.
      local map = {}
      for i, e in ipairs(spec.col or {}) do
        if e.lineno then map[i] = e.lineno end
      end
      M._rowmap[spec.buf] = map

      _apply_filetype(spec.buf, spec.side == "a" and f.old_path or (f.new_path or f.path))
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

---_pending_for returns the consumer's unsaved annotations for one file,
---tagged so the painter can tell them from stored ones.
---@param f table  a parsed diff file
---@return table[]
function M._pending_for(f)
  local a = _state and _state.annotate
  if not (a and type(a.pending) == "function") then return {} end
  local ok, list = pcall(a.pending)
  if not (ok and type(list) == "table") then return {} end
  local out = {}
  for _, e in ipairs(list) do
    if type(e) == "table" and (e.path == f.path or e.path == f.new_path or e.path == f.old_path) then
      local copy = vim.deepcopy(e)
      copy.author = "pending"
      out[#out + 1] = copy
    end
  end
  return out
end

---_side_for maps the focused pane onto a diff column and a GitHub side.
---
---`middle` is the `a/` column and `preview` the `b/` one — the same two names
---the pane titles use, so there is no second vocabulary to keep in step.
---@return table? column, string? side, string? reason
local function _side_for(pane)
  if not _state then return nil, nil, "no view" end
  local f = _state.files[_state.idx]
  if not f then return nil, nil, "no file" end
  local sides = gitdiff.sides(f)
  if pane == "middle" then return sides.before, "LEFT", nil end
  if pane == "preview" then return sides.after, "RIGHT", nil end
  return nil, nil, "put the cursor in a content pane to annotate a line"
end

---_focused_pane names the pane the cursor is in.
---@return string?
local function _focused_pane()
  if not _state then return nil end
  local win = vim.api.nvim_get_current_win()
  for _, name in ipairs({ "middle", "preview", "left" }) do
    if _state.float:winid(name) == win then return name end
  end
  return nil
end

---_anchor_here resolves the cursor (or a visual selection) to an anchor.
---
---`path` is ALWAYS `f.path`, on both sides. `f.path` is the new path when the
---file has one, it is what the renderer looks up first, and it is what GitHub
---expects even for a LEFT-side comment — so anchoring a rename's LEFT comment
---to `old_path` would render only through a fallback and upload to the wrong
---file.
---@param visual boolean?  true when invoked from a VISUAL-mode mapping
---@return table? anchor, string? reason
local function _anchor_here(visual)
  local pane = _focused_pane()
  local column, side, reason = _side_for(pane)
  if not column then return nil, reason end
  local f = _state.files[_state.idx]
  local win = _state.float:winid(pane)
  if not (win and vim.api.nvim_win_is_valid(win)) then return nil, "pane is gone" end

  local cursor = vim.api.nvim_win_get_cursor(win)[1]

  -- Whether this is a RANGE is decided by which mapping fired, never by
  -- inspecting the '< and '> marks.
  --
  -- Those marks are ambient: they hold the LAST visual selection made anywhere
  -- in the session and survive leaving visual mode entirely. Deriving intent
  -- from them meant a plain `c` in normal mode, with the cursor merely sitting
  -- inside a selection made minutes earlier, silently produced a multi-line
  -- range the user never asked for — observed as start_line=10,line=12 from a
  -- single-row cursor. The visual mapping passes `visual = true`; nothing else
  -- can.
  if visual then
    -- `v` is the other end of the LIVE selection, and `.` the cursor. Read
    -- while still in visual mode, so this is the selection on screen rather
    -- than a remembered one.
    local vpos = vim.fn.getpos("v")[2]
    local first, last = math.min(vpos, cursor), math.max(vpos, cursor)
    if first == last then
      local lineno, aerr = gitdiff.anchor(column, first - 1)
      if not lineno then return nil, aerr end
      return { path = f.path, side = side, line = lineno }
    end
    local span, rerr = gitdiff.range(column, first - 1, last - 1)
    if not span then return nil, rerr end
    return {
      path = f.path, side = side, start_side = side,
      start_line = span.start_line, line = span.line,
    }
  end

  local lineno, aerr = gitdiff.anchor(column, cursor - 1)
  if not lineno then return nil, aerr end
  return { path = f.path, side = side, line = lineno }
end

---COMPOSE_KEYS is what the composer advertises, in the same `key desc` shape
---`_render_footer` uses for the view itself.
local COMPOSE_KEYS = { { "<C-s>", "post" }, { "q / <Esc>", "cancel" } }

---_compose_footer renders COMPOSE_KEYS as border-footer chunks, or nil when the
---box is too narrow to carry them.
---
---Neovim ACCEPTS a footer wider than its window (verified — it does not error),
---so an oversized one is not refused, it is clipped: the tail goes, and the
---tail is the cancel key. At every width this view can open at the hints fit —
---`M.MIN_COLUMNS` is 100 and the box takes 62 columns of it at the narrowest —
---so this check exists to degrade gracefully if that floor ever drops, rather
---than to draw half a footer.
local function _compose_footer(width)
  local chunks, plain = { { " ", "AutoCoreFloatBorder" } }, " "
  for i, pair in ipairs(COMPOSE_KEYS) do
    if i > 1 then
      chunks[#chunks + 1] = { "   ", "AutoCoreHelpDesc" }
      plain = plain .. "   "
    end
    chunks[#chunks + 1] = { pair[1], "AutoCoreHelpKey" }
    chunks[#chunks + 1] = { " " .. pair[2], "AutoCoreHelpDesc" }
    plain = plain .. pair[1] .. " " .. pair[2]
  end
  chunks[#chunks + 1] = { " ", "AutoCoreFloatBorder" }
  plain = plain .. " "
  if vim.fn.strdisplaywidth(plain) > width then return nil end
  return chunks
end

---_compose asks for a severity and a body, then hands the annotation over.
---
---The body is a scratch FLOAT, not `vim.ui.input`: a review body is prose and
---frequently multi-line, which `vim.ui.input` cannot carry at all.
---
---It is SIZED FROM THE EDITOR and CARRIES ITS KEYS in the border footer. The
---box was a fixed 8 rows by at most 76 columns with nothing on screen naming
---`<C-s>`, so a reviewer who pressed `c` got a small box and no way to learn
---how to finish — the keys existed only in this source file (Johno,
---2026-09-02: "the modal seemed to be too small to begin with, then there was
---no instruction as to how I can finish and attach my note"). A prose box is
---where a reviewer spends the most time in this view, and the diff it refers
---to is hidden behind it, so it takes a share of the editor like every other
---float in the family — clamped at both ends, since a very wide terminal would
---otherwise give an unreadable prose column and a short one a box taller than
---the screen.
local function _compose(anchor, on_done)
  local a = _state and _state.annotate
  local severities = (a and a.severities) or M.SEVERITIES
  vim.ui.select(severities, { prompt = "severity:" }, function(sev)
    if not sev then return end
    -- The footer is drawn in AutoCoreHelpKey / AutoCoreHelpDesc, which exist
    -- only once the registry has run. `open` calls this too, but `_compose` is
    -- reachable from a test without it.
    highlights.ensure()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local cols = vim.o.columns
    -- `lines` counts the whole terminal; the cmdline and the last row are not
    -- ours to draw over.
    local rows = math.max(1, vim.o.lines - vim.o.cmdheight - 1)
    local width = math.max(60, math.min(110, math.floor(cols * 0.62)))
    local height = math.max(12, math.min(20, math.floor(rows * 0.45)))
    -- A terminal below the clamp floors still gets a box that fits inside it.
    width = math.min(width, math.max(20, cols - 4))
    height = math.min(height, math.max(3, rows - 4))
    local cfg = {
      relative = "editor", width = width, height = height,
      row = math.max(0, math.floor((rows - height) / 2)),
      col = math.max(0, math.floor((cols - width) / 2)),
      style = "minimal", border = "rounded",
      title = (" %s · %s:%d "):format(sev, anchor.path, anchor.line),
      title_pos = "center",
    }
    -- The two are set TOGETHER or not at all. A `footer_pos` with no `footer`
    -- is an error from `nvim_open_win` ("'footer' requires 'footer_pos'"), not
    -- an ignored field — so passing the position unconditionally turned the
    -- one case that legitimately has no hints into a thrown keypress. Caught
    -- by [9]'s 30-column pin, which is the whole reason it is there.
    local footer = _compose_footer(width)
    if footer then
      cfg.footer, cfg.footer_pos = footer, "center"
    end
    local win = vim.api.nvim_open_win(buf, true, cfg)
    vim.wo[win].wrap = true
    local function finish(accept)
      local lines = vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      local body = vim.trim(table.concat(lines, "\n"))
      if not accept then
        -- A cancelled box that held prose is work the reviewer has just lost,
        -- and the key that cancels sits one keystroke from the key that does
        -- not: `<Esc>` leaves insert mode, a second `<Esc>` discards. The
        -- empty-body path below has always announced itself; silence on this
        -- one was the louder of the two failures.
        if body ~= "" then
          vim.notify(("diffview: annotation discarded (%d characters)"):format(#body),
            vim.log.levels.WARN)
        end
        return
      end
      -- An empty body ABANDONS rather than storing a comment the schema would
      -- later reject. Refusing at the point of entry is the only place the
      -- reviewer still has the context to fix it.
      if body == "" then
        vim.notify("diffview: empty body — annotation abandoned", vim.log.levels.WARN)
        return
      end
      local ann = vim.tbl_extend("force", anchor, { severity = sev, body = body })
      on_done(ann)
    end
    vim.keymap.set({ "n", "i" }, "<C-s>", function() finish(true) end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "q", function() finish(false) end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<Esc>", function() finish(false) end, { buffer = buf, nowait = true })
    vim.cmd("startinsert")
  end)
end

---open renders `files` with optional `annotations`.
---@param opts { files: table[], annotations: table<string, table[]>?, title: string?, on_close: function?, annotate: table?, keymaps: table[]? }
---
---`opts.annotate` has THREE states, and which keys exist is how they differ:
---  * absent            — no authoring surface at all; nothing is bound, and
---                        every existing consumer behaves exactly as before
---  * `disabled_reason` — `c` alone is bound and EXPLAINS; `x` stays unbound so
---                        nothing implies a draft exists
---  * enabled           — `c` and `x`, plus whatever `opts.keymaps` adds
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

  -- Captured for teardown. `Float:close` empties `self.panes` BEFORE running
  -- `on_close`, so asking the float for its buffers at that point returns nil —
  -- which is exactly how the first attempt at this cleanup silently kept
  -- leaking. The handles have to be held independently of the float.
  local content_bufs = {}

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
    -- The consumer owns the draft, so it is the only thing that can say whether
    -- closing loses anything. Only a "key" close is vetoable (ADR-0065 §2.3).
    before_close = opts.annotate and opts.annotate.before_close or nil,
    on_close = function()
      -- Row-map cleanup lives HERE, not in `M.close`. `q`/`<Esc>` and a lost
      -- pane close the float directly through `float.multi`, never through
      -- `M.close`, so cleanup hung off `M.close` leaked a dead-buffer map on
      -- every key close — and the maps are keyed by buffer, so the leak was
      -- unbounded across a session. `on_close` is the once-only path EVERY
      -- close route converges on.
      for _, b in ipairs(content_bufs) do M._rowmap[b] = nil end
      -- Snapshot the last position BEFORE dropping _state. Windows are already
      -- gone here, but the file index and the line (recorded live by the
      -- content-pane autocmd) are still on _state -- which is exactly why the
      -- line is tracked as the cursor moves rather than read at close time.
      local f = _state.files[_state.idx]
      if f then
        M._last_position = {
          path = f.new_path or f.path or f.old_path,
          lnum = _state.cursor and _state.cursor.lnum or nil,
          col = _state.cursor and _state.cursor.col or nil,
        }
      end
      local pos = M._last_position
      _state = nil
      if opts.on_close then pcall(opts.on_close, pos) end
    end,
  })

  _state = { float = float, files = files, annotations = opts.annotations, idx = 1,
             annotate = opts.annotate, keymaps = opts.keymaps }
  float:open()

  for _, pane in ipairs({ "middle", "preview" }) do
    local b = float:bufnr(pane)
    if b then content_bufs[#content_bufs + 1] = b end
  end

  -- `float.multi` opens panes with `style = "minimal"`, which sets
  -- `number = false` AND `statuscolumn = ""` — so a status column string is not
  -- enough on its own; each content pane has to claim these window options.
  for _, pane in ipairs({ "middle", "preview" }) do
    local w = float:winid(pane)
    if w and vim.api.nvim_win_is_valid(w) then
      vim.wo[w].number = true
      vim.wo[w].relativenumber = false
      vim.wo[w].numberwidth = 1
      vim.wo[w].statuscolumn = "%!v:lua.require'auto-core.ui.diffview'.statuscolumn()"
    end
  end

  local left = float:bufnr("left")
  if left and vim.api.nvim_buf_is_valid(left) then
    vim.bo[left].modifiable = true
    vim.api.nvim_buf_set_lines(left, 0, -1, false, _file_rows(files))
    vim.bo[left].modifiable = false
  end

  M._render_footer()

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

  -- Remember where the reader is, so `last_position()` can hand it back after a
  -- close (requirement 6: navigate away to check a file, then recall the diff).
  -- One autocmd per content pane records the line; the file is `_state.idx`.
  -- Disposed with the float, like the left-pane follower above.
  for _, pane in ipairs({ "middle", "preview" }) do
    local cb = float:bufnr(pane)
    if cb and vim.api.nvim_buf_is_valid(cb) then
      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = cb,
        callback = function()
          if not _state then return true end
          local w = _state.float:winid(pane)
          if not (w and vim.api.nvim_win_is_valid(w)) then return end
          local c = vim.api.nvim_win_get_cursor(w)
          _state.cursor = { pane = pane, lnum = c[1], col = c[2] }
        end,
      })
    end
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
      -- C-l / C-h alias Tab / S-Tab, the family convention for a multi-pane
      -- float (`worktree.graph`, `log.viewer`): a reader who reaches for h/l to
      -- move between windows gets the same motion here. Forward and backward,
      -- not left/right-absolute, so the three keys stay interchangeable and the
      -- wrap at the ends matches what Tab already does.
      pcall(vim.keymap.set, "n", "<C-l>", function()
        if _state then _state.float:cycle("forward") end
      end, { buffer = b, silent = true, nowait = true, desc = "auto-core.diffview: next pane" })
      pcall(vim.keymap.set, "n", "<C-h>", function()
        if _state then _state.float:cycle("backward") end
      end, { buffer = b, silent = true, nowait = true, desc = "auto-core.diffview: prev pane" })
    end
  end

  -- Authoring keys. Bound on the CONTENT panes only: the file list has no
  -- lines to anchor to.
  local ann = opts.annotate
  if ann then
    local disabled = ann.disabled_reason
    for _, pane in ipairs({ "middle", "preview" }) do
      local b = float:bufnr(pane)
      if b and vim.api.nvim_buf_is_valid(b) then
        local function annotate(visual)
          if disabled then
            vim.notify("diffview: " .. tostring(disabled), vim.log.levels.WARN)
            return
          end
          local anchor, reason = _anchor_here(visual)
          if not anchor then
            vim.notify("diffview: " .. tostring(reason), vim.log.levels.WARN)
            return
          end
          _compose(anchor, function(a)
            local okc = pcall(ann.on_add, a)
            if not okc then
              vim.notify("diffview: the consumer refused the annotation", vim.log.levels.ERROR)
              return
            end
            _show(_state.idx)
            M._render_footer()
          end)
        end
        -- TWO mappings, not one shared across modes: the mode is the intent.
        pcall(vim.keymap.set, "n", "c", function() annotate(false) end,
          { buffer = b, silent = true, nowait = true, desc = "auto-core.diffview: annotate line" })
        pcall(vim.keymap.set, "x", "c", function() annotate(true) end,
          { buffer = b, silent = true, nowait = true, desc = "auto-core.diffview: annotate selection" })

        -- `x` is NOT bound while disabled: a key that removes from a draft
        -- implies a draft exists.
        if not disabled and type(ann.on_remove) == "function" then
          pcall(vim.keymap.set, "n", "x", function()
            local anchor, reason = _anchor_here()
            if not anchor then
              vim.notify("diffview: " .. tostring(reason), vim.log.levels.WARN)
              return
            end
            pcall(ann.on_remove, anchor)
            _show(_state.idx)
            M._render_footer()
          end, { buffer = b, silent = true, nowait = true, desc = "auto-core.diffview: drop pending annotation" })
        end
      end
    end
  end

  -- Consumer keymaps. This is how a submit key reaches the view without
  -- auto-core learning what submitting means.
  --
  -- CONTENT PANES ONLY. An earlier version also bound these on the Files pane,
  -- on the reasonable-sounding grounds that a submit key is not row-anchored —
  -- but ADR-0065 §2.4 normatively says `c`/`x`/`s` are bound on middle and
  -- preview only, and a code comment cannot amend an accepted ADR. If the wider
  -- binding is wanted, it needs a superseding decision first.
  for _, km in ipairs(opts.keymaps or {}) do
    if type(km) == "table" and type(km.key) == "string" and type(km.fn) == "function" then
      for _, pane in ipairs({ "middle", "preview" }) do
        local b = float:bufnr(pane)
        if b and vim.api.nvim_buf_is_valid(b) then
          pcall(vim.keymap.set, "n", km.key, function()
            -- The current file is handed to the consumer because its keys fire
            -- at press time and the file changes under j/k: an open-time capture
            -- would be stale. `o open this file` is the motivating case.
            km.fn(M.current_file())
            if M.is_open() then
              _show(_state.idx)
              M._render_footer()
            end
          end, { buffer = b, silent = true, nowait = true,
                 desc = "auto-core.diffview: " .. (km.desc or km.key) })
        end
      end
    end
  end

  -- opts.initial reopens the view where a prior session left it (requirement 6).
  -- A path that no longer exists in this diff is a SOFT miss -- open at the
  -- first file, never refuse -- because a stale resume must still show a diff.
  local start_idx = 1
  if opts.initial and opts.initial.path then
    for i, f in ipairs(files) do
      if (f.new_path or f.path or f.old_path) == opts.initial.path then start_idx = i; break end
    end
  end
  _show(start_idx)
  -- Move the file-list cursor to the shown file so the two agree.
  local lw = float:winid("left")
  if lw and vim.api.nvim_win_is_valid(lw) then
    pcall(vim.api.nvim_win_set_cursor, lw, { start_idx, 0 })
  end
  -- Restore the content-pane line, clamped to what the pane actually holds.
  if opts.initial and opts.initial.lnum then
    for _, pane in ipairs({ "middle", "preview" }) do
      local w, b = float:winid(pane), float:bufnr(pane)
      if w and b and vim.api.nvim_win_is_valid(w) and vim.api.nvim_buf_is_valid(b) then
        local last = vim.api.nvim_buf_line_count(b)
        pcall(vim.api.nvim_win_set_cursor, w, { math.min(opts.initial.lnum, last), 0 })
      end
    end
  end
  return float, nil
end

---_render_footer redraws the hint line, including the pending count.
---
---An unwritten draft that is invisible is one the reader can lose without ever
---being told, so the count lives on the surface that is always on screen.
function M._render_footer()
  if not _state then return end
  local foot = _state.float:bufnr("footer")
  if not (foot and vim.api.nvim_buf_is_valid(foot)) then return end

  -- PROSE orients a first-time reader; KEYS are what a returning one needs.
  -- They are assembled separately because a narrow pane has to shed one and not
  -- the other. The footer is a ONE-LINE pane: anything past its width is simply
  -- not drawn, and the tail is where the pending count lives — so an untrimmed
  -- line loses exactly the signal that must never go missing.
  local prose = { "j/k file", "<Tab> pane", "a/ = old, b/ = new" }
  local keys = {}
  local ann = _state.annotate
  if ann then
    keys[#keys + 1] = ann.disabled_reason and "c unavailable" or "c annotate"
    if not ann.disabled_reason and type(ann.on_remove) == "function" then
      keys[#keys + 1] = "x drop"
    end
  end
  -- Consumer keys are ADVERTISED, not only bound. `opts.keymaps` is how a
  -- consumer reaches the view without auto-core learning what its keys mean —
  -- but a key that appears nowhere on screen is a key nobody finds, and the one
  -- auto-finder passes is `s submit`: the key that actually writes the review.
  -- Until now it existed only in the source.
  for _, km in ipairs(_state.keymaps or {}) do
    if type(km) == "table" and type(km.key) == "string" and type(km.fn) == "function" then
      keys[#keys + 1] = km.key .. " " .. (km.desc or km.key)
    end
  end
  keys[#keys + 1] = "q close"

  local tail = ""
  if ann and type(ann.pending) == "function" then
    local ok, list = pcall(ann.pending)
    local n = (ok and type(list) == "table") and #list or 0
    if n > 0 then
      tail = ("     ● %d pending"):format(n)
    end
  end

  local win = _state.float:winid("footer")
  local width = (win and vim.api.nvim_win_is_valid(win))
    and vim.api.nvim_win_get_width(win) or math.huge

  local function assemble()
    local all = {}
    for _, x in ipairs(prose) do all[#all + 1] = x end
    for _, x in ipairs(keys) do all[#all + 1] = x end
    return "  " .. table.concat(all, "   ") .. tail
  end

  -- Shed prose from the right: `j/k file` survives longest because a reader who
  -- has lost their bearings still has to move between files.
  local line = assemble()
  while vim.fn.strdisplaywidth(line) > width and #prose > 0 do
    table.remove(prose)
    line = assemble()
  end
  -- No prose left and still over: the keys themselves overflow. Truncate THEM
  -- and keep the tail, because an unwritten draft the reader cannot see is one
  -- they can lose without ever being told.
  if vim.fn.strdisplaywidth(line) > width then
    local body = "  " .. table.concat(keys, "   ")
    while #body > 0 and vim.fn.strdisplaywidth(body .. "…" .. tail) > width do
      body = vim.fn.strcharpart(body, 0, vim.fn.strchars(body) - 1)
    end
    line = body .. "…" .. tail
  end

  vim.bo[foot].modifiable = true
  vim.api.nvim_buf_set_lines(foot, 0, -1, false, { line })
  vim.bo[foot].modifiable = false
end

---close disposes the view if it is open. Idempotent.
---close tears the view down. `reason` reaches the consumer's `before_close`
---hook, and per `Float:close` only `"key"` may be VETOED there.
---
---A veto is HONOURED here, which it was not. This wrapper asked the float to
---close and then cleared `_state` and disposed the registry entry
---unconditionally — so a consumer whose hook answered "cancel" kept its windows
---(the float layer respects the veto correctly) while the state those windows
---are driven from was destroyed underneath them: `is_open()` went false, the
---row maps and the annotate wiring went away, and the panes were left showing a
---diff the view no longer knew about. Found by analysis while chasing the
---review-submit trap, not by the symptom — auto-finder only ever calls
---`close("resume")`, which cannot be vetoed, so nothing in the family was
---exercising it (2026-09-02).
---@param reason string?
function M.close(reason)
  local float = _state and _state.float
  if float then
    pcall(function() float:dispose(reason) end)
    -- Still open means the hook refused. Leave `_state` exactly as it was: the
    -- windows are alive and they need it.
    local ok, open = pcall(function() return float:is_open() end)
    if ok and open then return end
  end
  _state = nil
  pcall(multi.dispose, NAME)
end

---is_open reports whether the view is showing.
---@return boolean
function M.is_open()
  return _state ~= nil and _state.float ~= nil and _state.float:is_open()
end

---current_file returns the diff file the view is showing, or nil when closed.
---
---The seam a consumer needs to act on "this file": its own keys fire at press
---time, and the shown file changes under j/k, so nothing an open-time capture
---holds is still true. Returns the parsed `AutoCoreDiffFile` (path / old_path /
---new_path / kind), not a copy — read it, do not mutate it.
---@return AutoCoreDiffFile?
function M.current_file()
  if not _state then return nil end
  return _state.files[_state.idx]
end

---last_position returns where the reader was when the view last closed, or nil
---if it has never been open. `{ path, lnum, col }` -- the file by path (idx is
---not stable across a re-parse) and the content-pane line. Pass it straight back
---as `opts.initial` to reopen there. It survives close (stored on M, not the
---per-open state), and is overwritten by the next close.
---@return { path: string, lnum: integer?, col: integer? }?
function M.last_position()
  return M._last_position
end

---_anchor_for_tests resolves an anchor exactly as a keypress would.
---
---A seam, because the stale-marks defect lives in the resolution and not in
---anything the buffer shows: with `'<`/`'>` left over from an earlier
---selection, a normal-mode `c` produced a RANGE. Asserting that the two
---mappings merely exist would not have caught it.
---@param visual boolean?
---@return table? anchor, string? reason
function M._anchor_for_tests(visual) return _anchor_here(visual) end

---_compose_for_tests opens the annotation composer exactly as `c` would, so a
---suite can assert on the box a reviewer actually meets — its size and the keys
---it advertises — rather than on the keymaps alone.
---@param anchor table
---@param on_done fun(annotation: table)
function M._compose_for_tests(anchor, on_done) return _compose(anchor, on_done) end

---COMPOSE_KEYS_FOR_TESTS is the advertised key list, so a suite pins the footer
---against the same source the footer is built from.
M.COMPOSE_KEYS_FOR_TESTS = COMPOSE_KEYS

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
