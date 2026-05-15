---auto-core.mailbox.transport — atomic enqueue + response write +
---claim/complete/fail state transitions.
---
---Writes are atomic: serialize → write to a temp file in the SAME
---directory → fsync → rename into place. The rename is the commit
---step. A consumer reading the inbox during the write therefore
---only ever sees fully-formed JSON files.
---
---Per ADR 0013 §3, the rename target is the inbox of the *recipient*
---mailbox. Senders need not have any directory of their own
---(though they typically do — `responses/` is part of the standard
---layout so request/response flows work).
---
---State transitions:
---
---  send()      → recipient/inbox/<id>.json   publishes core.mailbox:message_queued
---  claim()     → recipient/processing/<id>.json   publishes core.mailbox:message_claimed
---  complete()  → recipient/archive/<id>.json + sender/responses/<correlation_id>.json?
---                                              publishes core.mailbox:message_completed
---                                              + core.mailbox:response_written (when a response is recorded)
---  fail()      → recipient/archive/<id>.json with status='failed'
---                                              publishes core.mailbox:message_failed
---
---@module 'auto-core.mailbox.transport'

local events   = require("auto-core.events")
local fs_path  = require("auto-core.fs.path")
local mb_path  = require("auto-core.mailbox.path")
local registry = require("auto-core.mailbox.registry")
local message  = require("auto-core.mailbox.message")

local M = {}

-- ── low-level atomic write ───────────────────────────────────

---Write `text` to `final_path` atomically by going through a temp
---file in the same directory and fsync-renaming. Returns ok, err?.
---@param final_path string
---@param text string
---@return boolean ok, string? err
local function atomic_write(final_path, text)
  local dir = fs_path.parent(final_path)
  if not fs_path.is_dir(dir) then
    return false, "atomic_write: target dir missing: " .. tostring(dir)
  end
  local tmp = dir .. "/.tmp-" .. tostring(vim.uv.hrtime()) .. "-" .. tostring(math.random(1, 1e9))
  -- Open with 0644. fs_open returns (fd, err) — guard both.
  local fd, open_err = vim.uv.fs_open(tmp, "w", 420) -- 0644
  if not fd then return false, "fs_open: " .. tostring(open_err) end
  local _, write_err = vim.uv.fs_write(fd, text, 0)
  if write_err then
    pcall(vim.uv.fs_close, fd)
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_write: " .. tostring(write_err)
  end
  -- Best-effort fsync; some filesystems / sandboxes refuse it
  -- (e.g. tmpfs may return ENOSYS). Don't fail the write on that —
  -- rename is the durable commit.
  pcall(vim.uv.fs_fsync, fd)
  local _, close_err = vim.uv.fs_close(fd)
  if close_err then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_close: " .. tostring(close_err)
  end
  local rok, rename_err = vim.uv.fs_rename(tmp, final_path)
  if not rok then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_rename: " .. tostring(rename_err)
  end
  return true
end

---@param path string
---@return string? text, string? err
local function read_all(path)
  local fd, oerr = vim.uv.fs_open(path, "r", 420)
  if not fd then return nil, "fs_open: " .. tostring(oerr) end
  local stat, serr = vim.uv.fs_fstat(fd)
  if not stat then
    pcall(vim.uv.fs_close, fd)
    return nil, "fs_fstat: " .. tostring(serr)
  end
  local data, rerr = vim.uv.fs_read(fd, stat.size, 0)
  pcall(vim.uv.fs_close, fd)
  if not data then return nil, "fs_read: " .. tostring(rerr) end
  return data
end

---@param id string
---@return AutoCoreMailboxRecord
local function ensure_registered(id)
  local rec = registry.get(id)
  if rec then return rec end
  return registry.register(id)
end

---Resolve `<root>/<id>/<sub>/` for a registered mailbox, falling
---back to the host-default-rooted resolution for unregistered ones.
---@param id  string
---@param sub string
---@return string
local function subdir_for(id, sub)
  local rec = registry.get(id)
  if rec and rec.subs[sub] then return rec.subs[sub] end
  return mb_path.subdir(id, sub)
end

local function inbox_file(id, message_id)
  return subdir_for(id, "inbox") .. "/" .. message_id .. ".json"
end

local function outbox_file(id, message_id)
  return subdir_for(id, "outbox") .. "/" .. message_id .. ".json"
end

local function processing_file(id, message_id)
  return subdir_for(id, "processing") .. "/" .. message_id .. ".json"
end

local function archive_file(id, message_id)
  return subdir_for(id, "archive") .. "/" .. message_id .. ".json"
end

local function response_file(id, correlation_id)
  return subdir_for(id, "responses") .. "/" .. correlation_id .. ".json"
end

-- ── public API ───────────────────────────────────────────────

---@class AutoCoreMailboxSendResult
---@field id   string                   -- the assigned message id
---@field path string                   -- absolute path the message landed at
---@field message table                  -- the canonical message table written
---@field correlation_id string?         -- when set, the id the sender polls for

---Send a message. The `to` mailbox is auto-registered if it hasn't
---been already. Returns result, err — exactly one is nil. Either a
---structured-error result is returned OR a happy-path result; the
---callsite never has to pcall around the JSON encode or rename.
---@param opts AutoCoreMailboxMessageOpts
---@return AutoCoreMailboxSendResult? result, string? err
function M.send(opts)
  local msg, build_err = message.build(opts)
  if not msg then return nil, build_err end

  -- Auto-register both ends. The sender is only auto-registered for
  -- convenience — most senders DO have a responses/ directory.
  ensure_registered(msg.to)
  ensure_registered(msg.from)

  local target = inbox_file(msg.to, msg.id)
  local text = message.encode(msg)
  local wok, werr = atomic_write(target, text)
  if not wok then return nil, werr end

  local correlation_id
  if type(msg.correlation_id) == "string" and msg.correlation_id ~= "" then
    correlation_id = msg.correlation_id
  end

  events.publish("core.mailbox:message_queued", {
    mailbox        = msg.to,
    id             = msg.id,
    kind           = msg.kind,
    from           = msg.from,
    path           = target,
    correlation_id = correlation_id,
  })

  return {
    id             = msg.id,
    path           = target,
    message        = msg,
    correlation_id = correlation_id,
  }
end

---Read a message file off disk. Caller specifies which subdir
---(`inbox`, `processing`, `archive`); for the common "load by id"
---case use one of the dedicated helpers (`read_inbox`,
---`read_processing`, `read_archive`).
---@param mailbox_id string
---@param sub        string
---@param message_id string
---@return table? msg, string? err
function M.read_from(mailbox_id, sub, message_id)
  local path = subdir_for(mailbox_id, sub) .. "/" .. message_id .. ".json"
  local text, rerr = read_all(path)
  if not text then return nil, rerr end
  local msg, derr = message.decode(text)
  if not msg then return nil, derr end
  return msg
end

---Convenience: read a message from the inbox.
function M.read_inbox(mailbox_id, message_id)
  return M.read_from(mailbox_id, "inbox", message_id)
end

---Convenience: read a message from the processing dir.
function M.read_processing(mailbox_id, message_id)
  return M.read_from(mailbox_id, "processing", message_id)
end

---Convenience: read a message from the archive.
function M.read_archive(mailbox_id, message_id)
  return M.read_from(mailbox_id, "archive", message_id)
end

---List inbox message ids for `mailbox_id`. Returns ids without the
---`.json` suffix, sorted lexicographically (which is also
---chronological given the id format).
---@param mailbox_id string
---@return string[]
function M.list_inbox(mailbox_id)
  return M._list_dir_ids(subdir_for(mailbox_id, "inbox"))
end

---List outbox message ids for `mailbox_id`.
function M.list_outbox(mailbox_id)
  return M._list_dir_ids(subdir_for(mailbox_id, "outbox"))
end

---List processing message ids for `mailbox_id`.
function M.list_processing(mailbox_id)
  return M._list_dir_ids(subdir_for(mailbox_id, "processing"))
end

---List archive message ids for `mailbox_id`.
function M.list_archive(mailbox_id)
  return M._list_dir_ids(subdir_for(mailbox_id, "archive"))
end

---List response correlation ids for `mailbox_id`.
function M.list_responses(mailbox_id)
  return M._list_dir_ids(subdir_for(mailbox_id, "responses"))
end

---Internal: scan `dir` for `<id>.json` entries (skipping dotfiles,
---tempfiles, anything else). Returns sorted id list.
---@param dir string
---@return string[]
function M._list_dir_ids(dir)
  local out = {}
  if not fs_path.is_dir(dir) then return out end
  local sd = vim.uv.fs_scandir(dir)
  if not sd then return out end
  while true do
    local name, type_ = vim.uv.fs_scandir_next(sd)
    if not name then break end
    if (type_ == "file" or type_ == nil)
        and name:sub(1, 1) ~= "."
        and name:sub(-5) == ".json"
    then
      out[#out + 1] = name:sub(1, -6)
    end
  end
  table.sort(out)
  return out
end

---Derive the lifecycle state of `message_id` in `mailbox_id` purely
---from the filesystem. No separate index — survives restarts.
---Returns one of:
---   "queued"     — file in inbox/
---   "claimed"    — file in processing/
---   "completed"  — file in archive/ with status='completed'
---   "failed"     — file in archive/ with status='failed'
---   nil          — not found in any subdir
---@param mailbox_id string
---@param message_id string
---@return string?, integer?    state and file mtime (seconds since epoch) for sorting
function M.message_state(mailbox_id, message_id)
  local rec = registry.get(mailbox_id)
  local subs
  if rec then
    subs = rec.subs
  else
    subs = {
      inbox      = mb_path.subdir(mailbox_id, "inbox"),
      processing = mb_path.subdir(mailbox_id, "processing"),
      archive    = mb_path.subdir(mailbox_id, "archive"),
    }
  end
  -- inbox first (cheapest, most active).
  local p = subs.inbox .. "/" .. message_id .. ".json"
  if fs_path.is_file(p) then
    return "queued", vim.fn.getftime(p)
  end
  p = subs.processing .. "/" .. message_id .. ".json"
  if fs_path.is_file(p) then
    return "claimed", vim.fn.getftime(p)
  end
  p = subs.archive .. "/" .. message_id .. ".json"
  if fs_path.is_file(p) then
    -- Read status off the file. The archived copy carries
    -- status='completed' or status='failed' (set by complete()/fail()).
    local text = read_all(p)
    if text then
      local msg = message.decode(text)
      if msg and msg.status == "failed" then
        return "failed", vim.fn.getftime(p)
      end
      return "completed", vim.fn.getftime(p)
    end
    return "completed", vim.fn.getftime(p)
  end
  return nil
end

---Does the SENDER's responses/ have an envelope for the given
---correlation id? Useful for the viewer when annotating a sent
---message as "responded".
---@param sender_id     string
---@param correlation_id string
---@return boolean
function M.response_exists(sender_id, correlation_id)
  if type(correlation_id) ~= "string" or correlation_id == "" then
    return false
  end
  local rec = registry.get(sender_id)
  local dir = rec and rec.subs.responses or mb_path.subdir(sender_id, "responses")
  return fs_path.is_file(dir .. "/" .. correlation_id .. ".json")
end

---@class AutoCoreMailboxMessageEntry
---@field id            string
---@field subdir        string             "inbox"|"outbox"|"processing"|"archive"|"responses"
---@field path          string             absolute path of the message file
---@field state         string?            from `message_state` ("queued"|"claimed"|"completed"|"failed"|"responded")
---@field mtime         integer            seconds since epoch (for sorting; matches the file mtime)
---@field from          string?            from the decoded message (when readable)
---@field to            string?
---@field subject       string?
---@field kind          string?
---@field correlation_id string?
---@field responded     boolean?            true if a matching response exists (only set when scope='outbox'/'archive' and the message has a correlation_id)

---Walk a mailbox subdir and return one entry per message. Reads
---each file lightly to populate from/to/subject/kind for the
---viewer's middle pane. Sorted by mtime DESCending (newest first).
---@param mailbox_id string
---@param subdir     "inbox"|"outbox"|"processing"|"archive"|"responses"
---@return AutoCoreMailboxMessageEntry[]
function M.list_entries(mailbox_id, subdir)
  local out = {}
  local rec = registry.get(mailbox_id)
  local dir
  if rec then
    dir = rec.subs[subdir]
  else
    dir = mb_path.subdir(mailbox_id, subdir)
  end
  if not dir or not fs_path.is_dir(dir) then return out end
  local sd = vim.uv.fs_scandir(dir)
  if not sd then return out end
  while true do
    local name, type_ = vim.uv.fs_scandir_next(sd)
    if not name then break end
    if (type_ == "file" or type_ == nil)
        and name:sub(1, 1) ~= "."
        and name:sub(-5) == ".json"
    then
      local id = name:sub(1, -6)
      local path = dir .. "/" .. name
      local entry = {
        id     = id,
        subdir = subdir,
        path   = path,
        mtime  = vim.fn.getftime(path),
      }
      local text = read_all(path)
      if text then
        local msg = message.decode(text)
        if msg then
          entry.from           = msg.from
          entry.to             = msg.to
          entry.subject        = msg.subject
          entry.kind           = msg.kind
          if type(msg.correlation_id) == "string"
              and msg.correlation_id ~= ""
          then
            entry.correlation_id = msg.correlation_id
          end
          -- State derivation by subdir.
          if subdir == "inbox" then
            entry.state = "queued"
          elseif subdir == "processing" then
            entry.state = "claimed"
          elseif subdir == "archive" then
            entry.state = (msg.status == "failed") and "failed" or "completed"
            -- Annotate with "responded" if a response exists at the
            -- ORIGINAL sender's responses/<correlation_id>.
            if entry.correlation_id
                and M.response_exists(msg.from, entry.correlation_id)
            then
              entry.responded = true
            end
          elseif subdir == "outbox" then
            -- Still in outbox = router hasn't (yet) delivered.
            entry.state = "pending"
          elseif subdir == "responses" then
            entry.state = "response"
          end
        else
          entry.state = "decode_error"
        end
      end
      out[#out + 1] = entry
    end
  end
  -- Newest first.
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

---Combined inbox + outbox + processing + archive + responses listing
---for `mailbox_id`. Sorted by mtime descending. Useful as the
---"owner" view in the viewer.
---@param mailbox_id string
---@return AutoCoreMailboxMessageEntry[]
function M.list_all(mailbox_id)
  local out = {}
  for _, sub in ipairs({ "inbox", "outbox", "processing", "archive", "responses" }) do
    for _, e in ipairs(M.list_entries(mailbox_id, sub)) do
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

---Claim a message — move it from `inbox/` to `processing/` AND
---durably stamp `status='claimed'`, `claimed_at`, `claimed_by`, and
---an `attempt` counter onto the processing copy. Returns the loaded
---message table (with stamps applied), err — exactly one is nil.
---
---The stamps are written back to the file atomically AFTER the
---rename so a crash between rename and rewrite still leaves the
---file in processing/ (recoverable by `recover_stale`). The
---`attempt` counter survives recovery: if `recover_stale` requeues
---a message, the next claim sees `attempt = previous + 1`.
---
---If two consumers race, only one rename succeeds; the loser gets
---an err.
---@param mailbox_id string
---@param message_id string
---@param opts { claimed_by: string? }?
---@return table? msg, string? err
function M.claim(mailbox_id, message_id, opts)
  opts = opts or {}
  local src = inbox_file(mailbox_id, message_id)
  local dst = processing_file(mailbox_id, message_id)
  ensure_registered(mailbox_id)
  local rok, rerr = vim.uv.fs_rename(src, dst)
  if not rok then
    return nil, "claim: fs_rename " .. tostring(rerr)
  end
  local text, rderr = read_all(dst)
  if not text then return nil, rderr end
  local msg, derr = message.decode(text)
  if not msg then return nil, derr end

  -- Stamp processing metadata. `attempt` increments each time the
  -- same message id is claimed — initial claim is 1; a requeue-
  -- then-reclaim moves it to 2.
  -- We persist BOTH an ISO string (human-readable, audit-friendly)
  -- AND a unix epoch (`claimed_at_unix`) so `recover_stale` can
  -- compute age without parsing ISO across timezones.
  msg.status           = "claimed"
  msg.claimed_at       = message.now_iso()
  msg.claimed_at_unix  = os.time()
  msg.claimed_by       = opts.claimed_by or "nvim"
  msg.attempt          = (type(msg.attempt) == "number") and (msg.attempt + 1) or 1
  -- Best-effort rewrite. A failure here doesn't roll back the
  -- rename (we already own the message) — the caller still gets
  -- the in-memory msg with the stamps applied; the on-disk file
  -- just lacks them until next recovery.
  local _ = atomic_write(dst, message.encode(msg))

  events.publish("core.mailbox:message_claimed", {
    mailbox    = mb_path.bare_id(mailbox_id),
    id         = message_id,
    path       = dst,
    claimed_at = msg.claimed_at,
    claimed_by = msg.claimed_by,
    attempt    = msg.attempt,
  })
  return msg
end

---Complete a claimed message. Moves processing → archive. If
---`response` is supplied, also atomically writes a response file
---into the SENDER's `responses/` dir keyed by the correlation_id
---(falling back to the message id when absent).
---@param mailbox_id string
---@param message_id string
---@param response   table?     -- arbitrary table; will be JSON-encoded
---@return boolean ok, string? err
function M.complete(mailbox_id, message_id, response)
  ensure_registered(mailbox_id)
  local proc = processing_file(mailbox_id, message_id)
  local arch = archive_file(mailbox_id, message_id)

  -- Load the original first so we can find the sender + correlation.
  local text, rerr = read_all(proc)
  if not text then return false, "complete: " .. tostring(rerr) end
  local original, derr = message.decode(text)
  if not original then return false, derr end

  -- Stamp the archive copy with completion metadata.
  original.status       = "completed"
  original.completed_at = message.now_iso()
  local arch_text = message.encode(original)

  -- Write the archive copy first; then the response (if any); then
  -- unlink processing. This order means a partially-complete state
  -- ends up with extra archive data, not a lost original.
  local awok, awerr = atomic_write(arch, arch_text)
  if not awok then return false, "complete: archive " .. tostring(awerr) end

  local response_path
  if response ~= nil then
    local cor = original.correlation_id
    if type(cor) ~= "string" or cor == "" then cor = message_id end
    response_path = response_file(original.from, cor)
    ensure_registered(original.from)
    -- Wrap responses in a consistent envelope so consumers always
    -- get `{ ok, reply_to, correlation_id, value, completed_at }`.
    local envelope = {
      ok             = response.ok ~= false,  -- default true unless explicitly false
      reply_to       = message_id,
      correlation_id = cor,
      value          = response.value,
      error          = response.error,
      completed_at   = original.completed_at,
    }
    local rwok, rwerr = atomic_write(response_path, vim.json.encode(envelope))
    if not rwok then return false, "complete: response " .. tostring(rwerr) end
    events.publish("core.mailbox:response_written", {
      mailbox        = original.from,
      reply_to       = message_id,
      correlation_id = cor,
      path           = response_path,
      ok             = envelope.ok,
    })
  end

  -- Drop the processing file last.
  pcall(vim.uv.fs_unlink, proc)

  events.publish("core.mailbox:message_completed", {
    mailbox       = mb_path.bare_id(mailbox_id),
    id            = message_id,
    path          = arch,
    response_path = response_path,
  })
  return true
end

---Mark a claimed message as failed. Moves processing → archive with
---status='failed' and an `error` field. Optionally writes a response
---envelope `{ ok = false, error = ... }` to the sender. Returns ok,
---err.
---@param mailbox_id string
---@param message_id string
---@param err_info table|string?
---@param opts { response: boolean? }?
function M.fail(mailbox_id, message_id, err_info, opts)
  opts = opts or {}
  ensure_registered(mailbox_id)
  local proc = processing_file(mailbox_id, message_id)
  local arch = archive_file(mailbox_id, message_id)

  local text, rerr = read_all(proc)
  if not text then return false, "fail: " .. tostring(rerr) end
  local original, derr = message.decode(text)
  if not original then return false, derr end

  local err_msg
  if type(err_info) == "string" then err_msg = err_info
  elseif type(err_info) == "table" then err_msg = err_info.error or err_info.message
  else err_msg = "unspecified" end

  original.status       = "failed"
  original.completed_at = message.now_iso()
  original.error        = err_msg
  local awok, awerr = atomic_write(arch, message.encode(original))
  if not awok then return false, "fail: archive " .. tostring(awerr) end

  local response_path
  if opts.response then
    local cor = original.correlation_id
    if type(cor) ~= "string" or cor == "" then cor = message_id end
    response_path = response_file(original.from, cor)
    ensure_registered(original.from)
    local envelope = {
      ok             = false,
      reply_to       = message_id,
      correlation_id = cor,
      error          = err_msg,
      completed_at   = original.completed_at,
    }
    local rwok, rwerr = atomic_write(response_path, vim.json.encode(envelope))
    if not rwok then return false, "fail: response " .. tostring(rwerr) end
    events.publish("core.mailbox:response_written", {
      mailbox        = original.from,
      reply_to       = message_id,
      correlation_id = cor,
      path           = response_path,
      ok             = false,
    })
  end

  pcall(vim.uv.fs_unlink, proc)

  events.publish("core.mailbox:message_failed", {
    mailbox       = mb_path.bare_id(mailbox_id),
    id            = message_id,
    path          = arch,
    error         = err_msg,
    response_path = response_path,
  })
  return true
end

-- ── stale processing recovery ─────────────────────────────

---@class AutoCoreMailboxStaleRecoveryOpts
---@field threshold_ms integer?           default 300_000 (5 minutes)
---@field policy       "fail"|"requeue"?  default "fail"
---@field claimed_by   string?            only sweep messages claimed by this owner; nil = any
---@field write_response boolean?         default true (only honored by 'fail' policy)
---@field now_epoch    integer?           override "now" — used by tests

---@class AutoCoreMailboxStaleRecoveryResult
---@field recovered     { id: string, mailbox: string, policy: string, age_ms: integer, attempt: integer? }[]
---@field scanned       integer

---Sweep `<mailbox>/processing/` for messages whose `claimed_at` is
---older than `threshold_ms`. Apply the chosen policy:
---
---  "fail"    (default) — archive with status='failed', error=
---                        'stale_processing_timeout', and write a
---                        response envelope to the original
---                        sender's responses/ so blocking pollers
---                        unblock with a structured error.
---  "requeue" — atomically move the file back to inbox/. The
---              attempt counter is preserved; the next claim
---              increments it.
---
---Publishes `core.mailbox:stale_recovered` per recovered message.
---Idempotent: messages that have been claimed for less than
---threshold_ms are left alone.
---@param mailbox_id string
---@param opts AutoCoreMailboxStaleRecoveryOpts?
---@return AutoCoreMailboxStaleRecoveryResult
function M.recover_stale(mailbox_id, opts)
  opts = opts or {}
  local threshold_ms = opts.threshold_ms or (5 * 60 * 1000)
  local policy = opts.policy or "fail"
  if policy ~= "fail" and policy ~= "requeue" then
    error("auto-core.mailbox.transport.recover_stale: invalid policy '"
      .. tostring(policy) .. "' (expected 'fail' or 'requeue')")
  end
  local now_s = opts.now_epoch or os.time()
  local proc_dir = subdir_for(mailbox_id, "processing")
  ensure_registered(mailbox_id)

  local result = { recovered = {}, scanned = 0 }
  if not fs_path.is_dir(proc_dir) then return result end

  for _, mid in ipairs(M._list_dir_ids(proc_dir)) do
    result.scanned = result.scanned + 1
    local path = proc_dir .. "/" .. mid .. ".json"
    local text = read_all(path)
    if text then
      local msg = message.decode(text)
      if msg then
        -- Filter by claimed_by if requested.
        if opts.claimed_by and msg.claimed_by ~= opts.claimed_by then
          goto continue
        end
        local age_s
        if type(msg.claimed_at_unix) == "number" then
          age_s = now_s - msg.claimed_at_unix
        else
          -- No durable epoch stamp (older format / hand-crafted
          -- file). Fall back to file mtime so any unclaimed
          -- processing file is still recoverable.
          age_s = now_s - (vim.fn.getftime(path) or now_s)
        end
        if age_s * 1000 < threshold_ms then goto continue end

        if policy == "requeue" then
          local dst = inbox_file(mailbox_id, mid)
          local ok = vim.uv.fs_rename(path, dst)
          if ok then
            result.recovered[#result.recovered + 1] = {
              id = mid, mailbox = mailbox_id, policy = "requeue",
              age_ms = age_s * 1000, attempt = msg.attempt,
            }
            events.publish("core.mailbox:stale_recovered", {
              mailbox    = mb_path.bare_id(mailbox_id),
              id         = mid,
              policy     = "requeue",
              age_ms     = age_s * 1000,
              attempt    = msg.attempt,
              path       = dst,
            })
          end
        else
          -- "fail" policy: archive + optional response.
          msg.status       = "failed"
          msg.completed_at = message.now_iso()
          msg.error        = "stale_processing_timeout"
          local arch = archive_file(mailbox_id, mid)
          local awok = atomic_write(arch, message.encode(msg))
          if awok then
            local resp_path
            if opts.write_response ~= false then
              local cor = (type(msg.correlation_id) == "string"
                and msg.correlation_id ~= "") and msg.correlation_id or mid
              if type(msg.from) == "string" and msg.from ~= "" then
                resp_path = response_file(msg.from, cor)
                ensure_registered(msg.from)
                local envelope = {
                  ok             = false,
                  reply_to       = mid,
                  correlation_id = cor,
                  error          = "stale_processing_timeout",
                  completed_at   = msg.completed_at,
                }
                local rwok = atomic_write(resp_path, vim.json.encode(envelope))
                if rwok then
                  events.publish("core.mailbox:response_written", {
                    mailbox        = msg.from,
                    reply_to       = mid,
                    correlation_id = cor,
                    path           = resp_path,
                    ok             = false,
                  })
                end
              end
            end
            pcall(vim.uv.fs_unlink, path)
            result.recovered[#result.recovered + 1] = {
              id = mid, mailbox = mailbox_id, policy = "fail",
              age_ms = age_s * 1000, attempt = msg.attempt,
            }
            events.publish("core.mailbox:stale_recovered", {
              mailbox       = mb_path.bare_id(mailbox_id),
              id            = mid,
              policy        = "fail",
              age_ms        = age_s * 1000,
              attempt       = msg.attempt,
              path          = arch,
              response_path = resp_path,
            })
            events.publish("core.mailbox:message_failed", {
              mailbox       = mb_path.bare_id(mailbox_id),
              id            = mid,
              path          = arch,
              error         = "stale_processing_timeout",
              response_path = resp_path,
            })
          end
        end
      end
    end
    ::continue::
  end
  return result
end

---Sweep stale processing across every registered mailbox. Useful
---to call on router.start. Returns the merged result list.
---@param opts AutoCoreMailboxStaleRecoveryOpts?
---@return AutoCoreMailboxStaleRecoveryResult
function M.recover_stale_all(opts)
  local merged = { recovered = {}, scanned = 0 }
  for _, rec in ipairs(registry.records()) do
    local r = M.recover_stale(rec.id, opts)
    merged.scanned = merged.scanned + r.scanned
    for _, e in ipairs(r.recovered) do
      merged.recovered[#merged.recovered + 1] = e
    end
  end
  return merged
end

-- Expose the atomic-write primitive so adjacent modules (the
-- consumer + command registry) can reuse it without duplicating
-- the fsync/rename dance.
M._atomic_write = atomic_write
M._read_all     = read_all

return M