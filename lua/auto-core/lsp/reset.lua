---auto-core.lsp.reset — tech-stack-aware LSP restart on workspace
---switch.
---
---Per [[0007-worktree-absorbs-gitsgraph-via-auto-core]] §Phase 1
---Step 1.1. Replaces worktree.nvim's static-list
---`restart_workspace_lsps` (which restarted every server in a
---configured list unconditionally — a Go-only switch still
---restarted ts_ls, producing false errors during the cold-start
---window).
---
---Strategy: stop-mismatched + lazy re-attach. We enumerate
---`vim.lsp.get_clients()` and stop every client that (a) is in the
---set of servers belonging to the new path's detected stack, AND
---(b) has a `root_dir` that does NOT lie under the new path. Other
---clients are left running undisturbed (they may serve unrelated
---buffers — a stray markdown, config, etc.). Re-attach is delegated
---to lspconfig's existing `LspAttach` autocmd flow on the next
---BufEnter / FileType — we do NOT eagerly start servers.
---
---Tech-stack detection walks UP from `path` until it finds a
---directory containing one or more known marker files; matched
---markers there are OR-combined into the considered server set.
---A polyglot directory (rare — e.g. a tool repo with both `go.mod`
---and `package.json`) gets the union.
---
---Public surface:
---
---  reset.detect_stack(path)              → string[]   server names
---  reset.preview(path, opts?)            → { stopped, untouched }
---  reset.reset_for(path, opts?)          → { stopped, untouched }
---  reset.register_stack(marker, servers) → ok, err?
---  reset.list_stacks()                   → table       (read-only snapshot)
---
---Opts (all optional):
---  dry_run        boolean   — if true, preview without stopping
---  extra_servers  string[]  — append to detected stack (e.g. user's
---                             pre-existing `lsp_servers_to_restart`)
---  exclude        string[]  — never touch these client names
---
---Topic: `core.lsp:reset` published on every `reset_for`. Payload
---`{ path, stopped: { name, id }[], detected_stack: string[],
---dry_run: boolean }`. Lets `:checkhealth` and observability
---consumers track resets.
---@module 'auto-core.lsp.reset'

local events = require("auto-core.events")

local M = {}

-- Marker → server names. Mutable at runtime via register_stack;
-- snapshotted at module load for _reset_for_tests.
local _stacks = {
  ["go.mod"]            = { "gopls", "golangci_lint_ls" },
  ["package.json"]      = { "ts_ls", "eslint", "biome", "vtsls" },
  ["pyproject.toml"]    = { "pyright", "ruff", "ruff_lsp" },
  ["setup.py"]          = { "pyright", "ruff", "ruff_lsp" },
  ["requirements.txt"]  = { "pyright", "ruff", "ruff_lsp" },
  ["Cargo.toml"]        = { "rust_analyzer" },
  ["lazy-lock.json"]    = { "lua_ls" },
  [".luarc.json"]       = { "lua_ls" },
  [".luarc.jsonc"]      = { "lua_ls" },
  ["build.zig"]         = { "zls" },
  ["deno.json"]         = { "denols" },
  ["deno.jsonc"]        = { "denols" },
  ["Gemfile"]           = { "solargraph", "ruby_lsp" },
  ["composer.json"]     = { "intelephense", "phpactor" },
  ["pubspec.yaml"]      = { "dartls" },
  ["mix.exs"]           = { "elixirls", "lexical" },
}
local _DEFAULT_STACKS = vim.deepcopy(_stacks)

local TOPIC = "core.lsp:reset"

local function _normalize(path)
  if not path or path == "" then return vim.fs.normalize(vim.fn.getcwd()) end
  return vim.fs.normalize(path)
end

---Walk up from `path` until we find a directory containing one or
---more markers. Returns `{ dir, markers }` or nil.
local function _find_project_root(path)
  local cur = _normalize(path)
  if vim.fn.isdirectory(cur) ~= 1 then
    cur = vim.fn.fnamemodify(cur, ":h")
  end
  while cur and cur ~= "" and cur ~= "/" do
    local matched = {}
    for marker, _ in pairs(_stacks) do
      local probe = cur .. "/" .. marker
      if vim.fn.filereadable(probe) == 1
          or vim.fn.isdirectory(probe) == 1 then
        matched[#matched + 1] = marker
      end
    end
    if #matched > 0 then
      return { dir = cur, markers = matched }
    end
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur then break end
    cur = parent
  end
  return nil
end

---Detect the LSP-server set plausibly relevant for `path`. Walks
---up to find the project root (first dir with any known marker)
---and unions the servers for every marker present there.
---@param path string?
---@return string[]
function M.detect_stack(path)
  local found = _find_project_root(path)
  if not found then return {} end
  local seen, out = {}, {}
  for _, marker in ipairs(found.markers) do
    for _, srv in ipairs(_stacks[marker] or {}) do
      if not seen[srv] then
        seen[srv] = true
        out[#out + 1] = srv
      end
    end
  end
  return out
end

---Register additional servers for a marker. Idempotent — already-
---registered servers are de-duplicated. Use to extend the table at
---runtime without forking auto-core (e.g. a project-local plugin
---that uses an unusual LSP).
---@param marker string
---@param servers string[]
---@return boolean ok, string? err
function M.register_stack(marker, servers)
  if type(marker) ~= "string" or marker == "" then
    return false, "register_stack: marker must be a non-empty string"
  end
  if type(servers) ~= "table" then
    return false, "register_stack: servers must be a string[]"
  end
  _stacks[marker] = _stacks[marker] or {}
  local seen = {}
  for _, s in ipairs(_stacks[marker]) do seen[s] = true end
  for _, s in ipairs(servers) do
    if type(s) == "string" and #s > 0 and not seen[s] then
      _stacks[marker][#_stacks[marker] + 1] = s
      seen[s] = true
    end
  end
  return true
end

---Read-only snapshot of the marker → servers table. Useful for
---`:checkhealth auto-core` to print the current detection rules.
---@return table<string, string[]>
function M.list_stacks()
  return vim.deepcopy(_stacks)
end

---Predicate: does `client_root` lie at or under `path`?
local function _under(client_root, path)
  if not client_root or client_root == "" then return false end
  local norm_root = vim.fs.normalize(client_root)
  if norm_root == path then return true end
  return norm_root:sub(1, #path + 1) == path .. "/"
end

---Read-only enumeration. Returns the partition of current clients
---under the same logic `reset_for` will apply.
---@param path string?
---@param opts table?
---@return { stopped: vim.lsp.Client[], untouched: vim.lsp.Client[] }
function M.preview(path, opts)
  opts = opts or {}
  path = _normalize(path)

  local stack = M.detect_stack(path)
  local consider = {}
  for _, s in ipairs(stack) do consider[s] = true end
  for _, s in ipairs(opts.extra_servers or {}) do consider[s] = true end

  local exclude_set = {}
  for _, e in ipairs(opts.exclude or {}) do exclude_set[e] = true end

  local stopped, untouched = {}, {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    if exclude_set[client.name] then
      untouched[#untouched + 1] = client
    elseif not consider[client.name] then
      -- Not in the stack we care about; leave alone (may serve an
      -- unrelated buffer the user still wants).
      untouched[#untouched + 1] = client
    elseif _under(client.root_dir, path) then
      -- Already correctly rooted under the new path; keep.
      untouched[#untouched + 1] = client
    else
      stopped[#stopped + 1] = client
    end
  end
  return { stopped = stopped, untouched = untouched }
end

---Stop every mismatched client per `preview`, then publish
---`core.lsp:reset`. `dry_run = true` skips the actual stop but
---still publishes (with `dry_run = true` in the payload).
---@param path string?
---@param opts table?
---@return { stopped: vim.lsp.Client[], untouched: vim.lsp.Client[] }
function M.reset_for(path, opts)
  opts = opts or {}
  path = _normalize(path)
  local result = M.preview(path, opts)
  if not opts.dry_run then
    for _, client in ipairs(result.stopped) do
      pcall(vim.lsp.stop_client, client.id, true)
    end
  end
  events.publish(TOPIC, {
    path           = path,
    stopped        = vim.tbl_map(
      function(c) return { name = c.name, id = c.id } end,
      result.stopped),
    detected_stack = M.detect_stack(path),
    dry_run        = opts.dry_run == true,
  })
  return result
end

---Test-only: restore the marker table to module-load defaults.
function M._reset_for_tests()
  _stacks = vim.deepcopy(_DEFAULT_STACKS)
end

return M
