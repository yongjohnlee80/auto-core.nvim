---auto-core.docstore.revisions — revisioned document identity.
---
---ADR-0081 §2.2a. Allocating "the next revision of this thing" is generic;
---**naming the thing is not**. So a caller opens a HANDLE over an opaque
---directory and an opaque key, and the handle owns exactly five properties:
---
---  * an **exclusive claim** — two writers cannot both take revision N;
---  * a **lease** — a claim that is never committed expires;
---  * **retirement** — a revision can be fenced so it is never handed out again;
---  * **monotonic non-reuse** — a number, once seen in any record kind, is spent;
---  * **record persistence** — the reservation and tombstone documents.
---
---It owns nothing else. The caller supplies the key, the committed record's
---suffix, and every meaning attached to them. It does not know what a revision
---is *of* — proven by a non-review consumer driving it in the tests, not by
---grepping this file for domain words.
---
---### Why a handle, and not three loose strings
---
---The first draft took `(dir, key, suffix)` on every call. That is not a
---boundary, it is string concatenation, and three independent defects followed
---from it (lector MF3):
---
---  * `key = "../outside"` wrote `outside.r1.reserve` **outside** the directory
---    it was given. Nothing validated containment.
---  * committed records were counted only for the suffix passed on *that call*,
---    while control records ignored the suffix — so committing
---    `k.r1.yaml`, releasing, then allocating for `k` with `.json` **re-issued
---    r1**. "Once seen for this key is spent" was false the moment a directory
---    held two formats.
---  * a caller suffix of `.reserve` made the committed path and the reservation
---    path the same file.
---
---A handle fixes the grammar ONCE, at construction, where it can be validated
---and refused. `max_recorded` then scans `<key>.r<N>` followed by **any** tail,
---so every format sharing a directory participates in one numbering and a
---suffix change cannot rewind it.
---
---### Record naming
---
---`<key>.r<N><suffix>` for a committed record, and `<key>.r<N>.reserve` /
---`<key>.r<N>.tombstone` for the two control records. `key` and `suffix` are the
---caller's, so a caller whose documents are already named this way gets
---byte-identical paths — which is what lets an existing store move behind this
---module with no migration (ADR-0081 §3.1). The review store's
---`<owner>__<repo>@<short-sha>.r<N>.review.json` is exactly this shape, which
---the migration fixtures assert rather than assume.
---
---### Why the fencing matters
---
---Deleting a committed record without fencing its number puts that number back
---in circulation, and the next write becomes a second r<N> for the same key —
---every reference to "r2" then names two documents. That has already been a
---shipped defect once; it exists here so it exists once.
---@module 'auto-core.docstore.revisions'

local M = {}

local uv = vim.uv or vim.loop

---RESERVE_SUFFIX / TOMBSTONE_SUFFIX are the two control-record extensions.
M.RESERVE_SUFFIX = ".reserve"
M.TOMBSTONE_SUFFIX = ".tombstone"

---RESERVED_SUFFIXES are the tails a caller may NOT claim as its committed
---suffix, because the resulting path would be a control record's own name (or
---the lock the store puts beside a document).
M.RESERVED_SUFFIXES = { M.RESERVE_SUFFIX, M.TOMBSTONE_SUFFIX, ".lock" }

---LEASE_SECONDS is how long a reservation is live without renewal.
---
---Liveness is the lease and deliberately NOT a process probe. A pid check has
---two failure modes this does not: pid reuse looks live, and a stat-then-act
---interleaving can reap a live successor. A lease's worst case is a slow writer
---losing a number it had not committed.
M.LEASE_SECONDS = 120

---KEY_PATTERN is the whole grammar a key may use: one path component of
---alphanumerics and `- _ @ .`, starting alphanumeric.
---
---Permissive enough for the review store's `<owner>__<repo>@<short-sha>`, and
---narrow enough that a key can never be a path. Separators and `..` are refused
---outright rather than sanitised: silently rewriting a caller's identity would
---make two different keys collide, which is worse than a refusal.
M.KEY_PATTERN = "^[%w][%w%-_@.]*$"

---SUFFIX_PATTERN is the grammar for a committed record's suffix: a dot, then
---alphanumerics and `- _ .`.
M.SUFFIX_PATTERN = "^%.[%w][%w%-_.]*$"

local function _now() return os.time() end

local function _store()
  return require("auto-core.docstore")
end

---_normalize_dir renders a directory path comparably: expanded, normalized, no
---trailing slash.
local function _normalize_dir(dir)
  local d = vim.fs and vim.fs.normalize and vim.fs.normalize(dir) or dir
  d = tostring(d):gsub("/+$", "")
  return d
end

---validate checks a would-be handle's parts and explains every refusal.
---
---Returns the problems rather than raising: a caller opening a handle from
---user-supplied identity needs to report what was wrong, and a raise here would
---have to be caught at every call site.
---@param opts { dir: string, key: string, suffix: string }
---@return boolean ok, string[] problems
function M.validate(opts)
  local problems = {}
  opts = opts or {}
  local dir, key, suffix = opts.dir, opts.key, opts.suffix

  if type(dir) ~= "string" or dir == "" then
    problems[#problems + 1] = "dir must be a non-empty string"
  elseif not dir:match("^/") then
    -- A relative store root resolves against whatever the process's cwd
    -- happens to be, which for an editor changes under the user's feet.
    problems[#problems + 1] = "dir must be an absolute path: " .. dir
  elseif ("/" .. _normalize_dir(dir) .. "/"):find("/%.%./") then
    problems[#problems + 1] = "dir must not contain a `..` component: " .. dir
  end

  if type(key) ~= "string" or key == "" then
    problems[#problems + 1] = "key must be a non-empty string"
  elseif #key > 200 then
    problems[#problems + 1] = "key is longer than 200 characters"
  elseif not key:match(M.KEY_PATTERN) then
    -- ONE load-bearing check, with a message DERIVED from what is wrong. There
    -- were three overlapping branches here -- a separator check, a `..` check,
    -- and the pattern -- and the mutation matrix showed the first two were
    -- redundant: disabling either changed no outcome, because the pattern
    -- already excludes both. Overlapping guards are not defence in depth when
    -- they are the same guard written three times; they just make it unclear
    -- which one is holding the line.
    local why
    if key:find("/", 1, true) then
      why = "must be a single path component, not a path"
    elseif key:find("..", 1, true) then
      why = "must not contain `..`"
    else
      why = "must match " .. M.KEY_PATTERN .. " (alphanumerics and - _ @ .)"
    end
    problems[#problems + 1] = "key " .. why .. ": " .. key
  end

  if type(suffix) ~= "string" or suffix == "" then
    problems[#problems + 1] = "suffix must be a non-empty string"
  elseif not suffix:match(M.SUFFIX_PATTERN) then
    problems[#problems + 1] =
      "suffix must match " .. M.SUFFIX_PATTERN .. " (a dot, then alphanumerics and - _ .): "
      .. suffix
  else
    for _, reserved in ipairs(M.RESERVED_SUFFIXES) do
      if suffix == reserved then
        -- `<key>.r1.reserve` as a COMMITTED record is the reservation's own
        -- path: the two records would be one file.
        problems[#problems + 1] =
          "suffix `" .. reserved .. "` is reserved for a control record"
        break
      end
    end
  end

  return #problems == 0, problems
end

---Handle is a validated (dir, key, suffix) triple. Constructed only by `open`.
---@class AutoCoreRevisionHandle
---@field dir string
---@field key string
---@field suffix string
local Handle = {}
Handle.__index = Handle

---open validates and returns a handle over `dir` for `key`.
---@param opts { dir: string, key: string, suffix: string }
---@return AutoCoreRevisionHandle? handle, string? err
function M.open(opts)
  local ok, problems = M.validate(opts)
  if not ok then
    return nil, "revisions.open: " .. table.concat(problems, "; ")
  end
  local h = setmetatable({
    dir = _normalize_dir(opts.dir),
    key = opts.key,
    suffix = opts.suffix,
  }, Handle)

  -- CONTAINMENT, checked on a real path rather than trusted to the grammar.
  -- Defence in depth: if the key pattern is ever widened, this still refuses a
  -- key that would place a record anywhere but the directory it was given.
  local probe = h:record_path(1)
  if _normalize_dir(vim.fn.fnamemodify(probe, ":h")) ~= h.dir then
    return nil, ("revisions.open: key %q would write outside %s (to %s)")
      :format(tostring(opts.key), h.dir, probe)
  end
  return h, nil
end

---_base is the shared stem of all three record kinds for one revision.
---@param revision integer
---@return string
function Handle:_base(revision)
  return string.format("%s.r%d", self.key, tonumber(revision) or 1)
end

---record_path names a COMMITTED record, using the handle's suffix.
---@param revision integer
---@return string
function Handle:record_path(revision)
  return self.dir .. "/" .. self:_base(revision) .. self.suffix
end

---reserve_path / tombstone_path name the two control records.
---@param revision integer
---@return string
function Handle:reserve_path(revision)
  return self.dir .. "/" .. self:_base(revision) .. M.RESERVE_SUFFIX
end

---@param revision integer
---@return string
function Handle:tombstone_path(revision)
  return self.dir .. "/" .. self:_base(revision) .. M.TOMBSTONE_SUFFIX
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

---max_recorded is the allocation maximum over EVERY record for this key.
---
---Any tail, not just this handle's suffix: committed, reserved, tombstoned, and
---any other format sharing the directory. Scanning only the calling suffix
---re-issued a number as soon as a second format appeared (lector MF3 case 2),
---and scanning only committed records would hand a crashed writer's revision to
---the next writer.
---@return integer  0 when nothing is recorded
function Handle:max_recorded()
  local store = _store()
  local k = vim.pesc(self.key)
  local highest = 0
  for _, name in ipairs(store.list(self.dir)) do
    -- `.r<N>` must be followed by a suffix that starts at a DOT, so a key's
    -- record cannot be confused with a longer key's (`k.r1x...` is not ours).
    local rev = tonumber(name:match("^" .. k .. "%.r(%d+)%.[^/]*$"))
      or tonumber(name:match("^" .. k .. "%.r(%d+)$"))
    if rev and rev > highest then highest = rev end
  end
  return highest
end

---_reservation reads the reservation at `revision` and CLASSIFIES it.
---
---Three outcomes, because "absent" and "present but unintelligible" must not
---look alike (lector SF2): an indeterminate reservation has to be kept as a
---fence, and its caller has to be told.
---@param revision integer
---@return table? record, string? err, string state  "absent"|"ok"|"indeterminate"
function Handle:_reservation(revision)
  local store = _store()
  local path = self:reserve_path(revision)
  local data, err = store.read_json(path)
  if err then return nil, err, "indeterminate" end
  if data == nil then return nil, nil, "absent" end
  if type(data) ~= "table" then
    return nil, "reservation is not an object: " .. path, "indeterminate"
  end
  if type(data.lease_until) ~= "number" then
    -- Without a numeric lease there is no evidence of staleness to act on.
    return data, "reservation has no numeric lease_until: " .. path, "indeterminate"
  end
  return data, nil, "ok"
end

---owns reports whether `token` still holds the claim AND the revision has not
---been tombstoned underneath it.
---@param revision integer
---@param token string
---@return boolean
function Handle:owns(revision, token)
  if _store().exists(self:tombstone_path(revision)) then return false end
  local r = self:_reservation(revision)
  return r ~= nil and r.owner == token
end

---claim attempts to reserve one specific revision.
---@param revision integer
---@param token string
---@return boolean claimed, string? err
function Handle:claim(revision, token)
  local store = _store()
  if store.exists(self:tombstone_path(revision)) then return false, nil end
  return store.create_exclusive(self:reserve_path(revision),
    store.encode_pretty({ owner = token, created_at = _now(),
                          lease_until = _now() + M.LEASE_SECONDS }))
end

---claim_next walks upward from the recorded maximum until a claim succeeds.
---
---Upward, never into a gap: a hole below the maximum belongs to a record that
---once existed, and refilling it would reuse a number.
---@param opts { attempts: integer?, token: string? }?
---@return integer? revision, string? token, string? err
function Handle:claim_next(opts)
  opts = opts or {}
  local token = opts.token or M.token()
  local attempts = opts.attempts or 8
  local rev = self:max_recorded()
  for _ = 1, attempts do
    rev = rev + 1
    local claimed, err = self:claim(rev, token)
    if err then return nil, nil, err end
    if claimed then return rev, token, nil end
    -- Taken between the scan and the claim: try the next number up.
  end
  return nil, nil, ("could not claim a revision after %d attempts"):format(attempts)
end

---release drops OUR OWN reservation. Only ever our own — a reservation held by
---someone else is their fence, not ours to clear.
---@param revision integer
---@param token string
---@return boolean
function Handle:release(revision, token)
  local r = self:_reservation(revision)
  if not (r and r.owner == token) then return false end
  local ok = _store().delete(self:reserve_path(revision))
  return ok and true or false
end

---retire fences a revision so it can never be handed out again.
---
---Tombstoning can itself fail — a read-only directory rejects the tombstone for
---the same reason it rejected the record — so this is an ATTEMPT, not a
---guarantee, and it reports the two facts SEPARATELY (lector answer 2):
---whether a tombstone was written, and whether the revision is fenced at all.
---The reservation is the fallback fence, because it already participates in
---`max_recorded` — but only if it is still there, so that is now CONFIRMED
---rather than assumed.
---@param revision integer
---@param token string?
---@return boolean tombstoned, string? err, boolean fenced
function Handle:retire(revision, token)
  local store = _store()
  local ok, err = store.create_exclusive(self:tombstone_path(revision),
    store.encode_pretty({ retired_at = _now(), by = token }))
  if ok then
    -- The tombstone is the fence now, so releasing our own reservation is safe.
    -- Compared directly rather than through `owns`, which refuses any tombstoned
    -- revision — routing through it here would mean the branch never ran and
    -- every retire leaked its reservation.
    if token then
      local r = self:_reservation(revision)
      if r and r.owner == token then
        pcall(function() uv.fs_unlink(self:reserve_path(revision)) end)
      end
    end
    return true, nil, true
  end
  -- Someone else's tombstone is success for our purposes: fenced either way.
  if not err and store.exists(self:tombstone_path(revision)) then
    return true, nil, true
  end
  -- The tombstone could not be written. The number is still out of circulation
  -- IF the reservation survives, since `max_recorded` counts it — verified here
  -- instead of asserted, because a fence nobody checked is not a fence.
  local fenced = store.exists(self:reserve_path(revision))
  return false, err or "tombstone could not be created", fenced
end

---cleanup tombstones reservations whose lease has expired.
---
---An expired lease is the ONLY evidence of staleness this protocol accepts.
---"No committed record yet" is not: that is also the state of every live writer
---between claiming and committing, and a cleanup built on it reaps them.
---
---Returns a REPORT, not just a count (lector SF2). A corrupt reservation is kept
---— it is a fence, and nothing here can prove what it was for — but silently
---skipping it made corruption indistinguishable from a quiet no-op pass.
---@return integer retired, { indeterminate: integer[], errors: string[], fenced: integer[] } report
function Handle:cleanup()
  local store = _store()
  local k = vim.pesc(self.key)
  local n = 0
  local report = { indeterminate = {}, errors = {}, fenced = {} }
  for _, name in ipairs(store.list(self.dir)) do
    local rev = tonumber(name:match("^" .. k .. "%.r(%d+)%" .. M.RESERVE_SUFFIX .. "$"))
    if rev then
      -- Never tombstone a revision that already committed: the record is
      -- complete and the tombstone would be pure noise.
      local committed = store.exists(self:record_path(rev))
      -- ALREADY FENCED is nothing to do. `retire` with no token deliberately
      -- leaves the reservation in place (it is the fallback fence), so without
      -- this check a reaped-but-still-reserved revision is re-counted on every
      -- pass and the return value stops meaning "how many I newly fenced".
      local fenced = store.exists(self:tombstone_path(rev))
      local r, rerr, state = self:_reservation(rev)
      if state == "indeterminate" then
        -- THE FOURTH STATE: present, but its lease cannot be established. Never
        -- reaped automatically — the number stays fenced by the reservation
        -- itself — and reported so a caller can see corruption rather than
        -- inferring it from a zero count.
        report.indeterminate[#report.indeterminate + 1] = rev
        if rerr then report.errors[#report.errors + 1] = rerr end
      elseif not committed and not fenced
        and r and r.lease_until < _now() then
        local tombstoned, terr, is_fenced = self:retire(rev, nil)
        if tombstoned then
          n = n + 1
        else
          if terr then report.errors[#report.errors + 1] = terr end
          -- Report the fence separately from the tombstone: a failed retire that
          -- LEFT the reservation has still kept the number out of circulation,
          -- and a caller must be able to tell that from a lost fence.
          if is_fenced then report.fenced[#report.fenced + 1] = rev end
        end
      end
    end
  end
  return n, report
end

return M
