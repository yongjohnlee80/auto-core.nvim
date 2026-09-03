---auto-core.docstore — the family's document persistence layer.
---
---ADR-0081 §2.1: **auto-core communicates and allocates resources, including
---reading and writing files.** worktree.nvim owns what a document MEANS;
---auto-finder renders it; this module is the only place in the family that
---touches the filesystem on their behalf.
---
---**Nothing here knows what a review is.** No reviewer, no severity, no verdict,
---no commit. It moves opaque bytes to and from opaque paths, and allocates
---revision numbers against an opaque key (see `docstore.revisions`). That is the
---whole boundary: a caller supplies the naming and the meaning, this module
---supplies the durability. A grep of this file for domain vocabulary should come
---back empty, and a non-domain consumer test proves the abstraction rather than
---the grep (ADR-0081 §2.2a).
---
---Why it exists at all: persistence was previously spread across worktree.nvim
---and auto-finder, and the seams between them produced a documented run of
---defects — a value computed and discarded, an ambient read deep in a call, two
---paths computing one fact, a delete that freed a revision number for reuse, and
---an unvalidated path handed to unlink. One owner for "who wrote this file"
---removes that class rather than fixing instances of it.
---@module 'auto-core.docstore'

local M = {}

local uv = vim.uv or vim.loop

---encode_pretty renders a value as INDENTED JSON with stable key order.
---
---THE single encoder for persisted family documents (ADR-0081 criterion 6).
---`vim.json.encode` emits one minified line with keys in hash order — fine on a
---wire, poor for a file a human opens and for a history that should diff
---cleanly. Two-space indent, keys sorted, arrays in order.
---
---Scalar escaping is delegated to `vim.json.encode` so string quoting and number
---formatting stay exactly correct; only the shaping is ours. An empty table
---encodes as `[]`: Lua cannot distinguish an empty list from an empty map, and
---`[]` is the safer default for the document shapes this store holds.
---@param value any
---@param indent string?  internal — current indentation
---@return string
function M.encode_pretty(value, indent)
  indent = indent or ""
  local child = indent .. "  "
  if type(value) ~= "table" then
    -- Scalars, including nil → "null".
    return vim.json.encode(value)
  end
  local n, is_array = 0, true
  for k in pairs(value) do
    n = n + 1
    if type(k) ~= "number" then is_array = false end
  end
  if is_array and n == #value then
    if n == 0 then return "[]" end
    local parts = {}
    for _, v in ipairs(value) do
      parts[#parts + 1] = child .. M.encode_pretty(v, child)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  -- Carry the ORIGINAL key beside its rendered name. Stringifying the key and
  -- then indexing the table by that string loses non-string keys entirely:
  -- `{ [2] = "x" }` looked up value["2"], found nil, and encoded {"2": null} --
  -- a persistence encoder silently changing the value it was handed (lector
  -- SF1). Sparse and mixed-key tables failed the same way.
  local keys, seen = {}, {}
  for k in pairs(value) do
    -- A JSON object key can only be a string. Numbers render unambiguously and
    -- the review store's own documents rely on it; anything else (a boolean, a
    -- table, a function) has no defensible rendering, and inventing one is the
    -- silent value change this encoder exists to refuse.
    local tk = type(k)
    if tk ~= "string" and tk ~= "number" then
      error(("encode_pretty: cannot render a %s as an object key"):format(tk), 0)
    end
    local name = tostring(k)
    if seen[name] ~= nil then
      -- TWO KEYS, ONE RENDERED NAME: `{ [2] = 1, ["2"] = "x" }` emitted two
      -- members called "2", and decoding kept one of them. Carrying the
      -- original key fixed the lookup but not this: the document was still
      -- losing a value, silently, which is exactly what SF1 asked for
      -- (lector r1 MF4).
      error(("encode_pretty: keys %s and %s both render as %q; the document"
        .. " would lose one of them"):format(
        vim.inspect(seen[name]), vim.inspect(k), name), 0)
    end
    seen[name] = k
    keys[#keys + 1] = { name = name, key = k }
  end
  if #keys == 0 then return "{}" end
  table.sort(keys, function(a, b) return a.name < b.name end)
  local parts = {}
  for _, entry in ipairs(keys) do
    parts[#parts + 1] = child .. vim.json.encode(entry.name) .. ": "
      .. M.encode_pretty(value[entry.key], child)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

---ensure_dir creates `path` with owner-only permissions.
---
---0700 because a document store may hold quoted source and the directory
---listing itself can reveal what someone is working on. Neither belongs to the
---group.
---@param path string
---@return boolean
function M.ensure_dir(path)
  if type(path) ~= "string" or path == "" then return false end
  if uv.fs_stat(path) then return true end
  return vim.fn.mkdir(path, "p", 448) == 1 or uv.fs_stat(path) ~= nil
end

---exists reports whether a path is present at all.
---@param path string
---@return boolean
function M.exists(path)
  return type(path) == "string" and path ~= "" and uv.fs_stat(path) ~= nil
end

---kind reports WHAT is at `path`: "file", "directory", "link", and so on.
---
---nil means absent. A caller that must reject a directory sitting where a
---document belongs needs this, and the alternative — handing back a raw stat
---table — would put filesystem details back in the caller that this module
---exists to hold. Only ENOENT is absence, as everywhere else here.
---@param path string
---@return string? kind, string? err
function M.kind(path)
  if type(path) ~= "string" or path == "" then return nil, "no path" end
  local st, serr, scode = uv.fs_stat(path)
  if not st then
    if scode == "ENOENT" then return nil, nil end
    return nil, ("unreadable: %s (%s: %s)")
      :format(path, tostring(scode or "?"), tostring(serr or "stat failed"))
  end
  return st.type, nil
end

---mtime returns a comparable modification time in nanoseconds, or nil.
---@param path string
---@return integer?
function M.mtime(path)
  local st = type(path) == "string" and path ~= "" and uv.fs_stat(path) or nil
  if not st or not st.mtime then return nil end
  return st.mtime.sec * 1000000000 + (st.mtime.nsec or 0)
end

---write replaces a document ATOMICALLY.
---
---Atomic because a half-written document that still parses is worse than no
---document: a reader cannot tell the difference, and the store's whole value is
---that what it hands back was written on purpose.
---@param path string
---@param content string
---@return boolean ok, string? err
function M.write(path, content)
  if type(path) ~= "string" or path == "" then return false, "no path" end
  if not M.ensure_dir(vim.fn.fnamemodify(path, ":h")) then
    return false, "could not create " .. vim.fn.fnamemodify(path, ":h")
  end
  local ok_atomic, atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(atomic.write) == "function" then
    if atomic.write(path, content) then return true, nil end
    return false, "atomic write failed"
  end
  local fd, oerr = io.open(path, "w")
  if not fd then return false, tostring(oerr or ("could not open " .. path)) end
  fd:write(content)
  fd:close()
  return true, nil
end

---write_json writes `value` as pretty, stable-ordered JSON with a trailing
---newline, atomically.
---@param path string
---@param value any
---@return boolean ok, string? err
function M.write_json(path, value)
  local ok_enc, encoded = pcall(M.encode_pretty, value)
  if not ok_enc then return false, "encode failed: " .. tostring(encoded) end
  return M.write(path, encoded .. "\n")
end

---read returns a document's bytes, or nil.
---
---Nil means ABSENT; a second return distinguishes "present but unreadable", so
---a caller can tell a fresh store from a broken one.
---@param path string
---@return string? content, string? err
function M.read(path)
  if type(path) ~= "string" or path == "" then return nil, "no path" end
  -- STAT FIRST. `io.open` alone cannot tell the two cases apart: it returns nil
  -- both for a document that does not exist and for one that exists but cannot
  -- be opened (EACCES, a directory in the way, an exhausted fd table). This
  -- function reported BOTH as (nil, nil) — "absent" — so a review that is
  -- present and unreadable read back as "no review here". Reproduced against a
  -- chmod-000 document before this was written; the migration gate found it by
  -- comparing against worktree.store, which has always stated first.
  -- ONLY ENOENT MEANS ABSENT (lector MF2). `io.open` alone cannot tell the two
  -- cases apart: it returns nil both for a document that does not exist and for
  -- one that exists but cannot be opened. This function reported BOTH as
  -- (nil, nil) -- "absent" -- so a review that was present and unreadable read
  -- back as "no review here". Stat is not enough either: a stat that fails for
  -- EACCES on a parent directory is also not absence, so libuv's errno name is
  -- bound and only ENOENT is allowed through.
  local st, serr, scode = uv.fs_stat(path)
  if not st then
    if scode == "ENOENT" then return nil, nil end
    return nil, ("unreadable: %s (%s: %s)")
      :format(path, tostring(scode or "?"), tostring(serr or "stat failed"))
  end
  local fd, oerr = io.open(path, "r")
  if not fd then
    return nil, ("unreadable: %s (%s)"):format(path, tostring(oerr or "open failed"))
  end
  local content = fd:read("*a")
  fd:close()
  if content == nil then return nil, "unreadable: " .. path end
  return content, nil
end

---read_json decodes a document. Nil with no error means absent; nil with an
---error means present and undecodable.
---@param path string
---@return any? value, string? err
function M.read_json(path)
  local content, err = M.read(path)
  if err then return nil, err end
  if content == nil then return nil, nil end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then return nil, "malformed json: " .. path end
  return decoded, nil
end

---create_exclusive writes a document ONLY if it does not already exist.
---
---The primitive every "claim this identity" protocol rests on. Exclusivity is
---the filesystem's, not a check-then-write: `O_EXCL` fails if the path appeared
---between the look and the write, which is exactly the race a
---`if not exists then write` cannot close.
---@param path string
---@param content string
---@return boolean claimed, string? err   claimed=false with err=nil means "taken"
function M.create_exclusive(path, content)
  if type(path) ~= "string" or path == "" then return false, "no path" end
  if not M.ensure_dir(vim.fn.fnamemodify(path, ":h")) then
    return false, "could not create " .. vim.fn.fnamemodify(path, ":h")
  end
  if uv.fs_stat(path) then return false, nil end -- cheap pre-check; link is the real gate

  -- WRITE THEN LINK, not open-O_EXCL-then-write. `O_EXCL` publishes the name
  -- before the content exists, so a reader between the open and the write sees
  -- a claim record with no owner in it — and this store's whole promise is that
  -- what it hands back was written on purpose. `link` fails with EEXIST when
  -- the target is taken, which makes "claim this name" a single atomic step
  -- that can never publish a partially-written file. `rename` cannot do this:
  -- it overwrites.
  local tmp = path .. ".claim." .. tostring(uv.os_getpid and uv.os_getpid() or 0)
  local fd, oerr = uv.fs_open(tmp, "w", 384) -- 0600
  if not fd then return false, "temp open failed: " .. tostring(oerr) end
  -- BIND libuv's result AND compare the byte count. `pcall(uv.fs_write, ...)`
  -- reports only whether Lua threw, so a normal (nil, err, EIO) return read as
  -- success -- fault injection published an empty record with claimed=true.
  -- A partial write is the same defect with a subtler shape.
  local wrote, werr, wcode = uv.fs_write(fd, content, 0)
  pcall(uv.fs_fsync, fd)
  pcall(uv.fs_close, fd)
  if wrote ~= #content then
    pcall(uv.fs_unlink, tmp)
    return false, ("write failed: %s of %d bytes (%s: %s)"):format(
      tostring(wrote), #content, tostring(wcode or "?"),
      tostring(werr or "short write"))
  end

  local linked, lerr = uv.fs_link(tmp, path)
  pcall(uv.fs_unlink, tmp)
  if linked then return true, nil end
  -- EEXIST is the expected "someone else claimed it" outcome, not a failure.
  if tostring(lerr):match("EEXIST") then return false, nil end
  return false, "link failed: " .. tostring(lerr)
end

---delete removes a document.
---
---Absent counts as deleted: a caller asking for a path to be gone is satisfied
---by it already being gone, and reporting failure there turns idempotent
---cleanup into error handling.
---@param path string
---@return boolean ok, string? err
function M.delete(path)
  if type(path) ~= "string" or path == "" then return false, "no path" end
  -- ONLY ENOENT IS ALREADY-DELETED, the same distinction `read` makes. Mapping
  -- every stat failure to "gone" reported ok=true for a file that was still
  -- there and merely unreadable (lector r1 MF5) -- which becomes
  -- safety-critical in P4c, where this primitive decides whether the artifacts
  -- a delete PROMISED to remove are actually gone.
  local st, serr, scode = uv.fs_stat(path)
  if not st then
    if scode == "ENOENT" then return true, nil end
    return false, ("cannot delete %s (%s: %s)")
      :format(path, tostring(scode or "?"), tostring(serr or "stat failed"))
  end
  local ok, err, code = uv.fs_unlink(path)
  if not ok then
    -- Someone else removed it between the stat and the unlink: the caller asked
    -- for it to be gone, and it is gone.
    if code == "ENOENT" then return true, nil end
    return false, tostring(err or "unlink failed")
  end
  return true, nil
end

---list returns the entry names in `dir`, optionally filtered by a Lua pattern.
---Names only, sorted, never paths — the caller owns path construction.
---@param dir string
---@param pattern string?
---@return string[]
function M.list(dir, pattern)
  local out = {}
  if type(dir) ~= "string" or dir == "" then return out end
  local h = uv.fs_scandir(dir)
  if not h then return out end
  while true do
    local name, typ = uv.fs_scandir_next(h)
    if not name then break end
    -- DIRECTORIES ARE NOT DOCUMENTS. Returning them let a directory whose name
    -- matched the record grammar be counted as a record: a directory called
    -- `sub.r9.reserve` made `revisions.max_recorded` report r9 and burn nine
    -- revision numbers. Reproduced before this was written.
    if typ ~= "directory" and (not pattern or name:match(pattern)) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---The lock lives in `docstore.lock`, and `with_lock` is re-exported here so a
---caller has one entry point for the whole store. It is the lock from
---worktree.store, MOVED rather than reimplemented: an owner record, an enum-
---driven liveness decision, pid-reuse detection, a 10-second contention window
---that drives its own retry loop, and an inode-guarded release. See that
---module's header for why each exists.
---
---This file first shipped a 500ms pathname-unlinking lock with no owner record,
---which would have deleted six rounds of hardening the moment worktree
---delegated to it. `LOCK_WAIT_MS` is re-exported too so the constant has one
---value in the family, not two that drift.
local lock = require("auto-core.docstore.lock")

M.LOCK_WAIT_MS = lock.LOCK_WAIT_MS
M.LOCK_POLL_MS = lock.LOCK_POLL_MS

---with_lock runs `fn` while holding an exclusive lock beside `path`.
---
---Returns `(value, err)` — the convention worktree.store's callers already
---use, so delegation is a pass-through and not a translation layer that could
---invert a failure into a success.
---@param path string
---@param fn fun():any,any?
---@param opts { wait_ms: integer?, poll_ms: integer? }?
---@return any? value, string? err, any? completed_value
function M.with_lock(path, fn, opts)
  return lock.with_lock(path, fn, opts)
end

M.lock = lock

M.revisions = require("auto-core.docstore.revisions")

return M
