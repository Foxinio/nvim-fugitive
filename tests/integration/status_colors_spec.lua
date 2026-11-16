local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")

local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

local function raw(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

---A colorscheme of our own: the groups the status colours come from.
local function scheme(colors)
  vim.cmd("highlight clear")
  -- ":highlight clear" brings back Neovim's own colours: start from none
  for _, name in ipairs({
    "Normal",
    "Added",
    "Changed",
    "Removed",
    "diffAdded",
    "diffChanged",
    "diffRemoved",
    "GitSignsAdd",
    "GitSignsChange",
    "GitSignsDelete",
    "DiagnosticWarn",
    "WarningMsg",
  }) do
    vim.api.nvim_set_hl(0, name, {})
  end
  for name, spec in pairs(colors) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
end

local function open_summary()
  local repo = H.repo({ files = { ["a"] = "a\n" } })
  repo:write("a", "A\n")
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) ~= nil and summary.state(buf).tick > 0
  end, "summary render")
  return buf
end

describe("status colours", function()
  local tgc
  before_each(function()
    H.reset_ui()
    tgc = vim.o.termguicolors
    vim.o.termguicolors = true
  end)
  after_each(function()
    vim.o.termguicolors = tgc
    vim.cmd("highlight clear")
    vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "default" })
  end)

  it("come from the colorscheme's diff colours, on its background", function()
    scheme({
      Normal = { fg = 0xdddddd, bg = 0x101010 },
      Added = { fg = 0x00aa00, ctermfg = 2 },
      Changed = { fg = 0x0000cc, ctermfg = 4 },
      Removed = { fg = 0xcc0000, ctermfg = 1 },
      DiagnosticWarn = { fg = 0xcccc00 },
      Comment = { fg = 0x777777 },
      diffAdded = { link = "Added" },
      diffChanged = { link = "Changed" },
      diffRemoved = { link = "Removed" },
    })
    open_summary()
    assert.same(
      { 0x00aa00, 0x101010 },
      { hl("FugitiveStatusAdded").bg, hl("FugitiveStatusAdded").fg }
    )
    assert.equals(0x0000cc, hl("FugitiveStatusModified").bg)
    assert.equals(0xcc0000, hl("FugitiveStatusDeleted").bg)
    assert.equals(0x0000cc, hl("FugitiveStatusRenamed").bg)
    assert.equals(0x0000cc, hl("FugitiveStatusTypechange").bg)
    assert.equals(0xcccc00, hl("FugitiveStatusUnmerged").bg)
    assert.equals(2, hl("FugitiveStatusAdded").ctermbg)
    -- untracked: grey text, no background
    assert.equals("Comment", raw("FugitiveStatusUntracked").link)
    assert.is_nil(hl("FugitiveStatusUntracked").bg)
  end)

  it("follow the inline diff's own groups first", function()
    scheme({
      Normal = { bg = 0x101010 },
      Added = { fg = 0x00aa00 },
      diffAdded = { fg = 0x33ff33 },
    })
    open_summary()
    assert.equals(0x33ff33, hl("FugitiveStatusAdded").bg)
  end)

  it("follow a colorscheme change, but keep the user's own colours", function()
    scheme({ Normal = { bg = 0x101010 }, Added = { fg = 0x00aa00 }, Removed = { fg = 0xcc0000 } })
    open_summary()
    assert.equals(0x00aa00, hl("FugitiveStatusAdded").bg)
    vim.api.nvim_set_hl(0, "FugitiveStatusDeleted", { bg = 0x123456 })
    -- a colorscheme that doesn't clear highlights first
    vim.api.nvim_set_hl(0, "Added", { fg = 0x22bb22 })
    vim.api.nvim_set_hl(0, "Removed", { fg = 0xdd1111 })
    vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "other" })
    assert.equals(0x22bb22, hl("FugitiveStatusAdded").bg)
    assert.equals(0x123456, hl("FugitiveStatusDeleted").bg)
    -- and one that does
    scheme({ Normal = { bg = 0x101010 }, Added = { fg = 0x44cc44 } })
    assert.equals(0x44cc44, hl("FugitiveStatusAdded").bg)
  end)

  it("pick black or white text without a Normal background", function()
    scheme({ Added = { fg = 0xeeeeaa }, Removed = { fg = 0x220000 } })
    open_summary()
    assert.equals(0x000000, hl("FugitiveStatusAdded").fg)
    assert.equals(0xffffff, hl("FugitiveStatusDeleted").fg)
  end)

  it("use the cterm colours without termguicolors", function()
    vim.o.termguicolors = false
    scheme({ Added = { ctermfg = 2 }, Removed = { ctermfg = 9 } })
    open_summary()
    assert.equals(2, hl("FugitiveStatusAdded").ctermbg)
    assert.equals(9, hl("FugitiveStatusDeleted").ctermbg)
    assert.truthy(hl("FugitiveStatusAdded").ctermfg)
  end)

  it("fall back to the Diff groups when the scheme has no colour", function()
    scheme({})
    open_summary()
    assert.equals("DiffAdd", raw("FugitiveStatusAdded").link)
    assert.equals("DiffDelete", raw("FugitiveStatusDeleted").link)
  end)
end)
