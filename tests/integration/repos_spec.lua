local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")
local repo_mod = require("nvim-fugitive.git.repo")

local function open(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0
  end)
  return buf
end

local function notes(buf)
  local ns = vim.api.nvim_get_namespaces().fugitive_summary
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text then
      out[m[2] + 1] = m[4].virt_text[1][1]
    end
  end
  return out
end

describe("submodule maintenance", function()
  before_each(function()
    H.reset_ui()
    repo_mod._cache = {}
  end)

  local function parent_with_sub()
    local sub = H.repo({ files = { ["s.txt"] = "s\n" } })
    local parent = H.repo({ files = { ["p.txt"] = "p\n" } })
    parent:git("-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.root, "sm")
    parent:commit("add submodule")
    return parent, sub
  end

  it("notes dirty content and lists the submodule's own status under =", function()
    local parent = parent_with_sub()
    local f = io.open(parent:path("sm/s.txt"), "w")
    f:write("changed\n")
    f:close()
    local buf = open(parent.root)
    local l = assert(H.find_line("^%? sm$"))
    assert.equals("(modified content)", notes(buf)[l])
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    local st = summary.state(buf)
    local tick = st.tick
    H.feed("=")
    H.wait(function()
      return st.tick > tick
    end)
    assert.truthy(H.find_line("^   M s%.txt$"))
  end)

  it("lists uninitialized submodules and cu initializes them", function()
    local parent = parent_with_sub()
    local clone = H.clone(parent)
    local buf = open(clone.root)
    local l = assert(H.find_line("^%- sm$"))
    assert.truthy(H.find_line("^Uninitialized submodules %(1%)$"))
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    package.preload.overseer = function()
      error("absent")
    end
    local log, restore = H.capture_notify()
    vim.env.GIT_ALLOW_PROTOCOL = "file"
    H.feed("cu")
    H.wait(function()
      return vim.uv.fs_stat(clone:path("sm/s.txt")) ~= nil
    end, "submodule checked out", 10000)
    restore()
    vim.env.GIT_ALLOW_PROTOCOL = nil
    package.preload.overseer = nil
    H.wait(function()
      return H.find_line("^Uninitialized", buf) == nil
    end, "section gone")
    local _ = log
  end)
end)

describe("bare and external git dirs", function()
  before_each(function()
    H.reset_ui()
    repo_mod._cache = {}
  end)

  it("shows a bare repository like upstream", function()
    local src = H.repo({ files = { ["f"] = "1\n" } })
    local bare = H.tmpdir() .. "/bare.git"
    H.git(src.root, { "clone", "-q", "--bare", src.root, bare })
    local buf = open(bare)
    assert.same({ "Head: main", "Bare: yes", "Help: g?" }, H.lines(buf))
    vim.cmd("Gedit HEAD:f")
    assert.same({ "1" }, H.lines(0))
  end)

  it("supports $GIT_DIR / $GIT_WORK_TREE (dotfiles)", function()
    local home = H.tmpdir()
    local gd = home .. "/.dotfiles"
    H.git(home, { "init", "-q", "--bare", gd })
    H.git(home, { "--git-dir=" .. gd, "--work-tree=" .. home, "config", "user.name", "T" })
    H.git(home, { "--git-dir=" .. gd, "--work-tree=" .. home, "config", "user.email", "t@e" })
    local f = io.open(home .. "/.vimrc", "w")
    f:write("set nocp\n")
    f:close()
    H.git(home, { "--git-dir=" .. gd, "--work-tree=" .. home, "add", ".vimrc" })
    H.git(home, { "--git-dir=" .. gd, "--work-tree=" .. home, "commit", "-q", "-m", "dot" })
    f = io.open(home .. "/.vimrc", "w")
    f:write("set nocp\nset nu\n")
    f:close()
    vim.env.GIT_DIR = gd
    vim.env.GIT_WORK_TREE = home
    local ok, err = pcall(function()
      local repo = assert(repo_mod.find(home .. "/.vimrc"))
      assert.equals(vim.uv.fs_realpath(gd), repo.git_dir)
      assert.equals(vim.uv.fs_realpath(home), repo.worktree)
      assert.is_true(repo.explicit)
      local buf = open(home)
      assert.truthy(H.find_line("^M %.vimrc$", buf))
      -- staging goes to the external git dir
      vim.api.nvim_win_set_cursor(0, { H.find_line("^M %.vimrc$", buf), 0 })
      local st = summary.state(buf)
      local tick = st.tick
      H.feed("s")
      H.wait(function()
        return st.tick > tick and H.find_line("^Staged", buf) ~= nil
      end)
    end)
    vim.env.GIT_DIR = nil
    vim.env.GIT_WORK_TREE = nil
    assert(ok, err)
    local staged =
      H.git(home, { "--git-dir=" .. gd, "--work-tree=" .. home, "diff", "--cached", "--name-only" })
    assert.equals(".vimrc\n", staged)
  end)

  it("uses core.worktree of an external git dir", function()
    local wt = H.tmpdir()
    local gd = H.tmpdir() .. "/ext.git"
    H.git(wt, { "--git-dir=" .. gd, "--work-tree=" .. wt, "init", "-q" })
    H.git(wt, { "--git-dir=" .. gd, "config", "core.worktree", wt })
    local repo = repo_mod.new(vim.uv.fs_realpath(gd))
    assert.equals(vim.uv.fs_realpath(wt), repo.worktree)
    assert.is_true(repo.explicit)
  end)
end)
