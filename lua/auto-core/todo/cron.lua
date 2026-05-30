---Hand-rolled 5-field cron parser for ADR-0035 Phase 2.
---
---Surface (intentionally constrained):
---  • 5 space-separated fields: minute hour day-of-month month day-of-week
---  • Per-field tokens: `*`, `N`, `N-M`, `N,M,P`, `*/STEP`, `N-M/STEP`
---  • Day-of-week ordinal `D#K` — fires on the Kth occurrence of weekday D
---    in the month (e.g. `2#1` = first Tuesday). Common in Quartz; the
---    user's brief uses it explicitly for "first Tuesday each month".
---
---Field ranges:
---  • minute      0..59
---  • hour        0..23
---  • day-of-month 1..31
---  • month       1..12
---  • day-of-week 0..6 (0 = Sunday, per ISO + Quartz; `7` accepted as
---    a Sunday alias for crontab compatibility)
---
---Out-of-scope (no consumers in ADR-0035; revisit only if requested):
---  • Named months (`JAN`/`FEB`) or named weekdays (`SUN`/`MON`)
---  • `?` placeholder
---  • Seconds field, year field
---  • `@hourly` / `@daily` / `@weekly` shorthand
---
---Reference: ADR-0035 §8 "Cron parser (OQ5 / must-fix #5): hand-rolled
---5-field grammar … No external dependency. Extensible later if grammar
---grows."
---@module 'auto-core.todo.cron'

local M = {}

local FIELDS = {
  { name = "minute",       lo = 0, hi = 59 },
  { name = "hour",         lo = 0, hi = 23 },
  { name = "day_of_month", lo = 1, hi = 31 },
  { name = "month",        lo = 1, hi = 12 },
  { name = "day_of_week",  lo = 0, hi = 6  },
}

---@param s string
---@return integer? n, string? err
local function to_int(s)
  local n = tonumber(s)
  if type(n) ~= "number" or n ~= math.floor(n) then
    return nil, "expected integer, got '" .. tostring(s) .. "'"
  end
  return n, nil
end

---Coerce day-of-week 7 → 0 (crontab Sunday alias). Idempotent for
---other values.
---@param dow integer
---@return integer
local function normalize_dow(dow)
  if dow == 7 then return 0 end
  return dow
end

---Parse a single field token into a `Spec` describing how to match.
---
---Spec shape (one of):
---  • { kind = "any" }                                  -- `*`
---  • { kind = "list",    values = {n, …} }             -- explicit set
---  • { kind = "step",    base = N, step = S }          -- `*/S` or `N-M/S`
---  • { kind = "dow_ordinal", dow = D, k = K }          -- `D#K` (day_of_week only)
---
---The `dow_ordinal` form is a separate kind because the match logic
---needs the actual calendar date, not just the weekday number.
---
---@param tok string
---@param field { name: string, lo: integer, hi: integer }
---@return table? spec, string? err
local function parse_token(tok, field)
  if tok == "*" then
    return { kind = "any" }, nil
  end

  -- day_of_week-only: `D#K` ordinal form (`2#1` = first Tuesday).
  if field.name == "day_of_week" and tok:find("#", 1, true) then
    local d, k = tok:match("^(%d+)#(%d+)$")
    if not d then
      return nil, "day_of_week ordinal must be `<weekday>#<occurrence>` (e.g. `2#1`), got '" .. tok .. "'"
    end
    local dow, err1 = to_int(d); if not dow then return nil, err1 end
    local kn,  err2 = to_int(k); if not kn  then return nil, err2 end
    dow = normalize_dow(dow)
    if dow < 0 or dow > 6 then
      return nil, "day_of_week in `D#K` out of range 0..6 (7 alias accepted), got " .. d
    end
    if kn < 1 or kn > 5 then
      return nil, "ordinal `K` in `D#K` must be 1..5, got " .. k
    end
    return { kind = "dow_ordinal", dow = dow, k = kn }, nil
  end

  -- Step form: `*/S` or `RANGE/S`.
  if tok:find("/", 1, true) then
    local left, step_s = tok:match("^(.-)/(%d+)$")
    if not left then
      return nil, "malformed step token '" .. tok .. "'"
    end
    local step, err = to_int(step_s); if not step then return nil, err end
    if step < 1 then return nil, "step must be >= 1 in '" .. tok .. "'" end

    local base_lo, base_hi
    if left == "*" then
      base_lo, base_hi = field.lo, field.hi
    elseif left:find("-", 1, true) then
      local a, b = left:match("^(%d+)-(%d+)$")
      if not a then return nil, "malformed step-range '" .. tok .. "'" end
      base_lo = to_int(a); base_hi = to_int(b)
    else
      base_lo = to_int(left); base_hi = field.hi
    end
    if not (base_lo and base_hi) then
      return nil, "malformed step base in '" .. tok .. "'"
    end
    if base_lo < field.lo or base_hi > field.hi or base_lo > base_hi then
      return nil, "step range out of bounds for " .. field.name .. " in '" .. tok .. "'"
    end

    local values = {}
    local v = base_lo
    while v <= base_hi do
      values[#values + 1] = (field.name == "day_of_week") and normalize_dow(v) or v
      v = v + step
    end
    return { kind = "list", values = values }, nil
  end

  -- Comma-separated list.
  if tok:find(",", 1, true) then
    local values = {}
    for piece in tok:gmatch("[^,]+") do
      local spec, err = parse_token(piece, field)
      if not spec then return nil, err end
      if spec.kind == "list" then
        for _, v in ipairs(spec.values) do values[#values + 1] = v end
      elseif spec.kind == "any" then
        return nil, "`*` cannot be combined inside a comma list ('" .. tok .. "')"
      else
        return nil, "complex sub-tokens (#-ordinals) cannot appear inside a comma list"
      end
    end
    return { kind = "list", values = values }, nil
  end

  -- Range `N-M`.
  if tok:find("-", 1, true) then
    local a, b = tok:match("^(%d+)-(%d+)$")
    if not a then return nil, "malformed range '" .. tok .. "'" end
    local lo, err1 = to_int(a); if not lo then return nil, err1 end
    local hi, err2 = to_int(b); if not hi then return nil, err2 end
    if field.name == "day_of_week" then
      lo = normalize_dow(lo); hi = normalize_dow(hi)
    end
    if lo < field.lo or hi > field.hi or lo > hi then
      return nil, "range " .. lo .. "-" .. hi .. " out of bounds for " .. field.name
    end
    local values = {}
    for v = lo, hi do values[#values + 1] = v end
    return { kind = "list", values = values }, nil
  end

  -- Bare integer.
  local n, err = to_int(tok); if not n then return nil, err end
  if field.name == "day_of_week" then n = normalize_dow(n) end
  if n < field.lo or n > field.hi then
    return nil, field.name .. " value " .. n .. " out of range " .. field.lo .. ".." .. field.hi
  end
  return { kind = "list", values = { n } }, nil
end

---Parse a full 5-field cron expression. Returns a parsed structure
---usable by `M.matches(parsed, ts_or_components)`, or `(nil, err)`.
---@param expr string
---@return table? parsed, string? err
function M.parse(expr)
  if type(expr) ~= "string" then
    return nil, "cron expression must be a string, got " .. type(expr)
  end
  local trimmed = expr:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return nil, "empty cron expression"
  end

  local toks = {}
  for piece in trimmed:gmatch("%S+") do toks[#toks + 1] = piece end
  if #toks ~= 5 then
    return nil, "cron expression must have exactly 5 fields (got " .. #toks
      .. ": '" .. expr .. "')"
  end

  local parsed = { _raw = expr }
  for i, field in ipairs(FIELDS) do
    local spec, err = parse_token(toks[i], field)
    if not spec then
      return nil, "field " .. i .. " (" .. field.name .. "): " .. err
    end
    parsed[field.name] = spec
  end
  return parsed, nil
end

---Tests whether `value` matches the spec for a single field.
---@param spec table
---@param value integer
---@return boolean
local function spec_contains(spec, value)
  if spec.kind == "any" then return true end
  if spec.kind == "list" then
    for _, v in ipairs(spec.values) do
      if v == value then return true end
    end
    return false
  end
  -- `dow_ordinal` is handled separately by the caller (needs the
  -- calendar date, not just the weekday); never reached here.
  return false
end

---For day-of-week ordinal `D#K`, return true iff the date specified
---by `(year, month, day, weekday)` is the Kth occurrence of weekday
---D in the month.
---@param spec { dow: integer, k: integer }
---@param year integer
---@param month integer
---@param day integer
---@param weekday integer  0=Sunday … 6=Saturday
---@return boolean
local function dow_ordinal_matches(spec, _year, _month, day, weekday)
  if weekday ~= spec.dow then return false end
  -- The Kth occurrence of weekday W in a month is at day numbers
  -- (offset+1), (offset+8), (offset+15), … where `offset` is the
  -- 0-based day-of-month of the first occurrence. We don't need
  -- `offset` directly — we just need to know that `day` is the
  -- Kth such occurrence:
  --   k = floor((day - 1) / 7) + 1
  local k = math.floor((day - 1) / 7) + 1
  return k == spec.k
end

---Build the date-time components table from a Lua `os.time()`-style
---epoch (or accept a pre-built `os.date("*t", …)` table verbatim).
---Returned components are zero/one-indexed per `os.date`:
---  year (4-digit), month (1..12), day (1..31), hour (0..23),
---  min (0..59), wday (1..7 — Sunday=1; we convert to 0..6 with
---  Sunday=0 for cron matching).
---@param ts integer|table
---@return { year:integer, month:integer, day:integer, hour:integer, min:integer, wday:integer }
local function components(ts)
  local t
  if type(ts) == "table" then
    t = ts
  else
    t = os.date("*t", ts)
  end
  -- os.date returns wday 1..7 with Sunday = 1; cron uses 0..6 with
  -- Sunday = 0.
  local cron_wday = (t.wday or 1) - 1
  return {
    year  = t.year,
    month = t.month,
    day   = t.day,
    hour  = t.hour,
    min   = t.min,
    wday  = cron_wday,
  }
end

---True iff the cron expression matches the moment described by
---`ts_or_components`.
---
---Day-of-month + day-of-week logic mirrors POSIX crontab semantics:
---  • If both fields are `*`, all days match.
---  • If exactly one of the two is restricted, that restriction
---    decides.
---  • If BOTH are restricted, the OR of the two matches (a day
---    satisfies the cron if it matches day_of_month OR day_of_week).
---    This is the historic POSIX behavior — diverges from strict AND
---    that some users intuit, but matches what `cron(8)` actually does.
---
---@param parsed table
---@param ts_or_components integer|table
---@return boolean
function M.matches(parsed, ts_or_components)
  local c = components(ts_or_components)

  if not spec_contains(parsed.minute, c.min)  then return false end
  if not spec_contains(parsed.hour,   c.hour) then return false end
  if not spec_contains(parsed.month,  c.month) then return false end

  local dom_spec = parsed.day_of_month
  local dow_spec = parsed.day_of_week
  local dom_any  = dom_spec.kind == "any"
  local dow_any  = dow_spec.kind == "any"

  local function dom_match() return spec_contains(dom_spec, c.day) end
  local function dow_match()
    if dow_spec.kind == "dow_ordinal" then
      return dow_ordinal_matches(dow_spec, c.year, c.month, c.day, c.wday)
    end
    return spec_contains(dow_spec, c.wday)
  end

  if dom_any and dow_any then return true end
  if dom_any and not dow_any then return dow_match() end
  if dow_any and not dom_any then return dom_match() end
  -- Both restricted — POSIX OR semantics.
  return dom_match() or dow_match()
end

---Convenience: parse + match in one call. Returns
---`(matched: boolean, err: string?)`.
---@param expr string
---@param ts_or_components integer|table
---@return boolean matched, string? err
function M.parse_and_match(expr, ts_or_components)
  local parsed, err = M.parse(expr)
  if not parsed then return false, err end
  return M.matches(parsed, ts_or_components), nil
end

return M