local argv = require("nvim-fugitive.cmd.argv")

describe("argv.shell_alias_command", function()
  local cmd = argv.shell_alias_command
  it("finds the one git command a shell alias runs", function()
    assert.same({ "log", "--graph", "--oneline", "--all" }, cmd("!git log --graph --oneline --all"))
    assert.same({ "log", "--format=%h | %s" }, cmd([[!git log --format='%h | %s']]))
    assert.same({ "log" }, cmd("!cd sub && git log"))
    assert.same({ "log", "-n", "1" }, cmd("!command git log -n 1"))
  end)
  it("passes the arguments like git does", function()
    -- appended to a plain command
    assert.same({ "log", "--graph", "-n", "3" }, cmd("!git log --graph", { "-n", "3" }))
    -- "$@" / $1 in a function wrapper
    assert.same(
      { "log", "--graph", "-n", "3" },
      cmd([[!f() { git log --graph "$@"; }; f]], { "-n", "3" })
    )
    assert.same({ "show", "HEAD~2" }, cmd([[!f() { git show "$1"; }; f]], { "HEAD~2", "x" }))
    -- a wrapper that ignores them, or a pipeline that gets them
    assert.same({ "log" }, cmd([[!f() { git log; }; f]], { "-n", "3" }))
    assert.same({ "log", "--oneline" }, cmd("!git log --oneline | head -20", { "-5" }))
  end)
  it("gives up when it cannot tell what runs", function()
    assert.is_nil(cmd("!git checkout main && git pull"))
    assert.is_nil(cmd("!sh -c 'echo hi'"))
    assert.is_nil(cmd("!git log $(git rev-parse HEAD)"))
    assert.is_nil(cmd("!git log $REV"))
    assert.is_nil(cmd("!echo git"))
  end)
end)

describe("argv.has_flag", function()
  it("is per-word and stops at --", function()
    assert.is_true(argv.has_flag({ "-am" }, { "-m" }))
    assert.is_true(argv.has_flag({ "--message=x" }, { "--message" }))
    assert.is_false(argv.has_flag({ "--", "-m" }, { "-m" }))
    assert.is_false(argv.has_flag({ "--messages" }, { "--message" }))
    assert.is_false(argv.has_flag({ "-mfoe" }, { "-e" }))
  end)
  it("splits short clusters by the subcommand's own value letters", function()
    -- push -u is a switch, branch -u takes the upstream
    assert.is_true(argv.has_flag({ "-uf" }, { "-f" }, "push"))
    assert.is_false(argv.has_flag({ "-uf" }, { "-f" }, "branch"))
    assert.is_true(argv.has_flag({ "-fu" }, { "-u" }, "push"))
    -- --x v and --x=v are the same option
    assert.is_true(argv.has_flag({ "--fixup", "amend:HEAD" }, { "--fixup=amend:" }, "commit"))
    assert.is_true(argv.has_flag({ "--", "x" }, { "--" }, "blame"))
  end)
end)

describe("argv.scan", function()
  local scan = function(sub, s)
    return argv.scan(sub, vim.split(s, " ", { trimempty = true }))
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
    assert.same({ 3 }, scan("notes", "--ref foo add").at)
  end)
end)

describe("argv.shell_split", function()
  local split = argv.shell_split

  it("leaves a line without shell syntax alone", function()
    assert.is_nil(split("diff --stat HEAD~1"))
    assert.is_nil(split("log --format=%h --grep=a\\|b"))
    assert.is_nil(split("commit -m 'a > b'"))
    assert.is_nil(split('commit -m "a ; b"'))
    assert.is_nil(split("log \\> x"))
    assert.is_nil(split("show '$(x)'"))
  end)

  it("splits at the first redirection, pipe or separator", function()
    assert.same(
      { words = { "diff" }, raw = { diff = "diff" }, tail = "> a.patch" },
      split("diff > a.patch")
    )
    assert.equals(">>a", split("diff >>a").tail)
    assert.equals("2>&1 >x", split("diff 2>&1 >x").tail)
    assert.equals(">x", split("diff>x").tail)
    assert.equals("| head -3", split("log --oneline \\| head -3").tail)
    assert.equals("&& echo ok", split("fetch && echo ok").tail)
    assert.equals("; echo ok", split("fetch; echo ok").tail)
    assert.same({ "log", "--oneline" }, split("log --oneline \\| head -3").words)
  end)

  it("keeps the git part's words as typed", function()
    local s = split([[log -1 "--format=%h %s" $(git rev-parse HEAD)]])
    assert.equals("", s.tail)
    assert.same({ "log", "-1", "--format=%h %s", "$(git", "rev-parse", "HEAD)" }, s.words)
    assert.equals([["--format=%h %s"]], s.raw["--format=%h %s"])
    assert.is_truthy(split("log $REV"))
    assert.is_truthy(split('log "$REV"'))
  end)
end)

describe("argv.redirects_stdout", function()
  it("tells where the output goes", function()
    assert.is_true(argv.redirects_stdout("> a"))
    assert.is_true(argv.redirects_stdout(">> a"))
    assert.is_true(argv.redirects_stdout("1> a"))
    assert.is_true(argv.redirects_stdout("&> a"))
    assert.is_true(argv.redirects_stdout("2>&1 > a"))
    assert.is_true(argv.redirects_stdout("| grep x > a"))
    assert.is_false(argv.redirects_stdout("2> /dev/null"))
    assert.is_false(argv.redirects_stdout("2>&1"))
    assert.is_false(argv.redirects_stdout("> a | cat"))
    assert.is_false(argv.redirects_stdout("| grep '>'"))
    assert.is_false(argv.redirects_stdout(""))
  end)
end)
