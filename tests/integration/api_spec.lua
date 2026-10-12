local H = require("helpers")
local object = require("nvim-fugitive.object")

describe("Vimscript API", function()
  local repo
  before_each(function()
    H.reset_ui()
    repo = H.repo({ files = { ["dir/f"] = "x\n" } })
    repo:git("remote", "add", "origin", "https://example.com/r.git")
    vim.cmd("cd " .. repo.root)
  end)

  it("answers the common questions", function()
    vim.cmd("edit dir/f")
    assert.equals(repo.root .. "/.git", vim.fn.FugitiveGitDir())
    assert.equals(repo.root, vim.fn.FugitiveWorkTree())
    assert.equals("main", vim.fn.FugitiveHead())
    assert.equals("refs/heads/main", vim.fn.FugitiveHead(-1))
    assert.equals("[Git(main)]", vim.fn.FugitiveStatusline())
    assert.equals("main", vim.fn["fugitive#Head"]())
    assert.equals("Test", vim.fn.FugitiveConfigGet("user.name"))
    assert.equals("https://example.com/r.git", vim.fn.FugitiveRemoteUrl("origin"))
    assert.equals(
      object.format(repo.root .. "/.git", "0", "dir/f"),
      vim.fn.FugitiveFind(":0:dir/f")
    )
    assert.equals(repo.root .. "/.git", vim.fn.FugitiveExtractGitDir(repo:path("dir/f")))
    assert.equals(1, vim.fn.FugitiveGitVersion(2, 30))
    local r = vim.fn.FugitiveExecute({ "rev-parse", "HEAD" })
    assert.equals(0, r.exit_status)
    assert.equals(repo:rev("HEAD"), r.stdout[1])
  end)

  it("knows fugitive:// buffers", function()
    local sha = repo:rev("HEAD")
    vim.cmd("edit " .. vim.fn.fnameescape(object.format(repo.root .. "/.git", sha, "dir/f")))
    assert.same({ sha .. ":dir/f", repo.root .. "/.git" }, vim.fn.FugitiveParse())
    assert.equals(repo:path("dir/f"), vim.fn.FugitiveReal())
    assert.equals("[Git:" .. sha:sub(1, 7) .. "(main)]", vim.fn.FugitiveStatusline())
    repo:git("checkout", "-q", "--detach")
    assert.equals("", vim.fn.FugitiveHead())
    assert.equals(sha:sub(1, 7), vim.fn.FugitiveHead(7))
  end)

  it("runs FugitiveExecute callbacks asynchronously", function()
    vim.cmd(
      [[call FugitiveExecute(['rev-parse', 'HEAD'], {r -> execute('let g:fugitive_test_rev = r.stdout[0]')})]]
    )
    H.wait(function()
      return vim.g.fugitive_test_rev ~= nil
    end)
    assert.equals(repo:rev("HEAD"), vim.g.fugitive_test_rev)
  end)

  it("fires upstream's User events", function()
    local seen = {}
    for _, ev in ipairs({
      "FugitiveIndex",
      "FugitiveObject",
      "FugitiveCommit",
      "FugitiveBlob",
      "FugitivePager",
    }) do
      vim.api.nvim_create_autocmd("User", {
        pattern = ev,
        callback = function()
          seen[ev] = true
        end,
      })
    end
    vim.cmd("Git")
    vim.cmd("Gedit @")
    vim.cmd("Gedit @:dir/f")
    local before = require("nvim-fugitive.ui.output").get(1)
    vim.cmd("Git log")
    H.wait(function()
      local e = require("nvim-fugitive.ui.output").get(1)
      return e ~= before and not e.running
    end)
    assert.same({
      FugitiveIndex = true,
      FugitiveObject = true,
      FugitiveCommit = true,
      FugitiveBlob = true,
      FugitivePager = true,
    }, seen)
  end)

  it("gf opens the object under the cursor; <C-W>gf in a tab", function()
    repo:commit("second", { ["dir/f"] = "y\n" })
    vim.cmd("Gedit @")
    local plus = assert(H.find_line("^%+y"))
    vim.api.nvim_win_set_cursor(0, { plus, 0 })
    H.feed("gf")
    assert.equals(
      object.format(repo.root .. "/.git", repo:rev("HEAD"), "dir/f"),
      vim.api.nvim_buf_get_name(0)
    )
    vim.cmd("Gedit @")
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- parent line
    H.feed("<C-W>gf")
    assert.equals(2, #vim.api.nvim_list_tabpages())
  end)
end)
