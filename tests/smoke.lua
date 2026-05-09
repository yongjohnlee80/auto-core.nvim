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
ok("M.version is 0.0.2 (Phase 1 events tag)",
  select(1, eq(core.version, "0.0.2")))
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

-- Phase 1 wires events; subsequent subsystems still nil at this point.
ok("M.events is a table (Phase 1)",
  type(core.events) == "table")
ok("M.state is nil at this phase (lands in Phase 2)",
  core.state == nil)
ok("M.ui is nil at this phase (lands in Phase 3)",
  core.ui == nil)

-- ─────────────────────── 3. events: subscribe/publish ────────
print("\n[3] events.subscribe + publish + unsubscribe")
local events = core.events
events._reset_for_tests()

local hits = {}
local h1 = events.subscribe("panel:opened", function(p) table.insert(hits, p) end)
ok("subscribe returns a handle table", type(h1) == "table")
ok("handle has id, topic, callback", type(h1.id) == "number"
  and h1.topic == "panel:opened" and type(h1.callback) == "function")
ok("count_subscribers reflects 1 active sub",
  events.count_subscribers("panel:opened") == 1)

local invoked, errors = events.publish("panel:opened", { winid = 42 })
ok("publish returns (invoked=1, errors=0)",
  invoked == 1 and errors == 0,
  string.format("invoked=%d errors=%d", invoked, errors))
ok("subscriber received the payload",
  #hits == 1 and hits[1].winid == 42)

events.unsubscribe(h1)
ok("count_subscribers drops to 0 after unsubscribe",
  events.count_subscribers("panel:opened") == 0)
events.publish("panel:opened", { winid = 99 })
ok("subscriber doesn't fire after unsubscribe",
  #hits == 1, "hits=" .. #hits)

-- ─────────────────────── 4. events.once ─────────────────────
print("\n[4] events.once auto-unsubscribes")
events._reset_for_tests()
local once_hits = 0
events.once("panel:opened", function() once_hits = once_hits + 1 end)
events.publish("panel:opened", {})
events.publish("panel:opened", {})
events.publish("panel:opened", {})
ok("once-handler fires exactly once across 3 publishes",
  once_hits == 1, "once_hits=" .. once_hits)

-- ─────────────────────── 5. error isolation ─────────────────
print("\n[5] error isolation — bad subscriber doesn't kill the chain")
events._reset_for_tests()
events.subscribe("panel:opened", function() error("boom") end)
local late_hit = false
events.subscribe("panel:opened", function() late_hit = true end)
local invoked2, errors2 = events.publish("panel:opened", {})
ok("publish reports invoked=2 errors=1",
  invoked2 == 2 and errors2 == 1,
  string.format("invoked=%d errors=%d", invoked2, errors2))
ok("downstream subscriber still fires after upstream error",
  late_hit == true)

-- ─────────────────────── 6. pattern subscribe ───────────────
print("\n[6] pattern subscribe (* wildcard between . / : separators)")
events._reset_for_tests()
local pattern_hits = {}
events.subscribe("agent.*", function(p, t)
  table.insert(pattern_hits, t)
end)
events.publish("agent.task:queued", {})
events.publish("agent.status:changed", {})
events.publish("panel:opened", {})  -- non-matching, must NOT fire
ok("pattern 'agent.*' fired for agent.task:queued",
  vim.tbl_contains(pattern_hits, "agent.task:queued"))
ok("pattern 'agent.*' fired for agent.status:changed",
  vim.tbl_contains(pattern_hits, "agent.status:changed"))
ok("pattern 'agent.*' did NOT fire for panel:opened",
  not vim.tbl_contains(pattern_hits, "panel:opened"))
ok("count_subscribers('agent.task:queued') counts the pattern sub",
  events.count_subscribers("agent.task:queued") == 1)

-- Greedy `*` — `*:opened` matches anything ending in `:opened`,
-- regardless of how many `.`s are in front.
local hits_opened = 0
events.subscribe("*:opened", function() hits_opened = hits_opened + 1 end)
events.publish("panel:opened", {})       -- match
events.publish("agent.task:opened", {})  -- also match (greedy)
events.publish("panel:closed", {})       -- non-match
ok("'*:opened' is greedy across '.'  separators",
  hits_opened == 2, "hits_opened=" .. hits_opened)

-- ─────────────────────── 7. reentrancy cap ──────────────────
print("\n[7] reentrancy guard — caps runaway publish loops")
events._reset_for_tests()
local depth = 0
local max_depth_seen = 0
events.subscribe("loop:topic", function()
  depth = depth + 1
  if depth > max_depth_seen then max_depth_seen = depth end
  events.publish("loop:topic", {})  -- intentional infinite recursion
  depth = depth - 1
end)
events.publish("loop:topic", {})
ok("max recursive depth capped at 8",
  max_depth_seen == 8, "max_depth_seen=" .. max_depth_seen)

-- ─────────────────────── 8. trace ring buffer ───────────────
print("\n[8] events.trace ring buffer")
events._reset_for_tests()
events.configure({ trace_capacity = 5 })  -- small buffer to test wraparound
events.subscribe("panel:opened", function() end)
for i = 1, 8 do
  events.publish("panel:opened", { i = i })
end
local recent = events.trace.recent()
ok("trace cap honored (5 entries despite 8 publishes)",
  #recent == 5, "got " .. #recent)
ok("trace preserves most-recent entries (i=4..8)",
  recent[1].topic == "panel:opened"
    and recent[#recent].subscribers == 1)

-- Restore default capacity for any subsequent tests.
events.configure({ trace_capacity = 200 })
events._reset_for_tests()

-- ─────────────────────── 9. autocmd-fire compat shim (opt-in) ──
print("\n[9] autocmd-fire compat shim — opt-in via setup")
events.configure({ fire_autocmds = false })
local autocmd_hits = 0
local group = vim.api.nvim_create_augroup("AutoCoreSmokeTestShim", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "AutoCore_panel_opened",
  callback = function() autocmd_hits = autocmd_hits + 1 end,
})

events.publish("panel:opened", {})
ok("with fire_autocmds=false, no autocmd User AutoCore_panel_opened fires",
  autocmd_hits == 0, "autocmd_hits=" .. autocmd_hits)

events.configure({ fire_autocmds = true })
events.publish("panel:opened", {})
ok("with fire_autocmds=true, the User autocmd fires",
  autocmd_hits == 1, "autocmd_hits=" .. autocmd_hits)

vim.api.nvim_del_augroup_by_id(group)
events.configure({ fire_autocmds = false })
events._reset_for_tests()

-- ─────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
