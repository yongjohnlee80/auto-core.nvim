---auto-core.mailbox.bootstrap — render the canonical bootstrap doc
---and upsert it at the workspace-mailbox-root location.
---
---v0.1.8 hoisted the doc from `<mailbox-dir>/bootstrap-mailbox.md`
---(per agent, content with `{{id}}` and `{{dir}}` substituted) to
---a single doc per root, agent-agnostic — agents discover their
---identity via spawn-time env vars. v0.1.33 then re-anchored the
---root from per-CLI config dirs to a workspace-scoped location:
---`<workspace_root>/.auto-agents/mailbox/bootstrap-mailbox.md`
---(one doc per workspace mailbox root; resolved via
---`auto-core.git.worktree` state). The template has no per-call
---substitutions beyond `{{revision}}` / `{{upserted_at}}`, so every
---agent under a given workspace root sees the same doc and the same
---revision.
---
---`register(id, opts)` calls `upsert({ root })` to keep
---`<root>/bootstrap-mailbox.md` in sync with the canonical protocol.
---The `revision:` field in the frontmatter is the sha256 of the
---rendered body with placeholders substituted — "same content" →
---"same revision", regardless of when it was written. Agents compare
---this revision to their last-acknowledged value on wake to detect
---protocol changes (see template body).
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

---Absolute path to a template shipped in this plugin. `name` defaults
---to the canonical mailbox bootstrap; `permission.md` (ADR-0036) is the
---peer permission guideline. Computed relative to this module so any
---rtp-prepended install finds it.
---@param name string?  -- template basename; default "bootstrap.md"
---@return string
local function template_path(name)
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local self_dir = vim.fn.fnamemodify(src, ":h")
  return self_dir .. "/templates/" .. (name or "bootstrap.md")
end

---Read the raw template body. Returns text, err — exactly one is nil.
---@param name string?  -- template basename; default "bootstrap.md"
---@return string? text, string? err
function M.read_template(name)
  local path = template_path(name)
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
---Render a template by basename. Revision is the sha256 of the body
---with placeholders substituted, so identical content → identical
---revision regardless of when it ran.
---@param name string?  -- template basename; default "bootstrap.md"
---@return string text, string revision
local function render_template(name)
  local raw, err = M.read_template(name)
  if not raw then error("auto-core.mailbox.bootstrap: " .. tostring(err)) end
  local stable = substitute(raw, { revision = "PLACEHOLDER", upserted_at = "PLACEHOLDER" })
  local revision = sha256(stable)
  return substitute(raw, { revision = revision, upserted_at = message.now_iso() }), revision
end

---Render the canonical mailbox bootstrap doc. `opts` reserved for
---forward-compat (template vars are agent-agnostic at this schema).
---@param opts table?
---@return string text, string revision
function M.render(opts)
  local _ = opts
  return render_template("bootstrap.md")
end

---Render the ADR-0036 permission guideline doc (`PERMISSION.md`).
---@param opts table?
---@return string text, string revision
function M.render_permission(opts)
  local _ = opts
  return render_template("permission.md")
end

-- ── upsert ──────────────────────────────────────────────────

---@param path string
---@param text string
---@return boolean ok, string? err
local function atomic_write(path, text)
  -- Delegates to the shared `fs.atomic.write` primitive (ADR-0038
  -- Batch E). Historically inlined here to avoid depending on
  -- transport (a circular peer of registry); fs.atomic has no
  -- mailbox dependencies, so the cycle concern is gone.
  return require("auto-core.fs.atomic").write(path, text)
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

---Render and upsert `bootstrap-mailbox.md` into the **workspace
---mailbox root** (v0.1.33 layout — one doc per workspace, not
---per-mailbox; replaces the v0.1.8 per-tool-root location). No-op
---short-circuit: if the existing doc on disk already carries the
---rendered revision, skip the atomic write entirely. This keeps
---mtime stable and silences the router fs.watch on repeat
---`register()` calls with unchanged protocol inputs.
---@param opts { root: string }  -- workspace mailbox root (absolute path)
---@return { path: string, revision: string, wrote: boolean }
---Generic render-and-upsert into the workspace mailbox root, with the
---revision no-op short-circuit. Shared by the mailbox bootstrap doc
---and the ADR-0036 permission guideline. `render_fn` returns
---(text, revision). `root` must be an absolute path.
---@param root string
---@param render_fn fun(): string, string
---@param out_name string
---@param label string
---@return { path: string, revision: string, wrote: boolean }
local function upsert_doc(root, render_fn, out_name, label)
  if type(root) ~= "string" or root == "" then
    error("auto-core.mailbox.bootstrap." .. label
      .. ": opts.root (absolute path) is required")
  end
  local text, revision = render_fn()
  local path = root .. "/" .. out_name
  if read_existing_revision(path) == revision then
    return { path = path, revision = revision, wrote = false }
  end
  -- Ensure root exists before writing — register() normally creates
  -- the mailbox subtree (mkdir-ing the parent), but a direct caller
  -- might not have.
  vim.fn.mkdir(root, "p")
  local ok, err = atomic_write(path, text)
  if not ok then
    error("auto-core.mailbox.bootstrap." .. label .. ": " .. tostring(err))
  end
  return { path = path, revision = revision, wrote = true }
end

function M.upsert(opts)
  if type(opts) ~= "table" then
    error("auto-core.mailbox.bootstrap.upsert: opts.root "
      .. "(absolute path) is required")
  end
  return upsert_doc(opts.root, M.render, "bootstrap-mailbox.md", "upsert")
end

---Render + upsert the ADR-0036 `PERMISSION.md` guideline into the
---**workspace mailbox root** (peer to `bootstrap-mailbox.md`; same
---no-op-on-unchanged-revision short-circuit). Advisory doc — callers
---should not treat a write failure as fatal to mailbox bootstrap.
---@param opts { root: string }
---@return { path: string, revision: string, wrote: boolean }
function M.upsert_permission(opts)
  if type(opts) ~= "table" then
    error("auto-core.mailbox.bootstrap.upsert_permission: opts.root "
      .. "(absolute path) is required")
  end
  return upsert_doc(opts.root, M.render_permission, "PERMISSION.md", "upsert_permission")
end

return M