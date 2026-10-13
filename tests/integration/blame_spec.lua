local H = require("helpers")
local object = require("nvim-fugitive.object")
local blame = require("nvim-fugitive.buffers.blame")

local function url(repo, commit, path)
  return object.format(repo.root .. "/.git", commit, path)
end

local function history()
  local lines = {}
  for i = 1, 40 do
    lines[i] = "line " .. i
  end
  local repo = H.repo({ files = { ["f.txt"] = table.concat(lines, "\n") .. "\n" } })
  local first = repo:rev("HEAD")
  lines[30] = "changed 30"
  local second = repo:commit("change 30", { ["f.txt"] = table.concat(lines, "\n") .. "\n" })
  lines[30] = "changed again 30"
  local third = repo:commit("change 30 again", { ["f.txt"] = table.concat(lines, "\n") .. "\n" })
  return repo, first, second, third
end

local function blame_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "fugitiveblame" then
      return w
    end
  end
end

describe(":Git blame", function()
  before_each(function()
    H.reset_ui()
  end)

  it("parses git's blame lines", function()
    local info = blame.parse_line("^1a2b3c4 12 (Jane Doe 2024-01-01 10:00:00 +0000 14) code (here)")
    assert.same({ commit = "1a2b3c4", boundary = true, orig = 12, final = 14 }, info)
    info = blame.parse_line("abcdef12 old/name.txt 3 (A 2024-01-01 10:00:00 +0000  5) x")
    assert.equals("old/name.txt", info.path)
    assert.equals(3, info.orig)
  end)

  it("opens a scroll-bound window left of the file, aligned with it", function()
    local repo, _, _, third = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    local file_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(file_win, { 30, 0 })
    vim.cmd("Git blame")
    local win = assert(blame_win())
    assert.equals(win, vim.api.nvim_get_current_win())
    local buf = vim.api.nvim_win_get_buf(win)
    assert.equals(40, vim.api.nvim_buf_line_count(buf))
    assert.is_true(vim.wo[win].scrollbind)
    assert.is_true(vim.wo[file_win].scrollbind)
    assert.is_true(
      vim.api.nvim_win_get_position(win)[2] < vim.api.nvim_win_get_position(file_win)[2]
    )
    assert.equals(30, vim.fn.line("."))
    assert.equals(third:sub(1, 7), vim.api.nvim_get_current_line():match("^(%x+)"):sub(1, 7))
    -- sized to the metadata column
    local line = vim.api.nvim_get_current_line()
    assert.equals(blame.meta_width(line) + 1, vim.api.nvim_win_get_width(win))
  end)

  it("blames the buffer contents when modified", function()
    local repo = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved" })
    vim.cmd("Git blame")
    assert.truthy(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^0+ "))
  end)

  it("from the blame window blames the file again", function()
    local repo = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    local file_win = vim.api.nvim_get_current_win()
    vim.cmd("Git blame")
    local first = vim.api.nvim_get_current_buf()
    vim.cmd("Git blame")
    local win = assert(blame_win())
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.are_not.equals(first, vim.api.nvim_get_current_buf())
    assert.is_false(vim.api.nvim_buf_is_valid(first))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals(repo:path("f.txt"), vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(file_win)))
    assert.equals(40, vim.api.nvim_buf_line_count(0))
  end)

  it("ignores a configured blame.ignoreRevsFile that does not exist", function()
    local repo, _, second, third = history()
    repo:git("config", "--add", "blame.ignoreRevsFile", ".git-blame-ignore-revs")
    repo:git("config", "--add", "blame.ignoreRevsFile", "revs-present")
    repo:write("revs-present", third .. "\n")
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    vim.cmd("Git blame")
    assert.truthy(blame_win())
    -- the existing file still applies: line 30 goes past the ignored commit
    local line = vim.api.nvim_buf_get_lines(0, 29, 30, false)[1]
    assert.equals(second:sub(1, 7), line:match("^%^?(%x+)"):sub(1, 7))
  end)

  it("<CR> opens the commit at the line's hunk; gq restores the window", function()
    local repo, _, _, third = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    local file_win = vim.api.nvim_get_current_win()
    vim.cmd("Git blame")
    vim.api.nvim_win_set_cursor(0, { 30, 0 })
    H.feed("<CR>")
    assert.is_nil(blame_win())
    assert.equals(url(repo, third), vim.api.nvim_buf_get_name(0))
    assert.equals("+changed again 30", vim.api.nvim_get_current_line())
    assert.is_false(vim.wo[file_win].scrollbind)
    -- gq closes and leaves the file window as it was
    vim.cmd("edit " .. repo:path("f.txt"))
    vim.cmd("Git blame")
    H.feed("gq")
    assert.is_nil(blame_win())
    assert.is_false(vim.wo[file_win].scrollbind)
    assert.equals(repo:path("f.txt"), vim.api.nvim_buf_get_name(0))
  end)

  it("~ reblames at the parent of the line's commit; - at the commit", function()
    local repo, _, second, third = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    vim.cmd("Git blame")
    vim.api.nvim_win_set_cursor(0, { 30, 0 })
    H.feed("~")
    local win = assert(blame_win())
    -- the file window now shows f.txt at third~1 (= second)
    local origin
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= win then
        origin = w
      end
    end
    assert.equals(
      url(repo, second, "f.txt"),
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin))
    )
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 30, 0 })
    assert.equals(second:sub(1, 7), vim.api.nvim_get_current_line():match("^%^?(%x+)"):sub(1, 7))
    local _ = third
  end)

  it("<CR> in a blob at a commit opens the commit of that line", function()
    local repo, first, _, third = history()
    vim.cmd("edit " .. vim.fn.fnameescape(url(repo, third, "f.txt")))
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    H.feed("<CR>")
    -- line 5 dates from the root commit: a boundary, so the blob opens
    assert.equals(url(repo, first, "f.txt"), vim.api.nvim_buf_get_name(0))
    assert.equals(5, vim.fn.line("."))
  end)

  it("with a path argument the output goes to the float", function()
    local repo = history()
    vim.cmd("cd " .. repo.root)
    local before = require("nvim-fugitive.ui.output").get(1)
    vim.cmd("Git blame f.txt")
    H.wait(function()
      local e = require("nvim-fugitive.ui.output").get(1)
      return e ~= before and not e.running
    end)
    assert.equals("fugitiveblame", vim.bo.filetype)
    assert.is_true(vim.api.nvim_win_get_config(0).relative ~= "")
  end)

  local function float_blame(cmd)
    local before = require("nvim-fugitive.ui.output").get(1)
    vim.cmd(cmd)
    H.wait(function()
      local e = require("nvim-fugitive.ui.output").get(1)
      return e ~= before and not e.running
    end)
    local e = require("nvim-fugitive.ui.output").get(1)
    assert.equals(0, e.code)
    return H.lines(0)
  end

  it("-L or a revision without a path blames the current file in the float", function()
    local repo, first = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    local lines = float_blame("Git blame -L 30,31")
    assert.equals(2, #lines)
    assert.truthy(lines[1]:match("changed again 30$"))
    H.reset_ui()
    vim.cmd("edit f.txt")
    lines = float_blame("Git blame -L 30,30 " .. first)
    assert.truthy(lines[1]:match("line 30$"))
  end)

  it("a routes override for blame still blames the current file", function()
    local repo = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    local config = require("nvim-fugitive.config")
    local saved = vim.deepcopy(config.get().routes)
    config.get().routes = { blame = "float" }
    local ok, lines = pcall(float_blame, "Git blame")
    config.get().routes = saved
    assert(ok, lines)
    assert.equals(40, #lines)
  end)
end)

describe(":Git blame window lifetime", function()
  it("closes together with the file window", function()
    H.reset_ui()
    local repo = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    vim.cmd("split")
    local file_win = vim.api.nvim_get_current_win()
    vim.cmd("Git blame")
    assert.truthy(blame_win())
    vim.api.nvim_win_close(file_win, true)
    H.wait(function()
      return blame_win() == nil
    end, "blame window closed")
  end)
end)

describe(":Git blame and :only", function()
  it("turns a lone blame window back into a normal window", function()
    H.reset_ui()
    local repo = history()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f.txt")
    vim.cmd("Git blame")
    local win = vim.api.nvim_get_current_win()
    vim.cmd("only")
    vim.wait(50)
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.is_false(vim.wo[win].winfixbuf)
    assert.is_false(vim.wo[win].scrollbind)
    vim.cmd("edit " .. repo:path("f.txt"))
    assert.equals(repo:path("f.txt"), vim.api.nvim_buf_get_name(0))
  end)
end)
