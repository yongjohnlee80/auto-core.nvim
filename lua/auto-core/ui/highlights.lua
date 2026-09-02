---Shared highlight-group registry for the AutoVim family.
---
---Phase 6 per ADR 0006 + auto-core-todos. Provides:
---
---  M.ensure()                       -- register all defaults (idempotent)
---  M.theme_override(name, attrs)    -- runtime override entrypoint
---  M.list()                         -- inspect registered groups
---
---**Default-link semantics.** Every group is registered with
---`{ link = "<existing-nvim-group>", default = true }`. The
---`default = true` flag means the assignment is a no-op if the user
---(or a colorscheme) has already set the group. Consumers can also
---call `theme_override` to swap a link for explicit attrs (fg/bg/
---bold/italic/etc) at runtime; that bypasses `default = true` so it
---takes precedence over scheme-loaded values.
---
---Group catalog:
---  AutoCoreSectionActive  -- the active tab in a panel winbar tab strip
---  AutoCoreSectionInactive -- inactive tabs
---  AutoCorePanelTitle     -- panel-level winbar title text
---  AutoCoreFloatNormal    -- normal text in a help overlay / confirm
---  AutoCoreFloatBorder    -- border around floats
---  AutoCoreFloatTitle     -- centered title on a float (when set)
---  AutoCoreDimmed         -- de-emphasized inline text
---  AutoCoreHelpKey        -- the "<key>" column in help overlays
---  AutoCoreHelpDesc       -- the description column in help overlays
---  AutoCoreGridHeader     -- the column-title row of a result grid
---  AutoCoreDiff*          -- Add/Delete/Change/Context/Header/Hunk (ADR-0060)
---  AutoCoreGit*           -- Added/Modified/Deleted/Renamed/Untracked/
---                            Conflicted: per-file status in the repos tree
---                            (Modified links to the DERIVED tint
---                            AutoCoreGitModifiedBg — see DERIVED_TINT)
---  AutoCoreReview*        -- Frame/Body/MustFix/ShouldFix/Nit/Question/
---                            Resolved: inline review annotations
---
---Future groups can be added to DEFAULTS without breaking consumers
---— `ensure()` is forward-compatible.
---@module 'auto-core.ui.highlights'

local M = {}

---@type table<string, vim.api.keyset.highlight>
local DEFAULTS = {
  AutoCoreSectionActive   = { link = "Title",       default = true },
  AutoCoreSectionInactive = { link = "Comment",     default = true },
  AutoCorePanelTitle      = { link = "Title",       default = true },
  AutoCoreFloatNormal     = { link = "NormalFloat", default = true },
  AutoCoreFloatBorder     = { link = "FloatBorder", default = true },
  AutoCoreFloatTitle      = { link = "FloatTitle",  default = true },
  AutoCoreDimmed          = { link = "Comment",     default = true },
  AutoCoreHelpKey         = { link = "Special",     default = true },
  AutoCoreHelpDesc        = { link = "Comment",     default = true },
  AutoCoreGridHeader      = { link = "Title",       default = true },
  -- ADR-0060: the diff view. Linked to the built-in Diff* groups so every
  -- colourscheme already themes them; `theme_override` still wins.
  AutoCoreDiffAdd         = { link = "DiffAdd",     default = true },
  AutoCoreDiffDelete      = { link = "DiffDelete",  default = true },
  AutoCoreDiffChange      = { link = "DiffChange",  default = true },
  AutoCoreDiffContext     = { link = "Normal",      default = true },
  AutoCoreDiffHeader      = { link = "Title",       default = true },
  AutoCoreDiffHunk        = { link = "Special",     default = true },
  -- ADR-0060 §2.2, colours revised 2026-09-02 (§10): the repos tree's per-file
  -- status colours — added GREEN, modified YELLOW, deleted RED. Modified used
  -- to share DiffAdd's green with only the `+` marker telling them apart; it
  -- now links to AutoCoreGitModifiedBg, a tint DERIVED below from the scheme's
  -- warning colour, because no built-in Diff* group is reliably yellow. Still
  -- `default = true`: a scheme that defines AutoCoreGitModified itself wins.
  AutoCoreGitAdded        = { link = "DiffAdd",     default = true },
  AutoCoreGitModified     = { link = "AutoCoreGitModifiedBg", default = true },
  AutoCoreGitDeleted      = { link = "DiffDelete",  default = true },
  AutoCoreGitRenamed      = { link = "DiffChange",  default = true },
  AutoCoreGitUntracked    = { link = "DiffAdd",     default = true },
  AutoCoreGitConflicted   = { link = "ErrorMsg",    default = true },
  -- ADR-0060 §2.6: inline review annotations rendered as virt_lines.
  AutoCoreReviewFrame     = { link = "Comment",     default = true },
  AutoCoreReviewBody      = { link = "NormalFloat", default = true },
  AutoCoreReviewMustFix   = { link = "DiagnosticError", default = true },
  AutoCoreReviewShouldFix = { link = "DiagnosticWarn",  default = true },
  AutoCoreReviewNit       = { link = "DiagnosticHint",  default = true },
  AutoCoreReviewQuestion  = { link = "DiagnosticInfo",  default = true },
  AutoCoreReviewResolved  = { link = "Comment",     default = true },
}

-- Background-only diff groups (ADR-0065 §2.9).
--
-- They are NOT in DEFAULTS, because they are DERIVED from whatever
-- `DiffAdd`/`DiffDelete` the active colorscheme provides rather than linked to
-- it. A link would inherit the theme's FOREGROUND too, and a `line_hl_group`
-- carrying a foreground competes directly with treesitter's — which is the
-- whole reason the diff panes could not be highlighted before.
local DERIVED_BG = {
  AutoCoreDiffAddBg    = "DiffAdd",
  AutoCoreDiffDeleteBg = "DiffDelete",
}

-- Used when the theme's DiffAdd/DiffDelete carries no `bg` at all — some
-- minimal and monochrome schemes define only a foreground. Painting an
-- attribute-less group would be an invisible no-op that reads as "the diff
-- colouring broke", so we supply our own, chosen to be legible on both a dark
-- and a light background.
-- Tinted groups: a background BLENDED from a theme foreground. Same idea as
-- DERIVED_BG, different source — there is no built-in group to copy a
-- background from.
--
-- `AutoCoreGitModifiedBg` is the repos tree's colour for a MODIFIED file:
-- added GREEN, modified YELLOW, deleted RED (Johno, 2026-09-02, revising
-- ADR-0060 §2.2, where modified shared the green and only the `+` marker told
-- them apart). Added/Deleted link to DiffAdd/DiffDelete, whose backgrounds
-- every scheme themes; nothing in the Diff* family is reliably yellow —
-- DiffChange and Changed are BLUE in catppuccin, tokyonight and Neovim's own
-- default — so the yellow is taken from the scheme's warning colour and
-- blended into Normal's background at about the weight schemes give their own
-- diff tints (catppuccin-mocha's DiffAdd is its green at ~18%). The result is
-- a yellow that belongs to the active palette rather than a hardcoded one, and
-- it sits beside the green and red tints at the same visual weight.
local DERIVED_TINT = {
  AutoCoreGitModifiedBg = { from = { "DiagnosticWarn", "WarningMsg" }, ratio = 0.2 },
}

local FALLBACK_BG = {
  AutoCoreDiffAddBg     = { dark = "#20303b", light = "#d7f0dd" },
  AutoCoreDiffDeleteBg  = { dark = "#3b2028", light = "#f7d9de" },
  -- A transparent scheme gives Normal no background, and a monochrome one may
  -- give the warning groups no foreground: nothing to blend from.
  AutoCoreGitModifiedBg = { dark = "#3b3624", light = "#f5ecc4" },
}

---_blend mixes `fg` into `bg` by `ratio` (0 = bg, 1 = fg). Both are 24-bit RGB
---integers as `nvim_get_hl` returns them; each channel is rounded.
local function _blend(fg, bg, ratio)
  local function channel(shift)
    local f = bit.band(bit.rshift(fg, shift), 0xff)
    local b = bit.band(bit.rshift(bg, shift), 0xff)
    return math.floor(b + (f - b) * ratio + 0.5)
  end
  return bit.bor(bit.lshift(channel(16), 16), bit.lshift(channel(8), 8), channel(0))
end

---_resolved returns a group's EFFECTIVE attributes with links followed, or nil
---when the group cannot be read. See derive_bg_groups for why `link = false`
---is load-bearing.
local function _resolved(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then return hl end
  return nil
end

local function _fallback_bg(name)
  local fb = FALLBACK_BG[name]
  return (vim.o.background == "light") and fb.light or fb.dark
end

---derive_bg_groups recomputes the background-only groups from the ACTIVE
---colorscheme — the DERIVED_BG copies and the DERIVED_TINT blends alike.
---Idempotent, and safe to call on every `ColorScheme`.
---
---`link = false` is load-bearing: `nvim_get_hl` DEFAULTS to returning
---`{ link = "DiffAdd" }` with no attributes at all, and `AutoCoreDiffAdd` is
---itself a link — so the obvious call would silently yield an empty background
---and simply look unstyled. That failure would not have raised anything.
---
---A group claimed by `theme_override` is REAPPLIED, not skipped.
---
---Skipping was wrong and silently destructive: `:colorscheme` CLEARS every
---highlight group before the new scheme defines its own, so a derivation that
---declines to touch an overridden group leaves it **empty** — the override is
---not preserved, it is erased. Reapplying the stored spec is what actually
---keeps the promise that `theme_override` beats colorscheme defaults.
function M.derive_bg_groups()
  for name, source in pairs(DERIVED_BG) do
    local spec = M._overridden[name]
    if spec then
      pcall(vim.api.nvim_set_hl, 0, name, vim.deepcopy(spec))
    else
      local hl = _resolved(source)
      local bg = hl and hl.bg or _fallback_bg(name)
      -- No `fg`, deliberately: a line highlight that carries no foreground
      -- cannot compete with treesitter's, whatever the theme does.
      pcall(vim.api.nvim_set_hl, 0, name, { bg = bg })
    end
  end
  for name, tint in pairs(DERIVED_TINT) do
    local spec = M._overridden[name]
    if spec then
      pcall(vim.api.nvim_set_hl, 0, name, vim.deepcopy(spec))
    else
      local normal = _resolved("Normal")
      local base = normal and normal.bg
      local bg
      if base then
        -- First source that carries a foreground wins; the list is ordered
        -- from the most specifically themed group to the most generic.
        for _, from in ipairs(tint.from) do
          local hl = _resolved(from)
          if hl and hl.fg then
            bg = _blend(hl.fg, base, tint.ratio)
            break
          end
        end
      end
      pcall(vim.api.nvim_set_hl, 0, name, { bg = bg or _fallback_bg(name) })
    end
  end
end

-- Groups an explicit `theme_override` has claimed, and the SPEC it claimed them
-- with. The spec is kept, not just a flag: `:colorscheme` clears every group, so
-- surviving a theme switch means reapplying the attributes, not declining to
-- overwrite them.
M._overridden = {}

local _ensured = false

---Register every default group. Idempotent — safe to call from
---multiple subsystems on every panel open. The `default = true`
---attribute makes each call a no-op when a colorscheme has
---already defined the group.
function M.ensure()
  if _ensured then return end
  for name, spec in pairs(DEFAULTS) do
    pcall(vim.api.nvim_set_hl, 0, name, vim.deepcopy(spec))
  end
  M.derive_bg_groups()

  -- `ensure()` is once-only, so a background copied out of the theme would go
  -- stale the moment the user runs `:colorscheme`. Re-derive on the event.
  --
  -- Only the DERIVED groups are recomputed. An explicit `theme_override` is a
  -- deliberate user/consumer choice and must survive a theme switch — that API
  -- exists precisely to beat colorscheme defaults, so clobbering it here would
  -- undo the one thing it promises.
  pcall(vim.api.nvim_create_autocmd, "ColorScheme", {
    group = vim.api.nvim_create_augroup("AutoCoreDerivedHighlights", { clear = true }),
    callback = function() M.derive_bg_groups() end,
  })
  _ensured = true
end

---Override a registered (or new) highlight group at runtime.
---`attrs` accepts any nvim_set_hl spec (link, fg, bg, bold,
---italic, underline, etc.). Bypasses `default = true` so this
---wins over colorscheme defaults.
---@param name  string
---@param attrs vim.api.keyset.highlight
---@see M.derive_bg_groups for why an override is reapplied rather than skipped
function M.theme_override(name, attrs)
  assert(type(name) == "string" and #name > 0,
    "auto-core.ui.highlights.theme_override: name required")
  assert(type(attrs) == "table",
    "auto-core.ui.highlights.theme_override: attrs table required")
  -- Drop `default` — explicit overrides should always take effect.
  local spec = vim.deepcopy(attrs)
  spec.default = nil
  -- Remembered WITH its attributes, so the ColorScheme re-derivation can put
  -- it back after the scheme clears it.
  M._overridden[name] = vim.deepcopy(spec)
  pcall(vim.api.nvim_set_hl, 0, name, spec)
end

---Snapshot of every group name currently in the canonical
---registry. Order is alphabetical for stable output.
---@return string[]
function M.list()
  local out = {}
  for name in pairs(DEFAULTS) do out[#out + 1] = name end
  table.sort(out)
  return out
end

---Test-only — clears the ensure-once memo so tests can re-exercise
---the registration path.
function M._reset_for_tests()
  M._overridden = {}
  _ensured = false
end

M.DEFAULTS = DEFAULTS

return M
