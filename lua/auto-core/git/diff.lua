---auto-core.git.diff — a unified-diff parser.
---
---ADR-0060 P2. `graph.show_diff` returns the raw lines of
---`git show -p --no-color`; nothing in the family turned them into structure.
---A three-column diff view (files | before | after) needs per-file BEFORE and
---AFTER line arrays that carry their real line numbers, because that is what a
---review comment anchors to: `(path, line, side)` from the review JSON has to
---resolve to a buffer row without guessing.
---
---Pure text in, tables out — no git invocation, no windows, no highlights. That
---keeps it unit-testable without a repo and reusable by anything holding a
---diff (a commit, a working-tree diff, a `.patch` file on disk).
---@module 'auto-core.git.diff'

local M = {}

---@class AutoCoreDiffLine
---@field kind string     "context" | "add" | "del"
---@field text string     the line WITHOUT its +/-/space marker
---@field old integer?    1-based line number on the BEFORE side, nil for an add
---@field new integer?    1-based line number on the AFTER side, nil for a delete

---@class AutoCoreDiffHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field heading string        the text after the closing `@@`, often a function name
---@field header string         the verbatim `@@ ... @@` line
---@field lines AutoCoreDiffLine[]

---@class AutoCoreDiffFile
---@field old_path string?      nil for an added file
---@field new_path string?      nil for a deleted file
---@field path string           the path to display: new_path if present, else old_path
---@field kind string           "added" | "deleted" | "modified" | "renamed" | "binary"
---@field binary boolean
---@field hunks AutoCoreDiffHunk[]
---@field old_mode string?
---@field new_mode string?
---@field similarity integer?   rename/copy similarity percentage, when git reports one

-- `diff --git a/<old> b/<new>`. Paths may contain spaces, so this is
-- deliberately greedy-then-split rather than a naive `(%S+) (%S+)`: git writes
-- the a/ and b/ prefixes, and the b/ marker is the only reliable pivot.
local function _parse_git_header(line)
  local rest = line:match("^diff %-%-git (.+)$")
  if not rest then return nil, nil end
  -- Find the LAST " b/" — a path may itself contain " b/".
  local pivot
  local from = 1
  while true do
    local s = rest:find(" b/", from, true)
    if not s then break end
    pivot = s
    from = s + 1
  end
  if not pivot then return nil, nil end
  local a = rest:sub(1, pivot - 1)
  local b = rest:sub(pivot + 1)
  return (a:gsub("^a/", "")), (b:gsub("^b/", ""))
end

---_strip_prefix turns `a/foo` or `b/foo` into `foo`, and `/dev/null` into nil
---(which is how the parser represents "this side does not exist").
local function _strip_prefix(p)
  if not p or p == "/dev/null" then return nil end
  p = p:gsub("^[ab]/", "")
  -- git quotes paths with unusual bytes in the ---/+++ lines unless
  -- core.quotepath=off; strip a surrounding pair if present.
  if p:sub(1, 1) == '"' and p:sub(-1) == '"' then p = p:sub(2, -2) end
  return p
end

---parse turns unified-diff text into files → hunks → lines.
---
---Accepts either a list of lines (what `graph.show_diff` returns) or one blob.
---Unknown/extra headers are ignored rather than fatal: `git show` prefixes a
---commit message, and `diff.noprefix` / `--stat` output can lead the stream.
---@param input string[]|string
---@return AutoCoreDiffFile[]
function M.parse(input)
  local lines
  if type(input) == "string" then
    lines = vim.split(input, "\n", { plain = true })
  else
    lines = input or {}
  end

  local files, file, hunk = {}, nil, nil
  local old_no, new_no = 0, 0

  local function close_file()
    if file then files[#files + 1] = file end
    file, hunk = nil, nil
  end

  for _, raw in ipairs(lines) do
    local line = tostring(raw)

    if line:match("^diff %-%-git ") then
      close_file()
      local a, b = _parse_git_header(line)
      file = {
        old_path = a, new_path = b, path = b or a or "?",
        kind = "modified", binary = false, hunks = {},
      }
      hunk = nil

    elseif file and line:match("^new file mode ") then
      file.kind = "added"
      file.new_mode = line:match("^new file mode (%S+)")
      file.old_path = nil

    elseif file and line:match("^deleted file mode ") then
      file.kind = "deleted"
      file.old_mode = line:match("^deleted file mode (%S+)")
      file.new_path = nil
      file.path = file.old_path or file.path

    elseif file and line:match("^similarity index ") then
      file.similarity = tonumber(line:match("(%d+)"))

    elseif file and (line:match("^rename from ") or line:match("^copy from ")) then
      file.kind = "renamed"
      file.old_path = line:match("^%a+ from (.+)$")

    elseif file and (line:match("^rename to ") or line:match("^copy to ")) then
      file.kind = "renamed"
      file.new_path = line:match("^%a+ to (.+)$")
      file.path = file.new_path or file.path

    elseif file and line:match("^old mode ") then
      file.old_mode = line:match("^old mode (%S+)")
    elseif file and line:match("^new mode ") then
      file.new_mode = line:match("^new mode (%S+)")

    elseif line:match("^Binary files .* differ$") or line:match("^GIT binary patch") then
      -- A binary file has no hunks; say so rather than rendering an empty diff.
      if not file then
        file = { path = "?", kind = "binary", binary = true, hunks = {} }
      end
      file.binary, file.kind = true, "binary"

    elseif file and line:match("^%-%-%- ") then
      local p = _strip_prefix(vim.trim(line:sub(5)))
      if p then file.old_path = file.old_path or p
      else file.kind = "added"; file.old_path = nil end

    elseif file and line:match("^%+%+%+ ") then
      local p = _strip_prefix(vim.trim(line:sub(5)))
      if p then
        file.new_path = file.new_path or p
        file.path = file.new_path
      else
        file.kind = "deleted"; file.new_path = nil
        file.path = file.old_path or file.path
      end

    elseif line:match("^@@") then
      -- @@ -old_start,old_count +new_start,new_count @@ heading
      local os_, oc, ns_, nc, heading =
        line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")
      if os_ and file then
        hunk = {
          old_start = tonumber(os_), old_count = tonumber(oc) or 1,
          new_start = tonumber(ns_), new_count = tonumber(nc) or 1,
          heading = heading or "", header = line, lines = {},
        }
        file.hunks[#file.hunks + 1] = hunk
        old_no, new_no = hunk.old_start, hunk.new_start
      end

    elseif hunk then
      local marker, text = line:sub(1, 1), line:sub(2)
      if marker == "+" then
        hunk.lines[#hunk.lines + 1] = { kind = "add", text = text, new = new_no }
        new_no = new_no + 1
      elseif marker == "-" then
        hunk.lines[#hunk.lines + 1] = { kind = "del", text = text, old = old_no }
        old_no = old_no + 1
      elseif marker == " " then
        hunk.lines[#hunk.lines + 1] =
          { kind = "context", text = text, old = old_no, new = new_no }
        old_no, new_no = old_no + 1, new_no + 1
      elseif marker == "\\" then
        -- "\ No newline at end of file" annotates the PREVIOUS line; it is not
        -- content and must not advance either counter.
        local prev = hunk.lines[#hunk.lines]
        if prev then prev.no_newline = true end
      elseif line == "" then
        -- An empty context line: git writes a bare "" rather than " ".
        hunk.lines[#hunk.lines + 1] =
          { kind = "context", text = "", old = old_no, new = new_no }
        old_no, new_no = old_no + 1, new_no + 1
      end
    end
  end
  close_file()
  return files
end

---sides projects one file into the two column buffers a three-column view
---renders: BEFORE and AFTER, each entry carrying its real line number so a
---review comment's `(line, side)` resolves to a row by lookup rather than
---arithmetic.
---
---The two columns are kept ROW-ALIGNED: `#before == #after`, and a shared
---context line occupies the same index in both. A replacement block whose
---delete and add counts differ pairs del[k] with add[k] and pads the short side
---with a `pad` entry, so unrelated code is never drawn on the same visual row
---and shared context after the block resumes on the same row (ADR-0060 r1 MF4).
---git emits all `-` lines of a change region before all `+` lines, so a block
---is the run of del/add between two context lines; it is flushed at each
---context line and at end of hunk.
---
---`pad` entries carry no lineno, so `row_for` skips them and a review comment
---can never anchor to a filler row.
---
---Hunks are separated by a `gap` entry in BOTH columns; because every hunk
---leaves the columns equal-length, the divider lands on the same row in each.
---_sides_full renders full file context (ADR-0083 §2.4).
---Unchanged lines outside and between hunks are rendered as kind="context",
---with no "gap" dividers, so the reviewer can inspect surrounding code.
function M._sides_full(file, opts)
  opts = opts or {}
  local blines = opts.before_lines
  local alines = opts.after_lines
  if not blines and opts.read_file then
    local res = opts.read_file("before", file.old_path or file.path)
    if type(res) == "string" then blines = vim.split(res:gsub("\r\n", "\n"), "\n", { plain = true })
    elseif type(res) == "table" then blines = res end
  end
  if not alines and opts.read_file then
    local res = opts.read_file("after", file.new_path or file.path)
    if type(res) == "string" then alines = vim.split(res:gsub("\r\n", "\n"), "\n", { plain = true })
    elseif type(res) == "table" then alines = res end
  end

  -- Fallback to git/worktree if available and lines are missing
  if (not blines or not alines) and (opts.worktree or opts.cwd) then
    local dir = opts.worktree or opts.cwd
    if not blines and file.old_path and file.kind ~= "added" then
      local rev
      if opts.uncommitted then rev = "HEAD"
      elseif opts.base then rev = opts.base
      elseif opts.sha then rev = opts.sha .. "~1" end
      if rev then
        local out = vim.system({ "git", "-C", dir, "show", rev .. ":" .. file.old_path }, { text = true }):wait()
        if out.code == 0 and out.stdout then
          blines = vim.split(out.stdout:gsub("\r\n", "\n"), "\n", { plain = true })
          if #blines > 0 and blines[#blines] == "" and out.stdout:sub(-1) == "\n" then
            table.remove(blines)
          end
        end
      end
    end
    if not alines and file.new_path and file.kind ~= "deleted" then
      if opts.uncommitted then
        local p = dir .. "/" .. file.new_path
        local f = io.open(p, "r")
        if f then
          local content = f:read("*a")
          f:close()
          if content then
            alines = vim.split(content:gsub("\r\n", "\n"), "\n", { plain = true })
            if #alines > 0 and alines[#alines] == "" and content:sub(-1) == "\n" then
              table.remove(alines)
            end
          end
        end
      elseif opts.sha then
        local out = vim.system({ "git", "-C", dir, "show", opts.sha .. ":" .. file.new_path }, { text = true }):wait()
        if out.code == 0 and out.stdout then
          alines = vim.split(out.stdout:gsub("\r\n", "\n"), "\n", { plain = true })
          if #alines > 0 and alines[#alines] == "" and out.stdout:sub(-1) == "\n" then
            table.remove(alines)
          end
        end
      end
    end
  end

  if not blines and not alines then
    return M.sides(file, { context = "hunk" })
  end

  blines = blines or {}
  alines = alines or {}

  local before, after = {}, {}
  local dels, adds = {}, {}
  local function flush_block()
    local n = math.max(#dels, #adds)
    for k = 1, n do
      before[#before + 1] = dels[k] or { kind = "pad", text = "", lineno = nil }
      after[#after + 1] = adds[k] or { kind = "pad", text = "", lineno = nil }
    end
    dels, adds = {}, {}
  end

  local cur_old, cur_new = 1, 1
  for _, h in ipairs(file.hunks or {}) do
    -- Pre-hunk context lines
    while cur_old < h.old_start and cur_new < h.new_start do
      flush_block()
      local txt = blines[cur_old] or alines[cur_new] or ""
      before[#before + 1] = { kind = "context", text = txt, lineno = cur_old }
      after[#after + 1] = { kind = "context", text = txt, lineno = cur_new }
      cur_old = cur_old + 1
      cur_new = cur_new + 1
    end

    -- Hunk lines
    for _, l in ipairs(h.lines) do
      if l.kind == "context" then
        flush_block()
        before[#before + 1] = { kind = "context", text = l.text, lineno = l.old }
        after[#after + 1] = { kind = "context", text = l.text, lineno = l.new }
      elseif l.kind == "del" then
        dels[#dels + 1] = { kind = "del", text = l.text, lineno = l.old }
      elseif l.kind == "add" then
        adds[#adds + 1] = { kind = "add", text = l.text, lineno = l.new }
      end
    end
    flush_block()
    cur_old = h.old_start + h.old_count
    cur_new = h.new_start + h.new_count
  end

  -- Post-hunk tail context lines
  while cur_old <= #blines or cur_new <= #alines do
    flush_block()
    local txt = blines[cur_old] or alines[cur_new] or ""
    local o_no = (cur_old <= #blines) and cur_old or nil
    local n_no = (cur_new <= #alines) and cur_new or nil
    before[#before + 1] = { kind = "context", text = txt, lineno = o_no }
    after[#after + 1] = { kind = "context", text = txt, lineno = n_no }
    cur_old = cur_old + 1
    cur_new = cur_new + 1
  end

  return { before = before, after = after }
end

---sides projects one file into the two column buffers a three-column view
---renders: BEFORE and AFTER, each entry carrying its real line number so a
---review comment's `(line, side)` resolves to a row by lookup rather than
---arithmetic.
---
---Supports opts.context = "hunk" (default) or "full" (ADR-0083 §2.4).
---@param file AutoCoreDiffFile
---@param opts table?
---@return { before: table[], after: table[] }
function M.sides(file, opts)
  local before, after = {}, {}
  if not file then return { before = before, after = after } end

  local context_mode = (opts and opts.context) or "hunk"
  if context_mode == "full" then
    return M._sides_full(file, opts)
  end

  local dels, adds = {}, {}
  local function flush_block()
    local n = math.max(#dels, #adds)
    for k = 1, n do
      before[#before + 1] = dels[k] or { kind = "pad", text = "", lineno = nil }
      after[#after + 1] = adds[k] or { kind = "pad", text = "", lineno = nil }
    end
    dels, adds = {}, {}
  end

  for hi, h in ipairs(file.hunks or {}) do
    if hi > 1 then
      before[#before + 1] = { kind = "gap", text = "", lineno = nil }
      after[#after + 1] = { kind = "gap", text = "", lineno = nil }
    end
    for _, l in ipairs(h.lines) do
      if l.kind == "context" then
        flush_block()  -- close any open replacement before the shared line
        before[#before + 1] = { kind = "context", text = l.text, lineno = l.old }
        after[#after + 1] = { kind = "context", text = l.text, lineno = l.new }
      elseif l.kind == "del" then
        dels[#dels + 1] = { kind = "del", text = l.text, lineno = l.old }
      elseif l.kind == "add" then
        adds[#adds + 1] = { kind = "add", text = l.text, lineno = l.new }
      end
    end
    flush_block()  -- close the trailing block before the next hunk's gap
  end
  return { before = before, after = after }
end

---row_for finds the 0-based row in a `sides()` column that carries `lineno` —
---the lookup that anchors a review comment to a rendered line.
---@param column table[]  a `before` or `after` list from sides()
---@param lineno integer   1-based file line number
---@return integer? row    0-based row index, nil when that line is not shown
function M.row_for(column, lineno)
  if not column or not lineno then return nil end
  for i, entry in ipairs(column) do
    if entry.lineno == lineno then return i - 1 end
  end
  return nil
end

---anchor resolves a rendered ROW back to the 1-based FILE line it carries.
---
---The reverse of `row_for`, and the whole of what a review comment needs from
---the renderer: `sides()` already put the real line number on every entry, so
---anchoring is a lookup rather than arithmetic.
---
---A `gap` (hunk boundary) and a `pad` (the absent side of an unequal
---replacement block) carry no line and CANNOT anchor. That mirrors the painter,
---which refuses to mark a pad as part of a reviewer's span: marking "nothing
---here" would be a claim about absent code, and originating a comment there is
---the same claim.
---@param column table[]   a `before` or `after` list from sides()
---@param row integer      0-based rendered row
---@return integer? lineno, string? reason
function M.anchor(column, row)
  local e = column and row and column[row + 1]
  if not e then return nil, "no such row in this diff" end
  if e.kind == "gap" then return nil, "a hunk boundary is not a line" end
  if e.kind == "pad" then return nil, "this side has no line here" end
  if not e.lineno then return nil, "this row carries no file line" end
  return e.lineno, nil
end

---range validates a whole SELECTION and returns its file-line span.
---
---Scans every selected row, not just the endpoints. Sampling the ends alone
---turns a selection spanning two hunks into one contiguous range the reviewer
---never made — and, more quietly, TRIMS a leading or trailing `gap` instead of
---refusing it, so `{line 10, line 11, gap}` silently became 10-11.
---
---The rules, in order (ADR-0065 §2.2):
---  1. normalise top-to-bottom
---  2. both ENDPOINTS must be anchorable — a non-line endpoint is refused, not trimmed
---  3. ANY selected `gap` refuses, interior or terminal
---  4. a `pad` is permitted only in the interior
---  5. the surviving line numbers must increment by exactly 1
---
---An interior pad is accepted and an interior gap refused because a pad
---consumes no file line on that side — the numbers either side still differ by
---1 — while a gap skips lines. A pad crossing is a discontinuity in the
---RENDERING; `start_line..line` is a claim about the FILE.
---@param column table[]
---@param r1 integer   0-based
---@param r2 integer   0-based
---@return { start_line: integer, line: integer }? span, string? reason
function M.range(column, r1, r2)
  if not (column and r1 and r2) then return nil, "no selection" end
  if r1 > r2 then r1, r2 = r2, r1 end

  local first, ferr = M.anchor(column, r1)
  if not first then return nil, "the selection starts on a row that is not a line (" .. tostring(ferr) .. ")" end
  local last, lerr = M.anchor(column, r2)
  if not last then return nil, "the selection ends on a row that is not a line (" .. tostring(lerr) .. ")" end

  local prev
  for r = r1, r2 do
    local e = column[r + 1]
    if not e then return nil, "the selection runs past the end of this diff" end
    if e.kind == "gap" then
      return nil, "the selection crosses a hunk boundary, so its lines are not contiguous in the file"
    end
    if e.lineno then
      if prev and e.lineno ~= prev + 1 then
        return nil, ("the selection is not contiguous in the file (line %d is followed by %d)")
          :format(prev, e.lineno)
      end
      prev = e.lineno
    end
  end
  return { start_line = first, line = last }, nil
end

---stats counts added/removed lines per file — the `+12 -3` a tree row shows
---without opening the diff.
---@param file AutoCoreDiffFile
---@return { added: integer, removed: integer }
function M.stats(file)
  local a, r = 0, 0
  for _, h in ipairs(file and file.hunks or {}) do
    for _, l in ipairs(h.lines) do
      if l.kind == "add" then a = a + 1 elseif l.kind == "del" then r = r + 1 end
    end
  end
  return { added = a, removed = r }
end

---find returns the parsed file whose old or new path matches `path`. A review
---comment names one path; a rename means the diff carries two.
---@param files AutoCoreDiffFile[]
---@param path string
---@return AutoCoreDiffFile?
function M.find(files, path)
  if not path then return nil end
  for _, f in ipairs(files or {}) do
    if f.path == path or f.new_path == path or f.old_path == path then return f end
  end
  return nil
end

return M
