---auto-core.docstore.lock — the store's mutual exclusion.
---
---ADR-0081 §2.1 makes auto-core the owner of resource allocation, and a new
---owner must be **at least as capable as the thing it replaces**. This module
---is therefore not a fresh implementation: it is the lock from
---`worktree.store`, moved. Every property below was earned there across six
---review rounds, and each exists because its absence was a defect:
---
---  * the lock **carries its owner** — pid, host, and process start time — so a
---    refusal can name who holds it (r6 should-fix 1: a lock that cannot be
---    stamped is a lock nobody can diagnose, so a partial stamp ABORTS);
---  * liveness is decided by an **enum**, and the prose is derived from it
---    (r6 should-fix 2: control flow once keyed off `status:find("STILL
---    RUNNING")`, so rewording a sentence could advertise repair for a LIVE
---    holder);
---  * **pid reuse is defeated** by comparing the process start time, because a
---    pid alone is not an identity (r4 #2);
---  * only **ESRCH proves death** — EPERM means the process exists and this
---    user may not signal it (r3 #1);
---  * **a lock is never broken automatically.** Three revisions tried; libuv has
---    no atomic conditional unlink, so every `fs_stat`-then-`fs_unlink` leaves a
---    window in which a successor is installed and then deleted by an
---    already-stale decision (r4 #1);
---  * `LOCK_WAIT_MS` **drives the retry loop**, so the documented window and the
---    real one cannot drift — it once advertised 10000ms while looping a
---    measured 505ms (r5 should-fix 1);
---  * releasing is **inode-guarded**: the pathname is unlinked only if it still
---    names the file we created;
---  * libuv's own result is **bound** on every unlink, because `pcall` reports
---    only whether Lua threw (r4 #1, corrected in seven places in the original).
---
---The trade, stated plainly and unchanged: a crashed holder leaves a lock that
---must be cleared OFFLINE. That is chosen over automatic reclamation because a
---lost update in a shared store is silent and unbounded, whereas a stuck lock is
---loud and names its own cause.
---
---The first draft of auto-core's store shipped a 500ms pathname-unlinking lock
---with no owner record — none of the above. Delegating to it would have deleted
---six rounds of hardening while calling itself a refactor. The migration gate
---(ADR-0081 §3.1) is what caught that, before any delegation happened.
---@module 'auto-core.docstore.lock'

local M = {}

local uv = vim.uv or vim.loop

---LOCK_WAIT_MS is how long `with_lock` waits for a contested lock before
---refusing. A CONTENTION WINDOW and nothing more: age never establishes that a
---holder is dead, and no path here breaks a lock.
M.LOCK_WAIT_MS = 10000

---LOCK_POLL_MS is the retry interval inside that window.
M.LOCK_POLL_MS = 10

---_parse_proc_stat extracts field 22 (starttime) from one /proc/<pid>/stat line.
---
---Split out from `_proc_start` so the parsing can be tested against a hostile
---`comm` without needing a real process to be named that way.
---
---The comm field is parenthesised and may itself contain spaces AND
---parentheses, so the fields after it begin at the LAST ")" on the line.
---`line:match("%)%s+(.*)$")` does NOT do that — Lua takes the leftmost match, so
---a comm like `(nvim) shifted` starts from the FIRST ") " and returns the wrong
---field. The start time then reads as 0, `_owner_dead` reads that as pid reuse,
---and a LIVE holder is judged dead (r4 #2). Computed, not pattern-matched.
---@param line string
---@return integer? starttime
function M._parse_proc_stat(line)
  line = tostring(line or "")
  local close = nil
  for i = #line, 1, -1 do
    if line:sub(i, i) == ")" then close = i break end
  end
  if not close then return nil end
  local tail = line:sub(close + 1):match("^%s*(.*)$")
  if not tail or tail == "" then return nil end
  local n, i = nil, 0
  for word in tail:gmatch("%S+") do
    i = i + 1
    if i == 20 then n = tonumber(word) break end -- field 22 overall
  end
  return n
end

---_proc_start returns a process's start time, used to defeat PID REUSE.
---
---Linux exposes it as field 22 of /proc/<pid>/stat. Elsewhere this returns nil
---and the liveness check degrades to pid-only, which is still strictly better
---than age.
---@param pid integer
---@return integer? starttime
function M._proc_start(pid)
  if type(pid) ~= "number" then return nil end
  local fd = io.open("/proc/" .. pid .. "/stat", "r")
  if not fd then return nil end
  local line = fd:read("*l") or ""
  fd:close()
  return M._parse_proc_stat(line)
end

---_owner_record describes THIS process as the lock's owner.
local function _owner_record()
  local pid = uv.os_getpid and uv.os_getpid() or nil
  return {
    pid = pid,
    host = uv.os_gethostname and uv.os_gethostname() or nil,
    start = M._proc_start(pid or -1),
  }
end

---_owner_dead reports whether a lock's owner is PROVABLY gone.
---
---Conservative by design: every uncertain answer is "not dead", because
---breaking a live holder's lock lets two writers into the same
---read-modify-write — the lost update this lock exists to prevent.
---@param rec table?   decoded owner record
---@return boolean
local function _owner_dead(rec)
  if type(rec) ~= "table" or type(rec.pid) ~= "number" then return false end
  -- Another machine's lock is not ours to judge: its pids mean nothing here.
  local host = uv.os_gethostname and uv.os_gethostname() or nil
  if rec.host and host and rec.host ~= host then return false end
  if not (uv.kill and uv.os_getpid) then return false end
  if rec.pid == uv.os_getpid() then return false end -- ourselves, re-entering

  -- luv returns 0 on success, or nil, message, CODE. The third result is the
  -- stable errno name; matching the human-readable message was fragile across
  -- platforms and would silently mean "never break" if the wording differed.
  local ok_sig, _, sig_code = uv.kill(rec.pid, 0)
  if ok_sig ~= 0 then
    -- Only ESRCH proves death. EPERM means the process EXISTS and this user may
    -- not signal it; treating that as dead contradicts this contract.
    if sig_code == "ESRCH" then return true end
    return false
  end
  -- The pid is live. Is it still the SAME process, or a reused pid?
  local now_start = M._proc_start(rec.pid)
  if rec.start and now_start and rec.start ~= now_start then
    return true -- pid reused: the original owner is gone
  end
  return false  -- genuinely alive; never break it
end

---Test seam for the liveness model: a test asserts the DECISION, not the
---wording that happens to describe it.
M._owner_dead_for_tests = _owner_dead

---with_lock runs `fn` while holding an exclusive lock on `path`.
---
---Needed because atomic rename prevents a TORN file but not a LOST UPDATE: two
---processes can each read, each modify their own copy, and the second rename
---silently discards the first's change. Any read-modify-write of a shared store
---file must run in here.
---
---The lock is a sibling `<path>.lock` created with O_EXCL — atomic on every
---filesystem the family targets — and it carries its owner so a contender can
---say who holds it.
---
---Returns at most TWO values from `fn` (`value, err`), which is all any caller
---needs. Deliberately narrow: threading true varargs out would need
---`table.maxn`/`unpack`, whose availability differs across the Lua versions
---Neovim has shipped, for no benefit at these call sites.
---@param path string          the file being guarded (NOT the lock path)
---@param fn fun():any,any?    critical section; runs at most once
---@return any? value, string? err
function M.with_lock(path, fn)
  local store = require("auto-core.docstore")
  if type(path) ~= "string" or path == "" then return nil, "with_lock: no path" end
  if type(fn) ~= "function" then return nil, "with_lock: fn required" end
  if not store.ensure_dir(vim.fn.fnamemodify(path, ":h")) then
    return nil, "with_lock: could not create " .. vim.fn.fnamemodify(path, ":h")
  end
  local lock = path .. ".lock"
  local fd
  -- The owner record last read off a contested lock, so a refusal can say WHO
  -- holds it rather than only that acquisition failed.
  local held_by

  -- Deadline derived from the constant, not a hard-coded iteration count.
  local attempts = math.max(1, math.floor(M.LOCK_WAIT_MS / M.LOCK_POLL_MS))
  local open_err, open_code
  for _ = 1, attempts do
    -- Bind libuv's error. Treating any failure as contention reported an
    -- EACCES on an unwritable directory as "an owner record from an older
    -- version" — a misleading diagnosis of a permissions problem. Only EEXIST
    -- means "someone holds it".
    local nfd, err, code = uv.fs_open(lock, "wx", tonumber("600", 8))
    if nfd then fd = nfd break end
    open_err, open_code = err, code
    if code ~= "EEXIST" then break end   -- not contention; stop and report it
    -- NO automatic takeover. A lock we do not own is never removed — it is
    -- REPORTED, with the identity needed to clear it deliberately and offline.
    held_by = select(1, store.read_json(lock))
    vim.wait(M.LOCK_POLL_MS)
  end

  if not fd then
    if open_code and open_code ~= "EEXIST" then
      return nil, ("with_lock: cannot create %s (%s: %s)")
        :format(lock, tostring(open_code), tostring(open_err))
    end
    -- MANUAL RECOVERY REQUIRES GLOBAL QUIESCENCE. "Remove it to recover" moved
    -- the race out of the code and into the operator's hands: two repairers can
    -- both diagnose the same stale lock L, the first removes it, a writer
    -- acquires successor L2, and the second's `rm` — still justified by its own
    -- stale read — deletes L2, letting a fourth writer in beside the third. A
    -- pathname `rm` is no more conditional than `fs_unlink` was.
    --
    -- `liveness` is an ENUM driving the branch; the prose is derived FROM it.
    local who, liveness
    if type(held_by) == "table" and held_by.pid then
      who = ("pid %s on %s"):format(tostring(held_by.pid), tostring(held_by.host or "?"))
      local host = uv.os_gethostname and uv.os_gethostname() or nil
      if held_by.host and host and held_by.host ~= host then
        liveness = "unknown_host"
      elseif _owner_dead(held_by) then
        liveness = "dead"
      else
        liveness = "alive"
      end
    else
      who = "an owner record this version cannot read"
      liveness = "unknown_record"
    end

    local status = ({
      alive = "that process is STILL RUNNING, so this is normal contention",
      dead = "that process is NO LONGER RUNNING, so the lock is stale",
      unknown_host = "on another host, so its liveness is UNKNOWN from here",
      unknown_record = "liveness UNKNOWN (likely written by an older version)",
    })[liveness]

    -- Repair instructions ONLY when the holder is not alive, keyed off the enum
    -- rather than off the wording above.
    local repair = ""
    if liveness ~= "alive" then
      repair = (" To clear a stale lock: QUIT EVERY Neovim that writes %s (on"
        .. " every host that mounts it), THEN remove %s, then restart. Removing"
        .. " it while any writer is running can delete a live successor lock."
        .. " Full procedure: README.md, \"Recovering a stuck lock\".")
        :format(vim.fn.fnamemodify(path, ":h"), lock)
    end
    return nil, ("with_lock: could not acquire %s after %dms (held by %s — %s).%s")
      :format(lock, M.LOCK_WAIT_MS, who, status, repair)
  end

  ---_abandon closes and removes the lock we just created, and reports whether
  ---the removal actually happened. Removing OUR OWN lock is not the contested-
  ---pathname case: we created it a moment ago with O_EXCL and nothing else can
  ---hold it yet.
  ---@return string suffix  "" when clean, otherwise recovery text for the error
  local function _abandon()
    pcall(uv.fs_close, fd)
    local removed, uerr = uv.fs_unlink(lock)
    if removed then return "" end
    return (". The lock file %s COULD NOT be removed (%s) and will block the"
      .. " next writer — see README.md \"Recovering a stuck lock\"")
      :format(lock, tostring(uerr))
  end

  -- Stamp ownership INTO the lock so a contender can judge us the same way. A
  -- lock we cannot STAMP is a lock nobody can diagnose, so a failed or PARTIAL
  -- write aborts rather than proceeding. Logging and carrying on left exactly
  -- the "unreadable owner record" state that costs the next writer its
  -- diagnosis — and reported success while doing it.
  local ok_enc, encoded = pcall(vim.json.encode, _owner_record())
  if not ok_enc then
    return nil, ("with_lock: could not encode the owner record: %s%s")
      :format(tostring(encoded), _abandon())
  end
  local wrote, werr = uv.fs_write(fd, encoded, 0)
  if wrote ~= #encoded then
    return nil, ("with_lock: could not stamp the owner record on %s (wrote %s of"
      .. " %d bytes%s) — refusing rather than holding an unidentifiable lock%s")
      :format(lock, tostring(wrote), #encoded,
        werr and (": " .. tostring(werr)) or "", _abandon())
  end
  local mine = uv.fs_fstat(fd)

  -- Release on EVERY path, including a throw. There is no backstop that will
  -- clean up after us: a leaked lock blocks the next writer until someone
  -- removes it offline.
  local ok, value, err = pcall(fn)
  pcall(uv.fs_close, fd)

  -- Unlink only if the pathname STILL refers to the file we created. Sound only
  -- because nothing removes a lock automatically; if takeover ever returns,
  -- this stat-then-unlink becomes a race again.
  local release_err
  local now = uv.fs_stat(lock)
  if now and mine and now.ino == mine.ino then
    local removed, unlink_err = uv.fs_unlink(lock)
    if not removed then
      -- A FAILED RELEASE IS NOT SUCCESS (lector MF5). This was a warning in the
      -- log and nothing more, so the call returned (value, nil) while the lock
      -- it created stayed on disk and the next writer could never acquire it.
      -- The store reported clean success for an operation that had wedged it.
      release_err = ("with_lock: the critical section completed but %s COULD"
        .. " NOT be released (%s) — the next writer will refuse until it is"
        .. " removed; see README.md \"Recovering a stuck lock\"")
        :format(lock, tostring(unlink_err))
      local ok_log, log = pcall(require, "auto-core.log")
      if ok_log and type(log) == "table" and type(log.warn) == "function" then
        log.warn("docstore", release_err)
      end
    end
  end

  if not ok then return nil, "with_lock: " .. tostring(value) end
  -- The callback's result is PRESERVED alongside a release failure: the work
  -- itself succeeded, and a caller that discards the value on this path would
  -- lose a completed write as well as the lock. The body's own error wins when
  -- it set one -- it is the more specific fact -- but the release failure is
  -- appended so it can never vanish.
  if release_err then
    if err then return value, tostring(err) .. " | " .. release_err end
    return value, release_err
  end
  return value, err
end

return M
