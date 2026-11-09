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

  -- common aliases from git guides and dotfiles
  describe("aliases", function()
    local aliases = {
      st = { "status" },
      co = { "checkout" },
      br = { "branch" },
      ci = { "commit" },
      lg = {
        "log",
        "--graph",
        "--pretty=format:%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset",
        "--abbrev-commit",
        "--date=relative",
      },
      lola = { "log", "--graph", "--decorate", "--oneline", "--all" },
      ds = { "diff", "--staged" },
      unstage = { "reset", "HEAD", "--" },
      aliases = { "config", "--get-regexp", "alias" },
      ap = { "add", "-p" },
      main = {}, -- !git checkout main && git pull
      ac = {}, -- !git add -A && git commit
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

    it("are routed like the command they expand to", function()
      local expect = {
        st = { "status", "notification" },
        co = { "checkout", "notification" },
        br = { "branch", "float" },
        ci = { "commit", "editor" },
        lg = { "log", "float" },
        lola = { "log", "float" },
        ds = { "diff", "float" },
        unstage = { "reset", "notification" },
        aliases = { "config", "notification" },
        ap = { "add", "term" },
      }
      for name, e in pairs(expect) do
        local r = classify({ name })
        assert.equals(e[1], r.sub, name)
        assert.equals(e[2], r.route, name)
        assert.equals(name, r.alias)
      end
      -- arguments after the alias count too
      assert.equals("notification", classify({ "ci", "-m", "x" }).route)
      assert.equals("term", classify({ "co", "-p" }).route)
    end)

    it("run shell aliases as tasks", function()
      assert.equals("overseer", classify({ "main" }).route)
      assert.equals("overseer", classify({ "ac", "-m", "wip" }).route)
      assert.equals("float", classify({ "-p", "main" }).route)
      assert.equals("notification", classify({ "--no-pager", "main" }).route)
    end)

    it("are routed by their own name first, then by the expansion", function()
      assert.equals("vert", classify({ "lg" }, { lg = "vert", log = "tab" }).route)
      assert.equals("tab", classify({ "lg" }, { log = "tab" }).route)
      assert.equals("term", classify({ "main" }, { main = "term" }).route)
      assert.equals("float", classify({ "st" }, { st = "float" }).route)
      assert.equals("status", classify({ "st" }, { st = "float" }).sub)
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
  it("splits short clusters by the subcommand's own value letters", function()
    -- push -u is a switch, branch -u takes the upstream
    assert.is_true(routes.has_flag({ "-uf" }, { "-f" }, "push"))
    assert.is_false(routes.has_flag({ "-uf" }, { "-f" }, "branch"))
    assert.is_true(routes.has_flag({ "-fu" }, { "-u" }, "push"))
    -- --x v and --x=v are the same option
    assert.is_true(routes.has_flag({ "--fixup", "amend:HEAD" }, { "--fixup=amend:" }, "commit"))
    assert.is_true(routes.has_flag({ "--", "x" }, { "--" }, "blame"))
  end)
end)

describe("routes.scan", function()
  local scan = function(sub, s)
    return routes.scan(sub, vim.split(s, " ", { trimempty = true }))
  end
  it("reads options, their values and positionals per subcommand", function()
    local r = scan("commit", "-am msg --author me --date=now file")
    assert.same(
      {
        { "-a" },
        { "-m", "msg" },
        { "--author", "me" },
        { "--date", "now" },
      },
      vim.tbl_map(function(o)
        return { o[1], o[2] }
      end, r.opts)
    )
    assert.same({ "file" }, r.positionals)
    assert.is_false(r.dashdash)
  end)
  it("expands clusters with attached values", function()
    assert.same(
      { "-m", "fix" },
      { scan("commit", "-vmfix").opts[2][1], scan("commit", "-vmfix").opts[2][2] }
    )
    assert.equals(2, #scan("push", "-uf").opts)
    -- an optional value is attached only: -uno is -u no, -S takes no word
    assert.same({ { "-u", "no" } }, scan("commit", "-uno").opts)
    assert.same({ "msg" }, scan("commit", "-S msg").positionals)
  end)
  it("stops at -- and keeps a lone - as a positional", function()
    local r = scan("checkout", "-f - -- a b")
    assert.same({ "-" }, r.positionals)
    assert.is_true(r.dashdash)
    assert.same({ "a", "b" }, r.after)
  end)
  it("does not take option values for positionals", function()
    assert.same({}, scan("log", "-n 5 --author me").positionals)
    assert.same({ "add" }, scan("notes", "--ref foo add").positionals)
    assert.same({ "f.txt" }, scan("blame", "-L 1,5 --date iso f.txt").positionals)
  end)
end)

describe("editor routing", function()
  local route = function(s)
    return routes.classify(vim.split(s, " ", { trimempty = true }), { overrides = {} }).route
  end
  it("lets the last of --edit and --no-edit win, as git does", function()
    assert.equals("notification", route("commit -e --no-edit"))
    assert.equals("editor", route("commit --no-edit -e"))
    assert.equals("editor", route("merge --no-edit -e"))
    assert.equals("notification", route("merge -e --no-edit"))
    assert.equals("notification", route("commit -c HEAD --no-edit"))
  end)
  it("keeps -e over a message given elsewhere", function()
    assert.equals("editor", route("commit -e -m msg"))
    assert.equals("editor", route("commit -m msg --edit"))
    assert.equals("notification", route("commit -m msg"))
  end)
  it("reads the notes subcommand after the global --ref", function()
    assert.equals("editor", route("notes --ref foo add"))
    assert.equals("editor", route("notes --ref=foo add"))
    assert.equals("notification", route("notes --ref foo add -m msg"))
  end)
  it("opens the editor for annotated tags without a message", function()
    assert.equals("editor", route("tag -u key v1"))
    assert.equals("notification", route("tag -u key -m msg v1"))
    assert.equals("editor", route("tag -a v1 -m msg -e"))
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
    assert.same({ picker = "push", sub = "push", args = { "push" } }, trig("push"))
    for _, form in ipairs({ "push -u", "push --set-upstream" }) do
      local t = trig(form)
      assert.equals("push", t.picker, form)
      assert.is_true(t.set_upstream, form)
    end
  end)
  it("triggers for the allow-listed flag-only forms", function()
    assert.equals("log", trig("rebase -i").picker)
    assert.equals("log", trig("rebase --interactive").picker)
  end)
  it("triggers when only flags are given", function()
    for _, s in ipairs({
      "push -f",
      "push --force",
      "push --force-with-lease",
      "push -o ci.skip",
      "push --push-option ci.skip",
      "push -v --dry-run",
      "-c push.default=current push",
      "merge --no-ff",
      "merge -m msg",
      "checkout --detach",
      "switch --detach",
      "rebase --autostash",
    }) do
      local t = trig(s)
      assert.is_not_nil(t, s)
      assert.is_nil(t.set_upstream, s)
    end
    assert.equals("push", trig("push -f").picker)
    assert.equals("refs", trig("merge --no-ff").picker)
    assert.equals("log", trig("rebase -i --autosquash").picker)
    assert.same({ "-c", "push.default=current", "push" }, trig("-c push.default=current push").args)
  end)
  it("sets the upstream for -u anywhere in the flags", function()
    for _, s in ipairs({
      "push -f -u",
      "push -u -f",
      "push -fu",
      "push -uf",
      "push --set-upstream -f",
    }) do
      local t = trig(s)
      assert.equals("push", t and t.picker, s)
      assert.is_true(t.set_upstream, s)
    end
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
      -- creating a branch: from HEAD, no picker
      "switch -c topic",
      "switch --create topic",
      "checkout -b topic",
      "checkout -b topic main",
      "push origin",
      "push origin main",
      "push -f origin",
      "push -o ci.skip origin",
      "push --all",
      "push --tags",
      "push --mirror",
      "push -d",
      "push --delete",
      "merge --continue",
      "merge --quit",
      "rebase --skip",
      "rebase --edit-todo",
      "rebase -i --root",
      "checkout -p",
      "checkout --orphan new",
      "switch --orphan new",
      "push -u origin",
      "push -u origin main",
      "log",
    }) do
      assert.is_nil(trig(s), s)
    end
  end)
end)
