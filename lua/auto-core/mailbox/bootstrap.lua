---auto-core.mailbox.bootstrap — render the per-mailbox bootstrap doc
---from the canonical template and upsert it into the mailbox tree.
---
---Every `register(id, opts)` rewrites `bootstrap-mailbox.md` so the
---doc always reflects the current protocol. The `revision:` field
---in the frontmatter is the sha256 of the rendered body MINUS the
---revision line itself — that way "same content" → "same revision",
---regardless of when it was written. Agents compare this revision
---to their last-acknowledged value on wake to detect protocol
---changes (see the template body for the audit protocol).
---
---Template lookup: `lua/auto-core/mailbox/templates/bootstrap.md`,
---resolved relative to this module's source file. Family plugins
---can supply per-tool overrides in a future patch; v0.1.6 ships
---one template for everyone.
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

---Build the wake summary line shown in the doc for the agent to
---understand its wake mechanism.
---@param wake table?
---@return string
local function wake_summary(wake)
  if type(wake) ~= "table" or type(wake.command) ~= "string" then
    return "none (this mailbox has no wake hook; consumers must poll)"
  end
  local args = vim.json.encode(wake.args or {})
  return string.format("dispatch registered command `%s` with args %s",
    wake.command, args)
end

---Render a bootstrap doc for `id`. Returns (text, revision) — both
---always set. Revision is the sha256 of the rendered body WITH the
---revision placeholder substituted as "PLACEHOLDER"; that way two
---calls with identical inputs produce identical revisions even
---though `upserted_at` differs.
---@param opts { id: string, dir: string, wake: table? }
---@return string text, string revision
function M.render(opts)
  local raw, err = M.read_template()
  if not raw then error("auto-core.mailbox.bootstrap: " .. tostring(err)) end

  -- First pass: render with revision = "PLACEHOLDER" so we can hash
  -- a stable representation that doesn't depend on the timestamp.
  local stable_vars = {
    id           = opts.id,
    dir          = opts.dir,
    revision     = "PLACEHOLDER",
    upserted_at  = "PLACEHOLDER",
    wake_summary = wake_summary(opts.wake),
  }
  local stable = substitute(raw, stable_vars)
  local revision = sha256(stable)

  -- Second pass: render with the real revision + timestamp.
  local final_vars = {
    id           = opts.id,
    dir          = opts.dir,
    revision     = revision,
    upserted_at  = message.now_iso(),
    wake_summary = wake_summary(opts.wake),
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

---Render and upsert `bootstrap-mailbox.md` into the mailbox dir.
---Always writes (matches the "register is idempotent — protocol
---updates propagate automatically" design intent).
---@param opts { id: string, dir: string, wake: table? }
---@return { path: string, revision: string }
function M.upsert(opts)
  local text, revision = M.render(opts)
  local path = opts.dir .. "/bootstrap-mailbox.md"
  local ok, err = atomic_write(path, text)
  if not ok then
    error("auto-core.mailbox.bootstrap.upsert: " .. tostring(err))
  end
  return { path = path, revision = revision }
end

return M