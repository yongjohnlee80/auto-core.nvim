-- tests/git_read.lua — hardened repository reads (ADR-0069 revision 5).
-- Run: nvim --headless -u NONE -l tests/git_read.lua

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, condition, detail)
  local line = condition and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n")
  io.stdout:flush()
  if condition then pass = pass + 1 else fail = fail + 1 end
end

local real_system = vim.system
local reload_names = {
  "auto-core.git", "auto-core.git.version", "auto-core.git._read",
  "auto-core.git.repo", "auto-core.git.worktree", "auto-core.git.log",
}
local function reload_git()
  for _, name in ipairs(reload_names) do package.loaded[name] = nil end
  return require("auto-core.git")
end

local function mock_system(version_result, query_results)
  local calls, pending = {}, {}
  vim.system = function(argv, opts, callback)
    calls[#calls + 1] = vim.deepcopy(argv)
    local result
    if #argv == 2 and argv[1] == "git" and argv[2] == "--version" then
      result = version_result
    else
      result = query_results and query_results[argv[#argv]]
        or { code = 0, stdout = "", stderr = "" }
    end
    if result and result.throw then error(result.throw) end
    result = vim.deepcopy(result or { code = 0, stdout = "", stderr = "" })
    if callback then
      if result.defer then
        pending[argv[#argv]] = { callback = callback, result = result }
      else
        callback(result)
        if result.double then callback(result) end
      end
      return {}
    end
    return { wait = function() return result end }
  end
  return calls, pending
end

local function restore_system()
  vim.system = real_system
end

local function repo_call_count(calls)
  local count = 0
  for _, argv in ipairs(calls) do
    if not (#argv == 2 and argv[2] == "--version") then count = count + 1 end
  end
  return count
end

io.stdout:write("auto-core git reads -- ADR-0069 revision 5\n")

-- Version parsing, lexicographic thresholds, copies, and failure memoization.
do
  local cases = {
    { "2.11", false }, { "2.12.9", false }, { "2.13.0", false },
    { "2.14.99", false }, { "2.15", true }, { "2.15.0", true },
    { "3.0.0", true }, { "2.43.0.windows.1", true },
  }
  for _, case in ipairs(cases) do
    local calls = mock_system({ code = 0, stdout = "git version " .. case[1] .. "\n" })
    local git = reload_git()
    local parsed = git.version()
    ok("version parses " .. case[1], parsed ~= nil, vim.inspect(parsed))
    ok("version_at_least is lexicographic for " .. case[1],
      git.version_at_least(2, 15) == case[2])
    ok("version probe is memoized for " .. case[1], #calls == 1, #calls)
    restore_system()
  end

  local calls = mock_system({ code = 0, stdout = "git version 2.15.7.vendor\n" })
  local git = reload_git()
  local first = git.version()
  first.major = 99
  ok("version returns a copy of cached state", git.version().major == 2)
  ok("version argv is exactly git --version",
    vim.deep_equal(calls[1], { "git", "--version" }), vim.inspect(calls[1]))
  restore_system()

  calls = mock_system({ throw = "ENOENT" })
  git = reload_git()
  local missing, missing_err = git.version()
  git.version(); git.version_at_least(2, 15)
  ok("missing Git is a cached failure", missing == nil and missing_err ~= nil and #calls == 1,
    #calls)
  restore_system()

  calls = mock_system({ code = 0, stdout = "not a git version\n" })
  git = reload_git()
  local malformed, malformed_err = git.version()
  git.version(); git.version_at_least(2, 15)
  ok("malformed version is a cached failure",
    malformed == nil and malformed_err ~= nil and #calls == 1, #calls)
  restore_system()
end

-- Hardened argv and list_refs compatibility grammar.
do
  local refs_blob = table.concat({
    "refs/heads/main", "refs/heads/same", "refs/notes/review",
    "refs/remotes/origin/HEAD", "refs/remotes/origin/main",
    "refs/tags/same", "refs/tags/v1", "refs/x1/ignored",
  }, "\n") .. "\n"
  local calls = mock_system(
    { code = 0, stdout = "git version 2.15.0\n" },
    { refs = { code = 0, stdout = refs_blob } })
  -- The result is selected by the final argv value; list_refs ends in "refs".
  local git = reload_git()
  local refs, err = git.worktree.list_refs("/repo path")
  local expected = {
    "main", "same", "review", "origin/HEAD", "origin/main", "same", "v1",
  }
  ok("list_refs preserves full-ref order, duplicates, remote HEAD, and custom namespaces",
    err == nil and vim.deep_equal(refs, expected), vim.inspect(refs))
  local expected_argv = {
    "git", "--no-pager", "--no-optional-locks",
    "-c", "gc.auto=0", "-c", "core.quotepath=off",
    "-c", "color.ui=false", "-c", "color.diff=false",
    "--literal-pathspecs", "-C", "/repo path",
    "for-each-ref", "--sort=refname", "--format=%(refname)", "refs",
  }
  ok("list_refs uses the exact hardened argv", vim.deep_equal(calls[2], expected_argv),
    vim.inspect(calls[2]))
  restore_system()

  calls = mock_system({ code = 0, stdout = "git version 2.15\n" },
    { refs = { code = 0, stdout = "" } })
  git = reload_git()
  refs, err = git.worktree.list_refs("/unborn")
  ok("list_refs returns an empty table for an unborn repository",
    err == nil and type(refs) == "table" and #refs == 0)
  restore_system()

  calls = mock_system({ code = 0, stdout = "git version 2.15\n" },
    { refs = { code = 128, stderr = "not a repository" } })
  git = reload_git()
  refs, err = git.worktree.list_refs("/not-repo")
  ok("list_refs distinguishes repository failure from no refs", refs == nil and err ~= nil)
  restore_system()

  calls = mock_system({ code = 0, stdout = "git version 2.14.9\n" })
  git = reload_git()
  refs, err = git.worktree.list_refs("/repo")
  ok("list_refs refuses Git below 2.15 before a repository process",
    refs == nil and err == "Git 2.15+ required" and repo_call_count(calls) == 0,
    vim.inspect(calls))
  restore_system()
end

local base_discovery = {
  ["--absolute-git-dir"] = { code = 0, stdout = "/r/.git\n" },
  ["--show-toplevel"] = { code = 0, stdout = "/r\n" },
  ["--show-superproject-working-tree"] = { code = 0, stdout = "\n" },
}

-- Every synchronous aggregation row and fixed precedence.
do
  local cases = {
    { "success", {}, true, nil },
    { "git-dir spawn", { ["--absolute-git-dir"] = { throw = "spawn" } }, false, "spawn" },
    { "not repository", { ["--absolute-git-dir"] = { code = 128, stderr = "no" } }, false, "not_repo" },
    { "empty git-dir", { ["--absolute-git-dir"] = { code = 0, stdout = "\n" } }, false, "malformed" },
    { "root spawn", { ["--show-toplevel"] = { throw = "spawn" } }, false, "spawn" },
    { "bare root", { ["--show-toplevel"] = { code = 128, stderr = "bare" } }, true, nil },
    { "empty root", { ["--show-toplevel"] = { code = 0, stdout = "\n" } }, false, "malformed" },
    { "superproject spawn", { ["--show-superproject-working-tree"] = { throw = "spawn" } }, false, "spawn" },
    { "superproject git failure", { ["--show-superproject-working-tree"] = { code = 9, stderr = "bad" } }, false, "git" },
  }
  for _, case in ipairs(cases) do
    local outcomes = vim.deepcopy(base_discovery)
    for key, value in pairs(case[2]) do outcomes[key] = value end
    local calls = mock_system({ code = 0, stdout = "git version 2.15\n" }, outcomes)
    local result = reload_git().repo.discover("/input")
    ok("discover aggregates " .. case[1], result.ok == case[3] and result.kind == case[4],
      vim.inspect(result))
    if result.ok then
      ok("discover success has no error metadata for " .. case[1],
        result.error == nil and result.code == nil and result.git_dir == "/r/.git",
        vim.inspect(result))
    else
      ok("discover failure has no partial paths for " .. case[1],
        result.git_dir == nil and result.worktree_root == nil
          and result.superproject_worktree_root == nil, vim.inspect(result))
    end
    restore_system()
  end

  local outcomes = vim.deepcopy(base_discovery)
  outcomes["--absolute-git-dir"] = { code = 128, stderr = "primary" }
  outcomes["--show-toplevel"] = { throw = "secondary" }
  outcomes["--show-superproject-working-tree"] = { code = 7, stderr = "later" }
  mock_system({ code = 0, stdout = "git version 2.15\n" }, outcomes)
  local result = reload_git().repo.discover("/input")
  ok("discover precedence is git-dir before root before superproject",
    result.kind == "not_repo" and result.code == 128, vim.inspect(result))
  restore_system()

  local calls = mock_system({ code = 0, stdout = "git version 2.14\n" })
  result = reload_git().repo.discover("/input")
  ok("discover reports unsupported and starts no repository process below floor",
    result.ok == false and result.kind == "unsupported"
      and result.error == "Git 2.15+ required" and repo_call_count(calls) == 0,
    vim.inspect(result))
  restore_system()
end

-- Raw output preserves path bytes; the internal platform rule is pinned too.
do
  local outcomes = vim.deepcopy(base_discovery)
  outcomes["--absolute-git-dir"] = { code = 0, stdout = "/repo\nname/.git\n" }
  outcomes["--show-toplevel"] = { code = 0, stdout = "/repo/trailing\r\n" }
  outcomes["--show-superproject-working-tree"] = { code = 0, stdout = "/super\nroot\n" }
  mock_system({ code = 0, stdout = "git version 2.15\n" }, outcomes)
  local result = reload_git().repo.discover("/input")
  ok("discover removes only one POSIX LF and preserves embedded newline",
    result.git_dir == "/repo\nname/.git" and result.superproject_worktree_root == "/super\nroot",
    vim.inspect(result))
  ok("discover preserves a legal POSIX trailing CR before Git's LF",
    result.worktree_root == "/repo/trailing\r", vim.inspect(result.worktree_root))
  local read = require("auto-core.git._read")
  ok("native Windows strips one CRLF terminator",
    read.strip_terminator("C:\\repo\r\n", true) == "C:\\repo")
  ok("native Windows otherwise strips one LF terminator",
    read.strip_terminator("C:\\repo\n", true) == "C:\\repo")
  ok("POSIX strips LF only, retaining CR",
    read.strip_terminator("/repo\r\n", false) == "/repo\r")
  restore_system()
end

-- Async outcomes: exactly once, always scheduled, all queries concurrent.
do
  local cases = {
    { "success", "2.15", {}, nil },
    { "not_repo", "2.15", { ["--absolute-git-dir"] = { code = 128 } }, "not_repo" },
    { "spawn", "2.15", { ["--show-toplevel"] = { throw = "spawn" } }, "spawn" },
    { "git", "2.15", { ["--show-superproject-working-tree"] = { code = 5 } }, "git" },
    { "malformed", "2.15", { ["--absolute-git-dir"] = { code = 0, stdout = "\n" } }, "malformed" },
    { "unsupported", "2.14", {}, "unsupported" },
  }
  for _, case in ipairs(cases) do
    local outcomes = vim.deepcopy(base_discovery)
    for key, value in pairs(case[3]) do outcomes[key] = value end
    local calls = mock_system({ code = 0, stdout = "git version " .. case[2] .. "\n" }, outcomes)
    local count, result = 0, nil
    reload_git().repo.discover_async("/input", function(value)
      count, result = count + 1, value
    end)
    ok("discover_async does not deliver " .. case[1] .. " inline", count == 0, count)
    vim.wait(1000, function() return count > 0 end, 5)
    ok("discover_async delivers " .. case[1] .. " exactly once",
      count == 1 and result and result.kind == case[4], vim.inspect(result))
    local want_repo_calls = case[1] == "unsupported" and 0 or 3
    ok("discover_async starts the expected queries for " .. case[1],
      repo_call_count(calls) == want_repo_calls, vim.inspect(calls))
    restore_system()
  end

  local outcomes = vim.deepcopy(base_discovery)
  for _, value in pairs(outcomes) do value.defer = true end
  outcomes["--absolute-git-dir"] = { code = 128, stderr = "primary", defer = true }
  outcomes["--show-toplevel"] = { code = 0, stdout = "\n", defer = true }
  outcomes["--show-superproject-working-tree"] = { code = 4, defer = true }
  local _, pending = mock_system({ code = 0, stdout = "git version 2.15\n" }, outcomes)
  local count, result = 0, nil
  reload_git().repo.discover_async("/input", function(value)
    count, result = count + 1, value
  end)
  for _, option in ipairs({
    "--show-superproject-working-tree", "--show-toplevel", "--absolute-git-dir",
  }) do
    local item = pending[option]
    item.callback(item.result)
    item.callback(item.result)
  end
  vim.wait(1000, function() return count > 0 end, 5)
  ok("discover_async precedence ignores completion order and duplicate settlements",
    count == 1 and result.kind == "not_repo" and result.code == 128, vim.inspect(result))
  restore_system()

  local calls = mock_system({ code = 0, stdout = "git version 2.15\n" }, base_discovery)
  local git = reload_git()
  local raised = not pcall(git.repo.discover_async, "/input", "not a callback")
  ok("discover_async rejects an invalid callback before any process",
    raised and #calls == 0, vim.inspect(calls))
  restore_system()
end

-- rev_exists_at argv validation and unsupported floor under a process mock.
do
  local calls = mock_system({ code = 0, stdout = "git version 2.15\n" }, {
    ["HEAD; touch marker^{commit}"] = { code = 1 },
  })
  local git = reload_git()
  local exists, err = git.log.rev_exists_at("/repo path", "HEAD; touch marker")
  ok("rev_exists_at keeps a metacharacter ref in one argv element", exists == false and err == nil)
  local argv = calls[2]
  ok("rev_exists_at uses one hardened cwd process and a separate ref value",
    argv[#argv] == "HEAD; touch marker^{commit}" and argv[#argv - 1] == "--quiet"
      and argv[#argv - 3] == "rev-parse" and repo_call_count(calls) == 1,
    vim.inspect(argv))
  local before = #calls
  ok("rev_exists_at rejects empty, NUL, and option-shaped refs before spawning",
    git.log.rev_exists_at("/repo", "") == false
      and git.log.rev_exists_at("/repo", "bad\0ref") == false
      and git.log.rev_exists_at("/repo", "--help") == false
      and #calls == before)
  restore_system()

  calls = mock_system({ code = 0, stdout = "git version 2.14\n" })
  git = reload_git()
  exists, err = git.log.rev_exists_at("/repo", "HEAD")
  ok("rev_exists_at returns the floor error without a repository process",
    exists == false and err == "Git 2.15+ required" and repo_call_count(calls) == 0)
  restore_system()
end

-- Real Git controls for ref compatibility and commit-ish cwd validation.
do
  restore_system()
  local git = reload_git()
  ok("new APIs are exported at their documented levels",
    type(git.version) == "function" and type(git.version_at_least) == "function"
      and type(git.worktree.list_refs) == "function"
      and type(git.repo.discover) == "function" and type(git.repo.discover_async) == "function"
      and type(git.log.rev_exists_at) == "function")

  local function run(cwd, args)
    local argv = { "git", "-C", cwd }
    vim.list_extend(argv, args)
    return real_system(argv, { text = true }):wait()
  end
  local function new_repo(label)
    local dir = vim.fn.tempname() .. "-" .. label
    vim.fn.mkdir(dir, "p")
    run(dir, { "init", "-q", "-b", "main" })
    run(dir, { "config", "user.email", "test@example.com" })
    run(dir, { "config", "user.name", "Test" })
    vim.fn.writefile({ label }, dir .. "/tracked.txt")
    run(dir, { "add", "tracked.txt" })
    run(dir, { "commit", "-q", "-m", "initial" })
    return dir
  end

  local one, two = new_repo("one"), new_repo("two")
  run(one, { "branch", "same" })
  run(one, { "tag", "same" })
  run(one, { "tag", "light" })
  run(one, { "tag", "-a", "annotated", "-m", "annotated" })
  local head = vim.trim(run(one, { "rev-parse", "HEAD" }).stdout or "")
  run(one, { "update-ref", "refs/remotes/origin/main", head })
  run(one, { "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" })
  run(one, { "update-ref", "refs/notes/review", head })
  run(one, { "branch", "only-one" })
  run(two, { "branch", "only-two" })

  local refs, refs_err = git.worktree.list_refs(one)
  local counts = {}
  for _, ref in ipairs(refs or {}) do counts[ref] = (counts[ref] or 0) + 1 end
  ok("real list_refs includes branch/tag duplicates, remote HEAD, and notes",
    refs_err == nil and counts.same == 2 and counts["origin/HEAD"] == 1
      and counts.review == 1, vim.inspect(refs))

  local discovery = git.repo.discover(one)
  ok("real discover returns authoritative paths",
    discovery.ok and discovery.git_dir ~= nil and discovery.worktree_root == one,
    vim.inspect(discovery))

  ok("rev_exists_at validates branches and lightweight/annotated tags",
    git.log.rev_exists_at(one, "main")
      and git.log.rev_exists_at(one, "light")
      and git.log.rev_exists_at(one, "annotated"))
  local blob = vim.trim(run(one, { "rev-parse", "HEAD:tracked.txt" }).stdout or "")
  local tree = vim.trim(run(one, { "rev-parse", "HEAD^{tree}" }).stdout or "")
  ok("rev_exists_at rejects blobs, trees, and missing refs",
    not git.log.rev_exists_at(one, blob)
      and not git.log.rev_exists_at(one, tree)
      and not git.log.rev_exists_at(one, "does-not-exist"))
  ok("rev_exists_at selects the repository by cwd",
    git.log.rev_exists_at(one, "only-one") and not git.log.rev_exists_at(two, "only-one")
      and git.log.rev_exists_at(two, "only-two"))

  local marker = vim.fn.tempname() .. "-must-not-exist"
  local malicious = "HEAD; touch " .. marker
  ok("rev_exists_at shell metacharacters have no side effect",
    not git.log.rev_exists_at(one, malicious) and vim.uv.fs_stat(marker) == nil)

  vim.fn.delete(one, "rf")
  vim.fn.delete(two, "rf")
end

restore_system()
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
