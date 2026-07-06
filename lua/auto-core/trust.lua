---Generic workspace-scoped capability trust store (ADR-0048 §12).
---
---Promotes the ADR-0035 bash trust model out of `todo/automation.lua`
---into a reusable primitive. A *capability* is a named permission for
---a plugin to perform an execution-class action driven by plain-text
---project files or remote (mailbox) requests — e.g. `todo.bash`,
---`run.exec`, `run.command_env`. Each capability carries:
---
---  • `enabled`                 — off by default, always.
---  • `first_run_acknowledged`  — set ONLY by an interactive user
---    path (`acknowledge_first_run`). `set{enabled=true}` refuses
---    until the ack has landed, unless `force=true` — and mailbox
---    wiring must always call with `force=false` (or omit it), so a
---    remote agent can never bootstrap its own trust (ADR-0035 §4.5).
---  • `allowlist`               — optional list of Lua patterns. When
---    non-empty, `check(capability, subject)` additionally requires
---    the subject (a command string, config name, …) to match at
---    least one pattern.
---
---Storage: one record per capability under the `caps` key of
---`auto-core.state.namespace("auto-core.trust")`. Capability names
---may contain dots (`run.exec`); records are read/written as whole
---tables (never via dot-path traversal) so names can never collide
---with the state store's nested-key syntax.
---
---Per [[auto-core-maintenance]] #6 this module never notifies; it
---returns structured `(ok, reason)` pairs and consumers own the UX
---(prompts, panel warnings, mailbox error envelopes).
---@module 'auto-core.trust'

local M = {}

local STATE_NS = "auto-core.trust"

local function _state() return require("auto-core.state") end

local function _ns()
  return _state().namespace(STATE_NS, {
    schema = {
      caps = { kind = "any", default = nil },
    },
    persist = "json",
  })
end

---@class AutoCoreTrustState
---@field enabled boolean
---@field allowlist string[]|nil
---@field first_run_acknowledged boolean

local function _assert_capability(capability, caller)
  if type(capability) ~= "string" or capability == "" then
    error(caller .. ": capability must be a non-empty string")
  end
end

---Read the raw stored record for a capability (nil when the
---capability has never been written).
---@param capability string
---@return table|nil
local function _read(capability)
  local caps = _ns():get("caps")
  if type(caps) ~= "table" then return nil end
  local rec = caps[capability]
  if type(rec) ~= "table" then return nil end
  return rec
end

---Overwrite a capability's stored record (whole-table write — see
---module doc for why dot-path writes are off-limits here).
---@param capability string
---@param rec table
local function _write(capability, rec)
  local ns = _ns()
  local caps = ns:get("caps")
  caps = type(caps) == "table" and vim.deepcopy(caps) or {}
  caps[capability] = rec
  ns:set("caps", caps)
end

---Has this capability ever been written? Distinguishes "user set it
---back to defaults" from "never touched" — the todo.bash legacy
---migration keys off this.
---@param capability string
---@return boolean
function M.has_state(capability)
  _assert_capability(capability, "auto-core.trust.has_state")
  return _read(capability) ~= nil
end

---Current effective state for a capability. Unwritten capabilities
---return the all-off defaults.
---@param capability string
---@return AutoCoreTrustState
function M.state(capability)
  _assert_capability(capability, "auto-core.trust.state")
  local rec = _read(capability) or {}
  return {
    enabled                 = rec.enabled == true,
    allowlist               = rec.allowlist,
    first_run_acknowledged  = rec.first_run_acknowledged == true,
  }
end

---Programmatic trust setter. Returns `(ok, err)`. Refuses to flip
---`enabled` to true unless `first_run_acknowledged` is already true —
---the interactive path (`acknowledge_first_run`) must land first.
---`force = true` skips that gate; mailbox wiring MUST NOT pass it
---(ADR-0035 §4.5 / ADR-0048 §11-§12).
---
---`allowlist` accepts a list of Lua-pattern strings; `false` or `""`
---clears it. Setting `enabled = false` never requires the ack.
---@param capability string
---@param opts { enabled: boolean?, allowlist: any?, force: boolean? }?
---@return boolean ok, string? err
function M.set(capability, opts)
  _assert_capability(capability, "auto-core.trust.set")
  opts = opts or {}
  local cur = _read(capability) or {}
  local rec = {
    enabled                = cur.enabled == true,
    allowlist              = cur.allowlist,
    first_run_acknowledged = cur.first_run_acknowledged == true,
  }

  if opts.enabled ~= nil then
    if opts.enabled == true
        and rec.first_run_acknowledged ~= true
        and opts.force ~= true
    then
      return false, "trust_not_acknowledged"
    end
    rec.enabled = opts.enabled == true
  end

  if opts.allowlist ~= nil then
    if opts.allowlist == false or opts.allowlist == "" then
      rec.allowlist = nil
    elseif type(opts.allowlist) == "table" then
      for _, pat in ipairs(opts.allowlist) do
        if type(pat) ~= "string" then
          return false, "allowlist entries must be strings"
        end
      end
      rec.allowlist = opts.allowlist
    else
      return false, "allowlist must be a list of strings or nil"
    end
  end

  _write(capability, rec)
  return true, nil
end

---Acknowledge the first-run trust prompt for a capability. Interactive
---user-command paths ONLY — never reachable from mailbox handlers.
---@param capability string
function M.acknowledge_first_run(capability)
  _assert_capability(capability, "auto-core.trust.acknowledge_first_run")
  local cur = _read(capability) or {}
  _write(capability, {
    enabled                = cur.enabled == true,
    allowlist              = cur.allowlist,
    first_run_acknowledged = true,
  })
end

---Gate check. `(true)` when the capability is enabled and — if an
---allowlist is set and a subject was supplied — the subject matches
---at least one allowlist pattern.
---
---Reasons on the false path: `"disabled"`, `"allowlist_rejected"`.
---An enabled capability with an allowlist but NO subject passes: the
---caller has nothing to match, and per-subject enforcement is the
---call sites' contract (they pass the command/config-name they're
---about to act on).
---@param capability string
---@param subject string?
---@return boolean ok, string? reason
function M.check(capability, subject)
  _assert_capability(capability, "auto-core.trust.check")
  local s = M.state(capability)
  if not s.enabled then
    return false, "disabled"
  end
  if type(s.allowlist) == "table" and #s.allowlist > 0
      and type(subject) == "string"
  then
    for _, pat in ipairs(s.allowlist) do
      if type(pat) == "string" and subject:match(pat) then
        return true, nil
      end
    end
    return false, "allowlist_rejected"
  end
  return true, nil
end

---Test-only: wipe every capability record. Not part of the public
---API stability contract.
function M._reset_for_tests()
  _ns():set("caps", nil)
end

return M