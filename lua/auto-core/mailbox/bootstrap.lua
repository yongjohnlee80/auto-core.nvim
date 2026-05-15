---auto-core.mailbox.bootstrap — render the canonical bootstrap doc
---and upsert it at the per-tool-root location.
---
---v0.1.8 hoists the doc from `<mailbox-dir>/bootstrap-mailbox.md`
---(per agent, content with `{{id}}` and `{{dir}}` substituted) to
---`<tool-root>/bootstrap-mailbox.md` (one doc per tool root,
---agent-agnostic — agents discover their identity via spawn-time
---env vars). The template has no per-call substitutions beyond
---`{{revision}}` / `{{upserted_at}}`, so every agent under a given
---tool root sees the same doc and the same revision.
---
---`register(id, opts)` calls `upsert({ tool_root })` to keep
---`<tool-root>/bootstrap-mailbox.md` in sync with the canonical
---protocol. The `revision:` field in the frontmatter is the sha256
---of the rendered body with placeholders substituted — "same
---content" → "same revision", regardless of when it was written.
---Agents compare this revision to their last-acknowledged value on
---wake to detect protocol changes (see template body).
---
---v0.1.7's no-op short-circuit is preserved: if the existing doc's
---revision already matches the rendered revision, the atomic write
---is skipped. The return shape carries `wrote: boolean`.
---
---Template lookup: `lua/auto-core/mailbox/templates/bootstrap.md`,
---resolved relative to this module's source file. Family plugins
---can supply per-tool overrides in a future patch; v0.1.6–v0.1.8
---all ship one template for everyone.
---
---@module 'auto-core.mailbox.bootstrap'

local message = require("auto-core.mailbox.message")

local M = {}

-- ── template resolution ─────────────────────────────────────

---Absolute path to the canonical template shipped in this plugin.
---Computed once at module load; the file is part of the plugin
---tree so any rtp-prepended install finds it.
---@return string
local function template_path()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local self_dir = vim.fn.fnamemodify(src, ":h")
  return self_dir .. "/templates/bootstrap.md"
end

---Read the raw template body. Returns text, err — exactly one is nil.
---@return string? text, string? err
function M.read_template()
  local path = template_path()
  local fd, oerr = vim.uv.fs_open(path, "r", 420)
  if not fd then return nil, "bootstrap: cannot open template at "
                             .. tostring(path) .. ": " .. tostring(oerr) end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    pcall(vim.uv.fs_close, fd)
    return nil, "bootstrap: cannot stat template"
  end
  local data, rerr = vim.uv.fs_read(fd, stat.size, 0)
  pcall(vim.uv.fs_close, fd)
  if not data then return nil, "bootstrap: read failed: " .. tostring(rerr) end
  return data
end

-- ── rendering ───────────────────────────────────────────────

---@param raw  string
---@param vars table<string, string>
---@return string
local function substitute(raw, vars)
  -- Two-pass `{{var}}` substitution. Escape replacement so `%` in
  -- the value isn't interpreted as a capture reference by gsub.
  local function escape_replacement(s)
    return (s:gsub("%%", "%%%%"))
  end
  return (raw:gsub("{{%s*([%w_]+)%s*}}", function(name)
    local v = vars[name]
    if v == nil then return "" end
    return escape_replacement(tostring(v))
  end))
end

---Compute a short hex sha256 over a string. Uses vim.fn.sha256
---which is present on every modern nvim build.
---@param text string
---@return string
local function sha256(text) return vim.fn.sha256(text) end

---Render the canonical bootstrap doc. v0.1.8: agent-agnostic —
---no per-call substitutions beyond `{{revision}}` / `{{upserted_at}}`.
---Returns (text, revision). Revision is the sha256 of the body with
---both placeholders substituted with literal "PLACEHOLDER" so two
---calls produce identical revisions regardless of when they ran.
---
---`opts` is accepted for forward-compat but currently unused (all
---template variables are agent-agnostic at the v0.1.8 schema).
---@param opts table?
---@return string text, string revision
function M.render(opts)
  local _ = opts  -- reserved for future per-tool overrides
  local raw, err = M.read_template()
  if not raw then error("auto-core.mailbox.bootstrap: " .. tostring(err)) end

  local stable_vars = {
    revision    = "PLACEHOLDER",
    upserted_at = "PLACEHOLDER",
  }
  local stable = substitute(raw, stable_vars)
  local revision = sha256(stable)

  local final_vars = {
    revision    = revision,
    upserted_at = message.now_iso(),
  }
  return substitute(raw, final_vars), revision
end

-- ── upsert ──────────────────────────────────────────────────

---@param path string
---@param text string
---@return boolean ok, string? err
local function atomic_write(path, text)
  -- Same primitive as transport — write to a sibling tmp, fsync,
  -- rename. Inlined here so this module doesn't depend on transport
  -- (transport would otherwise be a circular peer of registry).
  local dir = vim.fn.fnamemodify(path, ":h")
  local tmp = dir .. "/.tmp-bootstrap-" .. tostring(vim.uv.hrtime())
  local fd, oerr = vim.uv.fs_open(tmp, "w", 420)
  if not fd then return false, "fs_open: " .. tostring(oerr) end
  local _, werr = vim.uv.fs_write(fd, text, 0)
  if werr then
    pcall(vim.uv.fs_close, fd)
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_write: " .. tostring(werr)
  end
  pcall(vim.uv.fs_fsync, fd)
  pcall(vim.uv.fs_close, fd)
  local rok, rerr = vim.uv.fs_rename(tmp, path)
  if not rok then
    pcall(vim.uv.fs_unlink, tmp)
    return false, "fs_rename: " .. tostring(rerr)
  end
  return true
end

---Read the `revision:` value from an existing bootstrap doc's
---frontmatter, without parsing the full file. Returns nil if the
---file doesn't exist or has no revision line — both cases force
---a write in `upsert`.
---
---Frontmatter is fixed-shape (mailbox_id, mailbox_dir, revision,
---upserted_at, schema_version) at the top of the file; a single
---small read covers it on every reasonable filesystem.
---@param path string
---@return string?
local function read_existing_revision(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then return nil end
  -- 512 bytes is well past the largest plausible frontmatter
  -- (current shape is ~180 bytes including the closing `---`).
  local data = vim.uv.fs_read(fd, 512, 0)
  pcall(vim.uv.fs_close, fd)
  if type(data) ~= "string" or data == "" then return nil end
  -- Match the frontmatter `revision:` line specifically. Anchor to
  -- a newline (or start of file) so a `revision:` token inside the
  -- body — unlikely, but cheap to guard — doesn't get mis-matched.
  return data:match("\nrevision:%s*([%w]+)")
      or data:match("^revision:%s*([%w]+)")
end

---Render and upsert `bootstrap-mailbox.md` into the **tool root**
---(v0.1.8 layout — one doc per tool root, not per-mailbox). No-op
---short-circuit: if the existing doc on disk already carries the
---rendered revision, skip the atomic write entirely. This keeps
---mtime stable and silences the router fs.watch on repeat
---`register()` calls with unchanged protocol inputs.
---@param opts { tool_root: string }
---@return { path: string, revision: string, wrote: boolean }
function M.upsert(opts)
  if type(opts) ~= "table" or type(opts.tool_root) ~= "string"
      or opts.tool_root == "" then
    error("auto-core.mailbox.bootstrap.upsert: opts.tool_root "
      .. "(absolute path) is required")
  end
  local text, revision = M.render()
  local path = opts.tool_root .. "/bootstrap-mailbox.md"
  if read_existing_revision(path) == revision then
    return { path = path, revision = revision, wrote = false }
  end
  -- Ensure tool root exists before writing — register() normally
  -- creates the mailbox subtree which would mkdir the parent, but
  -- a caller invoking upsert directly might not have.
  vim.fn.mkdir(opts.tool_root, "p")
  local ok, err = atomic_write(path, text)
  if not ok then
    error("auto-core.mailbox.bootstrap.upsert: " .. tostring(err))
  end
  return { path = path, revision = revision, wrote = true }
end

return M