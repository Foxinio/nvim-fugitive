local tree = require("nvim-fugitive.buffers.summary.tree")

local function entries(paths)
  return vim.tbl_map(function(p)
    if type(p) == "table" then
      return { path = p[1], orig = p[2], status = "R" }
    end
    return { path = p, status = "M" }
  end, paths)
end

---"d<depth> name" for each node, files with their path in brackets.
local function shape(nodes)
  return vim.tbl_map(function(n)
    if n.type == "dir" then
      return string.format("d%d %s (%s, %d)", n.depth, n.name, n.dir, #n.entries)
    end
    return string.format("f%d %s [%s]", n.depth, n.name, n.entry.path)
  end, nodes)
end

describe("summary tree", function()
  it("leaves lone files and root files flat", function()
    assert.same(
      {
        "f0 Makefile [Makefile]",
        "f0 src/a.lua [src/a.lua]",
        "f0 tests/unit/x.lua [tests/unit/x.lua]",
      },
      shape(
        tree.build(entries({ "Makefile", "src/a.lua", "tests/unit/x.lua" }), { compact = true })
      )
    )
  end)

  it("groups a directory with two or more files and merges single-child chains", function()
    local nodes = tree.build(
      entries({
        "README.md",
        "lua/nvim-fugitive/cmd/git.lua",
        "lua/nvim-fugitive/cmd/log.lua",
        "lua/nvim-fugitive/init.lua",
        "tests/unit/argv_spec.lua",
      }),
      { compact = true }
    )
    assert.same({
      "f0 README.md [README.md]",
      "d0 lua/nvim-fugitive/ (lua/nvim-fugitive/, 3)",
      "d1 cmd/ (lua/nvim-fugitive/cmd/, 2)",
      "f2 git.lua [lua/nvim-fugitive/cmd/git.lua]",
      "f2 log.lua [lua/nvim-fugitive/cmd/log.lua]",
      "f1 init.lua [lua/nvim-fugitive/init.lua]",
      "f0 tests/unit/argv_spec.lua [tests/unit/argv_spec.lua]",
    }, shape(nodes))
  end)

  it("keeps a lone file in a subdirectory on one line, relative to its group", function()
    local nodes = tree.build(entries({ "lua/a.lua", "lua/ui/new.lua" }), { compact = true })
    assert.same({
      "d0 lua/ (lua/, 2)",
      "f1 a.lua [lua/a.lua]",
      "f1 ui/new.lua [lua/ui/new.lua]",
    }, shape(nodes))
  end)

  it("puts every level on its own line without compact", function()
    local nodes = tree.build(
      entries({ "README.md", "lua/f/cmd/git.lua", "lua/f/init.lua", "tests/unit/x.lua" }),
      { compact = false }
    )
    assert.same({
      "f0 README.md [README.md]",
      "d0 lua/ (lua/, 2)",
      "d1 f/ (lua/f/, 2)",
      "d2 cmd/ (lua/f/cmd/, 1)",
      "f3 git.lua [lua/f/cmd/git.lua]",
      "f2 init.lua [lua/f/init.lua]",
      "d0 tests/ (tests/, 1)",
      "d1 unit/ (tests/unit/, 1)",
      "f2 x.lua [tests/unit/x.lua]",
    }, shape(nodes))
  end)

  it("orders files and directories by name, as git does", function()
    local nodes = tree.build(entries({ "b.txt", "a/x", "a/y", "c/z", "c/w" }), { compact = true })
    assert.same({
      "d0 a/ (a/, 2)",
      "f1 x [a/x]",
      "f1 y [a/y]",
      "f0 b.txt [b.txt]",
      "d0 c/ (c/, 2)",
      "f1 w [c/w]",
      "f1 z [c/z]",
    }, shape(nodes))
  end)

  it("files a rename under its new path and names both sides relative to it", function()
    local nodes = tree.build(
      entries({
        "lua/a.lua",
        { "lua/ui/new.lua", "lua/ui/old.lua" },
        { "lua/b.lua", "other/b.lua" },
      }),
      { compact = true }
    )
    assert.same({
      "d0 lua/ (lua/, 3)",
      "f1 a.lua [lua/a.lua]",
      "f1 b.lua [lua/b.lua]",
      "f1 ui/new.lua [lua/ui/new.lua]",
    }, shape(nodes))
    assert.equals("ui/old.lua -> ui/new.lua", tree.label(nodes[4], "name"))
    assert.equals("../other/b.lua -> b.lua", tree.label(nodes[3], "name"))
    assert.equals("lua/ui/old.lua -> lua/ui/new.lua", tree.label(nodes[4], "full"))
  end)

  it("treats an untracked directory git reports (dir/) as a leaf", function()
    local nodes = tree.build(entries({ "docs/", "docs2/a", "docs2/b" }), { compact = true })
    assert.same({
      "f0 docs/ [docs/]",
      "d0 docs2/ (docs2/, 2)",
      "f1 a [docs2/a]",
      "f1 b [docs2/b]",
    }, shape(nodes))
  end)

  it("labels files by name or full path", function()
    local nodes = tree.build(entries({ "src/a.lua", "src/b.lua" }), { compact = true })
    assert.equals("src/", tree.label(nodes[1], "name"))
    assert.equals("a.lua", tree.label(nodes[2], "name"))
    assert.equals("src/a.lua", tree.label(nodes[2], "full"))
    assert.equals("src/", tree.label(nodes[1], "full"))
  end)
end)
