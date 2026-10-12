-- The README's "Default configuration" block must stay true.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function readme_defaults()
  local text = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
  local block = text:match("<summary><b>Default configuration</b>.-```lua\n(.-)```")
  assert(block, "default configuration block not found")
  local body = block:match('^require%("nvim%-fugitive"%)%.setup%((.*)%)%s*$')
  assert(body, "block is not a setup() call")
  return assert(loadstring("return " .. body))()
end

describe("README", function()
  it("documents exactly the default configuration", function()
    assert.same(require("nvim-fugitive.config").defaults, readme_defaults())
  end)
end)
