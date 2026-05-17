---auto-core.log.dumps — JSONL persistence for log-ring snapshots.
---
---Per ADR 0021 §7. Writes happen only on user demand via the
---`:AutoCoreLog` viewer's `E` binding — there is no background
---I/O, no periodic flush, no rotation. Files live under
---`stdpath('cache')/auto-core/dumps/` with names of the form
---`dump-<UTC-timestamp>.log` (dashes instead of colons in the
---timestamp so the filename is portable to Windows). The on-disk
---format is JSON Lines: one normalized log entry per line.
---
---Entries are normalized at export time. The in-memory `ts` slot is
---a monotonic millisecond value from `vim.uv.now()`; the ADR
---requires ISO 8601 UTC on disk because monotonic timestamps are
---session-relative and meaningless after restart. We approximate the
---wall-clock at-entry time as `now_wall - (now_mono - entry.ts)`,
---which is exact modulo whatever clock drift happened during the
---session (negligible for incident-triage purposes).
---@module 'auto-core.log.dumps'

local M = {}

-- ── paths ────────────────────────────────────────────────────

local function _dir()
  return vim.fn.stdpath("cache") .. "/auto-core/dumps"
end

---Absolute path to the dumps directory. Public for tests + viewer.
---@return string
function M.dir() return _dir() end

local function _ensure_dir()
  local d = _dir()
  if vim.fn.isdirectory(d) == 0 then
    vim.fn.mkdir(d, "p")
  end
  return d
end

-- ── ISO 8601 UTC helpers ─────────────────────────────────────

---ISO 8601 UTC timestamp. `with_colons = true` is the display form
---(`2026-05-17T08:42:31Z`); `false` is the filename-safe form
---(`2026-05-17T08-42-31Z`).
---@param epoch_seconds integer
---@param with_colons boolean
---@return string
local function _iso_utc(epoch_seconds, with_colons)
  local fmt = with_colons and "!%Y-%m-%dT%H:%M:%SZ" or "!%Y-%m-%dT%H-%M-%SZ"
  return os.date(fmt, epoch_seconds) --[[@as string]]
end
M._iso_utc = _iso_utc

---Convert a monotonic `ts` (ms) into an ISO 8601 UTC string given
---the snapshot's wall-clock anchor. Exposed so the viewer can apply
---the same conversion to live Memory entries without re-implementing
---the math.
---@param ts_mono_ms integer
---@param now_wall_s integer
---@param now_mono_ms integer
---@return string
function M.iso_from_mono(ts_mono_ms, now_wall_s, now_mono_ms)
  local entry_wall_ms = (now_wall_s * 1000) - (now_mono_ms - (ts_mono_ms or now_mono_ms))
  local entry_wall_s  = math.floor(entry_wall_ms / 1000)
  return _iso_utc(entry_wall_s, true)
end

-- ── normalization ────────────────────────────────────────────

---Replace each entry's monotonic `ts` with an ISO 8601 UTC `ts_iso`
---field, leaving every other slot intact. The returned table is a
---fresh array — input entries are not mutated.
---@param entries AutoCoreLogEntry[]
---@param now_wall_s integer
---@param now_mono_ms integer
---@return table[]
function M.normalize_for_disk(entries, now_wall_s, now_mono_ms)
  local out = {}
  for i, e in ipairs(entries) do
    out[i] = {
      ts_iso     = M.iso_from_mono(e.ts, now_wall_s, now_mono_ms),
      level      = e.level,
      level_name = e.level_name,
      component  = e.component,
      message    = e.message,
      event_type = e.event_type,
      fields     = e.fields,
    }
  end
  return out
end

-- ── scan / read / write / delete ─────────────────────────────

---List dump files under the cache dir, newest first. Returns one
---record per file: `{ path, name, mtime, size }`. Empty list if the
---directory doesn't exist yet.
---@return { path: string, name: string, mtime: integer, size: integer }[]
function M.scan()
  local d = _dir()
  if vim.fn.isdirectory(d) == 0 then return {} end
  local names = vim.fn.readdir(d, function(name)
    return name:match("^dump%-.*%.log$") and 1 or 0
  end) or {}
  local out = {}
  for _, name in ipairs(names) do
    local path = d .. "/" .. name
    local stat = vim.uv.fs_stat(path)
    if stat then
      out[#out + 1] = {
        path  = path,
        name  = name,
        mtime = stat.mtime.sec,
        size  = stat.size,
      }
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

---Read a dump file, parsing JSONL into entries. Empty lines are
---skipped. A decode failure on any line aborts the read and surfaces
---the line number in the error.
---@param path string
---@return table[]?, string?
function M.read(path)
  local fd, oerr = io.open(path, "r")
  if not fd then return nil, oerr or ("could not open " .. path) end
  local entries, lineno = {}, 0
  for line in fd:lines() do
    lineno = lineno + 1
    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if not ok then
        fd:close()
        return nil, string.format("%s:%d: %s", path, lineno, tostring(decoded))
      end
      entries[#entries + 1] = decoded
    end
  end
  fd:close()
  return entries, nil
end

---Write entries as JSONL into a fresh `dump-<UTC>.log` file under
---the cache dir. Commit is atomic: write to a sibling `.tmp-…` file
---first, then `vim.uv.fs_rename` into the final name. Returns the
---committed path on success.
---@param entries AutoCoreLogEntry[]
---@return string?, string?
function M.write(entries)
  local d = _ensure_dir()
  local now_wall = os.time()
  local now_mono = vim.uv.now()
  local normalized = M.normalize_for_disk(entries, now_wall, now_mono)
  local final_path = d .. "/dump-" .. _iso_utc(now_wall, false) .. ".log"
  local tmp_path = string.format("%s/.tmp-%d-%d",
    d, now_mono, math.random(100000, 999999))

  local fd, oerr = io.open(tmp_path, "w")
  if not fd then return nil, oerr or "could not open tmp file" end
  for _, e in ipairs(normalized) do
    local ok, encoded = pcall(vim.json.encode, e)
    if not ok then
      fd:close()
      pcall(os.remove, tmp_path)
      return nil, "encode failed: " .. tostring(encoded)
    end
    fd:write(encoded)
    fd:write("\n")
  end
  fd:close()

  local ok_rename, rerr = pcall(vim.uv.fs_rename, tmp_path, final_path)
  if not ok_rename then
    pcall(os.remove, tmp_path)
    return nil, "rename failed: " .. tostring(rerr)
  end
  return final_path, nil
end

---Delete a dump file. Returns `(true, nil)` on success or
---`(false, <error string>)` on failure.
---@param path string
---@return boolean, string?
function M.delete(path)
  local ok, err = os.remove(path)
  if not ok then return false, tostring(err) end
  return true, nil
end

return M
