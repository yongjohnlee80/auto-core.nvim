---YAML decode/encode for the auto-core todo task store.
---
---This is the strict-subset adapter on top of the vendored
---`auto-core.vendor.tinyyaml` parser (peposso/lua-tinyyaml, MIT).
---Per ADR-0031 §2, the on-disk format is a STRICT SUBSET of YAML:
---  • mappings + sequences + scalars + multi-line `|` block strings
---  • no anchors (`&name`), no aliases (`*name`), no merge keys (`<<:`),
---    no explicit type tags (`!!str`, etc.)
---
---Decode rejects any of those forbidden constructs at the source level
---before the parser sees them. Encode emits canonical-form YAML for
---arbitrary Lua tables — the schema-aware emission (header comment,
---section headers, fixed field order) layered on top lives in the
---task-writer module.
---@module 'auto-core.todo.yaml'

local tinyyaml = require("auto-core.vendor.tinyyaml")

local M = {}

-- ── strict-subset enforcement ──────────────────────────────────

---Detect lines that exist inside a block scalar (introduced by `|`,
---`|-`, `|+`, `>`, `>-`, `>+`). Body lines of a block scalar are
---continuation content and are not subject to the anchor / merge /
---tag forbidden-construct check.
---
---Returns a set keyed by 1-based line number for every line inside a
---block scalar body.
---@param lines string[]
---@return table<integer, true>
local function block_scalar_body_lines(lines)
  local body = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- Match `key: |` or `key: >` (with optional chomp modifier and
    -- comment). Tolerate explicit indentation indicators too (`|2`).
    local opens_block = line:match("[:%-]%s*[|>][%-+]?%d*%s*$")
      or line:match("[:%-]%s*[|>][%-+]?%d*%s*#")
    if opens_block then
      -- Determine the indent of the parent key. Block-body lines are
      -- those indented MORE than the parent key (or any line until we
      -- hit a line indented at or below the parent indent, or EOF).
      local parent_indent = #(line:match("^( *)") or "")
      local j = i + 1
      while j <= #lines do
        local body_line = lines[j]
        -- Blank lines are part of the block body (preserve indents).
        if body_line:match("^%s*$") then
          body[j] = true
          j = j + 1
        else
          local body_indent = #(body_line:match("^( *)") or "")
          if body_indent > parent_indent then
            body[j] = true
            j = j + 1
          else
            break
          end
        end
      end
      i = j
    else
      i = i + 1
    end
  end
  return body
end

---Scan source for forbidden YAML constructs. Returns `nil` if clean,
---or `string` describing the offence on first hit.
---
---Approximate but adequate for hand-edited task files: only line-start
---(after leading whitespace) value-position constructs are checked.
---Anchors / aliases / merge keys / type tags inside block-scalar
---bodies (e.g. inside a `description: |` literal) are exempt because
---those lines are continuation prose, not YAML node markers.
---@param src string
---@return string?
local function check_forbidden(src)
  local lines = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local body = block_scalar_body_lines(lines)

  for n, line in ipairs(lines) do
    if not body[n] then
      -- Strip comments (everything after a ` #` not in a string). Cheap
      -- approximation: drop from the first unquoted `#` onward. Anything
      -- inside `"..."` or `'...'` survives. We don't need bulletproof
      -- handling here because we only test for the markers at line-start
      -- value-position.
      local stripped = line:gsub("%s+#.*$", "")

      -- Find the content after leading whitespace + optional `- ` (list
      -- item marker) + optional `key:` prefix. That's the value
      -- position where anchors / aliases / tags would appear.
      local _, _, _, value = stripped:find("^(%s*%-?%s*[%w_%-%.]*:?%s*)(.*)$")
      if value and value ~= "" then
        if value:match("^&[%w_%-]+") then
          return string.format("line %d: YAML anchor `%s` not permitted in strict subset",
            n, value:match("^(&[%w_%-]+)"))
        end
        if value:match("^%*[%w_%-]+") then
          return string.format("line %d: YAML alias `%s` not permitted in strict subset",
            n, value:match("^(%*[%w_%-]+)"))
        end
        if value:match("^!![%w_%-]+") then
          return string.format("line %d: YAML explicit tag `%s` not permitted in strict subset",
            n, value:match("^(!![%w_%-]+)"))
        end
      end

      -- Merge keys: `<<:` is its own key. Look for that key form
      -- (after optional leading list marker / whitespace).
      if stripped:match("^%s*%-?%s*<<%s*:") then
        return string.format("line %d: YAML merge key `<<:` not permitted in strict subset", n)
      end
    end
  end
  return nil
end

-- ── public: decode ─────────────────────────────────────────────

---Decode a YAML source string into a Lua table, enforcing the strict
---subset rules.
---
---Return shape: `{ ok = true, value = <table> }` on success;
---`{ ok = false, err = <string> }` on rejection (either forbidden
---construct, or upstream parser failure).
---@param src string
---@return { ok: boolean, value: any?, err: string? }
function M.decode(src)
  if type(src) ~= "string" then
    return { ok = false, err = "yaml.decode: source must be a string, got " .. type(src) }
  end

  local forbidden = check_forbidden(src)
  if forbidden then
    return { ok = false, err = "yaml.decode: " .. forbidden }
  end

  local ok, value = pcall(tinyyaml.parse, src)
  if not ok then
    return { ok = false, err = "yaml.decode: parser error: " .. tostring(value) }
  end
  return { ok = true, value = value }
end

-- ── public: encode ─────────────────────────────────────────────

local YAML_INDICATOR = "^[%-?:%[%]{},&*!|>'\"%%@`#]"

---Decide whether a scalar string needs quoting. Errs on the side of
---quoting — false positives are harmless, false negatives are bugs.
---@param s string
---@return boolean
local function needs_quoting(s)
  if s == "" then return true end
  -- Leading / trailing whitespace, indicator characters at start.
  if s:match("^%s") or s:match("%s$") then return true end
  if s:match(YAML_INDICATOR) then return true end
  -- Looks like a number, boolean, or null — would re-parse incorrectly.
  if s == "true" or s == "false" or s == "null" or s == "yes" or s == "no"
    or s == "True" or s == "False" or s == "Null" or s == "Yes" or s == "No"
    or s == "TRUE" or s == "FALSE" or s == "NULL" or s == "YES" or s == "NO"
    or s == "~" then
    return true
  end
  if s:match("^%-?%d+$") or s:match("^%-?%d*%.%d+$") then return true end
  -- ISO 8601 timestamp shape — YAML 1.1 native-parses, tinyyaml doesn't
  -- always, and we want them to round-trip as strings unambiguously.
  if s:match("^%d%d%d%d%-%d%d%-%d%d") then return true end
  -- Contains `: ` (mapping separator) or ` #` (comment opener).
  if s:find(": ") or s:find(" #") then return true end
  -- Contains characters that would mangle a flow scalar.
  if s:find("[\":'#]") then return true end
  return false
end

---Quote a string as a YAML double-quoted scalar. Escapes the minimal
---set needed by the spec: `\`, `"`, and control characters.
---@param s string
---@return string
local function quote(s)
  local esc = s
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\t", "\\t")
    :gsub("\r", "\\r")
  return '"' .. esc .. '"'
end

local encode_value -- forward declare for mutual recursion

---Emit a multi-line string as a `|` literal block scalar.
---@param s string
---@param indent string
---@return string
local function emit_block_scalar(s, indent)
  local body_indent = indent .. "  "
  local out = { "|" }
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = body_indent .. line
  end
  -- The trailing empty entry from the final `\n` makes the block end
  -- cleanly without a trailing whitespace line. Drop the last entry if
  -- it would just be the body indent with nothing after.
  if out[#out] == body_indent then
    out[#out] = nil
  end
  return table.concat(out, "\n")
end

---Detect whether a Lua table is a sequence (contiguous 1..N integer
---keys) versus a mapping. Empty tables count as sequences by
---convention — encode caller decides whether to emit `[]` or omit.
---@param t table
---@return boolean
local function is_sequence(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return true end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

---Get a stable, sorted list of keys for a mapping. We sort
---alphabetically here — schema-aware ordering (with section headers)
---is the task-writer module's job, not the generic encoder's.
---@param t table
---@return string[]
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  return keys
end

---Emit a value. `indent` is the current line's leading whitespace;
---values that span lines (mappings, sequences, block scalars) emit
---continuation lines indented further.
---@param v any
---@param indent string
---@return string
encode_value = function(v, indent)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    -- Preserve integers vs. floats faithfully.
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return tostring(math.floor(v))
    end
    return tostring(v)
  elseif t == "string" then
    if v:find("\n") then
      return emit_block_scalar(v, indent)
    end
    if needs_quoting(v) then
      return quote(v)
    end
    return v
  elseif t == "table" then
    if next(v) == nil then
      -- Empty table: emit as flow-style empty sequence. Callers that
      -- want to omit empty fields entirely should check before
      -- emitting.
      return "[]"
    end
    if is_sequence(v) then
      local child_indent = indent
      local lines = {}
      for _, item in ipairs(v) do
        if type(item) == "table" and next(item) ~= nil then
          -- List of mappings — first key inline after `- `, rest at
          -- two-space indent under it.
          local item_indent = child_indent .. "  "
          local keys = sorted_keys(item)
          local first_key = keys[1]
          local first_value = encode_value(item[first_key], item_indent)
          lines[#lines + 1] = child_indent .. "- " .. first_key .. ": " .. first_value
          for i = 2, #keys do
            local k = keys[i]
            lines[#lines + 1] = item_indent .. k .. ": " .. encode_value(item[k], item_indent)
          end
        else
          lines[#lines + 1] = child_indent .. "- " .. encode_value(item, child_indent .. "  ")
        end
      end
      return "\n" .. table.concat(lines, "\n")
    else
      -- Mapping.
      local child_indent = indent .. "  "
      local lines = {}
      for _, k in ipairs(sorted_keys(v)) do
        local val = v[k]
        local emitted = encode_value(val, child_indent)
        if type(val) == "table" and next(val) ~= nil then
          -- Nested mapping/sequence: key on its own line, body on next.
          lines[#lines + 1] = child_indent .. k .. ":" .. emitted
        else
          lines[#lines + 1] = child_indent .. k .. ": " .. emitted
        end
      end
      return "\n" .. table.concat(lines, "\n")
    end
  else
    error("yaml.encode: cannot serialize value of type " .. t)
  end
end

---Encode a Lua table to a YAML string. Output has alphabetical key
---ordering; the schema-aware writer in `auto-core.todo.task_writer`
---(task 4) layers section headers + canonical field order on top.
---
---The output starts at column 0 (no leading indent) so the result is
---a complete YAML document ready to write to disk.
---@param t any
---@return string
function M.encode(t)
  local body = encode_value(t, "")
  -- For top-level tables, encode_value returns a string beginning with
  -- `\n` followed by the indented body. Strip that leading newline.
  if body:sub(1, 1) == "\n" then
    body = body:sub(2)
  end
  return body .. "\n"
end

return M