---Tabular data model for `auto-core.ui.grid` — the PURE half.
---
---No windows, no buffers, no keymaps, no autocmds: given columns and
---raw row values it answers what a cell IS, what it should LOOK like,
---how wide the columns need to be, and how a row serializes to CSV or
---JSON. Everything here is a function of its inputs, so the whole
---model is testable headlessly (the view half owns the effects).
---
---The distinction that matters: a cell has a **raw value** and a
---**display text**, and they are not interchangeable. Yanking a row
---must reproduce the value the database returned — embedded newlines
---and all — while the grid on screen must stay one line per row. Any
---design that keeps only the rendered string loses data the moment a
---value contains a comma, a quote or a newline.
---
---Normative rules (ADR-0058 §3.4):
---
---  * NULL      `vim.NIL` (or a Lua nil hole) renders as the configured
---              null text, is `null = true`, encodes as JSON `null`,
---              and is an EMPTY CSV field — not the string "NULL".
---  * binary    a byte string that is not printable UTF-8 renders and
---              serializes as `0x<hex>`; JSON never carries invalid
---              UTF-8. Printability matches autodb's server-side rule:
---              valid UTF-8 with no control characters beyond tab,
---              newline and carriage return.
---  * newlines  display as `␤` so a row stays one line; yanks keep the
---              real newline.
---  * duplicate column names keep their position in `{columns, rows}`
---              form and are disambiguated as `name`, `name#2`, `name#3`
---              in object form, so a JSON object never silently drops a
---              column.
---  * CSV       RFC 4180: a field is quoted when it contains a comma,
---              a quote or a newline, and inner quotes are doubled.
---@module 'auto-core.ui.grid.model'

local M = {}

---Sentinel for "no value" when a caller cannot use `vim.NIL`.
M.NULL = setmetatable({}, { __tostring = function() return "NULL" end })

local DEFAULT_NULL_TEXT = "NULL"
local NEWLINE_GLYPH = "␤"

---@class AutoCoreGridColumn
---@field name string        -- RAW, as the source named it (may repeat)
---@field key string         -- unique, for object serialization
---@field label string       -- single-line DISPLAY form of `name`
---@field type string|nil    -- optional type hint from the source

---@class AutoCoreGridCell
---@field value any          -- the RAW value (never rendered)
---@field text string        -- single-line display text
---@field null boolean       -- true for SQL NULL / vim.NIL / nil
---@field binary boolean     -- true when the value is non-printable bytes

---is_null reports the three shapes a missing value arrives in.
local function is_null(v)
  return v == nil or v == vim.NIL or v == M.NULL
end

---is_printable reports whether s is valid UTF-8 carrying no control
---characters beyond tab/newline/carriage-return — the same test the
---autodb server uses, so both ends agree on what "text" means.
---@param s string
---@return boolean
function M.is_printable(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len, min
    if c < 0x80 then
      -- Control characters make it binary, except the three we allow.
      if c < 0x20 and c ~= 9 and c ~= 10 and c ~= 13 then return false end
      if c == 0x7f then return false end
      len, min = 1, 0
    elseif c >= 0xc2 and c <= 0xdf then
      len, min = 2, 0x80
    elseif c >= 0xe0 and c <= 0xef then
      len, min = 3, 0x800
    elseif c >= 0xf0 and c <= 0xf4 then
      len, min = 4, 0x10000
    else
      return false -- continuation byte or invalid lead
    end
    if i + len - 1 > n then return false end
    local cp = c
    if len > 1 then
      cp = c % (2 ^ (7 - len))
      for k = 1, len - 1 do
        local cc = s:byte(i + k)
        if not cc or cc < 0x80 or cc > 0xbf then return false end
        cp = cp * 64 + (cc - 0x80)
      end
      if cp < min then return false end            -- overlong
      if cp >= 0xd800 and cp <= 0xdfff then return false end -- surrogate
      if cp > 0x10ffff then return false end
    end
    i = i + len
  end
  return true
end

---hex renders bytes as 0x… for values that are not text.
local function hex(s)
  return "0x" .. (s:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end

---raw_text converts a value to its FAITHFUL string form — real
---newlines preserved. This is what a yank reproduces.
---@param v any
---@param null_text string
---@return string
function M.raw_text(v, null_text)
  if is_null(v) then return null_text end
  local t = type(v)
  if t == "string" then
    return M.is_printable(v) and v or hex(v)
  end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "table" then
    local okj, encoded = pcall(vim.json.encode, v)
    if okj then return encoded end
  end
  return tostring(v)
end

---display_text is raw_text flattened to ONE line, for the grid.
---@param v any
---@param null_text string
---@return string
function M.display_text(v, null_text)
  local s = M.raw_text(v, null_text)
  s = s:gsub("\r\n", NEWLINE_GLYPH):gsub("[\n\r]", NEWLINE_GLYPH)
  return (s:gsub("\t", "    "))
end

---csv_field quotes per RFC 4180. A NULL is an EMPTY field, which is
---how a spreadsheet distinguishes it from the literal text "NULL".
---@param v any
---@return string
function M.csv_field(v)
  if is_null(v) then return "" end
  local s = M.raw_text(v, "")
  if s:find('[",\n\r]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

---json_value encodes ONE value. Scalars go through vim.json.encode —
---the grid does not implement a JSON encoder — with normalization for
---the shapes it cannot represent (NULL, non-UTF-8 bytes).
---@param v any
---@return string
function M.json_value(v)
  if is_null(v) then return "null" end
  local t = type(v)
  if t == "number" or t == "boolean" then
    local okj, enc = pcall(vim.json.encode, v)
    if okj then return enc end
    return tostring(v)
  end
  local s = (t == "string") and (M.is_printable(v) and v or hex(v)) or M.raw_text(v, "null")
  local okj, enc = pcall(vim.json.encode, s)
  return okj and enc or '""'
end

---normalize_columns accepts strings or tables and assigns each column a
---UNIQUE key: the first `id` keeps `id`, the next becomes `id#2`. A
---name that would collide with a generated key is pushed further, so
---the mapping is always one-to-one.
---
---It also derives a **display label**, exactly as cells do. A quoted
---database column name may legally contain a newline, a tab or
---non-UTF-8 bytes; rendering that raw would break the buffer write
---(a line may not contain a newline) or leave a tab whose width depends
---on where it lands. `name` therefore stays RAW for CSV/JSON identity,
---while `label` is the single-line form used for widths and headers —
---which also guarantees that a rendered header contains no control
---characters, so its width can be measured character by character.
---@param columns table
---@param null_text string
---@return AutoCoreGridColumn[]
local function normalize_columns(columns, null_text)
  local out, taken = {}, {}
  for i, c in ipairs(columns or {}) do
    local name, ctype
    if type(c) == "string" then
      name = c
    elseif type(c) == "table" then
      name, ctype = c.name or c[1], c.type
    end
    name = tostring(name or ("column" .. i))
    local key, n = name, 1
    while taken[key] do
      n = n + 1
      key = name .. "#" .. n
    end
    taken[key] = true
    out[i] = { name = name, key = key, label = M.display_text(name, null_text), type = ctype }
  end
  return out
end

---@class AutoCoreGridModel
local Model = {}
Model.__index = Model

---new builds a model.
---
---`kind` is explicit state, not an inference the caller has to redo:
---  "rows"  a result set with columns
---  "write" a statement that affected rows and returned none
---  "empty" a result set with columns but no rows
---  "error" a failed statement, carrying `error`
---@param opts { columns: table?, rows: table?, null: string?, kind: string?, verb: string?, affected: integer?, duration_ms: integer?, more: boolean?, error: string? }
---@return AutoCoreGridModel
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Model)
  self._null = opts.null or DEFAULT_NULL_TEXT
  self._columns = normalize_columns(opts.columns, self._null)
  self._rows = opts.rows or {}
  self._verb = opts.verb
  self._affected = opts.affected
  self._duration_ms = opts.duration_ms
  self._more = opts.more and true or false
  self._error = opts.error
  if opts.kind then
    self._kind = opts.kind
  elseif opts.error then
    self._kind = "error"
  elseif #self._columns == 0 then
    self._kind = "write"
  elseif #self._rows == 0 then
    self._kind = "empty"
  else
    self._kind = "rows"
  end
  return self
end

function Model:kind() return self._kind end
function Model:error() return self._error end
function Model:more() return self._more end
function Model:ncols() return #self._columns end
function Model:nrows() return #self._rows end
function Model:is_empty() return #self._rows == 0 end

---columns returns a copy, so a consumer cannot mutate the model.
---@return AutoCoreGridColumn[]
function Model:columns()
  local out = {}
  for i, c in ipairs(self._columns) do
    out[i] = { name = c.name, key = c.key, label = c.label, type = c.type }
  end
  return out
end

---row returns the RAW values of row r (1-based), or nil.
---@param r integer
---@return table|nil
function Model:row(r)
  local src = self._rows[r]
  if not src then return nil end
  local out = {}
  for i = 1, #self._columns do out[i] = src[i] end
  return out
end

---cell answers what one cell is and how it should look.
---@param r integer
---@param c integer
---@return AutoCoreGridCell|nil
function Model:cell(r, c)
  local src = self._rows[r]
  if not src or c < 1 or c > #self._columns then return nil end
  local v = src[c]
  return {
    value = v,
    text = M.display_text(v, self._null),
    null = is_null(v),
    binary = type(v) == "string" and not M.is_printable(v),
  }
end

---@class AutoCoreGridRowEntry
---@field col     integer   -- 1-based column index; what a drill-down opens
---@field name    string    -- RAW column name. For identity, NEVER rendered.
---@field label   string    -- single-line column name. This is what renders.
---@field value   any       -- RAW value, newlines intact. NEVER rendered raw.
---@field text    string    -- single-line display value. This is what renders.
---@field null    boolean
---@field binary  boolean

---row_entries describes one row as a list of per-column entries, for a
---consumer rendering a row-detail view.
---
---Per [[0066-autodb-lua-grid-selection-mode-and-detail-views]] §2.4. It lives
---here rather than in the consumer because BOTH flattening rules already
---live here, and the rule they encode has now been got wrong twice on two
---different axes: a detail view that renders one line per column must
---flatten every string that becomes part of that line — the value AND the
---column name. `label` and `text` are the flattened halves; `name` and
---`value` are the faithful ones a drill-down and a yank use.
---
---A quoted database column name may legally contain a newline (see
---`normalize_columns`), so rendering `name` would break the one-line-per-
---column premise exactly as rendering `value` would, and with it every
---mapping from a cursor line back to a column.
---@param r integer  1-based row index
---@return AutoCoreGridRowEntry[]|nil
function Model:row_entries(r)
  if self._kind ~= "rows" then return nil end
  if not self._rows[r] then return nil end
  local out = {}
  for i, c in ipairs(self._columns) do
    local cell = self:cell(r, i)
    out[i] = {
      col    = i,
      name   = c.name,
      label  = c.label,
      value  = cell and cell.value or nil,
      text   = cell and cell.text or M.display_text(nil, self._null),
      null   = cell and cell.null or true,
      binary = cell and cell.binary or false,
    }
  end
  return out
end

---row_detail_lines renders `entries` for a row-detail view and returns the
---line→entry mapping alongside them.
---
---Per §2.4. The mapping is returned rather than recomputed by the consumer
---because the whole class of bug this ADR removed twice is a consumer
---deriving "which column is the cursor on?" from rendered TEXT. Here the
---answer is an index lookup that cannot drift: `map[i]` is the entry drawn on
---line `i`, by construction.
---
---It renders `label` and `text` — the flattened halves — never `name` and
---`value`. That is the whole point: one line per column is only true if every
---string on the line is single-line, and BOTH a value and a column name may
---legally contain a newline.
---@param entries AutoCoreGridRowEntry[]
---@param sep string?  default " = "
---@return string[] lines
---@return AutoCoreGridRowEntry[] map  map[i] is the entry rendered on line i
function M.row_detail_lines(entries, sep)
  sep = sep or " = "
  local lines, map = {}, {}
  for i, e in ipairs(entries or {}) do
    -- Validated, not defaulted. Flattening below is defensive on purpose, but
    -- a MISSING half is a different thing from an unflattened one: silently
    -- substituting "" would render a line that looks fine and carries no
    -- column name, so the reader cannot tell which column they are looking at.
    if type(e) ~= "table" or type(e.label) ~= "string" or type(e.text) ~= "string" then
      error(string.format(
        "auto-core grid: row_detail_lines entry %d needs string `label` and `text` "
        .. "(got label=%s text=%s)", i,
        type(e) == "table" and type(e.label) or "n/a",
        type(e) == "table" and type(e.text) or "n/a"), 2)
    end
    -- Flattened AGAIN, deliberately. `label` and `text` are already
    -- single-line when the entries come from `row_entries`, so for that path
    -- this is a no-op. It is here because the alternative is an invariant
    -- held by convention: a caller that hand-builds entries, or reaches for
    -- `name`/`value` instead, would otherwise emit a line containing a
    -- newline — and since the viewer splits such a string across buffer
    -- lines, the buffer would end up with MORE lines than `map` has entries
    -- and every lookup below that point would silently resolve to the wrong
    -- column. Making the flattening structural means `#lines == #map` cannot
    -- be broken from outside. (Observed while control-testing ADR-0066:
    -- the rejected renderer produced 5 buffer lines against a 3-entry map,
    -- and only the line-count assertion noticed.)
    lines[#lines + 1] = M.display_text(e.label, "") .. sep .. M.display_text(e.text, "")
    map[#lines] = e
  end
  return lines, map
end

---widths measures the INTRINSIC column widths in display cells —
---header included — using `strdisplaywidth`, never byte length, so
---multibyte content aligns. `opts.max` clamps a single column;
---`opts.sample` bounds how many rows are measured on large results.
---@param opts { max: integer?, sample: integer? }?
---@return integer[]
function Model:widths(opts)
  opts = opts or {}
  local maxw = opts.max or 60
  local sample = opts.sample or 200
  local w = {}
  for i, c in ipairs(self._columns) do
    w[i] = vim.fn.strdisplaywidth(c.label)
  end
  local rows = math.min(#self._rows, sample)
  for r = 1, rows do
    for c = 1, #self._columns do
      local cell = self:cell(r, c)
      if cell then
        local cw = vim.fn.strdisplaywidth(cell.text)
        if cw > w[c] then w[c] = cw end
      end
    end
  end
  for i = 1, #w do
    if w[i] > maxw then w[i] = maxw end
    if w[i] < 1 then w[i] = 1 end
  end
  return w
end

---truncate cuts s to `width` display cells, ending with `…` when it
---had to cut. Operates on characters, not bytes.
---@param s string
---@param width integer
---@return string
function M.truncate(s, width)
  if width <= 0 then return "" end
  if vim.fn.strdisplaywidth(s) <= width then return s end
  if width == 1 then return "…" end
  local out, used = {}, 0
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local cw = vim.fn.strdisplaywidth(ch)
    if used + cw > width - 1 then break end
    out[#out + 1] = ch
    used = used + cw
  end
  return table.concat(out) .. "…"
end

local GAP = "  "

---render_line lays `texts` out on the column grid and reports the BYTE
---range of every cell, which is what the view needs to place the
---cell-cursor highlight and to resolve a cursor column back to a cell.
---
---Trailing padding is trimmed (no trailing whitespace in the buffer)
---and the ranges are CLAMPED to the trimmed length — an extmark whose
---`end_col` runs past the end of the line is an error, not a no-op.
---@param texts string[]
---@param widths integer[]
---@return string line, table ranges  -- ranges[i] = { start = 0-based byte, stop = exclusive }
local function render_line(texts, widths)
  local parts, ranges, col = {}, {}, 0
  local n = #widths
  for c = 1, n do
    local text = M.truncate(texts[c] or "", widths[c])
    local pad = widths[c] - vim.fn.strdisplaywidth(text)
    local piece = text .. string.rep(" ", math.max(pad, 0))
    ranges[c] = { start = col, stop = col + #piece }
    parts[#parts + 1] = piece
    col = col + #piece
    if c < n then
      parts[#parts + 1] = GAP
      col = col + #GAP
    end
  end
  local line = table.concat(parts):gsub("%s+$", "")
  local len = #line
  for c = 1, n do
    local rg = ranges[c]
    if rg.start > len then rg.start = len end
    if rg.stop > len then rg.stop = len end
  end
  return line, ranges
end

---line renders row r on the column grid.
---@param r integer
---@param widths integer[]
---@return string|nil line, table|nil ranges
function Model:line(r, widths)
  if not self._rows[r] then return nil, nil end
  local texts = {}
  for c = 1, #self._columns do
    local cell = self:cell(r, c)
    texts[c] = cell and cell.text or ""
  end
  return render_line(texts, widths)
end

---header_line renders the column titles on the same grid as `line`.
---@param widths integer[]
---@return string line, table ranges
function Model:header_line(widths)
  local texts = {}
  for c, column in ipairs(self._columns) do texts[c] = column.label end
  return render_line(texts, widths)
end

---column_at resolves a 0-based byte column on row r's line back to a
---column index — how the view derives the current cell from the real
---cursor instead of trapping motions.
---@param ranges table
---@param byte_col integer
---@return integer
function M.column_at(ranges, byte_col)
  for i, rg in ipairs(ranges) do
    if byte_col < rg.stop then return i end
  end
  return #ranges > 0 and #ranges or 1
end

---csv serializes row r as one RFC-4180 record.
---@param r integer
---@return string|nil
function Model:csv(r)
  local row = self._rows[r]
  if not row then return nil end
  local fields = {}
  for c = 1, #self._columns do
    fields[c] = M.csv_field(row[c])
  end
  return table.concat(fields, ",")
end

---csv_rows serializes several rows, with a header record.
---@param rows integer[]|nil  -- nil means every row
---@return string
function Model:csv_rows(rows)
  local out = {}
  local head = {}
  for c, column in ipairs(self._columns) do head[c] = M.csv_field(column.name) end
  out[1] = table.concat(head, ",")
  local list = rows
  if not list then
    list = {}
    for i = 1, #self._rows do list[i] = i end
  end
  for _, r in ipairs(list) do
    local line = self:csv(r)
    if line then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

---json serializes row r as ONE object, keys in column order, duplicate
---names disambiguated. Written directly rather than through
---`vim.json.encode` on a Lua table because a table cannot preserve key
---ORDER — every VALUE still goes through `vim.json.encode`.
---@param r integer
---@param indent string?
---@return string|nil
function Model:json(r, indent)
  local row = self._rows[r]
  if not row then return nil end
  indent = indent or "  "
  local parts = {}
  for c, column in ipairs(self._columns) do
    parts[#parts + 1] = string.format("%s%s: %s",
      indent, vim.json.encode(column.key), M.json_value(row[c]))
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end

---json_all serializes the whole result as `{ columns, rows }` — the
---form that keeps duplicate column names positionally.
---@return string
function Model:json_all()
  local cols = {}
  for c, column in ipairs(self._columns) do
    cols[c] = string.format('    { "name": %s, "key": %s }',
      vim.json.encode(column.name), vim.json.encode(column.key))
  end
  local rows = {}
  for r = 1, #self._rows do
    local vals = {}
    for c = 1, #self._columns do
      vals[c] = M.json_value(self._rows[r][c])
    end
    rows[r] = "    [" .. table.concat(vals, ", ") .. "]"
  end
  return table.concat({
    "{",
    '  "columns": [',
    table.concat(cols, ",\n"),
    "  ],",
    '  "rows": [',
    table.concat(rows, ",\n"),
    "  ]",
    "}",
  }, "\n")
end

---json_rows renders the object form for every row — the JSON VIEW.
---@return string
function Model:json_rows()
  if #self._rows == 0 then return "[]" end
  local out = {}
  for r = 1, #self._rows do
    local body = self:json(r, "    "):gsub("^{", "  {"):gsub("\n}$", "\n  }")
    out[r] = body
  end
  return "[\n" .. table.concat(out, ",\n") .. "\n]"
end

---summary describes a non-row result in one line: what a write did, or
---why a statement failed.
---@return string
function Model:summary()
  if self._kind == "error" then
    return "error: " .. tostring(self._error)
  end
  local verb = self._verb and self._verb:upper() or "OK"
  if self._kind == "write" then
    local n = self._affected or 0
    local s = string.format("%s — %d row(s) affected", verb, n)
    if self._duration_ms then s = s .. string.format(" in %dms", self._duration_ms) end
    return s
  end
  local s = string.format("%s — %d row(s)", verb, #self._rows)
  if self._duration_ms then s = s .. string.format(" in %dms", self._duration_ms) end
  if self._more then s = s .. " (more truncated)" end
  return s
end

return M
