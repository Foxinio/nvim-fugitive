local H = require("helpers")
local object = require("nvim-fugitive.object")

local function wait_qf(get)
  H.wait(function()
    return #get() > 0
  end, "list filled")
  return get()
end

describe(":Gclog / :Gllog", function()
  local repo, c1, c2, c3
  before_each(function()
    H.reset_ui()
    vim.fn.setqflist({}, "r")
    local lines = {}
    for i = 1, 10 do
      lines[i] = "l" .. i
    end
    repo = H.repo({ files = { ["f"] = table.concat(lines, "\n") .. "\n", ["g"] = "g\n" } })
    c1 = repo:rev("HEAD")
    lines[5] = "FIVE"
    c2 = repo:commit("change five", { ["f"] = table.concat(lines, "\n") .. "\n" })
    c3 = repo:commit("touch g", { ["g"] = "G\n" })
    vim.cmd("cd " .. repo.root)
  end)

  it("loads commits into quickfix and jumps to the first", function()
    vim.cmd("Gclog")
    local qf = wait_qf(vim.fn.getqflist)
    assert.equals(3, #qf)
    assert.equals("touch g", qf[1].text)
    assert.equals(c3:sub(1, 7), qf[1].module)
    assert.equals(object.format(repo.root .. "/.git", c3), vim.api.nvim_buf_get_name(0))
  end)

  it("with a path lists that file at each commit; ! does not jump", function()
    vim.cmd("enew")
    vim.cmd("Gclog! -- f")
    local qf = wait_qf(vim.fn.getqflist)
    assert.equals(2, #qf)
    assert.equals(
      object.format(repo.root .. "/.git", c2, "f"),
      vim.api.nvim_buf_get_name(qf[1].bufnr)
    )
    assert.equals("", vim.api.nvim_buf_get_name(0))
  end)

  it(":{range}Gclog follows the lines with log -L, on each hunk", function()
    vim.cmd("edit f")
    vim.cmd("5,5Gclog")
    local qf = wait_qf(vim.fn.getqflist)
    assert.equals(2, #qf)
    assert.equals(
      object.format(repo.root .. "/.git", c2, "f"),
      vim.api.nvim_buf_get_name(qf[1].bufnr)
    )
    assert.equals(5, qf[1].lnum)
    assert.equals(
      object.format(repo.root .. "/.git", c1, "f"),
      vim.api.nvim_buf_get_name(qf[2].bufnr)
    )
  end)

  it(":0Gclog is the whole file's history; :Gllog uses the location list", function()
    vim.cmd("edit f")
    vim.cmd("0Gllog!")
    local ll = wait_qf(function()
      return vim.fn.getloclist(0)
    end)
    assert.equals(2, #ll)
    assert.equals(0, #vim.fn.getqflist())
  end)
end)
