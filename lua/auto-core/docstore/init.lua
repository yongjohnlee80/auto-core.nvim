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
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = tostring(k) end
  if #keys == 0 then return "{}" end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = child .. vim.json.encode(k) .. ": "
      .. M.encode_pretty(value[k], child)
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
  local fd = io.open(path, "r")
  if not fd then return nil, nil end
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
  local fd, oerr, ecode = uv.fs_open(path, "wx", 384) -- 0600
  if not fd then
    -- EEXIST is the ordinary "someone else has it" answer, not a failure.
    if ecode == "EEXIST" or tostring(oerr):find("EEXIST", 1, true) then
      return false, nil
    end
    return false, tostring(oerr or "open failed")
  end
  local ok_w, werr = pcall(uv.fs_write, fd, content, 0)
  pcall(uv.fs_close, fd)
  if not ok_w then return false, tostring(werr) end
  return true, nil
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
  if not uv.fs_stat(path) then return true, nil end
  local ok, err = uv.fs_unlink(path)
  if not ok then return false, tostring(err or "unlink failed") end
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
    local name = uv.fs_scandir_next(h)
    if not name then break end
    if not pattern or name:match(pattern) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

---LOCK_WAIT_MS is how long `with_lock` waits for a contested lock.
---
---A CONTENTION WINDOW and nothing more. Age never establishes that a holder is
---dead, so no path here breaks a lock; the constant DRIVES the retry loop so the
---documented figure and the real one cannot drift apart.
M.LOCK_WAIT_MS = 500

---with_lock runs `fn` while holding an exclusive lock beside `path`.
---
---The lock is a document like any other, claimed with `create_exclusive`, so the
---mutual exclusion is the filesystem's. It is released on every exit path,
---including an error inside `fn` — a lock leaked by a raising callback would
---wedge the store for the rest of the session.
---@param path string
---@param fn fun(): any
---@return boolean ok, any result_or_err
function M.with_lock(path, fn)
  if type(path) ~= "string" or path == "" then return false, "no path" end
  if type(fn) ~= "function" then return false, "with_lock: fn required" end
  local lock = path .. ".lock"
  local waited, step = 0, 10
  while true do
    local claimed, err = M.create_exclusive(lock, tostring(vim.fn.getpid()))
    if claimed then break end
    if err then return false, "lock error: " .. tostring(err) end
    if waited >= M.LOCK_WAIT_MS then
      return false, "lock contended for " .. M.LOCK_WAIT_MS .. "ms: " .. lock
    end
    vim.wait(step)
    waited = waited + step
  end
  local ok, result = pcall(fn)
  pcall(function() uv.fs_unlink(lock) end)
  if not ok then return false, result end
  return true, result
end

M.revisions = require("auto-core.docstore.revisions")

return M
