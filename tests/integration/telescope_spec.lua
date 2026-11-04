local H = require("helpers")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local deps = vim.env.FUGITIVE_TEST_DEPS or (root .. "/.deps")
local has_telescope = vim.uv.fs_stat(deps .. "/telescope.nvim") ~= nil
if has_telescope then
  vim.opt.runtimepath:append(deps .. "/telescope.nvim")
  vim.cmd("runtime plugin/telescope.lua")
end

local function picker()
  local bufnr
  H.wait(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "TelescopePrompt" then
        bufnr = b
        return true
      end
    end
  end, "telescope prompt")
  local p = require("telescope.actions.state").get_current_picker(bufnr)
  H.wait(function()
    return p.manager and p.manager:num_results() > 0
  end, "telescope results")
  vim.wait(100)
  return p, bufnr
end

---Select the entry for which `pred(value)` is true and run `action`.
local function select(p, bufnr, pred, action)
  local idx
  for i, e in ipairs(p.finder.results) do
    if pred(e.value or e) then
      idx = i
      break
    end
  end
  assert(idx, "entry not found")
  local entry = p.finder.results[idx]
  p:set_selection(p:get_row(p.manager:find_entry(entry) or idx))
  H.wait(function()
    local sel = require("telescope.actions.state").get_selected_entry()
    return sel and pred(sel.value or sel)
  end, "selection")
  action(bufnr)
end

describe("telescope integration", function()
  before_each(function()
    H.reset_ui()
    if not has_telescope then
      pending("telescope.nvim not in " .. deps)
    end
  end)

  it("refs picker: sorted by recency, <CR> checks out", function()
    if not has_telescope then
      return
    end
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:git("branch", "older")
    repo:git("checkout", "-q", "-b", "newer")
    repo:write("b", "b\n")
    repo:git("add", "b")
    repo:git(
      "commit",
      "-q",
      "-m",
      "newer commit",
      { env = { GIT_COMMITTER_DATE = "2030-01-01T00:00:00Z" } }
    )
    repo:git("checkout", "-q", "main")
    vim.cmd("cd " .. repo.root)
    require("nvim-fugitive.integrations.telescope.pickers").refs()
    local p, bufnr = picker()
    assert.equals("newer", p.finder.results[1].value.name)
    select(p, bufnr, function(v)
      return v.name == "older"
    end, require("telescope.actions").select_default)
    H.wait(function()
      return vim.trim(repo:git("rev-parse", "--abbrev-ref", "HEAD")) == "older"
    end, "checkout")
  end)

  it("log picker: <CR> opens the commit as a fugitive:// buffer", function()
    if not has_telescope then
      return
    end
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local sha = repo:commit("second", { ["b"] = "b\n" })
    vim.cmd("cd " .. repo.root)
    vim.cmd("Telescope fugitive log")
    local p, bufnr = picker()
    assert.equals(2, #p.finder.results)
    select(p, bufnr, function(v)
      return v.sha == sha
    end, require("telescope.actions").select_default)
    H.wait(function()
      return vim.api.nvim_buf_get_name(0):match(sha .. "$") ~= nil
    end, "commit buffer")
    assert.equals("commit", vim.b.fugitive_type)
  end)

  it("stash picker: <CR> applies", function()
    if not has_telescope then
      return
    end
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "stashed\n")
    repo:git("stash", "-q")
    vim.cmd("cd " .. repo.root)
    vim.cmd("Telescope fugitive stash")
    local p, bufnr = picker()
    select(p, bufnr, function(v)
      return v.ref == "stash@{0}"
    end, require("telescope.actions").select_default)
    H.wait(function()
      return repo:read("a") == "stashed\n"
    end, "stash applied")
  end)

  it(":Git checkout with no ref asks the refs picker", function()
    if not has_telescope then
      return
    end
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:git("branch", "topic")
    vim.cmd("cd " .. repo.root)
    vim.cmd("Git checkout")
    local p, bufnr = picker()
    select(p, bufnr, function(v)
      return v.name == "topic"
    end, require("telescope.actions").select_default)
    H.wait(function()
      return vim.trim(repo:git("rev-parse", "--abbrev-ref", "HEAD")) == "topic"
    end, "checkout topic")
  end)

  it(":Git push picks the remote, then the branch (the current one first)", function()
    if not has_telescope then
      return
    end
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local origin = H.repo({ bare = true })
    local fork = H.repo({ bare = true })
    repo:git("remote", "add", "fork", fork.root)
    repo:git("remote", "add", "origin", origin.root)
    repo:git("push", "-q", "origin", "main")
    repo:git("push", "-q", "origin", "main:release")
    repo:git("fetch", "-q", "origin")
    repo:git("checkout", "-q", "-b", "topic")
    repo:commit("topic", { ["b"] = "b\n" })
    vim.cmd("cd " .. repo.root)
    local actions = require("telescope.actions")
    local state = require("telescope.actions.state")
    local function selected_after(p)
      H.wait(function()
        return state.get_selected_entry() ~= nil
      end, "a selection")
      return p, state.get_selected_entry().value
    end

    vim.cmd("Git push")
    -- remotes: origin (the default) is selected at the start
    local p, value = selected_after(picker())
    assert.equals("origin", value)
    assert.same(
      { "fork", "origin" },
      vim.tbl_map(function(e)
        return e.value
      end, p.finder.results)
    )
    actions.select_default(p.prompt_bufnr)
    -- branches of origin: topic is not there yet, offered (new) and selected
    p, value = selected_after(picker())
    assert.equals("topic", value)
    local names = vim.tbl_map(function(e)
      return e.value
    end, p.finder.results)
    table.sort(names)
    assert.same({ "main", "release", "topic" }, names)
    actions.select_default(p.prompt_bufnr)
    H.wait(function()
      return vim.trim(origin:git("rev-parse", "--verify", "-q", "topic", { allow_fail = true }))
        == repo:rev("HEAD")
    end, "pushed topic", 10000)

    -- a name typed in the prompt that matches nothing is pushed to as is
    vim.cmd("Git push")
    p = picker()
    actions.select_default(p.prompt_bufnr)
    p = picker()
    p:set_prompt("brand-new")
    H.wait(function()
      return state.get_selected_entry() == nil
    end, "no match")
    actions.select_default(p.prompt_bufnr)
    H.wait(function()
      return vim.trim(origin:git("rev-parse", "--verify", "-q", "brand-new", { allow_fail = true }))
        == repo:rev("HEAD")
    end, "pushed HEAD:brand-new", 10000)
  end)

  it(":Ggrep opens a picker; <C-q> sends to quickfix", function()
    if not has_telescope then
      return
    end
    local repo = H.repo({ files = { ["a"] = "needle\n", ["b"] = "x needle\n" } })
    vim.cmd("cd " .. repo.root)
    vim.fn.setqflist({}, "r")
    vim.cmd("Ggrep needle")
    local p, bufnr = picker()
    assert.equals(2, #p.finder.results)
    require("telescope.actions").send_to_qflist(bufnr)
    assert.equals(2, #vim.fn.getqflist())
  end)
end)

describe("picker fallbacks without telescope", function()
  before_each(function()
    H.reset_ui()
    require("nvim-fugitive").setup({ integrations = { telescope = false } })
  end)
  after_each(function()
    require("nvim-fugitive").setup({})
  end)

  it(":Git switch uses vim.ui.select and appends the choice", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:git("branch", "topic")
    vim.cmd("cd " .. repo.root)
    local orig = vim.ui.select
    local offered
    vim.ui.select = function(items, opts, cb)
      offered = vim.tbl_map(opts.format_item, items)
      for _, i in ipairs(items) do
        if i.name == "topic" then
          return cb(i)
        end
      end
    end
    local log, restore = H.capture_notify()
    vim.cmd("Git switch")
    vim.ui.select = orig
    H.wait(function()
      return vim.trim(repo:git("rev-parse", "--abbrev-ref", "HEAD")) == "topic"
    end)
    restore()
    assert.truthy(offered[1]:match("topic") or offered[2]:match("topic"))
    local _ = log
  end)

  it(":Git push offers the current branch first; one remote needs no pick", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local origin = H.repo({ bare = true })
    repo:git("remote", "add", "origin", origin.root)
    repo:git("push", "-q", "origin", "main", "main:aaa")
    repo:git("fetch", "-q", "origin")
    vim.cmd("cd " .. repo.root)
    local orig = vim.ui.select
    local prompts, offered = {}, nil
    vim.ui.select = function(items, opts, cb)
      table.insert(prompts, opts.prompt)
      offered = vim.tbl_map(opts.format_item, items)
      cb(items[1])
    end
    local log, restore = H.capture_notify()
    repo:commit("more", { ["b"] = "b\n" })
    vim.cmd("Git push")
    vim.ui.select = orig
    H.wait(function()
      return vim.trim(origin:git("rev-parse", "main")) == repo:rev("HEAD")
    end, "pushed main", 10000)
    restore()
    local _ = log
    assert.same({ "git push origin" }, prompts)
    assert.same({ "main", "aaa", "other…" }, offered)
  end)

  it(":Git push asks only without an upstream; -u chooses it for good", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local origin = H.repo({ bare = true })
    repo:git("remote", "add", "origin", origin.root)
    repo:git("push", "-q", "origin", "main", "main:aaa")
    repo:git("fetch", "-q", "origin")
    vim.cmd("cd " .. repo.root)
    local orig = vim.ui.select
    local asked, pick = 0, nil
    vim.ui.select = function(items, opts, cb)
      asked = asked + 1
      local labels = vim.tbl_map(opts.format_item, items)
      for i, label in ipairs(labels) do
        if label == pick then
          return cb(items[i])
        end
      end
      cb(items[1])
    end
    local log, restore = H.capture_notify()
    local function push(cmd, ref)
      repo:commit("c" .. vim.uv.hrtime(), { ["b"] = tostring(vim.uv.hrtime()) })
      vim.cmd(cmd)
      H.wait(function()
        return vim.trim(origin:git("rev-parse", "--verify", "-q", ref, { allow_fail = true }))
          == repo:rev("HEAD")
      end, cmd .. " -> " .. ref, 10000)
    end
    local function upstream()
      return vim.trim(
        repo:git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}", { allow_fail = true })
      )
    end

    -- -u: the picker, then the choice is the upstream from now on
    pick = "aaa"
    push("Git push -u", "aaa")
    assert.equals(1, asked)
    assert.equals("origin/aaa", upstream())
    -- a bare push now goes there without asking, though the name differs
    push("Git push", "aaa")
    assert.equals(1, asked)
    -- -u asks again, starting at the upstream
    pick = "main"
    push("Git push --set-upstream", "main")
    assert.equals(2, asked)
    assert.equals("origin/main", upstream())
    push("Git push", "main")
    assert.equals(2, asked)
    -- other flags keep the picker: -f -u asks, -f alone uses the upstream
    pick = "aaa"
    push("Git push -f -u", "aaa")
    assert.equals(3, asked)
    assert.equals("origin/aaa", upstream())
    push("Git push -f", "aaa")
    assert.equals(3, asked)
    vim.ui.select = orig
    restore()
    local _ = log
  end)

  it("other invocations pass through without a picker", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:git("branch", "topic")
    vim.cmd("cd " .. repo.root)
    local orig = vim.ui.select
    local called = false
    vim.ui.select = function()
      called = true
    end
    local log, restore = H.capture_notify()
    vim.cmd("Git switch topic")
    H.wait(function()
      return vim.trim(repo:git("rev-parse", "--abbrev-ref", "HEAD")) == "topic"
    end)
    vim.cmd("Git rebase --abort")
    vim.wait(200)
    restore()
    vim.ui.select = orig
    assert.is_false(called)
    local _ = log
  end)
end)

describe("history pickers", function()
  before_each(function()
    H.reset_ui()
  end)

  local function history_repo()
    local repo = H.repo({ files = { ["f"] = "1\n2\n3\n" } })
    repo:commit("change line 2", { ["f"] = "1\nTWO\n3\n" })
    repo:commit("other file", { ["g"] = "g\n" })
    vim.cmd("cd " .. repo.root)
    return repo
  end

  it("file_history and line_history list the right commits", function()
    if not has_telescope then
      return
    end
    local repo = history_repo()
    vim.cmd("edit f")
    vim.cmd("Telescope fugitive file_history")
    local p, bufnr = picker()
    assert.equals(2, #p.finder.results)
    require("telescope.actions").close(bufnr)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("Telescope fugitive blame_line")
    p, bufnr = picker()
    assert.equals("change line 2", p.finder.results[1].value.subject)
    select(p, bufnr, function(v)
      return v.subject == "change line 2"
    end, require("telescope.actions").select_default)
    H.wait(function()
      return vim.api.nvim_buf_get_name(0):match("//%x+/f$") ~= nil
    end, "blob at commit")
    assert.equals(2, vim.fn.line("."))
    local _ = repo
  end)

  it(":FugitivePick falls back to vim.ui.select", function()
    require("nvim-fugitive").setup({ integrations = { telescope = false } })
    local repo = history_repo()
    vim.cmd("edit f")
    local orig = vim.ui.select
    local offered
    vim.ui.select = function(items, opts, cb)
      offered = vim.tbl_map(opts.format_item, items)
      cb(items[#items])
    end
    vim.cmd("FugitivePick file_history")
    vim.ui.select = orig
    require("nvim-fugitive").setup({})
    assert.equals(2, #offered)
    assert.truthy(vim.api.nvim_buf_get_name(0):match("//" .. repo:rev("HEAD~2") .. "/f$"))
  end)
end)

describe("work-tree hunks without gitsigns", function()
  before_each(function()
    H.reset_ui()
    package.preload.gitsigns = function()
      error("not installed")
    end
  end)
  after_each(function()
    package.preload.gitsigns = nil
  end)

  it("jumps, stages and resets hunks of the buffer against the index", function()
    local lines = {}
    for i = 1, 20 do
      lines[i] = "l" .. i
    end
    local repo = H.repo({ files = { ["f"] = table.concat(lines, "\n") .. "\n" } })
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit f")
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { "THREE" })
    vim.api.nvim_buf_set_lines(0, 15, 16, false, { "SIXTEEN", "extra" })
    local actions = require("nvim-fugitive.integrations.gitsigns").actions
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    actions.next_hunk()
    assert.equals(3, vim.fn.line("."))
    actions.next_hunk()
    assert.equals(16, vim.fn.line("."))
    actions.prev_hunk()
    assert.equals(3, vim.fn.line("."))
    -- stage the first hunk: the unsaved buffer's version goes to the index
    actions.stage_hunk()
    local staged = repo:git("diff", "--cached")
    assert.truthy(staged:match("%+THREE"))
    assert.falsy(staged:match("SIXTEEN"))
    -- reset the second hunk in the buffer
    vim.api.nvim_win_set_cursor(0, { 16, 0 })
    actions.reset_hunk()
    assert.equals("l16", vim.api.nvim_buf_get_lines(0, 15, 16, false)[1])
    assert.equals(20, vim.api.nvim_buf_line_count(0))
  end)
end)

describe("gitsigns integration", function()
  before_each(function()
    H.reset_ui()
  end)
  after_each(function()
    package.loaded.gitsigns = nil
    package.preload.gitsigns = nil
  end)

  it("refreshes gitsigns after mutating operations", function()
    local refreshed = 0
    package.loaded.gitsigns = {
      refresh = function()
        refreshed = refreshed + 1
      end,
    }
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    vim.cmd("cd " .. repo.root)
    local log, restore = H.capture_notify()
    vim.cmd("Git add a")
    H.wait(function()
      return refreshed > 0
    end, "gitsigns refresh")
    restore()
    local _ = log
  end)

  it("delegates work-tree hunk actions to gitsigns when present", function()
    local staged = false
    package.loaded.gitsigns = {
      stage_hunk = function()
        staged = true
      end,
    }
    local gs = require("nvim-fugitive.integrations.gitsigns")
    gs.actions.stage_hunk()
    assert.is_true(staged)
  end)

  it("work-tree maps are opt-in and honour g:fugitive_no_maps", function()
    package.loaded.gitsigns = { nav_hunk = function() end }
    require("nvim-fugitive").setup({ maps = { worktree = { ["]h"] = "next_hunk" } } })
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("edit " .. repo:path("a"))
    assert.truthy(vim.fn.maparg("]h", "n") ~= "")
    vim.g.fugitive_no_maps = 1
    vim.cmd("edit " .. repo:path("b"))
    vim.g.fugitive_no_maps = nil
    assert.equals("", vim.fn.maparg("]h", "n"))
    require("nvim-fugitive").setup({})
  end)
end)
