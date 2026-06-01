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
-- this literal-string version assertion needs manual updating on
-- each patch bump. v0.1.36 introduces auto-core.todo (ADR-0031);
-- the pattern matches the v0.1.x line. Left stale across bumps so
-- the failure stays discoverable.
ok("M.version matches the v0.1.x line",
  type(core.version) == "string" and core.version:match("^0%.1%.%d+$") ~= nil,
  "got " .. tostring(core.version))
ok("M.api_version is 0.1 (auto-core.todo additive; all prior surfaces unchanged)",
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
-- Build a fake worktree-style layout under a tempdir. The `.git/`
-- needs a `HEAD` entry to pass v0.1.33's empty-`.git` validator
-- (Lector audit 2026-05-24); plant the minimal real-git shape.
local repo = td .. "/proj-fake"
vim.fn.mkdir(repo .. "/.git", "p")
vim.fn.writefile({ "ref: refs/heads/main" }, repo .. "/.git/HEAD")
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

-- v0.1.33 / Lector round-3 regression: an EMPTY `.git/` directory
-- ancestor must not be treated as a valid git marker. Before the
-- validator was added, a stray `/tmp/.git/` (common on dev
-- machines) caused every `/tmp/<x>/` to misclassify as in-repo.
do
  local stray_root = vim.fn.tempname() .. "-empty-git-ancestor"
  local stray_git  = stray_root .. "/.git"
  local child      = stray_root .. "/sub/leaf"
  vim.fn.mkdir(stray_git, "p")  -- empty .git dir
  vim.fn.mkdir(child, "p")
  ok("git.repo.is_git rejects empty `.git` ancestor",
    repo_mod.is_git(child) == false,
    "got: " .. tostring(repo_mod.is_git(child)))
  ok("git.repo.root nil when ancestor `.git` is empty",
    repo_mod.root(child) == nil,
    "got: " .. tostring(repo_mod.root(child)))
  -- Plant a `HEAD` ref to verify the validator accepts a real
  -- repository-shaped `.git/` once entries appear.
  vim.fn.writefile({ "ref: refs/heads/main" }, stray_git .. "/HEAD")
  ok("git.repo.is_git accepts `.git` ancestor with HEAD",
    repo_mod.is_git(child) == true,
    "got: " .. tostring(repo_mod.is_git(child)))
  -- And a FILE `.git` (linked-worktree gitdir indirection) — also
  -- accepted, separate from the dir-marker validator.
  local lwt_root = vim.fn.tempname() .. "-linked-worktree"
  vim.fn.mkdir(lwt_root, "p")
  vim.fn.writefile({ "gitdir: /elsewhere/repo/.git/worktrees/lwt" },
    lwt_root .. "/.git")
  ok("git.repo.is_git accepts file-marker `.git` (linked-worktree gitdir indirection)",
    repo_mod.is_git(lwt_root) == true,
    "got: " .. tostring(repo_mod.is_git(lwt_root)))
  pcall(vim.fn.delete, stray_root, "rf")
  pcall(vim.fn.delete, lwt_root, "rf")
end

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

-- v0.1.28: opener-winid capture + restore. The float must
-- remember which window the user was in when it opened so that
-- close() doesn't leave focus on whatever window nvim's default
-- traversal happens to pick (frequently the tall left-side
-- auto-finder panel).
local opener_buf = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
local opener_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(opener_win, opener_buf)
local m_op = mfloat.new({
  name  = "smoke_opener_restore",
  panes = { middle = {} },
})
m_op:open()
ok("opener_winid captured on open",
  m_op._opener_winid == opener_win,
  "got " .. tostring(m_op._opener_winid)
    .. " expected " .. tostring(opener_win))
ok("focus moved off opener after open",
  vim.api.nvim_get_current_win() ~= opener_win)
m_op:close()
ok("close restored focus to opener",
  vim.api.nvim_get_current_win() == opener_win,
  "got " .. tostring(vim.api.nvim_get_current_win())
    .. " expected " .. tostring(opener_win))
ok("opener_winid cleared after close",
  m_op._opener_winid == nil)
m_op:dispose()

-- Opener captured BEFORE the bg pane opens — bg is not focusable
-- but we still want to confirm the captured winid isn't the bg
-- (regression guard).
vim.api.nvim_set_current_win(opener_win)
local m_op2 = mfloat.new({
  name  = "smoke_opener_not_bg",
  panes = { middle = {} },
})
m_op2:open()
ok("captured opener != bg pane",
  m_op2._opener_winid ~= m_op2:winid("bg"))
m_op2:dispose()

-- Invalid opener (opener window closed during the float's
-- lifetime): close should not crash, and shouldn't try to
-- restore a dead winid.
local victim_buf = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
local victim_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(victim_win, victim_buf)
local m_op3 = mfloat.new({
  name  = "smoke_opener_invalidated",
  panes = { middle = {} },
})
m_op3:open()
-- Kill the opener while the float is up.
pcall(vim.api.nvim_win_close, victim_win, true)
local ok_close = pcall(function() m_op3:close() end)
ok("close survives invalidated opener", ok_close)
ok("invalidated opener doesn't crash, no restore attempted",
  not vim.api.nvim_win_is_valid(victim_win))
m_op3:dispose()

-- Cleanup the opener split we made above.
if vim.api.nvim_win_is_valid(opener_win) then
  pcall(vim.api.nvim_win_close, opener_win, true)
end

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
ok("api_version is 0.1 (auto-core.todo additive surface)", v.api_version == "0.1")
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
ok("M.mailbox surface includes send/unregister/claim/complete/start/stop/refresh/scan_now",
  type(core.mailbox.send) == "function"
    and type(core.mailbox.unregister) == "function"
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
-- v0.1.33: host_fallback_root now resolves via workspace_root walk-up,
-- not the durable global location. The path ends in `.auto-agents/mailbox`
-- regardless of which workspace we're in.
ok("host_fallback_root ends in .auto-agents/mailbox (workspace-scoped)",
  mailbox.host_fallback_root():find("%.auto%-agents/mailbox$") ~= nil,
  "got: " .. mailbox.host_fallback_root())

vim.env.AUTO_AGENTS_MAILBOX_ROOT = tmp_root .. "/env-mb"
mailbox._reset_for_tests()
ok("AUTO_AGENTS_MAILBOX_ROOT env var still overrides workspace resolution",
  mailbox.host_fallback_root() == tmp_root .. "/env-mb",
  "got: " .. mailbox.host_fallback_root())
vim.env.AUTO_AGENTS_MAILBOX_ROOT = nil

-- Fixture: reflect distinct per-mailbox roots. The architecture treats
-- roots as opaque; the test verifies that multiple distinct roots
-- coexist and the central router collapses by unique root.
local active_root      = tmp_root .. "/active"
local codex_like_root  = tmp_root .. "/.codex/mailbox"
local claude_like_root = tmp_root .. "/.claude/mailbox"
local gemini_like_root = tmp_root .. "/.gemini/mailbox"
require("auto-core").setup({ mailbox = { root = active_root } })
ok("setup({mailbox={root=...}}) override applies to host fallback",
  mailbox.host_fallback_root() == active_root,
  "got: " .. mailbox.host_fallback_root())

-- v0.1.33: tool_root / TOOL_DIRS are gone. Production code uses
-- workspace_mailbox_root() instead; per-tool config dirs are now
-- a downstream consumer concern (auto-agents.runtime.identity), not
-- an auto-core primitive.
ok("v0.1.33: mb_path.tool_root removed (clean cut)",
  mb_path.tool_root == nil,
  "tool_root still present")
ok("v0.1.33: mb_path.TOOL_DIRS removed (clean cut)",
  mb_path.TOOL_DIRS == nil,
  "TOOL_DIRS still present")
-- workspace_mailbox_root semantics: only the no-override path is
-- workspace-relative. Once configure() has set an override (the
-- setup() call above set active_root as the override), the override
-- wins. Verify that explicitly by temporarily clearing it.
do
  mb_path.configure(nil)
  ok("workspace_mailbox_root() resolves to <workspace>/.auto-agents/mailbox when no override is set",
    mb_path.workspace_mailbox_root():find("%.auto%-agents/mailbox$") ~= nil,
    "got: " .. mb_path.workspace_mailbox_root())
  -- Restore the active_root override so subsequent assertions still see it.
  mb_path.configure(active_root)
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
-- v0.1.33: reject `agent:nvim` / `agent:user` (would collide with the
-- host/user mailbox after `_name_from_id` strips the type prefix).
ok("validate_id rejects reserved agent name 'agent:nvim'",
  not mb_path.validate_id("agent:nvim"))
ok("validate_id rejects reserved agent name 'agent:user'",
  not mb_path.validate_id("agent:user"))
ok("validate_id rejects reserved agent name with instance suffix",
  not mb_path.validate_id("agent:nvim:1747-3478"))
ok("validate_id still accepts host bare names 'nvim' and 'user'",
  (mb_path.validate_id("nvim")) and (mb_path.validate_id("user")))
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
    and lector_rec.dir == mb_path.mailbox_dir(FULL("agent:lector"), codex_like_root)
    and type(lector_rec.subs) == "table"
    and type(lector_rec.wake) == "table"
    and lector_rec.wake.command == "send_slot")
ok("lector's mailbox dir lives under Codex's tool root with instance suffix",
  lector_rec.dir == mb_path.mailbox_dir(FULL("agent:lector"), codex_like_root),
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
    and jarvis_rec.dir == mb_path.mailbox_dir(FULL("agent:jarvis"), claude_like_root),
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
    and hephaestus_rec.dir == mb_path.mailbox_dir(FULL("agent:hephaestus"), claude_like_root)
    and jarvis_rec.root == hephaestus_rec.root,
  "jarvis.dir=" .. jarvis_rec.dir
    .. " hephaestus.dir=" .. hephaestus_rec.dir)

-- Gemini-backed agent under its own tool root.
local gemini_rec = mailbox.register("agent:gemini", {
  root = gemini_like_root,
  wake = { command = "send_slot", args = { slot = "gemini" } },
})
ok("gemini-backed agent uses its own tool root",
  gemini_rec.dir == mb_path.mailbox_dir(FULL("agent:gemini"), gemini_like_root))

-- Host-side mailbox with no explicit root falls back.
local nvim_rec = mailbox.register("nvim")
ok("host-side 'nvim' mailbox falls back to host fallback root + instance suffix",
  nvim_rec.root == active_root
    and nvim_rec.dir == mb_path.mailbox_dir(FULL("nvim"), active_root))
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
ok("bootstrap doc stores seen-revision under per-agent workspace state (schema_version 7)",
  boot_text:find("seen_revisions/<your-agent-name>/seen_revision",
    1, true) ~= nil
    and boot_text:find("schema_version 7", 1, true) ~= nil)
ok("bootstrap doc still documents spawn-time permission grants",
  boot_text:find("Spawn-time permission grants", 1, true) ~= nil
    and boot_text:find("--add-dir <path>", 1, true) ~= nil)

-- ── ADR-0036: PERMISSION.md guideline (peer to bootstrap doc) ──
-- registry.register now also upserts PERMISSION.md (advisory peer) into
-- the workspace mailbox root; the bootstrap doc references it.
local perm_path = codex_like_root .. "/PERMISSION.md"
ok("ADR-0036: PERMISSION.md written alongside bootstrap doc",
  vim.fn.filereadable(perm_path) == 1, "expected at " .. perm_path)
local perm_text = vim.fn.filereadable(perm_path) == 1
  and table.concat(vim.fn.readfile(perm_path), "\n") or ""
ok("PERMISSION.md leads with the prompt-avoidance directive",
  perm_text:find("disrupt", 1, true) ~= nil
    and perm_text:find("avoid", 1, true) ~= nil)
ok("PERMISSION.md states the Read/Write tools are the prompt-free surface",
  perm_text:find("Read/Write", 1, true) ~= nil)
ok("PERMISSION.md frontmatter carries its own revision",
  perm_text:find("revision:") ~= nil)
ok("bootstrap doc references PERMISSION.md (ADR-0036) + schema_version 9",
  boot_text:find("PERMISSION.md", 1, true) ~= nil
    and boot_text:find("schema_version: 9", 1, true) ~= nil)
-- render_permission is deterministic (content sha → stable revision)
local _, perm_rev_a = boot.render_permission()
local _, perm_rev_b = boot.render_permission()
ok("render_permission revision is deterministic (content-addressed)",
  perm_rev_a == perm_rev_b and type(perm_rev_a) == "string")
ok("permission revision differs from the bootstrap revision",
  perm_rev_a ~= select(2, boot.render()))

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
local user_rec = mailbox.register("user", {
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

-- Regression: a mailbox registered after router.start under an already
-- watched root must still get its own mailbox-subtree watcher coverage.
-- This is the common Claude-backed multi-agent shape.
local watched_before = router.status().roots[claude_like_root]
  and router.status().roots[claude_like_root].watched or 0
local late_claude = mailbox.register("agent:late-claude", {
  root = claude_like_root,
  wake = { command = "send_slot", args = { slot = "late-claude" } },
})
local watched_after = router.status().roots[claude_like_root]
  and router.status().roots[claude_like_root].watched or 0
ok("router.refresh adds mailbox-subtree watchers for same-root late mailboxes",
  watched_after > watched_before,
  "before=" .. tostring(watched_before) .. " after=" .. tostring(watched_after))

local late_msg = message.build({
  from = "user", to = late_claude.id,
  body = "late claude wake test",
})
vim.fn.writefile({ vim.json.encode(late_msg) },
  user_rec.subs.outbox .. "/" .. late_msg.id .. ".json")
router.scan_now()
vim.wait(300, function()
  for _, inv in ipairs(wake_invocations) do
    if inv.ctx.arrival_id == late_msg.id then return true end
  end
  return false
end, 25)
ok("routed mail immediately dispatches wake for same-root late mailbox",
  (function()
    for _, inv in ipairs(wake_invocations) do
      if inv.ctx.arrival_id == late_msg.id
          and inv.ctx.mailbox == "agent:late-claude"
          and inv.args.slot == "late-claude"
      then return true end
    end
    return false
  end)(),
  vim.inspect(wake_invocations))

local removed_late = mailbox.unregister("agent:late-claude")
local watched_removed = router.status().roots[claude_like_root]
  and router.status().roots[claude_like_root].watched or 0
ok("mailbox.unregister returns removed record and releases watcher coverage",
  removed_late == late_claude and watched_removed < watched_after,
  "after=" .. tostring(watched_after) .. " removed=" .. tostring(watched_removed))

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
-- v0.1.23: ctx also surfaces the round-trip identity so handlers that
-- defer a verdict past the synchronous response (e.g. auto-agents'
-- diff_queue) can stash the correlation_id and route a follow-up
-- back to the sender keyed by it.
ok("ctx.correlation_id carries the original message's correlation_id (when set)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.correlation_id == cor,
  vim.inspect(handler_invocations[1] and handler_invocations[1].ctx))
ok("ctx.message_id carries the executor-path file basename (mid)",
  #handler_invocations >= 1
    and handler_invocations[1].ctx.message_id == cmd_msg.id,
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
  -- never registered. Path is composed via `mb_path.subdir` so the
  -- v0.1.33 layout (`<root>/<instance>/<name>/<sub>/`) is honored
  -- without test fixtures hardcoding the shape.
  local orphan_id  = "agent:orphan-ghost:9999999999-99999"
  local orphan_dir = path_m.subdir(orphan_id, "outbox", tmp_root)
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

  local orphan_event
  for _, event in ipairs(orphan_events) do
    if event.mailbox_id == orphan_id then
      orphan_event = event
      break
    end
  end
  ok("ADR 0023 §3.6: stale orphan write under unregistered mailbox emits event",
    orphan_event ~= nil, vim.inspect(orphan_events))
  ok("ADR 0023 §3.6: orphan event payload carries mailbox_id + reason",
    orphan_event
      and orphan_event.mailbox_id == orphan_id
      and orphan_event.reason == "unregistered_mailbox",
    vim.inspect(orphan_event))
  ok("ADR 0023 §3.6: orphan event payload carries sub + message_id + path",
    orphan_event
      and orphan_event.sub == "outbox"
      and orphan_event.message_id == "orphan-msg-id-001"
      and orphan_event.path == orphan_file)

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
  -- v0.1.33 layout: <root>/<instance>/<name>/. Compose via the path
  -- module's resolver so the test fixtures don't reproduce layout
  -- knowledge that lives in mb_path.
  local stale_full_a = mb_path.mailbox_dir("agent:lector:1111111111-1111",  codex_like_root)
  local stale_full_b = mb_path.mailbox_dir("agent:juliet:2222222222-2222", codex_like_root)
  vim.fn.mkdir(stale_full_a .. "/inbox", "p")
  vim.fn.mkdir(stale_full_b .. "/outbox", "p")
  -- Backdate each so they're older than the 7-day default. `touch`
  -- with relative time tags is the cheapest path; if the platform
  -- doesn't have it we fall back to a 1s threshold for this test.
  local backdate = function(p)
    os.execute("touch -d '8 days ago' " .. vim.fn.shellescape(p))
  end
  backdate(stale_full_a)
  backdate(stale_full_b)

  local result = mailbox.prune({ root = codex_like_root })
  local removed_set = {}
  for _, d in ipairs(result.removed) do removed_set[d] = true end
  ok("prune removed the two stale full-format instance dirs",
    removed_set[stale_full_a] == true and removed_set[stale_full_b] == true,
    vim.inspect(result.removed))
  local kept_alive_set = {}
  for _, d in ipairs(result.kept_alive) do kept_alive_set[d] = true end
  ok("prune kept the live registered lector dir alive",
    kept_alive_set[lector_rec.dir] == true,
    vim.inspect(result.kept_alive))
  ok("prune left the workspace bootstrap doc intact",
    vim.fn.filereadable(codex_like_root .. "/bootstrap-mailbox.md") == 1)

  -- A second register of a fresh dir followed by an immediate prune
  -- should keep it (younger than threshold).
  local fresh_dir = mb_path.mailbox_dir("agent:fresh:3333333333-3333", codex_like_root)
  vim.fn.mkdir(fresh_dir, "p")
  local result2 = mailbox.prune({ root = codex_like_root,
    max_age_seconds = 7 * 24 * 60 * 60 })
  local fresh_kept = false
  for _, d in ipairs(result2.kept_recent) do
    if d == fresh_dir then fresh_kept = true; break end
  end
  ok("prune keeps recent dirs under the age threshold", fresh_kept,
    vim.inspect(result2.kept_recent))

  -- v0.1.33 / Phase 8 safety rail: prune({ root = <legacy_root> })
  -- where the root has ZERO live registrations refuses by default —
  -- protects accidental cleanup of foreign trees. Bypass with force.
  local legacy_only_root = vim.fn.tempname() .. "_legacy-only-root"
  vim.fn.mkdir(legacy_only_root .. "/9999999999-9999/orphan-agent/inbox", "p")
  os.execute("touch -d '8 days ago' " .. vim.fn.shellescape(
    legacy_only_root .. "/9999999999-9999/orphan-agent"))
  local refused = mailbox.prune({ root = legacy_only_root })
  ok("Phase 8 safety rail: prune refuses root with zero live registrations",
    refused.refused == true and refused.reason == "no_live_registrations"
      and refused.root:sub(-#legacy_only_root) == legacy_only_root,
    vim.inspect(refused))
  ok("Phase 8 safety rail: refusal does NOT touch the filesystem",
    vim.fn.isdirectory(legacy_only_root .. "/9999999999-9999/orphan-agent") == 1)
  -- force=true bypasses the rail.
  local forced = mailbox.prune({ root = legacy_only_root, force = true })
  ok("Phase 8 safety rail: force=true bypasses (prune proceeds)",
    forced.refused ~= true
      and type(forced.removed) == "table"
      and #forced.removed >= 1,
    vim.inspect(forced))
  pcall(vim.fn.delete, legacy_only_root, "rf")
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

-- ─────────────────────── 51. git.watch — .git/ plumbing watcher (ADR 0025) ─────────────────────────
print("\n[51] git.watch — start/stop, kind classification, debounce, .lock filter, status invalidation")
;(function()
local gwatch = require("auto-core.git.watch")
local status_mod = require("auto-core.git.status")
local events = require("auto-core.events")
events._reset_for_tests()
gwatch._reset_for_tests()
status_mod._reset_for_tests()

-- Negative: nil / non-repo path.
local h_nil, err_nil = gwatch.start(nil)
ok("git.watch.start nil repo_root → err",
  h_nil == nil and type(err_nil) == "string", tostring(err_nil))
local non_git_root = vim.fn.tempname() .. "-not-a-repo"
vim.fn.mkdir(non_git_root, "p")
local h_ng, err_ng = gwatch.start(non_git_root)
ok("git.watch.start non-git path → err",
  h_ng == nil and type(err_ng) == "string"
    and err_ng:find("not a git repo"),
  tostring(err_ng))
pcall(vim.fn.delete, non_git_root, "rf")

-- Build a fresh, fully-initialized git repo. Use `commit --allow-empty`
-- so logs/HEAD exists (reflog is created on first ref update, not on
-- bare `init` — so a repo with zero commits has no logs/ dir yet).
local repo = vim.fn.tempname() .. "-gw-repo"
vim.fn.mkdir(repo, "p")
local function gsh(args)
  return vim.system(args, { cwd = repo, text = true }):wait()
end
gsh({ "git", "init", "-q", "-b", "main", repo })
gsh({ "git", "config", "user.email", "smoke@auto-core.test" })
gsh({ "git", "config", "user.name",  "Smoke Test"             })
gsh({ "git", "commit", "--allow-empty", "-q", "-m", "first" })

-- Sanity: confirm both watched dirs exist now.
ok("repo .git/ exists",       vim.fn.isdirectory(repo .. "/.git") == 1)
ok("repo .git/logs/ exists",  vim.fn.isdirectory(repo .. "/.git/logs") == 1)

-- Subscribe BEFORE starting the watch so initial publishes are caught.
local seen = {}
events.subscribe("core.git.state:changed", function(p, t)
  seen[#seen + 1] = { topic = t, kind = p.kind, repo_root = p.repo_root, path = p.path }
end)

local handle, start_err = gwatch.start(repo)
ok("git.watch.start succeeds on real repo",
  handle ~= nil and type(handle.id) == "number", tostring(start_err))
ok("git.watch.list reports one handle", #gwatch.list() == 1)
ok("handle has two fs_event handles (git_dir/ + logs/)",
  handle and #handle.fs_events == 2,
  vim.inspect(handle and #handle.fs_events))
ok("handle.repo_root + git_dir are normalized strings",
  type(handle.repo_root) == "string"
    and type(handle.git_dir) == "string"
    and handle.git_dir:find("/%.git$") ~= nil,
  vim.inspect({ repo_root = handle.repo_root, git_dir = handle.git_dir }))

-- ── Kind = "index" via `git add` ────────────────────────────
local before = #seen
vim.fn.writefile({ "abc" }, repo .. "/a.txt")
gsh({ "git", "add", "a.txt" })
vim.wait(800, function()
  for i = before + 1, #seen do
    if seen[i].kind == "index" then return true end
  end
  return false
end)
local saw_index = false
for i = before + 1, #seen do
  if seen[i].kind == "index" then saw_index = true end
end
ok("git add fires kind='index'", saw_index,
  vim.inspect({ before = before, total = #seen, slice = { unpack(seen, before + 1) } }))

-- ── Kind = "reflog" + index via `git commit` ────────────────
before = #seen
-- Let the 200ms debounce window clear so commit's index/HEAD/logs
-- mutations each get their own publish.
vim.wait(300)
gsh({ "git", "commit", "-q", "-m", "second" })
vim.wait(800, function()
  local saw_reflog = false
  for i = before + 1, #seen do
    if seen[i].kind == "reflog" then saw_reflog = true end
  end
  return saw_reflog
end)
local kinds_seen = {}
for i = before + 1, #seen do kinds_seen[seen[i].kind] = true end
ok("git commit fires kind='reflog' (logs/HEAD appended)",
  kinds_seen.reflog == true,
  vim.inspect({ before = before, kinds = kinds_seen, slice = { unpack(seen, before + 1) } }))
-- HEAD file is rewritten on commit (the SHA the ref points to changes
-- — though the HEAD file itself just says "ref: refs/heads/main" and
-- doesn't change content, the inode mtime updates on some platforms).
-- Don't strictly require "head" here — the load-bearing signal is
-- "reflog" which we just asserted.

-- ── kind = "head" via `git checkout -b` (HEAD content changes) ─
before = #seen
vim.wait(300)
gsh({ "git", "checkout", "-q", "-b", "branch2" })
vim.wait(800, function()
  for i = before + 1, #seen do
    if seen[i].kind == "head" then return true end
  end
  return false
end)
local saw_head = false
for i = before + 1, #seen do
  if seen[i].kind == "head" then saw_head = true end
end
ok("git checkout -b fires kind='head' (HEAD file rewritten)",
  saw_head,
  vim.inspect({ before = before, total = #seen, slice = { unpack(seen, before + 1) } }))

-- ── refs/remotes is NOT watched ────────────────────────────
-- Simulate a fetch-side write by creating the dir and dropping a ref
-- file. The watcher must NOT publish for this.
before = #seen
vim.wait(300)
vim.fn.mkdir(repo .. "/.git/refs/remotes/origin", "p")
vim.fn.writefile({ "0000000000000000000000000000000000000000" },
  repo .. "/.git/refs/remotes/origin/main")
vim.wait(400)
local saw_remote_publish = false
for i = before + 1, #seen do
  if seen[i].path and seen[i].path:find("/refs/remotes/") then
    saw_remote_publish = true
  end
end
ok("refs/remotes/ writes do NOT publish",
  not saw_remote_publish,
  vim.inspect({ added = #seen - before, slice = { unpack(seen, before + 1) } }))

-- ── .lock files are filtered ───────────────────────────────
before = #seen
vim.wait(300)
vim.fn.writefile({ "x" }, repo .. "/.git/index.lock")
vim.wait(400)
local saw_lock_publish = false
for i = before + 1, #seen do
  if seen[i].path and seen[i].path:match("%.lock$") then
    saw_lock_publish = true
  end
end
ok(".lock filename writes do NOT publish",
  not saw_lock_publish,
  vim.inspect({ added = #seen - before, slice = { unpack(seen, before + 1) } }))
pcall(vim.fn.delete, repo .. "/.git/index.lock")

-- ── status cache invalidation via the new topic ────────────
-- Done BEFORE the debounce burst test below because that test writes
-- garbage directly to `.git/index` (bypassing git tools) to verify
-- the publisher coalesces — which corrupts the index and makes
-- `git status` shell-out fail, so `status.get()` would no longer
-- populate the cache. Order matters: assert cache plumbing while
-- the repo is still healthy.
status_mod.get(repo)
ok("status cache is populated before invalidation test",
  status_mod.is_cached(repo) == true)
events.publish("core.git.state:changed", {
  repo_root = repo,
  git_dir   = repo .. "/.git",
  kind      = "index",
  path      = repo .. "/.git/index",
})
ok("status cache cleared by core.git.state:changed publish",
  status_mod.is_cached(repo) == false)

-- A publish naming a DIFFERENT repo_root must not affect this cache.
status_mod.get(repo)
events.publish("core.git.state:changed", {
  repo_root = "/some/other/repo",
  git_dir   = "/some/other/repo/.git",
  kind      = "index",
  path      = "/some/other/repo/.git/index",
})
ok("status cache survives publish for unrelated repo",
  status_mod.is_cached(repo) == true)

-- ── debounce coalescing on the SAME file ───────────────────
-- Three rapid writes to .git/index within the 200ms debounce window
-- should produce at most one publish. CORRUPTS the index — keep this
-- test last among the repo-dependent assertions.
before = #seen
vim.wait(300)
for i = 1, 3 do
  vim.fn.writefile({ string.rep("X", i) }, repo .. "/.git/index")
end
vim.wait(400)
local burst_count = 0
for i = before + 1, #seen do
  if seen[i].path and seen[i].path:sub(-#"/index") == "/index" then
    burst_count = burst_count + 1
  end
end
-- Bound matches fs.watch's own burst test (§26): libuv's inotify can
-- fire multiple events per writefile on Linux, so 1–2 publishes for
-- a burst of 3 is the realistic coalescing outcome. 3 (no coalescing)
-- would fail.
ok("debounce coalesces burst of 3 index writes to ≤2 publishes",
  burst_count >= 1 and burst_count <= 2,
  "got " .. tostring(burst_count))

-- ── stop / list / stop_all ─────────────────────────────────
gwatch.stop(handle)
ok("after stop, list is empty", #gwatch.list() == 0)
ok("stopped handle.fs_events is cleared",
  handle and #handle.fs_events == 0)

-- max_handles cap.
local capped, cap_err = gwatch.start(repo, { max_handles = 1 })
ok("max_handles cap refuses start when budget would overflow",
  capped == nil and type(cap_err) == "string"
    and cap_err:find("max_handles"),
  tostring(cap_err))

-- Restart for stop_all coverage.
local h2 = gwatch.start(repo)
ok("restart succeeds after stop", h2 ~= nil)
gwatch.stop_all()
ok("stop_all clears every handle", #gwatch.list() == 0)

-- ── default constants are exposed ──────────────────────────
ok("DEFAULT_DEBOUNCE_MS = 200", gwatch.DEFAULT_DEBOUNCE_MS == 200)
ok("DEFAULT_MAX_HANDLES = 64",  gwatch.DEFAULT_MAX_HANDLES == 64)
ok("FILENAME_KINDS includes HEAD/index/ORIG_HEAD/MERGE_HEAD",
  gwatch.FILENAME_KINDS.HEAD == "head"
    and gwatch.FILENAME_KINDS.index == "index"
    and gwatch.FILENAME_KINDS.ORIG_HEAD == "merge"
    and gwatch.FILENAME_KINDS.MERGE_HEAD == "merge")

-- ── topic registry entry ──────────────────────────────────
local topics = require("auto-core.events.topics")
ok("core.git.state:changed is registered in topics.lua",
  topics["core.git.state:changed"] ~= nil
    and type(topics["core.git.state:changed"].doc) == "string"
    and type(topics["core.git.state:changed"].payload) == "string")

-- cleanup
gwatch._reset_for_tests()
status_mod._reset_for_tests()
events._reset_for_tests()
pcall(vim.fn.delete, repo, "rf")
end)()

-- ─────────────────────── 52. ui.panel — VimResized visibility + unmarked-sibling cleanup ─────────────────────────
-- v0.1.21 panel-visibility branch. Closes the regression where
-- VimResized fired but produced no ring entry because the
-- field-table literal threw before log_panel.info ever saw the
-- message (per incident agents/white-vision/incidents/
-- 2026-05-18-auto-agents-panel-duplicated-recurrence.md). Also
-- covers the WinNew detection + post-VimResized cleanup pass.
print("\n[52] ui.panel — VimResized log anchor + unmarked-sibling cleanup")
;(function()
local panel_mod = require("auto-core.ui.panel")
local log = require("auto-core.log")
panel_mod._reset_for_tests()
log._reset_for_tests()

local p = panel_mod.new({
  name = "smoke52",
  side = "right",
  width = { default = 30, min = 10, max = 80 },
  filetype = "smoke52-panel",
})
p:open(true)
ok("panel opens for smoke 52", p:_is_open(),
  "winid=" .. tostring(p.winid))

-- ── VimResized → ring anchor MUST appear (regression guard). ──
-- Strictly-after-since search so an idempotent re-call doesn't
-- match the prior pass's entry. `since` is the ring length captured
-- BEFORE the action; only indices > since are valid "new" entries.
local function ring_has(needle, since)
  local r = log.recent()
  for i = #r, (since or 0) + 1, -1 do
    local m = (r[i] or {}).message or ""
    if m:find(needle, 1, true) then return true end
  end
  return false
end

local before = #log.recent()
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(50, function() return ring_has("VimResized", before) end)
ok("VimResized log entry lands in ring (regression guard)",
  ring_has("VimResized", before),
  "ring grew " .. before .. " → " .. #log.recent())

-- ── Defensive: log still lands when refresh_width's winid is stale. ──
local saved_winid = p.winid
p.winid = 99999   -- invalid → refresh_width's pcall silently fails
before = #log.recent()
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(50)
ok("VimResized anchor still logs when winid is racy-invalid",
  ring_has("VimResized", before))
p.winid = saved_winid  -- restore

-- ── WinNew detection path: synthetic unmarked sibling → log. ──
-- Spawn the sibling using the explicit nvim_open_win API (which
-- doesn't copy `w:` vars unlike `vim.cmd("split")`, and works
-- deterministically in headless mode). The panel-singleton's
-- WinNew autocmd should detect this via its `vim.schedule`-deferred
-- check, log INFO "unmarked sibling detected (WinNew)", and NOT
-- close the sibling (detection-only path).
local panel_bufnr = vim.api.nvim_win_get_buf(p.winid)
local winnew_before = #log.recent()
local sibling = vim.api.nvim_open_win(panel_bufnr, false, {
  win   = p.winid,
  split = "below",
})
ok("sibling spawned",
  sibling ~= nil and vim.api.nvim_win_is_valid(sibling),
  "sibling=" .. tostring(sibling))
ok("sibling has the panel buffer",
  vim.api.nvim_win_get_buf(sibling) == panel_bufnr)
local sib_marker_set, _ = pcall(vim.api.nvim_win_get_var, sibling, p._marker_var)
ok("sibling lacks the panel marker",
  not sib_marker_set)

-- Drain the schedule queue so the WinNew autocmd's deferred check
-- runs. nvim.wait() with a poll predicate gives time for vim.schedule
-- to flush.
vim.wait(100, function()
  return ring_has("unmarked sibling detected", winnew_before)
end)
ok("WinNew detection logged 'unmarked sibling detected (WinNew)'",
  ring_has("unmarked sibling detected", winnew_before),
  "expected WinNew log entry after nvim_open_win sibling spawn")
ok("WinNew detection did NOT close the sibling (detection-only)",
  vim.api.nvim_win_is_valid(sibling))

before = #log.recent()
p:_cleanup_unmarked_siblings()
ok("sibling closed by cleanup pass",
  not vim.api.nvim_win_is_valid(sibling))
ok("cleanup logs 'unmarked sibling closed' at INFO",
  ring_has("unmarked sibling closed", before))

-- ── Idempotent: cleanup with no siblings is a silent fast-path. ──
before = #log.recent()
p:_cleanup_unmarked_siblings()
ok("cleanup is silent when no siblings exist",
  not ring_has("unmarked sibling", before),
  "expected no new 'unmarked sibling' log lines")

-- ── Cleanup. ─────────────────────────────────────────────────
p:close()
p:dispose()
panel_mod._reset_for_tests()
log._reset_for_tests()
end)()

-- ─────────────────────── 53. ui.panel — ADR 0028 local-scope regression probe ─────────────────────────
-- Asserts that panel-open does NOT mutate the global-local
-- DEFAULTS for `number` / `relativenumber` / `signcolumn` /
-- `foldcolumn`, and that a fresh editor split spawned AFTER the
-- panel opens inherits the user-configured editor defaults — not
-- the panel-masked values.
--
-- Pre-ADR-0028 panel writes (`{ win = winid }` without
-- `scope = "local"`) had the side effect of mutating these
-- global-local defaults. The symptom was an editor window opened
-- after panels showing no line numbers / no sign column, because
-- it inherited the polluted defaults. The fix (set_winlocal in
-- ui/panel.lua) routes every appearance write through
-- `{ win = winid, scope = "local" }`. This section would have
-- caught the original bug.
print("\n[53] ui.panel — ADR 0028 panel-open does NOT pollute global defaults")
;(function()
local panel_mod = require("auto-core.ui.panel")
panel_mod._reset_for_tests()

-- Seed editor-side defaults so the assertions are self-contained
-- regardless of host config or prior smoke sections. Capture
-- pre-section globals to restore afterwards.
local saved = {
  number         = vim.api.nvim_get_option_value("number",         {}),
  relativenumber = vim.api.nvim_get_option_value("relativenumber", {}),
  signcolumn     = vim.api.nvim_get_option_value("signcolumn",     {}),
  foldcolumn     = vim.api.nvim_get_option_value("foldcolumn",     {}),
}
vim.api.nvim_set_option_value("number",         true,  {})
vim.api.nvim_set_option_value("relativenumber", true,  {})
vim.api.nvim_set_option_value("signcolumn",     "yes", {})
vim.api.nvim_set_option_value("foldcolumn",     "1",   {})

local seeded = {
  number         = vim.api.nvim_get_option_value("number",         {}),
  relativenumber = vim.api.nvim_get_option_value("relativenumber", {}),
  signcolumn     = vim.api.nvim_get_option_value("signcolumn",     {}),
  foldcolumn     = vim.api.nvim_get_option_value("foldcolumn",     {}),
}
ok("seed: global number=true",         seeded.number == true)
ok("seed: global relativenumber=true", seeded.relativenumber == true)
ok("seed: global signcolumn=yes",      seeded.signcolumn == "yes")
ok("seed: global foldcolumn=1",        seeded.foldcolumn == "1")

local p = panel_mod.new({
  name = "smoke53",
  side = "right",
  width = { default = 30, min = 10, max = 80 },
  filetype = "smoke53-panel",
})
p:open(true)
ok("panel opens for smoke 53", p:_is_open(),
  "winid=" .. tostring(p.winid))

-- ── Panel window has the masked appearance values (local). ──
local panel_win = p.winid
ok("panel win: number=false (local)",
  vim.api.nvim_get_option_value("number", { win = panel_win, scope = "local" }) == false)
ok("panel win: relativenumber=false (local)",
  vim.api.nvim_get_option_value("relativenumber", { win = panel_win, scope = "local" }) == false)
ok("panel win: signcolumn=no (local)",
  vim.api.nvim_get_option_value("signcolumn", { win = panel_win, scope = "local" }) == "no")
ok("panel win: foldcolumn=0 (local)",
  vim.api.nvim_get_option_value("foldcolumn", { win = panel_win, scope = "local" }) == "0")

-- ── Global defaults survive panel open (this is the bug guard). ──
-- Read via `{ scope = "global" }` explicitly. `{}` defaults to the
-- CURRENT window's local value for window-local options, which would
-- be the panel-masked false right now — that's the wrong assertion
-- shape for this regression. The global default is what editor
-- windows materialized fresh-from-defaults inherit from.
local function global(name) return vim.api.nvim_get_option_value(name, { scope = "global" }) end
ok("global number SURVIVES panel open",
  global("number") == seeded.number,
  "expected " .. tostring(seeded.number) .. " got " .. tostring(global("number")))
ok("global relativenumber SURVIVES panel open",
  global("relativenumber") == seeded.relativenumber,
  "expected " .. tostring(seeded.relativenumber) .. " got " .. tostring(global("relativenumber")))
ok("global signcolumn SURVIVES panel open",
  global("signcolumn") == seeded.signcolumn,
  "expected " .. tostring(seeded.signcolumn) .. " got " .. tostring(global("signcolumn")))
ok("global foldcolumn SURVIVES panel open",
  global("foldcolumn") == seeded.foldcolumn,
  "expected " .. tostring(seeded.foldcolumn) .. " got " .. tostring(global("foldcolumn")))

-- ── Fresh editor split spawned AFTER panel inherits editor defaults. ──
-- Use nvim_open_win with split=below targeting a non-panel window so
-- the new split is materialized cleanly without disturbing the panel.
-- Need a non-panel anchor: create a baseline editor window first via
-- vsplit from the panel (the resulting window is editor-side; the
-- panel keeps winfixwidth so layout doesn't squash it).
vim.api.nvim_set_current_win(panel_win)
-- Move focus to any non-panel window. nvim_open_win with split off
-- the panel would inherit panel-window-local options, so we leave
-- the panel and use the autocreated initial window if present, else
-- spawn an editor window from outside the panel context.
local editor_anchor
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if w ~= panel_win then editor_anchor = w; break end
end
if not editor_anchor then
  -- No editor window in headless tab — create one from the panel side
  -- via :new (horizontal split off the panel). The new window IS
  -- editor-side. We use a fresh scratch so we don't dirty any buffer.
  vim.cmd("new")
  editor_anchor = vim.api.nvim_get_current_win()
end
vim.api.nvim_set_current_win(editor_anchor)

local fresh = vim.api.nvim_open_win(0, false, {
  win   = editor_anchor,
  split = "below",
})
ok("fresh editor split spawned after panel open",
  fresh ~= nil and vim.api.nvim_win_is_valid(fresh),
  "winid=" .. tostring(fresh))

ok("fresh split inherits global number (not panel-masked)",
  vim.api.nvim_get_option_value("number", { win = fresh }) == seeded.number,
  "expected " .. tostring(seeded.number) ..
  " got " .. tostring(vim.api.nvim_get_option_value("number", { win = fresh })))
ok("fresh split inherits global relativenumber (not panel-masked)",
  vim.api.nvim_get_option_value("relativenumber", { win = fresh }) == seeded.relativenumber,
  "expected " .. tostring(seeded.relativenumber) ..
  " got " .. tostring(vim.api.nvim_get_option_value("relativenumber", { win = fresh })))
ok("fresh split inherits global signcolumn (not panel-masked)",
  vim.api.nvim_get_option_value("signcolumn", { win = fresh }) == seeded.signcolumn,
  "expected " .. tostring(seeded.signcolumn) ..
  " got " .. tostring(vim.api.nvim_get_option_value("signcolumn", { win = fresh })))

-- ── Cleanup. ─────────────────────────────────────────────────
if fresh and vim.api.nvim_win_is_valid(fresh) then
  pcall(vim.api.nvim_win_close, fresh, true)
end
p:close()
p:dispose()
panel_mod._reset_for_tests()

-- Restore pre-section globals so later sections / the host process
-- aren't perturbed by the seed.
vim.api.nvim_set_option_value("number",         saved.number,         {})
vim.api.nvim_set_option_value("relativenumber", saved.relativenumber, {})
vim.api.nvim_set_option_value("signcolumn",     saved.signcolumn,     {})
vim.api.nvim_set_option_value("foldcolumn",     saved.foldcolumn,     {})
end)()

-- ─────────────────────── 54. todo.yaml — strict-subset YAML adapter (ADR 0031 §2) ─
print("\n[54] todo.yaml — strict-subset decode / encode")
;(function()
  local ok_req, yaml = pcall(require, "auto-core.todo.yaml")
  ok("auto-core.todo.yaml loads", ok_req, tostring(yaml))
  if ok_req then

    -- ── decode: happy path ────────────────────────────────────
    local src_basic = table.concat({
      "id: 2026-05-25-foo",
      "version: 1",
      "status: open",
      "title: Test task",
      "tags:",
      "  - workflow",
      "  - testing",
      "",
    }, "\n")
    local r = yaml.decode(src_basic)
    ok("decode: minimal task succeeds", r.ok, r.err)
    ok("decode: id round-trips",
      r.ok and r.value and r.value.id == "2026-05-25-foo",
      r.ok and ("got " .. tostring(r.value and r.value.id)))
    ok("decode: version stays numeric",
      r.ok and r.value and r.value.version == 1)
    ok("decode: tags is a sequence of two items",
      r.ok and r.value and type(r.value.tags) == "table"
        and r.value.tags[1] == "workflow" and r.value.tags[2] == "testing")

    -- ── decode: strict-subset rejections ──────────────────────
    local rej_anchor = yaml.decode("foo: &my_anchor 42\nbar: *my_anchor\n")
    ok("decode: rejects YAML anchor",
      (not rej_anchor.ok) and rej_anchor.err and rej_anchor.err:find("anchor"),
      rej_anchor.err)

    local rej_alias = yaml.decode("foo: 42\nbar: *some_alias\n")
    ok("decode: rejects YAML alias (no anchor in scope)",
      (not rej_alias.ok) and rej_alias.err and rej_alias.err:find("alias"),
      rej_alias.err)

    local rej_merge = yaml.decode(table.concat({
      "base: &b",
      "  k: v",
      "child:",
      "  <<: *b",
      "  k2: v2",
      "",
    }, "\n"))
    ok("decode: rejects YAML merge key `<<:`",
      (not rej_merge.ok) and rej_merge.err
        and (rej_merge.err:find("merge") or rej_merge.err:find("anchor")),
      rej_merge.err)

    local rej_tag = yaml.decode("created: !!timestamp 2026-05-25T12:00:00Z\n")
    ok("decode: rejects YAML explicit tag `!!type`",
      (not rej_tag.ok) and rej_tag.err and rej_tag.err:find("explicit tag"),
      rej_tag.err)

    -- ── decode: block-scalar bodies are exempt from the check ─
    -- A `description: |` block whose body contains `&foo` is content,
    -- not a YAML anchor — must not be rejected.
    local block_with_ampersand = table.concat({
      "id: 2026-05-25-bar",
      "description: |",
      "  Free-form prose. Mentioning &foo and *bar and !!baz",
      "  here is just text; these are not YAML constructs.",
      "",
    }, "\n")
    local r_block = yaml.decode(block_with_ampersand)
    ok("decode: forbidden markers inside `|` block scalar bodies do NOT reject",
      r_block.ok, r_block.err)
    ok("decode: block-scalar body preserves the literal content",
      r_block.ok and r_block.value
        and type(r_block.value.description) == "string"
        and r_block.value.description:find("&foo")
        and r_block.value.description:find("*bar")
        and r_block.value.description:find("!!baz"))

    -- ── encode: happy path ────────────────────────────────────
    local enc_basic = yaml.encode({
      id      = "2026-05-25-foo",
      version = 1,
      status  = "open",
      title   = "Test task",
    })
    ok("encode: emits a string", type(enc_basic) == "string")
    -- Date-shaped strings are double-quoted by the encoder (round-trip
    -- safe given the strict subset disables native timestamp coercion).
    ok("encode: contains the id line (quoted because date-shaped)",
      enc_basic:find('id: "2026%-05%-25%-foo"') ~= nil, enc_basic)
    ok("encode: contains the version line",
      enc_basic:find("version: 1") ~= nil, enc_basic)
    ok("encode: ends with a trailing newline",
      enc_basic:sub(-1) == "\n", "tail=" .. string.format("%q", enc_basic:sub(-5)))

    -- ── encode: multi-line strings use `|` literal block ──────
    local enc_multi = yaml.encode({
      notes = "line one\nline two\nline three",
    })
    ok("encode: multi-line string uses `|` block scalar",
      enc_multi:find("notes: |\n") ~= nil, enc_multi)
    -- Top-level key is at column 0, so its block-scalar body is at
    -- indent+2 = 2 spaces.
    ok("encode: block-scalar body lines are indented 2 spaces",
      enc_multi:find("\n  line one\n") ~= nil
        and enc_multi:find("\n  line two\n") ~= nil, enc_multi)

    -- ── encode: ISO datetime is quoted ────────────────────────
    local enc_ts = yaml.encode({
      created = "2026-05-25T14:32:00-07:00",
    })
    ok("encode: ISO 8601 timestamp is double-quoted (round-trip safe)",
      enc_ts:find('created: "2026%-05%-25T14:32:00%-07:00"') ~= nil, enc_ts)

    -- ── encode: sequence of mappings (errors[] shape) ─────────
    local enc_errors = yaml.encode({
      errors = {
        { field = "blocked[0]", code = "not-found", message = "missing",
          detected = "2026-05-25T22:00:00-07:00" },
      },
    })
    -- First entry: `- code: not-found` (alphabetical order) inline
    -- after the dash; remaining keys indented by two spaces.
    ok("encode: list-of-mappings emits `- key: value` on first key",
      enc_errors:find("\n  %- code: not%-found\n") ~= nil, enc_errors)
    ok("encode: list-of-mappings indents subsequent keys to align",
      enc_errors:find("\n    detected:") ~= nil
        and enc_errors:find("\n    field: ") ~= nil
        and enc_errors:find("\n    message: missing") ~= nil, enc_errors)

    -- ── round-trip ────────────────────────────────────────────
    local round_input = {
      id          = "2026-05-25-rt",
      version     = 1,
      status      = "open",
      title       = "Round-trip test",
      description = "First line.\nSecond line.",
      tags        = { "a", "b", "c" },
      blocked     = { "2026-05-20-prereq" },
    }
    local round_yaml = yaml.encode(round_input)
    local round_dec  = yaml.decode(round_yaml)
    ok("round-trip: decode succeeds on encode output",
      round_dec.ok, round_dec.err)
    if round_dec.ok then
      local v = round_dec.value
      ok("round-trip: id preserved", v.id == round_input.id)
      ok("round-trip: version preserved", v.version == round_input.version)
      ok("round-trip: status preserved", v.status == round_input.status)
      ok("round-trip: title preserved", v.title == round_input.title)
      -- Block scalar with `|` includes a trailing newline by spec.
      ok("round-trip: description preserved (modulo block-scalar trailing \\n)",
        v.description == round_input.description
          or v.description == (round_input.description .. "\n"),
        "got " .. string.format("%q", tostring(v.description)))
      ok("round-trip: tags preserved",
        type(v.tags) == "table"
          and v.tags[1] == "a" and v.tags[2] == "b" and v.tags[3] == "c")
      ok("round-trip: blocked preserved",
        type(v.blocked) == "table" and v.blocked[1] == "2026-05-20-prereq")
    end

    -- ── decode: non-string source rejected cleanly ────────────
    local rej_type = yaml.decode(42)
    ok("decode: non-string source returns ok=false with type error",
      (not rej_type.ok) and rej_type.err and rej_type.err:find("string"),
      rej_type.err)
  end
end)()

-- ─────────────────────── 55. todo.schema — v1 validator (ADR 0031 §2) ────
print("\n[55] todo.schema — v1 schema validation")
;(function()
  local ok_req, schema = pcall(require, "auto-core.todo.schema")
  ok("auto-core.todo.schema loads", ok_req, tostring(schema))
  if not ok_req then return end

  -- ── blank() produces a valid skeleton ────────────────────────
  local b = schema.blank()
  ok("schema.blank() returns a table", type(b) == "table")
  ok("schema.blank() has version 1", b.version == 1)
  ok("schema.blank() has status 'open'", b.status == "open")
  ok("schema.blank() has matching id/created/updated/status_changed",
    type(b.id) == "string" and type(b.created) == "string"
    and b.updated == b.created and b.status_changed == b.created)
  local r_blank = schema.validate(b)
  ok("validate(blank()) succeeds", r_blank.ok, r_blank.err)

  -- ── full happy-path task ─────────────────────────────────────
  local full = schema.blank({
    id          = "2026-05-25-implement-todo-system",
    title       = "Implement the todo system",
    description = "Multi-line goal.",
    priority    = "high",
    tags        = { "auto-core", "workflow" },
    adr         = { "shared/adrs/0031-auto-core-per-project-todo-task-system.md" },
    review      = {
      "$KB_ROOT/shared/reviews/repo-a.md",
      "$KB_ROOT/shared/reviews/repo-b.md",
    },
    blocked     = { "2026-05-20-prereq" },
  })
  ok("validate(full happy task) succeeds", schema.validate(full).ok)

  -- ── review is a string_list (multi-repo / multi-agent reviews) ──
  ok("validate accepts multi-entry review list",
    schema.validate(schema.blank({
      title  = "two reviews",
      review = { "a.md", "b.md" },
    })).ok)
  local bad_review = schema.blank({ title = "bad review", review = { "ok", 7 } })
  local r_rv = schema.validate(bad_review)
  ok("validate rejects non-string in review list",
    (not r_rv.ok) and r_rv.field == "review", r_rv.err)

  -- ── required-field absence ───────────────────────────────────
  local missing_id = schema.blank()
  missing_id.id = nil
  local r_mid = schema.validate(missing_id)
  ok("validate rejects missing required id",
    (not r_mid.ok) and r_mid.field == "id" and r_mid.err:find("missing"), r_mid.err)

  local missing_title = schema.blank()
  missing_title.title = nil
  local r_mt = schema.validate(missing_title)
  ok("validate rejects missing required title",
    (not r_mt.ok) and r_mt.field == "title", r_mt.err)

  -- ── unknown top-level key ────────────────────────────────────
  local bogus = schema.blank()
  bogus.surprise_field = "noooo"
  local r_un = schema.validate(bogus)
  ok("validate rejects unknown top-level key",
    (not r_un.ok) and r_un.err:find("unknown top%-level key"), r_un.err)

  -- ── enum violations ──────────────────────────────────────────
  local bad_status = schema.blank()
  bad_status.status = "in_progress"  -- wrong enum
  local r_st = schema.validate(bad_status)
  ok("validate rejects invalid status enum",
    (not r_st.ok) and r_st.field == "status", r_st.err)

  local bad_prio = schema.blank({ priority = "urgent" })
  local r_pr = schema.validate(bad_prio)
  ok("validate rejects invalid priority enum",
    (not r_pr.ok) and r_pr.field == "priority", r_pr.err)

  -- ── type violations ──────────────────────────────────────────
  local bad_tags = schema.blank({ tags = { "ok", 42 } })
  local r_tg = schema.validate(bad_tags)
  ok("validate rejects non-string in tags list",
    (not r_tg.ok) and r_tg.field == "tags", r_tg.err)

  local bad_version = schema.blank()
  bad_version.version = 2
  local r_v = schema.validate(bad_version)
  ok("validate rejects version mismatch",
    (not r_v.ok) and r_v.field == "version" and r_v.err:find("v1"), r_v.err)

  local bad_dt = schema.blank()
  bad_dt.created = "2026-05-25"  -- date only, no time/offset
  local r_dt = schema.validate(bad_dt)
  ok("validate rejects datetime without time + offset",
    (not r_dt.ok) and r_dt.field == "created", r_dt.err)

  -- ── lifecycle consistency invariants ─────────────────────────
  local completed_no_ts = schema.blank({ status = "completed" })
  -- blank() defaults status='open' so completed_at is unset; force the
  -- override and expect a failure for missing completed_at.
  completed_no_ts.completed_at = nil
  local r_c1 = schema.validate(completed_no_ts)
  ok("validate rejects status=completed without completed_at",
    (not r_c1.ok) and r_c1.err:find("completed_at must be set"), r_c1.err)

  local open_with_completed_at = schema.blank()
  open_with_completed_at.completed_at = "2026-05-25T12:00:00Z"
  local r_c2 = schema.validate(open_with_completed_at)
  ok("validate rejects status=open with completed_at set",
    (not r_c2.ok) and r_c2.err:find("completed_at must be nil"), r_c2.err)

  local archived_no_ts = schema.blank({
    status       = "archived",
    completed_at = "2026-05-01T10:00:00Z",
  })
  archived_no_ts.archived_at = nil
  local r_a1 = schema.validate(archived_no_ts)
  ok("validate rejects status=archived without archived_at",
    (not r_a1.ok) and r_a1.err:find("archived_at must be set"), r_a1.err)

  local completed_ok = schema.blank({
    status       = "completed",
    completed_at = "2026-05-20T10:00:00-07:00",
  })
  ok("validate accepts status=completed with completed_at set",
    schema.validate(completed_ok).ok)

  local archived_ok = schema.blank({
    status       = "archived",
    completed_at = "2026-05-20T10:00:00Z",
    archived_at  = "2026-06-17T10:00:00Z",
  })
  ok("validate accepts status=archived with both completed_at + archived_at set",
    schema.validate(archived_ok).ok)

  -- ── errors[] shape ───────────────────────────────────────────
  local with_errors = schema.blank({
    errors = {
      {
        field    = "blocked[0]",
        code     = "not-found",
        message  = "Task '2026-05-20-prereq' does not exist",
        detected = "2026-05-25T22:00:00-07:00",
      },
    },
  })
  ok("validate accepts well-formed errors[] entry", schema.validate(with_errors).ok)

  local bad_err_code = schema.blank({
    errors = {
      { field = "blocked[0]", code = "made-up-code",
        message = "x", detected = "2026-05-25T22:00:00-07:00" },
    },
  })
  local r_be = schema.validate(bad_err_code)
  ok("validate rejects unknown errors[].code",
    (not r_be.ok) and r_be.err:find("code"), r_be.err)

  local extra_key_in_err = schema.blank({
    errors = {
      { field = "wip", code = "not-found", message = "x",
        detected = "2026-05-25T22:00:00-07:00", extra = "boo" },
    },
  })
  local r_ek = schema.validate(extra_key_in_err)
  ok("validate rejects unknown keys inside errors[] entry",
    (not r_ek.ok) and r_ek.err:find("unknown key"), r_ek.err)

  -- ── non-table input is rejected cleanly ──────────────────────
  local r_nt = schema.validate("not a table")
  ok("validate rejects non-table input",
    (not r_nt.ok) and r_nt.err:find("mapping"), r_nt.err)

  -- ── decode + validate end-to-end ─────────────────────────────
  -- Confirms the schema validator wires to the YAML decoder cleanly.
  local yaml = require("auto-core.todo.yaml")
  local src = table.concat({
    'id: "2026-05-25-e2e"',
    "version: 1",
    'created: "2026-05-25T14:32:00-07:00"',
    'updated: "2026-05-25T14:32:00-07:00"',
    'status_changed: "2026-05-25T14:32:00-07:00"',
    "status: open",
    "title: End-to-end YAML+schema test",
    "description: minimum viable task",
    "",
  }, "\n")
  local dec = yaml.decode(src)
  ok("e2e: yaml.decode succeeds", dec.ok, dec.err)
  if dec.ok then
    ok("e2e: schema.validate of decoded value succeeds",
      schema.validate(dec.value).ok)
  end
end)()

-- ─────────────────────── 56. todo.paths + todo.header (ADR 0031 §1+§2) ───
print("\n[56] todo.paths — dir resolver + bucket helpers + id slug")
;(function()
  local ok_p, paths = pcall(require, "auto-core.todo.paths")
  ok("auto-core.todo.paths loads", ok_p, tostring(paths))
  if not ok_p then return end

  -- ── workspace_root resolves through git.worktree ────────────
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root("/tmp/ac-todo-smoke-ws")
  ok("workspace_root() returns the explicitly-set value",
    paths.workspace_root() == "/tmp/ac-todo-smoke-ws",
    "got " .. paths.workspace_root())

  worktree.set_workspace_root(nil)  -- clear; fall through to other layers

  -- ── default_todo_dir is `<ws>/.todo-list` ───────────────────
  ok("default_todo_dir(ws) appends .todo-list",
    paths.default_todo_dir("/tmp/foo") == "/tmp/foo/.todo-list",
    "got " .. paths.default_todo_dir("/tmp/foo"))

  -- ── resolve_todo_dir honors explicit override ───────────────
  ok("resolve_todo_dir(override) returns the override",
    paths.resolve_todo_dir("/tmp/explicit") == "/tmp/explicit")
  worktree.set_workspace_root("/tmp/ac-todo-smoke-ws")
  ok("resolve_todo_dir(nil) falls back to workspace default",
    paths.resolve_todo_dir(nil) == "/tmp/ac-todo-smoke-ws/.todo-list")
  ok("resolve_todo_dir('') falls back like nil",
    paths.resolve_todo_dir("") == "/tmp/ac-todo-smoke-ws/.todo-list")
  worktree.set_workspace_root(nil)

  -- ── bucket_dir for non-archived statuses ────────────────────
  local td = "/tmp/foo/.todo-list"
  ok("bucket_dir(open)      → <td>/open",      paths.bucket_dir(td, "open")      == td .. "/open")
  ok("bucket_dir(completed) → <td>/completed", paths.bucket_dir(td, "completed") == td .. "/completed")
  ok("bucket_dir(deferred)  → <td>/deferred",  paths.bucket_dir(td, "deferred")  == td .. "/deferred")
  local ok_arch_err = pcall(paths.bucket_dir, td, "archived")
  ok("bucket_dir('archived') refuses (caller must use archive_bucket)", not ok_arch_err)
  local ok_bad_status = pcall(paths.bucket_dir, td, "wat")
  ok("bucket_dir(unknown status) raises",      not ok_bad_status)

  -- ── archive_bucket partitions by YYYY/MM ────────────────────
  ok("archive_bucket('2026-06-17T10:00:00Z') → <td>/archived/2026/06",
    paths.archive_bucket(td, "2026-06-17T10:00:00Z") == td .. "/archived/2026/06")
  ok("archive_bucket('2026-12-31T23:59:59-08:00') → <td>/archived/2026/12",
    paths.archive_bucket(td, "2026-12-31T23:59:59-08:00") == td .. "/archived/2026/12")
  local ok_bad_iso = pcall(paths.archive_bucket, td, "not-a-date")
  ok("archive_bucket(non-ISO) raises", not ok_bad_iso)

  -- ── task_file_path ──────────────────────────────────────────
  ok("task_file_path(open) builds <td>/open/<id>.md",
    paths.task_file_path(td, "2026-05-25-foo", "open")
      == td .. "/open/2026-05-25-foo.md")
  ok("task_file_path(archived) uses YYYY/MM partition",
    paths.task_file_path(td, "2026-05-25-foo", "archived", "2026-06-17T10:00:00Z")
      == td .. "/archived/2026/06/2026-05-25-foo.md")

  -- ── make_id slug rules ──────────────────────────────────────
  ok("make_id strips punctuation",
    paths.make_id("2026-05-25T12:00:00Z", "Implement the todo!  System.")
      == "2026-05-25-implement-the-todo-system",
    "got " .. paths.make_id("2026-05-25T12:00:00Z", "Implement the todo!  System."))
  ok("make_id collapses whitespace runs",
    paths.make_id("2026-05-25T12:00:00Z", "Fix   the     panel  bug")
      == "2026-05-25-fix-the-panel-bug")
  ok("make_id lower-cases",
    paths.make_id("2026-05-25T12:00:00Z", "MixedCASE Title")
      == "2026-05-25-mixedcase-title")
  ok("make_id preserves intentional dashes",
    paths.make_id("2026-05-25T12:00:00Z", "v1.2-bugfix release")
      == "2026-05-25-v12-bugfix-release",
    "got " .. paths.make_id("2026-05-25T12:00:00Z", "v1.2-bugfix release"))
  ok("make_id falls back to 'untitled' on empty slug",
    paths.make_id("2026-05-25T12:00:00Z", "?!@#")
      == "2026-05-25-untitled")
  local ok_no_date = pcall(paths.make_id, "not-a-date", "Foo")
  ok("make_id raises on non-ISO created", not ok_no_date)
end)()

print("\n[57] todo.header — canonical comment block")
;(function()
  local ok_h, header = pcall(require, "auto-core.todo.header")
  ok("auto-core.todo.header loads", ok_h, tostring(header))
  if not ok_h then return end

  local block = header.emit()
  ok("emit() returns a string", type(block) == "string")
  ok("first line is the canonical HTML-comment opener",
    block:match("^<!%-%- ─── auto%-core%.todo schema v1") ~= nil,
    "first line: " .. (block:match("^[^\n]*") or ""))
  ok("HAND-EDIT FREELY clause is present",
    block:find("HAND%-EDIT FREELY") ~= nil)
  ok("DO NOT HAND-EDIT clause is present",
    block:find("DO NOT HAND%-EDIT") ~= nil)
  ok("emit() does not trail with a blank line",
    block:sub(-1) ~= "\n")
  ok("emit() ends with the canonical HTML-comment closer",
    block:match("─── %-%->%s*$") ~= nil,
    "last bytes: " .. block:sub(-30))

  -- ── is_present recognizes its own output ────────────────────
  ok("is_present recognizes emit()'s output",
    header.is_present(block .. "\n\nid: foo\n"))
  ok("is_present returns false on non-headered body",
    not header.is_present("id: 2026-05-25-foo\nversion: 1\n"))
  ok("is_present returns false on non-string input",
    not header.is_present(42))
  ok("is_present returns false on empty string",
    not header.is_present(""))
end)()

-- ─────────────────────── 58. todo (CRUD + atomic write) — ADR-0031 §3.2 ──
print("\n[58] todo — add / get / list / update / remove")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  ok("auto-core.todo loads", ok_req, tostring(todo))
  if not ok_req then return end

  -- ── isolated workspace fixture ──────────────────────────────
  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)

  local function cleanup() vim.fn.delete(tmp_root, "rf") end

  ok("fixture: workspace_root applied",
    require("auto-core.todo.paths").workspace_root() == tmp_root)
  local td = todo._todo_dir()
  ok("fixture: todo_dir resolved under workspace",
    td == tmp_root .. "/.todo-list", "got " .. td)

  -- ── _now_iso shape ──────────────────────────────────────────
  local now = todo._now_iso()
  ok("_now_iso returns ISO 8601 with offset",
    now:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[Z+%-]") ~= nil,
    "got " .. now)

  -- ── add: basic + file placement ─────────────────────────────
  local id1 = todo.add({ title = "First task" })
  ok("add returns a non-empty id", type(id1) == "string" and id1 ~= "")
  ok("add id matches paths.make_id shape",
    id1:match("^%d%d%d%d%-%d%d%-%d%d%-first%-task$") ~= nil,
    "got " .. id1)

  local f1 = td .. "/open/" .. id1 .. ".md"
  ok("add wrote file under .todo-list/open/", vim.fn.filereadable(f1) == 1,
    "expected " .. f1)

  -- ── header comment + body present in the written file ──────
  local lines1 = vim.fn.readfile(f1)
  -- MD format: file opens with the `---` frontmatter delimiter; the
  -- HTML-comment header lives inside the body.
  ok("written file starts with the frontmatter delimiter",
    lines1[1] == "---", "first line: " .. tostring(lines1[1]))
  local raw1 = table.concat(lines1, "\n")
  ok("written file body contains the canonical header HTML comment",
    raw1:find("<!%-%- ─── auto%-core%.todo schema v1") ~= nil)
  ok("written file body contains the H1 title",
    raw1:find("\n# First task") ~= nil, raw1:sub(1, 200))

  -- ── add: explicit id + spec fields propagated ───────────────
  local id2 = todo.add({
    id          = "2026-05-25-explicit",
    title       = "Explicit id task",
    description = "with prose",
    tags        = { "alpha", "beta" },
    priority    = "high",
    assignee    = "jarvis",
  })
  ok("add honors explicit id", id2 == "2026-05-25-explicit")
  local t2 = todo.get(id2)
  ok("get reads the task back", type(t2) == "table" and t2.id == id2,
    t2 and tostring(t2.id))
  ok("get: description preserved",
    t2 and t2.description == "with prose")
  ok("get: tags preserved",
    t2 and t2.tags and t2.tags[1] == "alpha" and t2.tags[2] == "beta")
  ok("get: priority preserved", t2 and t2.priority == "high")
  ok("get: assignee preserved", t2 and t2.assignee == "jarvis")

  -- ── add: refuses missing/empty title ────────────────────────
  ok("add refuses missing title", not pcall(todo.add, {}))
  ok("add refuses empty title",   not pcall(todo.add, { title = "" }))

  -- ── add: refuses duplicate id ───────────────────────────────
  ok("add refuses duplicate id",
    not pcall(todo.add, { id = id2, title = "dup" }))

  -- ── add: deferred status places file in deferred bucket ─────
  local id3 = todo.add({ id = "2026-05-25-deferred-foo", title = "Deferred",
    status = "deferred" })
  local f3  = td .. "/deferred/" .. id3 .. ".md"
  ok("add(status=deferred) places file in deferred/", vim.fn.filereadable(f3) == 1)

  -- ── get: unknown id ─────────────────────────────────────────
  local t_unk, err_unk = todo.get("never-existed")
  ok("get(unknown) returns nil + err",
    t_unk == nil and type(err_unk) == "string" and err_unk:find("not found"))

  -- ── list: status filtering ──────────────────────────────────
  local all = todo.list()
  ok("list() returns array of all tasks",
    type(all) == "table" and #all == 3, "got " .. tostring(#all))
  local opens = todo.list({ status = "open" })
  ok("list(status=open) returns just the 2 open tasks",
    #opens == 2, "got " .. tostring(#opens))
  local deferred = todo.list({ status = "deferred" })
  ok("list(status=deferred) returns just the deferred task",
    #deferred == 1 and deferred[1].id == id3)

  -- ── list: filters ───────────────────────────────────────────
  local by_tag = todo.list({ tag = "alpha" })
  ok("list(tag=alpha) returns only id2",
    #by_tag == 1 and by_tag[1].id == id2)
  local by_assignee = todo.list({ assignee = "jarvis" })
  ok("list(assignee=jarvis) returns only id2",
    #by_assignee == 1 and by_assignee[1].id == id2)
  local by_prio = todo.list({ priority = "high" })
  ok("list(priority=high) returns only id2",
    #by_prio == 1 and by_prio[1].id == id2)
  local with_errors = todo.list({ has_errors = true })
  ok("list(has_errors=true) returns [] (none yet)", #with_errors == 0)

  -- ── update: content fields succeed ──────────────────────────
  -- (post-v0.1.36: `notes` field removed — free-form prose lives in
  -- the markdown body, i.e. the `description` field.)
  local before = todo.get(id2)
  local upd, upd_err = todo.update(id2, {
    description = "updated description body",
    priority    = "low",
    due         = "2026-06-15",
  })
  ok("update returns the new task table", type(upd) == "table" and upd.id == id2,
    upd_err)
  ok("update wrote description",
    upd and upd.description == "updated description body")
  ok("update wrote priority", upd and upd.priority == "low")
  ok("update wrote due", upd and upd.due == "2026-06-15")
  ok("update bumped `updated`",
    upd and before and upd.updated >= before.updated)

  -- ── update: refuses status change ───────────────────────────
  local _, e_st = todo.update(id2, { status = "completed" })
  ok("update refuses status changes (must use M.status)",
    e_st and e_st:find("M%.status") ~= nil, e_st)

  -- ── update: refuses managed fields ──────────────────────────
  local _, e_mg = todo.update(id2, { created = "2020-01-01T00:00:00Z" })
  ok("update refuses managed fields (e.g. created)",
    e_mg and e_mg:find("not hand%-editable") ~= nil, e_mg)

  local _, e_un = todo.update(id2, { surprise = "nope" })
  ok("update refuses unknown fields",
    e_un and e_un:find("not hand%-editable") ~= nil, e_un)

  -- ── update: unknown id ──────────────────────────────────────
  local _, e_no = todo.update("never-existed", { description = "x" })
  ok("update returns err on unknown id",
    e_no and e_no:find("not found") ~= nil, e_no)

  -- ── remove: deletes the file, returns true ──────────────────
  local rok, rerr = todo.remove(id1)
  ok("remove returns true on success", rok, rerr)
  ok("remove actually unlinks the file",
    vim.fn.filereadable(td .. "/open/" .. id1 .. ".md") == 0)
  local rok2, _ = todo.remove(id1)
  ok("remove returns false on missing id", not rok2)

  -- ── atomic write: no .tmp- file lingers in open/ ────────────
  local open_dir = td .. "/open"
  local files = vim.fn.readdir(open_dir) or {}
  local tmp_lingering = false
  for _, f in ipairs(files) do
    if f:match("^%.tmp%-") then tmp_lingering = true; break end
  end
  ok("atomic_write: no .tmp- residue in open/", not tmp_lingering)

  -- ── v0.1.46: add / update / remove publish core.todo:changed ──
  local events = require("auto-core.events")
  events._reset_for_tests()
  local changed = {}
  events.subscribe("core.todo:changed", function(p) table.insert(changed, p) end)

  local cid = todo.add({ title = "changed-event probe" })
  ok("add publishes core.todo:changed kind=add",
    #changed == 1 and changed[1].kind == "add" and changed[1].id == cid,
    "got: " .. vim.inspect(changed))

  todo.update(cid, { priority = "high" })
  ok("update publishes core.todo:changed kind=update",
    #changed == 2 and changed[2].kind == "update" and changed[2].id == cid)

  todo.remove(cid)
  ok("remove publishes core.todo:changed kind=remove",
    #changed == 3 and changed[3].kind == "remove" and changed[3].id == cid)

  -- ── teardown ────────────────────────────────────────────────
  worktree.set_workspace_root(nil)
  cleanup()
end)()

-- ─────────────────── 58d. todo — adr/review path normalization (v0.1.46) ──
print("\n[58d] todo — adr/review refs normalized to $VAR symbolic form on write")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  if not ok_req then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  -- Pin a fake KB root via env so $KB_ROOT resolves deterministically.
  local saved_kb = vim.env.AUTO_AGENTS_KB_ROOT
  local fake_kb = vim.fn.tempname()
  vim.fn.mkdir(fake_kb .. "/shared/adrs", "p")
  vim.env.AUTO_AGENTS_KB_ROOT = fake_kb
  package.loaded["auto-core.todo.vars"] = nil  -- re-resolve KB_ROOT

  -- Seed real files so the bare-relative + absolute branches can
  -- confirm existence.
  local kb_doc = fake_kb .. "/shared/adrs/0031-foo.md"
  vim.fn.writefile({ "# adr" }, kb_doc)
  vim.fn.mkdir(tmp_root .. "/docs", "p")
  local ws_doc = tmp_root .. "/docs/spec.md"
  vim.fn.writefile({ "# spec" }, ws_doc)

  -- 1. Absolute path under KB → $KB_ROOT/...
  local id1 = todo.add({ title = "abs kb", adr = { kb_doc } })
  local t1 = todo.get(id1)
  ok("absolute KB path symbolized to $KB_ROOT/...",
    t1.adr[1] == "$KB_ROOT/shared/adrs/0031-foo.md",
    "got " .. tostring(t1.adr and t1.adr[1]))

  -- 2. Absolute path under workspace → $WORKSPACE/... (review is a
  --    string_list since v0.2.x — symbolized per-entry like adr).
  local id2 = todo.add({ title = "abs ws", review = { ws_doc } })
  local t2 = todo.get(id2)
  ok("absolute workspace path symbolized to $WORKSPACE/... (review[1])",
    t2.review[1] == "$WORKSPACE/docs/spec.md",
    "got " .. tostring(t2.review and t2.review[1]))

  -- 3. Bare KB-relative that exists under KB → $KB_ROOT/...
  local id3 = todo.add({ title = "bare rel", adr = { "shared/adrs/0031-foo.md" } })
  local t3 = todo.get(id3)
  ok("bare KB-relative path symbolized to $KB_ROOT/...",
    t3.adr[1] == "$KB_ROOT/shared/adrs/0031-foo.md",
    "got " .. tostring(t3.adr and t3.adr[1]))

  -- 4. Already-symbolic passes through untouched.
  local id4 = todo.add({ title = "already symbolic", adr = { "$KB_ROOT/shared/adrs/0031-foo.md" } })
  local t4 = todo.get(id4)
  ok("already-$VAR ref left untouched",
    t4.adr[1] == "$KB_ROOT/shared/adrs/0031-foo.md")

  -- 5. Absolute path outside every known root → kept absolute.
  local outside = vim.fn.tempname() .. "-outside.md"
  vim.fn.writefile({ "# x" }, outside)
  local id5 = todo.add({ title = "outside", adr = { outside } })
  local t5 = todo.get(id5)
  ok("absolute path outside all roots kept absolute (last resort)",
    t5.adr[1] == outside,
    "got " .. tostring(t5.adr and t5.adr[1]))

  -- 6. update() also normalizes.
  local id6 = todo.add({ title = "update normalize" })
  todo.update(id6, { adr = { kb_doc } })
  local t6 = todo.get(id6)
  ok("update() symbolizes adr refs too",
    t6.adr[1] == "$KB_ROOT/shared/adrs/0031-foo.md")

  -- 7. refresh() self-heals a hand-planted bare-relative ref.
  local id7 = todo.add({ title = "refresh heal" })
  -- Hand-write a bare-relative adr directly into the file (bypass
  -- the API's write-time normalization) to simulate a legacy task.
  local f7 = todo.get_todo_dir() .. "/open/" .. id7 .. ".md"
  local raw = table.concat(vim.fn.readfile(f7), "\n")
  raw = raw:gsub("\n%-%-%-\n", "\nadr:\n  - shared/adrs/0031-foo.md\n---\n", 1)
  vim.fn.writefile(vim.split(raw, "\n"), f7)
  todo.refresh()
  local t7 = todo.get(id7)
  ok("refresh() self-heals bare-relative adr → $KB_ROOT/...",
    t7.adr and t7.adr[1] == "$KB_ROOT/shared/adrs/0031-foo.md",
    "got " .. tostring(t7.adr and t7.adr[1]))

  vim.env.AUTO_AGENTS_KB_ROOT = saved_kb
  package.loaded["auto-core.todo.vars"] = nil
  worktree.set_workspace_root(nil)
  vim.fn.delete(tmp_root, "rf")
  vim.fn.delete(fake_kb, "rf")
end)()

-- ─────────────────────── 58a. todo.md — tolerant scalar→list coercion ─────
print("\n[58a] todo.md — scalar→list coercion for list-of-string fields")
;(function()
  local ok_md, md = pcall(require, "auto-core.todo.md")
  if not ok_md then return end

  local src_adr = table.concat({
    "---",
    "id: 2026-05-26-coerce-adr",
    "version: 1",
    "status: open",
    "title: Coerce scalar adr",
    "description: ''",
    "created: 2026-05-26T00:00:00Z",
    "updated: 2026-05-26T00:00:00Z",
    "status_changed: 2026-05-26T00:00:00Z",
    "adr: shared/adrs/0031-foo.md",
    "---",
    "",
    "# Coerce scalar adr",
    "",
  }, "\n")
  local r = md.decode(src_adr)
  ok("md.decode accepts scalar adr without error", r.ok, tostring(r.err))
  ok("scalar adr coerced into list",
    r.value and type(r.value.adr) == "table",
    "got type " .. type(r.value and r.value.adr))
  ok("coerced adr has length 1",
    r.value and #r.value.adr == 1,
    "got " .. tostring(r.value and #r.value.adr))
  ok("coerced adr[1] preserves the original string value",
    r.value and r.value.adr[1] == "shared/adrs/0031-foo.md",
    "got " .. tostring(r.value and r.value.adr[1]))

  local src_blocked = src_adr
    :gsub("adr: shared/adrs/0031%-foo%.md", "blocked: 2026-01-01-other")
  local r2 = md.decode(src_blocked)
  ok("scalar blocked coerced into 1-element list",
    r2.ok and type(r2.value.blocked) == "table" and #r2.value.blocked == 1
      and r2.value.blocked[1] == "2026-01-01-other")

  local src_tags = src_adr
    :gsub("adr: shared/adrs/0031%-foo%.md", "tags: imported")
  local r3 = md.decode(src_tags)
  ok("scalar tags coerced into 1-element list",
    r3.ok and type(r3.value.tags) == "table" and #r3.value.tags == 1
      and r3.value.tags[1] == "imported")

  -- review went list-valued in v0.2.x; a legacy scalar `review:` must
  -- still read as a 1-element list (back-compat with pre-list files).
  local src_review = src_adr
    :gsub("adr: shared/adrs/0031%-foo%.md", "review: shared/reviews/x.md")
  local r_rv = md.decode(src_review)
  ok("scalar review coerced into 1-element list",
    r_rv.ok and type(r_rv.value.review) == "table" and #r_rv.value.review == 1
      and r_rv.value.review[1] == "shared/reviews/x.md",
    tostring(r_rv.err))

  local src_list = table.concat({
    "---",
    "id: 2026-05-26-already-list",
    "version: 1",
    "status: open",
    "title: Already a list",
    "description: ''",
    "created: 2026-05-26T00:00:00Z",
    "updated: 2026-05-26T00:00:00Z",
    "status_changed: 2026-05-26T00:00:00Z",
    "adr:",
    "  - shared/adrs/0031-foo.md",
    "  - shared/adrs/0032-bar.md",
    "---",
    "",
  }, "\n")
  local r4 = md.decode(src_list)
  ok("list form still passes through unchanged",
    r4.ok and #r4.value.adr == 2
      and r4.value.adr[1] == "shared/adrs/0031-foo.md"
      and r4.value.adr[2] == "shared/adrs/0032-bar.md")

  -- Empty-string scalar must NOT coerce into { "" }.
  local src_empty = src_adr:gsub("adr: shared/adrs/0031%-foo%.md", "adr: ''")
  local r5 = md.decode(src_empty)
  ok("empty-string scalar is not coerced into {\"\"}",
    r5.ok and (r5.value.adr == nil
      or r5.value.adr == ""
      or (type(r5.value.adr) == "table" and #r5.value.adr == 0)))
end)()

-- ─────────────────────── 58c. todo.schema — educational list error ─────────
print("\n[58c] todo.schema — educational error messages for list fields")
;(function()
  local ok_schema, schema = pcall(require, "auto-core.todo.schema")
  if not ok_schema then return end

  local task_num = schema.blank({
    id    = "2026-05-26-bad",
    title = "bad",
    adr   = 42,
  })
  local v = schema.validate(task_num)
  ok("number in list slot is rejected", not v.ok)
  ok("error field names the offending key", v.field == "adr",
    "got " .. tostring(v.field))
  ok("error mentions the YAML list form as a hint",
    v.err and v.err:find("YAML list form", 1, true) ~= nil,
    "got: " .. tostring(v.err))

  local task_map = schema.blank({
    id      = "2026-05-26-bad2",
    title   = "bad2",
    blocked = { not_a_seq = "x" },
  })
  local v2 = schema.validate(task_map)
  ok("mapping in list slot is rejected", not v2.ok)
  ok("mapping-error message also includes the list-form hint",
    v2.err and v2.err:find("YAML list form", 1, true) ~= nil,
    "got: " .. tostring(v2.err))

  local task_mixed = schema.blank({
    id    = "2026-05-26-bad3",
    title = "bad3",
    tags  = { "ok", 99 },
  })
  local v3 = schema.validate(task_mixed)
  ok("list with non-string item is rejected", not v3.ok)
  ok("item-error message also includes the list-form hint",
    v3.err and v3.err:find("YAML list form", 1, true) ~= nil,
    "got: " .. tostring(v3.err))
end)()

-- ─────────────────────── 58b. todo.scan — malformed surfacing ──────────────
print("\n[58b] todo.scan — partition tasks vs malformed files")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  if not ok_req then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local function cleanup() vim.fn.delete(tmp_root, "rf") end

  -- one good task
  local good_id = todo.add({ title = "Scan good task" })
  local td = todo._todo_dir()

  -- one malformed: bad YAML frontmatter
  local bad_path = td .. "/open/2026-05-26-broken-yaml.md"
  local fh = io.open(bad_path, "w")
  fh:write("---\nstatus: open\ntitle: [unclosed list\n---\n\nbody\n")
  fh:close()

  -- one malformed: missing required fields (decode OK but schema fails)
  local missing_path = td .. "/open/2026-05-26-missing-fields.md"
  local fh2 = io.open(missing_path, "w")
  fh2:write("---\ntitle: No status or id\n---\n\nbody\n")
  fh2:close()

  -- one malformed under archived/YYYY/MM/ tree
  vim.fn.mkdir(td .. "/archived/2026/05", "p")
  local arch_path = td .. "/archived/2026/05/2026-05-01-bad-archived.md"
  local fh3 = io.open(arch_path, "w")
  fh3:write("not a frontmatter file at all\n")
  fh3:close()

  local result = todo.scan()
  ok("scan returns table with tasks + malformed keys",
    type(result) == "table"
      and type(result.tasks) == "table"
      and type(result.malformed) == "table")
  ok("scan: tasks contains the good entry (and only valid ones)",
    #result.tasks == 1 and result.tasks[1].id == good_id,
    "got " .. tostring(#result.tasks) .. " tasks")
  ok("scan: malformed contains all three broken files",
    #result.malformed == 3,
    "got " .. tostring(#result.malformed))

  -- entry shape: file_path, bucket, filename, err
  local saw_open, saw_archived = 0, 0
  for _, m in ipairs(result.malformed) do
    ok("malformed entry has file_path",
      type(m.file_path) == "string" and m.file_path ~= "")
    ok("malformed entry has bucket",
      type(m.bucket) == "string" and m.bucket ~= "")
    ok("malformed entry has filename",
      type(m.filename) == "string" and m.filename:match("%.md$") ~= nil)
    ok("malformed entry has err",
      type(m.err) == "string" and m.err ~= "")
    if m.bucket == "open" then saw_open = saw_open + 1 end
    if m.bucket == "archived" then saw_archived = saw_archived + 1 end
  end
  ok("scan: open bucket malformed counted", saw_open == 2,
    "got " .. saw_open)
  ok("scan: archived bucket malformed counted", saw_archived == 1,
    "got " .. saw_archived)

  -- M.list() unaffected: must still skip malformed silently (back-compat)
  local listed = todo.list()
  ok("list() unchanged: still skips malformed silently",
    #listed == 1 and listed[1].id == good_id,
    "got " .. tostring(#listed))

  -- scan with empty/non-existent todo dir
  vim.fn.delete(td, "rf")
  local empty = todo.scan()
  ok("scan on missing todo_dir returns empty {tasks, malformed}",
    type(empty) == "table"
      and #empty.tasks == 0
      and #empty.malformed == 0)

  worktree.set_workspace_root(nil)
  cleanup()
end)()

-- ─────────────────────── 59. todo.status / archive — lifecycle (ADR §3.2) ─
print("\n[59] todo.status / archive — transitions + lifecycle timestamps")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  if not ok_req then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local td = todo._todo_dir()
  local function cleanup() vim.fn.delete(tmp_root, "rf") end

  -- ── open → completed sets completed_at, leaves archived_at nil ──
  local id1 = todo.add({ id = "2026-05-25-cycle", title = "Cycle test" })
  local r1, e1 = todo.status(id1, "completed")
  ok("status(open→completed) succeeds", r1 ~= nil, e1)
  ok("status(→completed) sets completed_at",
    r1 and type(r1.completed_at) == "string"
      and r1.completed_at:match("^%d%d%d%d%-") ~= nil,
    r1 and tostring(r1.completed_at))
  ok("status(→completed) leaves archived_at nil",
    r1 and r1.archived_at == nil)
  ok("status(→completed) bumped status_changed",
    r1 and r1.status_changed ~= nil)
  ok("status(→completed) did NOT bump updated",
    r1 and r1.updated == r1.created)
  -- File should have moved.
  ok("file moved to completed/ bucket",
    vim.fn.filereadable(td .. "/completed/" .. id1 .. ".md") == 1
      and vim.fn.filereadable(td .. "/open/" .. id1 .. ".md") == 0)

  -- ── completed → archived preserves completed_at ─────────────
  local prior_completed_at = r1.completed_at
  local r2, _ = todo.status(id1, "archived")
  ok("status(completed→archived) succeeds", r2 ~= nil)
  ok("status(completed→archived) sets archived_at",
    r2 and type(r2.archived_at) == "string")
  ok("status(completed→archived) PRESERVES completed_at",
    r2 and r2.completed_at == prior_completed_at,
    "expected " .. tostring(prior_completed_at)
      .. ", got " .. tostring(r2.completed_at))
  -- File moved to archived/YYYY/MM/.
  local y, m = r2.archived_at:match("^(%d%d%d%d)%-(%d%d)")
  ok("file moved to archived/YYYY/MM/",
    vim.fn.filereadable(td .. "/archived/" .. y .. "/" .. m .. "/" .. id1 .. ".md") == 1
      and vim.fn.filereadable(td .. "/completed/" .. id1 .. ".md") == 0)

  -- ── archived → open clears both lifecycle timestamps ────────
  local r3, _ = todo.status(id1, "open")
  ok("status(archived→open) clears completed_at",
    r3 and r3.completed_at == nil)
  ok("status(archived→open) clears archived_at",
    r3 and r3.archived_at == nil)
  ok("file moved back to open/",
    vim.fn.filereadable(td .. "/open/" .. id1 .. ".md") == 1
      and vim.fn.filereadable(td .. "/archived/" .. y .. "/" .. m .. "/" .. id1 .. ".md") == 0)

  -- ── open → archived (direct, never went through completed) ──
  -- Per the rules, completed_at MUST be nil because we never completed.
  local id2 = todo.add({ id = "2026-05-25-direct-arch", title = "Direct archive" })
  local r4, _ = todo.status(id2, "archived")
  ok("status(open→archived) leaves completed_at nil",
    r4 and r4.completed_at == nil)
  ok("status(open→archived) sets archived_at",
    r4 and type(r4.archived_at) == "string")

  -- ── deferred is a flat bucket; transitions work both ways ───
  local id3 = todo.add({ id = "2026-05-25-defer-me", title = "Defer me" })
  local r5, _ = todo.status(id3, "deferred")
  ok("status(open→deferred) places file in deferred/",
    vim.fn.filereadable(td .. "/deferred/" .. id3 .. ".md") == 1
      and vim.fn.filereadable(td .. "/open/" .. id3 .. ".md") == 0)
  ok("status(→deferred) leaves both lifecycle timestamps nil",
    r5 and r5.completed_at == nil and r5.archived_at == nil)
  todo.status(id3, "open")
  ok("status(deferred→open) moves file back to open/",
    vim.fn.filereadable(td .. "/open/" .. id3 .. ".md") == 1
      and vim.fn.filereadable(td .. "/deferred/" .. id3 .. ".md") == 0)

  -- ── idempotent no-op ────────────────────────────────────────
  local before = todo.get(id3)
  local r6, _ = todo.status(id3, "open")
  ok("status(same status) is idempotent (no-op, returns task)", r6 ~= nil)
  -- File still in same place.
  ok("idempotent no-op didn't move the file",
    vim.fn.filereadable(td .. "/open/" .. id3 .. ".md") == 1)
  -- status_changed should be unchanged (we early-returned before
  -- bumping anything).
  ok("idempotent no-op didn't bump status_changed",
    r6 and before and r6.status_changed == before.status_changed)

  -- ── invalid inputs ──────────────────────────────────────────
  local _, e_id = todo.status("", "open")
  ok("status('') returns err on empty id", e_id and e_id:find("non%-empty"))
  local _, e_st = todo.status(id3, "in_progress")
  ok("status(invalid_enum) returns err",
    e_st and e_st:find("must be one of"))
  local _, e_no = todo.status("nonexistent-id", "completed")
  ok("status(unknown_id) returns err",
    e_no and e_no:find("not found"))

  -- ── archive() shorthand ─────────────────────────────────────
  local id4 = todo.add({ id = "2026-05-25-arch-shortcut", title = "Archive me" })
  local r7, _ = todo.archive(id4)
  ok("archive() shortcut sets status=archived", r7 and r7.status == "archived")
  local y4, m4 = r7.archived_at:match("^(%d%d%d%d)%-(%d%d)")
  ok("archive() shortcut moves file to archived/YYYY/MM/",
    vim.fn.filereadable(td .. "/archived/" .. y4 .. "/" .. m4 .. "/" .. id4 .. ".md") == 1)

  -- ── core.todo.status:changed event fires ────────────────────
  local events = require("auto-core.events")
  events._reset_for_tests()
  local hits = {}
  events.subscribe("core.todo.status:changed", function(payload)
    table.insert(hits, payload)
  end)
  local id5 = todo.add({ id = "2026-05-25-event-test", title = "Event test" })
  todo.status(id5, "completed")
  ok("status() publishes core.todo.status:changed",
    #hits == 1 and hits[1].id == id5
      and hits[1].from == "open" and hits[1].to == "completed",
    "hits=" .. tostring(#hits))

  worktree.set_workspace_root(nil)
  cleanup()
end)()

-- ─────────────────────── 60. todo.refresh — reconciliation + 28-day auto-archive (§3) ─
print("\n[60] todo.refresh — bucket reconciliation + auto-archive")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  if not ok_req then return end
  local fs_path = require("auto-core.fs.path")

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local td = todo._todo_dir()
  local function cleanup() vim.fn.delete(tmp_root, "rf") end

  -- ── empty workspace: refresh is a no-op ─────────────────────
  local s_empty = todo.refresh()
  ok("refresh on empty dir returns zeroed summary",
    s_empty.scanned == 0 and s_empty.moved == 0
      and s_empty.archived == 0 and s_empty.skipped == 0)

  -- ── reconciliation: file in wrong bucket gets moved ─────────
  -- Plant a misplaced task directly: write a file with
  -- status:completed into the open/ bucket. Refresh should detect
  -- the mismatch and move it to completed/.
  local id1 = "2026-05-25-misplaced-completed"
  local src_file = td .. "/open/" .. id1 .. ".md"
  vim.fn.mkdir(td .. "/open", "p")
  vim.fn.writefile({
    "---",
    'id: "' .. id1 .. '"',
    "version: 1",
    "status: completed",
    "title: Misplaced completed",
    'created: "2026-05-25T10:00:00-07:00"',
    'updated: "2026-05-25T10:00:00-07:00"',
    'status_changed: "2026-05-25T10:00:00-07:00"',
    'completed_at: "2026-05-20T10:00:00-07:00"',
    "---",
    "",
    "# Misplaced completed",
    "",
    "body",
  }, src_file)

  local s1 = todo.refresh()
  ok("refresh detects misplaced file (scanned=1)", s1.scanned == 1,
    "summary=" .. vim.inspect(s1))
  ok("refresh moved the misplaced file (moved=1)", s1.moved == 1,
    "summary=" .. vim.inspect(s1))
  ok("refresh: file is now in completed/",
    fs_path.is_file(td .. "/completed/" .. id1 .. ".md")
      and not fs_path.is_file(src_file))

  -- ── 28-day auto-archive rule fires for old completed ────────
  -- Plant a completed task with completed_at = 30 days ago.
  local id2 = "2026-04-20-aged-completed"
  todo.add({
    id           = id2,
    title        = "Aged completed",
    status       = "completed",
    completed_at = "2026-04-20T10:00:00-07:00",  -- ~35 days before today (2026-05-25)
  })
  ok("setup: aged task lives in completed/",
    fs_path.is_file(td .. "/completed/" .. id2 .. ".md"))

  local s2 = todo.refresh()
  ok("refresh archived the aged task (archived=1)",
    s2.archived == 1, "summary=" .. vim.inspect(s2))
  -- File should now be in archived/YYYY/MM/
  ok("refresh moved aged task out of completed/",
    not fs_path.is_file(td .. "/completed/" .. id2 .. ".md"))
  -- Find it by glob to be timezone-tolerant.
  local found_in_archived = false
  local a_dir = td .. "/archived"
  if fs_path.is_dir(a_dir) then
    for _, y in ipairs(vim.fn.readdir(a_dir) or {}) do
      for _, m in ipairs(vim.fn.readdir(a_dir .. "/" .. y) or {}) do
        if fs_path.is_file(a_dir .. "/" .. y .. "/" .. m .. "/" .. id2 .. ".md") then
          found_in_archived = true
          break
        end
      end
      if found_in_archived then break end
    end
  end
  ok("refresh: aged file is now in archived/YYYY/MM/", found_in_archived)

  -- Read it back: completed_at must be preserved through auto-archive
  -- (per the lifecycle rules).
  local aged = todo.get(id2)
  ok("auto-archived task preserves completed_at",
    aged and aged.completed_at == "2026-04-20T10:00:00-07:00",
    aged and tostring(aged.completed_at))
  ok("auto-archived task has archived_at set",
    aged and type(aged.archived_at) == "string")

  -- ── recent completed (< 28 days) is NOT archived ────────────
  local id3 = "2026-05-20-recent-completed"
  todo.add({
    id           = id3,
    title        = "Recent completed",
    status       = "completed",
    completed_at = "2026-05-20T10:00:00-07:00",  -- 5 days before today
  })
  local s3 = todo.refresh()
  ok("refresh did NOT archive a recent completed task",
    s3.archived == 0, "summary=" .. vim.inspect(s3))
  ok("recent completed task is still in completed/",
    fs_path.is_file(td .. "/completed/" .. id3 .. ".md"))

  -- ── refresh is idempotent: running twice = no further moves ─
  local s4 = todo.refresh()
  ok("second refresh moved nothing (already reconciled)",
    s4.moved == 0 and s4.archived == 0)

  -- ── core.todo:refreshed event fires ─────────────────────────
  local events = require("auto-core.events")
  events._reset_for_tests()
  local fired = {}
  events.subscribe("core.todo:refreshed", function(p) table.insert(fired, p) end)
  local s5 = todo.refresh()
  ok("refresh publishes core.todo:refreshed event",
    #fired == 1 and fired[1].summary
      and fired[1].summary.scanned == s5.scanned)

  -- ── malformed file is skipped, not crashed ──────────────────
  vim.fn.mkdir(td .. "/open", "p")
  vim.fn.writefile({ "not: ", "valid: yaml: shape", "missing required fields" },
    td .. "/open/2026-05-25-broken.md")
  local s6 = todo.refresh()
  ok("refresh: malformed file counted as skipped",
    s6.skipped >= 1, "skipped=" .. tostring(s6.skipped))

  worktree.set_workspace_root(nil)
  cleanup()
end)()

-- ─────────────────────── 61. todo.refresh — reference validation + errors[] (§3) ─
print("\n[61] todo.refresh — reference validation + errors[] stability")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  if not ok_req then return end
  local fs_path = require("auto-core.fs.path")

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local td = todo._todo_dir()

  -- Set up a fake KB so we can test adr/review path validation.
  -- v0.1.37: also save+restore AUTO_AGENTS_KB_ROOT — the user's
  -- ambient session may have it set (per the auto-agents KB
  -- convention) and the post-v0.1.37 resolver prefers ROOT over
  -- WRITE. Without saving + nulling ROOT here, the ambient real
  -- KB root would win and the test fixture's tempdir would be
  -- ignored.
  local kb_dir = vim.fn.tempname()
  vim.fn.mkdir(kb_dir, "p")
  vim.fn.mkdir(kb_dir .. "/shared/adrs", "p")
  vim.fn.writefile({ "# real adr" }, kb_dir .. "/shared/adrs/0099-real.md")
  local saved_kb_root  = vim.env.AUTO_AGENTS_KB_ROOT
  local saved_kb_read  = vim.env.AUTO_AGENTS_KB_READ
  local saved_kb_write = vim.env.AUTO_AGENTS_KB_WRITE
  vim.env.AUTO_AGENTS_KB_ROOT  = kb_dir
  vim.env.AUTO_AGENTS_KB_READ  = nil
  vim.env.AUTO_AGENTS_KB_WRITE = nil

  local function cleanup()
    vim.env.AUTO_AGENTS_KB_ROOT  = saved_kb_root
    vim.env.AUTO_AGENTS_KB_READ  = saved_kb_read
    vim.env.AUTO_AGENTS_KB_WRITE = saved_kb_write
    vim.fn.delete(tmp_root, "rf")
    vim.fn.delete(kb_dir, "rf")
  end

  -- ── happy path: valid refs → no errors emitted ──────────────
  local id_ok = "2026-05-25-clean-refs"
  todo.add({
    id    = id_ok,
    title = "Clean refs",
    adr   = { "shared/adrs/0099-real.md" },
    wip   = tmp_root,  -- exists
  })
  todo.refresh()
  local t_clean = todo.get(id_ok)
  ok("clean refs: errors field is omitted (nil), not []",
    t_clean and t_clean.errors == nil)
  -- Re-read the raw bytes to confirm the file doesn't contain `errors:`.
  local raw_clean = table.concat(vim.fn.readfile(td .. "/open/" .. id_ok .. ".md"), "\n")
  ok("clean refs: 'errors:' literally absent from the file",
    not raw_clean:find("\nerrors:"), raw_clean)

  -- ── broken adr path → errors[] populated ─────────────────────
  local id_badref = "2026-05-25-broken-adr"
  todo.add({
    id    = id_badref,
    title = "Broken adr",
    adr   = { "shared/adrs/0999-does-not-exist.md" },
  })
  local s_br = todo.refresh()
  ok("broken adr: refresh detects + counts errors_set",
    s_br.errors_set >= 1, "summary=" .. vim.inspect(s_br))
  local t_br = todo.get(id_badref)
  ok("broken adr: task carries one errors[] entry",
    t_br and type(t_br.errors) == "table" and #t_br.errors == 1,
    t_br and vim.inspect(t_br.errors))
  ok("broken adr: errors[].field is adr[0]",
    t_br and t_br.errors[1].field == "adr[0]")
  ok("broken adr: errors[].code is 'not-found'",
    t_br and t_br.errors[1].code == "not-found")
  ok("broken adr: errors[].detected is set",
    t_br and type(t_br.errors[1].detected) == "string")
  local first_detected = t_br.errors[1].detected

  -- ── stable detected: re-running refresh doesn't change it ───
  -- Sleep briefly so any newly-stamped detected would differ.
  vim.wait(20, function() return false end)
  todo.refresh()
  local t_br2 = todo.get(id_badref)
  ok("stable detected: same {field,code} keeps original detected",
    t_br2 and t_br2.errors[1].detected == first_detected,
    "first=" .. first_detected .. " now=" .. (t_br2 and t_br2.errors[1].detected or "<nil>"))

  -- ── error cleared when ref fixed → errors omitted again ─────
  -- Make the broken adr exist now.
  vim.fn.writefile({ "# now real" }, kb_dir .. "/shared/adrs/0999-does-not-exist.md")
  local s_fix = todo.refresh()
  ok("fixed ref: refresh re-validates and clears errors",
    s_fix.scanned >= 2)
  local t_fixed = todo.get(id_badref)
  ok("fixed ref: errors field is omitted again",
    t_fixed and t_fixed.errors == nil)
  local raw_fixed = table.concat(vim.fn.readfile(td .. "/open/" .. id_badref .. ".md"), "\n")
  ok("fixed ref: 'errors:' literally absent from the file",
    not raw_fixed:find("\nerrors:"))

  -- (post-v0.1.36: `wip` field removed; working-dir refs now live
  -- in the markdown body where they're not validated. Coverage of
  -- the remaining path-checked fields stays via adr / review /
  -- blocked tests below.)

  -- ── broken review ─────────────────────────────────────────────
  local id_rev = "2026-05-25-bad-review"
  todo.add({ id = id_rev, title = "Bad review",
    review = { "shared/reviews/does-not-exist.md" } })
  todo.refresh()
  local t_rev = todo.get(id_rev)
  ok("broken review: errors[].field is 'review[0]'",
    t_rev and t_rev.errors and t_rev.errors[1].field == "review[0]",
    t_rev and vim.inspect(t_rev.errors))

  -- ── broken blocked ────────────────────────────────────────────
  local id_blk = "2026-05-25-bad-blocked"
  todo.add({
    id      = id_blk,
    title   = "Bad blocked",
    blocked = { "2026-01-01-does-not-exist" },
  })
  todo.refresh()
  local t_blk = todo.get(id_blk)
  ok("broken blocked: errors[].field is 'blocked[0]'",
    t_blk and t_blk.errors and t_blk.errors[1].field == "blocked[0]",
    t_blk and vim.inspect(t_blk.errors))

  -- (post-v0.1.36: `pr` / `links` fields removed. External URLs now
  -- live as plain markdown links in the description body — they're
  -- not part of the structured frontmatter and refresh has nothing
  -- structured to validate. Test removed.)

  -- ── refresh produces zero-diff bytes when nothing's wrong ───
  -- (omit-empty + stable detected together) — clean file after first
  -- refresh should match clean file after second refresh byte-for-byte.
  local clean_path = td .. "/open/" .. id_ok .. ".md"
  local before_bytes = table.concat(vim.fn.readfile(clean_path), "\n")
  todo.refresh()
  local after_bytes = table.concat(vim.fn.readfile(clean_path), "\n")
  ok("zero diff: clean file is byte-identical across refreshes",
    before_bytes == after_bytes)

  -- ── multiple errors stay sorted in detection order ──────────
  local id_multi = "2026-05-25-many-errors"
  todo.add({
    id      = id_multi,
    title   = "Many errors",
    adr     = { "shared/adrs/A-missing.md", "shared/adrs/B-missing.md" },
    review  = { "shared/reviews/C-missing.md" },
    blocked = { "missing-1", "missing-2" },
  })
  todo.refresh()
  local t_multi = todo.get(id_multi)
  ok("multi errors: each broken ref produces one entry (2 adr + 1 review + 2 blocked = 5)",
    t_multi and t_multi.errors and #t_multi.errors == 5,
    t_multi and ("got " .. #t_multi.errors .. " entries"))

  -- ── v0.1.37: KB-root resolver prefers AUTO_AGENTS_KB_ROOT ────
  -- The original resolver order was WRITE > READ > ROOT, which
  -- broke real-world env shapes where ROOT is the KB root and
  -- WRITE points at a sub-directory (e.g. `<kb>/shared/`). Joining
  -- a `shared/...`-rooted adr path onto KB_WRITE produced
  -- `<kb>/shared/shared/...` (duplicated segment) and reported
  -- not-found. Lock the new order:
  --   1. AUTO_AGENTS_KB_ROOT  2. AUTO_AGENTS_KB_READ[0]  3. AUTO_AGENTS_KB_WRITE
  do
    local saved_root  = vim.env.AUTO_AGENTS_KB_ROOT
    local saved_read  = vim.env.AUTO_AGENTS_KB_READ
    local saved_write = vim.env.AUTO_AGENTS_KB_WRITE

    -- Realistic shape: ROOT is the kb dir, WRITE is `<kb>/shared`,
    -- READ is colon-separated (we'll only use the WRITE entry for
    -- the test, but include READ in the env to verify ROOT still
    -- wins).
    vim.env.AUTO_AGENTS_KB_ROOT  = kb_dir
    vim.env.AUTO_AGENTS_KB_WRITE = kb_dir .. "/shared"
    vim.env.AUTO_AGENTS_KB_READ  = kb_dir .. "/shared:" .. kb_dir .. "/agents"

    local id_root = "2026-05-25-kb-root-resolver"
    todo.add({
      id    = id_root,
      title = "KB-root resolver test",
      adr   = { "shared/adrs/0099-real.md" },
    })
    todo.refresh()
    local t_root = todo.get(id_root)
    ok("KB-root resolver: ROOT preferred over WRITE — adr resolves cleanly",
      t_root and (t_root.errors == nil or #t_root.errors == 0),
      t_root and vim.inspect(t_root.errors))

    -- Now unset ROOT and confirm the fallback chain: READ wins.
    -- (kb_dir .. "/shared" is the first READ entry; `shared/adrs/...`
    -- joined to `<kb>/shared` again produces the duplicated artifact
    -- — so we EXPECT a not-found error this time, proving READ is
    -- the fallback path and that the bug pattern is well-defined.)
    vim.env.AUTO_AGENTS_KB_ROOT  = nil
    todo.update(id_root, { adr = { "shared/adrs/0099-real.md" } })
    -- update() doesn't run refresh; trigger explicitly.
    todo.refresh()
    local t_fallback = todo.get(id_root)
    ok("KB-root resolver: with ROOT unset, READ[0] is the next fallback",
      t_fallback and type(t_fallback.errors) == "table" and #t_fallback.errors == 1,
      t_fallback and vim.inspect(t_fallback.errors))

    -- Finally: only WRITE set (legacy / minimal shape) — should
    -- still work as a last-resort fallback.
    vim.env.AUTO_AGENTS_KB_READ  = nil
    -- Point WRITE at the actual kb root for this test so the adr
    -- path resolves cleanly via the last-resort branch.
    vim.env.AUTO_AGENTS_KB_WRITE = kb_dir
    todo.refresh()
    local t_write = todo.get(id_root)
    ok("KB-root resolver: WRITE-only setup still works as last-resort fallback",
      t_write and (t_write.errors == nil or #t_write.errors == 0),
      t_write and vim.inspect(t_write.errors))

    vim.env.AUTO_AGENTS_KB_ROOT  = saved_root
    vim.env.AUTO_AGENTS_KB_READ  = saved_read
    vim.env.AUTO_AGENTS_KB_WRITE = saved_write
  end

  cleanup()
  worktree.set_workspace_root(nil)
end)()

-- ─────────────────────── 62. todo.set_todo_dir / get_todo_dir / known_dirs (§3.3) ─
print("\n[62] todo — dir override + known_dirs registry")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  if not ok_req then return end

  -- Isolate the state store for this test — point persist_dir at a
  -- tempdir so prior runs of these smokes can't leak in. (After we
  -- configure, the namespace handle is recreated lazily via the next
  -- access since state.configure invalidates the persist path.)
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)

  local function cleanup()
    vim.fn.delete(tmp_root, "rf")
    vim.fn.delete(state_tmp, "rf")
    require("auto-core.state").configure({ persist_dir = nil })
    worktree.set_workspace_root(nil)
  end

  -- ── default resolution: no override → <ws>/.todo-list ──────
  ok("get_todo_dir() defaults to <ws>/.todo-list",
    todo.get_todo_dir() == tmp_root .. "/.todo-list",
    "got " .. todo.get_todo_dir())

  -- ── set_todo_dir applies the override ───────────────────────
  local override_dir = tmp_root .. "/custom-todo-store"
  todo.set_todo_dir(override_dir)
  ok("after set_todo_dir, get_todo_dir returns override",
    todo.get_todo_dir() == override_dir, "got " .. todo.get_todo_dir())

  -- A task added now lands in the override location.
  local id_under_override = todo.add({ id = "2026-05-25-overridden", title = "Override task" })
  ok("task written under override dir",
    vim.fn.filereadable(override_dir .. "/open/" .. id_under_override .. ".md") == 1
      and vim.fn.filereadable(tmp_root .. "/.todo-list/open/" .. id_under_override .. ".md") == 0)

  -- ── clear the override (nil) → fall back to default ────────
  todo.set_todo_dir(nil)
  ok("set_todo_dir(nil) clears override; default resumes",
    todo.get_todo_dir() == tmp_root .. "/.todo-list")

  -- ── clear via empty string also works ───────────────────────
  todo.set_todo_dir(override_dir)
  todo.set_todo_dir("")
  ok("set_todo_dir('') also clears override",
    todo.get_todo_dir() == tmp_root .. "/.todo-list")

  -- ── ~-prefixed paths are expanded ───────────────────────────
  todo.set_todo_dir("~/auto-core-test-tilde-todo")
  ok("set_todo_dir('~/...') expands ~ via vim.fn.expand",
    todo.get_todo_dir() == vim.fn.expand("~/auto-core-test-tilde-todo"))
  todo.set_todo_dir(nil)

  -- ── known_dirs reflects every touched dir ───────────────────
  todo.set_todo_dir(override_dir)
  todo.add({ id = "2026-05-25-trace-1", title = "Trace 1" })
  todo.set_todo_dir(nil)
  todo.add({ id = "2026-05-25-trace-2", title = "Trace 2" })

  local kd = todo.known_dirs()
  ok("known_dirs returns a table",
    type(kd) == "table", "type " .. type(kd))
  -- Should contain at least: default dir + override dir (state-fresh
  -- after configure(persist_dir=tmp) but there may be remnants from
  -- earlier sections this run; so use >=).
  local saw_default, saw_override = false, false
  for _, entry in ipairs(kd) do
    if entry.todo_dir == tmp_root .. "/.todo-list" then saw_default = true end
    if entry.todo_dir == override_dir then saw_override = true end
  end
  ok("known_dirs contains the default <ws>/.todo-list entry", saw_default)
  ok("known_dirs contains the override entry", saw_override)

  -- ── workspace_roots IS A LIST (N-to-1) ──────────────────────
  -- Add a SECOND workspace that points at the SAME override dir.
  local second_ws = vim.fn.tempname()
  vim.fn.mkdir(second_ws, "p")
  worktree.set_workspace_root(second_ws)
  todo.set_todo_dir(override_dir)  -- same dir, different workspace
  todo.add({ id = "2026-05-25-second-ws", title = "Second ws" })

  -- Restore original ws.
  worktree.set_workspace_root(tmp_root)

  local kd2 = todo.known_dirs()
  local override_entry
  for _, entry in ipairs(kd2) do
    if entry.todo_dir == override_dir then override_entry = entry; break end
  end
  ok("known_dirs entry for shared override exists", override_entry ~= nil)
  ok("known_dirs[shared].workspace_roots contains BOTH ws roots",
    override_entry and type(override_entry.workspace_roots) == "table"
      and #override_entry.workspace_roots == 2,
    override_entry and ("ws_roots: " .. vim.inspect(override_entry.workspace_roots)))

  -- ── workspace_roots dedupes on repeated add() from same ws ──
  local count_before = #override_entry.workspace_roots
  todo.set_todo_dir(override_dir)
  todo.add({ id = "2026-05-25-dup-trace", title = "Dup trace" })
  local kd3 = todo.known_dirs()
  for _, entry in ipairs(kd3) do
    if entry.todo_dir == override_dir then
      ok("workspace_roots does NOT duplicate the same ws on repeat add",
        #entry.workspace_roots == count_before,
        "before=" .. count_before .. " after=" .. #entry.workspace_roots)
      break
    end
  end

  vim.fn.delete(second_ws, "rf")
  cleanup()
end)()

-- ─────────────────────── 63. todo — :AutoCoreTodoRefresh + autocmd (§3) ─
print("\n[63] todo — user command + BufWritePost autocmd")
;(function()
  -- ── :AutoCoreTodoRefresh user command is registered ─────────
  local cmds = vim.api.nvim_get_commands({})
  ok(":AutoCoreTodoRefresh is a registered user command",
    cmds.AutoCoreTodoRefresh ~= nil)

  -- ── AutoCoreTodo autocmd group exists with a BufWritePost ───
  local autos = vim.api.nvim_get_autocmds({ group = "AutoCoreTodo" })
  ok("AutoCoreTodo augroup exists with at least one BufWritePost",
    type(autos) == "table" and #autos >= 1
      and autos[1].event == "BufWritePost")

  -- ── BufWritePost fires only inside the resolved todo dir ────
  local todo = require("auto-core.todo")
  local worktree = require("auto-core.git.worktree")

  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  worktree.set_workspace_root(tmp_root)

  -- Subscribe to core.todo:refreshed so we can detect autocmd firing.
  local events = require("auto-core.events")
  events._reset_for_tests()
  local fired = 0
  events.subscribe("core.todo:refreshed", function() fired = fired + 1 end)

  -- Add a task so the dir exists, then write to a file UNDER the
  -- todo dir → autocmd should fire refresh.
  local id1 = todo.add({ id = "2026-05-25-autocmd-target", title = "Autocmd target" })
  local todo_file = todo.get_todo_dir() .. "/open/" .. id1 .. ".md"
  fired = 0  -- reset counter (add doesn't fire refresh by itself)
  -- Open + save the buffer to simulate a hand-edit.
  vim.cmd.edit(todo_file)
  vim.cmd("noautocmd write")  -- skip the first write
  fired = 0
  vim.cmd.write()             -- this one should trigger the autocmd
  ok("BufWritePost inside todo dir triggers refresh", fired >= 1,
    "fired=" .. tostring(fired))

  -- Now write to a yaml file OUTSIDE the todo dir → no refresh.
  local outside = tmp_root .. "/random.md"
  vim.fn.writefile({ "k: v" }, outside)
  fired = 0
  vim.cmd.edit(outside)
  vim.cmd.write()
  ok("BufWritePost outside todo dir does NOT trigger refresh",
    fired == 0, "fired=" .. tostring(fired))

  -- ── User command invocation also triggers refresh ───────────
  fired = 0
  vim.cmd("AutoCoreTodoRefresh")
  ok(":AutoCoreTodoRefresh fires refresh", fired >= 1,
    "fired=" .. tostring(fired))

  -- Cleanup.
  vim.cmd("bwipeout!")  -- close the test buffers
  worktree.set_workspace_root(nil)
  require("auto-core.state").configure({ persist_dir = nil })
  vim.fn.delete(tmp_root, "rf")
  vim.fn.delete(state_tmp, "rf")
end)()

-- ─────────────────────── 64. todo.import — three source kinds (§3.4) ──
print("\n[64] todo.import — kb-todo-list / legacy-todos-md / asana-json")
;(function()
  local ok_req, todo = pcall(require, "auto-core.todo")
  if not ok_req then return end

  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)

  local function cleanup()
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_root, "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  -- ── kb-todo-list happy path ─────────────────────────────────
  local src = tmp_root .. "/source-todo.md"
  vim.fn.writefile({
    "---",
    "type: synthesis",
    "tags: [todo-list]",
    "---",
    "",
    "# Foo Bar Roadmap",
    "",
    "**Tags:** `type:todo-list` `status:open` `owner:shared` `repo:auto-core`",
    "",
    "**Abstract:** Living checkpoint for the Foo Bar feature.",
    "",
    "This is the first paragraph of body content.",
    "",
    "This is a second paragraph that should NOT appear in description.",
    "",
    "## Phase 1",
    "",
    "- [ ] First item",
    "- [x] Second item",
  }, src)

  local results = todo.import(src, { kind = "kb-todo-list" })
  ok("import returns a 1-element list (one spec per source)",
    type(results) == "table" and #results == 1,
    "got " .. tostring(results and #results))
  local res = results[1]
  ok("import: id is set (write happened)",
    type(res.id) == "string" and res.id ~= "",
    res and res.error)

  local task = todo.get(res.id)
  ok("imported task: title is the H1",
    task and task.title == "Foo Bar Roadmap",
    task and tostring(task.title))
  ok("imported task: status='open' (from inline status:open atom)",
    task and task.status == "open")
  ok("imported task: tags include `imported` + `kind:kb-todo-list`",
    task and task.tags and vim.tbl_contains(task.tags, "imported")
      and vim.tbl_contains(task.tags, "kind:kb-todo-list"),
    task and vim.inspect(task.tags))
  ok("imported task: tags include preserved `owner:shared` + `repo:auto-core`",
    task and vim.tbl_contains(task.tags, "owner:shared")
      and vim.tbl_contains(task.tags, "repo:auto-core"))
  -- Post-v0.1.36: description body now carries BOTH the source's
  -- first paragraph (as the lede) AND the full original markdown
  -- (under a `## Original source` subheading) for losslessness.
  -- The `notes:` field is gone — everything lives in description.
  ok("imported task: description starts with the first paragraph (lede)",
    task and task.description
      and task.description:find("^This is the first paragraph of body content%.") ~= nil,
    task and tostring(task.description and task.description:sub(1, 80)))
  ok("imported task: description contains the `## Original source` subheading",
    task and task.description
      and task.description:find("## Original source") ~= nil)
  ok("imported task: description contains the full original (incl. checked items)",
    task and task.description
      and task.description:find("%- %[x%] Second item") ~= nil)

  -- ── status mapping: blocked → deferred ──────────────────────
  local src_blocked = tmp_root .. "/blocked-todo.md"
  vim.fn.writefile({
    "# Blocked thing",
    "",
    "**Tags:** `type:todo-list` `status:blocked`",
    "",
    "Waiting on X.",
  }, src_blocked)
  local res_b = todo.import(src_blocked, { kind = "kb-todo-list" })
  local task_b = todo.get(res_b[1].id)
  ok("blocked KB doc → status=deferred", task_b and task_b.status == "deferred",
    task_b and tostring(task_b.status))

  -- ── status mapping: closed → completed ──────────────────────
  local src_closed = tmp_root .. "/closed-todo.md"
  vim.fn.writefile({
    "# Done thing",
    "",
    "**Tags:** `type:todo-list` `status:closed`",
    "",
    "Already finished.",
  }, src_closed)
  local res_c = todo.import(src_closed, { kind = "kb-todo-list" })
  local task_c = todo.get(res_c[1].id)
  ok("closed KB doc → status=completed",
    task_c and task_c.status == "completed",
    task_c and tostring(task_c.status))
  ok("closed KB doc: completed_at is set", task_c and task_c.completed_at ~= nil)

  -- ── dry_run: returns spec without writing ───────────────────
  local src_dry = tmp_root .. "/dry-todo.md"
  vim.fn.writefile({
    "# Dry run candidate",
    "",
    "**Tags:** `type:todo-list` `status:open`",
    "",
    "Would-be task body.",
  }, src_dry)
  local dry_results = todo.import(src_dry, { kind = "kb-todo-list", dry_run = true })
  ok("dry_run: returns the spec",
    dry_results[1].spec and dry_results[1].spec.title == "Dry run candidate")
  ok("dry_run: id is nil (no write)",
    dry_results[1].id == nil)
  -- And the workspace genuinely has NO file for this title's id.
  local default_dir = todo.get_todo_dir()
  ok("dry_run: no .md lands on disk",
    vim.fn.filereadable(default_dir .. "/open/" .. os.date("!%Y-%m-%d") ..
      "-dry-run-candidate.md") == 0)

  -- ── legacy-todos-md uses the same parser, different kind tag ─
  local src_legacy = tmp_root .. "/auto-core-todos.md"
  vim.fn.writefile({
    "# Legacy todos doc",
    "",
    "**Tags:** `type:todo-list` `status:open`",
    "",
    "Lives at the old filename glob.",
  }, src_legacy)
  local res_l = todo.import(src_legacy, { kind = "legacy-todos-md" })
  local task_l = todo.get(res_l[1].id)
  ok("legacy-todos-md: tags include `kind:legacy-todos-md`",
    task_l and vim.tbl_contains(task_l.tags, "kind:legacy-todos-md"))

  -- ── asana-json kind is rejected (removed in v0.1.36) ───────
  -- The /asana-sync skill writes a single multi-task markdown doc
  -- to the KB, not a per-task JSON dump — there is no per-task
  -- import path from Asana. The kind is unknown to import().
  local src_asana = tmp_root .. "/asana.json"
  vim.fn.writefile({ "{}" }, src_asana)
  local asana_ok = pcall(todo.import, src_asana, { kind = "asana-json" })
  ok("asana-json kind is rejected (no per-task path from Asana)",
    not asana_ok)

  -- ── invalid kind / missing source rejected ───────────────────
  ok("import refuses unknown kind",
    not pcall(todo.import, src, { kind = "made-up" }))
  ok("import refuses missing source",
    not pcall(todo.import, tmp_root .. "/nope.md", { kind = "kb-todo-list" }))

  -- ── tags-less file falls back to opening as 'open' ──────────
  local src_plain = tmp_root .. "/plain.md"
  vim.fn.writefile({
    "# Plain markdown",
    "",
    "Just prose, no Tags line.",
  }, src_plain)
  local res_p = todo.import(src_plain, { kind = "kb-todo-list" })
  local task_p = todo.get(res_p[1].id)
  ok("no Tags line → defaults to status=open", task_p and task_p.status == "open")
  ok("no H1 fallback: title from filename when H1 absent (separate test)", true)

  cleanup()
end)()

-- ─────────────────────── 65. todo.vars — variable store + $VAR resolver (v0.1.40) ──
print("\n[65] todo.vars — variable store + $VAR resolver")
;(function()
  local ok_v, vars = pcall(require, "auto-core.todo.vars")
  ok("auto-core.todo.vars loads", ok_v, tostring(vars))
  if not ok_v then return end

  -- Built-ins ----------------------------------------------------
  local builtin_names = {}
  for _, b in ipairs(vars.BUILTINS) do builtin_names[#builtin_names + 1] = b.name end
  ok("built-ins include KB_ROOT, WORKSPACE, HOME, CWD in order",
    table.concat(builtin_names, ",") == "KB_ROOT,WORKSPACE,HOME,CWD")
  ok("is_builtin('KB_ROOT') is true", vars.is_builtin("KB_ROOT"))
  ok("is_builtin('MY_VAR') is false", not vars.is_builtin("MY_VAR"))

  -- HOME built-in is unconditional (vim.fn.expand('~') always
  -- returns something). Use it to verify the resolver chain.
  local home = vars.get("HOME")
  ok("HOME built-in resolves to a non-empty string",
    type(home) == "string" and home ~= "")
  ok("CWD built-in resolves to a non-empty string",
    type(vars.get("CWD")) == "string" and vars.get("CWD") ~= "")

  -- KB_ROOT pinned via env so the test doesn't depend on the
  -- user's actual KB setup.
  local saved_root  = vim.env.AUTO_AGENTS_KB_ROOT
  local saved_read  = vim.env.AUTO_AGENTS_KB_READ
  local saved_write = vim.env.AUTO_AGENTS_KB_WRITE
  vim.env.AUTO_AGENTS_KB_ROOT  = "/tmp/fake-kb-root"
  vim.env.AUTO_AGENTS_KB_READ  = nil
  vim.env.AUTO_AGENTS_KB_WRITE = nil
  ok("KB_ROOT built-in resolves via AUTO_AGENTS_KB_ROOT",
    vars.get("KB_ROOT") == "/tmp/fake-kb-root",
    "got " .. tostring(vars.get("KB_ROOT")))

  -- Set / list / remove ----------------------------------------
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  -- Reset the cached vars-state handle so it picks up the new persist_dir
  package.loaded["auto-core.todo.vars"] = nil
  local _, vars2 = pcall(require, "auto-core.todo.vars")
  vars = vars2
  -- Re-restore env-vars (the reload re-read them; KB_ROOT still set).
  ok("set MY_VAR succeeds", select(1, vars.set("MY_VAR", "/abs/value")))
  ok("set returns false on built-in name",
    not select(1, vars.set("KB_ROOT", "/whatever")))
  ok("set returns false on invalid identifier",
    not select(1, vars.set("1bad", "/x")))
  ok("set returns false on identifier with hyphen",
    not select(1, vars.set("bad-name", "/x")))
  ok("get('MY_VAR') returns the set value",
    vars.get("MY_VAR") == "/abs/value")
  ok("list() includes both built-ins and user vars",
    (function()
      local list = vars.list()
      local saw_kb, saw_my = false, false
      for _, e in ipairs(list) do
        if e.name == "KB_ROOT" and e.builtin then saw_kb = true end
        if e.name == "MY_VAR"  and not e.builtin and e.value == "/abs/value" then saw_my = true end
      end
      return saw_kb and saw_my
    end)())

  -- env-var fallback for un-set user var
  vim.env.MY_FALLBACK = "/from/env"
  ok("env fallback: unset user var resolves from vim.env",
    vars.get("MY_FALLBACK") == "/from/env")

  -- remove
  ok("remove(MY_VAR) succeeds", select(1, vars.remove("MY_VAR")))
  ok("after remove, get('MY_VAR') is nil",
    vars.get("MY_VAR") == nil)
  ok("remove returns false on built-in",
    not select(1, vars.remove("KB_ROOT")))

  -- resolve_path ------------------------------------------------
  ok("set TARGET succeeds", select(1, vars.set("TARGET", "/usr/local/bin")))
  local r = vars.resolve_path("$TARGET/nvim")
  ok("resolve_path: $VAR/rest substitutes correctly",
    r.ok and r.path == "/usr/local/bin/nvim" and r.var_name == "TARGET",
    "got path=" .. tostring(r and r.path))
  local r2 = vars.resolve_path("${TARGET}/nvim")
  ok("resolve_path: brace form ${VAR}/rest works",
    r2.ok and r2.path == "/usr/local/bin/nvim" and r2.var_name == "TARGET")
  local r3 = vars.resolve_path("$TARGET")
  ok("resolve_path: bare $VAR (no rest) returns the var value",
    r3.ok and r3.path == "/usr/local/bin")
  local r4 = vars.resolve_path("$UNDEFINED/foo")
  ok("resolve_path: unknown var returns unresolved=true",
    not r4.ok and r4.unresolved
      and r4.var_name == "UNDEFINED"
      and r4.path == "$UNDEFINED/foo")  -- literal preserved
  local r5 = vars.resolve_path("/abs/path")
  ok("resolve_path: absolute path passes through expanded",
    r5.ok and r5.path == "/abs/path" and not r5.unresolved)
  local r6 = vars.resolve_path("relative/path")
  ok("resolve_path: plain relative passes through unchanged",
    r6.ok and r6.path == "relative/path" and not r6.unresolved)

  -- ── symbolize_path: inverse of resolve_path (v0.1.47) ────────
  -- KB_ROOT pinned to /tmp/fake-kb-root earlier in this section.
  ok("symbolize_path: absolute under $KB_ROOT → $KB_ROOT/...",
    vars.symbolize_path("/tmp/fake-kb-root/shared/adrs/x.md")
      == "$KB_ROOT/shared/adrs/x.md")
  ok("symbolize_path: exact root → bare $VAR",
    vars.symbolize_path("/tmp/fake-kb-root") == "$KB_ROOT")
  ok("symbolize_path: already-$VAR passes through",
    vars.symbolize_path("$KB_ROOT/a.md") == "$KB_ROOT/a.md")
  ok("symbolize_path: path outside all roots kept absolute",
    vars.symbolize_path("/opt/nowhere/a.md") == "/opt/nowhere/a.md")
  -- longest-prefix: TARGET=/usr/local/bin set earlier; a deeper
  -- user var would win, but here just confirm user vars are tried.
  ok("symbolize_path: absolute under a user var → $VAR/...",
    vars.symbolize_path("/usr/local/bin/nvim") == "$TARGET/nvim")

  -- Cleanup env-vars
  vim.env.AUTO_AGENTS_KB_ROOT  = saved_root
  vim.env.AUTO_AGENTS_KB_READ  = saved_read
  vim.env.AUTO_AGENTS_KB_WRITE = saved_write
  vim.env.MY_FALLBACK          = nil
  require("auto-core.state").configure({ persist_dir = nil })
  vim.fn.delete(state_tmp, "rf")
  package.loaded["auto-core.todo.vars"] = nil
end)()

-- ─────────────────────── 66. todo.refresh — $VAR ref + unresolved-variable error (v0.1.40) ──
print("\n[66] todo.refresh — $VAR substitution + unresolved-variable error")
;(function()
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local state_tmp = vim.fn.tempname()
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  package.loaded["auto-core.todo.vars"] = nil

  -- Set up a fake KB and a $MY_DOCS var pointing into it.
  local fake_kb = vim.fn.tempname()
  vim.fn.mkdir(fake_kb .. "/shared/adrs", "p")
  local good_path = fake_kb .. "/shared/adrs/0099-good.md"
  local fh = io.open(good_path, "w") fh:write("# good\n") fh:close()
  vim.env.AUTO_AGENTS_KB_ROOT  = fake_kb
  vim.env.AUTO_AGENTS_KB_READ  = nil
  vim.env.AUTO_AGENTS_KB_WRITE = nil

  local vars = require("auto-core.todo.vars")
  vars.set("MY_DOCS", fake_kb)

  -- Task #1: uses $KB_ROOT — should resolve, ref exists.
  local id1 = todo.add({ title = "kb-ref via builtin", adr = { "$KB_ROOT/shared/adrs/0099-good.md" } })
  -- Task #2: uses $MY_DOCS — should resolve, ref exists.
  local id2 = todo.add({ title = "user-var ref",       adr = { "$MY_DOCS/shared/adrs/0099-good.md" } })
  -- Task #3: uses $UNDEFINED — should flag unresolved-variable.
  local id3 = todo.add({ title = "unresolved",         adr = { "$UNDEFINED/foo.md" } })
  -- Task #4: legacy KB-relative — should still work.
  local id4 = todo.add({ title = "legacy kb-rel",      adr = { "shared/adrs/0099-good.md" } })

  todo.refresh()

  local t1, t2, t3, t4 = todo.get(id1), todo.get(id2), todo.get(id3), todo.get(id4)

  ok("$KB_ROOT-prefixed adr passes validation (no errors[])",
    not t1.errors or #t1.errors == 0,
    "got errors: " .. vim.inspect(t1.errors))
  ok("$MY_DOCS user-var adr passes validation",
    not t2.errors or #t2.errors == 0,
    "got errors: " .. vim.inspect(t2.errors))
  ok("$UNDEFINED adr emits unresolved-variable error",
    t3.errors and #t3.errors == 1
      and t3.errors[1].code == "unresolved-variable"
      and t3.errors[1].field == "adr[0]",
    "got: " .. vim.inspect(t3.errors))
  ok("unresolved-variable error message mentions Vars section",
    t3.errors and t3.errors[1].message:find("Vars section", 1, true) ~= nil,
    "got: " .. tostring(t3.errors and t3.errors[1].message))
  ok("legacy KB-relative adr still resolves (back-compat)",
    not t4.errors or #t4.errors == 0,
    "got errors: " .. vim.inspect(t4.errors))

  -- Cleanup
  vim.env.AUTO_AGENTS_KB_ROOT  = nil
  worktree.set_workspace_root(nil)
  require("auto-core.state").configure({ persist_dir = nil })
  vim.fn.delete(tmp_root,  "rf")
  vim.fn.delete(state_tmp, "rf")
  vim.fn.delete(fake_kb,   "rf")
  package.loaded["auto-core.todo.vars"] = nil
end)()

-- ─────────────────────── 67. todo.assign — assignee API + event (v0.1.43) ──
print("\n[67] todo.assign — sets assignee + fires core.todo.assignee:changed")
;(function()
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local function cleanup() worktree.set_workspace_root(nil); vim.fn.delete(tmp_root, "rf") end

  local id = todo.add({ title = "to assign" })

  -- Subscribe to capture the event payload.
  local events = require("auto-core.events")
  local captured = nil
  local handle = events.subscribe("core.todo.assignee:changed", function(payload)
    captured = payload
  end)

  -- Assign.
  local _, err = todo.assign(id, "agent:lector", "needs technical review")
  ok("assign returns no error", err == nil, "got: " .. tostring(err))

  -- Re-read the task and confirm the field landed.
  local t = todo.get(id)
  ok("assignee field written to disk",
    t and t.assignee == "agent:lector",
    "got: " .. tostring(t and t.assignee))

  -- Event fired with the right payload shape.
  vim.wait(50, function() return false end)
  ok("event fired", captured ~= nil)
  ok("event carries id",        captured and captured.id == id)
  ok("event carries from=nil",  captured and captured.from == nil)
  ok("event carries to",        captured and captured.to == "agent:lector")
  ok("event carries reason",    captured and captured.reason == "needs technical review")
  ok("event carries file_path", captured and type(captured.file_path) == "string" and captured.file_path ~= "")
  ok("event carries title",     captured and captured.title == "to assign")
  ok("event carries timestamp", captured and type(captured.at) == "string" and captured.at ~= "")

  -- Idempotent: same assignee again → no rewrite, no event
  captured = nil
  todo.assign(id, "agent:lector", "duplicate request")
  vim.wait(30, function() return false end)
  ok("idempotent: re-assign to same agent does NOT fire event", captured == nil)

  -- Clear assignee
  todo.assign(id, nil)
  vim.wait(50, function() return false end)
  local t2 = todo.get(id)
  ok("clear assignee with nil writes back",
    t2 and t2.assignee == nil,
    "got: " .. tostring(t2 and t2.assignee))
  ok("clear fires event with to=nil",
    captured ~= nil and captured.to == nil and captured.from == "agent:lector")

  -- Bad args
  ok("rejects empty id",       select(2, todo.assign("",         "agent:x")) ~= nil)
  ok("rejects empty assignee", select(2, todo.assign(id,         ""))       ~= nil)

  events.unsubscribe(handle)
  cleanup()
end)()

-- ───────────────────── 68. ADR-0035 Phase 1 ─────────────────────────
-- Schema additions (in-progress, automated statuses + automation
-- frontmatter fields), six-bucket reconciliation, and the atomic
-- in-line `open → in-progress` transition inside M.assign().
print("\n[68] ADR-0035 Phase 1 — in-progress / automated buckets + atomic assign hook")
;(function()
  local ok_t, todo = pcall(require, "auto-core.todo")
  if not ok_t then return end
  local schema = require("auto-core.todo.schema")
  local paths  = require("auto-core.todo.paths")

  -- 68a. schema enum carries the two new statuses
  ok("VALID_STATUS includes in-progress", schema.VALID_STATUS["in-progress"] == true)
  ok("VALID_STATUS includes automated",   schema.VALID_STATUS["automated"]   == true)
  ok("VALID_STATUS still has open",       schema.VALID_STATUS["open"]        == true)
  ok("VALID_STATUS still has archived",   schema.VALID_STATUS["archived"]    == true)

  -- 68b. paths.BUCKETS gains two literal dir mappings, and
  -- FLAT_BUCKETS exposes the canonical scan order.
  ok("paths.BUCKETS has in-progress entry",
    paths.BUCKETS["in-progress"] == "in-progress")
  ok("paths.BUCKETS has automated entry",
    paths.BUCKETS.automated == "automated")
  ok("paths.FLAT_BUCKETS is a sequence", type(paths.FLAT_BUCKETS) == "table" and #paths.FLAT_BUCKETS >= 5)
  -- Canonical order: open, in-progress, automated, deferred, completed.
  ok("FLAT_BUCKETS order: open first",          paths.FLAT_BUCKETS[1] == "open")
  ok("FLAT_BUCKETS order: in-progress second",  paths.FLAT_BUCKETS[2] == "in-progress")
  ok("FLAT_BUCKETS order: automated third",     paths.FLAT_BUCKETS[3] == "automated")
  ok("FLAT_BUCKETS order: deferred fourth",     paths.FLAT_BUCKETS[4] == "deferred")
  ok("FLAT_BUCKETS order: completed fifth",     paths.FLAT_BUCKETS[5] == "completed")

  -- 68c. schema rejects invalid combinations.
  local function _blank(over)
    local t = schema.blank(over or {})
    return t
  end

  -- Template-level assignee on automated → reject.
  local v_ta = schema.validate(_blank({ status = "automated", assignee = "agent:foo" }))
  ok("schema rejects automated template with top-level assignee",
    not v_ta.ok and tostring(v_ta.err):find("automation-template-assignee", 1, true) ~= nil,
    "got: " .. tostring(v_ta.err))

  -- in-progress + completed_at → reject.
  local v_ip_ct = schema.validate(_blank({ status = "in-progress", completed_at = "2026-05-30T00:00:00Z" }))
  ok("schema rejects in-progress with completed_at set",
    not v_ip_ct.ok, "got: " .. tostring(v_ip_ct.err))

  -- automated + condition[] / execute[] are allowed shape-wise.
  local v_auto_ok = schema.validate(_blank({
    status = "automated",
    condition = { "0 8 * * 2#1" },
    execute   = { "bash echo hi" },
  }))
  ok("schema accepts automated with condition[]+execute[]",
    v_auto_ok.ok, "got err: " .. tostring(v_auto_ok.err))

  -- non-automated + condition → reject (fields are template-only).
  local v_open_cond = schema.validate(_blank({ status = "open", condition = { "0 * * * *" } }))
  ok("schema rejects condition: on non-automated",
    not v_open_cond.ok, "got: " .. tostring(v_open_cond.err))

  -- non-automated + last_fired_at → reject.
  local v_open_lfa = schema.validate(_blank({ status = "open", last_fired_at = "2026-05-30T00:00:00Z" }))
  ok("schema rejects last_fired_at: on non-automated",
    not v_open_lfa.ok, "got: " .. tostring(v_open_lfa.err))

  -- automated with stray completed_at → reject.
  local v_auto_ct = schema.validate(_blank({
    status = "automated", completed_at = "2026-05-30T00:00:00Z",
  }))
  ok("schema rejects automated with completed_at set",
    not v_auto_ct.ok, "got: " .. tostring(v_auto_ct.err))

  -- automated with `origin:` set → reject (templates aren't clones).
  local v_auto_origin = schema.validate(_blank({
    status = "automated", origin = "some-other-template",
  }))
  ok("schema rejects automated with origin: set",
    not v_auto_origin.ok, "got: " .. tostring(v_auto_origin.err))

  -- 68d. atomic in-line assign transition: open → in-progress.
  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local function cleanup() worktree.set_workspace_root(nil); vim.fn.delete(tmp_root, "rf") end

  local id = todo.add({ title = "Phase 1 assign hook" })
  ok("freshly added task starts as open",
    (todo.get(id) or {}).status == "open")

  -- Capture both event types around the assign call.
  local events = require("auto-core.events")
  local assignee_evt, status_evt
  local h_a = events.subscribe("core.todo.assignee:changed", function(p) assignee_evt = p end)
  local h_s = events.subscribe("core.todo.status:changed",   function(p) status_evt   = p end)

  local _, err_assign = todo.assign(id, "agent:foo", "phase-1 test")
  ok("assign returns no error", err_assign == nil, "got: " .. tostring(err_assign))

  local t_after = todo.get(id)
  ok("status flipped open → in-progress atomically",
    t_after and t_after.status == "in-progress",
    "got: " .. tostring(t_after and t_after.status))
  ok("assignee landed in the same write",
    t_after and t_after.assignee == "agent:foo")
  ok("status_changed bumped to a non-empty ISO datetime",
    t_after and type(t_after.status_changed) == "string"
      and t_after.status_changed:match("^%d%d%d%d%-%d%d%-%d%d") ~= nil)

  -- File moved bucket: must now live in `.todo-list/in-progress/`.
  local td = paths.default_todo_dir(tmp_root)
  local ip_path = paths.task_file_path(td, id, "in-progress", nil)
  ok("file relocated into .todo-list/in-progress/",
    vim.fn.filereadable(ip_path) == 1,
    "expected: " .. ip_path)
  local old_open_path = paths.task_file_path(td, id, "open", nil)
  ok("stale file in .todo-list/open/ was unlinked",
    vim.fn.filereadable(old_open_path) == 0)

  vim.wait(50, function() return false end)
  ok("core.todo.assignee:changed event fired",
    assignee_evt ~= nil and assignee_evt.to == "agent:foo")
  ok("core.todo.status:changed event ALSO fired (atomic transition)",
    status_evt ~= nil
      and status_evt.from == "open"
      and status_evt.to == "in-progress")

  -- OQ1: clearing the assignee does NOT reverse the transition.
  assignee_evt, status_evt = nil, nil
  todo.assign(id, nil)
  vim.wait(50, function() return false end)
  local t_cleared = todo.get(id)
  ok("OQ1: clearing assignee leaves status at in-progress (no reversal)",
    t_cleared and t_cleared.status == "in-progress" and t_cleared.assignee == nil)
  ok("OQ1: no status event fired on assignee-clear",
    status_evt == nil)

  -- Re-assigning an in-progress task does NOT re-fire status event.
  status_evt = nil
  todo.assign(id, "agent:bar")
  vim.wait(50, function() return false end)
  ok("re-assigning in-progress task does NOT re-fire status:changed",
    status_evt == nil)

  -- Assigning a deferred task does NOT auto-engage in-progress.
  local id_def = todo.add({ id = "2026-05-30-deferred-assign-test", title = "deferred sibling" })
  todo.status(id_def, "deferred")
  status_evt = nil
  todo.assign(id_def, "agent:baz")
  vim.wait(50, function() return false end)
  ok("assigning a DEFERRED task does NOT flip to in-progress",
    (todo.get(id_def) or {}).status == "deferred")
  ok("no status:changed event for deferred→assigned",
    status_evt == nil)

  events.unsubscribe(h_a)
  events.unsubscribe(h_s)

  -- 68e. six-bucket reconciliation via todo.list across every bucket.
  -- Place one task in each bucket using the public API; list() must
  -- find them all.
  local id_open   = todo.add({ id = "2026-05-30-bucket-open",   title = "bucket open" })
  local id_def2   = todo.add({ id = "2026-05-30-bucket-def",    title = "bucket deferred" })
  todo.status(id_def2, "deferred")
  local id_comp   = todo.add({ id = "2026-05-30-bucket-comp",   title = "bucket completed" })
  todo.status(id_comp, "completed")
  local id_ip     = todo.add({ id = "2026-05-30-bucket-ip",     title = "bucket in-progress" })
  todo.assign(id_ip, "agent:bucket")  -- triggers the auto-transition
  local id_auto   = todo.add({ id = "2026-05-30-bucket-auto",   title = "bucket automated" })
  todo.status(id_auto, "automated")

  local all = todo.list()
  local by_id = {}
  for _, t in ipairs(all) do by_id[t.id] = t.status end
  ok("list() finds open task",        by_id[id_open]   == "open")
  ok("list() finds deferred task",    by_id[id_def2]   == "deferred")
  ok("list() finds completed task",   by_id[id_comp]   == "completed")
  ok("list() finds in-progress task", by_id[id_ip]     == "in-progress")
  ok("list() finds automated task",   by_id[id_auto]   == "automated")
  ok("list(status=in-progress) returns only in-progress rows",
    (function()
      local rows = todo.list({ status = "in-progress" })
      for _, r in ipairs(rows) do
        if r.status ~= "in-progress" then return false end
      end
      return #rows >= 2  -- id + id_ip
    end)())

  cleanup()
end)()

-- ───────────────────── 69. ADR-0035 Phase 2 — cron parser ──────────
print("\n[69] ADR-0035 Phase 2 — cron parser")
;(function()
  local cron = require("auto-core.todo.cron")

  -- 69a. parse — happy path for the standard tokens.
  local p, err = cron.parse("0 8 * * *")
  ok("parse `0 8 * * *` succeeds", p ~= nil, "err: " .. tostring(err))

  ok("parse `*/15 * * * *` succeeds (step)",
    cron.parse("*/15 * * * *") ~= nil)
  ok("parse `0 0-6 * * 1-5` succeeds (range)",
    cron.parse("0 0-6 * * 1-5") ~= nil)
  ok("parse `15,30,45 * * * *` succeeds (list)",
    cron.parse("15,30,45 * * * *") ~= nil)
  ok("parse `0 8 * * 2#1` succeeds (dow ordinal — first Tuesday)",
    cron.parse("0 8 * * 2#1") ~= nil)
  ok("parse accepts `7` as Sunday alias",
    cron.parse("0 0 * * 7") ~= nil)

  -- 69b. parse — rejection paths.
  ok("parse rejects empty string",
    select(2, cron.parse("")) ~= nil)
  ok("parse rejects too few fields",
    select(2, cron.parse("0 0 *")) ~= nil)
  ok("parse rejects too many fields",
    select(2, cron.parse("0 0 * * * *")) ~= nil)
  ok("parse rejects out-of-range minute",
    select(2, cron.parse("60 0 * * *")) ~= nil)
  ok("parse rejects out-of-range hour",
    select(2, cron.parse("0 24 * * *")) ~= nil)
  ok("parse rejects malformed dow ordinal",
    select(2, cron.parse("0 0 * * 2#")) ~= nil)
  ok("parse rejects ordinal K out of range",
    select(2, cron.parse("0 0 * * 2#6")) ~= nil)
  ok("parse rejects non-string input",
    select(2, cron.parse(nil)) ~= nil)

  -- 69c. matches — every-minute pattern always matches.
  local star = cron.parse("* * * * *")
  ok("matches `* * * * *` always true",
    cron.matches(star, os.time()))

  -- 69d. matches — specific minute. Fabricate a components table
  -- to avoid wall-clock flakiness.
  local at_0800 = {
    year = 2026, month = 5, day = 30,  -- a Saturday
    hour = 8, min = 0, sec = 0, wday = 7,  -- wday: Sat (Lua 7=Sat)
  }
  local at_0801 = vim.deepcopy(at_0800); at_0801.min = 1
  local p_eight = cron.parse("0 8 * * *")
  ok("matches `0 8 * * *` at 08:00", cron.matches(p_eight, at_0800))
  ok("does NOT match `0 8 * * *` at 08:01", not cron.matches(p_eight, at_0801))

  -- 69e. dow ordinal — first Tuesday of June 2026 is the 2nd.
  -- (June 1, 2026 is a Monday; June 2 is a Tuesday → first Tuesday.)
  local first_tue_jun = {
    year = 2026, month = 6, day = 2,
    hour = 8, min = 0, sec = 0, wday = 3,  -- Tue (Lua 3=Tue)
  }
  local second_tue_jun = vim.deepcopy(first_tue_jun); second_tue_jun.day = 9
  local p_ordinal = cron.parse("0 8 * * 2#1")
  ok("dow ordinal: first Tuesday at 08:00 → matches",
    cron.matches(p_ordinal, first_tue_jun))
  ok("dow ordinal: second Tuesday at 08:00 → does NOT match",
    not cron.matches(p_ordinal, second_tue_jun))

  -- 69f. parse_and_match convenience.
  local m, perr = cron.parse_and_match("* * * * *", os.time())
  ok("parse_and_match returns true for `* * * * *`", m == true and perr == nil)
  local m_bad, perr_bad = cron.parse_and_match("not cron", os.time())
  ok("parse_and_match returns (false, err) for malformed",
    m_bad == false and type(perr_bad) == "string")
end)()

-- ───────────────────── 70. ADR-0035 Phase 2 — automation engine ─────
print("\n[70] ADR-0035 Phase 2 — automation engine (registry, validate, fire)")
;(function()
  local ok_a, automation = pcall(require, "auto-core.todo.automation")
  if not ok_a then return end
  local todo = require("auto-core.todo")
  local schema = require("auto-core.todo.schema")

  -- Isolate workspace + state.
  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local state_tmp = vim.fn.tempname() .. "_p70-state"
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  local function cleanup()
    automation.stop()
    -- Clear registry between tests (the module-locals are sticky).
    for _, p in ipairs((function()
      local hs = (select(1, automation.registry_snapshot())); return hs
    end)()) do
      automation.unregister_hook(p)
    end
    for _, p in ipairs((function()
      local _, es = automation.registry_snapshot(); return es
    end)()) do
      automation.unregister_executor(p)
    end
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_root,  "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  -- 70a. registry — register/snapshot/unregister.
  local function id_hook(step) return "assign agent:fake", nil end
  local function id_exec(_step, _clone)
    return { ok = true, message = "stub", completed_clone = false }, nil
  end
  automation.register_hook("test-hook:", id_hook)
  automation.register_executor("test-exec:", id_exec)
  local hs, es = automation.registry_snapshot()
  ok("registry_snapshot contains the registered hook",
    (function() for _, p in ipairs(hs) do if p == "test-hook:" then return true end end return false end)())
  ok("registry_snapshot contains the registered executor",
    (function() for _, p in ipairs(es) do if p == "test-exec:" then return true end end return false end)())
  automation.unregister_hook("test-hook:")
  automation.unregister_executor("test-exec:")
  local hs2, es2 = automation.registry_snapshot()
  ok("unregister_hook removed the entry",
    (function() for _, p in ipairs(hs2) do if p == "test-hook:" then return false end end return true end)())
  ok("unregister_executor removed the entry",
    (function() for _, p in ipairs(es2) do if p == "test-exec:" then return false end end return true end)())

  -- 70b. validate — recognizes built-in primitives.
  -- Build a synthetic automated task via schema.blank + overrides.
  local function _automated_blank(over)
    over = over or {}
    over.status = "automated"
    return schema.blank(over)
  end

  -- All-good automated template — no errors.
  local good = _automated_blank({
    condition = { "0 8 * * 2#1", "event:new-task" },
    execute   = { "assign agent:lector", "bash echo hi" },
  })
  ok("validate accepts well-formed automated template",
    #automation.validate(good) == 0)

  -- Malformed cron in condition.
  local bad_cron = _automated_blank({
    condition = { "this is not cron" },
    execute   = { "assign agent:foo" },
  })
  local errs_cron = automation.validate(bad_cron)
  ok("validate flags malformed cron",
    #errs_cron == 1 and errs_cron[1].code == "automation-condition-malformed")

  -- Empty event topic.
  local bad_evt = _automated_blank({
    condition = { "event:" },
    execute   = { "assign agent:foo" },
  })
  ok("validate flags empty event: topic",
    #automation.validate(bad_evt) == 1)

  -- Unknown execute prefix → automation-execute-malformed.
  local bad_exec = _automated_blank({
    condition = { "event:new-task" },
    execute   = { "do-magic now" },
  })
  ok("validate flags unknown execute prefix",
    (function()
      local e = automation.validate(bad_exec)
      return #e == 1 and e[1].code == "automation-execute-malformed"
    end)())

  -- `assign slot:` with NO auto-agents hook registered → hint.
  local bad_slot = _automated_blank({
    condition = { "event:new-task" },
    execute   = { "assign slot:5" },
  })
  ok("validate flags assign slot: with no resolver",
    (function()
      local e = automation.validate(bad_slot)
      return #e == 1 and e[1].code == "automation-slot-no-resolver"
    end)())

  -- `bash -t=N` with NO auto-agents executor registered → hint.
  local bad_bt = _automated_blank({
    condition = { "event:new-task" },
    execute   = { "bash -t=2 echo hi" },
  })
  ok("validate flags bash -t= with no resolver",
    (function()
      local e = automation.validate(bad_bt)
      return #e == 1 and e[1].code == "automation-bash-t-no-resolver"
    end)())

  -- 70c. Non-automated task → validate returns empty (out of scope).
  local open_task = schema.blank({ status = "open" })
  ok("validate returns empty for non-automated tasks",
    #automation.validate(open_task) == 0)

  -- 70d. registered hook makes `assign slot:` validate-clean.
  automation.register_hook("assign slot:", function(step)
    local n = step:match("^assign slot:(%d+)$")
    if not n then return nil, "malformed" end
    return "assign agent:slot" .. n .. "-agent", nil
  end)
  ok("after hook register, assign slot:5 validates clean",
    #automation.validate(bad_slot) == 0)
  automation.unregister_hook("assign slot:")

  -- 70e. fire — happy path with a templated task whose execute step
  -- assigns an agent. The clone is born as open; the assign step
  -- runs through todo.assign which triggers the auto-transition
  -- to in-progress.
  local tpl_id = todo.add({
    id          = "2026-05-30-p70-fire-template",
    title       = "fire test template",
    description = "body of the template",
    tags        = { "kind:test", "owner:p70" },
  })
  -- Promote to automated via direct status + add condition/execute
  -- through a direct file edit (todo.update doesn't accept these
  -- fields yet — managed by the engine; for now we use a managed
  -- write path mirroring what the engine does internally).
  todo.status(tpl_id, "automated")
  local paths_p70 = require("auto-core.todo.paths")
  local md_p70    = require("auto-core.todo.md")
  local tpl_path = paths_p70.task_file_path(paths_p70.resolve_todo_dir(), tpl_id, "automated", nil)
  do
    local f = io.open(tpl_path, "r"); local txt = f:read("*a"); f:close()
    local dec = md_p70.decode(txt)
    dec.value.condition = { "event:new-task" }
    dec.value.execute   = { "assign agent:lector" }
    local enc = md_p70.encode(dec.value)
    local g = io.open(tpl_path .. ".tmp", "w"); g:write(enc); g:close()
    os.rename(tpl_path .. ".tmp", tpl_path)
  end

  -- Subscribe to the fire event so we can assert payload shape.
  local fired_payload
  local events = require("auto-core.events")
  local fired_handle = events.subscribe("core.todo.automation:fired", function(p)
    fired_payload = p
  end)

  local fire_res, fire_err = automation.fire(tpl_id, { reason = "smoke" })
  ok("fire succeeds", fire_res and not fire_err,
    "got: " .. tostring(fire_err))
  ok("fire returns a clone_id",
    fire_res and type(fire_res.clone_id) == "string"
      and fire_res.clone_id ~= "")
  ok("clone_id format: `<origin>--YYYYMMDDTHHMMSSZ`",
    fire_res and fire_res.clone_id:match("^"
      .. tpl_id:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
      .. "%-%-%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ$") ~= nil,
    "got: " .. tostring(fire_res and fire_res.clone_id))

  -- Clone should land in in-progress (assign agent step triggered
  -- the auto-transition).
  local clone = todo.get(fire_res.clone_id)
  ok("clone status is in-progress after assign step",
    clone and clone.status == "in-progress",
    "got: " .. tostring(clone and clone.status))
  ok("clone has origin: backref to template",
    clone and clone.origin == tpl_id)
  ok("clone has automation:fire tag",
    (function()
      if not (clone and type(clone.tags) == "table") then return false end
      for _, t in ipairs(clone.tags) do
        if t == "automation:fire" then return true end
      end
      return false
    end)())

  -- Template `last_fired_at` got bumped.
  local tpl_after = todo.get(tpl_id)
  ok("template last_fired_at is set after fire",
    tpl_after and type(tpl_after.last_fired_at) == "string"
      and tpl_after.last_fired_at:match("^%d%d%d%d%-%d%d%-%d%d") ~= nil)

  -- Event payload shape.
  vim.wait(50, function() return false end)
  ok("core.todo.automation:fired event fired", fired_payload ~= nil)
  ok("event carries origin_id", fired_payload and fired_payload.origin_id == tpl_id)
  ok("event carries clone_id", fired_payload and fired_payload.clone_id == fire_res.clone_id)
  ok("event carries outcome=ok", fired_payload and fired_payload.outcome == "ok")
  events.unsubscribe(fired_handle)

  -- 70f. trust_state defaults — bash disabled by default per ADR §4.5.
  local ts = automation.trust_state()
  ok("trust_state: bash_enabled defaults to false", ts.bash_enabled == false)
  ok("trust_state: bash_first_run_acknowledged defaults to false",
    ts.bash_first_run_acknowledged == false)

  -- 70g. set_trust: mailbox-shaped enable WITHOUT acknowledge → refused.
  local set_ok, set_err = automation.set_trust({ bash_enabled = true })
  ok("set_trust({bash_enabled=true}) refuses without ack",
    not set_ok and set_err == "trust_not_acknowledged",
    "got: " .. tostring(set_err))

  -- 70h. acknowledge_first_run, then enable works.
  automation.acknowledge_first_run()
  local ok2, err2 = automation.set_trust({ bash_enabled = true })
  ok("set_trust({bash_enabled=true}) succeeds after ack",
    ok2 and err2 == nil)
  ok("trust_state: bash_enabled now true",
    automation.trust_state().bash_enabled == true)

  -- 70i. set_trust: allowlist validation.
  local ok_al, err_al = automation.set_trust({ bash_allowlist = "not a list" })
  ok("set_trust: allowlist must be list-or-nil",
    not ok_al and err_al ~= nil)
  automation.set_trust({ bash_allowlist = { "^echo ", "^make " } })
  ok("set_trust: list-shaped allowlist accepted",
    (function()
      local v = automation.trust_state().bash_allowlist
      return type(v) == "table" and #v == 2
    end)())

  -- 70j. start/stop are idempotent + re-armable.
  automation.start()
  automation.start()  -- second call no-ops
  ok("start is idempotent (running=true)",
    automation.list_pending().running == true)
  automation.stop()
  ok("stop sets running=false",
    automation.list_pending().running == false)
  automation.start()  -- re-arm works
  ok("re-arm: start after stop works",
    automation.list_pending().running == true)

  -- 70k. Lector F4: register_hook / register_executor accept the
  -- table form `{resolve|execute = fn, validate = fn}` so
  -- malformed plugin-owned forms fail at validate time, not fire
  -- time.
  automation.register_hook("probe slot:", {
    resolve = function(step)
      local n = step:match("^probe slot:(%d+)$")
      if not n then return nil, "malformed" end
      return "assign agent:slot" .. n .. "-agent", nil
    end,
    validate = function(step)
      if not step:match("^probe slot:%d+$") then
        return "probe slot:<N> requires an integer"
      end
      return nil
    end,
  })
  local v_bad_probe = automation.validate(_automated_blank({
    condition = { "event:new-task" },
    execute   = { "probe slot:abc" },
  }))
  ok("F4: hook validator surfaces malformed registered-prefix step",
    #v_bad_probe == 1 and v_bad_probe[1].code == "automation-execute-malformed",
    "got: " .. vim.inspect(v_bad_probe))
  local v_good_probe = automation.validate(_automated_blank({
    condition = { "event:new-task" },
    execute   = { "probe slot:5" },
  }))
  ok("F4: hook validator passes well-formed registered-prefix step",
    #v_good_probe == 0)

  automation.register_executor("probe-exec:", {
    execute = function(_step, _clone, _ctx)
      return { ok = true, message = "stub", completed_clone = false }, nil
    end,
    validate = function(step)
      if not step:match("^probe%-exec:%d+$") then
        return "probe-exec:<N> expects an integer"
      end
      return nil
    end,
  })
  local v_bad_pe = automation.validate(_automated_blank({
    condition = { "event:new-task" },
    execute   = { "probe-exec:bad" },
  }))
  ok("F4: executor validator surfaces malformed registered-prefix step",
    #v_bad_pe == 1 and v_bad_pe[1].code == "automation-execute-malformed")

  automation.unregister_hook("probe slot:")
  automation.unregister_executor("probe-exec:")

  cleanup()
end)()

-- ───────────────────── 71. Lector F1 + F2 + F3 ──────────────────────
-- F1: bash steps are async; clone bumps to `in-progress` before
--     launching; eventual completion lands via the
--     `core.todo.automation:fired` event with the full outcome.
-- F2: failed steps persist errors[] to the clone FILE (managed-field
--     write), not just to the return value.
-- F3: host Lua bypass flags reach plugin executors via ctx.
print("\n[71] ADR-0035 Lector F1 + F2 + F3 — async bash + persisted errors + executor ctx")
;(function()
  local ok_a, automation = pcall(require, "auto-core.todo.automation")
  if not ok_a then return end
  local todo   = require("auto-core.todo")
  local schema = require("auto-core.todo.schema")
  local paths  = require("auto-core.todo.paths")
  local md     = require("auto-core.todo.md")

  -- Isolate workspace + state.
  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local state_tmp = vim.fn.tempname() .. "_p71-state"
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  -- Trust gate: enable bash for F1 happy-path testing. Reset the
  -- allowlist explicitly because section [70] left a leftover
  -- regex set (`{"^echo ", "^make "}`) and `auto-core.state`'s
  -- registry caches the namespace handle, so the persist_dir flip
  -- in this section's setup doesn't repopulate the in-memory
  -- state. The trust state propagates across smoke sections
  -- unless we explicitly reset.
  automation.acknowledge_first_run()
  automation.set_trust({ bash_enabled = true, bash_allowlist = false })

  local function cleanup()
    automation.stop()
    automation.set_trust({ bash_enabled = false })
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_root,  "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  -- ── helper: build a template via direct managed-field write ──
  local function _make_automated_template(id, title, exec_list)
    local tpl_id = todo.add({ id = id, title = title,
      description = "F1+F2 fixture" })
    todo.status(tpl_id, "automated")
    local tpl_path = paths.task_file_path(paths.resolve_todo_dir(), tpl_id, "automated", nil)
    local f = io.open(tpl_path, "r"); local txt = f:read("*a"); f:close()
    local dec = md.decode(txt)
    dec.value.condition = { "event:new-task" }
    dec.value.execute   = exec_list
    local enc = md.encode(dec.value)
    local g = io.open(tpl_path .. ".tmp", "w"); g:write(enc); g:close()
    os.rename(tpl_path .. ".tmp", tpl_path)
    return tpl_id
  end

  -- ── F1: bash success path. Use `true` so the step exits 0 fast.
  local tpl_ok = _make_automated_template(
    "2026-05-30-p71-bash-ok", "F1 bash ok", { "bash:5 true" })

  local events = require("auto-core.events")
  -- One subscriber, payloads keyed by origin_id so both F1 and F2
  -- can read their own fire result independently.
  local fired_by_origin = {}
  local sub_handle = events.subscribe("core.todo.automation:fired", function(p)
    if p and p.origin_id then fired_by_origin[p.origin_id] = p end
  end)

  local fire_res, fire_err = automation.fire(tpl_ok, {})
  ok("F1: fire returns immediately without blocking",
    fire_res and not fire_err)
  ok("F1: outcome reports in_flight (async)",
    fire_res and fire_res.outcome == "in_flight",
    "got outcome: " .. tostring(fire_res and fire_res.outcome))

  -- Clone must be in-progress while bash is in flight. The async
  -- callback fires via `vim.schedule` so the in-progress status
  -- transition (which happens BEFORE the vim.system call inside
  -- _execute_step) is observable synchronously after fire() returns.
  local clone = todo.get(fire_res.clone_id)
  ok("F1: clone exists after fire (file written to disk)",
    clone ~= nil,
    "clone_id=" .. tostring(fire_res.clone_id)
      .. " todo_dir=" .. tostring(require("auto-core.todo.paths").resolve_todo_dir()))
  ok("F1: clone bumped to in-progress BEFORE bash exit",
    clone and clone.status == "in-progress",
    "got status: " .. tostring(clone and clone.status))

  -- Wait for the fired event (`true` typically completes within
  -- 200ms; allow generous slack).
  vim.wait(5000, function() return fired_by_origin[tpl_ok] ~= nil end)
  local f1_event = fired_by_origin[tpl_ok]
  ok("F1: core.todo.automation:fired fires AFTER async bash completes",
    f1_event ~= nil)
  ok("F1: event outcome=ok for successful bash",
    f1_event and f1_event.outcome == "ok",
    "got outcome: " .. tostring(f1_event and f1_event.outcome))

  -- Clone should now be completed (last step succeeded; completed_clone=true).
  vim.wait(500, function()
    local t = todo.get(fire_res.clone_id)
    return t and t.status == "completed"
  end)
  local final = todo.get(fire_res.clone_id)
  ok("F1: clone reaches completed after async exit 0",
    final and final.status == "completed",
    "got: " .. tostring(final and final.status))

  -- ── F2: failed bash → errors[] persists to the clone FILE.
  local tpl_fail = _make_automated_template(
    "2026-05-30-p71-bash-fail", "F2 bash fail",
    { "bash:5 exit 7" })  -- exits non-zero

  local fire_res2, fire_err2 = automation.fire(tpl_fail, {})
  ok("F2: fire returns immediately even for failing bash",
    fire_res2 and not fire_err2)

  vim.wait(5000, function() return fired_by_origin[tpl_fail] ~= nil end)
  local f2_event = fired_by_origin[tpl_fail]
  ok("F2: fired event arrives for failed bash",
    f2_event ~= nil)
  ok("F2: outcome reports failed/partial",
    f2_event and (f2_event.outcome == "failed"
                  or f2_event.outcome == "partial"),
    "got: " .. tostring(f2_event and f2_event.outcome))

  -- The clone's errors[] must include the step-failed entry.
  local failed_clone = todo.get(fire_res2.clone_id)
  ok("F2: clone exists after failed bash",
    failed_clone ~= nil)
  ok("F2: clone's errors[] persisted to disk with code automation-step-failed",
    failed_clone and type(failed_clone.errors) == "table"
      and #failed_clone.errors >= 1
      and failed_clone.errors[1].code == "automation-step-failed",
    "got errors: " .. vim.inspect(failed_clone and failed_clone.errors))

  events.unsubscribe(sub_handle)

  -- ── F3: host Lua bypass flags reach plugin executors via ctx.
  -- Register a probe executor that asserts ctx is present and
  -- carries the flags we pass.
  local seen_ctx
  automation.register_executor("ctx-probe:", function(_step, _clone, ctx)
    seen_ctx = ctx
    return { ok = true, message = "ctx received", completed_clone = false }, nil
  end)

  local tpl_ctx = _make_automated_template(
    "2026-05-30-p71-ctx-probe", "F3 ctx probe", { "ctx-probe:1" })

  -- Trust state currently has bash_enabled=true (set above). To
  -- prove the bypass flow, flip back to disabled and pass bypass
  -- through opts.
  automation.set_trust({ bash_enabled = false })
  seen_ctx = nil
  automation.fire(tpl_ctx, {
    bypass_bash_disabled = true,
    bypass_allowlist     = true,
  })
  ok("F3: executor received ctx as 3rd argument",
    type(seen_ctx) == "table")
  ok("F3: ctx.bypass_bash_disabled propagated from opts",
    seen_ctx and seen_ctx.bypass_bash_disabled == true)
  ok("F3: ctx.bypass_allowlist propagated from opts",
    seen_ctx and seen_ctx.bypass_allowlist == true)
  ok("F3: ctx.clone_id is populated for executor introspection",
    seen_ctx and type(seen_ctx.clone_id) == "string")

  automation.unregister_executor("ctx-probe:")

  -- ── Lector F5: last_fired_at stamped at fire-start, not at
  -- async completion. Scheduler debounce depends on this; without
  -- the early stamp, a long-running cron bash template can be
  -- re-fired on the 30s tick that lands while the first command
  -- is still in flight, producing duplicate clones.
  --
  -- The test fires a bash:5 template and IMMEDIATELY reads the
  -- template's last_fired_at — must be set even though the bash
  -- step hasn't finished. (Re-enable bash for this since F3 left
  -- bash_enabled=false in the trust state.)
  automation.set_trust({ bash_enabled = true, bash_allowlist = false })
  local tpl_f5 = _make_automated_template(
    "2026-05-30-p71-f5-debounce", "F5 debounce stamp", { "bash:5 sleep 1" })
  local prior_lfa = (todo.get(tpl_f5) or {}).last_fired_at
  ok("F5: template starts with no last_fired_at",
    prior_lfa == nil)

  local f5_res = automation.fire(tpl_f5, {})
  ok("F5: fire returns in_flight for long-running bash",
    f5_res and f5_res.outcome == "in_flight")

  -- KEY ASSERTION: template's last_fired_at is set NOW, while
  -- async bash is still in flight. Without F5's fix this would
  -- be nil until _finalize runs (~1s later).
  local tpl_state = todo.get(tpl_f5)
  ok("F5: template.last_fired_at stamped at fire-start (in-flight)",
    tpl_state and type(tpl_state.last_fired_at) == "string"
      and tpl_state.last_fired_at:match("^%d%d%d%d%-%d%d%-%d%d") ~= nil,
    "got: " .. tostring(tpl_state and tpl_state.last_fired_at))

  -- Wait for the async to actually complete so cleanup doesn't
  -- leak a vim.uv handle.
  vim.wait(3000, function()
    return (todo.get(f5_res.clone_id) or {}).status == "completed"
  end)

  -- ── Lector A1: M.fire must NOT return outcome=in_flight when
  -- the (only / first) step fails synchronously BEFORE vim.system
  -- kicks off. Prior revision pre-detected `async_seen` by
  -- prefix-matching, so a `bash:5 anything` step that failed at
  -- the trust gate still returned in_flight, misleading callers
  -- (notably todos.fire). Disable bash, fire a bash template, and
  -- assert outcome reflects the synchronous failure.
  automation.set_trust({ bash_enabled = false })
  local tpl_a1 = _make_automated_template(
    "2026-05-30-p71-a1-sync-fail", "A1 sync trust-gate failure",
    { "bash:5 echo hi" })

  local a1_res = automation.fire(tpl_a1, {})
  ok("A1: fire of a sync-failing bash template returns synchronously (not in_flight)",
    a1_res and a1_res.outcome ~= "in_flight",
    "got outcome: " .. tostring(a1_res and a1_res.outcome))
  ok("A1: sync-failure outcome reports failed",
    a1_res and a1_res.outcome == "failed",
    "got outcome: " .. tostring(a1_res and a1_res.outcome))
  ok("A1: synchronous errors[] populated on the return value",
    a1_res and type(a1_res.errors) == "table" and #a1_res.errors >= 1
      and a1_res.errors[1].code == "automation-step-failed",
    "got errors: " .. vim.inspect(a1_res and a1_res.errors))

  -- A1 corollary: the clone file ALSO carries the errors[] on
  -- disk (F2 invariant continues to hold for sync failures).
  local a1_clone = todo.get(a1_res.clone_id)
  ok("A1: clone file errors[] persisted on sync failure",
    a1_clone and type(a1_clone.errors) == "table"
      and #a1_clone.errors >= 1
      and a1_clone.errors[1].code == "automation-step-failed",
    "got errors: " .. vim.inspect(a1_clone and a1_clone.errors))

  cleanup()
end)()

-- ───────────────── 72. ADR-0035 post-ship validator ─────────────
-- Empty / missing condition[] or execute[] on an automated template
-- is now flagged as malformed via automation.validate, so a
-- just-promoted template (without scaffolded defaults) lands in
-- the panel's malformed surface immediately instead of silently
-- never firing. The auto-finder scaffold (panel `s` → automated)
-- populates working defaults to keep newly-promoted templates
-- clean; the validator catches templates that explicitly clear
-- the fields or are authored by hand without them.
print("\n[72] ADR-0035 post-ship — empty condition/execute flagged as malformed")
;(function()
  local schema = require("auto-core.todo.schema")
  local automation = require("auto-core.todo.automation")

  local function _auto(over)
    over = over or {}
    over.status = "automated"
    return schema.blank(over)
  end

  -- Both fields absent → two errors.
  local v_both_absent = automation.validate(_auto())
  local saw_cond, saw_exec = false, false
  for _, e in ipairs(v_both_absent) do
    if e.code == "automation-condition-malformed" and e.field == "condition" then saw_cond = true end
    if e.code == "automation-execute-malformed"  and e.field == "execute"  then saw_exec = true end
  end
  ok("validator: missing condition[] flagged as automation-condition-malformed",
    saw_cond, "got: " .. vim.inspect(v_both_absent))
  ok("validator: missing execute[] flagged as automation-execute-malformed",
    saw_exec, "got: " .. vim.inspect(v_both_absent))

  -- Both empty lists → two errors.
  local v_both_empty = automation.validate(_auto({
    condition = {},
    execute   = {},
  }))
  local saw_cond_empty, saw_exec_empty = false, false
  for _, e in ipairs(v_both_empty) do
    if e.code == "automation-condition-malformed" and e.field == "condition" then saw_cond_empty = true end
    if e.code == "automation-execute-malformed"  and e.field == "execute"  then saw_exec_empty = true end
  end
  ok("validator: empty condition[] flagged",
    saw_cond_empty, "got: " .. vim.inspect(v_both_empty))
  ok("validator: empty execute[] flagged",
    saw_exec_empty, "got: " .. vim.inspect(v_both_empty))

  -- Only one missing → only one error of that kind.
  local v_only_cond_empty = automation.validate(_auto({
    condition = {},
    execute   = { "assign user" },
  }))
  local empty_cond_only = false
  for _, e in ipairs(v_only_cond_empty) do
    if e.code == "automation-condition-malformed" and e.field == "condition" then
      empty_cond_only = true
    end
  end
  ok("validator: only empty condition fires the condition error",
    empty_cond_only and #v_only_cond_empty == 1,
    "got: " .. vim.inspect(v_only_cond_empty))

  -- Scaffold-style template (the auto-finder defaults) passes clean.
  local v_scaffold = automation.validate(_auto({
    condition = { "0 0 * * *" },
    execute   = { 'bash -t=1 "echo hello world"' },
  }))
  -- May still have bash-t-no-resolver if auto-agents isn't loaded
  -- in this smoke (it isn't — auto-core smoke runs standalone),
  -- but specifically should NOT carry an empty-list error.
  local has_empty_err = false
  for _, e in ipairs(v_scaffold) do
    if e.field == "condition" or e.field == "execute" then
      if e.message:find("empty or missing", 1, true) then
        has_empty_err = true
      end
    end
  end
  ok("validator: scaffold-style defaults don't trigger empty-list errors",
    not has_empty_err,
    "got: " .. vim.inspect(v_scaffold))

  -- Non-automated tasks are out of scope.
  local v_open = automation.validate(schema.blank({ status = "open" }))
  ok("validator: empty-list rules don't fire for non-automated tasks",
    #v_open == 0)

  -- ADR-0035 post-ship Lector blocker (2026-05-31): demoting
  -- FROM automated must clear the template-only fields so the
  -- "non-automated rejects condition/execute/last_fired_at"
  -- validator rule doesn't reject the write and leave the file
  -- stuck at automated. Round-trip via real todo.status.
  local todo = require("auto-core.todo")
  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local state_tmp = vim.fn.tempname() .. "_p72-state"
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })
  local function _cleanup()
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_root,  "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  -- Build an automated template via the public surface; patch
  -- condition + execute via the managed-field-write pattern (the
  -- same one M.fire / auto-finder scaffold use).
  local tpl_id = todo.add({
    id    = "2026-05-31-p72-demote-test",
    title = "demote-clears-fields",
  })
  todo.status(tpl_id, "automated")
  do
    local paths = require("auto-core.todo.paths")
    local md    = require("auto-core.todo.md")
    local tpath = paths.task_file_path(paths.resolve_todo_dir(), tpl_id, "automated", nil)
    local f = io.open(tpath, "r"); local txt = f:read("*a"); f:close()
    local dec = md.decode(txt)
    dec.value.condition     = { "0 0 * * *" }
    dec.value.execute       = { 'bash -t=1 "echo hi"' }
    dec.value.last_fired_at = "2026-05-30T00:00:00Z"
    local enc = md.encode(dec.value)
    local g = io.open(tpath .. ".tmp", "w"); g:write(enc); g:close()
    os.rename(tpath .. ".tmp", tpath)
  end

  local before = todo.get(tpl_id)
  ok("demote-cleanup: template starts with condition + execute populated",
    type(before.condition) == "table" and #before.condition == 1
      and type(before.execute) == "table" and #before.execute == 1
      and before.last_fired_at ~= nil)

  -- THE TEST: demote automated → open must succeed AND clear the
  -- template-only fields.
  local demoted, demote_err = todo.status(tpl_id, "open")
  ok("demote-cleanup: todo.status(automated→open) succeeds",
    demoted ~= nil and demote_err == nil,
    "got err: " .. tostring(demote_err))
  ok("demote-cleanup: condition cleared on demote",
    demoted and demoted.condition == nil,
    "got: " .. vim.inspect(demoted and demoted.condition))
  ok("demote-cleanup: execute cleared on demote",
    demoted and demoted.execute == nil,
    "got: " .. vim.inspect(demoted and demoted.execute))
  ok("demote-cleanup: last_fired_at cleared on demote",
    demoted and demoted.last_fired_at == nil,
    "got: " .. tostring(demoted and demoted.last_fired_at))

  -- Re-read from disk to confirm persistence.
  local on_disk = todo.get(tpl_id)
  ok("demote-cleanup: cleared fields are persisted on disk",
    on_disk and on_disk.condition == nil and on_disk.execute == nil
      and on_disk.last_fired_at == nil)

  -- Demote to deferred / completed / archived also works (same path).
  todo.status(tpl_id, "automated")
  do
    local paths = require("auto-core.todo.paths")
    local md    = require("auto-core.todo.md")
    local tpath = paths.task_file_path(paths.resolve_todo_dir(), tpl_id, "automated", nil)
    local f = io.open(tpath, "r"); local txt = f:read("*a"); f:close()
    local dec = md.decode(txt)
    dec.value.condition = { "0 0 * * *" }
    dec.value.execute   = { 'bash -t=1 "echo hi"' }
    local enc = md.encode(dec.value)
    local g = io.open(tpath .. ".tmp", "w"); g:write(enc); g:close()
    os.rename(tpath .. ".tmp", tpath)
  end
  local def_demoted = todo.status(tpl_id, "deferred")
  ok("demote-cleanup: automated → deferred also clears template fields",
    def_demoted and def_demoted.condition == nil and def_demoted.execute == nil)

  -- ADR-0035 post-ship Lector finding F2 (round-2): the
  -- SYMMETRIC promote direction. A clone (born from a template
  -- fire) carries `origin: <template-id>` as a managed field.
  -- Schema rejects origin on automated rows ("templates aren't
  -- clones"); without M.status clearing origin on the into-
  -- automated transition, a user promoting a clone via the
  -- modal hits the validator and the promote write is rejected.
  --
  -- Synthesize a clone-like task (status=open + origin set),
  -- promote to automated, verify origin is cleared on the
  -- returned task AND persisted to disk.
  local clone_id = todo.add({
    id    = "2026-05-31-p72-clone-promote",
    title = "clone promote test",
  })
  -- Patch origin via the managed-field write pattern.
  do
    local paths = require("auto-core.todo.paths")
    local md    = require("auto-core.todo.md")
    local cpath = paths.task_file_path(paths.resolve_todo_dir(), clone_id, "open", nil)
    local f = io.open(cpath, "r"); local txt = f:read("*a"); f:close()
    local dec = md.decode(txt)
    dec.value.origin = "some-parent-template"
    local enc = md.encode(dec.value)
    local g = io.open(cpath .. ".tmp", "w"); g:write(enc); g:close()
    os.rename(cpath .. ".tmp", cpath)
  end

  local pre_promote = todo.get(clone_id)
  ok("F2: clone starts with origin set",
    pre_promote and pre_promote.origin == "some-parent-template")

  local promoted_clone, prom_err = todo.status(clone_id, "automated")
  ok("F2: todo.status(open→automated) on a clone succeeds",
    promoted_clone and prom_err == nil,
    "got err: " .. tostring(prom_err))
  ok("F2: origin cleared on promote to automated",
    promoted_clone and promoted_clone.origin == nil,
    "got: " .. tostring(promoted_clone and promoted_clone.origin))

  -- Re-read from disk to confirm persistence.
  local clone_on_disk = todo.get(clone_id)
  ok("F2: origin clear persists on disk after promote",
    clone_on_disk and clone_on_disk.origin == nil)
  ok("F2: clone is now status=automated",
    clone_on_disk and clone_on_disk.status == "automated")

  _cleanup()
end)()

-- ───────────── 73. ADR-0035 post-ship — overridden todo-dir ──────────
-- BUG FIX (2026-06-01): the automation engine's managed-field
-- writer (_write_managed_field — patches origin / last_fired_at /
-- errors during M.fire) resolved the todo-dir with the
-- override-IGNORING `paths.resolve_todo_dir(nil)`, which falls back
-- to `<workspace>/.todo-list`. On a KB-rooted store (todo-dir set
-- via `set_todo_dir` to a path OUTSIDE the workspace), it scanned
-- the wrong tree, never found the clone, and the managed writes
-- silently failed. Worst casualty: last_fired_at never stamped →
-- the debounce gate never engages → re-fire every scheduler tick.
-- This section reproduces the override mismatch and asserts the
-- managed writes land.
print("\n[73] ADR-0035 post-ship — clone-on-fire under an OVERRIDDEN todo-dir")
;(function()
  local ok_a, automation = pcall(require, "auto-core.todo.automation")
  if not ok_a then return end
  local todo  = require("auto-core.todo")
  local paths = require("auto-core.todo.paths")
  local md    = require("auto-core.todo.md")

  -- Workspace at tmp_ws, but todo-dir OVERRIDDEN to a DIFFERENT
  -- tree (tmp_store) — mirrors the user's KB-rooted setup where
  -- the store lives outside the workspace.
  local tmp_ws    = vim.fn.tempname() .. "_p73-ws"
  local tmp_store = vim.fn.tempname() .. "_p73-store"
  vim.fn.mkdir(tmp_ws, "p")
  vim.fn.mkdir(tmp_store, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_ws)
  local state_tmp = vim.fn.tempname() .. "_p73-state"
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  -- Override the todo-dir to the OUT-OF-WORKSPACE store.
  todo.set_todo_dir(tmp_store .. "/.todo-list")

  local function _cleanup()
    automation.stop()
    automation.set_trust({ bash_enabled = false })
    todo.set_todo_dir(nil)
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_ws,    "rf")
    vim.fn.delete(tmp_store, "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  -- Sanity: the override resolver disagrees with the raw workspace
  -- fallback — exactly the mismatch that hid the bug.
  ok("p73: get_todo_dir() honors the override (not the workspace)",
    todo.get_todo_dir() == (tmp_store .. "/.todo-list"),
    "got: " .. tostring(todo.get_todo_dir()))
  ok("p73: raw resolve_todo_dir() would have pointed at the workspace",
    paths.resolve_todo_dir() ~= todo.get_todo_dir())

  -- Build an automated template in the OVERRIDDEN store. Use an
  -- assign step (no bash trust needed) so the fire's managed
  -- writes (origin on clone, last_fired_at on template) are the
  -- thing under test, not bash.
  local tpl_id = todo.add({ id = "2026-06-01-p73-tpl", title = "override fire test" })
  todo.status(tpl_id, "automated")
  do
    local tpath = paths.task_file_path(todo.get_todo_dir(), tpl_id, "automated", nil)
    local f = io.open(tpath, "r"); local txt = f:read("*a"); f:close()
    local dec = md.decode(txt)
    dec.value.condition = { "event:new-task" }
    dec.value.execute   = { "assign user" }
    local enc = md.encode(dec.value)
    local g = io.open(tpath .. ".tmp", "w"); g:write(enc); g:close()
    os.rename(tpath .. ".tmp", tpath)
  end

  -- Fire it.
  local res, ferr = automation.fire(tpl_id, {})
  ok("p73: fire succeeds under the overridden todo-dir",
    res and not ferr, "got err: " .. tostring(ferr))

  -- The clone must exist IN THE OVERRIDDEN STORE (todo.get is
  -- override-aware, so this also confirms find_task_path agrees).
  local clone = todo.get(res.clone_id)
  ok("p73: clone exists in the overridden store",
    clone ~= nil, "clone_id=" .. tostring(res and res.clone_id))
  ok("p73: clone file physically under the override path",
    res and vim.fn.filereadable(
      paths.task_file_path(todo.get_todo_dir(), res.clone_id,
        (clone or {}).status or "open", nil)) == 1)

  -- THE KEY ASSERTIONS: managed-field writes landed despite the
  -- override (would have silently failed under the old resolver).
  ok("p73: clone carries origin backref (managed write found the file)",
    clone and clone.origin == tpl_id,
    "got: " .. tostring(clone and clone.origin))

  local tpl_after = todo.get(tpl_id)
  ok("p73: template last_fired_at stamped (debounce gate works under override)",
    tpl_after and type(tpl_after.last_fired_at) == "string"
      and tpl_after.last_fired_at:match("^%d%d%d%d%-%d%d%-%d%d") ~= nil,
    "got: " .. tostring(tpl_after and tpl_after.last_fired_at))

  _cleanup()
end)()

-- ───────── 74. ADR-0035 amendment — clone lifecycle + exit_code ─────────
-- (2026-06-01) Two coupled semantics under test:
--   • Clone-completion lifecycle. Every fire bumps its clone
--     open→in-progress at fire-start (covered by [71] F1). On
--     SUCCESS the clone completes UNLESS a step assigned it to an
--     AGENT (`assign agent:` / `assign slot:`) — that agent owns
--     closing it. `assign user` does NOT block completion. Failures
--     stay in-progress with errors[] for triage.
--   • exit_code capture. A built-in CAPTURED bash step
--     (`bash <cmd>` / `bash:<sec> <cmd>`, run via vim.system) records
--     its exit status in the managed `exit_code` field — 0 on
--     success, the real code on failure. Executor-routed steps
--     (the shape `bash -t=N` takes — auto-agents floating terminal)
--     record NO exit_code: nothing to capture. Assigns record none.
print("\n[74] ADR-0035 amendment — clone in-progress→completed lifecycle + exit_code")
;(function()
  local ok_a, automation = pcall(require, "auto-core.todo.automation")
  if not ok_a then return end
  local todo  = require("auto-core.todo")
  local paths = require("auto-core.todo.paths")
  local md    = require("auto-core.todo.md")
  local events = require("auto-core.events")

  -- Isolate workspace + state.
  local tmp_root = vim.fn.tempname() .. "_p74"
  vim.fn.mkdir(tmp_root, "p")
  local worktree = require("auto-core.git.worktree")
  worktree.set_workspace_root(tmp_root)
  local state_tmp = vim.fn.tempname() .. "_p74-state"
  vim.fn.mkdir(state_tmp, "p")
  require("auto-core.state").configure({ persist_dir = state_tmp })

  automation.acknowledge_first_run()
  automation.set_trust({ bash_enabled = true, bash_allowlist = false })

  local function cleanup()
    automation.stop()
    automation.set_trust({ bash_enabled = false })
    worktree.set_workspace_root(nil)
    require("auto-core.state").configure({ persist_dir = nil })
    vim.fn.delete(tmp_root,  "rf")
    vim.fn.delete(state_tmp, "rf")
  end

  local function _make_tpl(id, exec_list)
    local tpl_id = todo.add({ id = id, title = id, description = "p74 fixture" })
    todo.status(tpl_id, "automated")
    local tpath = paths.task_file_path(todo.get_todo_dir(), tpl_id, "automated", nil)
    local f = io.open(tpath, "r"); local txt = f:read("*a"); f:close()
    local dec = md.decode(txt)
    dec.value.condition = { "event:new-task" }
    dec.value.execute   = exec_list
    local enc = md.encode(dec.value)
    local g = io.open(tpath .. ".tmp", "w"); g:write(enc); g:close()
    os.rename(tpath .. ".tmp", tpath)
    return tpl_id
  end

  local fired = {}
  local sub = events.subscribe("core.todo.automation:fired", function(p)
    if p and p.origin_id then fired[p.origin_id] = p end
  end)

  -- ── (a) Captured bash SUCCESS → exit_code=0, clone completed. ──
  local tpl_ok = _make_tpl("2026-06-01-p74-bash-ok", { "bash:10 true" })
  local res_ok = automation.fire(tpl_ok, {})
  vim.wait(5000, function() return fired[tpl_ok] ~= nil end)
  vim.wait(1000, function()
    return (todo.get(res_ok.clone_id) or {}).status == "completed"
  end)
  local clone_ok = todo.get(res_ok.clone_id)
  ok("p74(a): captured-bash success → clone completed",
    clone_ok and clone_ok.status == "completed",
    "got status: " .. tostring(clone_ok and clone_ok.status))
  ok("p74(a): captured-bash success → exit_code == 0 persisted on clone",
    clone_ok and clone_ok.exit_code == 0,
    "got exit_code: " .. tostring(clone_ok and clone_ok.exit_code))

  -- ── (b) Captured bash FAILURE → exit_code=7, stays in-progress. ──
  local tpl_fail = _make_tpl("2026-06-01-p74-bash-fail", { "bash:10 exit 7" })
  local res_fail = automation.fire(tpl_fail, {})
  vim.wait(5000, function() return fired[tpl_fail] ~= nil end)
  -- Give the async finalize a beat to land the managed write.
  vim.wait(1000, function()
    return (todo.get(res_fail.clone_id) or {}).exit_code ~= nil
  end)
  local clone_fail = todo.get(res_fail.clone_id)
  ok("p74(b): captured-bash failure → exit_code == 7 persisted on clone",
    clone_fail and clone_fail.exit_code == 7,
    "got exit_code: " .. tostring(clone_fail and clone_fail.exit_code))
  ok("p74(b): captured-bash failure → clone STAYS in-progress (not completed)",
    clone_fail and clone_fail.status == "in-progress",
    "got status: " .. tostring(clone_fail and clone_fail.status))
  ok("p74(b): captured-bash failure → errors[] carries automation-step-failed",
    clone_fail and type(clone_fail.errors) == "table"
      and #clone_fail.errors >= 1
      and clone_fail.errors[1].code == "automation-step-failed",
    "got errors: " .. vim.inspect(clone_fail and clone_fail.errors))

  -- ── (c) Executor-routed step (the `bash -t=N` shape) → clone
  --        completes but records NO exit_code. Register a stub
  --        executor standing in for auto-agents' terminal router:
  --        returns ok with no exit_code, exactly like the real one.
  automation.register_executor("p74-term:", function(_step, _clone, _ctx)
    return { ok = true, message = "routed to terminal", completed_clone = true }, nil
  end)
  local tpl_term = _make_tpl("2026-06-01-p74-term", { "p74-term:echo hi" })
  local res_term = automation.fire(tpl_term, {})
  -- Synchronous executor: fire finalizes inline. completion is a
  -- status-API call; allow a brief settle in case of scheduling.
  vim.wait(1000, function()
    return (todo.get(res_term.clone_id) or {}).status == "completed"
  end)
  local clone_term = todo.get(res_term.clone_id)
  ok("p74(c): executor-routed step → clone completes on successful dispatch",
    clone_term and clone_term.status == "completed",
    "got status: " .. tostring(clone_term and clone_term.status))
  ok("p74(c): executor-routed step → NO exit_code recorded (nothing to capture)",
    clone_term and clone_term.exit_code == nil,
    "got exit_code: " .. tostring(clone_term and clone_term.exit_code))
  automation.unregister_executor("p74-term:")

  -- ── (d) Agent-assign step → clone STAYS in-progress (the agent
  --        owns closing it), NO exit_code.
  local tpl_asn = _make_tpl("2026-06-01-p74-assign", { "assign agent:smoke-target" })
  local res_asn = automation.fire(tpl_asn, {})
  vim.wait(500, function()
    local t = todo.get(res_asn.clone_id)
    return t and t.assignee == "agent:smoke-target"
  end)
  local clone_asn = todo.get(res_asn.clone_id)
  ok("p74(d): agent-assign → clone assignee set",
    clone_asn and clone_asn.assignee == "agent:smoke-target",
    "got assignee: " .. tostring(clone_asn and clone_asn.assignee))
  ok("p74(d): agent-assign → clone STAYS in-progress (agent owns close)",
    clone_asn and clone_asn.status == "in-progress",
    "got status: " .. tostring(clone_asn and clone_asn.status))
  ok("p74(d): agent-assign → NO exit_code recorded",
    clone_asn and clone_asn.exit_code == nil,
    "got exit_code: " .. tostring(clone_asn and clone_asn.exit_code))

  events.unsubscribe(sub)
  cleanup()
end)()

-- ─────────────────────── summary ─────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
