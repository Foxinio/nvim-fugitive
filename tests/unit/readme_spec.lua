-- The README's configuration must stay true: the options block matches the
-- defaults, and every setup() recipe is valid.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local config = require("nvim-fugitive.config")

local function readme()
  return table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
end

---The table passed to a `require("nvim-fugitive").setup(...)` block.
local function setup_arg(block)
  local body = block:match('^require%("nvim%-fugitive"%)%.setup%((.*)%)%s*$')
  assert(body, "block is not a setup() call:\n" .. block)
  return assert(loadstring("return " .. body))()
end

describe("README", function()
  it("documents every option's default (the key maps live in :help and g?)", function()
    local block = readme():match("<summary><b>All options and their defaults</b>.-```lua\n(.-)```")
    assert(block, "options block not found")
    local documented = setup_arg(block)
    assert.is_nil(documented.maps, "the key maps are documented in :help, not the README")
    local defaults = vim.deepcopy(config.defaults)
    defaults.maps = nil
    assert.same(defaults, documented)
  end)

  it("has only valid setup() recipes", function()
    local n = 0
    for block in readme():gmatch("```lua\n(.-)```") do
      if block:match('^require%("nvim%-fugitive"%)%.setup%(') then
        n = n + 1
        local ok, err = pcall(config.merge, setup_arg(block))
        assert(ok, tostring(err) .. "\n" .. block)
      end
    end
    assert.truthy(n >= 7, "expected the recipes and the options block, found " .. n)
  end)
end)
