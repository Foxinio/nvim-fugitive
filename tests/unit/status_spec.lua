local status = require("nvim-fugitive.git.status")

local function z(...)
  return table.concat({ ... }, "\0") .. "\0"
end

local H40 = string.rep("1", 40)
local H40b = string.rep("2", 40)

describe("status.parse", function()
  it("parses branch headers", function()
    local st = status.parse(
      z(
        "# branch.oid " .. H40,
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +2 -1",
        "# stash 3"
      )
    )
    assert.equals(H40, st.oid)
    assert.equals("main", st.head)
    assert.equals("origin/main", st.upstream)
    assert.equals(2, st.ahead)
    assert.equals(1, st.behind)
    assert.equals(3, st.stash)
  end)

  it("handles unborn and detached heads", function()
    local st = status.parse(z("# branch.oid (initial)", "# branch.head (detached)"))
    assert.is_nil(st.oid)
    assert.is_nil(st.head)
  end)

  it("splits ordinary entries into staged and unstaged", function()
    local st = status.parse(
      z(
        "1 MM N... 100644 100644 100644 " .. H40 .. " " .. H40b .. " both.txt",
        "1 .D N... 100644 100644 000000 " .. H40 .. " " .. H40 .. " gone.txt",
        "1 A. N... 000000 100644 100644 "
          .. string.rep("0", 40)
          .. " "
          .. H40
          .. " dir/with space.txt"
      )
    )
    assert.equals(2, #st.staged)
    assert.equals("M", st.staged[1].status)
    assert.equals("A", st.staged[2].status)
    assert.equals("dir/with space.txt", st.staged[2].path)
    assert.equals(2, #st.unstaged)
    assert.equals("M", st.unstaged[1].status)
    assert.equals("D", st.unstaged[2].status)
  end)

  it("parses renames with their original path", function()
    local st = status.parse(
      z("2 R. N... 100644 100644 100644 " .. H40 .. " " .. H40 .. " R100 new.txt", "old.txt")
    )
    assert.equals(1, #st.staged)
    assert.equals("new.txt", st.staged[1].path)
    assert.equals("old.txt", st.staged[1].orig)
    assert.equals("R old.txt -> new.txt", status.format(st.staged[1]))
  end)

  it("puts unmerged entries in their own section", function()
    local st = status.parse(
      z("u UU N... 100644 100644 100644 100644 " .. H40 .. " " .. H40b .. " " .. H40 .. " c.txt")
    )
    assert.equals(0, #st.staged)
    assert.equals(0, #st.unstaged)
    assert.equals(1, #st.unmerged)
    assert.equals("c.txt", st.unmerged[1].path)
    assert.equals("UU", st.unmerged[1].xy)
  end)

  it("parses untracked and ignored files and submodules", function()
    local st = status.parse(
      z(
        "? new file.txt",
        "! build/",
        "1 .M SC.. 160000 160000 160000 " .. H40 .. " " .. H40 .. " sm",
        "1 .M S.M. 160000 160000 160000 " .. H40 .. " " .. H40 .. " sm2"
      )
    )
    assert.equals("new file.txt", st.untracked[1].path)
    assert.equals("build/", st.ignored[1].path)
    assert.is_true(st.unstaged[1].submodule)
    assert.equals("M", st.unstaged[1].status)
    assert.equals("?", st.unstaged[2].status)
  end)
end)
