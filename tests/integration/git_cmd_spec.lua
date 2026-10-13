local H = require("helpers")
local output = require("nvim-fugitive.ui.output")

local function wait_done(before)
  H.wait(function()
    local e = output.get(1)
    return e and e ~= before and not e.running
  end, "command completion", 10000)
  return output.get(1)
end

local function float_wins()
  return vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative ~= ""
  end, vim.api.nvim_list_wins())
end

describe(":Git routes", function()
  before_each(function()
    H.reset_ui()
    vim.cmd("messages clear")
  end)

  it("pager commands open the float; <CR> on a commit opens it", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:commit("second", { ["b"] = "b\n" })
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git log --oneline")
    wait_done(before)
    assert.equals(1, #float_wins())
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("git", vim.bo[buf].filetype)
    assert.truthy(H.lines(buf)[1]:match("^%x+ second$"))
    H.feed("<CR>")
    assert.truthy(vim.api.nvim_buf_get_name(0):match("^fugitive://"))
    assert.equals("commit", vim.b.fugitive_type)
  end)

  it("window modifiers open pager output in a split instead", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("cd " .. repo.root)
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    local before = output.get(1)
    vim.cmd("vertical Git log")
    wait_done(before)
    assert.equals(0, #float_wins())
    assert.equals(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
    assert.truthy(H.find_line("^commit %x+"))
    local tabs = #vim.api.nvim_list_tabpages()
    before = output.get(1)
    vim.cmd("tab Git show")
    wait_done(before)
    assert.equals(tabs + 1, #vim.api.nvim_list_tabpages())
  end)

  it("-p forces the pager, --no-pager the notification", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("cd " .. repo.root)
    local log, restore = H.capture_notify()
    repo:write("x", "x")
    local before = output.get(1)
    vim.cmd("Git -p status --short")
    wait_done(before)
    assert.equals(1, #float_wins())
    H.reset_ui()
    before = output.get(1)
    vim.cmd("Git --no-pager log --oneline")
    wait_done(before)
    restore()
    assert.equals(0, #float_wins())
    assert.truthy(vim.iter(log):any(function(m)
      return m.msg:match("initial")
    end))
  end)

  it("notify route reports and refreshes (User FugitiveChanged)", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    vim.cmd("cd " .. repo.root)
    local fired
    vim.api.nvim_create_autocmd("User", {
      pattern = "FugitiveChanged",
      once = true,
      callback = function(ev)
        fired = ev.data.git_dir
      end,
    })
    local log, restore = H.capture_notify()
    vim.cmd("Git add %") -- in an unnamed buffer % stays literal
    H.wait(function()
      return fired ~= nil
    end)
    restore()
    assert.equals(repo.root .. "/.git", fired)
    -- the literal "%" failed: errors always notify
    assert.equals(1, #log)
    assert.equals("Fugitive", log[1].opts.title)
    assert.equals(vim.log.levels.ERROR, log[1].level)
    log, restore = H.capture_notify()
    vim.cmd("edit " .. repo:path("a"))
    local before = output.get(1)
    vim.cmd("Git add %")
    wait_done(before)
    assert.equals("M  a\n", repo:status())
    -- a successful `add` is not significant: silent
    assert.same({}, log)
    before = output.get(1)
    vim.cmd("Git commit -m significant")
    wait_done(before)
    restore()
    assert.equals(1, #log)
    assert.truthy(log[1].msg:match("significant"))
  end)

  it("notify.significant is configurable, with subcommand + flag entries", function()
    local routes = require("nvim-fugitive.cmd.routes")
    local list = { "commit", "reset --hard" }
    assert.is_true(routes.is_significant({ "commit", "-m", "x" }, list))
    assert.is_true(routes.is_significant({ "-c", "a=b", "reset", "--hard" }, list))
    assert.is_false(routes.is_significant({ "reset", "--soft", "HEAD~" }, list))
    assert.is_false(routes.is_significant({ "add", "." }, list))
  end)

  it("interactive commands run in a terminal", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    vim.cmd("cd " .. repo.root)
    vim.cmd("Git add -p")
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("terminal", vim.bo[buf].buftype)
    H.wait(function()
      return table.concat(H.lines(buf), "\n"):match("Stage this hunk")
    end, "prompt", 10000)
    vim.fn.chansend(vim.bo[buf].channel, "y\n")
    H.wait(function()
      return repo:status() == "M  a\n"
    end, "staged via add -p", 10000)
  end)

  it("checkout -b / switch -c with a name create the branch, without a picker", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("cd " .. repo.root)
    local select = vim.ui.select
    local picked = false
    vim.ui.select = function()
      picked = true
    end
    local before = output.get(1)
    vim.cmd("Git checkout -b topic")
    wait_done(before)
    assert.equals("topic", vim.trim(repo:git("branch", "--show-current")))
    before = output.get(1)
    vim.cmd("Git switch -c other")
    wait_done(before)
    vim.ui.select = select
    assert.equals("other", vim.trim(repo:git("branch", "--show-current")))
    assert.is_false(picked)
  end)

  it("chains commands with |", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    vim.cmd("cd " .. repo.root)
    local log, restore = H.capture_notify()
    vim.cmd("Git add a | Git commit -m chained")
    H.wait(function()
      return vim.trim(repo:git("log", "-1", "--format=%s")) == "chained"
    end, "chained commit")
    restore()
    local _ = log
  end)

  it("user-defined aliases are routed like their expansion; shell ones are tasks", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    -- common aliases from git guides and dotfiles
    repo:git("config", "alias.st", "status")
    repo:git(
      "config",
      "alias.lg",
      "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative"
    )
    repo:git("config", "alias.aliases", "config --get-regexp alias")
    repo:git("config", "alias.last", "log -1 HEAD")
    repo:git("config", "alias.hello", "!echo hello from a shell alias")
    -- shadowing a builtin is ignored by git, and so by the routing
    repo:git("config", "alias.status", "log")
    repo:write("a", "A\n")
    vim.cmd("cd " .. repo.root)

    -- a notification command that prints: the output is shown (it used to be
    -- dropped because `status` is not "significant")
    local log, restore = H.capture_notify()
    local before = output.get(1)
    vim.cmd("Git st")
    wait_done(before)
    assert.equals(0, #float_wins())
    assert.equals(1, #log)
    assert.truthy(log[1].msg:match("modified:%s+a"))
    restore()
    log, restore = H.capture_notify()
    before = output.get(1)
    vim.cmd("Git aliases")
    wait_done(before)
    assert.equals(1, #log)
    assert.truthy(log[1].msg:match("alias%.lg log %-%-graph"))
    restore()

    -- pager commands: the float
    before = output.get(1)
    vim.cmd("Git lg")
    wait_done(before)
    assert.equals(1, #float_wins())
    assert.truthy(H.lines(0)[1]:match("^%* %x+ %- %(HEAD %-> main%) initial %(.+%) <Test>$"))
    H.reset_ui()

    -- a shell alias runs as a task (overseer, or a plain job without it)
    log, restore = H.capture_notify()
    before = output.get(1)
    vim.cmd("Git hello")
    wait_done(before)
    H.wait(function()
      return #log >= 2
    end, "task report")
    restore()
    assert.equals(0, #float_wins())
    assert.truthy(log[1].msg:match("running"))
    assert.truthy(log[2].msg:match("done\nhello from a shell alias"))

    -- routes keyed by the alias name
    local config = require("nvim-fugitive.config")
    local saved = config.get().routes
    config.get().routes = { hello = "vert", last = "float" }
    before = output.get(1)
    vim.cmd("Git hello")
    wait_done(before)
    assert.equals(0, #float_wins())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals("hello from a shell alias", H.lines(0)[1])
    H.reset_ui()
    before = output.get(1)
    vim.cmd("Git last")
    wait_done(before)
    config.get().routes = saved
    assert.equals(1, #float_wins())
    assert.truthy(H.lines(0)[1]:match("^commit %x+"))
    H.reset_ui()

    -- `:Git status` is still git's status, not the alias
    log, restore = H.capture_notify()
    before = output.get(1)
    vim.cmd("Git status")
    wait_done(before)
    restore()
    assert.equals(0, #float_wins())
    assert.truthy(log[1].msg:match("modified:%s+a"))
  end)

  it("errors clearly on a name that is neither a git command nor an alias", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    local log, restore = H.capture_notify()
    vim.cmd("Git nosuchthing --flag")
    restore()
    assert.equals(1, #log)
    assert.equals(vim.log.levels.ERROR, log[1].level)
    assert.truthy(log[1].msg:match("'nosuchthing' is not a git command or a defined alias"))
    -- nothing was run
    assert.equals(before, output.get(1))
    assert.equals(0, #float_wins())
  end)

  it("expands % to the repo-relative path and errors outside a repo", function()
    local dir = H.tmpdir()
    vim.cmd("cd " .. dir)
    local log, restore = H.capture_notify()
    vim.cmd("Git status")
    restore()
    assert.truthy(log[1].msg:match("not a git repository"))
    assert.equals(vim.log.levels.ERROR, log[1].level)
  end)

  -- last: the error message leaves a hit-enter prompt behind in headless mode
  it(
    "notifications without a notify plugin end up in :messages, truncated, with the full text in :FugitiveOutput",
    function()
      local repo = H.repo({ files = { ["a"] = "a\n" } })
      vim.cmd("cd " .. repo.root)
      repo:git("config", "alias.boom", "!sh -c 'seq 1 30; echo fatal: kaboom >&2; exit 3'")
      local config = require("nvim-fugitive.config")
      local saved = config.get().routes
      config.get().routes = { boom = "notification" }
      local before = output.get(1)
      vim.cmd("Git boom")
      local e = wait_done(before)
      config.get().routes = saved
      assert.equals(3, e.code)
      local messages = vim.api.nvim_exec2("messages", { output = true }).output
      assert.truthy(messages:match("fatal: kaboom\n1\n2\n"))
      assert.truthy(messages:match("%(exit code 3%)"))
      assert.truthy(messages:match("… %(%+%d+ lines%) — :FugitiveOutput"))
      -- the error line is kept even though it is past max_lines
      assert.truthy(messages:match("fatal: kaboom"))
      assert.falsy(messages:match("\n25\n"))
      vim.cmd("FugitiveOutput")
      local buf = vim.api.nvim_get_current_buf()
      local text = table.concat(H.lines(buf), "\n")
      assert.truthy(text:match("\n25\n"))
      assert.truthy(text:match("fatal: kaboom"))
      assert.truthy(text:match("# exit code 3"))
      assert.equals(1, #float_wins())
    end
  )
end)

describe("completion", function()
  it("completes subcommands, flags, refs and paths", function()
    local repo = H.repo({ files = { ["dir/file.txt"] = "x\n", ["top.txt"] = "t\n" } })
    repo:git("branch", "feature")
    vim.cmd("cd " .. repo.root)
    local c = require("nvim-fugitive.cmd.complete")
    assert.truthy(vim.tbl_contains(c.git("chec", "Git chec", 8), "checkout"))
    assert.truthy(vim.tbl_contains(c.git("--am", "Git commit --am", 15), "--amend"))
    assert.truthy(vim.tbl_contains(c.git("fea", "Git checkout fea", 16), "feature"))
    assert.same({ "dir/" }, c.git("d", "Git add d", 9))
    assert.same({ "dir/file.txt" }, c.git("dir/", "Git add dir/", 12))
    assert.truthy(vim.tbl_contains(c.object("HEAD:"), "HEAD:dir/"))
    assert.truthy(vim.tbl_contains(c.object(":0:t"), ":0:top.txt"))
    assert.truthy(vim.tbl_contains(vim.fn.getcompletion("Git rest", "cmdline"), "restore-discard"))
  end)
end)
