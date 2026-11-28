local fold = require("nvim-fugitive.buffers.summary.fold")
local render = require("nvim-fugitive.buffers.summary.render")

describe("summary fold state", function()
  it("opens directories and closes diffs by default", function()
    local open = fold.new()
    assert.is_true(fold.is_open(open, fold.node("dir", "Unstaged", "src/")))
    assert.is_false(fold.is_open(open, fold.node("file", "Unstaged", "src/a")))
    assert.is_false(fold.is_open(open, fold.node("commit", "Unpushed", "abc")))
    assert.is_false(fold.is_open(open, fold.node("stash", "Stash", "stash@{0}")))
  end)

  it("keeps a directory and a file with the same path apart", function()
    local open = fold.new()
    local dir = fold.node("dir", "Untracked", "docs/")
    local file = fold.node("file", "Untracked", "docs/")
    fold.set(open, file, true)
    fold.set(open, dir, false)
    assert.is_true(fold.is_open(open, file))
    assert.is_false(fold.is_open(open, dir))
    fold.reset(open, dir)
    assert.is_true(fold.is_open(open, dir))
    assert.is_true(fold.is_open(open, file))
  end)

  it("closes a node and resets what was opened under it, keeping directories", function()
    local open = fold.new()
    local d = { fold = fold.node("dir", "S", "a/") }
    local sub = { fold = fold.node("dir", "S", "a/b/"), parent = d }
    local f = { fold = fold.node("file", "S", "a/b/f"), parent = sub }
    local g = { fold = fold.node("file", "S", "c/g") }
    fold.set(open, sub.fold, false)
    fold.set(open, f.fold, true)
    fold.set(open, g.fold, true)
    fold.close(open, { d, sub, f, g }, d)
    assert.is_false(fold.is_open(open, d.fold))
    assert.is_false(fold.is_open(open, sub.fold)) -- its own state, kept
    assert.is_false(fold.is_open(open, f.fold)) -- reset
    assert.is_nil(open.diff[f.fold.id])
    assert.is_true(fold.is_open(open, g.fold)) -- not under it
  end)

  it("gives the snapshot the open and closed diffs, live", function()
    local open = fold.new()
    local seen = fold.expansions(open)
    fold.set(open, fold.node("file", "Unstaged", "a"), true)
    fold.set(open, fold.node("stash", "Stash", "stash@{0}"), true)
    fold.set(open, fold.node("file", "Untracked", "d/"), false)
    fold.set(open, fold.node("dir", "Unstaged", "x/"), false)
    assert.same(
      { ["Unstaged\0a"] = true, ["Stash\0stash@{0}"] = true, ["Untracked\0d/"] = false },
      seen
    )
  end)
end)

describe("summary render links", function()
  local function entry(path, status)
    return { path = path, status = status or "M", xy = " M", sub = "N...", submodule = false }
  end
  local function snap(status, extra)
    return vim.tbl_extend("force", {
      headers = {},
      status = vim.tbl_extend(
        "force",
        { untracked = {}, unstaged = {}, staged = {}, unmerged = {} },
        status
      ),
      diffs = { Unstaged = {}, Staged = {}, Untracked = {}, Unmerged = {} },
      logs = {},
      stashes = {},
    }, extra or {})
  end
  local function find(info, pred)
    for _, i in ipairs(info) do
      if pred(i) then
        return i
      end
    end
  end

  it("links files to their directory line and diff lines to their file", function()
    local s = snap({ unstaged = { entry("a/x"), entry("a/b/y"), entry("a/b/z") } })
    s.diffs.Unstaged["a/b/y"] = {
      header = { "diff --git a/a/b/y b/a/b/y" },
      hunks = { { header = "@@ -1 +1 @@", lines = { "-y", "+Y" } } },
    }
    local open = fold.new()
    fold.set(open, fold.node("file", "Unstaged", "a/b/y"), true)
    local _, info = render.render(s, open, { tree = true, compact = true })
    local a = find(info, function(i)
      return i.kind == "dir" and i.dir == "a/"
    end)
    local b = find(info, function(i)
      return i.kind == "dir" and i.dir == "a/b/"
    end)
    local y = find(info, function(i)
      return i.kind == "file" and i.entry.path == "a/b/y"
    end)
    local x = find(info, function(i)
      return i.kind == "file" and i.entry.path == "a/x"
    end)
    local hunk = find(info, function(i)
      return i.kind == "hunk"
    end)
    assert.is_nil(a.parent)
    assert.equals(a, b.parent)
    assert.equals(b, y.parent)
    assert.equals(a, x.parent)
    assert.equals(y, hunk.parent)
    assert.is_true(y.open)
    assert.is_nil(x.open)
    assert.same(fold.node("dir", "Unstaged", "a/b/"), b.fold)
  end)

  it("links an expanded untracked directory's files to its line", function()
    local d = entry("docs/", "?")
    local s = snap({ untracked = { d } }, {
      untracked_children = { ["docs/"] = { entry("docs/one", "?"), entry("docs/two", "?") } },
    })
    local _, info = render.render(s, fold.new(), { tree = false })
    local dline = find(info, function(i)
      return i.kind == "file" and i.entry.path == "docs/"
    end)
    local one = find(info, function(i)
      return i.kind == "file" and i.entry.path == "docs/one"
    end)
    assert.is_true(dline.open)
    assert.equals(dline, one.parent)
  end)
end)

describe("summary items", function()
  local items = require("nvim-fugitive.buffers.summary.items")
  local function entry(path, status)
    return { path = path, status = status or "M", xy = " M", sub = "N...", submodule = false }
  end
  local function rendered()
    local s = {
      headers = { { key = "Head", value = "main" } },
      status = {
        untracked = {},
        unstaged = { entry("a/x"), entry("a/y") },
        staged = { entry("b") },
        unmerged = {},
      },
      diffs = { Unstaged = {}, Staged = {}, Untracked = {}, Unmerged = {} },
      logs = {},
      stashes = {},
    }
    s.diffs.Unstaged["a/x"] = {
      header = { "diff --git a/a/x b/a/x" },
      hunks = {
        { header = "@@ -1 +1 @@", lines = { "-1", "+2" } },
        { header = "@@ -5 +5 @@", lines = { "-5", "+6" } },
      },
    }
    local open = fold.new()
    fold.set(open, fold.node("file", "Unstaged", "a/x"), true)
    local lines, info = render.render(s, open, { tree = true, compact = true, paths = "full" })
    return { info = info }, lines
  end
  local function line_of(lines, text)
    for l, t in ipairs(lines) do
      if t == text then
        return l
      end
    end
    error("no line " .. text)
  end

  it("gives every line its item, and every item its lines", function()
    local st, lines = rendered()
    local head = items.at(st, 1)
    assert.equals("header", head.kind)
    local sec = items.at(st, line_of(lines, "Unstaged (2)"))
    assert.equals("section", sec.kind)
    local dir = items.at(st, line_of(lines, "▾ a/"))
    assert.equals(dir, items.at(st, dir.first))
    local x = items.at(st, line_of(lines, "  a/x"))
    local hunk2 = items.at(st, line_of(lines, "@@ -5 +5 @@"))
    assert.equals("hunk", hunk2.kind)
    assert.equals(hunk2, items.at(st, line_of(lines, "+6")))
    assert.equals(x, hunk2.parent)
    assert.equals(x, items.foldable(hunk2))
    -- the file covers its diff, the dir its files, the section all of it
    assert.equals(line_of(lines, "+6"), x.last)
    assert.equals(line_of(lines, "  a/y"), dir.last)
    assert.equals(dir.last, sec.last)
    assert.equals(sec, x.section_item)
    assert.same(
      { 1, 2, 3, 4 },
      { items.depth(sec), items.depth(dir), items.depth(x), items.depth(hunk2) }
    )
    assert.is_nil(items.at(st, line_of(lines, "Unstaged (2)") - 1)) -- the blank line
  end)

  it("lists the distinct items of a range, across sections", function()
    local st, lines = rendered()
    local got = items.in_range(st, line_of(lines, "-1"), line_of(lines, "  b"))
    local kinds = vim.tbl_map(function(i)
      return i.kind
    end, got)
    assert.same({ "hunk", "hunk", "file", "section", "file" }, kinds)
  end)
end)
