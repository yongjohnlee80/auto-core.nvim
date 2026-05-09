-- auto-core.nvim — smoke test driver
--
-- Run headless:
--   nvim --headless -u tests/smoke.lua -c 'qa!'
--
-- Per the binding convention at
--   ~/.config/nvim/.auto-agents-config/kb/shared/conventions/lua-nvim-plugin-development.md
-- (loaded automatically by the autovim agent kb), every iteration
-- on this plugin must extend or update this driver and run it green
-- before reporting work complete.
--
-- Phase 0: only validates package metadata + setup idempotency.
-- Subsystem tests land alongside their phase implementations:
--   Phase 1 → [2] events
--   Phase 2 → [3] state
--   Phase 3 → [4] ui.panel + [5] ui.winbar + [6] ui.section
--   Phase 4 → [7] fs.watch + [8] git.worktree
--   Phase 5 → [9] tasks
--   Phase 6 → [10] ui.float
--   Phase 7 → [11] log + [12] health
--
-- Discipline (assert-the-contract-not-internals): each `ok()` call
-- targets a public-API observable, never a private helper.

-- ─────────────────────── runtime setup ──────────────────────
-- Prepend the plugin and its hard deps onto the runtimepath so
-- this driver runs with `-u tests/smoke.lua` and finds modules
-- regardless of the user's lazy/packer state.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.rtp:prepend(plugin_root)

-- Hard dep: plenary.nvim. Per ADR 0006 §"Resolutions" #3, plenary is a
-- hard dependency. Probe the standard install paths; fail the suite
-- with a clear message if it's missing rather than silently passing.
local plenary_paths = {
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
}
local plenary_found = false
for _, p in ipairs(plenary_paths) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.rtp:prepend(p)
    plenary_found = true
    break
  end
end

-- ─────────────────────── runner harness ────────────────────
local pass_count, fail_count = 0, 0

local function ok(name, cond, detail)
  if cond then
    print("  PASS  " .. name)
    pass_count = pass_count + 1
  else
    print("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
    fail_count = fail_count + 1
  end
end

local function eq(a, b)
  if a == b then return true end
  return false, "expected " .. tostring(b) .. ", got " .. tostring(a)
end

-- ─────────────────────── 0. environment ────────────────────
print("\n[0] environment")
ok("plenary.nvim discoverable on rtp",
  plenary_found, "checked: " .. table.concat(plenary_paths, ", "))
ok("plenary.path module loads",
  pcall(require, "plenary.path"))

-- ─────────────────────── 1. package metadata ───────────────
print("\n[1] package metadata + public surface")
local ok_req, core = pcall(require, "auto-core")
ok("require('auto-core') succeeds", ok_req, tostring(core))
if not ok_req then
  print(string.format("\n%d passed, %d failed", pass_count, fail_count))
  if fail_count > 0 then os.exit(1) end
  os.exit(0)
end

ok("M.version is a semver string",
  type(core.version) == "string" and core.version:match("^%d+%.%d+%.%d+$") ~= nil,
  tostring(core.version))
ok("M.version is 0.0.1 (Phase 0 scaffold tag)",
  select(1, eq(core.version, "0.0.1")))
ok("M.api_version is 0.0 (pre-stable surface)",
  select(1, eq(core.api_version, "0.0")))
ok("M.setup is a function", type(core.setup) == "function")
ok("M.config table present",
  type(core.config) == "table"
    and type(core.config.events) == "table"
    and type(core.config.events.fire_autocmds) == "boolean")

-- Default config sanity per ADR §"Resolutions" #6 (autocmd-fire opt-in)
ok("default config: events.fire_autocmds == false",
  core.config.events.fire_autocmds == false)
ok("default config: log.level == 'info'",
  core.config.log.level == "info")
ok("default config: state.persist_dir == nil (resolves at runtime)",
  core.config.state.persist_dir == nil)

-- ─────────────────────── 2. setup idempotency ──────────────
print("\n[2] setup() — idempotent + opts merge")
ok("M._initialized starts false (pre-setup)",
  core._initialized == false)

core.setup()
ok("M._initialized true after first setup()",
  core._initialized == true)
ok("default config preserved after no-arg setup",
  core.config.events.fire_autocmds == false)

core.setup({ events = { fire_autocmds = true } })
ok("setup({events={fire_autocmds=true}}) flips the flag",
  core.config.events.fire_autocmds == true)
ok("setup merge preserved unrelated defaults",
  core.config.log.level == "info")

-- Re-default for downstream tests.
core.setup({ events = { fire_autocmds = false } })
ok("re-setup re-merges from defaults",
  core.config.events.fire_autocmds == false)

-- Phase 1 will assert these are tables; for now they're nil (stubs not landed).
ok("M.events is nil at Phase 0 (lands in Phase 1)",
  core.events == nil)
ok("M.state is nil at Phase 0 (lands in Phase 2)",
  core.state == nil)
ok("M.ui is nil at Phase 0 (lands in Phase 3)",
  core.ui == nil)

-- ─────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
