---auto-core.ui.modal — a title + body + select confirm/prompt modal.
---
---ADR 0195 §2.3. A titled float carrying a readable BODY — so a long name is not
---truncated the way a single-line `vim.ui.select` prompt is — plus a select list
---of role-tagged items. **Irreversibility is an ENFORCED construction input, not
---a caller convention.** An `irreversible` modal removes any affirmative default
---and orders its declining answer FIRST with the cursor on it, so a bare `<CR>`
---cannot fire the destructive action (ADR-0101 D12). Built on
---`ui.float.viewer`; it falls back to `vim.ui.select` — preserving the
---decline-first ordering — when a float cannot be opened.
---
---This is the STRUCTURED, role-aware surface. The legacy `ui.float.confirm`
---adapter keeps its own arbitrary-item / `on_choice(nil)` contract unchanged
---(ADR 0195 §2.3): no role is ever inferred from an arbitrary label there.
---
---Selection: a number key (`1`..`N`, matching the rendered list), the cursor +
---`<CR>`, or a per-item `mnemonic`. `<Esc>` / `q` cancel. Exactly one of
---`on_choice` / `on_cancel` fires, once, across selection, cancel, and an
---external window close.
---@module 'auto-core.ui.modal'

local viewer = require("auto-core.ui.float.viewer")

local M = {}

---@class AutoCoreModalItem
---@field label    string   -- what the reader sees
---@field value    any      -- what on_choice receives (may be nil/false)
---@field role     string?  -- "confirm" | "cancel" (default "confirm")
---@field mnemonic string?  -- optional single-key selector, in addition to its number

---@class AutoCoreModalOpts
---@field title         string?               -- frame title (the question)
---@field body          (string|string[])?    -- the readable detail region
---@field items         AutoCoreModalItem[]   -- >= 1; a cancel-role item is REQUIRED when irreversible
---@field reversibility string                -- REQUIRED: "reversible" | "irreversible"
---@field default       any?                  -- reversible only: the value of the item to focus
---@field on_choice     fun(value: any)?      -- an item was chosen
---@field on_cancel     fun()?                -- dismissed (Esc / q / window close)
---@field opener        integer?              -- window refocused on close if still valid
---@field backend       string?               -- "auto" (default) | "float" | "select"
---@field input         any?                  -- RESERVED (ADR 0195 OQ-4) — not built in P1

local function is_cancel(item) return item.role == "cancel" end

-- Keys the modal OWNS structurally. A caller-supplied mnemonic that collides with
-- one of these would overwrite the protected handler (the safety <CR>, the close
-- keys, or a rendered number key), so a collision is REFUSED at construction
-- rather than silently resolved by keymap-install order (lector, PR#50 P0).
local RESERVED_KEYS = { ["<cr>"] = true, ["<esc>"] = true, ["q"] = true }

---Split a string into buffer lines with the SAME CRLF/LF semantics the viewer
---uses, so the option-line map is computed against exactly what the viewer will
---render — a multiline body must not shift the rendered option rows (lector P1).
---@param s string
---@return string[]
local function split_to_lines(s)
  local out = {}
  for _, part in ipairs(vim.split((s:gsub("\r\n", "\n")), "\n", { plain = true })) do
    out[#out + 1] = part
  end
  return out
end

---The body as a single string, for the degraded `vim.ui.select` prompt so the
---destructive target is not lost precisely in the fallback (lector P2).
---@return string?
local function body_text(opts)
  if opts.body == nil then return nil end
  local body = opts.body
  if type(body) == "string" then body = { body } end
  return table.concat(body, "\n")
end

---Validate + normalize the items, decide the ordering and the initially-focused
---item. This is where the irreversibility policy is ENFORCED (ADR-0195 §2.3):
---an irreversible modal must have a declining answer, that answer is moved to
---the front, and no affirmative default is honoured.
---@param opts AutoCoreModalOpts
---@return AutoCoreModalItem[] items, integer initial, string reversibility
local function prepare(opts)
  local rev = opts.reversibility
  if rev ~= "reversible" and rev ~= "irreversible" then
    error("auto-core modal: `reversibility` must be 'reversible' or 'irreversible', got "
      .. tostring(rev), 3)
  end

  local raw = opts.items
  if type(raw) ~= "table" or rawget(raw, 1) == nil then
    error("auto-core modal: at least one item is required", 3)
  end

  local items = {}
  for i, it in ipairs(raw) do
    if type(it) ~= "table" or type(it.label) ~= "string" then
      error(("auto-core modal: item %d needs a string `label`"):format(i), 3)
    end
    local role = it.role or "confirm"
    if role ~= "confirm" and role ~= "cancel" then
      error(("auto-core modal: item %d has an unknown role %q (want 'confirm' or 'cancel')")
        :format(i, tostring(role)), 3)
    end
    items[i] = { label = it.label, value = it.value, role = role, mnemonic = it.mnemonic }
  end

  -- Refuse any mnemonic that would overwrite a structural key. The safety <CR>,
  -- the close keys, and the rendered number keys (`1`..`N`) belong to the modal,
  -- and a duplicate mnemonic makes one item unreachable — all are construction
  -- errors, so ADR-0101 D12 does not depend on keymap-install order (lector P0).
  local seen_mnemonic = {}
  for i, it in ipairs(items) do
    local m = it.mnemonic
    if m ~= nil then
      if type(m) ~= "string" or m == "" then
        error(("auto-core modal: item %d `mnemonic` must be a non-empty string"):format(i), 3)
      end
      -- A mnemonic is a single quick key, and it is restricted to ONE printable,
      -- non-digit character. This is what makes the collision check sound: a
      -- literal-string comparison is BLIND to Neovim's key ALIASES — `<Enter>`,
      -- `<Return>`, `<C-m>` all normalize to `<CR>`, and `vim.keymap.set` would
      -- then overwrite the protected Enter mapping (lector PR#50 r1 P0). Refusing
      -- all `<...>`/control/multi-char notation means a mnemonic can never spell a
      -- structural key by an alias. Digits are the rendered number-select keys.
      if not m:match("^[%w%p]$") or m:match("^%d$") then
        error(("auto-core modal: item %d mnemonic %q must be a single printable "
          .. "non-digit character (no <...> key notation)"):format(i, m), 3)
      end
      local lower = m:lower()
      if RESERVED_KEYS[lower] then
        error(("auto-core modal: item %d mnemonic %q collides with a reserved key")
          :format(i, m), 3)
      end
      if seen_mnemonic[lower] then
        error(("auto-core modal: item %d mnemonic %q duplicates an earlier item's")
          :format(i, m), 3)
      end
      seen_mnemonic[lower] = true
    end
  end

  local initial = 1
  if rev == "irreversible" then
    local cancel_idx
    for i, it in ipairs(items) do
      if is_cancel(it) then cancel_idx = i; break end
    end
    if not cancel_idx then
      error("auto-core modal: an irreversible modal requires a cancel-role item "
        .. "(the declining answer a bare <CR> must land on)", 3)
    end
    -- Order the declining answer FIRST and put the cursor there. The affirmative
    -- stays reachable by its number, its mnemonic, and a cursor move — it is
    -- simply never the thing already under the cursor (ADR-0101 D12).
    if cancel_idx ~= 1 then
      table.insert(items, 1, table.remove(items, cancel_idx))
    end
    initial = 1
    -- `default` is ignored on purpose: there is no affirmative default here.
  elseif opts.default ~= nil then
    for i, it in ipairs(items) do
      if it.value == opts.default then initial = i; break end
    end
  end

  return items, initial, rev
end

---Build the buffer lines (body, a blank spacer, then the numbered options) and a
---map from option index to its 1-indexed buffer line.
---@return string[] lines, table<integer,integer> option_line
local function build_lines(opts, items)
  local out = {}
  if opts.body ~= nil then
    local body = opts.body
    if type(body) == "string" then body = { body } end
    -- Split embedded newlines HERE, with the viewer's own semantics, so the
    -- option-line map below counts exactly the rows the viewer will render — a
    -- multiline body must not shift the decline row the cursor starts on (P1).
    for _, l in ipairs(body) do
      for _, part in ipairs(split_to_lines(l)) do out[#out + 1] = part end
    end
    out[#out + 1] = ""
  end
  local option_line = {}
  for i, it in ipairs(items) do
    out[#out + 1] = ("%d. %s"):format(i, it.label)
    option_line[i] = #out
  end
  return out, option_line
end

---Open the modal.
---@param opts AutoCoreModalOpts
---@return AutoCoreViewerHandle|table handle
function M.open(opts)
  opts = opts or {}
  -- Capture the invoking window NOW, before any float steals focus, so the
  -- primitive OWNS focus restoration rather than leaving a destructive dialog's
  -- focus lifecycle to each consumer (lector P1). A caller may still override it.
  local opener = opts.opener
  if opener == nil then opener = vim.api.nvim_get_current_win() end

  local items, initial = prepare(opts)

  local backend = opts.backend or "auto"
  if backend ~= "auto" and backend ~= "float" and backend ~= "select" then
    error(("auto-core modal: unknown backend %q (want 'auto' | 'float' | 'select')")
      :format(tostring(backend)), 2)
  end

  local resolved = false
  local handle

  local function resolve_choice(item)
    if resolved then return end
    resolved = true
    if handle then pcall(function() handle:close() end) end
    if opts.on_choice then pcall(opts.on_choice, item.value) end
  end

  local function resolve_cancel()
    if resolved then return end
    resolved = true
    if opts.on_cancel then pcall(opts.on_cancel) end
  end

  -- The `vim.ui.select` fallback. Items are ALREADY ordered decline-first for an
  -- irreversible modal (prepare), so a backend that highlights its first entry
  -- highlights the safe one — ordering is the whole safety mechanism here,
  -- because a picker has no notion of a default. A cancelled select is a decline.
  local function open_select()
    -- Pass the item OBJECTS themselves — not their labels — so duplicate labels
    -- cannot make the first (decline) row resolve to a later affirmative
    -- (lector P1). The prompt carries the body so the destructive target is not
    -- lost in the degraded environment (lector P2).
    local prompt = opts.title or "Confirm"
    local bt = body_text(opts)
    if bt and bt ~= "" then prompt = bt .. "\n" .. prompt end
    vim.ui.select(items, {
      prompt      = prompt,
      format_item = function(it) return it.label end,
    }, function(item)
      if item == nil then resolve_cancel() else resolve_choice(item) end
    end)
    return {
      is_open = function() return not resolved end,
      close   = function() resolve_cancel() end,
    }
  end

  if backend == "select" then
    return open_select()
  end

  local lines, option_line = build_lines(opts, items)

  local keymaps = {}
  keymaps["<CR>"] = function(h)
    local win = h:win()
    if not (win and vim.api.nvim_win_is_valid(win)) then return end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    for i, ln in pairs(option_line) do
      if ln == row then resolve_choice(items[i]); return end
    end
    -- Cursor is on a body line, not an option: a bare <CR> here does nothing.
  end
  for i, it in ipairs(items) do
    keymaps[tostring(i)] = function() resolve_choice(it) end
    if type(it.mnemonic) == "string" and it.mnemonic ~= "" then
      keymaps[it.mnemonic] = function() resolve_choice(it) end
    end
  end

  local ok, h = pcall(viewer, lines, {
    title      = opts.title,
    cursorline = true,
    wrap       = true,
    keymaps    = keymaps,
    opener     = opener,
    on_close   = function() resolve_cancel() end,
  })
  if not ok then
    -- No float could be opened (e.g. a degraded environment). Fall back so the
    -- confirmation still works AND keeps the decline-first safety contract.
    return open_select()
  end
  handle = h

  local win = handle:win()
  if win and vim.api.nvim_win_is_valid(win) and option_line[initial] then
    pcall(vim.api.nvim_win_set_cursor, win, { option_line[initial], 0 })
  end
  return handle
end

return M
