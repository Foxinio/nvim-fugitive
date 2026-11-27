local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")

local function open(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0 and not summary.state(buf).running
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

describe("summary items", function()
  before_each(function()
    H.reset_ui()
    require("nvim-fugitive.watch").enable(false)
  end)
  after_each(function()
    require("nvim-fugitive.watch").enable(true)
  end)

  it("keep the cursor on its hunk when another file is staged", function()
    local lines = {}
    for n = 1, 20 do
      lines[n] = tostring(n)
    end
    local repo = H.repo({ files = { ["a"] = table.concat(lines, "\n") .. "\n", ["b"] = "b\n" } })
    lines[2], lines[16] = "X", "Y"
    repo:write("a", table.concat(lines, "\n") .. "\n")
    repo:write("b", "B\n")
    local buf = open(repo)
    local st = summary.state(buf)
    vim.api.nvim_win_set_cursor(0, { assert(H.find_line("a$")), 0 })
    after(buf, function()
      H.feed("=")
    end)
    local hunk = assert(H.find_line("^@@ %-13"))
    vim.api.nvim_win_set_cursor(0, { hunk + 1, 0 })
    local before = st.info[hunk + 1]
    local text = vim.api.nvim_get_current_line()
    -- stage b with a command, the cursor staying in a's diff
    after(buf, function()
      repo:git("add", "b")
      summary.refresh(buf)
    end)
    local now = st.info[vim.fn.line(".")]
    assert.equals(text, vim.api.nvim_get_current_line())
    assert.equals("hunk", now.item.kind)
    assert.equals(before.hunk_index, now.hunk_index)
  end)
end)
