---Schema v1 validator for the auto-core todo task store.
---
---Operates on a decoded task table (the result of `yaml.decode(...).value`).
---Returns `{ ok = true }` on success or `{ ok = false, err = <string>,
---field = <string>? }` on rejection.
---
---Reference: ADR-0031 §2 (schema v1) and the bootstrap todo Phase 1.2.
---@module 'auto-core.todo.schema'

local M = {}

M.VERSION = 1

---@type table<string, true>
---
---ADR-0035 extends this enum from the original four (ADR-0031) to six:
---  - `in-progress` — task is being actively worked on. Auto-engaged
---    by `M.assign()` on `open → in-progress` when an open task gets
---    a non-nil assignee (atomic same-write-path).
---  - `automated` — template task; never transitions on its own.
---    Lives in `.todo-list/automated/`; consumed by the automation
---    engine (Phase 2) which clones it on each condition match.
M.VALID_STATUS = {
  open            = true,
  ["in-progress"] = true,   -- ADR-0035 Phase 1
  automated       = true,   -- ADR-0035 Phase 1 (engine in Phase 2)
  completed       = true,
  deferred        = true,
  archived        = true,
}

---@type table<string, true>
M.VALID_PRIORITY = {
  low    = true,
  normal = true,
  high   = true,
}

---@type table<string, true>
M.VALID_ERROR_CODE = {
  ["not-found"]                    = true,
  ["unresolved-variable"]          = true,  -- v0.1.40: `$VAR/...` ref whose VAR has no resolver
  ["automation-template-assignee"] = true,  -- ADR-0035 §3: automated templates must not carry a top-level assignee
  ["automation-origin-not-found"]  = true,  -- ADR-0035 §5.5: clone's `origin:` doesn't resolve to a live automated template
  ["automation-condition-malformed"] = true, -- ADR-0035 §12: cron-or-event parse failure
  ["automation-execute-malformed"] = true,  -- ADR-0035 §8: execute DSL parse failure
  -- ADR-0035 Phase 2 + Lector F2 amendment: codes produced by
  -- `auto-core.todo.automation` at fire-time, written to the clone's
  -- `errors[]` via the managed-field write helper. Without them in
  -- this catalog, schema.validate rejects clones whose execute steps
  -- failed and `todo.get()` returns nil — which masks the audit trail.
  ["automation-step-failed"]         = true,  -- generic step failure (catches every fire-time error)
  ["automation-bash-disabled"]       = true,  -- bash step refused: workspace trust gate off (§4.5)
  ["automation-bash-not-allowlisted"] = true, -- bash step refused: doesn't match `bash_allowlist` (§4.5)
  ["automation-bash-t-no-resolver"]  = true,  -- `bash -t=N` step but no auto-agents executor registered
  ["automation-bash-t-range"]        = true,  -- `bash -t=N` step with N out of 1..MAX_SLOTS (4)
  ["automation-bash-t-slot-admin"]   = true,  -- reserved (was used pre-floating-terminal correction; kept for cross-version migration)
  ["automation-slot-no-resolver"]    = true,  -- `assign slot:N` but no auto-agents hook registered
}

-- Field-shape catalog. Drives both presence-checks and unknown-key
-- detection. Order is not semantically meaningful here (the canonical
-- writer in md.lua owns ordering).
local FIELDS = {
  -- Managed (required, system-owned)
  id             = { required = true,  kind = "string"   },
  version        = { required = true,  kind = "integer"  },
  created        = { required = true,  kind = "datetime" },
  updated        = { required = true,  kind = "datetime" },
  status_changed = { required = true,  kind = "datetime" },
  status         = { required = true,  kind = "status"   },

  -- Conditionally-required lifecycle timestamps. Presence rule
  -- enforced in lifecycle_consistency() below.
  completed_at   = { required = false, kind = "datetime_or_null" },
  archived_at    = { required = false, kind = "datetime_or_null" },

  -- Hand-editable content
  title          = { required = true,  kind = "string"   },
  description    = { required = true,  kind = "string"   },
  due            = { required = false, kind = "date_or_null"   },
  priority       = { required = false, kind = "priority" },
  assignee       = { required = false, kind = "string_or_null" },
  tags           = { required = false, kind = "string_list" },

  -- Hand-editable references (paths checked by refresh)
  adr            = { required = false, kind = "string_list" },
  review         = { required = false, kind = "string_list" },
  blocked        = { required = false, kind = "string_list" },

  -- ADR-0035 §5.5: automation fields. Hand-editable on templates;
  -- shape-validated here (Phase 1). Deep content validation (cron
  -- syntax, execute-DSL prefix match) lands in Phase 2 via
  -- `auto-core.todo.automation.validate(task)` and gets surfaced as
  -- `errors[]` entries by `refresh()`. Required-when invariants
  -- (must be present iff `status == automated`) enforced in
  -- `lifecycle_consistency()`.
  condition      = { required = false, kind = "string_list" },
  execute        = { required = false, kind = "string_list" },

  -- ADR-0035 §5.5: managed automation fields.
  --   `origin`         — clone backref to the automated template id.
  --                      Resolution check (must point at a live
  --                      automated template in the same `.todo-list/`)
  --                      runs in `refresh()`; schema only validates
  --                      shape here.
  --   `last_fired_at`  — template-only timestamp of the most recent
  --                      clone-fire. Datetime.
  origin         = { required = false, kind = "string_or_null" },
  last_fired_at  = { required = false, kind = "datetime_or_null" },

  -- Auto-managed
  errors         = { required = false, kind = "error_list" },

  -- Note (v0.1.36): `wip`, `pr`, `links`, `notes` are removed from
  -- the structured schema. Free-form working-dir references, PR
  -- URLs, doc links, and scratch notes all live in the markdown
  -- body (the `description` field's content) where they read more
  -- naturally and are not required by auto-finder. auto-finder
  -- consumes only the frontmatter for panel rendering.
}

-- ── kind validators ───────────────────────────────────────────

---@param v any
---@return boolean ok, string? err
local function is_string(v)
  if type(v) == "string" then return true end
  return false, "expected string, got " .. type(v)
end

---@param v any
---@return boolean ok, string? err
local function is_integer(v)
  if type(v) == "number" and v == math.floor(v) then return true end
  return false, "expected integer, got " .. type(v)
end

---ISO 8601 datetime with offset. Required: YYYY-MM-DDTHH:MM:SS<Z|±HH:MM>.
---Fractional seconds optional.
---@param v any
---@return boolean ok, string? err
local function is_datetime(v)
  if type(v) ~= "string" then
    return false, "expected ISO 8601 datetime string, got " .. type(v)
  end
  -- Accept either trailing Z or ±HH:MM offset.
  local pat = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.%d]*[Z+%-]"
  if not v:match(pat) then
    return false, "string '" .. v .. "' does not look like an ISO 8601 datetime with offset"
  end
  return true
end

---@param v any
---@return boolean ok, string? err
local function is_datetime_or_null(v)
  if v == nil then return true end
  return is_datetime(v)
end

---Bare ISO 8601 date in `YYYY-MM-DD` form. Used for the `due` field
---where time-of-day isn't meaningful. Distinguished from `datetime`
---which requires a `T` separator and timezone offset.
---@param v any
---@return boolean ok, string? err
local function is_date_or_null(v)
  if v == nil then return true end
  if type(v) ~= "string" then
    return false, "expected YYYY-MM-DD date string, got " .. type(v)
  end
  if not v:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return false, "string '" .. v .. "' is not a bare YYYY-MM-DD date "
      .. "(use datetime form only for created/updated/etc.)"
  end
  return true
end

---@param v any
---@return boolean ok, string? err
local function is_string_or_null(v)
  if v == nil then return true end
  return is_string(v)
end

---@param v any
---@return boolean ok, string? err
local function is_status(v)
  if type(v) == "string" and M.VALID_STATUS[v] then return true end
  return false, "expected status ∈ {open,in-progress,automated,completed,deferred,archived}, got " .. tostring(v)
end

---@param v any
---@return boolean ok, string? err
local function is_priority(v)
  if v == nil then return true end
  if type(v) == "string" and M.VALID_PRIORITY[v] then return true end
  return false, "expected priority ∈ {low,normal,high}, got " .. tostring(v)
end

---Sequence of strings. Empty table is allowed (but the writer omits
---empty list-fields entirely; this validator accepts either form).
---
---Educational error messages (v0.1.39): tolerant-reader coercion in
---md.lua already wraps a scalar STRING into a 1-element list, so a
---bare string never reaches this validator. The remaining failure
---modes are numbers, booleans, or mappings — none of which can be
---auto-coerced without guessing intent. The error string includes
---the canonical YAML list form as a hint so the user knows how to
---repair the file.
---@param v any
---@return boolean ok, string? err
local function is_string_list(v)
  if v == nil then return true end

  local LIST_HINT =
    " — use the YAML list form, one entry per line:\n"
    .. "    field:\n"
    .. "      - first-entry\n"
    .. "      - second-entry\n"
    .. "  (a single entry is fine — just one `- ` line)"

  if type(v) ~= "table" then
    return false,
      "expected list of strings, got " .. type(v) .. " (`"
        .. tostring(v) .. "`)" .. LIST_HINT
  end

  -- Reject mappings (non-integer keys) up front.
  for k in pairs(v) do
    if type(k) ~= "number" then
      return false,
        "expected list (integer-keyed sequence), got mapping with key '"
          .. tostring(k) .. "'" .. LIST_HINT
    end
  end

  for i, item in ipairs(v) do
    if type(item) ~= "string" then
      return false,
        "list item [" .. i .. "] is " .. type(item)
          .. " (`" .. tostring(item) .. "`), expected string"
          .. LIST_HINT
    end
  end
  return true
end

---List of {field, code, message, detected} maps. Auto-managed.
---@param v any
---@return boolean ok, string? err
local function is_error_list(v)
  if v == nil then return true end
  if type(v) ~= "table" then
    return false, "errors: expected list of {field,code,message,detected}, got " .. type(v)
  end
  for k in pairs(v) do
    if type(k) ~= "number" then
      return false, "errors: expected list, got mapping (key " .. tostring(k) .. ")"
    end
  end
  for i, entry in ipairs(v) do
    if type(entry) ~= "table" then
      return false, "errors[" .. i .. "]: expected map, got " .. type(entry)
    end
    if type(entry.field) ~= "string" then
      return false, "errors[" .. i .. "].field: expected string, got " .. type(entry.field)
    end
    if type(entry.code) ~= "string" or not M.VALID_ERROR_CODE[entry.code] then
      return false, "errors[" .. i .. "].code: expected one of {not-found}, got " ..
        tostring(entry.code)
    end
    if type(entry.message) ~= "string" then
      return false, "errors[" .. i .. "].message: expected string, got " .. type(entry.message)
    end
    local ok_dt, dt_err = is_datetime(entry.detected)
    if not ok_dt then
      return false, "errors[" .. i .. "].detected: " .. dt_err
    end
    -- Reject unknown keys within each error entry.
    for ek in pairs(entry) do
      if ek ~= "field" and ek ~= "code" and ek ~= "message" and ek ~= "detected" then
        return false, "errors[" .. i .. "]: unknown key '" .. tostring(ek) .. "'"
      end
    end
  end
  return true
end

local KIND_VALIDATORS = {
  string            = is_string,
  integer           = is_integer,
  datetime          = is_datetime,
  datetime_or_null  = is_datetime_or_null,
  date_or_null      = is_date_or_null,
  string_or_null    = is_string_or_null,
  status            = is_status,
  priority          = is_priority,
  string_list       = is_string_list,
  error_list        = is_error_list,
}

-- ── cross-field invariants ────────────────────────────────────

---Lifecycle-timestamp rules per ADR-0031 §2 + ADR-0035 §1:
---  • status == 'open'         → completed_at must be nil, archived_at must be nil
---  • status == 'in-progress'  → completed_at must be nil, archived_at must be nil
---  • status == 'automated'    → completed_at must be nil, archived_at must be nil;
---                               last_fired_at MAY be set; `assignee` MUST be nil
---                               (templates are inert — see ADR-0035 §3); when
---                               `assignee` is set, schema rejects with the
---                               `automation-template-assignee` error code shape
---                               so `refresh()` can surface it via `errors[]`.
---  • status == 'deferred'     → completed_at must be nil, archived_at must be nil
---  • status == 'completed'    → completed_at must be set, archived_at must be nil
---  • status == 'archived'     → archived_at must be set; completed_at MAY be set
---    (preserved from a prior completed→archived transition so the
---    "when was this done vs. archived" history isn't lost)
---
---Cross-field invariants for automation fields (ADR-0035 §5.5):
---  • status == 'automated'    → `condition[]` and `execute[]` SHOULD be present
---                               (an empty/missing template can't fire, but the
---                                schema permits it so users can stub a template
---                                before filling it in; the automation engine
---                                ignores empty templates).
---  • status != 'automated'    → `condition[]` and `execute[]` MUST be nil (those
---                               fields are meaningful only on templates).
---  • `origin` is permitted on clones (typically open/in-progress/completed
---    tasks born from a template fire) and forbidden on automated templates
---    themselves (a template firing produces a clone, not a back-pointer to
---    itself).
---  • `last_fired_at` MUST be nil unless `status == automated`.
---
---@param t table
---@return boolean ok, string? err
local function lifecycle_consistency(t)
  local s = t.status

  -- Lifecycle timestamps (open / in-progress / deferred share the
  -- "neither set" invariant; the three statuses are equivalent from
  -- a timestamp-presence standpoint).
  if s == "open" or s == "in-progress" or s == "deferred" then
    if t.completed_at ~= nil then
      return false, "completed_at must be nil when status == '" .. s .. "'"
    end
    if t.archived_at ~= nil then
      return false, "archived_at must be nil when status == '" .. s .. "'"
    end

  elseif s == "automated" then
    if t.completed_at ~= nil then
      return false, "completed_at must be nil when status == 'automated' (templates never complete)"
    end
    if t.archived_at ~= nil then
      return false, "archived_at must be nil when status == 'automated' (templates never archive)"
    end
    -- ADR-0035 §3: template-level assignee is rejected.
    if t.assignee ~= nil and t.assignee ~= "" then
      return false,
        "[automation-template-assignee] automated templates must not carry a top-level "
          .. "`assignee:` — templates are inert; use `execute: assign agent:<name>` instead"
    end
    if t.origin ~= nil then
      return false, "origin must be nil when status == 'automated' (templates aren't clones)"
    end

  elseif s == "completed" then
    if t.completed_at == nil then
      return false, "completed_at must be set when status == 'completed'"
    end
    if t.archived_at ~= nil then
      return false, "archived_at must be nil when status == 'completed'"
    end

  elseif s == "archived" then
    if t.archived_at == nil then
      return false, "archived_at must be set when status == 'archived'"
    end
    -- completed_at is permitted (preserved through the archive
    -- transition when the task was previously completed) but not
    -- required (a task can be archived directly from open/deferred
    -- if a human/agent explicitly chooses to).
  end

  -- Automation-field invariants (independent of the timestamp rules).
  if s ~= "automated" then
    if t.condition ~= nil then
      return false, "`condition:` is meaningful only when status == 'automated'; got status == '" .. s .. "'"
    end
    if t.execute ~= nil then
      return false, "`execute:` is meaningful only when status == 'automated'; got status == '" .. s .. "'"
    end
    if t.last_fired_at ~= nil then
      return false, "`last_fired_at:` is meaningful only when status == 'automated'; got status == '" .. s .. "'"
    end
  end

  return true
end

---Version must match the schema this validator knows about.
---@param t table
---@return boolean ok, string? err
local function version_match(t)
  if t.version ~= M.VERSION then
    return false, "schema version mismatch: validator is v" .. M.VERSION
      .. ", file declares v" .. tostring(t.version)
  end
  return true
end

-- ── public ────────────────────────────────────────────────────

---Validate a decoded task table against schema v1. Returns
---`{ ok = true }` on success or `{ ok = false, err = <string>,
---field = <string>? }` on failure.
---@param t any
---@return { ok: boolean, err: string?, field: string? }
function M.validate(t)
  if type(t) ~= "table" then
    return { ok = false, err = "expected task to be a mapping, got " .. type(t) }
  end

  -- Reject unknown top-level keys before doing anything expensive.
  for k in pairs(t) do
    if type(k) ~= "string" or not FIELDS[k] then
      return {
        ok    = false,
        field = tostring(k),
        err   = "unknown top-level key '" .. tostring(k) .. "' (schema v1 is closed)",
      }
    end
  end

  -- Presence + type for each known field.
  for name, spec in pairs(FIELDS) do
    local v = t[name]
    if v == nil then
      if spec.required then
        return { ok = false, field = name, err = "required field '" .. name .. "' is missing" }
      end
    else
      local validator = KIND_VALIDATORS[spec.kind]
      local ok, err = validator(v)
      if not ok then
        return { ok = false, field = name, err = name .. ": " .. err }
      end
    end
  end

  -- Cross-field invariants.
  local ok_v, err_v = version_match(t)
  if not ok_v then return { ok = false, field = "version", err = err_v } end

  local ok_lc, err_lc = lifecycle_consistency(t)
  if not ok_lc then return { ok = false, err = err_lc } end

  return { ok = true }
end

---Build a minimal valid v1 task table with the supplied overrides.
---Useful for tests + the writer's "blank task skeleton" emission.
---Required-but-content fields you must supply: `title`. Everything
---else defaults to a coherent open-status open task.
---@param overrides table
---@return table
function M.blank(overrides)
  overrides = overrides or {}
  local now = overrides.created or os.date("!%Y-%m-%dT%H:%M:%SZ")
  local id  = overrides.id      or (os.date("!%Y-%m-%d") .. "-untitled")
  local out = {
    id             = id,
    version        = M.VERSION,
    created        = now,
    updated        = now,
    status_changed = now,
    status         = "open",
    title          = "Untitled task",
    description    = "",
  }
  for k, v in pairs(overrides) do
    out[k] = v
  end
  return out
end

return M
