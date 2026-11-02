---auto-core.export_mailbox — an old file mailbox's archives, as JSONL.
---
---v0.6.0 has no file mailbox (ADR 1793271500 phase 5): AutoDoc's crew carries every
---message. The trees an older auto-core wrote stay on disk, and nothing deletes or
---rewrites them. This reads one: every `archive/*.json` under its root, in path
---order, becomes one line, `{ path, message }`, with the path relative to the root.
---A file that doesn't parse is carried as `{ path, raw, decode_error }`. It only
---ever reads the tree, and it refuses an output inside it.
---@module 'auto-core.export_mailbox'

local M = {}

local SUFFIX = ".auto-agents/mailbox"

---default_root is the project's old mailbox tree: `<workspace>/.auto-agents/mailbox`.
---@return string
function M.default_root()
  local ok, ws = pcall(function() return require("auto-core.git.worktree").get_workspace_root() end)
  local base = (ok and type(ws) == "string" and ws ~= "") and ws or vim.fn.getcwd()
  return base .. "/" .. SUFFIX
end

---default_out is where an export goes when no file is named: Neovim's state folder, outside
---every tree.
---@return string
function M.default_out()
  return vim.fn.stdpath("state") .. "/auto-core/mailbox-export-" .. os.date("!%Y%m%dT%H%M%SZ") .. ".jsonl"
end

local function abs(p) return (vim.fn.fnamemodify(p, ":p"):gsub("/+$", "")) end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

---export writes root's archived messages to out, one JSON object per line.
---@param opts { root: string?, out: string? }?
---@return { count: integer, out: string }? result, string? err
function M.export(opts)
  opts = opts or {}
  local root = abs(opts.root or M.default_root())
  local out = abs(opts.out or M.default_out())
  if vim.fn.isdirectory(root) == 0 then
    return nil, "no mailbox tree at " .. root
  end
  if out == root or out:sub(1, #root + 1) == root .. "/" then
    return nil, "the export must go outside the tree it reads (" .. root .. ")"
  end
  local files = vim.fn.globpath(root, "**/archive/*.json", true, true)
  local rel = {}
  for _, p in ipairs(files) do
    local a = abs(p)
    if vim.fn.isdirectory(a) == 0 and a:sub(1, #root + 1) == root .. "/" then
      rel[#rel + 1] = a:sub(#root + 2)
    end
  end
  table.sort(rel)
  local lines = {}
  for _, r in ipairs(rel) do
    local text = read(root .. "/" .. r)
    local row = { path = r }
    if text == nil then
      row.decode_error = "unreadable"
    else
      local ok, msg = pcall(vim.json.decode, text)
      if ok and type(msg) == "table" then
        row.message = msg
      else
        row.raw, row.decode_error = text, ok and "not a JSON object" or tostring(msg)
      end
    end
    lines[#lines + 1] = vim.json.encode(row)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
  local text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
  local ok, err = require("auto-core.fs.atomic").write(out, text)
  if not ok then return nil, "could not write " .. out .. ": " .. tostring(err) end
  return { count = #lines, out = out }
end

return M
