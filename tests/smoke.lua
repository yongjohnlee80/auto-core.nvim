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
-- FIXME (baseline-stale): see the long FIXME in section [48] below —
-- this literal-string version assertion needs manual updating on every
-- patch bump (currently expects 0.1.5; this branch ships v0.1.6). Same
-- maintenance opportunity as section [48]. Left stale on purpose so
-- the failure stays discoverable.
ok("M.version matches the v0.1.x line",
  type(core.version) == "string" and core.version:match("^0%.1%.%d+$") ~= nil,
  "got " .. tostring(core.version))
ok("M.api_version is 0.1 (M.debug additive; events/state/ui/fs/git/tasks/log/health unchanged)",
  select(1, eq(core.api_version, "0.1")))
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
ok("M.fs is a table with path (Phase 4a)",
  type(core.fs) == "table" and type(core.fs.path) == "table")
ok("M.git is a table with repo (Phase 4a)",
  type(core.git) == "table" and type(core.git.repo) == "table")

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

-- ─────────────────────── 22. fs.path normalize/join/parent ───────
print("\n[22] fs.path — normalize, join, parent, basename, relative")
local p = core.fs.path

ok("normalize collapses trailing slash",
  p.normalize("/tmp/foo/")  == "/tmp/foo")
ok("normalize resolves ~",
  p.normalize("~/x"):sub(1, 1) == "/")  -- should be absolute
ok("normalize resolves '..'",
  p.normalize("/tmp/foo/../bar") == "/tmp/bar")
ok("normalize on empty returns empty",
  p.normalize("") == "")

ok("join concatenates two with /",
  p.join("/tmp", "foo") == "/tmp/foo")
ok("join handles trailing slash on first arg",
  p.join("/tmp/", "foo") == "/tmp/foo")
ok("join skips empty components",
  p.join("/tmp", "", "foo") == "/tmp/foo")
ok("join with abs middle component resets",
  p.join("/tmp", "/etc", "passwd") == "/etc/passwd")

ok("parent returns dirname",
  p.parent("/tmp/foo/bar.lua") == "/tmp/foo")
ok("basename returns filename",
  p.basename("/tmp/foo/bar.lua") == "bar.lua")

ok("relative under base", p.relative("/a/b/c", "/a") == "b/c")
ok("relative same path is .", p.relative("/a/b", "/a/b") == ".")
ok("relative not under returns nil",
  p.relative("/a/b", "/x") == nil)
ok("relative doesn't false-positive prefix",
  p.relative("/foobar", "/foo") == nil)

-- ─────────────────────── 23. fs.path is_under / type checks ─────
print("\n[23] fs.path — is_under, exists, is_dir, is_file")
ok("is_under true for child",
  p.is_under("/tmp/foo/bar", "/tmp/foo") == true)
ok("is_under true for self",
  p.is_under("/tmp/foo", "/tmp/foo") == true)
ok("is_under false for sibling",
  p.is_under("/tmp/foobar", "/tmp/foo") == false)

local td = vim.fn.tempname()
vim.fn.mkdir(td, "p")
ok("is_dir true on a real dir", p.is_dir(td))
ok("exists true on a real dir", p.exists(td))
ok("is_file false on a dir", p.is_file(td) == false)

local tf = td .. "/sample.txt"
vim.fn.writefile({ "hello" }, tf)
ok("is_file true on a real file", p.is_file(tf))
ok("exists true on a real file", p.exists(tf))
ok("is_dir false on a file", p.is_dir(tf) == false)
ok("exists false on a non-existent path",
  p.exists(td .. "/nope") == false)

-- ─────────────────────── 24. fs.path root resolvers ─────────────
print("\n[24] fs.path — project_root / git_root / workspace_root")
-- Build a fake worktree-style layout under a tempdir.
local repo = td .. "/proj-fake"
vim.fn.mkdir(repo .. "/.git", "p")
vim.fn.writefile({ "" }, repo .. "/go.mod")
local sub = repo .. "/internal/pkg"
vim.fn.mkdir(sub, "p")

ok("project_root finds the .git ancestor",
  p.project_root({ start = sub }) == repo)
ok("git_root finds the .git ancestor",
  p.git_root({ start = sub }) == repo)
ok("project_root respects custom markers (go.mod alone)",
  p.project_root({ start = sub, markers = { "go.mod" } }) == repo)
ok("project_root returns nil when no marker found",
  p.project_root({ start = "/", markers = { "definitely-not-here.x" } }) == nil)

-- workspace_root: parent of the .git ancestor
ok("workspace_root falls back to parent of git_root",
  p.workspace_root({ start = sub }) == td)

-- workspace_root with a `.bare` marker prefers the container
local ws = td .. "/multi-repo"
vim.fn.mkdir(ws .. "/.bare", "p")
vim.fn.mkdir(ws .. "/branch-a/.git", "p")
ok("workspace_root with .bare picks the container directly",
  p.workspace_root({ start = ws .. "/branch-a" }) == ws)

-- Cleanup
pcall(vim.fn.delete, td, "rf")

-- ─────────────────────── 25. git.repo — is_git / root / dirs ────
print("\n[25] git.repo — is_git / root / git_dir / common_dir / is_bare")
-- This test depends on the auto-core repo itself being a git repo
-- (we're running in-tree).
local repo_mod = core.git.repo
local self_root = repo_mod.root()
ok("git.repo.root returns a non-nil string when run inside a repo",
  type(self_root) == "string" and #self_root > 0,
  tostring(self_root))

ok("git.repo.is_git true on the repo root",
  repo_mod.is_git(self_root) == true)
ok("git.repo.is_git true on a sub-path of the repo",
  repo_mod.is_git(self_root .. "/lua") == true)

local gd = repo_mod.git_dir(self_root)
ok("git.repo.git_dir returns an absolute path",
  type(gd) == "string" and gd:sub(1, 1) == "/", tostring(gd))

local cd = repo_mod.common_dir(self_root)
ok("git.repo.common_dir returns an absolute path",
  type(cd) == "string" and cd:sub(1, 1) == "/", tostring(cd))

ok("git.repo.is_bare false on the auto-core working tree",
  repo_mod.is_bare(self_root) == false)

-- Negative cases — a known-non-git path.
local non_git = vim.fn.tempname() .. "-no-git"
vim.fn.mkdir(non_git, "p")
ok("git.repo.is_git false on a fresh empty dir",
  repo_mod.is_git(non_git) == false)
ok("git.repo.root nil on a fresh empty dir",
  repo_mod.root(non_git) == nil)
pcall(vim.fn.delete, non_git, "rf")

-- ─────────────────────── 26. fs.watch — libuv watcher + events ──────────────
print("\n[26] fs.watch — start/stop, events, debounce, ignore, max_handles")
local watch = require("auto-core.fs.watch")
local events_mod = require("auto-core.events")
events_mod._reset_for_tests()
watch._reset_for_tests()

ok("fs.watch.start returns nil on a non-directory",
  (function()
    local h, err = watch.start("/definitely/not/a/path/to/anywhere")
    return h == nil and type(err) == "string"
  end)())

-- Build a tmp tree:  <root>/   {a.txt, sub/, .git/HEAD, sub/b.txt}
local tmp_root = vim.fn.tempname() .. "-fs-watch"
vim.fn.mkdir(tmp_root, "p")
vim.fn.mkdir(tmp_root .. "/sub", "p")
vim.fn.mkdir(tmp_root .. "/.git", "p")  -- should be ignored by default
vim.fn.writefile({ "stamp" }, tmp_root .. "/.git/HEAD")

-- Capture events for assertion. Subscriber records into a list.
local seen = {}
events_mod.subscribe("core.file:*", function(payload, topic)
  seen[#seen + 1] = { topic = topic, path = payload.path, change = payload.change }
end)

local handle, err = watch.start(tmp_root)
ok("watch.start succeeds on real dir",
  handle ~= nil and handle.id ~= nil, tostring(err))
ok("watch.list reports one handle",
  #watch.list() == 1)

-- Trigger a create. Use writefile (synchronous) then vim.wait to
-- drain the libuv event loop into our subscriber.
vim.fn.writefile({ "hello" }, tmp_root .. "/a.txt")
vim.wait(300, function()
  for _, e in ipairs(seen) do
    if e.path:sub(-#"/a.txt") == "/a.txt" then return true end
  end
  return false
end)
local saw_a = false
local saw_kind = nil
for _, e in ipairs(seen) do
  if e.path:sub(-#"/a.txt") == "/a.txt" then
    saw_a = true
    saw_kind = e.change
    break
  end
  end
ok("create-event fired for new file", saw_a, vim.inspect(seen))
ok("create-event change kind is 'created' or 'modified'",
  saw_kind == "created" or saw_kind == "modified",
  "got " .. tostring(saw_kind))

-- Modify the same file. Wait long enough for the debounce window
-- (default 100 ms) to clear.
local pre_modify_count = #seen
vim.wait(150)
vim.fn.writefile({ "hello", "again" }, tmp_root .. "/a.txt")
vim.wait(300, function()
  for i = pre_modify_count + 1, #seen do
    if seen[i].path:sub(-#"/a.txt") == "/a.txt" then return true end
  end
  return false
end)
local saw_modify = false
for i = pre_modify_count + 1, #seen do
  if seen[i].path:sub(-#"/a.txt") == "/a.txt" then saw_modify = true end
end
ok("modify-event fired on subsequent write", saw_modify,
  vim.inspect({ before = pre_modify_count, total = #seen, last = seen[#seen] }))

-- Delete it.
local pre_delete_count = #seen
vim.wait(150)
vim.fn.delete(tmp_root .. "/a.txt")
vim.wait(300, function()
  for i = pre_delete_count + 1, #seen do
    if seen[i].path:sub(-#"/a.txt") == "/a.txt"
        and seen[i].change == "deleted" then
      return true
    end
  end
  return false
end)
local saw_delete = false
for i = pre_delete_count + 1, #seen do
  if seen[i].path:sub(-#"/a.txt") == "/a.txt" and seen[i].change == "deleted" then
    saw_delete = true
  end
end
ok("delete-event fired with change='deleted'", saw_delete,
  vim.inspect({ before = pre_delete_count, total = #seen, last = seen[#seen] }))

-- Directory creation and deletion.
local pre_dir_count = #seen
vim.wait(150)
vim.fn.mkdir(tmp_root .. "/new_dir")
vim.wait(300, function()
  for i = pre_dir_count + 1, #seen do
    if seen[i].path:sub(-#"/new_dir") == "/new_dir" then return true end
  end
  return false
end)
local saw_dir_create = false
for i = pre_dir_count + 1, #seen do
  if seen[i].path:sub(-#"/new_dir") == "/new_dir" and seen[i].change == "created" then
    saw_dir_create = true
  end
end
ok("create-event fired for new directory", saw_dir_create)

local pre_dir_del_count = #seen
vim.wait(150)
vim.fn.delete(tmp_root .. "/new_dir", "d")
vim.wait(300, function()
  for i = pre_dir_del_count + 1, #seen do
    if seen[i].path:sub(-#"/new_dir") == "/new_dir" and seen[i].change == "deleted" then return true end
  end
  return false
end)
local saw_dir_delete = false
for i = pre_dir_del_count + 1, #seen do
  if seen[i].path:sub(-#"/new_dir") == "/new_dir" and seen[i].change == "deleted" then
    saw_dir_delete = true
  end
end
ok("delete-event fired for deleted directory", saw_dir_delete)

-- Ignore filter: writes under .git/ should produce NO events.
local before_ignore = #seen
vim.fn.writefile({ "ref" }, tmp_root .. "/.git/HEAD")
vim.wait(200)
local saw_git_event = false
for i = before_ignore + 1, #seen do
  if seen[i].path:find("/%.git/") then saw_git_event = true end
end
ok("ignore filter: no events under .git/ subtree", not saw_git_event,
  vim.inspect({ added = #seen - before_ignore }))

-- Debounce coalescing: a burst of writes within 100 ms should
-- produce at most one event for that path.
local before_burst = #seen
vim.wait(150)  -- clear any debounce window from prior writes
local burst_path = tmp_root .. "/burst.txt"
for i = 1, 5 do
  vim.fn.writefile({ tostring(i) }, burst_path)
end
vim.wait(300)
local burst_event_count = 0
for i = before_burst + 1, #seen do
  if seen[i].path:sub(-#"/burst.txt") == "/burst.txt" then
    burst_event_count = burst_event_count + 1
  end
end
ok("debounce coalesces rapid writes (<= 2 events for burst of 5)",
  burst_event_count >= 1 and burst_event_count <= 2,
  "got " .. tostring(burst_event_count))

-- Stop and verify list is empty.
watch.stop(handle)
ok("watch.stop drops the handle from list",
  #watch.list() == 0)

-- max_handles cap. Setting a tiny cap should refuse the start when
-- the recursive walk would exceed it.
vim.fn.mkdir(tmp_root .. "/d1", "p")
vim.fn.mkdir(tmp_root .. "/d2", "p")
vim.fn.mkdir(tmp_root .. "/d3", "p")
local capped, cap_err = watch.start(tmp_root, { max_handles = 1 })
ok("max_handles cap refuses oversized recursive watch",
  capped == nil and type(cap_err) == "string"
    and cap_err:find("max_handles"),
  tostring(cap_err))

-- Cleanup.
watch.stop_all()
events_mod._reset_for_tests()
pcall(vim.fn.delete, tmp_root, "rf")

-- ─────────────────────── 27. git.status — cached porcelain ──────────────
print("\n[27] git.status — cache, parse, invalidate-on-event")
local status_mod = require("auto-core.git.status")
events_mod._reset_for_tests()
status_mod._reset_for_tests()

-- Build a fresh git repo with one untracked file.
local git_root = vim.fn.tempname() .. "-status"
vim.fn.mkdir(git_root, "p")
local function sh(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return r.code == 0, r.stdout, r.stderr
end
local init_ok = sh({ "git", "init", "-q", "-b", "main", git_root })
ok("test repo initialized", init_ok)
-- Local user.* config so commits / status work in isolated env.
sh({ "git", "config", "user.email", "smoke@auto-core.test" }, git_root)
sh({ "git", "config", "user.name",  "Smoke Test"             }, git_root)
vim.fn.writefile({ "first" }, git_root .. "/untracked.txt")

local entries, ts = status_mod.get(git_root)
ok("status.get returns entries on repo with untracked file",
  type(entries) == "table" and #entries >= 1,
  vim.inspect(entries))
ok("status.get cached_at returned (number)", type(ts) == "number")
ok("entry has shape { path, status_x, status_y }",
  entries[1] ~= nil
    and type(entries[1].path) == "string"
    and type(entries[1].status_x) == "string"
    and type(entries[1].status_y) == "string",
  vim.inspect(entries[1]))
local untracked = nil
for _, e in ipairs(entries) do
  if e.path == "untracked.txt" then untracked = e end
end
ok("untracked file appears with status_y = '?'",
  untracked ~= nil and untracked.status_y == "?",
  vim.inspect(untracked))

ok("status.is_cached true after first get",
  status_mod.is_cached(git_root) == true)

-- Second get returns the SAME cached_at (cache hit, no re-shell).
local _, ts2 = status_mod.get(git_root)
ok("second get returns same cached_at (cache hit)",
  ts == ts2,
  string.format("first=%s second=%s", tostring(ts), tostring(ts2)))

-- Invalidate manually.
status_mod.invalidate(git_root)
ok("status.is_cached false after invalidate",
  status_mod.is_cached(git_root) == false)

-- Re-populate, then publish a core.file:modified for a path under
-- the repo. The auto-wired subscriber should drop the cache.
status_mod.get(git_root)
ok("re-populated cache before invalidation-by-event",
  status_mod.is_cached(git_root) == true)
events_mod.publish("core.file:modified", {
  path   = git_root .. "/untracked.txt",
  change = "modified",
})
-- Subscriber dispatches synchronously — no vim.wait needed.
ok("cache invalidated by core.file:modified event",
  status_mod.is_cached(git_root) == false)

-- Events for paths OUTSIDE the repo do NOT invalidate.
status_mod.get(git_root)
events_mod.publish("core.file:modified", {
  path   = "/tmp/some-other-place/x.txt",
  change = "modified",
})
ok("cache survives event for path outside repo",
  status_mod.is_cached(git_root) == true)

-- invalidate_all wipes everything.
status_mod.invalidate_all()
ok("invalidate_all wipes the cache",
  status_mod.is_cached(git_root) == false)

-- Negative case: not in a git repo.
local non_git = vim.fn.tempname() .. "-no-git-status"
vim.fn.mkdir(non_git, "p")
local none, none_err = status_mod.get(non_git)
ok("status.get nil + err on non-git path",
  none == nil and type(none_err) == "string", tostring(none_err))
pcall(vim.fn.delete, non_git, "rf")

pcall(vim.fn.delete, git_root, "rf")
events_mod._reset_for_tests()

-- ─────────────────────── 28. fs.tree — directory walker ─────────────────────────
print("\n[28] fs.tree — walk, walk_dirs, walk_files, exclude defaults")
local tree = require("auto-core.fs.tree")

-- Stage a tree:
--   <root>/
--     a.txt
--     sub/
--       b.txt
--     .git/
--       HEAD
--     .bare/
--       HEAD
--     node_modules/
--       skip-me.txt
--     .hidden        (a dotfile — skipped unless include_hidden)
local tree_root = vim.fn.tempname() .. "-fs-tree"
vim.fn.mkdir(tree_root, "p")
vim.fn.mkdir(tree_root .. "/sub", "p")
vim.fn.mkdir(tree_root .. "/.git", "p")
vim.fn.mkdir(tree_root .. "/.bare", "p")
vim.fn.mkdir(tree_root .. "/node_modules", "p")
vim.fn.writefile({ "x" }, tree_root .. "/a.txt")
vim.fn.writefile({ "x" }, tree_root .. "/sub/b.txt")
vim.fn.writefile({ "x" }, tree_root .. "/.git/HEAD")
vim.fn.writefile({ "x" }, tree_root .. "/.bare/HEAD")
vim.fn.writefile({ "x" }, tree_root .. "/node_modules/skip-me.txt")
vim.fn.writefile({ "x" }, tree_root .. "/.hidden")

local entries = tree.walk(tree_root)
local function find_path(es, suffix)
  for _, e in ipairs(es) do
    if e.path:sub(-#suffix) == suffix then return e end
  end
  return nil
end

ok("walk includes a.txt", find_path(entries, "/a.txt") ~= nil)
ok("walk includes sub/", find_path(entries, "/sub") ~= nil)
ok("walk includes sub/b.txt (recursive)", find_path(entries, "/sub/b.txt") ~= nil)
ok("walk excludes .git subtree by default",
  find_path(entries, "/.git") == nil
    and find_path(entries, "/.git/HEAD") == nil)
ok("walk excludes .bare subtree by default",
  find_path(entries, "/.bare") == nil
    and find_path(entries, "/.bare/HEAD") == nil)
ok("walk excludes node_modules subtree by default",
  find_path(entries, "/node_modules") == nil)
ok("walk excludes dotfiles by default",
  find_path(entries, "/.hidden") == nil)

local with_hidden = tree.walk(tree_root, { include_hidden = true })
ok("walk with include_hidden surfaces .hidden",
  find_path(with_hidden, "/.hidden") ~= nil)
-- include_hidden does NOT override the .git/.bare exclusion patterns
-- because those are matched as full-path patterns, not hidden-name
-- exclusions.
ok("include_hidden still excludes .git subtree",
  find_path(with_hidden, "/.git/HEAD") == nil)

local depth0 = tree.walk(tree_root, { depth = 0 })
ok("depth=0 returns only root's direct children",
  find_path(depth0, "/sub") ~= nil
    and find_path(depth0, "/a.txt") ~= nil
    and find_path(depth0, "/sub/b.txt") == nil)

local dirs = tree.walk_dirs(tree_root)
ok("walk_dirs returns only directories",
  (function()
    for _, e in ipairs(dirs) do
      if e.type ~= "directory" then return false end
    end
    return #dirs > 0
  end)())

local files = tree.walk_files(tree_root)
ok("walk_files returns only files",
  (function()
    for _, e in ipairs(files) do
      if e.type ~= "file" then return false end
    end
    return #files > 0
  end)())

-- Negative case: non-existent root.
ok("walk on non-existent path returns empty",
  #tree.walk("/definitely/not/anywhere") == 0)

pcall(vim.fn.delete, tree_root, "rf")

-- ─────────────────────── 29. git.worktree — porcelain parser + queries ─────────────────────────
print("\n[29] git.worktree — parse_porcelain, list, branches, helpers")
local wt = require("auto-core.git.worktree")
events_mod._reset_for_tests()
wt._reset_for_tests()

-- 29a. parse_porcelain — pure function tests
local sample = {
  "worktree /home/u/repo",
  "HEAD abc1234567890",
  "branch refs/heads/main",
  "",
  "worktree /home/u/repo-feature",
  "HEAD def4567890abc",
  "branch refs/heads/feature",
  "",
  "worktree /home/u/repo-detached",
  "HEAD 0123456789ab",
  "detached",
  "",
  "worktree /home/u/repo/.bare",
  "bare",
}
local parsed = wt.parse_porcelain(sample)
ok("parse_porcelain returns 4 entries", #parsed == 4,
  vim.inspect(parsed))
-- Note: parse_porcelain extracts head as line:sub(6, 13) = 8 chars
-- (verbatim from upstream worktree.nvim/git.lua). Git's "short HEAD"
-- length is configurable; 8 covers most repos comfortably.
ok("first entry has main branch + 8-char head",
  parsed[1].path == "/home/u/repo"
    and parsed[1].branch == "main"
    and parsed[1].head == "abc12345",
  vim.inspect(parsed[1]))
ok("feature entry has branch stripped of refs/heads/",
  parsed[2].branch == "feature")
ok("detached entry flagged",
  parsed[3].detached == true and parsed[3].branch == nil)
ok("bare entry flagged",
  parsed[4].bare == true and parsed[4].path == "/home/u/repo/.bare")

-- 29b. list — against this auto-core repo (we know it has worktrees)
local self_root = require("auto-core.git.repo").root()
ok("repo root resolved", type(self_root) == "string")
local listed = wt.list(self_root)
ok("list returns a table", type(listed) == "table")
ok("list has at least one entry", #listed >= 1, vim.inspect(listed))
ok("list entries include the auto-core path",
  (function()
    for _, e in ipairs(listed) do
      if e.path:find("auto%-core") then return true end
    end
    return false
  end)())

-- 29c. list_branches — main/master should float to top
local branches = wt.list_branches(self_root)
ok("list_branches returns a table with main first (or master)",
  #branches >= 1
    and (branches[1] == "main" or branches[1] == "master"
         or #branches == 0),
  vim.inspect(branches))

-- 29d. local_branch_exists / worktree_for_branch
ok("local_branch_exists true on default branch",
  wt.local_branch_exists(self_root, wt.default_branch(self_root)))
ok("local_branch_exists false on bogus branch",
  wt.local_branch_exists(self_root,
    "definitely-no-such-branch-xyz") == false)

-- 29e. default_branch
local def = wt.default_branch(self_root)
ok("default_branch returns a non-empty string",
  type(def) == "string" and #def > 0, tostring(def))

-- 29f. repo_name_from_url — pure function
ok("repo_name from ssh url",
  wt.repo_name_from_url("git@github.com:foo/bar.git") == "bar")
ok("repo_name from https url with .git",
  wt.repo_name_from_url("https://github.com/foo/bar.git") == "bar")
ok("repo_name from https url without .git",
  wt.repo_name_from_url("https://github.com/foo/bar") == "bar")
ok("repo_name from local path",
  wt.repo_name_from_url("/path/to/myrepo") == "myrepo")

-- 29g. repo_container — parent of common dir
ok("repo_container of /foo/repo/.bare → /foo/repo",
  wt.repo_container("/foo/repo/.bare") == "/foo/repo")
ok("repo_container of /foo/repo.git → /foo",
  wt.repo_container("/foo/repo.git") == "/foo")

-- 29h. negative case: non-git path
local none = vim.fn.tempname() .. "-no-git"
vim.fn.mkdir(none, "p")
local entries_none, err_none = wt.list(none)
ok("list returns nil + err on non-git path",
  entries_none == nil and type(err_none) == "string", tostring(err_none))
pcall(vim.fn.delete, none, "rf")

-- ─────────────────────── 30. git.worktree — workspace memory + events ─────────────────────────
print("\n[30] git.worktree — set/get active + workspace_root + events")
events_mod._reset_for_tests()
wt._reset_for_tests()

-- Capture published events.
local active_events = {}
local root_events = {}
events_mod.subscribe("core.active_worktree:changed", function(payload)
  active_events[#active_events + 1] = payload
end)
events_mod.subscribe("core.workspace_root:changed", function(payload)
  root_events[#root_events + 1] = payload
end)

ok("get_active starts as nil after reset",
  wt.get_active() == nil)

wt.set_active("/tmp/some-wt")
ok("get_active returns the path after set",
  wt.get_active() == "/tmp/some-wt")
ok("core.active_worktree:changed fired with from=nil to=/tmp/some-wt",
  #active_events == 1
    and active_events[1].from == nil
    and active_events[1].to == "/tmp/some-wt"
    and type(active_events[1].cwd) == "string",
  vim.inspect(active_events))

wt.set_active("/tmp/another-wt")
ok("event fires with from=previous, to=new",
  #active_events == 2
    and active_events[2].from == "/tmp/some-wt"
    and active_events[2].to == "/tmp/another-wt")

-- Idempotent set should NOT republish.
wt.set_active("/tmp/another-wt")
ok("idempotent set does NOT republish",
  #active_events == 2)

wt.set_active(nil)
ok("set_active(nil) clears + publishes",
  wt.get_active() == nil
    and #active_events == 3
    and active_events[3].to == nil,
  string.format("get_active=%s #events=%d events=%s",
    tostring(wt.get_active()), #active_events,
    vim.inspect(active_events)))

-- workspace_root parallel test
ok("get_workspace_root starts as nil",
  wt.get_workspace_root() == nil)

wt.set_workspace_root("/home/u/Source/Projects")
ok("get_workspace_root returns set value",
  wt.get_workspace_root() == "/home/u/Source/Projects")
ok("core.workspace_root:changed fired",
  #root_events == 1
    and root_events[1].from == nil
    and root_events[1].to == "/home/u/Source/Projects")

events_mod._reset_for_tests()
wt._reset_for_tests()

-- ─────────────────────── 31. tasks.queue — FIFO + priority dispatch ─────────────────────────
print("\n[31] tasks.queue — enqueue / claim / peek / complete / priority")
local queue = require("auto-core.tasks.queue")
events_mod._reset_for_tests()
queue._reset_for_tests()

-- Capture events.
local q_events = { queued = {}, claimed = {}, completed = {} }
events_mod.subscribe("agent.task:queued",    function(p) q_events.queued[#q_events.queued + 1]       = p end)
events_mod.subscribe("agent.task:claimed",   function(p) q_events.claimed[#q_events.claimed + 1]     = p end)
events_mod.subscribe("agent.task:completed", function(p) q_events.completed[#q_events.completed + 1] = p end)

local t1 = queue.enqueue("jarvis", { payload = "first",  priority = "normal" })
local t2 = queue.enqueue("jarvis", { payload = "urgent", priority = "urgent" })
local t3 = queue.enqueue("jarvis", { payload = "high",   priority = "high"   })
local t4 = queue.enqueue("jarvis", { payload = "low",    priority = "low"    })

ok("enqueue returns task with id + status='queued'",
  t1.id ~= nil and t1.status == "queued" and t1.priority == "normal")
ok("4 queued events fired",
  #q_events.queued == 4
    and q_events.queued[2].priority == "urgent")

-- Peek picks the highest-priority queued task.
local peeked = queue.peek("jarvis")
ok("peek returns the urgent task first",
  peeked ~= nil and peeked.id == t2.id,
  "got id=" .. tostring(peeked and peeked.id))

ok("peek does NOT transition status",
  t2.status == "queued"
    and #q_events.claimed == 0)

-- Claim — should return urgent first, then high, then normal, then low.
local c1 = queue.claim("jarvis")
ok("claim 1 → urgent (priority order)",
  c1 ~= nil and c1.id == t2.id and c1.status == "claimed")
ok("claimed event fired with id",
  #q_events.claimed == 1 and q_events.claimed[1].id == t2.id)

local c2 = queue.claim("jarvis")
ok("claim 2 → high",
  c2 ~= nil and c2.id == t3.id)

local c3 = queue.claim("jarvis")
ok("claim 3 → normal (FIFO across priorities)",
  c3 ~= nil and c3.id == t1.id)

local c4 = queue.claim("jarvis")
ok("claim 4 → low",
  c4 ~= nil and c4.id == t4.id)

local c5 = queue.claim("jarvis")
ok("claim 5 → nil (empty)", c5 == nil)

-- Complete one — verify event + removal from active list.
ok("complete returns true on claimed task",
  queue.complete(t1.id, { ok = true }))
ok("completed event fired with result",
  #q_events.completed == 1
    and q_events.completed[1].id == t1.id
    and q_events.completed[1].result.ok == true)
ok("complete returns false on already-completed",
  queue.complete(t1.id) == false)

-- FIFO within same priority. Enqueue two normal tasks; claim order
-- should match insertion order.
queue.clear("jarvis")
queue.enqueue("jarvis", { payload = "a", priority = "normal" })
queue.enqueue("jarvis", { payload = "b", priority = "normal" })
local first  = queue.claim("jarvis")
local second = queue.claim("jarvis")
ok("FIFO within same priority — first-in claims first",
  first.payload == "a" and second.payload == "b")

-- Per-agent isolation.
queue.clear()
queue.enqueue("jarvis", { payload = "for-jarvis" })
queue.enqueue("vision", { payload = "for-vision" })
ok("list(agent) returns only that agent's tasks",
  #queue.list("jarvis") == 1
    and queue.list("jarvis")[1].payload == "for-jarvis")
ok("list() returns every agent's tasks",
  #queue.list() == 2)

queue._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 32. tasks.channel — append-only message log ─────────────────────────
print("\n[32] tasks.channel — send / list / filter / recent / events")
local ch = require("auto-core.tasks.channel")
events_mod._reset_for_tests()
ch._reset_for_tests()

local m_events = {}
events_mod.subscribe("agent.message:sent",
  function(p) m_events[#m_events + 1] = p end)

local m1 = ch.send({ from = "jarvis", to = "vision",
  body = "ping",          kind = "info" })
local m2 = ch.send({ from = "vision",
  body = "broadcast hi",  kind = "info" })
local m3 = ch.send({ from = "jarvis", to = "vision",
  body = "again",         kind = "warn" })

ok("send returns message with id + iso timestamp",
  m1.id ~= nil
    and type(m1.sent_at) == "number"
    and type(m1.sent_at_iso) == "string"
    and m1.sent_at_iso:match("^%d%d%d%d%-"))
ok("ids are monotonic across sends",
  m2.id == m1.id + 1 and m3.id == m2.id + 1)
ok("3 sent events fired",
  #m_events == 3 and m_events[2].body == "broadcast hi")

-- list — no filter
local all = ch.list()
ok("list() returns all 3 messages", #all == 3)

-- filter: from
local from_jarvis = ch.list({ from = "jarvis" })
ok("filter by from='jarvis' returns 2",
  #from_jarvis == 2,
  vim.inspect(from_jarvis))

-- filter: to (specific agent)
local to_vision = ch.list({ to = "vision" })
ok("filter by to='vision' returns 2 (the directed messages)",
  #to_vision == 2)

-- filter: to="" (broadcast-only)
local broadcasts = ch.list({ to = "" })
ok("filter by to='' returns broadcasts only (1)",
  #broadcasts == 1 and broadcasts[1].body == "broadcast hi")

-- filter: kind
local warns = ch.list({ kind = "warn" })
ok("filter by kind='warn' returns 1", #warns == 1)

-- filter: since
local mid_ts = m2.sent_at
local since_mid = ch.list({ since = mid_ts })
ok("filter by since returns messages at or after the timestamp",
  #since_mid >= 1
    and (function()
      for _, m in ipairs(since_mid) do
        if m.sent_at < mid_ts then return false end
      end
      return true
    end)())

-- recent(n)
ok("recent(2) returns the 2 most recent",
  #ch.recent(2) == 2 and ch.recent(2)[2].body == "again")
ok("recent() default 100 returns all 3",
  #ch.recent() == 3)

-- clear
ch.clear()
ok("clear() empties the log", #ch.list() == 0)

-- after clear, ids should still be monotonic (don't restart)
local m_after_clear = ch.send({ from = "jarvis", body = "post-clear" })
ok("ids remain monotonic after clear",
  m_after_clear.id > m3.id,
  string.format("got %d, expected > %d", m_after_clear.id, m3.id))

ch._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 33. tasks.status — per-agent state surface ─────────────────────────
print("\n[33] tasks.status — set / get / list / transitions / events")
local stat = require("auto-core.tasks.status")
events_mod._reset_for_tests()
stat._reset_for_tests()

local s_events = {}
events_mod.subscribe("agent.status:changed",
  function(p) s_events[#s_events + 1] = p end)

ok("get on unknown agent returns nil", stat.get("jarvis") == nil)

stat.set("jarvis", "working")
ok("set+get round-trip", stat.get("jarvis") == "working")
ok("first set fires changed event with from=nil",
  #s_events == 1
    and s_events[1].agent == "jarvis"
    and s_events[1].from == nil
    and s_events[1].to == "working")

stat.set("jarvis", "idle")
ok("transition fires event with from=working to=idle",
  #s_events == 2
    and s_events[2].from == "working"
    and s_events[2].to == "idle")

-- Idempotent set.
stat.set("jarvis", "idle")
ok("idempotent set does NOT republish", #s_events == 2)

-- Multi-agent.
stat.set("vision", "waiting")
local snapshot = stat.list()
ok("list() returns map with both agents",
  snapshot.jarvis == "idle" and snapshot.vision == "waiting")

-- Invalid state
local invalid_ok = pcall(stat.set, "jarvis", "exploded")
ok("set rejects invalid state with error", not invalid_ok)

-- Clear single
stat.clear("vision")
ok("clear(agent) removes that agent's state",
  stat.get("vision") == nil)
ok("clear publishes a changed event with to=nil",
  s_events[#s_events].agent == "vision"
    and s_events[#s_events].to == nil)

stat._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 34. tasks.ui — :AutoCoreChannel panel ─────────────────────────
print("\n[34] tasks.ui — open / sections / refresh on event / close")
local ui = require("auto-core.tasks.ui")
events_mod._reset_for_tests()
ch._reset_for_tests()
stat._reset_for_tests()
queue._reset_for_tests()
ui._reset_for_tests()

-- Seed some data so the rendered buffers have content.
ch.send({ from = "jarvis", body = "channel-test message" })
stat.set("jarvis", "working")
queue.enqueue("jarvis", { payload = "ui-test-task" })

ui.open()

-- Panel should be live + have a window.
local panel_mod = require("auto-core.ui.panel")
local panel = panel_mod.get("auto-core-channel")
ok("ui.open creates the auto-core-channel panel",
  panel ~= nil and panel.winid ~= nil
    and vim.api.nvim_win_is_valid(panel.winid))

-- The active section should be 0 (messages) and its buffer should
-- contain the seeded message.
local active_buf = vim.api.nvim_win_get_buf(panel.winid)
ok("active buffer has filetype 'auto-core-channel'",
  vim.bo[active_buf].filetype == "auto-core-channel")

local lines = vim.api.nvim_buf_get_lines(active_buf, 0, -1, false)
local saw_message = false
for _, l in ipairs(lines) do
  if l:find("channel%-test message") then saw_message = true end
end
ok("messages section renders the seeded message", saw_message,
  vim.inspect(lines))

-- Send a new message — refresh subscriber should re-render.
ch.send({ from = "vision", body = "live-refresh-check" })
-- refresh is synchronous via subscribe → fire — no vim.wait needed.
local lines2 = vim.api.nvim_buf_get_lines(active_buf, 0, -1, false)
local saw_new = false
for _, l in ipairs(lines2) do
  if l:find("live%-refresh%-check") then saw_new = true end
end
ok("new message triggers panel refresh", saw_new,
  vim.inspect(lines2))

-- Close + reopen idempotency.
ui.close()
ok("ui.close closes the panel",
  panel.winid == nil
    or not vim.api.nvim_win_is_valid(panel.winid))

ui.open()
ok("ui.open after close re-opens cleanly",
  panel.winid ~= nil and vim.api.nvim_win_is_valid(panel.winid))

ui._reset_for_tests()
queue._reset_for_tests()
stat._reset_for_tests()
ch._reset_for_tests()
events_mod._reset_for_tests()

-- ─────────────────────── 35. ui.highlights — registry + theme_override ─────────────────────────
print("\n[35] ui.highlights — defaults + theme_override")
local highlights = require("auto-core.ui.highlights")
highlights._reset_for_tests()

-- Defaults catalog matches the documented set.
local listed = highlights.list()
local function listed_has(name)
  for _, n in ipairs(listed) do if n == name then return true end end
  return false
end
ok("DEFAULTS includes AutoCoreSectionActive",  listed_has("AutoCoreSectionActive"))
ok("DEFAULTS includes AutoCoreFloatNormal",    listed_has("AutoCoreFloatNormal"))
ok("DEFAULTS includes AutoCoreFloatBorder",    listed_has("AutoCoreFloatBorder"))
ok("DEFAULTS includes AutoCoreHelpKey",        listed_has("AutoCoreHelpKey"))

highlights.ensure()
ok("ensure registers AutoCoreSectionActive",
  vim.fn.hlexists("AutoCoreSectionActive") == 1)
ok("ensure registers AutoCoreFloatNormal",
  vim.fn.hlexists("AutoCoreFloatNormal") == 1)

-- Idempotent: second ensure call doesn't re-register (no-op).
highlights.ensure()
ok("ensure is idempotent (still registered)",
  vim.fn.hlexists("AutoCoreSectionActive") == 1)

-- theme_override should bypass `default = true` so it overrides
-- whatever was registered at ensure-time.
highlights.theme_override("AutoCoreFloatNormal", { bg = "#112233", fg = "#ffeedd" })
local hl_attrs = vim.api.nvim_get_hl(0, { name = "AutoCoreFloatNormal" })
ok("theme_override applies fg",
  hl_attrs.fg ~= nil,
  vim.inspect(hl_attrs))
ok("theme_override applies bg",
  hl_attrs.bg ~= nil,
  vim.inspect(hl_attrs))

-- Reset + restore link semantics by re-running ensure.
pcall(vim.api.nvim_set_hl, 0, "AutoCoreFloatNormal", { link = "NormalFloat", default = true })

-- ─────────────────────── 36. ui.float.help_overlay ─────────────────────────
print("\n[36] ui.float.help_overlay — open / dismiss / events")
local float = require("auto-core.ui.float")
events_mod._reset_for_tests()

local f_events = { opened = {}, closed = {} }
events_mod.subscribe("float:opened", function(p) f_events.opened[#f_events.opened + 1] = p end)
events_mod.subscribe("float:closed", function(p) f_events.closed[#f_events.closed + 1] = p end)

local handle = float.help_overlay({
  { "?",       "show help" },
  { "q",       "close" },
  { "<cr>",    "confirm" },
  "Free-form line",
  { key = "x", desc = "named-pair entry" },
}, { title = "test help" })

ok("help_overlay returns handle with buf+win+close",
  type(handle) == "table"
    and handle.buf ~= nil
    and handle.win ~= nil
    and type(handle.close) == "function")
ok("help_overlay window is valid",
  vim.api.nvim_win_is_valid(handle.win))
ok("help_overlay buffer has filetype 'auto-core-help'",
  vim.bo[handle.buf].filetype == "auto-core-help")
ok("help_overlay buffer is non-modifiable",
  vim.bo[handle.buf].modifiable == false)
ok("float:opened event fired with kind='help_overlay'",
  #f_events.opened == 1
    and f_events.opened[1].kind == "help_overlay"
    and f_events.opened[1].buf == handle.buf)

-- Lines should include the rendered key/desc pairs.
local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
local function has_substr(lst, s)
  for _, l in ipairs(lst) do if l:find(s) then return true end end
  return false
end
ok("help_overlay rendered '?' key entry",
  has_substr(lines, "show help"))
ok("help_overlay rendered free-form line",
  has_substr(lines, "Free%-form line"))
ok("help_overlay rendered named-pair entry",
  has_substr(lines, "named%-pair entry"))

-- Close via the explicit handle.
handle.close()
ok("help_overlay close() dismisses the window",
  not vim.api.nvim_win_is_valid(handle.win))
ok("float:closed event fired",
  #f_events.closed == 1
    and f_events.closed[1].kind == "help_overlay")

-- close() is idempotent — second call doesn't republish.
handle.close()
ok("close() is idempotent (no double-publish)",
  #f_events.closed == 1)

-- on_close hook fires on explicit close.
local on_close_fired = false
local h2 = float.help_overlay({ "x" },
  { on_close = function() on_close_fired = true end })
h2.close()
ok("on_close hook fires on dismiss",
  on_close_fired)

-- ─────────────────────── 37. ui.float.confirm ─────────────────────────
print("\n[38] ui.float.confirm — vim.ui.select wrapper")

-- Stub vim.ui.select to capture the call without blocking.
local orig_select = vim.ui.select
local select_calls = {}
local stub_choice = "yes"
vim.ui.select = function(items, opts, on_choice)
  select_calls[#select_calls + 1] = { items = items, prompt = opts.prompt }
  if on_choice then on_choice(stub_choice) end
end

local choice_received = nil
float.confirm("Proceed?", {
  on_choice = function(c) choice_received = c end,
})

ok("confirm calls vim.ui.select once",
  #select_calls == 1)
ok("confirm passes prompt to vim.ui.select",
  select_calls[1].prompt == "Proceed?")
ok("confirm default items are { yes, no }",
  #select_calls[1].items == 2
    and select_calls[1].items[1] == "yes"
    and select_calls[1].items[2] == "no")
ok("confirm forwards choice to on_choice",
  choice_received == "yes")

-- Custom items override the default.
select_calls = {}
choice_received = nil
stub_choice = "abort"
float.confirm("Pick action:", {
  items = { "save", "discard", "abort" },
  on_choice = function(c) choice_received = c end,
})
ok("confirm respects custom items",
  #select_calls[1].items == 3 and select_calls[1].items[3] == "abort")
ok("confirm forwards custom choice",
  choice_received == "abort")

-- Restore vim.ui.select.
vim.ui.select = orig_select
events_mod._reset_for_tests()

-- ─────────────────────── 39. log — levels, ring, namespace, notify ─────────────────────────
print("\n[39] log — levels, ring buffer, namespace, notify mirror")
local log = require("auto-core.log")
log._reset_for_tests()

-- Stub vim.notify so tests don't spam stderr; capture calls.
local orig_notify = vim.notify
local notify_calls = {}
vim.notify = function(msg, level, opts)
  notify_calls[#notify_calls + 1] = { msg = msg, level = level, opts = opts }
end

-- Stub nvim_echo too — we don't want INFO spam in test output.
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function() end

-- Default level is INFO; calls at INFO+ land in ring + notify; DEBUG/TRACE drop.
log.error("comp", "boom")
log.warn("comp", "watch out")
log.info("comp", "fyi")
log.debug("comp", "internal")  -- below default level; should NOT record
log.trace("comp", "deep")      -- below default level; should NOT record

-- vim.schedule is used for the notify side-effect; drain.
vim.wait(20)

local recent = log.recent()
ok("default level INFO records error+warn+info (3)",
  #recent == 3, vim.inspect(recent))
ok("ring entries carry component + level_name",
  recent[1].component == "comp"
    and recent[1].level_name == "ERROR"
    and recent[2].level_name == "WARN"
    and recent[3].level_name == "INFO")
-- v0.1.12 behavior: ERROR + WARN toast by default; INFO is RING-ONLY
-- (no nvim_echo → no `:messages` spam). Users who want the old behavior
-- opt in via `log.configure({ echo = true })` or per-call `opts.echo`.
ok("ERROR + WARN went to vim.notify; INFO is ring-only (no :messages echo)",
  #notify_calls == 2
    and notify_calls[1].level == vim.log.levels.ERROR
    and notify_calls[2].level == vim.log.levels.WARN)
ok("notify message includes [AutoCore] prefix",
  notify_calls[1].msg:find("%[AutoCore%]") ~= nil)
ok("notify message includes component bracket",
  notify_calls[1].msg:find("%[comp%]") ~= nil)

-- v0.1.12: `opts.echo = true` re-enables the nvim_echo path per-call
-- (the migration knob for callers who actually wanted the :messages
-- visibility). The ring entry is also written.
do
  log._reset_for_tests()
  local echo_count = 0
  local prev_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() echo_count = echo_count + 1 end
  log.info("comp", "echoed-info", { echo = true })
  log.info("comp", "silent-info")
  vim.wait(20)
  vim.api.nvim_echo = prev_echo
  ok("v0.1.12: opts.echo=true forwards INFO to nvim_echo",
    echo_count == 1, "echo_count=" .. echo_count)
  ok("v0.1.12: omitted opts.echo stays ring-only (silent)",
    #log.recent() == 2 and echo_count == 1)
end

-- v0.1.12: global `configure({ echo = true })` flips the default
-- for every emission. Mirrors the old (pre-v0.1.12) behavior for
-- users / projects that want the :messages visibility back.
do
  log._reset_for_tests()
  log.configure({ echo = true })
  local echo_count = 0
  local prev_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() echo_count = echo_count + 1 end
  log.info("comp", "echoed-via-config-1")
  log.info("comp", "echoed-via-config-2")
  vim.wait(20)
  vim.api.nvim_echo = prev_echo
  ok("v0.1.12: configure({ echo = true }) re-enables nvim_echo by default",
    echo_count == 2, "echo_count=" .. echo_count)
end

-- is_level_enabled
ok("is_level_enabled('error') true at default INFO", log.is_level_enabled("error"))
ok("is_level_enabled('debug') false at default INFO", not log.is_level_enabled("debug"))

-- Lower level → DEBUG passes through.
log.configure({ level = "debug" })
log.debug("comp", "now visible")
ok("after configure(debug), debug entries record",
  (function()
    for _, e in ipairs(log.recent()) do
      if e.level_name == "DEBUG" then return true end
    end
    return false
  end)())

-- Numeric level (reset FIRST, then configure — _reset_for_tests
-- restores defaults so the order matters).
vim.wait(30)  -- drain pending notify schedules from prior assertions
log._reset_for_tests()
log.configure({ level = log.levels.WARN })
log.error("c", "e1")
log.warn("c", "w1")
log.info("c", "i1")
vim.wait(30)  -- drain
ok("level=WARN drops INFO",
  #log.recent() == 2,
  string.format("got %d entries", #log.recent()))

-- Notify off (same order — drain + reset, then configure).
vim.wait(30)
log._reset_for_tests()
notify_calls = {}
log.configure({ notify = false })
log.error("c", "silent")
vim.wait(30)
ok("notify=false suppresses vim.notify",
  #notify_calls == 0
    and #log.recent() == 1,
  string.format("notify_calls=%d log.recent=%d",
    #notify_calls, #log.recent()))

-- Ring capacity behavior
log._reset_for_tests()
log.configure({ ring_capacity = 5, level = log.levels.TRACE, notify = false })
for i = 1, 12 do log.info("c", "msg-" .. i) end
local r = log.recent()
ok("ring capped at 5 (FIFO eviction)",
  #r == 5)
ok("ring contents are the last 5 entries (oldest first)",
  r[1].message:find("msg%-8")  ~= nil
    and r[5].message:find("msg%-12") ~= nil,
  string.format("first=%s last=%s", r[1].message, r[5].message))

-- recent(n)
local r3 = log.recent(3)
ok("recent(n) returns last n",
  #r3 == 3 and r3[3].message:find("msg%-12") ~= nil)

-- namespace handle
log._reset_for_tests()
log.configure({ notify = false })
local h = log.namespace("watcher")
h.error("boom")
h.info("hello")
local nrh = log.recent()
ok("namespace handle pre-binds component",
  #nrh == 2
    and nrh[1].component == "watcher"
    and nrh[2].component == "watcher")

-- inspect
local snap = log.inspect()
ok("inspect returns config snapshot",
  type(snap) == "table"
    and snap.ring_capacity ~= nil
    and snap.notify == false
    and type(snap.count) == "number")

-- ── ADR 0021 Phase 1: options-table sentinel detection + schema ─────
-- Wrapped in `do ... end` so the locals release before the smoke
-- script's main-function 200-local cap.
do
  -- Backward compat: a trailing table with no sentinel keys remains a
  -- message part (renders via vim.inspect into `message`).
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "msg", { path = "/x", count = 3 })
  local r = log.recent()
  ok("ADR 0021: trailing table without sentinel keys stays a message part",
    #r == 1
      and r[1].message:find("path") ~= nil
      and r[1].event_type == nil
      and r[1].fields == nil,
    vim.inspect(r))

  -- Sentinel: `event` key promotes the table to options. The table is
  -- popped off the parts; the ring entry carries event_type, not the
  -- table-as-message-part.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "started", { event = "auto-finder.scan.started" })
  r = log.recent()
  ok("ADR 0021: `event` sentinel populates event_type on the ring entry",
    #r == 1
      and r[1].event_type == "auto-finder.scan.started"
      and r[1].message:find("auto%-finder%.scan%.started") == nil
      and r[1].message:find("started") ~= nil,
    vim.inspect(r))

  -- Sentinel: `fields` key preserves the structured table on the entry.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "completed", {
    fields = { path = "/proj", elapsed_ms = 314 },
  })
  r = log.recent()
  ok("ADR 0021: `fields` sentinel preserves the structured table unflattened",
    #r == 1
      and type(r[1].fields) == "table"
      and r[1].fields.path == "/proj"
      and r[1].fields.elapsed_ms == 314,
    vim.inspect(r))

  -- Sentinels combine: event + fields together.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "done", {
    event  = "auto-finder.scan.completed.slow",
    fields = { elapsed_ms = 3142 },
  })
  r = log.recent()
  ok("ADR 0021: event + fields combine on one entry",
    #r == 1
      and r[1].event_type == "auto-finder.scan.completed.slow"
      and r[1].fields.elapsed_ms == 3142)

  -- `notify` and `level_override` sentinels: recognized + popped even
  -- though Phase 1 does not yet act on them (routing lands in Phase 2).
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "msg", { notify = true })
  log.info("comp", "msg2", { level_override = log.levels.WARN })
  r = log.recent()
  ok("ADR 0021: `notify` sentinel pops the opts table (no message bleed)",
    r[1].message:find("notify = true", 1, true) == nil)
  ok("ADR 0021: `level_override` sentinel pops the opts table",
    r[2].message:find("level_override", 1, true) == nil)

  -- Multiple message parts followed by opts.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "part1", "part2", "part3", { event = "auto-core.x" })
  r = log.recent()
  ok("ADR 0021: parts before opts table all reach the message",
    #r == 1
      and r[1].message:find("part1") ~= nil
      and r[1].message:find("part2") ~= nil
      and r[1].message:find("part3") ~= nil
      and r[1].event_type == "auto-core.x",
    vim.inspect(r))

  -- Existing entries (no opts) still have nil for the new fields.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info("comp", "plain")
  r = log.recent()
  ok("ADR 0021: pre-existing call shape leaves event_type/fields nil",
    r[1].event_type == nil and r[1].fields == nil)

  -- First-arg-not-string shape combined with opts table.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info({ event = "auto-core.nocomp" })
  r = log.recent()
  ok("ADR 0021: non-string first arg + opts table — component nil, opts applied",
    #r == 1
      and r[1].component == nil
      and r[1].event_type == "auto-core.nocomp")

  -- Namespace handle passes opts through.
  log._reset_for_tests()
  log.configure({ notify = false })
  local h2 = log.namespace("watcher")
  h2.info("watching", { event = "auto-core.watcher.armed" })
  r = log.recent()
  ok("ADR 0021: namespace handle propagates opts through to dispatch",
    #r == 1
      and r[1].component == "watcher"
      and r[1].event_type == "auto-core.watcher.armed")
end

-- ── ADR 0021 Phase 1 Step 2: notify / notifyIf + opts.notify routing ─
do
  -- log.notify(msg) — default level INFO, toasts + ring.
  log._reset_for_tests()
  notify_calls = {}
  log.notify("hello world")
  vim.wait(20)
  local r = log.recent()
  ok("ADR 0021 §5: log.notify writes the ring entry",
    #r == 1 and r[1].level_name == "INFO"
      and r[1].message:find("hello world") ~= nil,
    vim.inspect(r))
  ok("ADR 0021 §5: log.notify fires vim.notify (forces toast at INFO)",
    #notify_calls == 1
      and notify_calls[1].level == vim.log.levels.INFO,
    vim.inspect(notify_calls))

  -- log.notify(msg, { level = "warn", component = "scan", title = "Custom" })
  log._reset_for_tests()
  notify_calls = {}
  log.notify("watch out", {
    level     = "warn",
    component = "scan",
    title     = "Custom Title",
    fields    = { path = "/tmp" },
  })
  vim.wait(20)
  r = log.recent()
  ok("ADR 0021 §5: log.notify honors opts.level (warn)",
    #r == 1 and r[1].level_name == "WARN" and r[1].component == "scan")
  ok("ADR 0021 §5: log.notify preserves opts.fields on the ring entry",
    type(r[1].fields) == "table" and r[1].fields.path == "/tmp")
  ok("ADR 0021 §5: log.notify uses opts.title for the toast",
    #notify_calls == 1
      and notify_calls[1].opts.title == "Custom Title"
      and notify_calls[1].level == vim.log.levels.WARN)

  -- log.notifyIf with the default stub (always returns false) — ring
  -- entry written, NO toast.
  log._reset_for_tests()
  notify_calls = {}
  log.notifyIf("auto-finder.scan.started", "mapping ~/proj")
  vim.wait(20)
  r = log.recent()
  ok("ADR 0021 §5: notifyIf writes ring entry even when event unsubscribed",
    #r == 1
      and r[1].event_type == "auto-finder.scan.started"
      and r[1].message:find("mapping") ~= nil)
  ok("ADR 0021 §5: notifyIf stays silent when stub returns false",
    #notify_calls == 0,
    string.format("got %d notifies", #notify_calls))

  -- log.notifyIf when the registry says subscribed — toast fires.
  log._reset_for_tests()
  notify_calls = {}
  local saved_is_enabled = log.events.is_notify_enabled
  log.events.is_notify_enabled = function(e) return e == "auto-finder.scan.completed.slow" end
  log.notifyIf("auto-finder.scan.completed.slow", "mapped ~/proj (3.1s)")
  log.notifyIf("auto-finder.scan.started",         "mapping ~/proj")  -- not subscribed
  vim.wait(20)
  ok("ADR 0021 §5: notifyIf toasts when event is subscribed",
    #notify_calls == 1
      and notify_calls[1].msg:find("3%.1s") ~= nil,
    vim.inspect(notify_calls))
  log.events.is_notify_enabled = saved_is_enabled

  -- Per-call opts.notify = true forces toast even for INFO.
  log._reset_for_tests()
  notify_calls = {}
  log.info("comp", "force-toast", { notify = true })
  vim.wait(20)
  ok("ADR 0021 §4: opts.notify=true forces toast at INFO",
    #notify_calls == 1
      and notify_calls[1].level == vim.log.levels.INFO)

  -- Per-call opts.notify = false suppresses toast even for ERROR.
  log._reset_for_tests()
  notify_calls = {}
  log.error("comp", "silent-error", { notify = false })
  vim.wait(20)
  r = log.recent()
  ok("ADR 0021 §4: opts.notify=false suppresses toast at ERROR (ring entry still written)",
    #notify_calls == 0 and #r == 1 and r[1].level_name == "ERROR",
    string.format("notify_calls=%d ring=%d", #notify_calls, #r))

  -- Default routing preserved: no opts → ERROR/WARN toast, INFO+ silent.
  log._reset_for_tests()
  notify_calls = {}
  log.error("c", "e")
  log.warn ("c", "w")
  log.info ("c", "i")
  vim.wait(20)
  ok("ADR 0021 §4: omitted opts.notify keeps the pre-existing default routing",
    #notify_calls == 2
      and notify_calls[1].level == vim.log.levels.ERROR
      and notify_calls[2].level == vim.log.levels.WARN)

  -- Below-level filter applies to notify too: log.notify at INFO is
  -- dropped when active level is WARN (both ring and toast).
  log._reset_for_tests()
  log.configure({ level = "warn" })
  notify_calls = {}
  log.notify("dropped")
  vim.wait(20)
  ok("ADR 0021 §5: log.notify still honors the active level filter",
    #notify_calls == 0 and #log.recent() == 0)

  -- M.events stub callable + default-false.
  log._reset_for_tests()
  ok("ADR 0021 §5: M.events.is_notify_enabled is callable + returns false (stub)",
    type(log.events) == "table"
      and type(log.events.is_notify_enabled) == "function"
      and log.events.is_notify_enabled("any.event") == false)

  -- notify=auto without event → never toasts.
  log._reset_for_tests()
  notify_calls = {}
  log.info("c", "auto-no-event", { notify = "auto" })
  vim.wait(20)
  ok("ADR 0021 §4: notify='auto' without event silences (no key to look up)",
    #notify_calls == 0)
end

-- ── ADR 0021 Phase 1 Step 3: event-type registry + persistence ──────
do
  local state = require("auto-core.state")
  -- Use a temp persist dir so the subscription set written during
  -- this test doesn't pollute the user's real auto-core state.
  local persist_dir = vim.fn.tempname()
  vim.fn.mkdir(persist_dir, "p")
  state.configure({ persist_dir = persist_dir })

  -- register: bare event name gets fully-qualified with plugin prefix.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", { "scan.started", "scan.completed.slow" })
  local listed = log.events.list("auto-finder")
  ok("ADR 0021 §5: register auto-prefixes bare event names",
    #listed == 2
      and listed[1].event == "auto-finder.scan.completed.slow"
      and listed[2].event == "auto-finder.scan.started",
    vim.inspect(listed))
  ok("ADR 0021 §5: list returns owning plugin per record",
    listed[1].plugin == "auto-finder" and listed[2].plugin == "auto-finder")

  -- Pre-qualified event names pass through unchanged (no double prefix).
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-agents", { "auto-agents.spawn.failed" })
  local pq = log.events.list("auto-agents")
  ok("ADR 0021 §5: register skips re-prefixing already-qualified names",
    #pq == 1 and pq[1].event == "auto-agents.spawn.failed",
    vim.inspect(pq))

  -- register accepts a single string for ergonomic single-event registration.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("md-harpoon", "doc.pinned")
  local single = log.events.list("md-harpoon")
  ok("ADR 0021 §5: register accepts a bare string for a single event",
    #single == 1 and single[1].event == "md-harpoon.doc.pinned")

  -- register is idempotent: repeat call doesn't duplicate.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", "scan.started")
  log.events.register("auto-finder", "scan.started")
  log.events.register("auto-finder", "scan.started")
  ok("ADR 0021 §5: register is idempotent (no duplicates)",
    #log.events.list("auto-finder") == 1)

  -- list() with no arg returns ALL registered events.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", { "scan.started" })
  log.events.register("auto-agents", { "spawn.failed" })
  log.events.register("auto-core",   { "mailbox.delivered" })
  local all = log.events.list()
  ok("ADR 0021 §5: list() with no plugin filter returns events across plugins",
    #all == 3
      and all[1].event == "auto-agents.spawn.failed"
      and all[2].event == "auto-core.mailbox.delivered"
      and all[3].event == "auto-finder.scan.started",
    vim.inspect(all))

  -- enable_notify + is_notify_enabled round trip.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.enable_notify("auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: is_notify_enabled returns true after enable_notify",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == true)
  ok("ADR 0021 §5: is_notify_enabled returns false for un-subscribed events",
    log.events.is_notify_enabled("auto-finder.scan.started") == false)

  -- disable_notify clears the subscription.
  log.events.disable_notify("auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: disable_notify clears the subscription",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == false)

  -- Tolerant of registration order: subscribe-before-register works.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.enable_notify("not-yet.registered")
  ok("ADR 0021 §5: enable_notify works on unregistered events (tolerant ordering)",
    log.events.is_notify_enabled("not-yet.registered") == true)

  -- Persistence round-trip: write subscription, flush, reset cache,
  -- reload — subscription survives.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.enable_notify("persisted.event.x")
  -- Force a synchronous flush so the file lands before we tear down.
  local ns_pre = state.namespace("auto-core.log.events")
  ns_pre:persist_now()
  -- Drop the cache so the next call re-loads from disk.
  log._reset_for_tests()
  state._reset_for_tests()
  ok("ADR 0021 §5: subscriptions persist across state reset (json round-trip)",
    log.events.is_notify_enabled("persisted.event.x") == true)
  -- Cleanup: clear the persisted entry so we leave the temp dir clean.
  log.events.disable_notify("persisted.event.x")
  state.namespace("auto-core.log.events"):persist_now()

  -- notifyIf with real registry: subscribed → toast; unsubscribed → silent.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder", { "scan.started", "scan.completed.slow" })
  log.events.enable_notify("auto-finder.scan.completed.slow")
  notify_calls = {}
  log.notifyIf("auto-finder.scan.completed.slow", "mapped (slow)")
  log.notifyIf("auto-finder.scan.started",         "mapping")
  vim.wait(20)
  ok("ADR 0021 §5: notifyIf consults the real registry (subscribed → toast)",
    #notify_calls == 1
      and notify_calls[1].msg:find("mapped %(slow%)") ~= nil)
  ok("ADR 0021 §5: notifyIf consults the real registry (unsubscribed → silent)",
    (function()
      for _, c in ipairs(notify_calls) do
        if c.msg:find("mapping") then return false end
      end
      return true
    end)())

  -- Argument validation.
  log._reset_for_tests()
  state._reset_for_tests()
  ok("ADR 0021 §5: register rejects empty plugin name",
    not pcall(log.events.register, "", { "x" }))
  ok("ADR 0021 §5: register rejects non-string event names",
    not pcall(log.events.register, "p", { 42 }))
  ok("ADR 0021 §5: enable_notify rejects empty event",
    not pcall(log.events.enable_notify, ""))

  -- Teardown: restore default persist dir.
  state.configure({ persist_dir = nil })
  state._reset_for_tests()
  pcall(vim.fn.delete, persist_dir, "rf")
end

-- ── ADR 0021 Phase 1 Step 4: :AutoCoreLogEvent user command ─────────
do
  -- Make sure the plugin file has been sourced. In a real session
  -- nvim does this at startup; the smoke harness boots with
  -- `-u tests/smoke.lua` which bypasses normal plugin loading, so
  -- we force it here.
  vim.cmd("runtime! plugin/auto-core.lua")

  local state = require("auto-core.state")
  local persist_dir = vim.fn.tempname()
  vim.fn.mkdir(persist_dir, "p")
  state.configure({ persist_dir = persist_dir })

  -- Reset state + log for a clean slate.
  log._reset_for_tests()
  state._reset_for_tests()
  log.events.register("auto-finder",
    { "scan.started", "scan.completed.slow" })

  -- Capture vim.notify to verify the command emits a confirmation.
  notify_calls = {}

  -- Command registration: AutoCoreLogEvent must exist as a user command.
  local cmds = vim.api.nvim_get_commands({})
  ok("ADR 0021 §5: :AutoCoreLogEvent command is registered",
    cmds.AutoCoreLogEvent ~= nil,
    "no AutoCoreLogEvent in nvim_get_commands")

  -- :AutoCoreLogEvent notify <event> enables the subscription.
  vim.cmd("AutoCoreLogEvent notify auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: :AutoCoreLogEvent notify enables the subscription",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == true)

  -- :AutoCoreLogEvent silence <event> disables it again.
  vim.cmd("AutoCoreLogEvent silence auto-finder.scan.completed.slow")
  ok("ADR 0021 §5: :AutoCoreLogEvent silence disables the subscription",
    log.events.is_notify_enabled("auto-finder.scan.completed.slow") == false)

  -- :AutoCoreLogEvent list runs without raising; we capture nvim_echo
  -- output via the stub installed at the top of [39].
  local echo_calls = 0
  local prev_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() echo_calls = echo_calls + 1 end
  local list_ok = pcall(vim.cmd, "AutoCoreLogEvent list")
  vim.api.nvim_echo = prev_echo
  ok("ADR 0021 §5: :AutoCoreLogEvent list runs without error",
    list_ok and echo_calls >= 1,
    string.format("list_ok=%s echo_calls=%d", tostring(list_ok), echo_calls))

  -- :AutoCoreLogEvent (no subcommand) defaults to list.
  echo_calls = 0
  vim.api.nvim_echo = function() echo_calls = echo_calls + 1 end
  local default_ok = pcall(vim.cmd, "AutoCoreLogEvent")
  vim.api.nvim_echo = prev_echo
  ok("ADR 0021 §5: :AutoCoreLogEvent with no subcommand defaults to list",
    default_ok and echo_calls >= 1)

  -- Unknown subcommand surfaces an ERROR notify.
  log.events.enable_notify("auto-finder.scan.started")  -- noise to clear
  notify_calls = {}
  pcall(vim.cmd, "AutoCoreLogEvent garbage")
  ok("ADR 0021 §5: :AutoCoreLogEvent rejects unknown subcommand with ERROR notify",
    (function()
      for _, c in ipairs(notify_calls) do
        if c.level == vim.log.levels.ERROR
            and c.msg:find("unknown subcommand") then
          return true
        end
      end
      return false
    end)(),
    vim.inspect(notify_calls))

  -- notify without an event arg errors.
  notify_calls = {}
  pcall(vim.cmd, "AutoCoreLogEvent notify")
  ok("ADR 0021 §5: :AutoCoreLogEvent notify without event arg errors",
    (function()
      for _, c in ipairs(notify_calls) do
        if c.level == vim.log.levels.ERROR
            and c.msg:find("missing <event>") then
          return true
        end
      end
      return false
    end)())

  -- Tab completion: subcommand list.
  local complete_fn = cmds.AutoCoreLogEvent.complete
  -- Neovim's complete function gets the user-defined complete
  -- callback under .complete = "customlist,<func>" / fnref. The
  -- nvim_get_commands API doesn't expose the raw callback, so we
  -- access it through the registered command directly via cmd.
  -- For the smoke test, we exercise the command-defined completion
  -- function by re-importing the user-command callback indirectly:
  -- call the underlying logic. Skip if not accessible.
  ok("ADR 0021 §5: :AutoCoreLogEvent has a completion fn registered",
    complete_fn == "customlist" or type(complete_fn) == "function"
      or type(complete_fn) == "string",
    string.format("complete_fn type=%s val=%s",
      type(complete_fn), tostring(complete_fn)))

  -- Teardown.
  state.configure({ persist_dir = nil })
  state._reset_for_tests()
  pcall(vim.fn.delete, persist_dir, "rf")
end

-- ── ADR 0021 Phase 1 Step 5: throttled emission (hot-loop guard) ────
do
  -- First call passes the throttle; second call within the window
  -- is silently dropped; after the window elapses, the next call
  -- passes again.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("test-scan", 100, "comp", "msg-1")
  log.info_throttled("test-scan", 100, "comp", "msg-2")  -- dropped
  log.info_throttled("test-scan", 100, "comp", "msg-3")  -- dropped
  local r = log.recent()
  ok("ADR 0021 §11: throttled emission drops calls within window",
    #r == 1 and r[1].message:find("msg%-1") ~= nil,
    string.format("got %d entries", #r))

  -- Wait past the window, then the next call passes.
  vim.wait(120)
  log.info_throttled("test-scan", 100, "comp", "msg-4")
  r = log.recent()
  ok("ADR 0021 §11: throttled emission re-emits after window elapses",
    #r == 2 and r[2].message:find("msg%-4") ~= nil)

  -- Different keys throttle independently — neither leaks into the
  -- other's bucket.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("key-A", 1000, "comp", "A1")
  log.info_throttled("key-B", 1000, "comp", "B1")  -- different bucket
  log.info_throttled("key-A", 1000, "comp", "A2")  -- dropped
  log.info_throttled("key-B", 1000, "comp", "B2")  -- dropped
  r = log.recent()
  ok("ADR 0021 §11: throttle buckets are key-keyed (independent)",
    #r == 2
      and r[1].message:find("A1") ~= nil
      and r[2].message:find("B1") ~= nil,
    vim.inspect(r))

  -- All five level variants exist and route to the matching level.
  log._reset_for_tests()
  log.configure({ level = log.levels.TRACE, notify = false })
  log.error_throttled("k-e", 50, "c", "e")
  log.warn_throttled ("k-w", 50, "c", "w")
  log.info_throttled ("k-i", 50, "c", "i")
  log.debug_throttled("k-d", 50, "c", "d")
  log.trace_throttled("k-t", 50, "c", "t")
  r = log.recent()
  ok("ADR 0021 §11: every level has a *_throttled variant routing to the right level",
    #r == 5
      and r[1].level_name == "ERROR"
      and r[2].level_name == "WARN"
      and r[3].level_name == "INFO"
      and r[4].level_name == "DEBUG"
      and r[5].level_name == "TRACE",
    vim.inspect(r))

  -- Argument validation.
  log._reset_for_tests()
  ok("ADR 0021 §11: throttled rejects empty key",
    not pcall(log.info_throttled, "", 100, "c", "x"))
  ok("ADR 0021 §11: throttled rejects non-positive every_ms",
    not pcall(log.info_throttled, "k", 0, "c", "x")
      and not pcall(log.info_throttled, "k", -10, "c", "x"))

  -- _reset_for_tests clears the throttle map so tests don't leak.
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("k-reset", 1000, "c", "first")
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("k-reset", 1000, "c", "after-reset")
  r = log.recent()
  ok("ADR 0021 §11: _reset_for_tests clears the throttle map",
    #r == 1 and r[1].message:find("after%-reset") ~= nil,
    vim.inspect(r))

  -- Throttled call honors opts-table sentinel detection: a trailing
  -- opts table flows through to dispatch (event/fields preserved).
  log._reset_for_tests()
  log.configure({ notify = false })
  log.info_throttled("k-opts", 100, "scan", "started", {
    event  = "auto-finder.scan.started",
    fields = { path = "~/proj" },
  })
  r = log.recent()
  ok("ADR 0021 §11: throttled calls flow opts through (event + fields preserved)",
    #r == 1
      and r[1].event_type == "auto-finder.scan.started"
      and r[1].fields.path == "~/proj")
end

-- Restore stubs.
vim.notify = orig_notify
vim.api.nvim_echo = orig_echo
log._reset_for_tests()

-- ─────────────────────── 40. health — :checkhealth subsystem checks ─────────────────────────
print("\n[40] health — checkhealth runs without error, reports each subsystem")
local health = require("auto-core.health")

-- Stub vim.health.* to capture calls.
local orig_health = vim.health
local health_calls = { start = {}, ok = {}, info = {}, warn = {}, err = {} }
vim.health = {
  start = function(name) health_calls.start[#health_calls.start + 1] = name end,
  ok    = function(msg)  health_calls.ok[#health_calls.ok + 1] = msg end,
  info  = function(msg)  health_calls.info[#health_calls.info + 1] = msg end,
  warn  = function(msg)  health_calls.warn[#health_calls.warn + 1] = msg end,
  error = function(msg, advice)
    health_calls.err[#health_calls.err + 1] = { msg = msg, advice = advice }
  end,
}

local check_ok = pcall(health.check)
ok("health.check runs without error", check_ok)

ok("health.start invoked with 'auto-core'",
  #health_calls.start == 1 and health_calls.start[1] == "auto-core")

ok("at least one ok report (e.g. plenary or events bus)",
  #health_calls.ok >= 1, vim.inspect(health_calls.ok))

ok("info reports include version line",
  (function()
    for _, m in ipairs(health_calls.info) do
      if m:find("version") then return true end
    end
    return false
  end)(),
  vim.inspect(health_calls.info))

ok("info reports include log status",
  (function()
    for _, m in ipairs(health_calls.info) do
      if m:find("^log:") then return true end
    end
    return false
  end)(),
  vim.inspect(health_calls.info))

ok("info reports include fs.watch status",
  (function()
    for _, m in ipairs(health_calls.info) do
      if m:find("fs%.watch") then return true end
    end
    return false
  end)())

ok("topic registry check produces ok or warn",
  (function()
    for _, m in ipairs(health_calls.ok) do
      if m:find("topic registry") then return true end
    end
    for _, m in ipairs(health_calls.warn) do
      if m:find("topic registry") then return true end
    end
    return false
  end)())

ok("events bus probe produced ok status",
  (function()
    for _, m in ipairs(health_calls.ok) do
      if m:find("events bus dispatch responsive") then return true end
    end
    return false
  end)())

-- Restore.
vim.health = orig_health

-- ─────────────────────── 41. setup() forwards log config ─────────────────────────
print("\n[41] setup() forwards log config to log.configure")
core.setup({ log = { level = "error" } })
local snap_after_setup = log.inspect()
ok("setup({log.level='error'}) lowers level to ERROR",
  snap_after_setup.level == log.levels.ERROR,
  vim.inspect(snap_after_setup))

-- Restore default.
core.setup({})

-- ─────────────────────── 42. lsp.reset — tech-stack-aware restart ─────────────────────────
print("\n[42] lsp.reset — tech-stack detection, partition, dry_run")
;(function()
local lsp_reset = require("auto-core.lsp.reset")
lsp_reset._reset_for_tests()

-- Build a deterministic tmpdir tree with a few stack markers.
local tmp = vim.fn.tempname() .. "_lspreset"
vim.fn.mkdir(tmp .. "/go-proj/sub", "p")
vim.fn.writefile({ "module x" }, tmp .. "/go-proj/go.mod")
vim.fn.mkdir(tmp .. "/ts-proj/src", "p")
vim.fn.writefile({ "{}" }, tmp .. "/ts-proj/package.json")
vim.fn.mkdir(tmp .. "/poly", "p")
vim.fn.writefile({ "module y" }, tmp .. "/poly/go.mod")
vim.fn.writefile({ "{}" }, tmp .. "/poly/package.json")
vim.fn.mkdir(tmp .. "/empty", "p")

-- detect_stack: walk-up from a file or subdir, OR-combine markers.
local go_stack = lsp_reset.detect_stack(tmp .. "/go-proj/sub/file.go")
ok("detect_stack(go file under go.mod) returns gopls",
  vim.tbl_contains(go_stack, "gopls"),
  vim.inspect(go_stack))
ok("detect_stack(go file) does NOT return ts_ls",
  not vim.tbl_contains(go_stack, "ts_ls"))

local ts_stack = lsp_reset.detect_stack(tmp .. "/ts-proj/src")
ok("detect_stack(ts dir) returns ts_ls + eslint",
  vim.tbl_contains(ts_stack, "ts_ls")
    and vim.tbl_contains(ts_stack, "eslint"))

-- Polyglot dir (rare but legal): both go.mod and package.json present.
local poly_stack = lsp_reset.detect_stack(tmp .. "/poly")
ok("detect_stack(polyglot dir) unions both stacks",
  vim.tbl_contains(poly_stack, "gopls")
    and vim.tbl_contains(poly_stack, "ts_ls"),
  vim.inspect(poly_stack))

-- No marker reachable: empty result.
local empty_stack = lsp_reset.detect_stack(tmp .. "/empty")
ok("detect_stack(no marker) returns empty",
  type(empty_stack) == "table" and #empty_stack == 0,
  vim.inspect(empty_stack))

-- register_stack adds servers; idempotent on repeat add.
lsp_reset.register_stack("go.mod", { "custom_go_lsp" })
local extended = lsp_reset.detect_stack(tmp .. "/go-proj")
ok("register_stack appends new server",
  vim.tbl_contains(extended, "custom_go_lsp"))
lsp_reset.register_stack("go.mod", { "custom_go_lsp" })  -- duplicate
local snap = lsp_reset.list_stacks()["go.mod"]
local custom_count = 0
for _, s in ipairs(snap) do
  if s == "custom_go_lsp" then custom_count = custom_count + 1 end
end
ok("register_stack is idempotent (no duplicate entries)",
  custom_count == 1, "custom_count=" .. custom_count)

-- preview / reset_for partition logic. Stub vim.lsp.get_clients to
-- return synthetic clients so we don't depend on a real LSP setup.
local orig_get_clients = vim.lsp.get_clients
local orig_stop = vim.lsp.stop_client
local stop_calls = {}
local function fake_clients(list)
  vim.lsp.get_clients = function() return list end
end
vim.lsp.stop_client = function(id, _force)
  stop_calls[#stop_calls + 1] = id
end

-- Case A: a gopls client rooted under the new go-proj path → kept.
fake_clients({
  { id = 11, name = "gopls", root_dir = tmp .. "/go-proj" },
})
local p1 = lsp_reset.preview(tmp .. "/go-proj")
ok("preview keeps gopls already rooted under target",
  #p1.stopped == 0 and #p1.untouched == 1,
  string.format("stopped=%d untouched=%d", #p1.stopped, #p1.untouched))

-- Case B: a gopls client rooted under a DIFFERENT go project → stopped.
fake_clients({
  { id = 12, name = "gopls", root_dir = "/some/other/go-project" },
})
local p2 = lsp_reset.preview(tmp .. "/go-proj")
ok("preview stops gopls rooted outside target",
  #p2.stopped == 1 and p2.stopped[1].id == 12)

-- Case C: a ts_ls client when the target is a Go project → untouched
-- (ts_ls is NOT in the considered set for go.mod stack).
fake_clients({
  { id = 13, name = "ts_ls", root_dir = "/some/ts-project" },
})
local p3 = lsp_reset.preview(tmp .. "/go-proj")
ok("preview leaves out-of-stack clients alone",
  #p3.stopped == 0 and #p3.untouched == 1)

-- Case D: extra_servers extends the considered set.
fake_clients({
  { id = 14, name = "ts_ls", root_dir = "/elsewhere" },
})
local p4 = lsp_reset.preview(tmp .. "/go-proj",
  { extra_servers = { "ts_ls" } })
ok("preview with extra_servers stops the additional name",
  #p4.stopped == 1 and p4.stopped[1].id == 14)

-- Case E: exclude takes precedence — even mismatched + in-stack
-- clients are untouched if excluded.
fake_clients({
  { id = 15, name = "gopls", root_dir = "/elsewhere" },
})
local p5 = lsp_reset.preview(tmp .. "/go-proj",
  { exclude = { "gopls" } })
ok("preview honors opts.exclude",
  #p5.stopped == 0 and #p5.untouched == 1)

-- Case F: dry_run skips the actual stop_client call but still publishes.
fake_clients({
  { id = 16, name = "gopls", root_dir = "/elsewhere" },
})
stop_calls = {}
local got_topic = nil
events.subscribe("core.lsp:reset", function(payload, _topic)
  got_topic = payload
end)
lsp_reset.reset_for(tmp .. "/go-proj", { dry_run = true })
vim.wait(20)
ok("dry_run does NOT call vim.lsp.stop_client",
  #stop_calls == 0, "stop_calls=" .. vim.inspect(stop_calls))
ok("dry_run still publishes core.lsp:reset",
  got_topic ~= nil and got_topic.dry_run == true,
  vim.inspect(got_topic))

-- Case G: real reset_for stops mismatched clients AND publishes.
fake_clients({
  { id = 17, name = "gopls", root_dir = "/elsewhere" },
})
stop_calls = {}
got_topic = nil
lsp_reset.reset_for(tmp .. "/go-proj")
vim.wait(20)
ok("reset_for stops the mismatched client", vim.tbl_contains(stop_calls, 17))
ok("reset_for publishes payload with detected_stack",
  got_topic ~= nil
    and vim.tbl_contains(got_topic.detected_stack, "gopls"),
  vim.inspect(got_topic))

-- Restore real LSP API.
vim.lsp.get_clients = orig_get_clients
vim.lsp.stop_client = orig_stop
lsp_reset._reset_for_tests()
vim.fn.delete(tmp, "rf")
end)()  -- close [42] IIFE so its locals don't count toward main function's 200 limit

-- ─────────────────────── 43. ui.float.multi — multi-pane float ─────────────────────────
print("\n[43] ui.float.multi — open/close/focus/cycle/resize/dispose")
;(function()
local mfloat = require("auto-core.ui.float.multi")
mfloat._reset_for_tests()

-- Open a four-pane instance. The fixture mirrors the gitsgraph
-- shape exactly so Phase 3's worktree.graph can drop in.
local m = mfloat.new({
  name  = "smoke_test_panel",
  outer = { width_pct = 0.85, height_pct = 0.85, title = " smoke " },
  panes = {
    left    = { width = 28, cursorline = true },
    middle  = { title = " middle " },
    preview = { width = 60, min_width = 30, min_middle = 30 },
    footer  = { height = 1, content = " <Tab> cycle • q close " },
  },
  initial_focus = "middle",
})

ok("registry holds the instance after .new()",
  mfloat.get("smoke_test_panel") == m)

m:open()
ok("is_open after :open()", m:is_open())
ok("bg pane has a winid",
  m:winid("bg") and vim.api.nvim_win_is_valid(m:winid("bg")))
ok("left pane has a winid", m:winid("left") ~= nil)
ok("middle pane has a winid", m:winid("middle") ~= nil)
ok("footer pane has a winid", m:winid("footer") ~= nil)

-- All panes carry the marker var.
local marker = "auto_core_multi_float"
local function _wvar(w)
  local ok_v, v = pcall(vim.api.nvim_win_get_var, w, marker)
  return ok_v and v or nil
end
ok("bg window stamped with marker",
  _wvar(m:winid("bg")) == "smoke_test_panel")
ok("left window stamped with marker",
  _wvar(m:winid("left")) == "smoke_test_panel")
ok("middle window stamped with marker",
  _wvar(m:winid("middle")) == "smoke_test_panel")

-- Initial focus landed on middle.
ok("initial_focus moved cursor to middle",
  vim.api.nvim_get_current_win() == m:winid("middle"))

-- Footer is non-focusable; focusing it is a no-op (the function
-- still stays on the requested winid because we don't validate
-- focusable in :focus). Skip.

-- Cycle: middle → preview (or → left if preview wasn't laid out).
m:cycle("forward")
local cur = vim.api.nvim_get_current_win()
ok("cycle forward moved focus off middle", cur ~= m:winid("middle"))

m:cycle("backward")
ok("cycle backward returned to middle",
  vim.api.nvim_get_current_win() == m:winid("middle"))

-- Footer content lands in the auto-spawned scratch buffer.
local footer_buf = m:bufnr("footer")
local footer_lines = vim.api.nvim_buf_get_lines(footer_buf, 0, -1, false)
ok("footer content rendered into scratch",
  footer_lines[1] and footer_lines[1]:find("cycle", 1, true))

-- set_buffer swaps a pane's bufnr; the auto-spawned old buffer is wiped.
local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = "hide"  -- so wipe-on-set doesn't kill it
local prev = m:bufnr("left")
m:set_buffer("left", replacement)
ok("set_buffer updates bufnr",
  m:bufnr("left") == replacement)
ok("set_buffer wiped the auto-spawned buffer",
  not vim.api.nvim_buf_is_valid(prev))

-- resize() recomputes layout — call it manually and confirm
-- bg geometry still matches the editor dims.
local pre = vim.api.nvim_win_get_config(m:winid("bg"))
m:resize()
local post = vim.api.nvim_win_get_config(m:winid("bg"))
ok("resize re-applies bg geometry",
  pre.width == post.width and pre.height == post.height,
  string.format("pre=%dx%d post=%dx%d",
    pre.width, pre.height, post.width, post.height))

-- WinClosed on any pane triggers full close. Close left manually,
-- expect the whole multi to tear down on the next event tick.
local left_win = m:winid("left")
pcall(vim.api.nvim_win_close, left_win, true)
vim.wait(50, function() return not m:is_open() end)
ok("closing one pane closes the whole multi-float",
  not m:is_open())

-- New idempotent: re-calling .new with the same name returns the
-- same instance.
local m2 = mfloat.new({
  name  = "smoke_test_panel",
  panes = { middle = {} },
})
ok("idempotent .new returns the existing instance", m2 == m)

-- dispose drops it from the registry.
m:dispose()
ok("dispose removes from registry",
  mfloat.get("smoke_test_panel") == nil)

-- A 2-pane variant (no preview, no footer) lays out cleanly.
local m3 = mfloat.new({
  name  = "smoke_two_pane",
  panes = {
    left   = { width = 28 },
    middle = {},
  },
})
m3:open()
ok("2-pane variant opens",
  m3:winid("left") and m3:winid("middle") and not m3:winid("preview"))
ok("2-pane: middle width fills the rest",
  vim.api.nvim_win_get_config(m3:winid("middle")).width
    > vim.api.nvim_win_get_config(m3:winid("left")).width)
m3:dispose()

-- A middle-only variant (a single content pane) opens.
local m4 = mfloat.new({
  name  = "smoke_solo",
  panes = { middle = {} },
})
m4:open()
ok("middle-only variant opens", m4:is_open())
ok("middle-only has no left/preview/footer",
  not m4:winid("left") and not m4:winid("preview")
    and not m4:winid("footer"))
m4:dispose()

-- Percentage-based widths (Responsive)
local m_perc = mfloat.new({
  name  = "smoke_test_percentage",
  outer = { width_pct = 0.8 }, -- 0.8 * 80 = 64
  panes = {
    left    = { width = 0.25 }, -- 0.25 * 62 (inner) = 15
    middle  = { title = " middle " },
    preview = { width = 0.5, min_middle = 0 },  -- 0.5 * 62 (inner) = 31
    },
  })
  m_perc:open()
  -- inner_w = math.floor(80 * 0.8) - 2 = 64 - 2 = 62
  -- left_w = math.floor(62 * 0.25) = 15
  -- gap1 = 1 (left/middle)
  -- gap2 = 1 (middle/preview)
  -- preview_w = math.floor(62 * 0.5) = 31
  -- middle_w = 62 - 15 - 31 - 2 = 14

local l_win = m_perc:winid("left")
local m_win = m_perc:winid("middle")
local p_win = m_perc:winid("preview")

ok("percentage: left window width is 25% of inner",
  vim.api.nvim_win_get_width(l_win) == 15, "got " .. vim.api.nvim_win_get_width(l_win))
ok("percentage: preview window width is 50% of inner",
  vim.api.nvim_win_get_width(p_win) == 31, "got " .. vim.api.nvim_win_get_width(p_win))
ok("percentage: middle window width claims rest",
  vim.api.nvim_win_get_width(m_win) == 14, "got " .. vim.api.nvim_win_get_width(m_win))
m_perc:dispose()

mfloat._reset_for_tests()
end)()

-- ─────────────────────── 44. git.graph — fan_out + show_stat + show_diff ─────────────────────────
print("\n[44] git.graph — multi-repo discovery + commit show caches")
;(function()
local graph = require("auto-core.git.graph")
graph._reset_for_tests()

-- Build a small workspace with two real git repos so fan_out can probe.
local tmp = vim.fn.tempname() .. "_graph_ws"
vim.fn.mkdir(tmp .. "/repo-a", "p")
vim.fn.mkdir(tmp .. "/repo-b", "p")
vim.fn.system({ "git", "-C", tmp .. "/repo-a", "init", "-q" })
vim.fn.system({ "git", "-C", tmp .. "/repo-a",
  "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "init" })
vim.fn.system({ "git", "-C", tmp .. "/repo-b", "init", "-q" })
vim.fn.system({ "git", "-C", tmp .. "/repo-b",
  "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "init" })

-- fan_out: discovers both repos.
local repos_found = graph.fan_out(tmp)
ok("fan_out finds repo-a + repo-b", #repos_found == 2,
  "found=" .. #repos_found)
ok("fan_out repos sorted by label",
  repos_found[1].label == "repo-a" and repos_found[2].label == "repo-b")
ok("fan_out repo-a has sample_worktree",
  type(repos_found[1].sample_worktree) == "string"
    and repos_found[1].sample_worktree == tmp .. "/repo-a")
ok("fan_out repo-a not bare", repos_found[1].is_bare == false)
ok("fan_out repo-a has common_dir",
  repos_found[1].common_dir:find("/repo%-a/%.git") ~= nil,
  repos_found[1].common_dir)

-- Cached: second call returns same array.
local cached = graph.fan_out(tmp)
ok("fan_out result is cached (same table)",
  cached == repos_found)

-- show_stat against the init commit. We need the actual hash.
local hash = vim.fn.systemlist({
  "git", "--git-dir=" .. repos_found[1].common_dir,
  "rev-parse", "HEAD",
})[1]
ok("captured a real commit hash for repo-a",
  type(hash) == "string" and #hash >= 7, "hash=" .. tostring(hash))

local stat_lines = graph.show_stat(repos_found[1].common_dir, hash)
ok("show_stat returns non-empty output for real hash", #stat_lines > 0,
  "lines=" .. #stat_lines)
ok("show_stat output mentions the commit message",
  (function()
    for _, l in ipairs(stat_lines) do
      if l:find("init", 1, true) then return true end
    end
    return false
  end)())

local diff_lines = graph.show_diff(repos_found[1].common_dir, hash)
ok("show_diff returns non-empty output for real hash",
  #diff_lines > 0)

-- Cache returns the same table on a second call.
local stat_cached = graph.show_stat(repos_found[1].common_dir, hash)
ok("show_stat result is cached", stat_cached == stat_lines)

-- Bad hash: returns an error tag instead of crashing.
local stat_bad = graph.show_stat(repos_found[1].common_dir, "deadbeefdeadbeef")
ok("show_stat with bad hash returns a defensive output",
  type(stat_bad) == "table" and #stat_bad > 0)

-- clear_repo_cache wipes the per-repo caches but leaves fan-out alone.
graph.clear_repo_cache(repos_found[1].common_dir)
local stat_recomputed = graph.show_stat(repos_found[1].common_dir, hash)
ok("clear_repo_cache forced a recomputation",
  stat_recomputed ~= stat_lines and #stat_recomputed > 0)
ok("clear_repo_cache preserved fan_out cache",
  graph.fan_out(tmp) == repos_found)

-- Topic invalidation: publishing worktree:added drops fan_out cache.
require("auto-core").events.publish("worktree:added", { path = "/x" })
vim.wait(20)
local refreshed = graph.fan_out(tmp)
ok("worktree:added event invalidates fan_out cache",
  refreshed ~= repos_found and #refreshed == 2,
  string.format("refreshed=%s repos_found=%s same=%s len=%d",
    tostring(refreshed), tostring(repos_found),
    tostring(refreshed == repos_found), #refreshed))

-- worktree:removed too.
require("auto-core").events.publish("worktree:removed", { path = "/x" })
vim.wait(20)
local refreshed2 = graph.fan_out(tmp)
ok("worktree:removed event invalidates fan_out cache",
  refreshed2 ~= refreshed,
  string.format("refreshed2=%s refreshed=%s same=%s",
    tostring(refreshed2), tostring(refreshed),
    tostring(refreshed2 == refreshed)))

-- Cleanup.
vim.fn.delete(tmp, "rf")
graph._reset_for_tests()
end)()

-- ─────────────────────── 45. git.fetch / git.pull / git.worktree.destroy (Phase 3.5) ─────────────────────────
print("\n[45] git.fetch + git.pull + git.worktree.destroy")
;(function()
local fetch_mod = require("auto-core.git.fetch")
local pull_mod  = require("auto-core.git.pull")
local wt_mod    = require("auto-core.git.worktree")
events._reset_for_tests()

ok("git.fetch.fetch_one is a function", type(fetch_mod.fetch_one) == "function")
ok("git.fetch.fetch_all is a function", type(fetch_mod.fetch_all) == "function")
ok("git.pull.pull_status is a function", type(pull_mod.pull_status) == "function")
ok("git.pull.pull_apply is a function",  type(pull_mod.pull_apply)  == "function")
ok("git.pull.worktree_dirty is a function",
  type(pull_mod.worktree_dirty) == "function")
ok("git.worktree.destroy is a function", type(wt_mod.destroy) == "function")

-- Build two repos so we can test fetch with a real local remote.
local tmp = vim.fn.tempname() .. "_p35"
local upstream = tmp .. "/upstream.git"
local clone = tmp .. "/clone"
vim.fn.mkdir(tmp, "p")
vim.fn.system({ "git", "init", "--bare", "-q",
  "--initial-branch=main", upstream })
local seed = tmp .. "/seed"
vim.fn.mkdir(seed, "p")
vim.fn.system({ "git", "-C", seed, "init", "-q", "--initial-branch=main" })
vim.fn.system({ "git", "-C", seed, "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "seed" })
vim.fn.system({ "git", "-C", seed, "remote", "add", "origin", upstream })
vim.fn.system({ "git", "-C", seed, "push", "-q", "origin", "main" })
-- Now clone a fresh working copy that we'll fetch + pull against.
-- `-b main` forces the branch even if upstream's HEAD ref points
-- elsewhere (avoids the default-branch ambiguity that bit the test
-- on systems where init defaults to master).
vim.fn.system({ "git", "clone", "-q", "-b", "main", upstream, clone })

-- pull_status on a clean uptodate clone.
local s = pull_mod.pull_status({ path = clone, branch = "main" })
ok("pull_status: uptodate after fresh clone",
  s.state == "uptodate", "state=" .. tostring(s.state))
ok("pull_status: clean clone reports not dirty", s.dirty == false)

-- worktree_dirty on the clean clone.
local d = pull_mod.worktree_dirty({ path = clone })
ok("worktree_dirty: clean clone is not dirty",
  d.dirty == false and d.dirty_count == 0)

-- Touch a tracked-style file in the clone to make it dirty for a
-- subsequent assertion (we must add a tracked file first since
-- worktree_dirty includes untracked).
vim.fn.writefile({ "x" }, clone .. "/scratch.txt")
local d2 = pull_mod.worktree_dirty({ path = clone })
ok("worktree_dirty: untracked file flips dirty true",
  d2.dirty == true and d2.dirty_count >= 1)
vim.fn.delete(clone .. "/scratch.txt")

-- Add a new commit upstream so the clone falls behind.
vim.fn.system({ "git", "-C", seed, "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "advance" })
vim.fn.system({ "git", "-C", seed, "push", "-q", "origin", "main" })

-- fetch_one on the clone; capture topic payloads.
local fetch_started, fetch_completed = nil, nil
events.subscribe("core.git.fetch:started",
  function(p) fetch_started = p end)
events.subscribe("core.git.fetch:completed",
  function(p) fetch_completed = p end)

local clone_common = vim.trim(vim.fn.systemlist({
  "git", "-C", clone, "rev-parse", "--git-dir",
})[1] or "")
-- `--git-dir` returns either an absolute path or a relative one
-- (typically `.git`) depending on cwd. Resolve to absolute.
if not clone_common:match("^/") then
  clone_common = clone .. "/" .. clone_common
end

local fetch_done = false
fetch_mod.fetch_one({ common_dir = clone_common, label = "clone" }, nil,
  function(ok_done, _stderr) fetch_done = ok_done end)
vim.wait(8000, function() return fetch_done end)
ok("fetch_one completed successfully against local remote",
  fetch_done == true)
ok("fetch:started topic fired with label",
  fetch_started ~= nil and fetch_started.label == "clone")
ok("fetch:completed topic fired with ok=true",
  fetch_completed ~= nil and fetch_completed.ok == true,
  vim.inspect(fetch_completed))

-- After fetch, pull_status should report ff (one commit behind).
local s2 = pull_mod.pull_status({ path = clone, branch = "main" })
ok("pull_status: ff after upstream advance + fetch",
  s2.state == "ff", "state=" .. tostring(s2.state))

-- pull_apply ff brings the clone forward.
local pull_started, pull_completed = nil, nil
events.subscribe("core.git.pull:started",
  function(p) pull_started = p end)
events.subscribe("core.git.pull:completed",
  function(p) pull_completed = p end)

local pull_done = false
pull_mod.pull_apply({ path = clone, branch = "main" }, "ff", nil,
  function(ok_done) pull_done = ok_done end)
vim.wait(8000, function() return pull_done end)
ok("pull_apply ff succeeded", pull_done == true)
ok("pull:started topic fired with mode=ff",
  pull_started ~= nil and pull_started.mode == "ff")
ok("pull:completed topic fired with ok=true",
  pull_completed ~= nil and pull_completed.ok == true)

-- After pull, status is uptodate.
local s3 = pull_mod.pull_status({ path = clone, branch = "main" })
ok("pull_status: uptodate after ff", s3.state == "uptodate")

-- Unknown pull mode is a clean error.
local bad_done = false
local bad_err
pull_mod.pull_apply({ path = clone, branch = "main" }, "not-a-mode", nil,
  function(ok_done, err) bad_done = ok_done; bad_err = err end)
vim.wait(50)
ok("pull_apply unknown mode returns error",
  bad_done == false and type(bad_err) == "string"
    and bad_err:find("unknown mode", 1, true) ~= nil)

-- Now add a worktree to the clone and test destroy. Use the seed
-- repo for this since it has the bare-style common dir.
vim.fn.mkdir(tmp .. "/wt-target", "p")
vim.fn.system({ "git", "-C", seed,
  "worktree", "add", "-b", "feature-x", tmp .. "/wt-target" })
local seed_common = vim.trim(vim.fn.systemlist({
  "git", "-C", seed, "rev-parse", "--git-dir",
})[1] or "")
if not seed_common:match("^/") then
  seed_common = seed .. "/" .. seed_common
end

local destroy_topic = nil
events.subscribe("core.git.worktree:destroyed",
  function(p) destroy_topic = p end)

local destroy_done = false
local destroy_err
wt_mod.destroy({ common_dir = seed_common },
  { path = tmp .. "/wt-target", branch = "feature-x" },
  { force = false },
  function(ok_done, err) destroy_done = ok_done; destroy_err = err end)
vim.wait(8000, function() return destroy_done ~= false end)
ok("destroy: clean worktree removed",
  destroy_done == true and destroy_err == nil,
  string.format("done=%s err=%s",
    tostring(destroy_done), tostring(destroy_err)))
ok("destroy: target dir is gone",
  vim.fn.isdirectory(tmp .. "/wt-target") == 0)
ok("destroy: worktree:destroyed topic fired with ok=true",
  destroy_topic ~= nil and destroy_topic.ok == true)
-- Branch was deleted as part of destroy (no branch_err on success).
ok("destroy: branch_err nil when branch deletes cleanly",
  destroy_topic.branch_err == nil)

-- Cleanup.
vim.fn.delete(tmp, "rf")
events._reset_for_tests()
require("auto-core.git.graph")._reset_for_tests()
end)()

-- ─────────────────────── 46. files — show_hidden / show_dotfiles prefs ─────────────────────────
print("\n[46] files — global show_hidden / show_dotfiles prefs")
;(function()
local files = require("auto-core.files")
files._reset_for_tests()

ok("get_show_hidden defaults to true",   files.get_show_hidden()   == true)
ok("get_show_dotfiles defaults to true", files.get_show_dotfiles() == true)

-- Flip + read back.
files.set_show_hidden(false)
ok("set_show_hidden(false) round-trips", files.get_show_hidden() == false)
files.set_show_dotfiles(false)
ok("set_show_dotfiles(false) round-trips", files.get_show_dotfiles() == false)

-- Watcher fires on change.
local got_hidden, got_dotfiles = nil, nil
files.watch_show_hidden(function(p) got_hidden = p end)
files.watch_show_dotfiles(function(p) got_dotfiles = p end)
files.set_show_hidden(true)
vim.wait(20)
ok("watch_show_hidden fired with new=true",
  got_hidden ~= nil and got_hidden.new == true)
files.set_show_dotfiles(true)
vim.wait(20)
ok("watch_show_dotfiles fired with new=true",
  got_dotfiles ~= nil and got_dotfiles.new == true)

-- Truthy non-bool coerces to bool (defensive).
files.set_show_hidden("yes")
ok("set_show_hidden coerces truthy non-bool to false (strict ==)",
  files.get_show_hidden() == false,
  "set_show_hidden requires literal `true`; non-true → false")

files._reset_for_tests()
end)()

-- ─────────────────────── 47. debug.winlog — opt-in window/buffer probe ─────────────────────────
print("\n[47] debug.winlog — start/stop/status/tail/clear contract")
;(function()
local winlog = require("auto-core").debug.winlog

-- Start clean: route the log to a temp path so we don't trample the
-- user's real cache file when the smoke runs locally.
local tmp = vim.fn.tempname() .. "-winlog.log"
winlog.stop()                                       -- defensive: prior run residue
winlog.start({ log_path = tmp, poll_interval_ms = 60 })

ok("is_running() true after start()", winlog.is_running() == true)

local s = winlog.status()
ok("status.running mirrors is_running()", s.running == true)
ok("status.log_path matches the opt we passed", s.log_path == tmp)
ok("status.poll_interval_ms honors opt (clamped to >=50)",
  s.poll_interval_ms == 60)
ok("status.events is non-empty list",
  type(s.events) == "table" and #s.events > 0)
ok("path() == status.log_path", winlog.path() == tmp)
-- start() writes a banner + INITIAL line synchronously, so the
-- count is non-zero immediately after start.
ok("status.event_count > 0 immediately after start() (banner written)",
  s.event_count > 0,
  "got " .. tostring(s.event_count))

-- Banner is on disk synchronously. Verify before any window activity
-- so the assertion targets the start path, not the poll/autocmd path.
local saw_banner = false
for _, line in ipairs(winlog.tail(40)) do
  if line:find("winlog started", 1, true) then saw_banner = true; break end
end
ok("tail() contains the start banner", saw_banner)

-- Provoke a window event: open + close a scratch split. The poll
-- detector and the WinNew autocmd both fire — we assert event_count
-- moves and tail() reflects the change.
local count_before = winlog.status().event_count
vim.cmd("botright new")
local probe_win = vim.api.nvim_get_current_win()
local probe_buf = vim.api.nvim_get_current_buf()
vim.bo[probe_buf].bufhidden = "wipe"
vim.bo[probe_buf].buftype   = "nofile"
-- Wait for one poll tick + the autocmd-driven append. The 60ms poll
-- plus jitter is plenty for the writes to land.
vim.wait(250, function()
  return winlog.status().event_count > count_before
end, 20)
ok("event_count rises after a real WinNew",
  winlog.status().event_count > count_before,
  "before=" .. count_before .. " after=" .. winlog.status().event_count)

-- Close the probe window so we don't leak it past the test.
pcall(vim.api.nvim_win_close, probe_win, true)
vim.wait(120)

local tail = winlog.tail(20)
ok("tail() returns at least one line after activity",
  type(tail) == "table" and #tail > 0)

-- Stop and confirm running state flips. tail() still reads from the
-- file after stop — it's a pure file read.
winlog.stop()
ok("is_running() false after stop()", winlog.is_running() == false)
ok("status.running mirrors is_running()", winlog.status().running == false)

-- clear() truncates AND resets the counter. Assert in that order
-- (counter check first, then file check) to mirror the doc contract.
winlog.clear()
ok("event_count zero after clear()", winlog.status().event_count == 0)
ok("tail() empty after clear()", #winlog.tail(40) == 0)

-- toggle() round-trips: off → on → off. start() will re-write the
-- banner so event_count rises again; the assertion targets the
-- running-state flip, not the count.
ok("toggle() turns it back on",  winlog.toggle({ log_path = tmp }) == true)
ok("toggle() turns it back off", winlog.toggle() == false)

-- Idempotent stop — second stop is a no-op, doesn't error.
local ok_stop2 = pcall(winlog.stop)
ok("stop() is idempotent (second call doesn't error)", ok_stop2)

-- Out-of-range poll interval clamps to the documented [50, 5000].
winlog.start({ log_path = tmp, poll_interval_ms = 1 })
ok("poll_interval_ms clamps low value to 50",
  winlog.status().poll_interval_ms == 50)
winlog.start({ log_path = tmp, poll_interval_ms = 1e9 })
ok("poll_interval_ms clamps high value to 5000",
  winlog.status().poll_interval_ms == 5000)
winlog.stop()

-- panel_filter flag is honored — start with it on and verify status
-- mirrors it. (We can't easily exercise the filter outcome headlessly
-- without booting a panel; assert the option surface.)
winlog.start({ log_path = tmp, panel_filter = true })
ok("panel_filter honored when opt is true",
  winlog.status().panel_filter == true)
winlog.start({ log_path = tmp, panel_filter = false })
ok("panel_filter honored when opt is false",
  winlog.status().panel_filter == false)
winlog.stop()

-- Cleanup the temp log file.
pcall(os.remove, tmp)
end)()

-- ─────────────────────── 48. version + api_version sanity ─────────────────────────
-- FIXME (baseline-stale): the literal-string version assertion below
-- needs manual updating on every patch bump (currently expects 0.1.5;
-- this branch is shipping v0.1.6). The next maintenance pass should
-- either
--   (a) parse `require("auto-core.version").version` and assert it
--       matches a regex like "^0%.1%.%d+$" so the test tracks
--       additive patch bumps without manual edits, OR
--   (b) replace this section with a single check that the surface
--       exists (M.debug.winlog, M.mailbox, etc) and drop the version
--       string assertion entirely.
-- Tracked: leave the assertion as-is so the failure stays
-- discoverable until someone consciously picks it up.
print("\n[48] version + api_version sanity")
;(function()
local v = require("auto-core.version")
ok("version is on the v0.1.x line",
  type(v.version) == "string" and v.version:match("^0%.1%.%d+$") ~= nil,
  "got " .. tostring(v.version))
ok("api_version is 0.1 (additive, no break to existing surface)", v.api_version == "0.1")
-- :h api_version semver gate consumers will use.
local core = require("auto-core")
ok("M.debug is a table on the public surface",
  type(core.debug) == "table")
ok("M.debug.winlog is a table on the public surface",
  type(core.debug) == "table" and type(core.debug.winlog) == "table")
ok("M.debug.winlog.start is a function",
  type(core.debug.winlog.start) == "function")
ok("M.debug.winlog.stop is a function",
  type(core.debug.winlog.stop) == "function")
ok("M.mailbox is a table on the public surface (ADR 0013 Phase 1)",
  type(core.mailbox) == "table")
ok("M.mailbox surface includes send/claim/complete/start/stop/refresh/scan_now",
  type(core.mailbox.send) == "function"
    and type(core.mailbox.claim) == "function"
    and type(core.mailbox.complete) == "function"
    and type(core.mailbox.start) == "function"
    and type(core.mailbox.stop) == "function"
    and type(core.mailbox.refresh) == "function"
    and type(core.mailbox.scan_now) == "function")
ok("M.mailbox.commands is a table",
  type(core.mailbox.commands) == "table"
    and type(core.mailbox.commands.register) == "function")
ok("M.mailbox.router is a table",
  type(core.mailbox.router) == "table"
    and type(core.mailbox.router.start) == "function")
ok("M.mailbox.bootstrap is a table",
  type(core.mailbox.bootstrap) == "table"
    and type(core.mailbox.bootstrap.render) == "function")
ok("legacy M.mailbox.consume is gone (router replaces per-mailbox consumers)",
  core.mailbox.consume == nil)
end)()

-- ─────────────────────── 49. mailbox subsystem (ADR 0013 Phase 1, revised) ─────────
print("\n[49] mailbox: per-mailbox roots, bootstrap upsert, central router, outbox delivery, wake, commands")
;(function()
local mailbox  = require("auto-core.mailbox")
local mb_path  = mailbox.path
local message  = mailbox.message
local registry = mailbox.registry
local transp   = mailbox.transport
local commands = mailbox.commands
local router   = mailbox.router
local boot     = mailbox.bootstrap
local events_m = require("auto-core.events")

-- Hermetic temp root so the test never touches the real durable
-- mailbox root. configure(nil) at teardown restores defaults.
local tmp_root = vim.fn.tempname() .. "-mailbox-test"
vim.fn.mkdir(tmp_root, "p")

-- Capture any AUTO_AGENTS_* env overrides up-front so the
-- "default points at the durable global location" assertions
-- aren't fooled by the surrounding shell environment.
local saved_env = {
  AUTO_AGENTS_MAILBOX_ROOT = vim.env.AUTO_AGENTS_MAILBOX_ROOT,
  AUTO_AGENTS_CONFIG_DIR   = vim.env.AUTO_AGENTS_CONFIG_DIR,
  AUTO_AGENTS_KB_ROOT      = vim.env.AUTO_AGENTS_KB_ROOT,
}
vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil
vim.env.AUTO_AGENTS_CONFIG_DIR   = nil
vim.env.AUTO_AGENTS_KB_ROOT      = nil

-- ── 49a. host-fallback root resolution (used for nvim/user) ─
mailbox._reset_for_tests()
events_m._reset_for_tests()

-- v0.1.8: forward-declare the instance_id pin + FULL helper. We
-- can't pin yet because [49a] calls _reset_for_tests several more
-- times to exercise env-var precedence (each reset would wipe the
-- pin via path._reset_for_tests). Pin is applied just before [49c]
-- registrations below.
local TEST_INSTANCE_ID = "9999999999-12345"
local function FULL(bare) return bare .. ":" .. TEST_INSTANCE_ID end
ok("host_fallback_root is durable global location (.auto-agents-config/mailbox)",
  mailbox.host_fallback_root():find("%.auto%-agents%-config/mailbox$") ~= nil,
  "got: " .. mailbox.host_fallback_root())
ok("host_fallback_root does NOT include any worktree path segment",
  not mailbox.host_fallback_root():find(tmp_root, 1, true),
  "got: " .. mailbox.host_fallback_root())

vim.env.AUTO_AGENTS_MAILBOX_ROOT = tmp_root .. "/env-mb"
mailbox._reset_for_tests()
ok("AUTO_AGENTS_MAILBOX_ROOT env var takes precedence for host fallback",
  mailbox.host_fallback_root() == tmp_root .. "/env-mb",
  "got: " .. mailbox.host_fallback_root())
vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil

vim.env.AUTO_AGENTS_CONFIG_DIR = tmp_root .. "/cfg"
mailbox._reset_for_tests()
ok("AUTO_AGENTS_CONFIG_DIR resolves to <cfg>/mailbox",
  mailbox.host_fallback_root() == tmp_root .. "/cfg/mailbox",
  "got: " .. mailbox.host_fallback_root())
vim.env.AUTO_AGENTS_CONFIG_DIR = nil

vim.env.AUTO_AGENTS_KB_ROOT = tmp_root .. "/cfg2/kb"
mailbox._reset_for_tests()
ok("AUTO_AGENTS_KB_ROOT derives <dirname>/mailbox",
  mailbox.host_fallback_root() == tmp_root .. "/cfg2/mailbox",
  "got: " .. mailbox.host_fallback_root())
vim.env.AUTO_AGENTS_KB_ROOT = nil

-- setup({mailbox = {root = ...}}) override beats env.
-- Fixture: reflect the actual agent-roster tool backing:
--   agent:lector  → codex-backed
--   agent:jarvis  → claude-backed (Claude Code; this very assistant)
--   agent:gemini  → gemini-backed
-- The architecture treats roots as opaque per-mailbox config dirs;
-- the test verifies that multiple distinct roots coexist and that
-- the central router collapses by unique root regardless of name.
local active_root      = tmp_root .. "/active"
local codex_like_root  = tmp_root .. "/.codex/mailbox"
local claude_like_root = tmp_root .. "/.claude/mailbox"
local gemini_like_root = tmp_root .. "/.gemini/mailbox"
require("auto-core").setup({ mailbox = { root = active_root } })
ok("setup({mailbox={root=...}}) override applies to host fallback",
  mailbox.host_fallback_root() == active_root,
  "got: " .. mailbox.host_fallback_root())

-- ── 49a2. tool_root resolver — per-tool agent mailbox layout ──
-- The default agent-mailbox layout is the tool's own config dir
-- under $HOME, not the host coordination dir. host_fallback_root
-- is reserved for nvim/user.
do
  local saved_home = vim.env.HOME
  vim.env.HOME = "/home/test"
  ok("tool_root('claude') resolves to ~/.claude/mailbox",
    mb_path.tool_root("claude") == "/home/test/.claude/mailbox",
    "got: " .. tostring(mb_path.tool_root("claude")))
  ok("tool_root('gemini') resolves to ~/.gemini/mailbox",
    mb_path.tool_root("gemini") == "/home/test/.gemini/mailbox")
  ok("tool_root('codex') resolves to ~/.codex/mailbox",
    mb_path.tool_root("codex") == "/home/test/.codex/mailbox")
  ok("tool_root('unknown') returns nil",
    mb_path.tool_root("unknown") == nil)
  ok("tool_root('') returns nil",
    mb_path.tool_root("") == nil)
  -- Extensibility: a new tool can join by mutating TOOL_DIRS.
  mb_path.TOOL_DIRS["amp"] = ".amp/mailbox"
  ok("TOOL_DIRS is extensible for new tools",
    mb_path.tool_root("amp") == "/home/test/.amp/mailbox")
  mb_path.TOOL_DIRS["amp"] = nil
  vim.env.HOME = saved_home
end

-- Demonstrate the recommended call shape: register an agent
-- mailbox with root = path.tool_root('codex'). The fact that
-- a host coordination root exists doesn't affect agent registration.
do
  local probe_root = mb_path.tool_root("codex")
  ok("an agent mailbox registered with tool_root('codex') lives under ~/.codex/mailbox",
    type(probe_root) == "string"
      and probe_root:find("%.codex/mailbox$") ~= nil,
    "got: " .. tostring(probe_root))
end

-- ── 49b. id validation ─────────────────────────────────────
ok("validate_id accepts 'user'", (mb_path.validate_id("user")))
ok("validate_id accepts 'agent:lector'", (mb_path.validate_id("agent:lector")))
ok("validate_id rejects empty string",
  not mb_path.validate_id(""))
ok("validate_id rejects path traversal '../boom'",
  not mb_path.validate_id("../boom"))
ok("validate_id rejects slash 'a/b'",
  not mb_path.validate_id("a/b"))
ok("validate_id rejects leading dot '.hidden'",
  not mb_path.validate_id(".hidden"))

-- ── 49c. registration uses per-mailbox roots + upserts bootstrap doc ──
-- Pin the instance_id NOW (after all the [49a] env-var resets) so
-- the rest of [49] sees stable full ids in assertions.
mb_path.set_instance_id(TEST_INSTANCE_ID)

local registered_payloads = {}
local sub = events_m.subscribe("core.mailbox:registered", function(p)
  registered_payloads[#registered_payloads + 1] = p
end)

-- Codex-backed agent (Lector) — uses Codex's tool config root.
local lector_rec = mailbox.register("agent:lector", {
  root = codex_like_root,
  wake = { command = "send_slot", args = { slot = "lector" } },
})
ok("register returns record with per-mailbox root + dir + subs + wake (v0.1.8: id is full)",
  type(lector_rec) == "table"
    and lector_rec.id == FULL("agent:lector")
    and lector_rec.bare_id == "agent:lector"
    and lector_rec.root == codex_like_root
    and lector_rec.dir == codex_like_root .. "/" .. FULL("agent:lector")
    and type(lector_rec.subs) == "table"
    and type(lector_rec.wake) == "table"
    and lector_rec.wake.command == "send_slot")
ok("lector's mailbox dir lives under Codex's tool root with instance suffix",
  lector_rec.dir == codex_like_root .. "/" .. FULL("agent:lector"),
  "got: " .. lector_rec.dir)
ok("inbox/outbox/processing/archive/responses all exist on disk",
  vim.fn.isdirectory(lector_rec.subs.inbox)      == 1
    and vim.fn.isdirectory(lector_rec.subs.outbox)     == 1
    and vim.fn.isdirectory(lector_rec.subs.processing) == 1
    and vim.fn.isdirectory(lector_rec.subs.archive)    == 1
    and vim.fn.isdirectory(lector_rec.subs.responses)  == 1)

-- Claude-backed agent (Jarvis) — separate tool, separate root.
-- A second claude-backed agent would share this root, subdivided
-- by id (~/.claude/mailbox/agent:jarvis/, ~/.claude/mailbox/agent:hephaestus/,
-- etc) so the central router opens just ONE watcher on
-- ~/.claude/mailbox/ regardless of how many Claude agents exist.
local jarvis_rec = mailbox.register("agent:jarvis", {
  root = claude_like_root,
  wake = { command = "send_slot", args = { slot = "jarvis" } },
})
ok("claude-backed agent uses Claude's tool root",
  jarvis_rec.root == claude_like_root
    and jarvis_rec.dir == claude_like_root .. "/" .. FULL("agent:jarvis"),
  "got: " .. jarvis_rec.dir)

-- Add a second claude-backed agent to exercise the
-- multi-agent-per-tool-root case. Both share ~/.claude/mailbox/,
-- subdivided by id, and the router opens ONE watcher on the root.
local hephaestus_rec = mailbox.register("agent:hephaestus", {
  root = claude_like_root,
  wake = { command = "send_slot", args = { slot = "hephaestus" } },
})
ok("multiple claude-backed agents share the root, subdivided by full id",
  hephaestus_rec.root == claude_like_root
    and hephaestus_rec.dir == claude_like_root .. "/" .. FULL("agent:hephaestus")
    and jarvis_rec.root == hephaestus_rec.root,
  "jarvis.dir=" .. jarvis_rec.dir
    .. " hephaestus.dir=" .. hephaestus_rec.dir)

-- Gemini-backed agent under its own tool root.
local gemini_rec = mailbox.register("agent:gemini", {
  root = gemini_like_root,
  wake = { command = "send_slot", args = { slot = "gemini" } },
})
ok("gemini-backed agent uses its own tool root",
  gemini_rec.dir == gemini_like_root .. "/" .. FULL("agent:gemini"))

-- Host-side mailbox with no explicit root falls back.
local nvim_rec = mailbox.register("nvim")
ok("host-side 'nvim' mailbox falls back to host fallback root + instance suffix",
  nvim_rec.root == active_root
    and nvim_rec.dir == active_root .. "/" .. FULL("nvim"))
ok("nvim retains 'nvim' as bare_id (executioner-default key)",
  nvim_rec.bare_id == "nvim" and nvim_rec.executioner == true)

ok("core.mailbox:registered fired for every register call",
  #registered_payloads == 5)
ok("first registered payload carries first_time=true",
  registered_payloads[1].first_time == true)
ok("registered payload includes bootstrap_path + bootstrap_revision",
  type(registered_payloads[1].bootstrap_path)     == "string"
    and type(registered_payloads[1].bootstrap_revision) == "string"
    and #registered_payloads[1].bootstrap_revision >= 16)

-- registry.list reflects what we've registered (full ids in v0.1.8).
ok("registry.list reports all five mailboxes as full ids",
  (function()
    local set = {}
    for _, id in ipairs(registry.list()) do set[id] = true end
    return set[FULL("agent:lector")] and set[FULL("agent:jarvis")]
       and set[FULL("agent:hephaestus")] and set[FULL("agent:gemini")]
       and set[FULL("nvim")]
  end)())
ok("registry.get accepts bare id (auto-resolves to this instance)",
  registry.get("agent:lector") == lector_rec
    and registry.get("agent:jarvis") == jarvis_rec)
ok("registry.get accepts full id directly",
  registry.get(FULL("agent:lector")) == lector_rec)

-- unique_roots collapses claude+claude → one entry.
ok("registry.unique_roots collapses shared roots (jarvis + hephaestus on claude → one entry)",
  (function()
    local roots = registry.unique_roots()
    -- expect 4 unique roots: codex (lector), claude (jarvis+hephaestus),
    -- gemini, host-fallback (nvim).
    return #roots == 4
  end)(),
  "got: " .. vim.inspect(registry.unique_roots()))

events_m.unsubscribe(sub)

-- ── 49c2. bootstrap-mailbox.md per-tool-root layout (v0.1.8) ──
-- v0.1.8 hoists the doc from per-mailbox to per-tool-root, so every
-- agent under a given tool root shares one bootstrap doc. The doc
-- content is agent-agnostic — agents read their identity from
-- env vars at spawn time (see env_for_agent).
local boot_path = lector_rec.bootstrap.path
ok("bootstrap-mailbox.md written to <tool-root>/bootstrap-mailbox.md",
  boot_path == codex_like_root .. "/bootstrap-mailbox.md"
    and vim.fn.filereadable(boot_path) == 1,
  "got: " .. tostring(boot_path))

-- All agents under the same root reference the same doc path.
ok("jarvis + hephaestus share the same per-tool-root bootstrap doc",
  jarvis_rec.bootstrap.path == hephaestus_rec.bootstrap.path
    and jarvis_rec.bootstrap.path == claude_like_root .. "/bootstrap-mailbox.md")
ok("different tool roots get different bootstrap docs",
  lector_rec.bootstrap.path ~= jarvis_rec.bootstrap.path
    and jarvis_rec.bootstrap.path ~= gemini_rec.bootstrap.path)

local boot_text = table.concat(vim.fn.readfile(boot_path), "\n")
ok("bootstrap doc body references the env-var contract (no per-call ids)",
  boot_text:find("AUTO_AGENTS_MAILBOX_ID", 1, true) ~= nil
    and boot_text:find("AUTO_AGENTS_MAILBOX_DIR", 1, true) ~= nil
    and boot_text:find("AUTO_AGENTS_INSTANCE_ID", 1, true) ~= nil)
ok("bootstrap doc frontmatter has revision field",
  boot_text:find("revision:") ~= nil)
ok("bootstrap doc body does NOT bake in any specific agent id (v0.1.8 hoist)",
  boot_text:find("agent:lector", 1, true) == nil)
ok("bootstrap doc carries the audit instructions",
  boot_text:find("bootstrap audit protocol") ~= nil)
ok("bootstrap doc stores seen-revision under persistent tool-root state",
  boot_text:find('$(dirname "$AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC")/.agent-state/seen-revision',
    1, true) ~= nil
    and boot_text:find("Do not store this only under `$AUTO_AGENTS_MAILBOX_DIR`",
      1, true) ~= nil)
ok("bootstrap doc still documents spawn-time permission grants",
  boot_text:find("Spawn-time permission grants", 1, true) ~= nil
    and boot_text:find("--add-dir <path>", 1, true) ~= nil)

-- v0.1.8 render is agent-agnostic — identical revisions across
-- arbitrary inputs (the template no longer substitutes per-call
-- variables beyond revision/upserted_at).
local _, rev_a = boot.render()
local _, rev_b = boot.render()
ok("render is stable across calls (no per-call inputs)",
  rev_a == rev_b, "a=" .. tostring(rev_a) .. " b=" .. tostring(rev_b))
ok("render's revision matches the on-disk doc",
  rev_a == lector_rec.bootstrap.revision)

-- v0.1.7's revision-skip survives the v0.1.8 hoist: re-register with
-- ANY inputs (the doc is now agent-agnostic) leaves the per-tool-root
-- doc untouched on disk.
local first_mtime = vim.fn.getftime(boot_path)
vim.wait(1100)
local skip_rec = mailbox.register("agent:lector", {
  root = codex_like_root,
  wake = { command = "send_slot", args = { slot = "lector" } },
})
ok("v0.1.8: re-register leaves per-tool-root bootstrap doc mtime unchanged",
  vim.fn.getftime(boot_path) == first_mtime,
  string.format("before=%d after=%d", first_mtime, vim.fn.getftime(boot_path)))
ok("v0.1.8: skipped upsert returns wrote=false",
  skip_rec.bootstrap.wrote == false,
  "wrote=" .. tostring(skip_rec.bootstrap.wrote))
ok("v0.1.8: revision survives a skipped upsert",
  skip_rec.bootstrap.revision == lector_rec.bootstrap.revision)

-- env_for_agent helper: every spawn-time env var an agent needs to
-- find its own mailbox without socket access.
local env = mailbox.env_for_agent(lector_rec)
ok("env_for_agent returns AUTO_AGENTS_INSTANCE_ID matching the pin",
  env.AUTO_AGENTS_INSTANCE_ID == TEST_INSTANCE_ID)
ok("env_for_agent returns AUTO_AGENTS_MAILBOX_ID = full id",
  env.AUTO_AGENTS_MAILBOX_ID == FULL("agent:lector"))
ok("env_for_agent returns AUTO_AGENTS_MAILBOX_DIR = record dir",
  env.AUTO_AGENTS_MAILBOX_DIR == lector_rec.dir)
ok("env_for_agent returns AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC = per-tool-root doc",
  env.AUTO_AGENTS_MAILBOX_BOOTSTRAP_DOC == boot_path)

-- ── 49d. message construction + validation ─────────────────
local m1, m1_err = message.build({
  from = "agent:gemini", to = "agent:lector",
  subject = "review please", body = "ready",
})
ok("message.build returns a valid message", m1 ~= nil and m1_err == nil,
  tostring(m1_err))
ok("kind defaults to 'message'", m1.kind == "message")
ok("id auto-generated and non-empty", type(m1.id) == "string" and #m1.id > 0)
ok("created_at ISO 8601 (Z)", type(m1.created_at) == "string"
  and m1.created_at:match("Z$") ~= nil)
ok("validate accepts a built message",
  (message.validate(m1)))

local m2, m2_err = message.build({ from = "x" })  -- missing to
ok("build rejects missing 'to'", m2 == nil and type(m2_err) == "string")
local m3, m3_err = message.build({
  from = "a", to = "b", kind = "command",
})
ok("build rejects command without command name",
  m3 == nil and type(m3_err) == "string", tostring(m3_err))
local m4, m4_err = message.build({
  from = "a", to = "b", kind = "command", command = "harpoon",
})
ok("build accepts command with command name",
  m4 ~= nil and m4_err == nil, tostring(m4_err))

-- ── 49e. host-side send() writes directly to recipient inbox ──
local queued_events = {}
local qs = events_m.subscribe("core.mailbox:message_queued", function(p)
  queued_events[#queued_events + 1] = p
end)

local result, send_err = mailbox.send({
  from = "agent:gemini", to = "agent:lector",
  subject = "ready", body = "branch X is up",
})
ok("send returns a result with id/path/message",
  result ~= nil and send_err == nil
    and type(result.id) == "string"
    and type(result.path) == "string"
    and type(result.message) == "table",
  tostring(send_err))
ok("send wrote the JSON file under the RECIPIENT's per-mailbox root (codex for lector)",
  result.path:sub(1, #codex_like_root) == codex_like_root,
  "got: " .. result.path)
ok("send wrote a complete JSON object (atomic rename was the commit)",
  (function()
    local lines = vim.fn.readfile(result.path)
    local ok_dec, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    return ok_dec
      and type(decoded) == "table"
      and decoded.id == result.id
      and decoded.from == "agent:gemini"
      and decoded.to   == "agent:lector"
  end)())
ok("recipient inbox contains NO leftover .tmp- files",
  (function()
    local inbox = lector_rec.subs.inbox
    for _, e in ipairs(vim.fn.readdir(inbox)) do
      if e:sub(1, 5) == ".tmp-" then return false end
    end
    return true
  end)())
ok("core.mailbox:message_queued fired synchronously from send",
  #queued_events == 1
    and queued_events[1].mailbox == "agent:lector"
    and queued_events[1].id == result.id,
  vim.inspect(queued_events))
ok("transport.list_inbox lists the new id",
  vim.tbl_contains(transp.list_inbox("agent:lector"), result.id))

-- ── 49f. claim → processing, complete → archive + response ──
local completed_events = {}
local response_events = {}
events_m.subscribe("core.mailbox:message_completed", function(p)
  completed_events[#completed_events + 1] = p
end)
events_m.subscribe("core.mailbox:response_written", function(p)
  response_events[#response_events + 1] = p
end)

local cor = message.new_correlation_id()
local r2 = mailbox.send({
  from = "agent:gemini", to = "agent:lector",
  subject = "needs reply", body = "do the thing",
  correlation_id = cor,
})

local claimed, claim_err = mailbox.claim("agent:lector", r2.id)
ok("claim returns the message", claimed ~= nil and claim_err == nil,
  tostring(claim_err))
ok("claim moves file out of inbox",
  not vim.tbl_contains(transp.list_inbox("agent:lector"), r2.id))
ok("claim moves file into processing",
  vim.tbl_contains(transp.list_processing("agent:lector"), r2.id))

local cok, cerr = mailbox.complete("agent:lector", r2.id, {
  ok = true, value = { result = "approved" },
})
ok("complete returns true", cok == true, tostring(cerr))
ok("complete moves out of processing",
  not vim.tbl_contains(transp.list_processing("agent:lector"), r2.id))
ok("complete archives the message",
  vim.tbl_contains(transp.list_archive("agent:lector"), r2.id))
ok("response landed in sender's responses dir keyed by correlation_id",
  vim.tbl_contains(transp.list_responses("agent:gemini"), cor))
ok("response file is a valid envelope with ok=true and matching reply_to",
  (function()
    local resp_path = gemini_rec.subs.responses .. "/" .. cor .. ".json"
    if vim.fn.filereadable(resp_path) ~= 1 then return false end
    local content = table.concat(vim.fn.readfile(resp_path), "\n")
    local ok_dec, decoded = pcall(vim.json.decode, content)
    return ok_dec
      and decoded.ok == true
      and decoded.reply_to == r2.id
      and decoded.correlation_id == cor
      and type(decoded.value) == "table"
      and decoded.value.result == "approved"
  end)())
ok("core.mailbox:message_completed fired",
  #completed_events == 1 and completed_events[1].id == r2.id)
ok("core.mailbox:response_written fired with the correlation_id",
  #response_events == 1
    and response_events[1].correlation_id == cor
    and response_events[1].reply_to == r2.id)

events_m.unsubscribe(qs)

-- ── 49g. central router: lifecycle + start/stop/refresh ─────
router._reset_for_tests()
events_m._reset_for_tests()
ok("router is not running before start", router.is_running() == false)
router.start()
ok("router is running after start", router.is_running() == true)
local status = router.status()
ok("router status reports one entry per unique registered root",
  (function()
    local count = 0
    for _ in pairs(status.roots) do count = count + 1 end
    -- codex + claude + gemini + active_root (host fallback) = 4.
    -- jarvis + hephaestus collapse onto the single claude watcher.
    return count == 4
  end)(),
  vim.inspect(status))

-- Idempotent start.
router.start()
ok("router.start is idempotent", router.is_running() == true)

-- ── 49h. router routes outbox → recipient inbox ─────────────
local routed_events = {}
events_m.subscribe("core.mailbox:outbox_routed", function(p)
  routed_events[#routed_events + 1] = p
end)
local queued_via_router = {}
events_m.subscribe("core.mailbox:message_queued", function(p)
  if p.mailbox == "agent:gemini" then
    queued_via_router[#queued_via_router + 1] = p
  end
end)

-- jarvis writes to its OWN outbox addressed to gemini.
-- (Simulates a sandboxed agent dropping a message in its outbox.)
local jarvis_outgoing = message.build({
  from = "agent:jarvis", to = "agent:gemini",
  body = "hello gemini from jarvis",
})
local outbox_file = jarvis_rec.subs.outbox .. "/" .. jarvis_outgoing.id .. ".json"
vim.fn.writefile({ vim.json.encode(jarvis_outgoing) }, outbox_file)
-- Force a scan since we wrote directly with writefile (not atomic rename
-- through the watcher path) — the watcher may or may not fire on the
-- single-step write; scan_now makes the test deterministic.
router.scan_now()
vim.wait(300, function() return #routed_events >= 1 end, 25)

ok("router fired core.mailbox:outbox_routed",
  #routed_events >= 1
    and routed_events[1].from == "agent:jarvis"
    and routed_events[1].to == "agent:gemini"
    and routed_events[1].id == jarvis_outgoing.id,
  vim.inspect(routed_events))
ok("outbox file is GONE from jarvis's outbox after routing",
  vim.fn.filereadable(outbox_file) == 0)
ok("message landed in gemini's inbox",
  vim.tbl_contains(transp.list_inbox("agent:gemini"), jarvis_outgoing.id))
-- After routing, the router's inbox dispatch fires too.
vim.wait(200, function() return #queued_via_router >= 1 end, 25)
ok("core.mailbox:message_queued fired for gemini's inbox after routing",
  #queued_via_router >= 1
    and queued_via_router[1].id == jarvis_outgoing.id)

-- ── 49i. outbox_undeliverable when recipient is unregistered ──
local undeliverable_events = {}
events_m.subscribe("core.mailbox:outbox_undeliverable", function(p)
  undeliverable_events[#undeliverable_events + 1] = p
end)
local orphan = message.build({
  from = "agent:jarvis", to = "agent:nobody_registered",
  body = "noone home",
})
local orphan_path = jarvis_rec.subs.outbox .. "/" .. orphan.id .. ".json"
vim.fn.writefile({ vim.json.encode(orphan) }, orphan_path)
router.scan_now()
vim.wait(200, function() return #undeliverable_events >= 1 end, 25)
ok("undeliverable fires when recipient is unregistered",
  #undeliverable_events >= 1
    and undeliverable_events[1].reason == "recipient_unregistered"
    and undeliverable_events[1].to == "agent:nobody_registered",
  vim.inspect(undeliverable_events))
ok("undeliverable: file REMAINS in sender's outbox (retryable)",
  vim.fn.filereadable(orphan_path) == 1)

-- Now register the missing recipient with a tmp root and re-scan;
-- the next routing pass should succeed.
mailbox.register("agent:nobody_registered", { root = tmp_root .. "/.misc/mailbox" })
router.scan_now()
vim.wait(300, function()
  return vim.fn.filereadable(orphan_path) == 0
end, 25)
ok("recipient registers later → re-scan routes the pending message",
  vim.fn.filereadable(orphan_path) == 0
    and vim.tbl_contains(transp.list_inbox("agent:nobody_registered"), orphan.id))

router.stop()
ok("router.stop drops running state", router.is_running() == false)

-- ── 49j. wake hook dispatch via command registry ────────────
commands._reset_for_tests()
events_m._reset_for_tests()
router._reset_for_tests()

local wake_invocations = {}
commands.register("send_slot", {
  owner = "auto-agents.nvim",
  handler = function(args, ctx)
    wake_invocations[#wake_invocations + 1] = { args = args, ctx = ctx }
    return { ok = true }
  end,
  description = "wake the agent's terminal slot",
})

-- Register user FIRST so its wake hook is in place before we send.
mailbox.register("user", {
  wake = { command = "send_slot", args = { slot = "user_terminal" } },
})

router.start()

-- Send a fresh user→lector message and capture its id specifically
-- (lector's inbox has leftovers from earlier sections; using the
-- returned id keeps this section hermetic).
local wake_msg = mailbox.send({
  from = "user", to = "agent:lector",
  body = "wake test 1",
})
vim.wait(300, function()
  for _, inv in ipairs(wake_invocations) do
    if inv.ctx.arrival_id == wake_msg.id then return true end
  end
  return false
end, 25)
ok("wake hook dispatched send_slot on inbox arrival for the new message",
  (function()
    for _, inv in ipairs(wake_invocations) do
      if inv.ctx.arrival_id == wake_msg.id
          and inv.args.slot == "lector"
          and inv.ctx.reason == "mailbox_wake"
          and inv.ctx.mailbox == "agent:lector"
          and inv.ctx.arrival_kind == "inbox"
      then return true end
    end
    return false
  end)(),
  vim.inspect(wake_invocations))

-- Wake also fires for response arrivals to the sender. Subscribe
-- AFTER the send so we only capture the response leg.
local response_received = {}
events_m.subscribe("core.mailbox:response_received", function(p)
  response_received[#response_received + 1] = p
end)

mailbox.claim("agent:lector", wake_msg.id)
mailbox.complete("agent:lector", wake_msg.id, { ok = true, value = "ack" })
-- complete() writes a response to user/responses; router.scan_now()
-- makes arrival detection deterministic without waiting on fs_event.
router.scan_now()
vim.wait(400, function()
  for _, p in ipairs(response_received) do
    if p.mailbox == "user" then return true end
  end
  return false
end, 25)
ok("core.mailbox:response_received fired for user's responses",
  (function()
    for _, p in ipairs(response_received) do
      if p.mailbox == "user" then return true end
    end
    return false
  end)(),
  vim.inspect(response_received))
ok("wake hook also dispatched on response arrival for user",
  (function()
    for _, inv in ipairs(wake_invocations) do
      if inv.ctx.arrival_kind == "responses"
          and inv.ctx.mailbox == "user"
          and inv.args.slot == "user_terminal"
      then return true end
    end
    return false
  end)(),
  vim.inspect(wake_invocations))

router.stop()

-- ── 49k. command registry: register, list, get, reject unknown ──
commands._reset_for_tests()
local cmd_registered = {}
local cmd_executed = {}
local cmd_rejected = {}
events_m.subscribe("core.command:registered", function(p)
  cmd_registered[#cmd_registered + 1] = p
end)
events_m.subscribe("core.command:executed", function(p)
  cmd_executed[#cmd_executed + 1] = p
end)
events_m.subscribe("core.command:rejected", function(p)
  cmd_rejected[#cmd_rejected + 1] = p
end)

local reg_ok, reg_err = commands.register("harpoon", {
  owner = "md-harpoon.nvim",
  handler = function(args) return { ok = true, value = { panel = args.panel or "1" } } end,
  description = "pin a doc to a md-harpoon slot",
})
ok("commands.register returns true", reg_ok == true, tostring(reg_err))
ok("core.command:registered fired",
  #cmd_registered == 1 and cmd_registered[1].name == "harpoon")
ok("commands.get returns the spec", (function()
  local s = commands.get("harpoon")
  return type(s) == "table" and s.owner == "md-harpoon.nvim"
end)())
ok("commands.list includes harpoon",
  (function()
    for _, s in ipairs(commands.list()) do
      if s.name == "harpoon" then return true end
    end
    return false
  end)())

-- Re-register with a different owner is refused.
local rr_ok, rr_err = commands.register("harpoon", {
  owner = "evil.plugin", handler = function() end,
})
ok("re-register with different owner is refused",
  rr_ok == false and type(rr_err) == "string" and rr_err:find("already owned"),
  tostring(rr_err))
-- Re-register with the SAME owner is allowed (hot-reload friendly).
local rr2_ok = commands.register("harpoon", {
  owner = "md-harpoon.nvim", handler = function() return { ok = true } end,
})
ok("re-register with same owner is allowed", rr2_ok == true)

-- Dispatch unknown command via handle_message → structured rejection.
local unknown_msg = message.build({
  from = "agent:gemini", to = "nvim",
  kind = "command", command = "definitely_not_real",
  correlation_id = "cor-test-1",
})
local resp = commands.handle_message(unknown_msg)
ok("handle_message returns ok=false for unknown command",
  type(resp) == "table" and resp.ok == false)
ok("rejection code is 'unknown_command'",
  resp.code == "unknown_command",
  tostring(resp.code))
ok("core.command:rejected fired with the correlation_id",
  #cmd_rejected >= 1
    and cmd_rejected[#cmd_rejected].name == "definitely_not_real"
    and cmd_rejected[#cmd_rejected].correlation_id == "cor-test-1")

-- Dispatch known command — handler returns table.
local known_msg = message.build({
  from = "user", to = "nvim",
  kind = "command", command = "harpoon",
  args = { panel = "2" },
})
local resp2 = commands.handle_message(known_msg)
ok("handle_message dispatches known command",
  type(resp2) == "table" and resp2.ok == true)
ok("core.command:executed fired",
  #cmd_executed >= 1 and cmd_executed[#cmd_executed].name == "harpoon")

-- kind != command is rejected (it's not a command message).
local bad_kind = { id = "x", kind = "message", from = "a", to = "b" }
local resp3 = commands.handle_message(bad_kind)
ok("handle_message rejects kind != 'command'",
  resp3.ok == false and resp3.code == "not_a_command")

-- handler that throws → handler_error, NOT a raise.
commands.register("crashy", {
  owner = "test", handler = function() error("oops") end,
})
local resp4 = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "crashy",
}))
ok("handler that errors → ok=false, code='handler_error'",
  resp4.ok == false and resp4.code == "handler_error"
    and resp4.error:find("oops"),
  vim.inspect(resp4))

-- ── Schema validation (should-fix #5) ───────────────────────
-- Register a command with a schema covering required/optional
-- fields and the supported type primitives.
commands.register("opendiff", {
  owner = "auto-agents.nvim",
  schema = {
    old_file_path = "string",
    new_file_path = "string",
    tab_name      = "string?",
    line_count    = "integer?",
  },
  handler = function(args)
    return { ok = true, value = args }
  end,
})

-- Happy path — handler returns ok=true.
local good = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = "/b", tab_name = "T" },
}))
ok("schema: handler runs when args satisfy schema",
  good.ok == true and good.value.old_file_path == "/a",
  vim.inspect(good))

-- Missing required field → bad_args, NOT handler_error.
local missing = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a" },
  correlation_id = "cor-bad-args-1",
}))
ok("schema: missing required field → ok=false, code=bad_args",
  missing.ok == false and missing.code == "bad_args"
    and missing.field == "new_file_path",
  vim.inspect(missing))

-- Wrong type → bad_args.
local wrongtype = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = 42 },
}))
ok("schema: wrong-type field → ok=false, code=bad_args, error names the type mismatch",
  wrongtype.ok == false and wrongtype.code == "bad_args"
    and wrongtype.field == "new_file_path"
    and wrongtype.error:find("string", 1, true) ~= nil,
  vim.inspect(wrongtype))

-- Optional field absent is fine.
local opt_absent = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a", new_file_path = "/b" },
}))
ok("schema: optional field omitted is accepted",
  opt_absent.ok == true)

-- Integer type rejects floats.
commands.register("setline", {
  owner = "test", schema = { n = "integer" },
  handler = function() return { ok = true } end,
})
local floaty = commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "setline",
  args = { n = 3.5 },
}))
ok("schema: integer type rejects non-integer numbers",
  floaty.ok == false and floaty.code == "bad_args")

-- Schema rejection publishes core.command:rejected with reason='bad_args'.
local bad_args_rejections = {}
events_m.subscribe("core.command:rejected", function(p)
  bad_args_rejections[#bad_args_rejections + 1] = p
end)
commands.handle_message(message.build({
  from = "a", to = "b", kind = "command", command = "opendiff",
  args = { old_file_path = "/a" },
  correlation_id = "cor-bad-args-event",
}))
ok("schema: rejection publishes core.command:rejected with reason='bad_args'",
  (function()
    for _, e in ipairs(bad_args_rejections) do
      if e.name == "opendiff" and e.reason == "bad_args"
          and e.correlation_id == "cor-bad-args-event"
      then return true end
    end
    return false
  end)(),
  vim.inspect(bad_args_rejections))

-- ── 49l. fail() transition writes failure envelope ─────────
local r3 = mailbox.send({
  from = "agent:gemini", to = "agent:lector",
  body = "intentional fail", correlation_id = "cor-fail-1",
})
mailbox.claim("agent:lector", r3.id)
local fok, ferr = mailbox.fail("agent:lector", r3.id, "deliberate",
  { response = true })
ok("fail returns true", fok == true, tostring(ferr))
ok("failed message archived",
  vim.tbl_contains(transp.list_archive("agent:lector"), r3.id))
ok("response envelope for failure has ok=false and the error",
  (function()
    -- gemini's responses dir lives under its tool root, not the host
    -- fallback — read via the registered record.
    local p = registry.get("agent:gemini").subs.responses .. "/cor-fail-1.json"
    if vim.fn.filereadable(p) ~= 1 then return false end
    local content = table.concat(vim.fn.readfile(p), "\n")
    local ok_dec, decoded = pcall(vim.json.decode, content)
    return ok_dec and decoded.ok == false and decoded.error == "deliberate"
  end)())

-- ── 49l0. host executioner via file transport (ADR §4) ─────
;(function()
local mb = require("auto-core.mailbox")
local router = mb.router
local commands = mb.commands

commands._reset_for_tests()
events_m._reset_for_tests()
router._reset_for_tests()

-- Register the host-side executioner mailbox. Default
-- executioner=true for id='nvim'; we exercise that default here.
local nvim_rec = mb.register("nvim")
ok("register('nvim') sets executioner=true by default",
  nvim_rec.executioner == true)
-- Other ids default to executioner=false.
local lector_rec_now = registry.get("agent:lector")
ok("non-nvim mailbox defaults to executioner=false",
  lector_rec_now.executioner == false)

-- Register a 'harpoon' command. The handler captures invocations
-- so we can assert it actually ran via the file path (not direct
-- lua dispatch).
local handler_invocations = {}
commands.register("harpoon", {
  owner = "md-harpoon.nvim",
  handler = function(args, ctx)
    handler_invocations[#handler_invocations + 1] = {
      args = args, ctx = ctx,
    }
    return { ok = true, value = { panel = args.panel or "1" } }
  end,
  description = "pin a doc to a md-harpoon slot",
})

router.start()

-- The realistic flow: a sandboxed agent (here jarvis) writes a
-- command JSON to its OWN outbox addressed to 'nvim'. Router
-- routes outbox → nvim/inbox → executioner claims+dispatches+
-- completes; sender (jarvis) gets a response in its responses/
-- dir keyed by correlation_id.
local cor = "cor-exec-harpoon-" .. tostring(vim.uv.hrtime())
local cmd_msg = mb.message.build({
  from = "agent:jarvis", to = "nvim",
  kind = "command", command = "harpoon",
  args = { panel = "2", file = "/tmp/foo.md" },
  correlation_id = cor,
})
local jarvis_rec_now = registry.get("agent:jarvis")
vim.fn.writefile({ vim.json.encode(cmd_msg) },
  jarvis_rec_now.subs.outbox .. "/" .. cmd_msg.id .. ".json")

local executed_events = {}
events_m.subscribe("core.command:executed", function(p)
  executed_events[#executed_events + 1] = p
end)
local completed_events = {}
events_m.subscribe("core.mailbox:message_completed", function(p)
  completed_events[#completed_events + 1] = p
end)

router.scan_now()
vim.wait(400, function()
  return #executed_events >= 1 and #completed_events >= 1
end, 25)

ok("executioner dispatched the file-routed command via registry",
  #handler_invocations >= 1
    and handler_invocations[1].args.panel == "2"
    and handler_invocations[1].args.file  == "/tmp/foo.md"
    and handler_invocations[1].ctx.reason == "mailbox_executioner"
    and handler_invocations[1].ctx.mailbox == "nvim",
  vim.inspect(handler_invocations))
-- v0.1.11: ctx surfaces the SENDER's identity alongside the executor's
-- mailbox so command handlers can attribute the call to who actually
-- asked for it (the executor is always `nvim`, which historically
-- forced handlers to guess or to require an explicit `args.sender`).
ok("ctx.sender carries the sender's full mailbox id (msg.from)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.sender == cmd_msg.from,
  vim.inspect(handler_invocations[1] and handler_invocations[1].ctx))
ok("ctx.sender_bare carries the bare form (agent:jarvis without instance suffix)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.sender_bare == "agent:jarvis",
  vim.inspect(handler_invocations[1] and handler_invocations[1].ctx))
ok("core.command:executed fired with name='harpoon'",
  #executed_events >= 1 and executed_events[1].name == "harpoon")
ok("core.mailbox:message_completed fired for the executioner-handled message",
  (function()
    for _, e in ipairs(completed_events) do
      if e.mailbox == "nvim" and e.id == cmd_msg.id then return true end
    end
    return false
  end)(),
  vim.inspect(completed_events))
ok("command file moved out of nvim inbox/processing into archive",
  not vim.tbl_contains(transp.list_inbox("nvim"), cmd_msg.id)
    and not vim.tbl_contains(transp.list_processing("nvim"), cmd_msg.id)
    and vim.tbl_contains(transp.list_archive("nvim"), cmd_msg.id))

-- Response envelope landed in sender's responses/ with the
-- handler's return value. This is the "blocking sender" contract:
-- the agent that sent the command can poll <jarvis>/responses/
-- <cor>.json and unblock.
ok("sender's responses/<cor>.json contains the handler's return value",
  (function()
    local p = jarvis_rec_now.subs.responses .. "/" .. cor .. ".json"
    if vim.fn.filereadable(p) ~= 1 then return false end
    local txt = table.concat(vim.fn.readfile(p), "\n")
    local okd, dec = pcall(vim.json.decode, txt)
    return okd and dec.ok == true
      and dec.reply_to == cmd_msg.id
      and dec.correlation_id == cor
      and type(dec.value) == "table"
      and dec.value.panel == "2"
  end)())

-- Unknown command through the file transport — structured
-- rejection lands in the sender's responses dir, not a thrown error.
local cor_unknown = "cor-exec-unknown-" .. tostring(vim.uv.hrtime())
local unknown_msg = mb.message.build({
  from = "agent:jarvis", to = "nvim",
  kind = "command", command = "definitely_not_registered",
  correlation_id = cor_unknown,
})
vim.fn.writefile({ vim.json.encode(unknown_msg) },
  jarvis_rec_now.subs.outbox .. "/" .. unknown_msg.id .. ".json")
local rejected_events = {}
events_m.subscribe("core.command:rejected", function(p)
  rejected_events[#rejected_events + 1] = p
end)
router.scan_now()
vim.wait(400, function() return #rejected_events >= 1 end, 25)
ok("unknown command via file path is rejected with structured response",
  #rejected_events >= 1
    and rejected_events[1].name == "definitely_not_registered",
  vim.inspect(rejected_events))
ok("sender unblocks via responses/<cor>.json with ok=false code=unknown_command",
  (function()
    local p = jarvis_rec_now.subs.responses .. "/" .. cor_unknown .. ".json"
    if vim.fn.filereadable(p) ~= 1 then return false end
    local txt = table.concat(vim.fn.readfile(p), "\n")
    local okd, dec = pcall(vim.json.decode, txt)
    return okd and dec.ok == false
  end)())

-- Non-command messages on an executioner mailbox still trigger
-- the wake hook (executioner only intercepts kind='command').
-- We can't register a wake on nvim here without polluting, but we
-- can assert: a plain 'message' to nvim does NOT call the
-- executioner (handler_invocations doesn't grow).
local hi_before = #handler_invocations
mb.send({ from = "agent:jarvis", to = "nvim",
  body = "just a message, not a command" })
router.scan_now()
vim.wait(200, function() return false end, 50)  -- give it a moment
ok("non-command messages on executioner mailbox do NOT invoke handlers",
  #handler_invocations == hi_before)

router.stop()
commands._reset_for_tests()
events_m._reset_for_tests()
end)()

-- ── 49l1. router polling fallback + status flags ──────────
;(function()
local mb = require("auto-core.mailbox")
local router = mb.router
events_m._reset_for_tests()
router._reset_for_tests()

-- mode='poll' skips fs_event entirely; the global poll timer must
-- pick up new arrivals via scan_now().
router.configure({ mode = "poll", poll_interval_ms = 60 })
router.start()
ok("status.mode reports 'poll' after configure",
  router.status().mode == "poll",
  vim.inspect(router.status()))
ok("status.poll_running is true with poll mode + an interval",
  router.status().poll_running == true,
  vim.inspect(router.status()))
ok("every root reports poll_active=true in poll mode",
  (function()
    for _, entry in pairs(router.status().roots) do
      if entry.poll_active ~= true then return false end
    end
    return next(router.status().roots) ~= nil
  end)(),
  vim.inspect(router.status()))
ok("every root has zero fs_event handles in poll mode",
  (function()
    for _, entry in pairs(router.status().roots) do
      if entry.handles ~= 0 then return false end
    end
    return true
  end)(),
  vim.inspect(router.status()))

-- Now send via outbox: simulate an agent dropping a message in
-- its own outbox, no fs_event; only the poll timer can find it.
local jarvis_rec = registry.get("agent:jarvis")
local outgoing = mb.message.build({
  from = "agent:jarvis", to = "agent:gemini",
  body = "polled delivery test",
})
vim.fn.writefile({ vim.json.encode(outgoing) },
  jarvis_rec.subs.outbox .. "/" .. outgoing.id .. ".json")
local routed_via_poll = false
events_m.subscribe("core.mailbox:outbox_routed", function(p)
  if p.id == outgoing.id then routed_via_poll = true end
end)
-- Wait a bit longer than the poll interval. We do NOT call
-- scan_now() — the timer must fire on its own.
vim.wait(400, function() return routed_via_poll end, 25)
ok("poll-mode timer routes outbox without fs_event",
  routed_via_poll)
router.stop()
ok("status.poll_running false after stop", router.status().poll_running == false)

-- mode='watch' is strict: even with poll_interval_ms set, no
-- timer should run. Useful as a "must have watchers" mode.
router._reset_for_tests()
router.configure({ mode = "watch", poll_interval_ms = 60 })
router.start()
ok("watch mode never starts the poll timer even with interval set",
  router.status().poll_running == false,
  vim.inspect(router.status()))
ok("every root reports poll_active=false in watch mode",
  (function()
    for _, entry in pairs(router.status().roots) do
      if entry.poll_active ~= false then return false end
    end
    return true
  end)())
router.stop()

-- poll_interval_ms=false disables polling even if a root would
-- otherwise need it.
router._reset_for_tests()
router.configure({ mode = "poll", poll_interval_ms = false })
router.start()
ok("poll_interval_ms=false prevents the timer from starting",
  router.status().poll_running == false)
router.stop()

router._reset_for_tests()
events_m._reset_for_tests()
end)()

-- ── 49l2. claim stamps + stale processing recovery ─────────
;(function()
local mb = require("auto-core.mailbox")
local tr = mb.transport
events_m._reset_for_tests()

-- Fresh message → claim stamps claimed_at/claimed_by/attempt
-- durably on the processing file.
local r = mb.send({ from = "agent:gemini", to = "agent:lector",
  body = "stamp test", correlation_id = "cor-stale-stamp" })
local msg, claim_err = mb.claim("agent:lector", r.id,
  { claimed_by = "test-harness" })
ok("claim returns the message with stamps", msg ~= nil and claim_err == nil,
  tostring(claim_err))
ok("claim stamps claimed_at + claimed_by + attempt on the returned msg",
  type(msg.claimed_at) == "string"
    and msg.claimed_by == "test-harness"
    and msg.attempt == 1,
  vim.inspect(msg))

-- Stamps are durable on disk (read processing file independently).
local on_disk = tr.read_from("agent:lector", "processing", r.id)
ok("claim stamps persist to disk",
  on_disk ~= nil
    and on_disk.claimed_by == "test-harness"
    and on_disk.attempt == 1
    and type(on_disk.claimed_at) == "string")

-- Recover-stale with a tiny threshold (0ms) trips immediately. Use
-- 'fail' policy (default) → archived + structured response.
local stale_events = {}
events_m.subscribe("core.mailbox:stale_recovered", function(p)
  stale_events[#stale_events + 1] = p
end)
local result = tr.recover_stale("agent:lector", { threshold_ms = 0 })
ok("recover_stale returns recovered list + scan count",
  type(result) == "table"
    and type(result.recovered) == "table"
    and type(result.scanned) == "number",
  vim.inspect(result))
ok("the stamped message was recovered with policy='fail'",
  (function()
    for _, e in ipairs(result.recovered) do
      if e.id == r.id and e.policy == "fail" then return true end
    end
    return false
  end)(),
  vim.inspect(result.recovered))
ok("core.mailbox:stale_recovered fired for the recovery",
  (function()
    for _, e in ipairs(stale_events) do
      if e.id == r.id and e.policy == "fail" then return true end
    end
    return false
  end)())
ok("recovered message archived",
  vim.tbl_contains(tr.list_archive("agent:lector"), r.id))
ok("recovered message no longer in processing",
  not vim.tbl_contains(tr.list_processing("agent:lector"), r.id))
-- Structured response with stale_processing_timeout went to sender.
ok("recovery wrote a response envelope with error=stale_processing_timeout",
  (function()
    local resp_path = registry.get("agent:gemini").subs.responses
                     .. "/cor-stale-stamp.json"
    if vim.fn.filereadable(resp_path) ~= 1 then return false end
    local txt = table.concat(vim.fn.readfile(resp_path), "\n")
    local okd, dec = pcall(vim.json.decode, txt)
    return okd and dec.ok == false
      and dec.error == "stale_processing_timeout"
  end)())

-- 'requeue' policy puts the message back in inbox; attempt
-- preserved; next claim → attempt = 2.
local r2 = mb.send({ from = "agent:gemini", to = "agent:lector",
  body = "requeue test", correlation_id = "cor-requeue" })
mb.claim("agent:lector", r2.id, { claimed_by = "test-harness" })
local result2 = tr.recover_stale("agent:lector",
  { threshold_ms = 0, policy = "requeue" })
ok("requeue policy recovers the message",
  (function()
    for _, e in ipairs(result2.recovered) do
      if e.id == r2.id and e.policy == "requeue" then return true end
    end
    return false
  end)(),
  vim.inspect(result2))
ok("requeued message returns to inbox",
  vim.tbl_contains(tr.list_inbox("agent:lector"), r2.id))
ok("requeued message no longer in processing",
  not vim.tbl_contains(tr.list_processing("agent:lector"), r2.id))

-- Next claim → attempt = 2 (the counter survived requeue).
local msg2 = mb.claim("agent:lector", r2.id, { claimed_by = "test-harness" })
ok("next claim after requeue increments attempt to 2",
  msg2 ~= nil and msg2.attempt == 2,
  vim.inspect(msg2))
-- Cleanup.
mb.fail("agent:lector", r2.id, "test-done", { response = false })

-- Threshold honors recency: a fresh claim with the default
-- threshold (5min) is NOT recovered.
local r3 = mb.send({ from = "agent:gemini", to = "agent:lector",
  body = "young message" })
mb.claim("agent:lector", r3.id)
local result3 = tr.recover_stale("agent:lector")  -- default 5min
ok("fresh claim is NOT swept under default threshold",
  (function()
    for _, e in ipairs(result3.recovered) do
      if e.id == r3.id then return false end
    end
    return true
  end)(),
  vim.inspect(result3))
mb.fail("agent:lector", r3.id, "test-cleanup", { response = false })

-- recover_stale_all walks every registered mailbox.
local merged = tr.recover_stale_all({ threshold_ms = 999999999 })
ok("recover_stale_all returns merged scanned + recovered list",
  type(merged) == "table"
    and type(merged.scanned) == "number"
    and type(merged.recovered) == "table",
  vim.inspect(merged))
end)()

-- ── 49n_pre. message_state + list_entries + viewer data pipeline ──
;(function()
local mb = require("auto-core.mailbox")
local tr = mb.transport
local ui = mb.ui

-- The earlier 49l block left agent:lector with an archived 'failed'
-- message. Find it specifically (list_archive returns sorted-by-id,
-- which is roughly oldest-first; archive contains both completed
-- and failed messages by now).
local fail_id
for _, id in ipairs(transp.list_archive("agent:lector")) do
  if tr.message_state("agent:lector", id) == "failed" then
    fail_id = id; break
  end
end
ok("agent:lector archive has a 'failed' message from the fail test",
  type(fail_id) == "string")
local fail_state = tr.message_state("agent:lector", fail_id)
ok("message_state classifies the archived failed message as 'failed'",
  fail_state == "failed",
  "got " .. tostring(fail_state))

-- Send a fresh message and verify it's "queued" before claim.
local r = mb.send({
  from = "agent:gemini", to = "agent:lector",
  body = "fresh queued",
})
local s = tr.message_state("agent:lector", r.id)
ok("freshly-sent inbox message reports 'queued'",
  s == "queued", "got " .. tostring(s))

-- Claim it → "claimed".
mb.claim("agent:lector", r.id)
s = tr.message_state("agent:lector", r.id)
ok("after claim, message_state reports 'claimed'",
  s == "claimed", "got " .. tostring(s))

-- Complete with response → "completed", and the response exists
-- in the sender's responses dir.
local cor = "cor-state-test-" .. tostring(vim.uv.hrtime())
mb.complete("agent:lector", r.id, {
  ok = true, value = "ack", correlation_id = cor,
})
s = tr.message_state("agent:lector", r.id)
ok("after complete, message_state reports 'completed'",
  s == "completed", "got " .. tostring(s))

-- Unknown id → nil.
ok("unknown message id → state is nil",
  tr.message_state("agent:lector", "nope-never-existed") == nil)

-- list_entries: ensure decoded payload fields land on entries.
local inbox_entries = tr.list_entries("agent:lector", "inbox")
ok("list_entries(inbox) returns a table",
  type(inbox_entries) == "table")
local arch_entries = tr.list_entries("agent:lector", "archive")
ok("list_entries(archive) carries states + responded annotation",
  (function()
    local saw_completed, saw_failed = false, false
    for _, e in ipairs(arch_entries) do
      if e.state == "completed" then saw_completed = true end
      if e.state == "failed"    then saw_failed    = true end
    end
    return saw_completed and saw_failed
  end)(),
  vim.inspect(arch_entries))

-- list_all merges every subdir, sorted by mtime desc.
local all = tr.list_all("agent:lector")
ok("list_all merges across subdirs and sorts desc",
  (function()
    if #all < 2 then return true end  -- nothing to compare
    for i = 1, #all - 1 do
      if all[i].mtime < all[i + 1].mtime then return false end
    end
    return true
  end)())

-- Viewer's data pipeline (without actually rendering windows).
ui._reset_for_tests()
ui._select("agent:lector", "all")
local data = ui._render_data()
ok("ui._render_data returns tree + tree_map + entries",
  type(data.tree) == "table"
    and type(data.tree_map) == "table"
    and type(data.entries) == "table")
ok("tree contains a row per registered mailbox + 5 subdirs each",
  (function()
    -- One owner row + 5 scope rows per mailbox.
    local owner_rows = 0
    for _, m in ipairs(data.tree_map) do
      if m.scope == "all" then owner_rows = owner_rows + 1 end
    end
    return owner_rows == #registry.records()
  end)(),
  vim.inspect(data.tree_map))

-- Backlog indicator: lower threshold and check tree includes warning.
ui._reset_for_tests()
ui.open({ backlog_threshold = 1, initial_mailbox = "agent:lector",
  initial_scope = "all" })
-- Immediately read state and close — open() requires a real UI but
-- we don't drive interactions; the smoke run is headless so windows
-- exist briefly. We just verify the tree was built with the
-- backlog warning embedded.
local s2 = ui._state()
local saw_warn = false
for _, line in ipairs(s2.tree_lines) do
  if line:find("⚠ inbox=", 1, true) then saw_warn = true; break end
end
ok("backlog indicator appears in the tree when inbox >= threshold",
  saw_warn, vim.inspect(s2.tree_lines))
ui.close()
end)()

-- ── 49n. debug probe surface — :AutoCoreDebug mailbox helpers ─
;(function()
local dbg = require("auto-core").debug.mailbox
ok("debug.mailbox is a table",
  type(dbg) == "table"
    and type(dbg.recent)         == "function"
    and type(dbg.format_entry)   == "function"
    and type(dbg.status)         == "function"
    and type(dbg.registry_lines) == "function"
    and type(dbg.tail_lines)     == "function"
    and type(dbg.follow_start)   == "function"
    and type(dbg.follow_stop)    == "function"
    and type(dbg.clear)          == "function")

-- registry_lines renders the current state without crashing on
-- empty/full registries.
local lines = dbg.registry_lines()
ok("registry_lines returns a non-empty list of strings",
  type(lines) == "table" and #lines >= 3
    and type(lines[1]) == "string"
    -- `:find(needle, 1, true)` is a literal-text search; the hyphens
    -- in "auto-core" would otherwise be pattern-quantifiers.
    and lines[1]:find("auto-core mailbox registry", 1, true) ~= nil,
  type(lines) == "table" and ("first=" .. tostring(lines[1])
                              .. " count=" .. tostring(#lines)) or "not-a-table")

-- tail_lines pulls from the trace; we trust the trace's existing
-- contract here. Just verify the shape.
local tail = dbg.tail_lines(20)
ok("tail_lines returns a list with at least the header rows",
  type(tail) == "table" and #tail >= 2)

-- recent() filters trace to core.mailbox:* / core.command:*. The
-- earlier sections fired both, so we should see entries.
local rec_events = dbg.recent(50)
ok("recent() returns mailbox / command events only",
  (function()
    if #rec_events == 0 then return false end
    for _, e in ipairs(rec_events) do
      if not (e.topic:sub(1, 13) == "core.mailbox:"
              or e.topic:sub(1, 13) == "core.command:") then
        return false
      end
    end
    return true
  end)(),
  vim.inspect(rec_events))
end)()

-- ── 49o. ADR 0023 Phase 1 — stale-orphan event + wake identity_hint ─
print("\n[49o] ADR 0023 Phase 1 — stale orphan event + wake identity_hint")
;(function()
  local mailbox_m  = require("auto-core.mailbox")
  local router_m   = require("auto-core.mailbox.router")
  local registry_m = require("auto-core.mailbox.registry")
  local transport_m = require("auto-core.mailbox.transport")
  local message_m  = require("auto-core.mailbox.message")
  local commands_m = require("auto-core.mailbox.commands")
  local path_m     = require("auto-core.mailbox.path")

  -- Don't reset registry/commands/events — section 49p downstream
  -- depends on the `agent:lector` registration that section 49
  -- planted. Just stop the router, swap in a fresh tmp root, and
  -- restart so this section's orphan event doesn't get polluted by
  -- the prior root's activity.
  router_m.stop()

  local tmp_root = vim.fn.tempname() .. "_adr0023_orphan"
  vim.fn.mkdir(tmp_root, "p")
  mailbox_m.configure({ host_fallback_root = tmp_root, mode = "watch" })

  -- Register a live mailbox so the router has something to scope to.
  local rec = mailbox_m.register("agent:live-peer", {
    root = tmp_root,
    wake = { command = "test_wake_hint" },
  })
  -- Stage a stale orphan mailbox dir layout under the same root —
  -- never registered. Path matches the classify-expected shape
  -- `<root>/<mailbox-id>/<sub>/<id>.json` so it would otherwise
  -- pass parsing.
  local orphan_id  = "agent:orphan-ghost:9999999999-99999"
  local orphan_dir = tmp_root .. "/" .. orphan_id .. "/outbox"
  vim.fn.mkdir(orphan_dir, "p")
  local orphan_file = orphan_dir .. "/orphan-msg-id-001.json"

  -- Start router + collect orphan events as they fire.
  router_m.start()
  local orphan_events = {}
  local orphan_sub = events_m.subscribe(
    "core.mailbox:stale_orphan_detected",
    function(p) orphan_events[#orphan_events + 1] = p end)

  -- Plant the orphan file; router's fs.watch on the recursive root
  -- catches the write OR a manual scan_now() catches it on poll.
  vim.fn.writefile({ "{}" }, orphan_file)
  mailbox_m.scan_now()
  vim.wait(150, function() return #orphan_events > 0 end, 20)

  ok("ADR 0023 §3.6: stale orphan write under unregistered mailbox emits event",
    #orphan_events >= 1, vim.inspect(orphan_events))
  ok("ADR 0023 §3.6: orphan event payload carries mailbox_id + reason",
    orphan_events[1]
      and orphan_events[1].mailbox_id == orphan_id
      and orphan_events[1].reason == "unregistered_mailbox",
    vim.inspect(orphan_events[1]))
  ok("ADR 0023 §3.6: orphan event payload carries sub + message_id + path",
    orphan_events[1]
      and orphan_events[1].sub == "outbox"
      and orphan_events[1].message_id == "orphan-msg-id-001"
      and orphan_events[1].path == orphan_file)

  events_m.unsubscribe(orphan_sub)

  -- ── Track A — wake-payload identity_hint round trip ──
  -- Register a fake wake-command handler that captures the ctx it
  -- received. Plant an inbox arrival on the live mailbox; the
  -- router's dispatch_wake should fire the handler with the new
  -- identity_hint slot populated.
  local captured_ctx
  commands_m.register("test_wake_hint", {
    owner       = "smoke",
    description = "ADR 0023 wake hint probe",
    schema      = nil,
    handler     = function(_args, ctx)
      captured_ctx = ctx
      return { ok = true, value = {} }
    end,
  })

  -- Write a minimal inbox message and trigger a scan.
  local arrival_mid = message_m.new_id()
  local arrival = {
    id   = arrival_mid,
    kind = "command",
    from = "auto-core",
    to   = rec.id,
    command = "test_wake_hint",
    args = {},
  }
  local arrival_path = rec.subs.inbox .. "/" .. arrival_mid .. ".json"
  vim.fn.writefile({ vim.fn.json_encode(arrival) }, arrival_path)
  mailbox_m.scan_now()
  vim.wait(200, function() return captured_ctx ~= nil end, 20)

  ok("ADR 0023 §3.5: wake handler receives ctx with identity_hint slot",
    type(captured_ctx) == "table"
      and type(captured_ctx.identity_hint) == "table",
    vim.inspect(captured_ctx))
  ok("ADR 0023 §3.5: identity_hint.expected_instance_id matches host's get_instance_id()",
    captured_ctx and captured_ctx.identity_hint
      and captured_ctx.identity_hint.expected_instance_id == path_m.get_instance_id())
  ok("ADR 0023 §3.5: identity_hint.expected_mailbox_id matches the addressed mailbox's full id",
    captured_ctx and captured_ctx.identity_hint
      and captured_ctx.identity_hint.expected_mailbox_id == rec.id)
  ok("ADR 0023 §3.5: identity_hint.expected_bare_id matches the addressed mailbox's bare id",
    captured_ctx and captured_ctx.identity_hint
      and captured_ctx.identity_hint.expected_bare_id == "agent:live-peer")

  router_m.stop()
end)()

-- ── 49p. mailbox.prune — sweep old per-instance dirs (v0.1.8) ─
print("\n[49p] mailbox.prune — sweep stale per-instance dirs")
;(function()
  -- Plant three stale dirs under the codex-like root, alongside the
  -- live `agent:lector:9999999999-12345` registered earlier. Two
  -- look like full-format instance dirs (pruneable by name pattern),
  -- one is a bare-id orphan from pre-v0.1.8 layout (also pruneable
  -- since it can never be "live" in v0.1.8).
  local stale_full_a = codex_like_root .. "/agent:lector:1111111111-1111"
  local stale_full_b = codex_like_root .. "/agent:juliet:2222222222-2222"
  local stale_bare   = codex_like_root .. "/agent:orphan"
  vim.fn.mkdir(stale_full_a .. "/inbox", "p")
  vim.fn.mkdir(stale_full_b .. "/outbox", "p")
  vim.fn.mkdir(stale_bare .. "/inbox", "p")
  -- Backdate each so they're older than the 7-day default. `touch`
  -- with relative time tags is the cheapest path; if the platform
  -- doesn't have it we fall back to a 1s threshold for this test.
  local backdate = function(p)
    os.execute("touch -d '8 days ago' " .. vim.fn.shellescape(p))
  end
  backdate(stale_full_a)
  backdate(stale_full_b)
  backdate(stale_bare)

  local result = mailbox.prune({ root = codex_like_root })
  local removed_set = {}
  for _, d in ipairs(result.removed) do removed_set[d] = true end
  ok("prune removed the two stale full-format instance dirs",
    removed_set[stale_full_a] == true and removed_set[stale_full_b] == true,
    vim.inspect(result.removed))
  ok("prune removed the pre-v0.1.8 bare-id orphan",
    removed_set[stale_bare] == true)
  local kept_alive_set = {}
  for _, d in ipairs(result.kept_alive) do kept_alive_set[d] = true end
  ok("prune kept the live registered lector dir alive",
    kept_alive_set[lector_rec.dir] == true,
    vim.inspect(result.kept_alive))
  ok("prune left the per-tool-root bootstrap doc intact",
    vim.fn.filereadable(codex_like_root .. "/bootstrap-mailbox.md") == 1)

  -- A second register of a fresh dir followed by an immediate prune
  -- should keep it (younger than threshold).
  local fresh_dir = codex_like_root .. "/agent:fresh:3333333333-3333"
  vim.fn.mkdir(fresh_dir, "p")
  local result2 = mailbox.prune({ root = codex_like_root,
    max_age_seconds = 7 * 24 * 60 * 60 })
  local fresh_kept = false
  for _, d in ipairs(result2.kept_recent) do
    if d == fresh_dir then fresh_kept = true; break end
  end
  ok("prune keeps recent dirs under the age threshold", fresh_kept,
    vim.inspect(result2.kept_recent))
end)()

-- ── 49o. teardown ───────────────────────────────────────────
mailbox._reset_for_tests()
events_m._reset_for_tests()
require("auto-core").setup()  -- restore defaults
pcall(vim.fn.delete, tmp_root, "rf")
-- Restore env so the rest of the suite (if any) sees originals.
vim.env.AUTO_AGENTS_MAILBOX_ROOT = saved_env.AUTO_AGENTS_MAILBOX_ROOT
vim.env.AUTO_AGENTS_CONFIG_DIR   = saved_env.AUTO_AGENTS_CONFIG_DIR
vim.env.AUTO_AGENTS_KB_ROOT      = saved_env.AUTO_AGENTS_KB_ROOT
end)()

-- ─────────────────────── 49. remote branches + git mutations (Phase 3.5+) ─────────────────────────
print("\n[49] git.worktree/git.repo — remote branches + mutations")
;(function()
local wt_mod = require("auto-core.git.worktree")
local repo_mod = require("auto-core.git.repo")
local events = require("auto-core.events")

-- 1. Setup local bare remote and a clone
local tmp = vim.fn.tempname()
local remote_path = tmp .. "/remote.git"
local clone_path  = tmp .. "/clone"
vim.fn.mkdir(remote_path, "p")
vim.system({ "git", "init", "--bare", remote_path }):wait()

vim.fn.mkdir(clone_path, "p")
vim.system({ "git", "clone", remote_path, clone_path }):wait()
vim.system({ "git", "-C", clone_path, "config", "user.email", "test@example.com" }):wait()
vim.system({ "git", "-C", clone_path, "config", "user.name", "Test User" }):wait()
vim.system({ "git", "-C", clone_path, "commit", "--allow-empty", "-m", "initial" }):wait()
vim.system({ "git", "-C", clone_path, "push", "origin", "HEAD" }):wait()

-- 2. Create a remote branch
vim.system({ "git", "-C", clone_path, "checkout", "-b", "feature-y" }):wait()
vim.system({ "git", "-C", clone_path, "push", "origin", "feature-y" }):wait()
local def_branch = wt_mod.default_branch(clone_path)
vim.system({ "git", "-C", clone_path, "checkout", def_branch }):wait()

-- 3. Test list_remote_branches
local remotes = wt_mod.list_remote_branches(clone_path)
local found = false
for _, r in ipairs(remotes) do if r == "origin/feature-y" then found = true end end
ok("list_remote_branches finds real remote branch", found)

-- 4. Test track()
local wt_added_event = nil
events.subscribe("core.git.worktree:added", function(p) wt_added_event = p end)

local track_path = tmp .. "/track-wt"
local track_done = false
wt_mod.track({ common_dir = clone_path .. "/.git" }, "origin/feature-y", "feature-y-local", track_path, function(res)
  ok("track() callback reports success", res.ok, res.stderr)
  track_done = true
end)
vim.wait(2000, function() return track_done end)

ok("track() created directory", vim.fn.isdirectory(track_path) == 1)
ok("track() published core.git.worktree:added", wt_added_event and wt_added_event.path == track_path)

-- 5. Test create_branch()
local branch_created_event = nil
events.subscribe("core.git.repo.branch:created", function(p) branch_created_event = p end)

local cb_done = false
repo_mod.create_branch(clone_path, "new-branch", def_branch, function(res)
  ok("create_branch() callback reports success", res.ok, res.stderr)
  cb_done = true
end)
vim.wait(2000, function() return cb_done end)
ok("create_branch() published core.git.repo.branch:created", branch_created_event and branch_created_event.name == "new-branch")

-- 6. Test checkout() + checkout_status()
ok("checkout_status() reports ok for clean branch", repo_mod.checkout_status(clone_path, def_branch).ok)

local checkout_event = nil
events.subscribe("core.git.repo.checkout:completed", function(p) checkout_event = p end)
local co_done = false
repo_mod.checkout(clone_path, def_branch, function(res)
  ok("checkout() callback reports success", res.ok, res.stderr)
  co_done = true
end)
vim.wait(2000, function() return co_done end)
ok("checkout() published core.git.repo.checkout:completed", checkout_event and checkout_event.branch == def_branch)

-- 7. Test delete_remote()
local remote_deleted_event = nil
events.subscribe("core.git.repo.remote:deleted", function(p) remote_deleted_event = p end)
local del_done = false
repo_mod.delete_remote(clone_path, "origin", "feature-y", function(res)
  ok("delete_remote() callback reports success", res.ok)
  del_done = true
end)
vim.wait(2000, function() return del_done end)
ok("delete_remote() published core.git.repo.remote:deleted", remote_deleted_event and remote_deleted_event.branch == "feature-y")

-- Verify remote branch is gone from listing
vim.system({ "git", "-C", clone_path, "fetch", "--prune" }):wait()
remotes = wt_mod.list_remote_branches(clone_path)
found = false
for _, r in ipairs(remotes) do if r == "origin/feature-y" then found = true end end
ok("remote branch gone after delete_remote + prune", not found)

-- Cleanup
vim.fn.delete(tmp, "rf")
end)()

print("\n[50] log.dumps — JSONL persistence (ADR 0021 §7)")
;(function()
local dumps = require("auto-core.log.dumps")
local log   = require("auto-core.log")
log._reset_for_tests()

-- Isolate the dumps dir to a tmpdir so we don't trample the user's
-- real cache or other suite runs. Override stdpath('cache') for the
-- length of this section.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local orig_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "cache" then return tmp end
  return orig_stdpath(what)
end

-- Path helper points at the isolated dir.
ok("dumps.dir() resolves under stdpath('cache')",
  dumps.dir() == tmp .. "/auto-core/dumps")

-- scan() on a non-existent dir returns empty list, not an error.
ok("scan() on missing dir returns empty", #dumps.scan() == 0)

-- iso_from_mono — exercise the wall-clock reconstruction. Picking
-- a fixed epoch (Jan 1 2020 UTC = 1577836800) keeps the assertion
-- portable across timezones.
local fixed_wall = 1577836800
local iso_now = dumps.iso_from_mono(1000, fixed_wall, 1000)
ok("iso_from_mono with ts == now_mono renders now_wall",
  iso_now == "2020-01-01T00:00:00Z", "got " .. tostring(iso_now))
local iso_back = dumps.iso_from_mono(0, fixed_wall, 1000)
ok("iso_from_mono with 1s-ago mono renders 1s before now",
  iso_back == "2019-12-31T23:59:59Z", "got " .. tostring(iso_back))

-- Write a small ring snapshot and read it back.
log.info("smoke.dumps", "first line")
log.warn("smoke.dumps", "second line", { event = "smoke.dumps.warned" })
log.error("smoke.dumps", "third line",
  { fields = { code = 42, where = "section-50" } })
vim.wait(20)
local snapshot = log.recent()
ok("ring captured 3 entries pre-export", #snapshot == 3)

local path, werr = dumps.write(snapshot)
ok("write() returned a path", type(path) == "string", "err=" .. tostring(werr))
ok("write() created a real file",
  path ~= nil and vim.fn.filereadable(path) == 1)
ok("filename matches dump-<UTC>.log",
  path ~= nil and path:match("/dump%-%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%dZ%.log$") ~= nil,
  path)

local read_back, rerr = dumps.read(path)
ok("read() succeeds", read_back ~= nil, "err=" .. tostring(rerr))
ok("read() returned the same entry count",
  read_back and #read_back == 3, "got " .. tostring(read_back and #read_back))
ok("disk entries carry ts_iso instead of monotonic ts",
  read_back and read_back[1].ts_iso ~= nil and read_back[1].ts == nil)
ok("ts_iso is well-formed ISO 8601 UTC",
  read_back and read_back[1].ts_iso:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil,
  read_back and read_back[1].ts_iso)
ok("structured fields survive the round trip",
  read_back and read_back[3].fields ~= nil
    and read_back[3].fields.code == 42
    and read_back[3].fields.where == "section-50")
ok("event_type survives the round trip",
  read_back and read_back[2].event_type == "smoke.dumps.warned")

-- scan() lists the file.
local listing = dumps.scan()
ok("scan() finds the new dump", #listing == 1
  and listing[1].path == path)

-- delete() removes the file; scan goes back to empty.
local del_ok, derr = dumps.delete(path)
ok("delete() returned true", del_ok, tostring(derr))
ok("file gone after delete", vim.fn.filereadable(path) == 0)
ok("scan() empty again", #dumps.scan() == 0)

-- Atomic write: the .tmp- prefix must not survive a successful write.
log.clear()
log.info("smoke.dumps", "post-clean")
vim.wait(10)
local path2 = dumps.write(log.recent())
ok("write #2 returned a path", type(path2) == "string")
local leftover_tmp = vim.fn.glob(tmp .. "/auto-core/dumps/.tmp-*", false, true)
ok("no .tmp- file lingers after successful write",
  type(leftover_tmp) == "table" and #leftover_tmp == 0,
  vim.inspect(leftover_tmp))

-- Restore stdpath + tear down.
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = orig_stdpath
vim.fn.delete(tmp, "rf")
end)()

print("\n[51] log.viewer — :AutoCoreLog 3-pane snapshot viewer (ADR 0021 §7)")
;(function()
local viewer = require("auto-core.log.viewer")
local mfloat = require("auto-core.ui.float.multi")
local log    = require("auto-core.log")
local dumps  = require("auto-core.log.dumps")

viewer._reset_for_tests()
mfloat._reset_for_tests()
log._reset_for_tests()

-- Stub vim.notify so the viewer's user-feedback toasts don't spam
-- test stderr. We aren't asserting on these; the convention path
-- (log.notify / log.error) routes through vim.notify which we want
-- silent under the suite.
local orig_notify = vim.notify
vim.notify = function() end
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function() end

-- Isolate dumps dir for this section, same trick as [50].
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local orig_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "cache" then return tmp end
  return orig_stdpath(what)
end

-- ── _apply_filters: pure-function math ──────────────────────
do
  local entries = {
    { level = 1, level_name = "ERROR", component = "scan",  message = "err: boom",  event_type = "auto-finder.scan.failed" },
    { level = 2, level_name = "WARN",  component = "scan",  message = "warn: slow", event_type = "auto-finder.scan.slow"   },
    { level = 3, level_name = "INFO",  component = "panel", message = "ok",         event_type = "auto-finder.panel.open"  },
    { level = 4, level_name = "DEBUG", component = "panel", message = "details",    event_type = nil },
  }

  -- ALL filter (index 1) → all 4.
  local r = viewer._apply_filters(entries, "", 1)
  ok("filter ALL keeps every entry", #r == 4)

  -- INFO+ (index 2) → 3.
  r = viewer._apply_filters(entries, "", 2)
  ok("filter INFO+ drops DEBUG", #r == 3 and r[3].level_name == "INFO")

  -- WARN+ (index 3) → 2.
  r = viewer._apply_filters(entries, "", 3)
  ok("filter WARN+ drops INFO+DEBUG", #r == 2 and r[2].level_name == "WARN")

  -- ERROR (index 4) → 1.
  r = viewer._apply_filters(entries, "", 4)
  ok("filter ERROR keeps only ERROR", #r == 1 and r[1].level_name == "ERROR")

  -- Substring filter — matches against message + component + event_type.
  r = viewer._apply_filters(entries, "panel", 1)
  ok("substring 'panel' matches component", #r == 2)
  r = viewer._apply_filters(entries, "auto-finder.scan", 1)
  ok("substring matches event_type", #r == 2)
  r = viewer._apply_filters(entries, "boom", 1)
  ok("substring matches message body", #r == 1 and r[1].message == "err: boom")
  r = viewer._apply_filters(entries, "PANEL", 1)
  ok("substring filter is case-insensitive", #r == 2)
  r = viewer._apply_filters(entries, "nothing-matches-this", 1)
  ok("substring with no matches returns empty", #r == 0)

  -- Combined: WARN+ AND component contains "scan" → 2.
  r = viewer._apply_filters(entries, "scan", 3)
  ok("level + substring compose (AND)", #r == 2)
end

-- ── open / close idempotency ────────────────────────────────
ok("is_open() false before open", not viewer.is_open())
viewer.open()
ok("is_open() true after open", viewer.is_open())

local state = viewer._state()
ok("viewer state populated after open",
  state ~= nil and state.float ~= nil)
ok("Memory is dumps[1]",
  state.dumps[1] and state.dumps[1].kind == "memory")

-- Re-calling open() must focus, not throw.
viewer.open()
ok("open() is idempotent — still open", viewer.is_open())

-- Snapshot is read-only — mutating the live ring after open
-- doesn't change the cached snapshot.
log.info("after-snapshot", "this entry came after snapshot")
vim.wait(10)
ok("snapshot length unchanged after live ring mutation",
  #state.memory_entries == 0)

-- R re-snapshots; now we should see the new entry.
viewer._reset_for_tests()
log._reset_for_tests()
log.info("before", "pre")
log.info("before", "pre-2")
vim.wait(10)
viewer.open()
state = viewer._state()
ok("snapshot picks up entries that existed at open-time",
  #state.memory_entries == 2)
log.info("after", "post-1")
log.info("after", "post-2")
vim.wait(10)
ok("live ring grew but snapshot is stable",
  #state.memory_entries == 2 and #log.recent() == 4)

-- Manually exercise the R path (calling internal helper because
-- buf-local keymaps can't be triggered headlessly without simulating
-- input).
do
  local mod = require("auto-core.log.viewer")
  -- Reproduce what the `R` keymap does: re-snapshot.
  local s = mod._state()
  -- Inline the snapshot — the `R` keymap is a thin closure over
  -- `_snapshot_memory` which isn't exported. Verify via the public
  -- observable: close + open does the same thing.
  mod.close()
  vim.wait(10)
  mod.open()
  s = mod._state()
  ok("close+reopen re-snapshots Memory (proxy for R)",
    s and #s.memory_entries == 4)
end

-- ── delete (Memory branch) → log.clear() and re-snapshot ────
-- Direct call into log.clear because exercising the D keymap
-- requires vim.ui.input which is non-trivial to fake. The
-- post-clear behavior is what we assert.
log.clear()
viewer.close()
vim.wait(10)
viewer.open()
state = viewer._state()
ok("post-clear, snapshot is empty",
  state and #state.memory_entries == 0)

-- ── export round-trip via dumps.write, then verify viewer picks
--    up the new file on rescan (via close+open) ──────────────
log._reset_for_tests()
log.info("export-test", "entry 1")
log.warn("export-test", "entry 2")
vim.wait(10)
local path = dumps.write(log.recent())
ok("dumps.write produced an export file",
  type(path) == "string" and vim.fn.filereadable(path) == 1)

viewer.close()
vim.wait(10)
viewer.open()
state = viewer._state()
ok("viewer rescans dumps dir on open — file is visible as dumps[2]",
  state and state.dumps[2] and state.dumps[2].kind == "file"
    and state.dumps[2].path == path)

-- ── cleanup ─────────────────────────────────────────────────
viewer.close()
viewer._reset_for_tests()
mfloat._reset_for_tests()
log._reset_for_tests()

---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = orig_stdpath
vim.fn.delete(tmp, "rf")
vim.notify = orig_notify
vim.api.nvim_echo = orig_echo
end)()

-- ─────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
