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
---Hunks are separated by a `gap` entry, so the view can draw a divider instead
---of implying the file is contiguous.
---@param file AutoCoreDiffFile
---@return { before: table[], after: table[] }
function M.sides(file)
  local before, after = {}, {}
  if not file then return { before = before, after = after } end
  for hi, h in ipairs(file.hunks or {}) do
    if hi > 1 then
      before[#before + 1] = { kind = "gap", text = "", lineno = nil }
      after[#after + 1] = { kind = "gap", text = "", lineno = nil }
    end
    for _, l in ipairs(h.lines) do
      if l.kind == "context" then
        before[#before + 1] = { kind = "context", text = l.text, lineno = l.old }
        after[#after + 1] = { kind = "context", text = l.text, lineno = l.new }
      elseif l.kind == "del" then
        before[#before + 1] = { kind = "del", text = l.text, lineno = l.old }
      elseif l.kind == "add" then
        after[#after + 1] = { kind = "add", text = l.text, lineno = l.new }
      end
    end
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
