---auto-core.ui.marks — line/range highlights, gutter marks, and virt_lines
---annotations.
---
---ADR-0060 P2. Before this module the ENTIRE codebase contained one
---`nvim_buf_set_extmark` call (the grid's cell cursor) and zero uses of
---virtual text or virtual lines. A diff view needs per-line colouring; inline
---review comments need virt_lines. Both were being invented from scratch at
---the call site, so they live here once
---([[shared-resolver-single-source-of-truth]]).
---
---Every function is namespace-scoped and every write is `pcall`ed: an extmark
---whose row is past the end of a buffer is an ERROR, not a no-op, and a render
---pass must never take the window down because content shrank between the read
---and the paint. Failures are reported by return value, never thrown.
---@module 'auto-core.ui.marks'

local highlights = require("auto-core.ui.highlights")

local M = {}

local _ns = {}

---ns returns (creating once) a named namespace. Callers pass a stable name so
---`clear` can wipe exactly their own marks and nothing else.
---@param name string
---@return integer
function M.ns(name)
  local key = "auto-core." .. tostring(name)
  if not _ns[key] then _ns[key] = vim.api.nvim_create_namespace(key) end
  return _ns[key]
end

---clear removes this namespace's marks. `from`/`to` are 0-based rows; omit
---both to clear the buffer.
---@param bufnr integer
---@param ns integer
---@param from integer?
---@param to integer?
function M.clear(bufnr, ns, from, to)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, from or 0, to or -1)
end

---_rows returns a buffer's line count, or nil when it is gone.
local function _rows(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return nil end
  return vim.api.nvim_buf_line_count(bufnr)
end

---line highlights a whole row.
---
---`line_hl_group` colours the row to the window edge (what a diff wants);
---passing `eol = false` restricts the highlight to the text instead.
---@param bufnr integer
---@param ns integer
---@param row integer          0-based
---@param hl_group string
---@param opts { eol: boolean?, priority: integer? }?
---@return boolean ok
function M.line(bufnr, ns, row, hl_group, opts)
  opts = opts or {}
  local n = _rows(bufnr)
  if not n or row < 0 or row >= n then return false end
  highlights.ensure()
  local mark = { priority = opts.priority or 100 }
  if opts.eol == false then
    mark.end_row, mark.end_col, mark.hl_group = row + 1, 0, hl_group
    mark.hl_eol = false
  else
    mark.line_hl_group = hl_group
  end
  local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, mark)
  return ok
end

---range highlights a byte span, clamped to what the buffer actually holds.
---Clamping matters: a caller computing columns from pre-render text would
---otherwise throw when a line was truncated.
---@param bufnr integer
---@param ns integer
---@param row integer        0-based
---@param col integer        0-based byte
---@param end_row integer
---@param end_col integer
---@param hl_group string
---@param opts { priority: integer? }?
---@return boolean ok
function M.range(bufnr, ns, row, col, end_row, end_col, hl_group, opts)
  local n = _rows(bufnr)
  if not n or row < 0 or row >= n then return false end
  highlights.ensure()
  end_row = math.min(end_row or row, n - 1)
  local last = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, math.max(col, 0), {
    end_row = end_row,
    end_col = math.min(end_col or #last, #last),
    hl_group = hl_group,
    priority = (opts and opts.priority) or 100,
  })
  return ok
end

---gutter places a sign in the sign column via an extmark, so it is scoped to a
---namespace and cleared with everything else — unlike the legacy `sign_place`
---API, which is global and leaks across consumers.
---@param bufnr integer
---@param ns integer
---@param row integer
---@param text string        1-2 display cells
---@param hl_group string?
---@return boolean ok
function M.gutter(bufnr, ns, row, text, hl_group)
  local n = _rows(bufnr)
  if not n or row < 0 or row >= n then return false end
  highlights.ensure()
  -- `sign_text` must be 1-2 DISPLAY CELLS. Byte-slicing is wrong: `:sub(1,2)`
  -- on a 3-byte glyph like "▎" yields a truncated UTF-8 sequence and nvim
  -- rejects the whole extmark, so the sign silently never appears. Trim by
  -- CHARACTER and re-measure.
  local sign = tostring(text or "")
  if sign == "" then return false end
  if vim.fn.strdisplaywidth(sign) > 2 then
    sign = vim.fn.strcharpart(sign, 0, 2)
    if vim.fn.strdisplaywidth(sign) > 2 then sign = vim.fn.strcharpart(sign, 0, 1) end
  end
  return (pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    sign_text = sign,
    sign_hl_group = hl_group,
    priority = 100,
  }))
end

---virt_lines renders text BELOW (or above) a row without occupying buffer
---lines — the mechanism GitHub-style inline comments need, since the diff's
---own line numbering must not shift.
---@param bufnr integer
---@param ns integer
---@param row integer                     0-based anchor
---@param lines (string|table[])[]         plain strings, or [{text, hl}] chunk lists
---@param opts { above: boolean?, priority: integer? }?
---@return boolean ok
function M.virt_lines(bufnr, ns, row, lines, opts)
  opts = opts or {}
  local n = _rows(bufnr)
  if not n or row < 0 or row >= n then return false end
  highlights.ensure()
  local vl = {}
  for _, l in ipairs(lines or {}) do
    if type(l) == "string" then
      vl[#vl + 1] = { { l, "AutoCoreReviewBody" } }
    else
      -- already a chunk list: {{text, hl}, {text, hl}}
      vl[#vl + 1] = l
    end
  end
  if #vl == 0 then return false end
  return (pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    virt_lines = vl,
    virt_lines_above = opts.above and true or false,
    priority = opts.priority or 100,
  }))
end

-- ── review annotations ───────────────────────────────────────

---SEVERITY_HL maps the KB's review severity ladder onto highlight groups.
M.SEVERITY_HL = {
  ["must-fix"]   = "AutoCoreReviewMustFix",
  ["should-fix"] = "AutoCoreReviewShouldFix",
  ["nit"]        = "AutoCoreReviewNit",
  ["question"]   = "AutoCoreReviewQuestion",
}

---annotate renders one review comment as a framed block under `row`.
---
---Shape, so a reader can tell a comment from code at a glance:
---
---  ▎ must-fix · lector
---  ▎ the body, wrapped to `width`
---
---A resolved comment renders dimmed rather than being hidden: a review that
---silently drops what it already answered is harder to audit, not easier.
---@param bufnr integer
---@param ns integer
---@param row integer                                     0-based anchor
---@param entry { severity: string?, author: string?, body: string?, resolved: boolean? }
---@param opts { width: integer?, above: boolean? }?
---@return boolean ok
function M.annotate(bufnr, ns, row, entry, opts)
  entry, opts = entry or {}, opts or {}
  local width = opts.width or 78
  local frame = entry.resolved and "AutoCoreReviewResolved" or "AutoCoreReviewFrame"
  local sev = tostring(entry.severity or "comment")
  local sev_hl = entry.resolved and "AutoCoreReviewResolved"
    or (M.SEVERITY_HL[sev] or "AutoCoreReviewFrame")
  local body_hl = entry.resolved and "AutoCoreReviewResolved" or "AutoCoreReviewBody"

  local head = sev
  if entry.author and entry.author ~= "" then head = head .. " · " .. entry.author end
  -- The reviewer's SPAN, when the finding covers more than one line. It goes in
  -- the header rather than being implied by highlighting alone, so the scope
  -- survives even when one endpoint falls outside the rendered diff and the
  -- span itself cannot be drawn (ADR-0060 r1 MF5).
  if entry.range and entry.range ~= "" then head = head .. " · " .. entry.range end
  if entry.resolved then head = head .. " · resolved" end

  local out = { { { "▎ ", frame }, { head, sev_hl } } }
  for _, para in ipairs(vim.split(tostring(entry.body or ""), "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = { { "▎ ", frame } }
    else
      -- Wrap on words so a long finding stays readable; a single word longer
      -- than `width` is emitted whole rather than being cut mid-token.
      local cur = ""
      for word in para:gmatch("%S+") do
        if cur == "" then
          cur = word
        elseif #cur + 1 + #word <= width then
          cur = cur .. " " .. word
        else
          out[#out + 1] = { { "▎ ", frame }, { cur, body_hl } }
          cur = word
        end
      end
      if cur ~= "" then out[#out + 1] = { { "▎ ", frame }, { cur, body_hl } } end
    end
  end
  return M.virt_lines(bufnr, ns, row, out, { above = opts.above })
end

---paint_diff_column colours a rendered `git.diff.sides()` column in one pass.
---
---The view writes the text; this decides the colour. Keeping them apart means
---the highlight rules are testable without a window and the same column can be
---re-painted (after a review file loads, say) without re-rendering text.
---@param bufnr integer
---@param ns integer
---@param column table[]        a `before` or `after` list from git.diff.sides()
---@param opts { offset: integer?, legacy_hl: boolean?, priority: integer? }?
---@return integer painted
function M.paint_diff_column(bufnr, ns, column, opts)
  local offset = (opts and opts.offset) or 0
  -- BACKGROUND-ONLY groups, at a priority BELOW treesitter (ADR-0065 §2.9).
  --
  -- `AutoCoreDiffAdd`/`Delete` link the THEME's `DiffAdd`/`DiffDelete`, which
  -- commonly carry a foreground as well as a background — and `M.line` defaults
  -- to priority 100, exactly what treesitter uses. Painting those groups at that
  -- priority left the outcome to extmark ordering and to whatever the colorscheme
  -- happened to define, so a diff pane could not carry syntax highlighting at all.
  --
  -- The derived `*Bg` groups have no `fg` by construction and sit at 90, so
  -- foreground belongs to treesitter and background to the diff. Neither can
  -- override the other at any priority, because they are different attributes.
  --
  -- `opts.legacy_hl = true` restores the pre-ADR-0065 groups for any consumer
  -- that renders a diff column WITHOUT treesitter and wants the theme's full
  -- DiffAdd/DiffDelete look.
  local legacy = opts and opts.legacy_hl
  local hl = {
    add = legacy and "AutoCoreDiffAdd" or "AutoCoreDiffAddBg",
    del = legacy and "AutoCoreDiffDelete" or "AutoCoreDiffDeleteBg",
    context = nil,                 -- context stays Normal: colouring every
                                   -- line makes the changed ones stop standing out
    gap = "AutoCoreDiffHunk",
  }
  local prio = (opts and opts.priority) or (legacy and 100 or 90)
  local painted = 0
  for i, entry in ipairs(column or {}) do
    local group = hl[entry.kind]
    if group and M.line(bufnr, ns, offset + i - 1, group, { priority = prio }) then
      painted = painted + 1
    end
  end
  return painted
end

---_reset_for_tests drops the namespace cache.
function M._reset_for_tests() _ns = {} end

return M
