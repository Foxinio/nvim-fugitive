local diff = require("fugitive.git.diff")

local sample = table.concat({
  "diff --git a/f.txt b/f.txt",
  "index 1111111..2222222 100644",
  "--- a/f.txt",
  "+++ b/f.txt",
  "@@ -1,4 +1,4 @@",
  " one",
  "-two",
  "+TWO",
  " three",
  "-four",
  "+FOUR",
  "@@ -10,2 +10,3 @@ ctx",
  " ten",
  "+ten and a half",
  " eleven",
  "diff --git a/with space.txt b/with space.txt",
  "new file mode 100644",
  "index 0000000..3333333",
  "--- /dev/null",
  "+++ b/with space.txt",
  "@@ -0,0 +1 @@",
  "+hello",
  "\\ No newline at end of file",
}, "\n") .. "\n"

describe("diff.parse", function()
  it("parses files, headers and hunks", function()
    local files = diff.parse(sample)
    assert.equals(2, #files)
    assert.equals("f.txt", files[1].path)
    assert.equals(4, #files[1].header)
    assert.equals(2, #files[1].hunks)
    local h = files[1].hunks[2]
    assert.same({ 10, 2, 10, 3 }, { h.old_start, h.old_count, h.new_start, h.new_count })
    assert.equals("with space.txt", files[2].path)
    assert.is_true(files[2].new_file)
    assert.same({ "+hello", "\\ No newline at end of file" }, files[2].hunks[1].lines)
    assert.equals(1, files[2].hunks[1].new_count)
  end)

  it("handles renames, binaries, quoted paths and mode-only changes", function()
    local files = diff.parse(table.concat({
      "diff --git a/old b/new",
      "similarity index 100%",
      "rename from old",
      "rename to new",
      "diff --git a/bin b/bin",
      "index 1..2 100644",
      "Binary files a/bin and b/bin differ",
      'diff --git "a/t\\tab" "b/t\\tab"',
      "old mode 100644",
      "new mode 100755",
      "diff --git a/x b/x",
      "old mode 100644",
      "new mode 100755",
    }, "\n"))
    assert.equals("new", files[1].path)
    assert.equals("old", files[1].old_path)
    assert.is_true(files[2].binary)
    assert.equals("t\tab", files[3].path)
    assert.equals("x", files[4].path)
  end)

  it("computes line numbers", function()
    local h = diff.parse(sample)[1].hunks[1]
    local n = diff.line_numbers(h)
    assert.same({ old = 1, new = 1 }, n[1])
    assert.same({ old = 2 }, n[2])
    assert.same({ new = 2 }, n[3])
    assert.same({ old = 3, new = 3 }, n[4])
  end)
end)

describe("diff.build_patch", function()
  local file = diff.parse(sample)[1]

  it("returns whole hunks verbatim", function()
    local p = diff.build_patch(file, { { hunk = file.hunks[2] } }, false)
    assert.equals(table.concat({
      "diff --git a/f.txt b/f.txt",
      "index 1111111..2222222 100644",
      "--- a/f.txt",
      "+++ b/f.txt",
      "@@ -10,2 +10,3 @@ ctx",
      " ten",
      "+ten and a half",
      " eleven",
    }, "\n") .. "\n", p)
  end)

  it("forward: unselected - become context, unselected + are dropped", function()
    -- select "-two" and "+TWO" only
    local p = diff.build_patch(
      file,
      { { hunk = file.hunks[1], lines = { [2] = true, [3] = true } } },
      false
    )
    local body = vim.split(p, "\n")
    assert.same(
      { "@@ -1,4 +1,4 @@", " one", "-two", "+TWO", " three", " four" },
      vim.list_slice(body, 5, 10)
    )
  end)

  it("reverse: unselected + become context, unselected - are dropped", function()
    local p =
      diff.build_patch(file, { { hunk = file.hunks[1], lines = { [5] = true, [6] = true } } }, true)
    local body = vim.split(p, "\n")
    assert.same(
      { "@@ -1,4 +1,4 @@", " one", " TWO", " three", "-four", "+FOUR" },
      vim.list_slice(body, 5, 10)
    )
  end)

  it("returns nil when no change line is selected", function()
    assert.is_nil(
      diff.build_patch(file, { { hunk = file.hunks[1], lines = { [1] = true } } }, false)
    )
  end)

  it("drops a no-newline marker whose line was dropped", function()
    local f2 = diff.parse(table.concat({
      "diff --git a/n b/n",
      "--- a/n",
      "+++ b/n",
      "@@ -1,2 +1,2 @@",
      " a",
      "-b",
      "\\ No newline at end of file",
      "+B",
      "\\ No newline at end of file",
    }, "\n"))[1]
    local p = diff.build_patch(f2, { { hunk = f2.hunks[1], lines = { [2] = true } } }, false)
    assert.equals("@@ -1,2 +1,1 @@\n a\n-b\n\\ No newline at end of file\n", p:match("(@@.*)$"))
  end)
end)
