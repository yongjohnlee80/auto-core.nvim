---Persistence backends for auto-core's namespaced state store.
---
---Each backend exposes a uniform interface:
---   load(path) -> table | nil
---   save(path, table) -> boolean
---
---Phase 2 ships `ephemeral` and `json`. `toml` is reserved as a
---known backend name but errors with a clear message when invoked
---— it lights up in a follow-on iteration once auto-agents's
---existing TOML serializer is extracted into the shared lib.
---
---The default persist root is `vim.fn.stdpath("state") .. "/auto-core/"`
---unless overridden by `cfg.state.persist_dir` at setup. Each
---namespace gets one file: `<root>/<namespace>.<ext>`.
---@module 'auto-core.state.persist'

local M = {}

---Resolve the persist root, creating it if necessary. Falls back to
---a tempdir if writes fail (cleared at session end — caller logs).
---@param override string?
---@return string
function M.resolve_root(override)
  local root = override
  if not root or root == "" then
    root = vim.fn.stdpath("state") .. "/auto-core"
  end
  if vim.fn.isdirectory(root) ~= 1 then
    local ok = pcall(vim.fn.mkdir, root, "p")
    if not ok then
      root = vim.fn.tempname() .. "-auto-core"
      pcall(vim.fn.mkdir, root, "p")
    end
  end
  return root
end

---Compute the absolute file path for a namespace + format.
---@param root string
---@param namespace string
---@param format string  -- "json" | "toml"
---@return string
function M.path_for(root, namespace, format)
  -- Sanitize namespace: only [a-zA-Z0-9_-]; replace anything else
  -- with `_`. Prevents a malicious / malformed namespace from
  -- escaping the persist root via path traversal.
  local safe = (namespace:gsub("[^%w%-_]", "_"))
  return root .. "/" .. safe .. "." .. format
end

-- ── ephemeral ──────────────────────────────────────────────────
M.ephemeral = {}

---@return table
function M.ephemeral.load(_path) return {} end

---@return boolean
function M.ephemeral.save(_path, _data) return true end

-- ── json ──────────────────────────────────────────────────────
M.json = {}

---Read + decode JSON. Missing file → empty table (fresh namespace).
---Malformed file → empty table + warn (don't crash; preserve
---continuity across schema migrations).
---@param path string
---@return table
function M.json.load(path)
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok_read, raw = pcall(vim.fn.readfile, path)
  if not ok_read or type(raw) ~= "table" then return {} end
  local body = table.concat(raw, "\n")
  if body == "" then return {} end
  local ok_decode, decoded = pcall(vim.json.decode, body)
  if not ok_decode or type(decoded) ~= "table" then
    vim.schedule(function()
      vim.notify(
        "auto-core.state: malformed json at " .. path
          .. " — starting from empty (file preserved on disk).",
        vim.log.levels.WARN
      )
    end)
    return {}
  end
  return decoded
end

---Encode + write atomically (write to .tmp then rename) so a
---crash mid-write doesn't leave a corrupt persist file.
---@param path string
---@param data table
---@return boolean
function M.json.save(path, data)
  local ok_encode, encoded = pcall(vim.json.encode, data)
  if not ok_encode then return false end
  local tmp = path .. ".tmp"
  local ok_write = pcall(vim.fn.writefile, vim.split(encoded, "\n"), tmp)
  if not ok_write then return false end
  local ok_rename = pcall(vim.uv.fs_rename, tmp, path)
  return ok_rename == true
end

-- ── toml (deferred) ──────────────────────────────────────────
M.toml = {}

local function toml_not_yet()
  error("auto-core.state: 'toml' persist backend not yet available "
    .. "(deferred to a follow-on iteration; use 'json' or 'ephemeral'). "
    .. "See ADR 0006 §Plan Phase 2 + the v0.0.3 changelog.")
end

M.toml.load = toml_not_yet
M.toml.save = toml_not_yet

-- ── lookup ─────────────────────────────────────────────────────
M.backends = {
  ephemeral = M.ephemeral,
  json      = M.json,
  toml      = M.toml,
}

---Resolve a backend by name. Errors with a clear message on unknown.
---@param name string
---@return { load: fun(path: string): table, save: fun(path: string, data: table): boolean }
function M.get(name)
  local b = M.backends[name]
  if not b then
    error("auto-core.state: unknown persist backend '" .. tostring(name)
      .. "' (must be one of: ephemeral, json, toml).")
  end
  return b
end

return M
