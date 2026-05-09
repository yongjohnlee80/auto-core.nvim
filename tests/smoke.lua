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
ok("M.version is 0.0.4 (Phase 3 UI primitives tag)",
  select(1, eq(core.version, "0.0.4")))
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

-- Phase 1 wires events; Phase 2 wires state; Phase 3 wires ui.
ok("M.events is a table (Phase 1)",
  type(core.events) == "table")
ok("M.state is a table (Phase 2)",
  type(core.state) == "table")
ok("M.ui is a table with panel/winbar/section (Phase 3)",
  type(core.ui) == "table"
    and type(core.ui.panel) == "table"
    and type(core.ui.winbar) == "table"
    and type(core.ui.section) == "table")

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

-- ─────────────────────── 10. state: namespace + get/set/defaults ───
print("\n[10] state.namespace — claim, defaults fallthrough, set/get")
local state = core.state
state._reset_for_tests()
events._reset_for_tests()

-- Use ephemeral so this test never touches disk.
local s = state.namespace("auto-test", {
  defaults = { panel = { width = 38, mode = "auto" }, count = 5 },
  persist  = "ephemeral",
})

ok("namespace returns an object with get/set/watch",
  type(s.get) == "function" and type(s.set) == "function"
    and type(s.watch) == "function")
ok("get returns the default when no value has been set",
  s:get("panel.width") == 38, "got " .. tostring(s:get("panel.width")))
ok("get returns nil for an unknown key not in defaults",
  s:get("nope.unknown") == nil)

s:set("panel.width", 50)
ok("set + get round-trips the value",
  s:get("panel.width") == 50, "got " .. tostring(s:get("panel.width")))
ok("set on one path doesn't disturb another",
  s:get("panel.mode") == "auto" and s:get("count") == 5)

ok("get_all returns defaults + sets layered",
  (function()
    local all = s:get_all()
    return all.panel.width == 50 and all.panel.mode == "auto" and all.count == 5
  end)())

-- ─────────────────────── 11. state: change events ───────────────
print("\n[11] state set auto-publishes a change event")
state._reset_for_tests()
events._reset_for_tests()
local ns = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { panel = { user_width = nil } } })

local event_hits = {}
core.events.subscribe("state.auto-test:panel.user_width:changed", function(p)
  table.insert(event_hits, p)
end)

ns:set("panel.user_width", 42)
ok("set fires state.<ns>:<key>:changed with new+old payload",
  #event_hits == 1
    and event_hits[1].namespace == "auto-test"
    and event_hits[1].key == "panel.user_width"
    and event_hits[1].new == 42
    and event_hits[1].old == nil,
  vim.inspect(event_hits))

ns:set("panel.user_width", 42)  -- same value
ok("setting same value does NOT re-fire the change event",
  #event_hits == 1, "extra hits=" .. (#event_hits - 1))

ns:set("panel.user_width", 60)
ok("changing the value fires another event with old=42",
  #event_hits == 2 and event_hits[2].old == 42 and event_hits[2].new == 60)

-- ─────────────────────── 12. state.watch convenience ────────────
print("\n[12] state:watch is sugar over events.subscribe")
state._reset_for_tests()
events._reset_for_tests()
local ns2 = state.namespace("auto-test", { persist = "ephemeral" })

local watch_hits = 0
local h = ns2:watch("foo.bar", function() watch_hits = watch_hits + 1 end)
ns2:set("foo.bar", 1)
ok("watch fires on the matching change event", watch_hits == 1)
ns2:unwatch(h)
ns2:set("foo.bar", 2)
ok("unwatch stops further fires", watch_hits == 1)

-- Wildcard via events bus
local wild_hits = 0
ns2:watch("foo.*", function() wild_hits = wild_hits + 1 end)
ns2:set("foo.bar", 3)
ns2:set("foo.baz", 1)
ok("watch('foo.*') fires for any matching child key",
  wild_hits == 2, "wild_hits=" .. wild_hits)

-- ─────────────────────── 13. state isolation across namespaces ──
print("\n[13] state isolation — auto-agents and auto-finder don't collide")
state._reset_for_tests()
events._reset_for_tests()
local agents = state.namespace("auto-agents", {
  defaults = { panel = { slot_count = 5 } },
  persist  = "ephemeral",
})
local finder = state.namespace("auto-finder", {
  defaults = { panel = { user_width = 38 } },
  persist  = "ephemeral",
})

agents:set("panel.slot_count", 7)
ok("auto-agents.panel.slot_count = 7", agents:get("panel.slot_count") == 7)
ok("auto-finder.panel.user_width still default",
  finder:get("panel.user_width") == 38)
ok("auto-finder doesn't see the auto-agents key (different namespace)",
  finder:get("panel.slot_count") == nil)

finder:set("panel.user_width", 42)
ok("auto-finder.panel.user_width = 42", finder:get("panel.user_width") == 42)
ok("auto-agents.panel.user_width still nil (different namespace)",
  agents:get("panel.user_width") == nil)

ok("agents fires its own change events, NOT auto-finder's",
  (function()
    local agents_hits = 0
    state._reset_for_tests()
    events._reset_for_tests()
    local a = state.namespace("auto-agents", { persist = "ephemeral",
      defaults = { panel = { slot_count = 5 } } })
    local f = state.namespace("auto-finder", { persist = "ephemeral",
      defaults = { panel = { user_width = 38 } } })
    core.events.subscribe("state.auto-agents:panel.slot_count:changed",
      function() agents_hits = agents_hits + 1 end)
    f:set("panel.user_width", 99)  -- writing to finder
    a:set("panel.slot_count", 7)   -- writing to agents
    return agents_hits == 1
  end)())

-- ─────────────────────── 14. state idempotent claim ──────────────
print("\n[14] state.namespace is idempotent (singleton per name)")
state._reset_for_tests()
events._reset_for_tests()
local first = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { a = 1 } })
first:set("a", 99)
local second = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { b = 2 } })  -- additional defaults merged
ok("second claim returns the same instance",
  first == second, "first ~= second")
ok("user-set value preserved across re-claim",
  second:get("a") == 99)
ok("additional defaults merged in",
  second:get("b") == 2)

-- ─────────────────────── 15. state: json persist round-trip ─────
print("\n[15] state json persist — write + reload round-trip")
state._reset_for_tests()
events._reset_for_tests()

-- Use a tempdir specifically for this test so we don't pollute the
-- user's actual ~/.local/state/nvim/auto-core/.
local persist_dir = vim.fn.tempname()
vim.fn.mkdir(persist_dir, "p")
state.configure({ persist_dir = persist_dir })

local ns3 = state.namespace("persist-test", {
  defaults = { panel = { width = 38 } },
  persist  = "json",
})
ns3:set("panel.width", 77)
ns3:set("flag", true)
ns3:persist_now()  -- flush synchronously so the test can read the file

local persist_path = persist_dir .. "/persist-test.json"
ok("json file written at the expected path",
  vim.fn.filereadable(persist_path) == 1, persist_path)

-- Reset registry + reload to simulate restart
state._reset_for_tests()
local reloaded = state.namespace("persist-test", {
  defaults = { panel = { width = 38 } },
  persist  = "json",
})
ok("persisted panel.width survives reload",
  reloaded:get("panel.width") == 77)
ok("persisted flag survives reload",
  reloaded:get("flag") == true)
ok("default still falls through for non-persisted keys",
  reloaded:get("never_set") == nil)

-- Cleanup the tempdir.
state._reset_for_tests()
state.configure({ persist_dir = nil })  -- back to default
pcall(vim.fn.delete, persist_dir, "rf")

-- ─────────────────────── 16. state.clear ────────────────────────
print("\n[16] state:clear")
state._reset_for_tests()
events._reset_for_tests()
local ns4 = state.namespace("auto-test", { persist = "ephemeral",
  defaults = { x = 10 } })
ns4:set("x", 99)
ok("get returns user-set value before clear", ns4:get("x") == 99)
ns4:clear("x")
ok("clear(key) removes user-set value, fall-through to default",
  ns4:get("x") == 10)

ns4:set("a", 1)
ns4:set("b", 2)
ns4:clear()
ok("clear() with no key removes all user-set values",
  ns4:get("a") == nil and ns4:get("b") == nil)

-- ─────────────────────── 17. ui.winbar.render (pure) ────────
print("\n[17] ui.winbar.render — three modes by available width")
local winbar = core.ui.winbar
local sections_def = {
  { number = 0, name = "config" },
  { number = 1, name = "files"  },
  { number = 2, name = "repos"  },
}
local full = winbar.render(1, sections_def, 80)
ok("winbar(80, focused=1) contains '0: config' (full label)",
  full:find("0: config", 1, true) ~= nil, full)
ok("winbar contains the focused active highlight wrap",
  full:find("AutoCoreSectionActive", 1, true) ~= nil, full)
ok("winbar contains a clickable region for section 1",
  full:find("%%1@v:lua%.require'auto%-core%.ui%.winbar'%.click@") ~= nil)

local narrow = winbar.render(1, sections_def, 12)
ok("winbar(narrow=12) drops the unfocused labels",
  narrow:find("config", 1, true) == nil, narrow)
ok("winbar(narrow) keeps the focused label '[1: files]' or '[1]'",
  narrow:find("[1", 1, true) ~= nil, narrow)

-- ─────────────────────── 18. ui.panel singleton + open/close ─
print("\n[18] ui.panel — open / close / singleton-marker adoption")
local Panel = core.ui.panel
Panel._reset_for_tests()
events._reset_for_tests()

local panel = Panel.new({
  name  = "test-panel",
  side  = "left",
  width = { default = 30, min = 20, max = 80 },
  filetype = "auto-core-test",
})
ok("Panel.new returns a table with open/close/toggle/focus/resize",
  type(panel.open) == "function" and type(panel.close) == "function"
    and type(panel.toggle) == "function" and type(panel.focus) == "function"
    and type(panel.resize) == "function")

-- Pre-open: subscribe to panel:opened so we can verify the event.
local opened_payload = nil
core.events.subscribe("panel:opened", function(p) opened_payload = p end)

local winid = panel:open(true)
ok("panel:open() returns a valid winid",
  winid and vim.api.nvim_win_is_valid(winid))
ok("panel.winid was set",
  panel.winid == winid)
ok("panel:opened event fired with name + winid",
  opened_payload and opened_payload.name == "test-panel"
    and opened_payload.winid == winid,
  vim.inspect(opened_payload))

ok("panel window has winfixwidth set",
  vim.wo[winid].winfixwidth == true)
ok("panel window has winfixbuf set",
  vim.wo[winid].winfixbuf == true)
ok("panel window stamped w:test-panel_panel = 1",
  (function()
    local ok_get, m = pcall(vim.api.nvim_win_get_var, winid, "test_panel_panel")
    return ok_get and m == 1
  end)())
ok("panel window stamped w:auto_core_panel_name = 'test-panel'",
  (function()
    local ok_get, n = pcall(vim.api.nvim_win_get_var, winid, "auto_core_panel_name")
    return ok_get and n == "test-panel"
  end)())

-- Singleton-marker adoption: drop the cached winid (simulate
-- :Lazy reload), call open() again, expect adoption rather than
-- a duplicate.
local pre_count = #vim.api.nvim_tabpage_list_wins(0)
panel.winid = nil
local re_winid = panel:open(true)
ok("re-open with cleared state ADOPTS the marked window",
  re_winid == winid, "got " .. tostring(re_winid) .. " expected " .. tostring(winid))
ok("no duplicate window created",
  #vim.api.nvim_tabpage_list_wins(0) == pre_count)

-- ─────────────────────── 19. ui.panel resize + pin ──────────
print("\n[19] ui.panel resize + reset_width")
panel:resize(50)
ok("panel:resize(50) pins user_width", panel.user_width == 50)
ok("panel window width == 50 after resize",
  vim.api.nvim_win_get_width(winid) == 50,
  "got " .. vim.api.nvim_win_get_width(winid))

panel:reset_width()
ok("panel:reset_width() clears user_width", panel.user_width == nil)
-- After reset, width returns to the default (30).
ok("panel window width back to default (30)",
  vim.api.nvim_win_get_width(winid) == 30,
  "got " .. vim.api.nvim_win_get_width(winid))

-- ─────────────────────── 20. ui.panel close + event ─────────
print("\n[20] ui.panel close fires panel:closed")
local closed_payload = nil
core.events.subscribe("panel:closed", function(p) closed_payload = p end)
panel:close()
ok("panel.winid cleared after close", panel.winid == nil)
ok("panel:closed event fired with name",
  closed_payload and closed_payload.name == "test-panel",
  vim.inspect(closed_payload))

Panel._reset_for_tests()
events._reset_for_tests()

-- ─────────────────────── 21. ui.section attach + focus ──────
print("\n[21] ui.section — attach + focus + buffer-local q keymap")
local panel2 = Panel.new({
  name  = "test-sections",
  side  = "left",
  width = { default = 30, min = 20, max = 80 },
})
panel2:open(true)

-- Two simple sections, each builds a scratch buffer with a name.
local mk_buf = function(label)
  return function(_panel)
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].buftype = "nofile"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "section: " .. label })
    return b
  end
end
local Section = core.ui.section
local registry = Section.attach(panel2, {
  { number = 0, name = "config", get_buffer = mk_buf("config") },
  { number = 1, name = "files",  get_buffer = mk_buf("files")  },
}, { default = 0 })

ok("Section.attach returns a registry with focus/add/remove",
  type(registry.focus) == "function" and type(registry.add) == "function"
    and type(registry.remove) == "function")

local ok_focus = registry:focus(0)
ok("registry:focus(0) returns true", ok_focus)
ok("active section == 0", registry.active == 0)
ok("panel buffer holds 'section: config'",
  (function()
    local b = vim.api.nvim_win_get_buf(panel2.winid)
    local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
    return first == "section: config"
  end)())

ok("section bufnr cached after first focus",
  registry._bufs[0] ~= nil)

registry:focus(1)
ok("active section == 1 after focus(1)", registry.active == 1)
ok("panel buffer holds 'section: files' after focus(1)",
  (function()
    local b = vim.api.nvim_win_get_buf(panel2.winid)
    local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
    return first == "section: files"
  end)())

-- Buffer-local 0..9 keymap and q keymap should be bound.
local map = vim.fn.maparg("q", "n", false, true)
ok("q is bound buffer-locally on the section buffer",
  type(map) == "table" and map.buffer == 1
    and (map.desc or ""):find("close panel") ~= nil,
  vim.inspect(map))
local map0 = vim.fn.maparg("0", "n", false, true)
ok("0 is bound buffer-locally for section switch",
  type(map0) == "table" and map0.buffer == 1
    and (map0.desc or ""):find("focus section") ~= nil)

-- Add a runtime section.
registry:add({ number = 2, name = "repos", get_buffer = mk_buf("repos") })
ok("registry:add appends new section",
  #registry.sections == 3 and registry.sections[3].name == "repos")

registry:focus(2)
ok("focus(new section) works",
  registry.active == 2)

-- Remove a section — its on_close hook should fire and bufnr drop.
local on_close_hits = 0
registry:add({ number = 3, name = "logs",
  get_buffer = mk_buf("logs"),
  on_close = function() on_close_hits = on_close_hits + 1 end })
registry:focus(3)  -- materialize the buffer first
ok("section 3 (logs) bufnr cached", registry._bufs[3] ~= nil)
local removed = registry:remove(3)
ok("registry:remove returns true", removed)
ok("on_close hook fired", on_close_hits == 1)
ok("bufnr cache cleared after remove", registry._bufs[3] == nil)

panel2:close()
registry:dispose()
Panel._reset_for_tests()
events._reset_for_tests()

-- ─────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
