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

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
vim.cmd(fail == 0 and "qa!" or "cq!")
