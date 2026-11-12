local H = require("helpers")

---Run :checkhealth nvim-fugitive and return its text.
local function health()
  vim.cmd("checkhealth nvim-fugitive")
  local buf = vim.api.nvim_get_current_buf()
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  -- newer Neovim fills the report asynchronously
  H.wait(function()
    return text():find("Integrations (all optional)", 1, true) ~= nil
  end, "the health report")
  local out = text()
  vim.cmd("bwipeout!")
  return out
end

local function has(text, plain)
  return text:find(plain, 1, true) ~= nil
end

describe(":checkhealth nvim-fugitive", function()
  before_each(function()
    H.reset_ui()
  end)
  after_each(function()
    require("nvim-fugitive").setup({})
  end)

  it("checks Neovim and git", function()
    local text = health()
    assert.truthy(text:match("OK Neovim %d+%.%d+"))
    assert.truthy(text:match("OK git %d+%.%d+"))
    assert.is_false(has(text, "No healthcheck found"))
  end)

  it("lists the options changed from the defaults, and a failed setup", function()
    require("nvim-fugitive").setup({
      notify = { max_lines = 5 },
      maps = { summary = { X = false } },
      args = { commit = { "--signoff" } },
    })
    local text = health()
    assert.truthy(has(text, "setup() was called"))
    assert.truthy(has(text, "notify.max_lines = 5"))
    assert.truthy(has(text, "maps.summary.X = false"))
    assert.truthy(has(text, 'args = { commit = { "--signoff" } }'))

    assert.is_false(pcall(require("nvim-fugitive").setup, { notify = { max_lines = "ten" } }))
    text = health()
    assert.truthy(text:match("ERROR the last setup%(%) failed: .*max_lines"))
  end)

  it("shows the repository and warns about git settings that bite", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:git("config", "--unset", "user.email")
    repo:git("config", "alias.log", "log --oneline")
    repo:git("config", "alias.lg", "log --graph")
    vim.cmd("cd " .. repo.root)
    local text = health()
    assert.truthy(has(text, "work tree: " .. vim.uv.fs_realpath(repo.root)))
    assert.truthy(has(text, "HEAD: main"))
    assert.truthy(has(text, "OK user.name = Test"))
    assert.truthy(text:match("WARNING user%.email is not set"))
    assert.truthy(text:match("WARNING alias%.log = log %-%-oneline %(%.git/config%) is ignored"))
    assert.is_false(has(text, "alias.lg = "))
    assert.truthy(has(text, "2 git aliases"))
  end)

  it("outside a repository, says so without an error", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.cmd("cd " .. dir)
    local text = health()
    assert.truthy(has(text, "not in a git repository"))
    assert.is_false(has(text, "ERROR"))
  end)

  it("reports each optional integration", function()
    local text = health()
    for _, name in ipairs({
      "telescope.nvim",
      "overseer.nvim",
      "gitsigns.nvim",
      "term-color-parser.nvim",
    }) do
      assert.truthy(has(text, name .. ":"), name)
    end
  end)
end)
