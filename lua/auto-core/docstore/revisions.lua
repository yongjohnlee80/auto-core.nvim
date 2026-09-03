---auto-core.docstore.revisions — revisioned document identity.
---
---ADR-0081 §2.2a. Allocating "the next revision of this thing" is generic;
---**naming the thing is not**. So this module takes an opaque `dir` (a store
---handle) and an opaque `key`, and owns exactly five properties:
---
---  * an **exclusive claim** — two writers cannot both take revision N;
---  * a **lease** — a claim that is never committed expires;
---  * **retirement** — a revision can be fenced so it is never handed out again;
---  * **monotonic non-reuse** — a number, once seen in any record kind, is spent;
---  * **record persistence** — the reservation and tombstone documents.
---
---It owns nothing else. The caller supplies the key, the committed record's
---suffix, and every meaning attached to them. It does not know what a revision
---is *of*.
---
---**Record naming.** `<key>.r<N><suffix>` for a committed record, and
---`<key>.r<N>.reserve` / `<key>.r<N>.tombstone` for the two control records.
---`key` and `suffix` are the caller's strings, so a caller whose documents are
---already named this way gets byte-identical paths — which is what lets an
---existing store move behind this module with no migration (ADR-0081 §3.1).
---
---**Why the fencing matters.** Deleting a committed record without fencing its
---number puts that number back in circulation, and the next write becomes a
---second r<N> for the same key — every reference to "r2" then names two
---documents. That has already been a shipped defect once; it exists here so it
---exists once.
---@module 'auto-core.docstore.revisions'

local M = {}

local uv = vim.uv or vim.loop

---RESERVE_SUFFIX / TOMBSTONE_SUFFIX are the two control-record extensions.
M.RESERVE_SUFFIX = ".reserve"
M.TOMBSTONE_SUFFIX = ".tombstone"

---LEASE_SECONDS is how long a reservation is live without renewal.
---
---Liveness is the lease and deliberately NOT a process probe. A pid check has
---two failure modes this does not: pid reuse looks live, and a stat-then-act
---interleaving can reap a live successor. A lease's worst case is a slow writer
---losing a number it had not committed.
M.LEASE_SECONDS = 120

local function _now() return os.time() end

local function _store()
  return require("auto-core.docstore")
end

---_base is the shared stem of all three record kinds for one revision.
local function _base(key, revision)
  return string.format("%s.r%d", tostring(key), tonumber(revision) or 1)
end

---reserve_path / tombstone_path name the two control records.
---@param dir string
---@param key string
---@param revision integer
---@return string
function M.reserve_path(dir, key, revision)
  return dir .. "/" .. _base(key, revision) .. M.RESERVE_SUFFIX
end

---@param dir string
---@param key string
---@param revision integer
---@return string
function M.tombstone_path(dir, key, revision)
  return dir .. "/" .. _base(key, revision) .. M.TOMBSTONE_SUFFIX
end

---record_path names a COMMITTED record, using the caller's suffix.
---@param dir string
---@param key string
---@param revision integer
---@param suffix string   e.g. ".review.json" — the caller's, never ours
---@return string
function M.record_path(dir, key, revision, suffix)
  return dir .. "/" .. _base(key, revision) .. tostring(suffix or "")
end

---token mints an opaque claim token.
---
---`uv.random` where available. The fallback is seeded per call so two writers
---starting in the same second cannot mint the same value; it is a uniqueness tag
---and the security claim rests on `uv.random`, not on it.
---@return string
function M.token()
  if uv.random then
    local ok, bytes = pcall(uv.random, 16)
    if ok and type(bytes) == "string" then
      return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end
  end
  local t = { tostring(vim.fn.getpid()), tostring(_now()) }
  math.randomseed((_now() * 1000 + vim.fn.getpid()) % 2147483647)
  for _ = 1, 16 do t[#t + 1] = string.format("%02x", math.random(0, 255)) end
  return table.concat(t, "-")
end

---max_recorded is the allocation maximum over ALL THREE record kinds.
---
---Committed, reserved and tombstoned alike. Scanning only committed records
---would re-offer a number that is reserved but not yet written, handing a
---crashed writer's revision to the next one — and would re-offer a number whose
---record was deleted, which is the reuse this module exists to prevent.
---@param dir string
---@param key string
---@param suffix string
---@return integer  0 when nothing is recorded
function M.max_recorded(dir, key, suffix)
  local store = _store()
  local k = vim.pesc(tostring(key))
  local sfx = vim.pesc(tostring(suffix or ""))
  local highest = 0
  for _, name in ipairs(store.list(dir)) do
    local rev = name:match("^" .. k .. "%.r(%d+)" .. sfx .. "$")
      or name:match("^" .. k .. "%.r(%d+)%" .. M.RESERVE_SUFFIX .. "$")
      or name:match("^" .. k .. "%.r(%d+)%" .. M.TOMBSTONE_SUFFIX .. "$")
    rev = tonumber(rev)
    if rev and rev > highest then highest = rev end
  end
  return highest
end

---_reservation reads the decoded reservation at `revision`, or nil.
local function _reservation(dir, key, revision)
  local data = _store().read_json(M.reserve_path(dir, key, revision))
  if type(data) ~= "table" then return nil end
  return data
end

---owns reports whether `token` still holds the claim AND the revision has not
---been tombstoned underneath it.
---@param dir string
---@param key string
---@param revision integer
---@param token string
---@return boolean
function M.owns(dir, key, revision, token)
  if _store().exists(M.tombstone_path(dir, key, revision)) then return false end
  local r = _reservation(dir, key, revision)
  return r ~= nil and r.owner == token
end

---claim attempts to reserve one specific revision.
---@param dir string
---@param key string
---@param revision integer
---@param token string
---@return boolean claimed, string? err
function M.claim(dir, key, revision, token)
  if _store().exists(M.tombstone_path(dir, key, revision)) then return false, nil end
  return _store().create_exclusive(M.reserve_path(dir, key, revision),
    _store().encode_pretty({ owner = token, created_at = _now(),
                             lease_until = _now() + M.LEASE_SECONDS }))
end

---claim_next walks upward from the recorded maximum until a claim succeeds.
---
---Upward, never into a gap: a hole below the maximum belongs to a record that
---once existed, and refilling it would reuse a number.
---@param dir string
---@param key string
---@param suffix string
---@param opts { attempts: integer?, token: string? }?
---@return integer? revision, string? token, string? err
function M.claim_next(dir, key, suffix, opts)
  opts = opts or {}
  local token = opts.token or M.token()
  local attempts = opts.attempts or 8
  local rev = M.max_recorded(dir, key, suffix)
  for _ = 1, attempts do
    rev = rev + 1
    local claimed, err = M.claim(dir, key, rev, token)
    if err then return nil, nil, err end
    if claimed then return rev, token, nil end
    -- Taken between the scan and the claim: try the next number up.
  end
  return nil, nil, ("could not claim a revision after %d attempts"):format(attempts)
end

---release drops OUR OWN reservation. Only ever our own — a reservation held by
---someone else is their fence, not ours to clear.
---@param dir string
---@param key string
---@param revision integer
---@param token string
---@return boolean
function M.release(dir, key, revision, token)
  local r = _reservation(dir, key, revision)
  if not (r and r.owner == token) then return false end
  local ok = _store().delete(M.reserve_path(dir, key, revision))
  return ok and true or false
end

---retire fences a revision so it can never be handed out again.
---
---Tombstoning can itself fail — a read-only directory rejects the tombstone for
---the same reason it rejected the record — so this is an ATTEMPT, not a
---guarantee. The reservation is the fallback fence: it already participates in
---`max_recorded`, so keeping it holds the number out of circulation just as
---well. The only difference is whether the fence survives a cleanup pass.
---@param dir string
---@param key string
---@param revision integer
---@param token string?
---@return boolean tombstoned, string? err
function M.retire(dir, key, revision, token)
  local store = _store()
  local ok, err = store.create_exclusive(M.tombstone_path(dir, key, revision),
    store.encode_pretty({ retired_at = _now(), by = token }))
  if ok then
    -- The tombstone is the fence now, so releasing our own reservation is safe.
    -- Compared directly rather than through `owns`, which refuses any tombstoned
    -- revision — routing through it here would mean the branch never ran and
    -- every retire leaked its reservation.
    if token then
      local r = _reservation(dir, key, revision)
      if r and r.owner == token then
        pcall(function() uv.fs_unlink(M.reserve_path(dir, key, revision)) end)
      end
    end
    return true, nil
  end
  -- Someone else's tombstone is success for our purposes: fenced either way.
  if not err and store.exists(M.tombstone_path(dir, key, revision)) then
    return true, nil
  end
  return false, err or "tombstone could not be created"
end

---cleanup tombstones reservations whose lease has expired.
---
---An expired lease is the ONLY evidence of staleness this protocol accepts.
---"No committed record yet" is not: that is also the state of every live writer
---between claiming and committing, and a cleanup built on it reaps them.
---@param dir string
---@param key string
---@param suffix string
---@return integer retired
function M.cleanup(dir, key, suffix)
  local store = _store()
  local k = vim.pesc(tostring(key))
  local n = 0
  for _, name in ipairs(store.list(dir)) do
    local rev = tonumber(name:match("^" .. k .. "%.r(%d+)%" .. M.RESERVE_SUFFIX .. "$"))
    if rev then
      -- Never tombstone a revision that already committed: the record is
      -- complete and the tombstone would be pure noise.
      local committed = store.exists(M.record_path(dir, key, rev, suffix))
      -- ALREADY FENCED is nothing to do. `retire` with no token deliberately
      -- leaves the reservation in place (it is the fallback fence), so without
      -- this check a reaped-but-still-reserved revision is re-counted on every
      -- pass and the return value stops meaning "how many I newly fenced" —
      -- caught by the [2] cleanup assertions, which ran it twice.
      local fenced = store.exists(M.tombstone_path(dir, key, rev))
      local r = _reservation(dir, key, rev)
      local expired = r and type(r.lease_until) == "number" and r.lease_until < _now()
      if not committed and not fenced and expired then
        if M.retire(dir, key, rev, nil) then n = n + 1 end
      end
    end
  end
  return n
end

return M
