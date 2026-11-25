local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")
local config = require("nvim-fugitive.config")

local function open(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0
  end)
  return buf
end

local function after(buf, fn)
  local st = summary.state(buf)
  H.wait(function()
    return not st.running
  end, "summary idle")
  local tick = st.tick
  fn()
  H.wait(function()
    return st.tick > tick and not st.running
  end, "refresh")
end

local function goto_line(pattern)
  local l = assert(H.find_line(pattern), "no line " .. pattern)
  vim.api.nvim_win_set_cursor(0, { l, 0 })
end

---A repo with `c` in conflict: two blocks, main's and topic's sides.
local function conflicted()
  local repo = H.repo({ files = { ["c"] = "1\nx\n2\n3\n4\n5\ny\n6\n" } })
  repo:git("checkout", "-q", "-b", "topic")
  repo:commit("topic", { ["c"] = "1\nT1\n2\n3\n4\n5\nT2\n6\n" })
  repo:git("checkout", "-q", "main")
  repo:commit("main", { ["c"] = "1\nM1\n2\n3\n4\n5\nM2\n6\n" })
  repo:git("merge", "topic", { allow_fail = true })
  return repo
end

describe("summary section keys", function()
  local log, restore
  before_each(function()
    H.reset_ui()
    log, restore = H.capture_notify()
    require("nvim-fugitive.watch").enable(false)
  end)
  after_each(function()
    restore()
    require("nvim-fugitive.watch").enable(true)
    config.set({})
  end)

  local function letters(preset)
    config.set({
      maps = { preset = preset },
      summary = { status = { letters = true, color = { enabled = false } } },
    })
  end

  for _, case in ipairs({
    { "co", "1\nM1\n2\n3\n4\n5\nM2\n6\n" },
    { "ct", "1\nT1\n2\n3\n4\n5\nT2\n6\n" },
    { "cb", "1\nM1\nT1\n2\n3\n4\n5\nM2\nT2\n6\n" },
    { "c0", "1\n2\n3\n4\n5\n6\n" },
  }) do
    it(case[1] .. " resolves every block of an unmerged file, and g- undoes it", function()
      letters("default")
      local repo = conflicted()
      local before = repo:read("c")
      local buf = open(repo)
      goto_line("^U c")
      after(buf, function()
        H.feed(case[1])
      end)
      assert.equals(case[2], repo:read("c"))
      after(buf, function()
        H.feed("g-")
      end)
      assert.equals(before, repo:read("c"))
    end)
  end

  it("says where a key works on a section it does nothing in", function()
    letters("default")
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    open(repo)
    goto_line("^M a")
    H.feed("ct")
    H.feed("cb")
    local msgs = vim.tbl_map(function(m)
      return m.msg
    end, log)
    assert.truthy(vim.tbl_contains(msgs, "ct: works on Unmerged files"))
    assert.truthy(vim.tbl_contains(msgs, "cb: works on Unmerged files"))
    assert.equals("A\n", repo:read("a"))
    assert.equals("", vim.fn.getcmdline())
  end)

  it("co checks out an unpushed commit", function()
    letters("default")
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:git("checkout", "-q", "-b", "up")
    repo:git("checkout", "-q", "main")
    repo:git("branch", "-q", "--set-upstream-to=up")
    repo:commit("second", { ["b"] = "b\n" })
    local buf = open(repo)
    goto_line("second$")
    after(buf, function()
      H.feed("co")
    end)
    assert.truthy(vim.trim(repo:git("status", "--short", "--branch")):match("HEAD"))
  end)

  it("keeps 2X/3X in both presets, and coo/cb<Space> in upstream", function()
    for _, preset in ipairs({ "default", "upstream" }) do
      H.reset_ui()
      letters(preset)
      local repo = conflicted()
      local buf = open(repo)
      goto_line("^U c")
      after(buf, function()
        H.feed("3X")
      end)
      assert.equals("1\nT1\n2\n3\n4\n5\nT2\n6\n", repo:read("c"))
    end
    local maps = config.get().maps.summary
    assert.equals("checkout", maps.coo)
    assert.equals("branch_prompt", maps["cb<Space>"])
    assert.equals(
      "(dv: 3-way diff) (2X: ours) (3X: theirs) (s: resolved)",
      summary.hint_keys().Unmerged
    )
  end)
end)
