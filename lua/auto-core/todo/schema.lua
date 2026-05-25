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
M.VALID_STATUS = {
  open      = true,
  completed = true,
  deferred  = true,
  archived  = true,
}

---@type table<string, true>
M.VALID_PRIORITY = {
  low    = true,
  normal = true,
  high   = true,
}

---@type table<string, true>
M.VALID_ERROR_CODE = {
  ["not-found"] = true,
}

-- Field-shape catalog. Drives both presence-checks and unknown-key
-- detection. Order is not semantically meaningful here (the canonical
-- writer in task-writer.lua owns ordering).
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
  priority       = { required = false, kind = "priority" },
  assignee       = { required = false, kind = "string_or_null" },
  tags           = { required = false, kind = "string_list" },
  notes          = { required = false, kind = "string"   },

  -- Hand-editable references
  adr            = { required = false, kind = "string_list" },
  wip            = { required = false, kind = "string_or_null" },
  pr             = { required = false, kind = "string_list" },
  review         = { required = false, kind = "string_or_null" },
  links          = { required = false, kind = "string_list" },
  blocked        = { required = false, kind = "string_list" },

  -- Auto-managed
  errors         = { required = false, kind = "error_list" },
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
  return false, "expected status ∈ {open,completed,deferred,archived}, got " .. tostring(v)
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
---@param v any
---@return boolean ok, string? err
local function is_string_list(v)
  if v == nil then return true end
  if type(v) ~= "table" then
    return false, "expected list of strings, got " .. type(v)
  end
  -- Reject mappings (non-integer keys) up front.
  for k in pairs(v) do
    if type(k) ~= "number" then
      return false, "expected list (integer-keyed), got mapping (key " .. tostring(k) .. ")"
    end
  end
  for i, item in ipairs(v) do
    if type(item) ~= "string" then
      return false, "list item [" .. i .. "] is " .. type(item) .. ", expected string"
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
  string_or_null    = is_string_or_null,
  status            = is_status,
  priority          = is_priority,
  string_list       = is_string_list,
  error_list        = is_error_list,
}

-- ── cross-field invariants ────────────────────────────────────

---Lifecycle-timestamp rules per ADR-0031 §2:
---  • status == 'open'      → completed_at must be nil, archived_at must be nil
---  • status == 'deferred'  → completed_at must be nil, archived_at must be nil
---  • status == 'completed' → completed_at must be set, archived_at must be nil
---  • status == 'archived'  → archived_at must be set; completed_at MAY be set
---    (preserved from a prior completed→archived transition so the
---    "when was this done vs. archived" history isn't lost)
---@param t table
---@return boolean ok, string? err
local function lifecycle_consistency(t)
  local s = t.status

  if s == "open" or s == "deferred" then
    if t.completed_at ~= nil then
      return false, "completed_at must be nil when status == '" .. s .. "'"
    end
    if t.archived_at ~= nil then
      return false, "archived_at must be nil when status == '" .. s .. "'"
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
