-- tests/retire-mailbox.lua — auto-core v0.6.0 has no file mailbox (ADR 1793271500 phase 5).
--
-- The crew (AutoDoc's daemon mail) is the one transport. What the mailbox held that
-- outlives it moves out of `auto-core.mailbox`: the command registry the editor socket
-- dispatches through (`auto-core.commands`), and the process's instance id
-- (`auto-core.instance`). No daemon is needed, so this suite runs in tests/run-all.sh.
--
-- Run: nvim --headless -u NONE -l tests/retire-mailbox.lua
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail ~= nil and ("  — " .. tostring(detail)) or ""))
  io.stdout:write("\n", (line:gsub("[\r\n]+", " ")), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end
local function section(t) io.stdout:write("\n", t, "\n"); io.stdout:flush() end

-- Sandbox auto-core's state: this suite must not touch the developer's.
local state_tmp = vim.fn.tempname() .. "-state"
vim.fn.mkdir(state_tmp, "p")
require("auto-core.state").configure({ persist_dir = state_tmp })

-- ─── the command registry ────────────────────────────────────

section("auto-core.commands: the registry the editor socket dispatches through")
do
  local loaded, commands = pcall(require, "auto-core.commands")
  ok("auto-core.commands loads", loaded, commands)
  if not loaded then commands = {} end
  for _, fn in ipairs({ "register", "get", "list", "unregister", "validate_args" }) do
    ok("auto-core.commands." .. fn .. " is a function", type(commands[fn]) == "function")
  end
  ok("the file-envelope path is not part of it (handle_message, reject_unknown)",
    commands.handle_message == nil and commands.reject_unknown == nil)

  if loaded then
    local announced
    local events = require("auto-core.events")
    local sub = events.subscribe("core.command:registered", function(p) announced = p end)
    local function handler(args) return args.x end
    local schema = { x = "string" }
    local r_ok, r_err = commands.register("retire.echo", { owner = "retire-test", handler = handler,
      schema = schema, description = "echoes x" })
    ok("register accepts a dotted name with an owner and a handler", r_ok, r_err)
    ok("register announces core.command:registered with the name and owner",
      type(announced) == "table" and announced.name == "retire.echo" and announced.owner == "retire-test",
      vim.inspect(announced))
    pcall(events.unsubscribe, sub)

    local spec = commands.get("retire.echo")
    ok("get answers the spec, its handler included",
      type(spec) == "table" and spec.handler == handler and spec.owner == "retire-test"
        and spec.description == "echoes x", vim.inspect(spec))
    ok("get answers nil for a name never registered", commands.get("retire.nobody") == nil)

    local other_ok = commands.register("retire.echo", { owner = "someone-else", handler = handler })
    ok("another owner can't take a registered name", other_ok == false)
    ok("the same owner may register it again", commands.register("retire.echo",
      { owner = "retire-test", handler = handler, schema = schema }) == true)
    ok("a malformed name is refused", commands.register("retire..x", { owner = "o", handler = handler }) == false)
    ok("a spec with no handler is refused", commands.register("retire.nohandler", { owner = "o" }) == false)

    local listed
    for _, row in ipairs(commands.list()) do
      if row.name == "retire.echo" then listed = row end
    end
    ok("list carries the name, owner and schema",
      type(listed) == "table" and listed.owner == "retire-test" and type(listed.schema) == "table"
        and listed.schema.x == "string", vim.inspect(listed))
    if listed and listed.schema then listed.schema.x = "number" end
    ok("list answers a copy: changing it leaves the registry's schema alone",
      commands.get("retire.echo").schema.x == "string")

    local v_ok, v_err, v_field = commands.validate_args({}, { x = "string" })
    ok("validate_args refuses a missing required field, naming it",
      v_ok == false and type(v_err) == "string" and v_field == "x", vim.inspect({ v_ok, v_err, v_field }))
    local args = { x = vim.NIL }
    ok("validate_args takes JSON null for an optional field and clears it",
      commands.validate_args(args, { x = "string?" }) == true and args.x == nil)
    ok("validate_args refuses the wrong type",
      commands.validate_args({ x = 1 }, { x = "string" }) == false)

    commands.unregister("retire.echo")
    ok("unregister removes it", commands.get("retire.echo") == nil)
  end
end

-- ─── the instance id ─────────────────────────────────────────

section("auto-core.instance: this Neovim's instance id, the notifier's consumer and the agents' suffix")
do
  local loaded, instance = pcall(require, "auto-core.instance")
  ok("auto-core.instance loads", loaded, instance)
  if not loaded then instance = {} end
  ok("auto-core.instance.id and set_id are functions",
    type(instance.id) == "function" and type(instance.set_id) == "function")
  if type(instance.id) == "function" and type(instance.set_id) == "function" then
    local first = instance.id()
    ok("id is <unix-seconds>-<pid>", type(first) == "string" and first:match("^%d+%-%d+$") ~= nil, first)
    ok("id is this process's", type(first) == "string" and first:match("%-(%d+)$") == tostring(vim.fn.getpid()), first)
    ok("id stays the same for the process", instance.id() == first)
    instance.set_id("1111111111-22222")
    ok("set_id overrides it", instance.id() == "1111111111-22222")
    ok("set_id refuses an id with a separator", not pcall(instance.set_id, "a/b"))
    ok("a refused set_id leaves the id alone", instance.id() == "1111111111-22222")
    instance.set_id(nil)
    ok("set_id(nil) clears the override", instance.id():match("^%d+%-%d+$") ~= nil
      and instance.id() ~= "1111111111-22222", instance.id())
  end
end

-- ─── the file mailbox is gone ────────────────────────────────

section("no file mailbox: the modules, the topics, the commands and the log events are gone")
do
  for _, name in ipairs({ "auto-core.mailbox", "auto-core.mailbox.router", "auto-core.mailbox.transport",
      "auto-core.mailbox.registry", "auto-core.mailbox.path", "auto-core.mailbox.message",
      "auto-core.mailbox.bootstrap", "auto-core.mailbox.ui", "auto-core.mailbox.commands",
      "auto-core.debug.mailbox" }) do
    ok(name .. " no longer loads", not pcall(require, name))
  end
  local core = require("auto-core")
  ok("auto-core has no mailbox field", core.mailbox == nil)
  ok("auto-core.debug has no mailbox probe", require("auto-core.debug").mailbox == nil)

  local topics = require("auto-core.events.topics")
  local left = {}
  for topic in pairs(topics) do
    if type(topic) == "string" and (topic:match("^core%.mailbox:") or topic == "core.command:executed"
        or topic == "core.command:rejected") then
      left[#left + 1] = topic
    end
  end
  table.sort(left)
  ok("no core.mailbox:* topic, nor the envelope path's command topics", #left == 0, table.concat(left, ", "))
  ok("core.command:registered stays (the registry announces)", topics["core.command:registered"] ~= nil)

  vim.cmd("runtime! plugin/auto-core.lua")
  -- by its exact name: exists(":AutoCoreMailbox") also matches :AutoCoreMailboxExport, a prefix match
  ok(":AutoCoreMailbox is gone", vim.api.nvim_get_commands({})["AutoCoreMailbox"] == nil)
  local probes = vim.fn.getcompletion("AutoCoreDebug ", "cmdline")
  ok(":AutoCoreDebug offers no mailbox probe", not vim.tbl_contains(probes, "mailbox"), vim.inspect(probes))
  local stale = {}
  for _, e in ipairs(require("auto-core.log").events.list("auto-core")) do
    if tostring(e.event):find("mailbox", 1, true) then stale[#stale + 1] = e.event end
  end
  ok("no mailbox log events are registered", #stale == 0, table.concat(stale, ", "))
end

-- ─── setup ───────────────────────────────────────────────────

section("setup: a leftover mailbox config warns once; nothing is created; the notifier starts")
do
  local proj = vim.fn.tempname() .. "-proj"
  vim.fn.mkdir(proj, "p")
  local old_cwd = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(proj))
  local notices = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level) notices[#notices + 1] = { msg = tostring(msg), level = level } end

  local core = require("auto-core")
  local mbroot = proj .. "/mbroot"
  local s_ok, s_err = pcall(core.setup, { mailbox = { root = mbroot, autostart = true } })
  ok("setup with a leftover mailbox = {...} doesn't fail", s_ok, s_err)
  pcall(core.setup, { mailbox = { root = mbroot } })
  local warned = {}
  for _, n in ipairs(notices) do
    if n.msg:find("mailbox", 1, true) then warned[#warned + 1] = n end
  end
  ok("one warning names it, over two setups", #warned == 1, vim.inspect(warned))
  ok("… at WARN", warned[1] ~= nil and warned[1].level == vim.log.levels.WARN, vim.inspect(warned[1]))
  local before = #notices
  pcall(core.setup, {})
  ok("a setup without it says nothing more", #notices == before, vim.inspect(notices))
  vim.notify = real_notify

  ok("setup creates no mailbox root", vim.fn.isdirectory(mbroot) == 0)
  ok("… and no .auto-agents/mailbox in the project", vim.fn.isdirectory(proj .. "/.auto-agents") == 0)
  ok("… nor anywhere under it", #vim.fn.globpath(proj, "**/mailbox", true, true) == 0)

  local notifier = require("auto-core.todo.notifier")
  ok("setup starts the assignment notifier", notifier.is_running())
  notifier.stop()
  ok("setup registers editor.open on auto-core.commands", require("auto-core.commands").get("editor.open") ~= nil)
  vim.cmd("cd " .. vim.fn.fnameescape(old_cwd))
end

-- ─── the archive export ──────────────────────────────────────

section(":AutoCoreMailboxExport: an old mailbox tree's archives to JSONL, read-only")
do
  local root = vim.fn.tempname() .. "-mailbox"
  local function put(rel, text)
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(p, "w")); f:write(text); f:close()
  end
  put("1793000000-1/agent:lector/archive/m1.json", vim.json.encode({ id = "m1", from = "nvim", body = "one" }))
  put("1793000000-1/agent:lector/archive/m2.json", vim.json.encode({ id = "m2", from = "agent:vision", body = "two" }))
  put("1793000000-1/nvim/archive/m3.json", vim.json.encode({ id = "m3", kind = "command", command = "peek" }))
  put("1793000000-1/nvim/archive/broken.json", "{ not json")
  put("1793000000-1/agent:lector/inbox/waiting.json", vim.json.encode({ id = "w1" }))
  put("bootstrap-mailbox.md", "# old bootstrap\n")

  local function snapshot()
    local out = {}
    for _, p in ipairs(vim.fn.globpath(root, "**", true, true)) do
      local st = vim.uv.fs_stat(p)
      out[p] = st and (st.type .. ":" .. st.size .. ":" .. st.mtime.sec .. ":" .. st.mtime.nsec) or "?"
    end
    return out
  end
  local before = snapshot()

  local loaded, export = pcall(require, "auto-core.export_mailbox")
  ok("auto-core.export_mailbox loads", loaded, export)
  if not loaded then export = {} end
  local out = vim.fn.tempname() .. "-export.jsonl"
  local res, err
  if type(export.export) == "function" then res, err = export.export({ root = root, out = out }) end
  ok("export answers the count and the file", type(res) == "table" and res.count == 4 and res.out == out,
    vim.inspect({ res, err }))
  local lines = vim.fn.filereadable(out) == 1 and vim.fn.readfile(out) or {}
  ok("one line per archived message (inbox and other files left out)", #lines == 4, #lines)
  local rows = {}
  for _, l in ipairs(lines) do
    local okd, row = pcall(vim.json.decode, l)
    if okd and type(row) == "table" then rows[#rows + 1] = row end
  end
  local paths = {}
  for _, r in ipairs(rows) do paths[#paths + 1] = r.path end
  ok("each line is JSON naming its path under the root, in path order", vim.deep_equal(paths, {
    "1793000000-1/agent:lector/archive/m1.json", "1793000000-1/agent:lector/archive/m2.json",
    "1793000000-1/nvim/archive/broken.json", "1793000000-1/nvim/archive/m3.json" }), vim.inspect(paths))
  ok("a message is carried whole", rows[2] and type(rows[2].message) == "table" and rows[2].message.from == "agent:vision"
    and rows[2].message.body == "two", vim.inspect(rows[2]))
  ok("a file that doesn't parse is carried raw, with why", rows[3] and rows[3].message == nil
    and rows[3].raw == "{ not json" and type(rows[3].decode_error) == "string", vim.inspect(rows[3]))
  ok("the tree is untouched: nothing written, moved or removed", vim.deep_equal(snapshot(), before))

  local inside = root .. "/export.jsonl"
  local r2, e2
  if type(export.export) == "function" then r2, e2 = export.export({ root = root, out = inside }) end
  ok("an output inside the tree is refused", r2 == nil and type(e2) == "string", vim.inspect({ r2, e2 }))
  ok("… and nothing is written there", vim.fn.filereadable(inside) == 0 and vim.deep_equal(snapshot(), before))
  local gone = vim.fn.tempname() .. "-none"
  local out3 = vim.fn.tempname() .. "-none.jsonl"
  local r3, e3
  if type(export.export) == "function" then r3, e3 = export.export({ root = gone, out = out3 }) end
  ok("a root that doesn't exist is an error, and no file is made", r3 == nil and type(e3) == "string"
    and vim.fn.filereadable(out3) == 0, vim.inspect({ r3, e3 }))

  vim.cmd("runtime! plugin/auto-core.lua")
  ok(":AutoCoreMailboxExport exists", vim.api.nvim_get_commands({})["AutoCoreMailboxExport"] ~= nil)
  local out4 = vim.fn.tempname() .. "-cmd.jsonl"
  local real_notify = vim.notify
  local said
  vim.notify = function(msg) said = tostring(msg) end
  pcall(vim.cmd, "AutoCoreMailboxExport " .. vim.fn.fnameescape(root) .. " " .. vim.fn.fnameescape(out4))
  vim.notify = real_notify
  ok(":AutoCoreMailboxExport <root> <out> writes the file and says where",
    #(vim.fn.filereadable(out4) == 1 and vim.fn.readfile(out4) or {}) == 4 and said ~= nil and said:find(out4, 1, true) ~= nil,
    tostring(said))
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
vim.cmd(fail == 0 and "qa!" or "cq!")
