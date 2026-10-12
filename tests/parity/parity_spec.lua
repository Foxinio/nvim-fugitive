local H = require("helpers")
local P = require("parity.harness")
local B = require("fixtures.browse_cases")

local function skip()
  if not P.upstream() then
    pending("set UPSTREAM to a vim-fugitive checkout (make parity)")
    return true
  end
end

describe("parity with upstream vim-fugitive", function()
  before_each(function()
    H.reset_ui()
  end)

  local scenarios = {
    {
      "untracked, unstaged, staged and renamed files",
      function()
        local repo = P.repo({ ["a.txt"] = "a\n", ["old.txt"] = "o\n", ["b.txt"] = "b\n" })
        repo:write("a.txt", "A\n")
        repo:write("new.txt", "n\n")
        repo:write("dir/nested.txt", "n\n")
        repo:write("b.txt", "B\n")
        repo:git("add", "b.txt")
        repo:git("mv", "old.txt", "renamed.txt")
        os.remove(repo:path("a.txt"))
        return repo
      end,
    },
    {
      "unborn branch",
      function()
        local repo = P.repo()
        repo:write("first", "1\n")
        repo:git("add", "first")
        return repo
      end,
    },
    {
      "detached HEAD",
      function()
        local repo = P.repo({ ["a"] = "a\n" })
        P.commit(repo, "second", { ["a"] = "b\n" })
        repo:git("checkout", "-q", "--detach", "HEAD~1")
        repo:write("a", "changed\n")
        return repo
      end,
    },
    {
      "ahead of and behind the upstream",
      function()
        local origin = P.repo({ ["f"] = "1\n" })
        local clone = H.clone(origin)
        P.commit(origin, "upstream side", { ["g"] = "g\n" })
        clone:git("fetch", "-q")
        P.commit(clone, "local side", { ["h"] = "h\n" })
        return clone
      end,
    },
    {
      "push remote differs from the upstream",
      function()
        local origin = P.repo({ ["f"] = "1\n" })
        local clone = H.clone(origin)
        clone:git("remote", "add", "fork", origin.root)
        clone:git("fetch", "-q", "fork")
        clone:git("config", "remote.pushDefault", "fork")
        P.commit(clone, "local side", { ["h"] = "h\n" })
        return clone
      end,
    },
    {
      "rebase -i stopped on edit",
      function()
        local repo = P.repo({ ["a"] = "a\n" })
        P.commit(repo, "second", { ["b"] = "b\n" })
        P.commit(repo, "third", { ["c"] = "c\n" })
        repo:git(
          "-c",
          "sequence.editor=sed -i 1s/^pick/edit/",
          "rebase",
          "-q",
          "-i",
          "HEAD~2",
          { env = P.env }
        )
        return repo
      end,
    },
  }

  for _, sc in ipairs(scenarios) do
    it("summary text: " .. sc[1], function()
      if skip() then
        return
      end
      local repo = sc[2]()
      local upstream = P.upstream_summary(repo)
      local ours = P.our_summary(repo)
      -- deliberate deviation: newer git writes "pick <oid> # <subject>" in the
      -- todo list; upstream shows the "# ", we strip it
      if type(upstream) == "table" then
        for i, l in ipairs(upstream) do
          upstream[i] = l:gsub("^(%l+ %x+) # ", "%1 ")
        end
      end
      assert.same(upstream, ours)
    end)
  end

  local map_scenarios = {
    { "s on an unstaged file", "^M a", "s" },
    { "s on the Unstaged heading", "^Unstaged", "s" },
    { "u on a staged file", "^M b", "u" },
    { "- on an untracked file", "^%? new", "-" },
    { "U", "^Head", "U" },
    { "X on an unstaged file", "^M a", "X" },
  }
  for _, ms in ipairs(map_scenarios) do
    it("repo state after " .. ms[1], function()
      if skip() then
        return
      end
      local function build()
        local repo = P.repo({ ["a"] = "a\n", ["b"] = "b\n" })
        repo:write("a", "A\n")
        repo:write("b", "B\n")
        repo:git("add", "b")
        repo:write("new", "n\n")
        return repo
      end
      local up, ours = build(), build()
      local lua_pattern = ms[2]
      local vim_pattern = lua_pattern:gsub("%%", "\\")
      P.run_upstream(up.root, {
        "Git",
        "call search(" .. vim.fn.string(vim_pattern) .. ")",
        "exe 'normal " .. ms[3] .. "'",
        "sleep 300m",
        "let g:result = 1",
      })
      P.our_summary(ours)
      local buf = vim.api.nvim_get_current_buf()
      local st = require("nvim-fugitive.buffers.summary").state(buf)
      vim.api.nvim_win_set_cursor(0, { assert(H.find_line(lua_pattern)), 0 })
      local tick = st.tick
      H.feed(ms[3])
      H.wait(function()
        return st.tick > tick
      end)
      assert.equals(up:status(), ours:status())
      assert.equals(up:read("a"), ours:read("a"))
    end)
  end

  it("object resolution matches FugitiveFind()", function()
    if skip() then
      return
    end
    local repo = P.repo({ ["dir/f.txt"] = "1\n", ["Makefile"] = "all:\n" })
    P.commit(repo, "second", { ["dir/f.txt"] = "2\n" })
    P.commit(repo, "fix the frobnicator", { ["dir/f.txt"] = "3\n" })
    local specs = {
      "@",
      "HEAD^",
      "@^:dir/f.txt",
      "main:",
      ":Makefile",
      ":2:dir/f.txt",
      "Makefile",
      ":(top)dir/f.txt",
      ".git/config",
      ":",
      ":/frobnicator",
      "@~2:%",
      ":%",
    }
    local lines = { "edit dir/f.txt", "let g:result = {}" }
    for _, s in ipairs(specs) do
      table.insert(
        lines,
        "let g:result["
          .. vim.fn.string(s)
          .. "] = FugitiveFind(fugitive#Expand("
          .. vim.fn.string(s)
          .. "))"
      )
    end
    local upstream = P.run_upstream(repo.root, lines)
    H.reset_ui()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit dir/f.txt")
    local object = require("nvim-fugitive.object")
    local r = require("nvim-fugitive.git.repo").find(repo.root)
    for _, s in ipairs(specs) do
      local ours = object.find(r, object.expand(s, r))
      assert.equals(upstream[s], ours, s)
    end
  end)

  it("the Vimscript API answers like upstream", function()
    if skip() then
      return
    end
    local repo = P.repo({ ["dir/f.txt"] = "1\n" })
    P.commit(repo, "second", { ["dir/f.txt"] = "2\n" })
    repo:git("remote", "add", "origin", "https://example.com/r.git")
    local sha = repo:rev("HEAD")
    local blob = "fugitive://" .. repo.root .. "/.git//" .. sha .. "/dir/f.txt"
    local exprs = {
      "FugitiveGitDir()",
      "FugitiveWorkTree()",
      "FugitiveHead()",
      "FugitiveHead(7)",
      "FugitiveHead(-1)",
      "FugitiveStatusline()",
      "FugitiveConfigGet('user.name')",
      "FugitiveRemoteUrl('origin')",
      "FugitiveFind(':0:dir/f.txt')",
      "FugitiveFind('@:dir/f.txt')",
      "FugitiveReal()",
      "FugitiveExtractGitDir(expand('%:p'))",
      "fugitive#Head(7)",
    }
    local function script(file)
      local lines = { "edit " .. vim.fn.fnameescape(file), "let g:result = {}" }
      for _, e in ipairs(exprs) do
        table.insert(lines, "let g:result[" .. vim.fn.string(e) .. "] = " .. e)
      end
      return lines
    end
    for _, file in ipairs({ "dir/f.txt", blob }) do
      local upstream = P.run_upstream(repo.root, script(file))
      H.reset_ui()
      vim.cmd("cd " .. repo.root)
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      for _, e in ipairs(exprs) do
        assert.equals(upstream[e], vim.fn.eval(e), file .. ": " .. e)
      end
    end
  end)

  it(":Git blame window text", function()
    if skip() then
      return
    end
    local repo = P.repo({ ["f.txt"] = "one\ntwo\nthree\n" })
    P.commit(repo, "second", { ["f.txt"] = "one\nTWO\nthree\n" })
    local upstream = P.run_upstream(repo.root, {
      "edit f.txt",
      "Git blame",
      "let g:result = getline(1, '$')",
    })
    H.reset_ui()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    vim.cmd("Git blame")
    assert.equals("fugitiveblame", vim.bo.filetype)
    assert.same(upstream, H.lines(0))
  end)

  it(":GBrowse handler dicts are identical (and refresh the fixture)", function()
    if skip() then
      return
    end
    local repo = B.setup()
    local upstream = B.normalize(P.run_upstream(repo.root, B.upstream_script(repo.root)), repo.root)
    local ours = B.normalize(B.ours(repo.root), repo.root)
    if vim.env.UPDATE_FIXTURES then
      local f = assert(io.open(vim.env.FIXTURES .. "/browse_upstream.json", "w"))
      f:write(vim.json.encode(upstream))
      f:close()
    end
    for _, c in ipairs(B.cases) do
      assert.same(upstream[c[1]], ours[c[1]], c[1])
    end
  end)
end)
