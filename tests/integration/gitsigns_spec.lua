-- gitsigns.nvim on fugitive:// buffers (an optional dependency): `make deps`
-- clones it into .deps, like telescope
local H = require("helpers")
local object = require("nvim-fugitive.object")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local deps = vim.env.FUGITIVE_TEST_DEPS or (root .. "/.deps")
local has_gitsigns = vim.uv.fs_stat(deps .. "/gitsigns.nvim") ~= nil
if has_gitsigns then
  vim.opt.runtimepath:append(deps .. "/gitsigns.nvim")
  require("gitsigns").setup({})
end

---Lines with a gitsigns sign of `group`.
local function signed(buf, group)
  local lines = {}
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if name:match("gitsigns") then
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if m[4].sign_hl_group == group then
          table.insert(lines, m[2] + 1)
        end
      end
    end
  end
  table.sort(lines)
  return lines
end

describe("gitsigns on fugitive:// buffers", function()
  before_each(function()
    H.reset_ui()
  end)

  it("shows a commit's changes in its blob and the staged ones in the index", function()
    if not has_gitsigns then
      pending("gitsigns.nvim is not in " .. deps .. " (make deps)")
      return
    end
    local lines = { "a", "b", "c", "d", "e", "f", "g", "h" }
    local repo = H.repo({ files = { ["f"] = table.concat(lines, "\n") .. "\n" } })
    lines[2] = "B"
    local sha = repo:commit("two", { ["f"] = table.concat(lines, "\n") .. "\n" })
    lines[7] = "G"
    repo:write("f", table.concat(lines, "\n") .. "\n")
    repo:git("add", "f")
    vim.cmd("cd " .. repo.root)
    local gd = repo.root .. "/.git"

    vim.cmd("edit " .. vim.fn.fnameescape(object.format(gd, sha, "f")))
    local blob = vim.api.nvim_get_current_buf()
    H.wait(function()
      return #signed(blob, "GitSignsStagedChange") > 0
    end, "signs in the commit's blob")
    assert.same({ 2 }, signed(blob, "GitSignsStagedChange"))

    vim.cmd("edit " .. vim.fn.fnameescape(object.format(gd, "0", "f")))
    local index = vim.api.nvim_get_current_buf()
    H.wait(function()
      return #signed(index, "GitSignsStagedChange") > 0
    end, "staged signs in the index")
    assert.same({ 7 }, signed(index, "GitSignsStagedChange"))
  end)
end)
