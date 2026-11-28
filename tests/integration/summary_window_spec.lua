local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")

describe("summary window", function()
  local sb, sr
  before_each(function()
    H.reset_ui()
    sb, sr = vim.o.splitbelow, vim.o.splitright
  end)
  after_each(function()
    vim.o.splitbelow, vim.o.splitright = sb, sr
    require("nvim-fugitive.config").set({})
  end)

  local function open()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
    vim.cmd("edit a")
    vim.cmd("vsplit")
    vim.cmd("Git")
    return vim.api.nvim_get_current_win()
  end

  it("spans the tab across the top, like upstream, from a vertical split", function()
    vim.o.splitbelow = false
    local win = open()
    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(win))
    assert.same({ 0, 0 }, vim.api.nvim_win_get_position(win))
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("goes across the bottom with 'splitbelow'", function()
    vim.o.splitbelow = true
    local win = open()
    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(win))
    assert.is_true(vim.api.nvim_win_get_position(win)[1] > 0)
  end)

  it("spans the height to the left with window = vsplit, and keeps given positions", function()
    vim.o.splitright = false
    require("nvim-fugitive.config").set({ summary = { window = "vsplit" } })
    local win = open()
    assert.same({ 0, 0 }, vim.api.nvim_win_get_position(win))
    assert.equals("botright vertical", summary.edge("botright vertical"))
    assert.equals("topleft vertical", summary.edge("vertical"))
    assert.equals("tab", summary.edge("tab"))
  end)
end)
