---Import handlers for the auto-core todo task store (ADR-0031 §3.4).
---
---v1 supports three source kinds:
---  • `kb-todo-list`     — KB markdown identified by inline `**Tags:**
---                          type:todo-list`. Reads the file as a SINGLE
---                          task, deriving title/status from the H1
---                          and inline status atom respectively. Full
---                          markdown lands in the description body so
---                          nothing is lost across the migration.
---  • `legacy-todos-md`  — Compatibility subset of `kb-todo-list` for
---                          the superseded `*-todos.md` filename glob.
---                          Same parsing path; differentiated only by
---                          the `kind:` tag we attach.
---
---All importers return a list of `{spec, id?}` entries. With
---`dry_run = true`, `id` is nil and no writes happen. Otherwise each
---spec is fed to `auto-core.todo.add` and the resulting id is
---attached.
---@module 'auto-core.todo.import'

local fs_path = require("auto-core.fs.path")

local M = {}

-- ── helpers ─────────────────────────────────────────────────

---@param path string
---@return string? text, string? err
local function read_file(path)
  local fd, open_err = vim.uv.fs_open(path, "r", 0)
  if not fd then return nil, "fs_open: " .. tostring(open_err) end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    pcall(vim.uv.fs_close, fd)
    return nil, "fs_fstat failed"
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  pcall(vim.uv.fs_close, fd)
  if not data then return nil, "fs_read failed" end
  return data
end

---Strip a YAML frontmatter block at the start of a markdown source,
---if present. The block is opened by `---` on line 1 and closed by
---the next `---` on its own line. Returns the body that follows,
---or the original `md` unchanged when no frontmatter is detected.
---@param md string
---@return string body
local function strip_frontmatter(md)
  local first_nl = md:find("\n", 1, true)
  if not first_nl then return md end
  local first_line = md:sub(1, first_nl - 1)
  if first_line ~= "---" then return md end
  -- Find the closing `---` on its own line.
  local close_pat = "\n%-%-%-\n"
  local s, e = md:find(close_pat, first_nl)
  if not s then
    -- Unterminated frontmatter — fall through and treat as body.
    return md
  end
  return md:sub(e + 1)
end

---Extract the first H1 (`# Title`) from a markdown source. Returns
---nil if no H1 is found. Frontmatter (if any) is stripped first.
---@param md string
---@return string?
local function extract_h1(md)
  md = strip_frontmatter(md)
  for line in md:gmatch("[^\n]+") do
    local title = line:match("^#%s+(.+)$")
    if title then
      return title:gsub("%s+$", "")
    end
  end
  return nil
end

---Pull out the first non-blank paragraph following the H1 (or from
---the top if no H1). Stops at the first blank line. Used as the
---YAML task `description`. Frontmatter (if any) is stripped first.
---@param md string
---@return string
local function extract_first_paragraph(md)
  md = strip_frontmatter(md)
  local lines = vim.split(md, "\n", { plain = true })
  local seen_h1 = false
  local buf = {}
  for _, line in ipairs(lines) do
    if not seen_h1 and line:match("^#%s+") then
      seen_h1 = true
    elseif seen_h1 or not line:match("^#") then
      if line:match("^%s*$") then
        if #buf > 0 then break end
      elseif line:match("^%*%*Tags:%*%*") or line:match("^%*%*Abstract:%*%*") then
        -- Skip the structured "Tags" / "Abstract" inline metadata lines.
      else
        buf[#buf + 1] = line
      end
    end
  end
  return table.concat(buf, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
end

---Parse the inline `**Tags:**` line for this doc's atoms. Returns a
---table containing every `key:value` atom found (e.g. `type:todo-list`,
---`status:open`, `owner:shared`). Atom values are strings; missing
---tag line returns an empty table.
---@param md string
---@return table<string, string>
local function extract_inline_tags(md)
  local atoms = {}
  for line in md:gmatch("[^\n]+") do
    -- Match `**Tags:**` somewhere in the line (it's typically the
    -- second line after the H1).
    if line:match("%*%*Tags:%*%*") then
      -- Each tag is wrapped in backticks: `key:value` `key2:value2`.
      for atom in line:gmatch("`([^`]+)`") do
        local k, v = atom:match("^([^:]+):(.+)$")
        if k and v then atoms[k] = v end
      end
      break
    end
  end
  return atoms
end

---Map an inline `status:<x>` atom from a KB todo doc to the
---corresponding YAML schema status. The mapping covers the
---vocabulary that real-world KBs use, not just the ADR's
---canonical set:
---  open                      → open
---  blocked                   → deferred
---  closed | completed | done | resolved | superseded
---                            → completed
---  deferred | paused | wip   → deferred
---Anything else (including absent) → open.
---
---Background (v0.1.42): the ADR §6 table only documented
---`open / blocked / closed`. Real KBs accumulated other status
---atoms over time (`completed`, `resolved`, `done`, etc.) —
---these all SHOULD have mapped to `completed` (the YAML schema
---name), but the original `kb_status_to_schema` defaulted them
---to `open` and the corresponding docs migrated into the wrong
---bucket. The expanded vocabulary fixes that without breaking
---existing classifications (`closed` still maps to completed).
---@param atom string?
---@return string status
local function kb_status_to_schema(atom)
  if atom == "open"       then return "open"      end
  if atom == "closed"     then return "completed" end
  if atom == "completed"  then return "completed" end
  if atom == "done"       then return "completed" end
  if atom == "resolved"   then return "completed" end
  if atom == "superseded" then return "completed" end
  if atom == "blocked"    then return "deferred"  end
  if atom == "deferred"   then return "deferred"  end
  if atom == "paused"     then return "deferred"  end
  if atom == "wip"        then return "deferred"  end
  return "open"
end

-- ── kb-todo-list / legacy-todos-md parsers ──────────────────

---Parse one KB markdown source into a single task spec.
---@param md string         the file contents
---@param source string     absolute path of the source (for provenance)
---@param kind string       'kb-todo-list' or 'legacy-todos-md'
---@return table spec
local function parse_kb_todo(md, source, kind)
  local title  = extract_h1(md) or fs_path.basename(source):gsub("%.md$", "")
  local desc   = extract_first_paragraph(md)
  local atoms  = extract_inline_tags(md)
  local status = kb_status_to_schema(atoms.status)

  -- Build tag list: provenance + any KB atom we want to preserve. We
  -- intentionally don't slurp every KB atom (those are KB conventions,
  -- not task-system tags) — just `owner:<x>` and `repo:<x>` as those
  -- carry through useful per-task filtering.
  local tags = { "imported", "kind:" .. kind }
  if atoms.owner then tags[#tags + 1] = "owner:" .. atoms.owner end
  if atoms.repo  then tags[#tags + 1] = "repo:"  .. atoms.repo  end

  -- Description body. Per the v0.1.36 schema, there's no separate
  -- `notes:` field — everything imported lives in the markdown
  -- description body. We compose:
  --   • the source's first paragraph (or title fallback) as the
  --     visible lede, then
  --   • a horizontal rule, then
  --   • a provenance line citing the source path + import time, and
  --   • the full original markdown for losslessness.
  local lede = desc ~= "" and desc or title
  local provenance = "Imported from `" .. source .. "` on "
    .. os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()) .. "."
  local description = lede .. "\n\n---\n\n"
    .. provenance .. "\n\n"
    .. "## Original source\n\n"
    .. md

  return {
    title       = title,
    description = description,
    status      = status,
    tags        = tags,
  }
end

-- ── public entry point ──────────────────────────────────────

local VALID_KINDS = {
  ["kb-todo-list"]    = true,
  ["legacy-todos-md"] = true,
  -- `asana-json` was previously stubbed here. Removed because the
  -- `/asana-sync` skill writes a single multi-task markdown file
  -- directly into the KB (per the skill's existing convention),
  -- not a per-task JSON dump. There is no per-task import path
  -- from Asana; users curate the synced doc and create individual
  -- tasks via `M.add()` or the auto-finder panel as needed.
}

---Import an external todo source. `opts.source` may be passed via
---the first argument (file path) for convenience.
---
---  opts.kind     — 'kb-todo-list' | 'legacy-todos-md'
---  opts.dry_run  — boolean; when true, return planned specs without
---                  writing anything to disk
---
---Returns a list of `{spec, id?}` entries. `id` is the result of
---`auto-core.todo.add(spec)` (nil for dry_run or for failed adds).
---@param source string         path to the source file
---@param opts table?
---@return table[] results
function M.import(source, opts)
  opts = opts or {}
  local kind = opts.kind or "kb-todo-list"

  if not VALID_KINDS[kind] then
    error("auto-core.todo.import: unknown kind '" .. tostring(kind)
      .. "' (valid: kb-todo-list, legacy-todos-md)")
  end

  if type(source) ~= "string" or source == "" then
    error("auto-core.todo.import: source path must be a non-empty string")
  end

  if not fs_path.exists(source) then
    error("auto-core.todo.import: source '" .. source .. "' does not exist")
  end

  local md, read_err = read_file(source)
  if not md then
    error("auto-core.todo.import: " .. tostring(read_err))
  end

  -- Both `kb-todo-list` and `legacy-todos-md` share the same parser.
  local spec = parse_kb_todo(md, source, kind)

  local results = { { spec = spec } }

  if not opts.dry_run then
    local todo = require("auto-core.todo")
    local ok, id_or_err = pcall(todo.add, spec)
    if ok then
      results[1].id = id_or_err
    else
      results[1].error = tostring(id_or_err)
    end
  end

  return results
end

return M
