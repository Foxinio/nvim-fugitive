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
      assert.equals(case[2], route(case[1]))
    end)
  end

  it("honours config overrides", function()
    local r = routes.classify({ "status" }, { overrides = { status = "float" }, long_running = {} })
    assert.equals("float", r.route)
  end)

  it("classifies aliases through their expansion", function()
    local r = routes.classify({ "ci" }, {
      overrides = {},
      long_running = {},
      aliases = function(name)
        return name == "ci" and { "commit" } or nil
      end,
    })
    assert.equals("editor", r.route)
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
