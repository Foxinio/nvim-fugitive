local routes = require("nvim-fugitive.cmd.routes")

local function route(cmdline)
  local args = vim.split(cmdline, " ", { trimempty = true })
  return routes.classify(args, {
    overrides = {},
    long_running = { "pull", "fetch", "push", "clone", "submodule update", "lfs" },
  }).route
end

describe("routes.classify", function()
  local cases = {
    -- pager -> float
    { "log", "float" },
    { "log --oneline -5", "float" },
    { "show HEAD", "float" },
    { "diff", "float" },
    { "diff --quiet", "notify" },
    { "blame foo.c", "float" },
    { "shortlog -sn", "float" },
    { "reflog", "float" },
    { "help commit", "float" },
    { "branch", "float" },
    { "branch -a", "float" },
    { "branch -vv", "float" },
    { "branch --contains HEAD", "float" },
    { "tag", "float" },
    { "tag -l v*", "float" },
    { "stash list", "float" },
    { "stash show -p", "float" },
    -- `-e` is a pattern for grep
    { "grep -e foo", "float" },
    { "grep -e foo -e bar", "float" },
    -- notify
    { "add foo", "notify" },
    { "rm foo", "notify" },
    { "mv a b", "notify" },
    { "reset --hard", "notify" },
    { "checkout main", "notify" },
    { "switch -c topic", "notify" },
    { "branch -d topic", "notify" },
    { "branch topic", "notify" },
    { "tag v1", "notify" },
    { "tag -d v1", "notify" },
    { "stash", "notify" },
    { "stash push", "notify" },
    { "stash pop", "notify" },
    { "cherry-pick abc", "notify" },
    { "commit -m x", "notify" },
    { "commit -am x", "notify" },
    { "commit -mfix-e", "notify" },
    { "commit --message=x", "notify" },
    { "commit -F msg.txt", "notify" },
    { "commit -C HEAD", "notify" },
    { "commit --amend --no-edit", "notify" },
    { "commit --fixup=abc", "notify" },
    { "merge topic", "notify" },
    { "merge --no-edit topic", "notify" },
    { "revert --no-edit HEAD", "notify" },
    { "config --get user.name", "notify" },
    { "config user.name x", "notify" },
    { "rebase main", "notify" },
    { "rebase --continue", "notify" },
    { "status", "notify" },
    { "frobnicate", "notify" },
    -- editor-first
    { "commit", "editor" },
    { "commit --amend", "editor" },
    { "commit -v", "editor" },
    { "commit -m x -e", "editor" },
    { "commit -c HEAD", "editor" },
    { "commit --fixup=reword:HEAD", "editor" },
    { "commit --squash=HEAD", "editor" },
    { "merge -e topic", "editor" },
    { "merge --edit topic", "editor" },
    { "revert HEAD", "editor" },
    { "cherry-pick -e abc", "editor" },
    { "config -e", "editor" },
    { "config --edit", "editor" },
    { "rebase -i HEAD~3", "editor" },
    { "rebase --interactive main", "editor" },
    { "rebase --edit-todo", "editor" },
    { "notes add", "editor" },
    { "notes edit", "editor" },
    { "notes add -m x", "notify" },
    { "tag -a v1", "editor" },
    { "tag -s v1", "editor" },
    { "tag -a v1 -m msg", "notify" },
    { "branch --edit-description", "editor" },
    -- terminal
    { "add -p", "terminal" },
    { "add --patch foo", "terminal" },
    { "reset -p", "terminal" },
    { "checkout -p", "terminal" },
    { "stash -p", "terminal" },
    { "stash push -p", "terminal" },
    { "clean -i", "terminal" },
    { "commit -p", "terminal" },
    -- tasks
    { "pull", "task" },
    { "fetch --all", "task" },
    { "push -u origin main", "task" },
    { "clone url", "task" },
    { "submodule update --init", "task" },
    { "submodule status", "notify" },
    { "lfs pull", "task" },
    -- global options
    { "-p status", "float" },
    { "--paginate status", "float" },
    { "-P log", "notify" },
    { "--no-pager log", "notify" },
    { "-c core.abbrev=12 log", "float" },
    { "-C sub commit -m x", "notify" },
  }
  for _, case in ipairs(cases) do
    it(case[1] .. " -> " .. case[2], function()
      -- the table uses the old names; classify returns the new targets
      local expected = routes.normalize(case[2])
      if expected == "editor" then
        expected = "editor"
      end
      assert.equals(expected, route(case[1]))
    end)
  end

  it("routes a bare blame to the side window", function()
    assert.equals("blame", route("blame"))
    assert.equals("blame", route("blame -w"))
    assert.equals("float", route("blame -L 1,2"))
  end)

  it("matches overrides by subcommand or 'subcommand word', most specific first", function()
    local function r(cmdline, overrides)
      return routes.classify(vim.split(cmdline, " ", { trimempty = true }), {
        overrides = overrides,
        long_running = {},
      })
    end
    local o =
      { stash = "notification", ["stash list"] = "tab", ["log --graph"] = "vert", status = "float" }
    assert.equals("tab", r("stash list", o).route)
    assert.equals("notification", r("stash show", o).route)
    assert.equals("vert", r("log --oneline --graph", o).route)
    assert.equals("float", r("log", o).route)
    assert.equals("float", r("status", o).route)
    assert.is_true(r("status", o).explicit)
    -- old names are aliases
    assert.equals("overseer", r("status", { status = "task" }).route)
    assert.equals("term", r("status", { status = "terminal" }).route)
  end)

  it("honours config overrides", function()
    local r = routes.classify({ "status" }, { overrides = { status = "float" }, long_running = {} })
    assert.equals("float", r.route)
  end)

  describe("aliases", function()
    local aliases = {
      ci = { "commit" },
      lg = { "log", "--oneline" },
      ap = { "add", "-p" },
      sh = {},
    }
    local function classify(args, overrides)
      return routes.classify(args, {
        overrides = overrides or {},
        long_running = {},
        aliases = function(name)
          return aliases[name]
        end,
      })
    end

    it("go to the float by default", function()
      for _, name in ipairs({ "ci", "lg", "sh" }) do
        local r = classify({ name })
        assert.equals("float", r.route, name)
        assert.equals(name, r.alias)
      end
      assert.equals("commit", classify({ "ci" }).sub)
    end)

    it("keep a terminal for interactive expansions", function()
      assert.equals("term", classify({ "ap" }).route)
    end)

    it("are routed by their own name first, then by the expansion", function()
      assert.equals("vert", classify({ "lg" }, { lg = "vert", log = "tab" }).route)
      assert.equals("tab", classify({ "lg" }, { log = "tab" }).route)
      assert.equals("overseer", classify({ "sh" }, { sh = "task" }).route)
      assert.equals("notification", classify({ "ci", "-m", "x" }, { ["ci -m"] = "notify" }).route)
    end)
  end)
end)

describe("routes.has_flag", function()
  it("is per-word and stops at --", function()
    assert.is_true(routes.has_flag({ "-am" }, { "-m" }))
    assert.is_true(routes.has_flag({ "--message=x" }, { "--message" }))
    assert.is_false(routes.has_flag({ "--", "-m" }, { "-m" }))
    assert.is_false(routes.has_flag({ "--messages" }, { "--message" }))
    assert.is_false(routes.has_flag({ "-mfoe" }, { "-e" }))
  end)
end)

describe("routes.picker_trigger", function()
  local trig = function(s)
    return routes.picker_trigger(vim.split(s, " ", { trimempty = true }))
  end
  it("triggers for the exact bare forms", function()
    assert.same({ picker = "refs", sub = "checkout", args = { "checkout" } }, trig("checkout"))
    assert.same({ picker = "refs", sub = "switch", args = { "switch" } }, trig("switch"))
    assert.same({ picker = "refs", sub = "merge", args = { "merge" } }, trig("merge"))
    assert.same({ picker = "refs", sub = "rebase", args = { "rebase" } }, trig("rebase"))
  end)
  it("triggers for the allow-listed flag-only forms", function()
    assert.equals("log", trig("rebase -i").picker)
    assert.equals("log", trig("rebase --interactive").picker)
    assert.equals("refs", trig("switch -c topic").picker)
    assert.equals("refs", trig("checkout -b topic").picker)
  end)
  it("passes every other invocation through", function()
    for _, s in ipairs({
      "rebase --continue",
      "rebase --abort",
      "merge --abort",
      "checkout -- file",
      "switch -",
      "checkout main",
      "rebase -i main",
      "switch -c",
      "checkout -b topic main",
      "log",
    }) do
      assert.is_nil(trig(s), s)
    end
  end)
end)
