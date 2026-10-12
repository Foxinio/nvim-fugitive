local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")
local output = require("nvim-fugitive.ui.output")

local function open(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0
  end)
  return buf
end

local function goto_line(pattern)
  local l = assert(H.find_line(pattern), "no line " .. pattern)
  vim.api.nvim_win_set_cursor(0, { l, 0 })
end

local function run_and_wait(keys)
  local before = output.get(1)
  H.feed(keys)
  H.wait(function()
    local e = output.get(1)
    return e and e ~= before and not e.running
  end, "command for " .. keys, 10000)
  return output.get(1)
end

local function wait_editor(pattern)
  local found
  H.wait(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_loaded(b)
        and vim.api.nvim_buf_get_name(b):match(pattern)
        and vim.b[b].fugitive_editor
      then
        found = b
        return true
      end
    end
  end, "editor " .. pattern, 10000)
  vim.api.nvim_set_current_win(vim.fn.win_findbuf(found)[1])
  return found
end

describe("summary maps (M2 and extras)", function()
  local log, restore
  before_each(function()
    H.reset_ui()
    log, restore = H.capture_notify()
  end)
  after_each(function()
    restore()
  end)

  it("czz stashes, cza applies with --index, czp pops", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    repo:git("add", "a")
    open(repo)
    run_and_wait("czz")
    assert.equals("", repo:status())
    assert.equals(1, #vim.split(vim.trim(repo:git("stash", "list")), "\n"))
    run_and_wait("cza")
    assert.equals("M  a\n", repo:status())
    repo:git("reset", "-q", "--hard")
    run_and_wait("czp")
    assert.equals("M  a\n", repo:status())
    assert.equals("", vim.trim(repo:git("stash", "list")))
  end)

  it("shows a Stashes section", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    repo:git("stash", "-q")
    open(repo)
    assert.truthy(H.find_line("^Stashes %(1%)$"))
    assert.truthy(H.find_line("^stash@{0} "))
  end)

  it("= expands a stash inline; <CR> opens the stashed file; s is inert", function()
    local repo = H.repo({ files = { ["a"] = "a\n", ["b"] = "b\n" } })
    repo:write("a", "A\n")
    repo:write("b", "B\n")
    repo:git("stash", "-q")
    local buf = open(repo)
    local st = summary.state(buf)
    goto_line("^stash@{0} ")
    local tick = st.tick
    H.feed("=")
    H.wait(function()
      return st.tick > tick
    end)
    assert.truthy(H.find_line("^diff %-%-git a/a b/a$"))
    assert.truthy(H.find_line("^diff %-%-git a/b b/b$"))
    local plus = assert(H.find_line("^%+A$"))
    -- folds like a file's inline diff (headless: recompute without a redraw)
    vim.cmd("normal! zx")
    assert.equals(2, vim.fn.foldlevel(plus))
    -- staging keys do nothing on stash lines
    vim.api.nvim_win_set_cursor(0, { plus, 0 })
    H.feed("s")
    vim.wait(100)
    assert.equals("", repo:status())
    H.feed("<CR>")
    assert.truthy(vim.api.nvim_buf_get_name(0):match("^fugitive://.*//%x+/a$"))
    assert.same({ "A" }, H.lines(0))
    -- = on a diff line collapses back to the stash line
    vim.cmd("buffer " .. buf)
    vim.api.nvim_win_set_cursor(0, { assert(H.find_line("^%+B$")), 0 })
    tick = st.tick
    H.feed("=")
    H.wait(function()
      return st.tick > tick
    end)
    assert.is_nil(H.find_line("^diff "))
    assert.truthy(vim.api.nvim_get_current_line():match("^stash@{0} "))
  end)

  it("coo checks out the commit under the cursor", function()
    local origin = H.repo({ files = { ["f"] = "1\n" } })
    local clone = H.clone(origin)
    local sha = clone:commit("local", { ["g"] = "g\n" })
    open(clone)
    goto_line(" local$")
    run_and_wait("coo")
    assert.equals(sha, clone:rev("HEAD"))
    assert.equals("HEAD", vim.trim(clone:git("rev-parse", "--abbrev-ref", "HEAD")))
  end)

  it("rw rewords the commit under the cursor via the rebase todo", function()
    local origin = H.repo({ files = { ["f"] = "1\n" } })
    local clone = H.clone(origin)
    clone:commit("first local", { ["g"] = "g\n" })
    clone:commit("second local", { ["h"] = "h\n" })
    open(clone)
    goto_line(" first local$")
    H.feed("rw")
    local todo = wait_editor("git%-rebase%-todo$")
    assert.truthy(
      vim.api.nvim_buf_get_lines(todo, 0, 1, false)[1]:match("^reword %x+ #? ?first local")
    )
    vim.cmd("wq")
    local msg = wait_editor("COMMIT_EDITMSG$")
    vim.api.nvim_buf_set_lines(msg, 0, 1, false, { "reworded" })
    vim.cmd("wq")
    H.wait(function()
      return clone:git("log", "--format=%s", "-2") == "second local\nreworded\n"
    end, "reworded history", 10000)
  end)

  it("ri on a commit starts an interactive rebase from its parent; ra aborts", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local origin = H.repo({ files = { ["f"] = "1\n" } })
    local clone = H.clone(origin)
    clone:commit("one", { ["g"] = "g\n" })
    clone:commit("two", { ["h"] = "h\n" })
    local head = clone:rev("HEAD")
    open(clone)
    goto_line(" one$")
    H.feed("ri")
    local todo = wait_editor("git%-rebase%-todo$")
    local first = vim.api.nvim_buf_get_lines(todo, 0, 1, false)[1]
    assert.truthy(first:match("^pick %x+ #? ?one"))
    vim.api.nvim_buf_set_lines(todo, 0, 1, false, { (first:gsub("^pick", "edit")) })
    vim.cmd("wq")
    H.wait(function()
      return vim.uv.fs_stat(clone.root .. "/.git/rebase-merge") ~= nil
        and H.find_line("^Rebasing main", vim.fn.bufnr("fugitive://" .. clone.root .. "/.git//"))
          ~= nil
    end, "rebase stopped", 10000)
    vim.cmd("buffer fugitive://" .. clone.root .. "/.git//")
    run_and_wait("ra")
    assert.equals(head, clone:rev("HEAD"))
    local _ = repo
  end)

  it("cf puts a fixup commit on the command line", function()
    local origin = H.repo({ files = { ["f"] = "1\n" } })
    local clone = H.clone(origin)
    clone:commit("target", { ["g"] = "g\n" })
    open(clone)
    goto_line(" target$")
    local commit = vim.api.nvim_get_current_line():match("^(%x+)")
    local orig = vim.api.nvim_feedkeys
    local typed
    vim.api.nvim_feedkeys = function(keys)
      typed = keys
    end
    local ok, err = pcall(vim.fn.maparg("cf", "n", false, true).callback)
    vim.api.nvim_feedkeys = orig
    assert(ok, err)
    assert.equals(":Git commit --fixup=" .. commit, typed)
  end)

  it("gI appends the file under the cursor to .git/info/exclude", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("junk.log", "x\n")
    local buf = open(repo)
    goto_line("^%? junk.log")
    H.feed("gI")
    assert.equals(repo.root .. "/.git/info/exclude", vim.api.nvim_buf_get_name(0))
    assert.truthy(repo:read(".git/info/exclude"):match("/junk%.log\n"))
    H.wait(function()
      return H.find_line("^%? junk.log", buf) == nil
    end, "ignored file disappears")
  end)

  it("u on the Discarded line restores", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    local buf = open(repo)
    goto_line("^M a")
    local st = summary.state(buf)
    local tick = st.tick
    H.feed("X")
    H.wait(function()
      return st.tick > tick and H.find_line("^Discarded: a", buf) ~= nil
    end)
    goto_line("^Discarded: a")
    H.feed("u")
    H.wait(function()
      return repo:read("a") == "A\n"
    end, "restored")
  end)

  it("g? shows the map help in a float", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    open(repo)
    H.feed("g?")
    assert.equals("fugitivehelp", vim.bo.filetype)
    assert.truthy(H.find_line("^  s +stage$"))
    assert.truthy(H.find_line("discard"))
  end)

  it("dd on an unmerged file opens the 3-way diff", function()
    local repo = H.repo({ files = { ["c"] = "base\n" } })
    repo:git("checkout", "-q", "-b", "topic")
    repo:commit("topic", { ["c"] = "topic\n" })
    repo:git("checkout", "-q", "main")
    repo:commit("main", { ["c"] = "main\n" })
    repo:git("merge", "topic", { allow_fail = true })
    open(repo)
    goto_line("^U c")
    H.feed("dd")
    assert.equals(3, #vim.tbl_filter(function(w)
      return vim.wo[w].diff
    end, vim.api.nvim_tabpage_list_wins(0)))
  end)

  it("dv on an unstaged file diffs it against the index", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    open(repo)
    goto_line("^M a")
    H.feed("dv")
    local names = vim.tbl_map(
      function(w)
        return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      end,
      vim.tbl_filter(function(w)
        return vim.wo[w].diff
      end, vim.api.nvim_tabpage_list_wins(0))
    )
    table.sort(names)
    assert.same({ repo:path("a"), "fugitive://" .. repo.root .. "/.git//0/a" }, names)
  end)
end)
