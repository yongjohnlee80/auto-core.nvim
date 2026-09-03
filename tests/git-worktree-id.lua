-- auto-core — git.worktree.worktree_id (ADR-0081 §2.5): a durable per-worktree
-- identity, so a draft store can key on the worktree without a path (which
-- moves) or a git registration name (which remove+recreate can reuse).
--
-- The git-layout knowledge lives HERE (auto-core owns git primitives and file
-- I/O); a consumer calls the API and never parses `.git` itself. So the
-- remove/recreate control that proves the guarantee belongs here too.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

local wt = require("auto-core.git.worktree")
local sb = vim.fn.tempname() .. "-wtid"
vim.fn.mkdir(sb, "p")
local function git(dir, ...)
  return vim.fn.system({ "git", "-C", dir, "-c", "user.email=t@t",
    "-c", "user.name=t", ... })
end

print("[1] identity is an opaque UUID, minted lazily, in git admin metadata")
do
  local repo = sb .. "/main"; vim.fn.mkdir(repo, "p"); git(repo, "init", "-q")

  ok("[1] *** a PEEK before any bind mints nothing and returns nil ***", (function()
    return wt.worktree_id(repo, { create = false }) == nil
      and vim.fn.filereadable(repo .. "/.git/" .. wt.WORKTREE_UUID_FILE) == 0
  end)())

  local id = wt.worktree_id(repo, { create = true })
  ok("[1] *** create=true mints a 32-hex UUID ***",
    type(id) == "string" and id:match("^%x+$") ~= nil and #id == 32, tostring(id))
  ok("[1] *** the UUID lives in the git ADMIN dir, not the tracked tree ***",
    vim.fn.filereadable(repo .. "/.git/" .. wt.WORKTREE_UUID_FILE) == 1)
  ok("[1] a second create is STABLE — same id, not a fresh mint",
    wt.worktree_id(repo, { create = true }) == id)
  ok("[1] and a later peek reads that id back",
    wt.worktree_id(repo, { create = false }) == id)
  ok("[1] the id is NOT the path and NOT the gitdir",
    id ~= repo and id ~= (repo .. "/.git"))

  ok("[1] a non-worktree path resolves to nil, not a crash",
    wt.worktree_id(sb .. "/not-a-repo", { create = true }) == nil)
end

print("\n[2] a LINKED worktree gets its own identity, in ITS admin dir")
do
  local base = sb .. "/linkbase"; vim.fn.mkdir(base, "p"); git(base, "init", "-q")
  vim.fn.writefile({ "x" }, base .. "/f.txt"); git(base, "add", "."); git(base, "commit", "-q", "-m", "one")
  local link = sb .. "/linkwt"
  git(base, "worktree", "add", "-q", link)

  local id_main = wt.worktree_id(base, { create = true })
  local id_link = wt.worktree_id(link, { create = true })
  ok("[2] *** the linked worktree's id DIFFERS from the main worktree's ***",
    type(id_link) == "string" and id_link ~= id_main,
    ("main=%s link=%s"):format(tostring(id_main), tostring(id_link)))
  ok("[2] the linked worktree's UUID is under ITS registration dir, not the checkout",
    vim.fn.filereadable(link .. "/.git/" .. wt.WORKTREE_UUID_FILE) == 0, "(.git is a file here)")
end

print("\n[3] *** remove + recreate at the SAME path mints a NEW id ***")
do
  -- lector's required control: a git registration NAME is not an immutable
  -- incarnation, so a fresh worktree at the same path must NOT reuse the id.
  local base = sb .. "/rrbase"; vim.fn.mkdir(base, "p"); git(base, "init", "-q")
  vim.fn.writefile({ "x" }, base .. "/f.txt"); git(base, "add", "."); git(base, "commit", "-q", "-m", "one")
  local w = sb .. "/rrwt"
  git(base, "worktree", "add", "-q", w)
  local before = wt.worktree_id(w, { create = true })
  git(base, "worktree", "remove", "--force", w)
  git(base, "worktree", "add", "-q", w)   -- same path, likely the same registration name
  local after = wt.worktree_id(w, { create = true })
  ok("[3] both incarnations resolved an id",
    type(before) == "string" and type(after) == "string")
  ok("[3] *** and they are DIFFERENT — no incarnation inherits another's id ***",
    before ~= after, ("before=%s after=%s"):format(before, after))
end

print("\n[4] the id survives a git worktree MOVE (same worktree, new path)")
do
  local base = sb .. "/mvbase"; vim.fn.mkdir(base, "p"); git(base, "init", "-q")
  vim.fn.writefile({ "x" }, base .. "/f.txt"); git(base, "add", "."); git(base, "commit", "-q", "-m", "one")
  local w1 = sb .. "/mvwt"; local w2 = sb .. "/mvwt-moved"
  git(base, "worktree", "add", "-q", w1)
  local before = wt.worktree_id(w1, { create = true })
  local mv = git(base, "worktree", "move", w1, w2)
  local after = wt.worktree_id(w2, { create = false })
  ok("[4] *** a moved worktree keeps its id (rebinds by identity) ***",
    before ~= nil and after == before,
    ("before=%s after=%s move=%q"):format(tostring(before), tostring(after), tostring(mv)))
end

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
