---Markdown + YAML-frontmatter encode/decode for auto-core todo tasks
---(ADR-0031 §2, MD pivot per the 2026-05-26 release note).
---
---Wire format per task:
---
---  ```
---  ---
---  <YAML frontmatter — structured fields>
---  ---
---
---  <!-- canonical header HTML comment -->
---
---  # <title>
---
---  <description — free-form markdown body>
---  ```
---
---Frontmatter parsing reuses `auto-core.todo.yaml` (strict-subset
---decoder). The body sits below the closing `---` and is treated
---verbatim modulo:
---  • a single leading H1 `# <title>` is stripped on decode (it is
---    a duplicate of the frontmatter title for Obsidian-native
---    display), and re-emitted on encode
---  • the canonical HTML-comment header (`<!-- … -->`) is stripped
---    on decode and re-emitted on encode
---
---This module is the second wire format auto-core ships — the first
---was pure YAML (v0.2.0, never released; preserved in this branch's
---history as design audit trail).
---@module 'auto-core.todo.md'

local yaml   = require("auto-core.todo.yaml")
local header = require("auto-core.todo.header")

local M = {}

-- ─── canonical frontmatter field order ────────────────────────
--
-- Hand-editable + content-required first (humans skim the top of
-- the file); managed fields second; auto-managed errors[] last.
-- This is purely an emission convention — decoders accept any
-- ordering because YAML mappings are unordered.

local FRONTMATTER_ORDER = {
  -- Hand-editable: identity + status / lifecycle
  "id",
  "version",
  "status",
  "title",
  "due",
  "priority",
  "assignee",
  "tags",

  -- Hand-editable: references
  "adr",
  "review",
  "blocked",

  -- Hand-editable: automation (ADR-0035 Phase 1 — required-iff-automated).
  -- Placed BEFORE the managed timestamp block so a template author
  -- sees `condition:` / `execute:` near the top of the file where
  -- they live operationally, not buried below the lifecycle TS.
  "condition",
  "execute",

  -- Managed: timestamps
  "created",
  "updated",
  "status_changed",
  "completed_at",
  "archived_at",

  -- Managed: automation (ADR-0035 Phase 1). `origin` is set on
  -- clones; `last_fired_at` is set on templates.
  "origin",
  "last_fired_at",

  -- Auto-managed
  "errors",
}

-- (FRONTMATTER_ORDER doubles as the membership check via the
-- ordered_frontmatter_pairs walker — no separate set needed.)

-- ─── decode ───────────────────────────────────────────────────

---Split a source string into (frontmatter_text, body_text). Returns
---(nil, "no-frontmatter") when the file doesn't open with `---`.
---@param src string
---@return string? fm, string? body, string? err
local function split_frontmatter(src)
  if src:sub(1, 4) ~= "---\n" and src:sub(1, 4) ~= "---\r" then
    return nil, nil, "missing opening `---` frontmatter delimiter"
  end
  -- Find the closing `---` on its own line. Tolerate `\r\n` and `\n`.
  local close_s, close_e = src:find("\n%-%-%-\n", 4)
  if not close_s then
    close_s, close_e = src:find("\n%-%-%-\r\n", 4)
  end
  if not close_s then
    -- Special case: file ends with `---` on a final line, no trailing newline.
    local tail_s = src:find("\n%-%-%-$", 4)
    if tail_s then
      return src:sub(5, tail_s - 1), "", nil
    end
    return nil, nil, "missing closing `---` frontmatter delimiter"
  end
  local fm   = src:sub(5, close_s - 1)
  local body = src:sub(close_e + 1)
  return fm, body, nil
end

---Strip the canonical HTML-comment header (if present) and a leading
---H1 line from the body. Returns the cleaned body (the description).
---Also trims trailing newlines — the file's trailing newline is
---structural, not part of the description content.
---@param body string
---@return string description
local function clean_body(body)
  -- Strip the HTML-comment header block. Match the canonical opener
  -- and closer; any intervening lines are part of the comment.
  body = body:gsub("<!%-%- ─── auto%-core%.todo schema v1.-─── %-%->%s*\n?", "", 1)
  -- Strip a single leading H1. Allow any amount of leading blank
  -- whitespace and require it to be the first non-blank content.
  body = body:gsub("^%s*#%s+[^\n]*\n?", "", 1)
  -- Trim leading blank lines (cosmetic spacing between header/H1
  -- and the description) and the structural trailing newline at
  -- the end of the file. The user's prose body is preserved
  -- verbatim between these trims.
  body = body:gsub("^\n+", ""):gsub("\n+$", "")
  return body
end

---Decode a MD+frontmatter source string into a Lua task table.
---Return shape mirrors `yaml.decode`: `{ ok, value?, err? }`.
---@param src string
---@return { ok: boolean, value: table?, err: string? }
function M.decode(src)
  if type(src) ~= "string" then
    return { ok = false, err = "md.decode: source must be a string, got " .. type(src) }
  end

  local fm, body, split_err = split_frontmatter(src)
  if not fm then
    return { ok = false, err = "md.decode: " .. tostring(split_err) }
  end

  local fm_decoded = yaml.decode(fm)
  if not fm_decoded.ok then
    return { ok = false, err = "md.decode: frontmatter " .. tostring(fm_decoded.err) }
  end
  local task = fm_decoded.value
  if type(task) ~= "table" then
    return { ok = false, err = "md.decode: frontmatter is not a mapping" }
  end

  -- Body → description. Empty body is fine (some tasks may have only
  -- structured metadata at first); description defaults to "" so the
  -- schema's required-field check still passes (per schema.lua,
  -- description is required but may be empty).
  task.description = clean_body(body or "")

  -- v0.1.39: tolerant-reader coercion for list-of-string fields.
  -- The schema requires `tags`, `adr`, `review`, and `blocked` to be YAML
  -- sequences (`- item`), but a human writing one entry naturally
  -- types it as a scalar:
  --
  --     adr: shared/adrs/0031-foo.md
  --
  -- Pre-v0.1.39 this caused the task to render with `errors[]: not-
  -- found` (validator iterated the string character by character) or
  -- — post-v0.1.38 — disappear into the panel's malformed section
  -- with a cryptic message. Neither tells the user "wrap it in `-`".
  -- We bridge the gap on read: any non-empty scalar string in one of
  -- these slots is wrapped into a 1-element list. The next write
  -- (via M.encode) will normalize it to the canonical list form.
  -- Genuinely-broken values (numbers, booleans, mappings) flow
  -- through unchanged and hit the schema's improved error message.
  local LIST_FIELDS = { "tags", "adr", "review", "blocked" }
  for _, k in ipairs(LIST_FIELDS) do
    local v = task[k]
    if type(v) == "string" and v ~= "" then
      task[k] = { v }
    end
  end

  return { ok = true, value = task }
end

-- ─── encode ───────────────────────────────────────────────────

---Take an arbitrary Lua task table and return a new table containing
---only the known frontmatter fields, preserving the canonical order.
---Fields not in FRONTMATTER_KEY are dropped from the frontmatter
---(notably `description`, which lives in the body, not the
---frontmatter). Empty lists are omitted entirely so they don't
---churn the file with `field: []` on every refresh.
---@param task table
---@return table[] ordered_pairs   list of {k, v} pairs in canonical order
local function ordered_frontmatter_pairs(task)
  local pairs_out = {}
  for _, k in ipairs(FRONTMATTER_ORDER) do
    local v = task[k]
    if v ~= nil then
      -- Omit empty lists from emission. (Empty mappings can't occur
      -- in our schema, so we don't check those here.)
      if type(v) == "table" and #v == 0 and next(v) == nil then
        -- skip
      else
        pairs_out[#pairs_out + 1] = { k, v }
      end
    end
  end
  return pairs_out
end

---YAML-encode a single value at a given indent. Strings get quoting
---when needed; lists go as block sequences; mappings (e.g. errors[]
---entries) go as inline-first-key block mappings under a dash.
---
---This is intentionally narrower than the generic
---`auto-core.todo.yaml.encode` because frontmatter scalars are
---usually one-liners and we want predictable, terse emission.
---@param v any
---@return string  frontmatter-friendly fragment (no leading indent)
local function encode_frontmatter_value(v)
  -- Reuse yaml.encode for everything; it handles strings, numbers,
  -- bools, nils, lists, and mappings consistently with the strict
  -- subset our parser accepts. gsub returns (string, count); we only
  -- want the string — wrap in parens to drop the count.
  return (yaml.encode({ __v__ = v }):gsub("^__v__:%s*", ""):gsub("\n$", ""))
end

---Emit the YAML frontmatter block (between two `---` delimiters)
---for a task table. Skips empty-list fields (no churn). Output
---includes the trailing newline after the closing `---`.
---@param task table
---@return string
local function emit_frontmatter(task)
  local lines = { "---" }
  for _, pair in ipairs(ordered_frontmatter_pairs(task)) do
    local k, v = pair[1], pair[2]
    -- For lists and mappings, yaml.encode of a single-key wrapper
    -- gives us the multiline block style; for scalars it gives a
    -- single line. Re-prepend `key:` ourselves so we control the
    -- ordering precisely.
    if type(v) == "table" then
      -- yaml.encode emits sequence/mapping starting with a `\n` then
      -- indented body. We embed it under `key:` on its own line.
      local body = yaml.encode({ [k] = v }):gsub("\n$", "")
      lines[#lines + 1] = body
    else
      lines[#lines + 1] = k .. ": " .. encode_frontmatter_value(v)
    end
  end
  lines[#lines + 1] = "---"
  return table.concat(lines, "\n") .. "\n"
end

---Encode a task table into the canonical MD+frontmatter wire format:
---frontmatter block, blank line, header HTML comment, blank line,
---H1, blank line, description body, trailing newline.
---@param task table
---@return string
function M.encode(task)
  local fm   = emit_frontmatter(task)
  local hdr  = header.emit()
  local h1   = "# " .. tostring(task.title or "(untitled)")
  local desc = task.description or ""

  -- Normalize trailing newline on description for clean emission.
  desc = desc:gsub("\n+$", "")

  local body_parts = { hdr, "", h1 }
  if desc ~= "" then
    body_parts[#body_parts + 1] = ""
    body_parts[#body_parts + 1] = desc
  end

  return fm .. "\n" .. table.concat(body_parts, "\n") .. "\n"
end

return M
