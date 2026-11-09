-- git's colours through term-color-parser.nvim (an optional dependency):
-- `make deps` clones it into .deps, like telescope
local H = require("helpers")
local output = require("nvim-fugitive.ui.output")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local deps = vim.env.FUGITIVE_TEST_DEPS or (root .. "/.deps")
local has_plugin = vim.uv.fs_stat(deps .. "/term-color-parser.nvim") ~= nil
if has_plugin then
  vim.opt.runtimepath:append(deps .. "/term-color-parser.nvim")
end

local function wait_done(before)
  H.wait(function()
    local e = output.get(1)
    return e and e ~= before and not e.running
  end, "command completion", 10000)
  return output.get(1)
end

local function float_wins()
  return vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative ~= ""
  end, vim.api.nvim_list_wins())
end

describe("git colours", function()
  before_each(function()
    H.reset_ui()
  end)

  it("the float and :FugitiveOutput show git's colours, as in a terminal", function()
    if not has_plugin then
      pending("term-color-parser.nvim is not in " .. deps .. " (make deps)")
      return
    elseif not require("nvim-fugitive.ui.ansi").available() then
      pending("term-color-parser.nvim in " .. deps .. " has no decoder(): update it")
      return
    end
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    -- the user's setup: graph = graph1, graph1 = log --graph with a coloured format
    repo:git(
      "config",
      "alias.graph1",
      "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(auto)%d%C(reset)' --all"
    )
    repo:git("config", "alias.graph", "graph1")
    repo:git("config", "alias.lgs", "!git log --graph --oneline --all")
    vim.cmd("cd " .. repo.root)
    local ansi = require("ansi-colorize")
    local function run(cmd)
      local log, restore = H.capture_notify()
      local before = output.get(1)
      vim.cmd(cmd)
      wait_done(before)
      restore()
      local buf = vim.api.nvim_get_current_buf()
      local marks = vim.api.nvim_buf_get_extmarks(buf, ansi.ns, 0, -1, { details = true })
      return buf, marks, log
    end

    for _, name in ipairs({ "graph", "graph1", "lgs" }) do
      local buf, marks, log = run("Git " .. name)
      assert.equals(1, #float_wins(), name)
      assert.equals("git", vim.bo[buf].filetype, name)
      assert.same({}, log, name)
      local text = table.concat(H.lines(buf), "\n")
      assert.is_nil(text:find("\27", 1, true), name)
      assert.truthy(H.lines(buf)[1]:match("^%* %x+ "), name)
      assert.truthy(#marks > 0, name)
      H.reset_ui()
    end
    -- the hash is bold blue, as git prints it in a terminal
    local buf, marks = run("Git graph")
    local hash = H.lines(buf)[1]:match("^%* (%x+)")
    local first = marks[1]
    assert.equals(0, first[2])
    assert.equals(2, first[3])
    assert.equals(2 + #hash, first[4].end_col)
    local group = vim.api.nvim_get_hl(0, { name = first[4].hl_group })
    assert.is_true(group.bold)
    assert.equals(4, group.ctermfg)
    H.reset_ui()

    -- :FugitiveOutput keeps them
    vim.cmd("FugitiveOutput")
    buf = vim.api.nvim_get_current_buf()
    assert.is_nil(table.concat(H.lines(buf), "\n"):find("\27", 1, true))
    assert.truthy(#vim.api.nvim_buf_get_extmarks(buf, ansi.ns, 0, -1, {}) > 0)
    H.reset_ui()

    -- no colours where a terminal would show none
    for _, cfg in ipairs({
      { "color.ui", "false" },
      { "color.pager", "false" },
      { "color.diff", "never" },
    }) do
      repo:git("config", cfg[1], cfg[2])
      require("nvim-fugitive.git.repo").invalidate(repo.root .. "/.git")
      _, marks = run("Git log --oneline")
      assert.same({}, marks, cfg[1])
      repo:git("config", "--unset", cfg[1])
      require("nvim-fugitive.git.repo").invalidate(repo.root .. "/.git")
      H.reset_ui()
    end
    _, marks = run("Git log --oneline")
    assert.truthy(#marks > 0)
    H.reset_ui()

    -- an explicit --color reaching a notification: no escapes in it
    local _, _, log = run("Git --no-pager log --color --oneline -1")
    assert.equals(1, #log)
    assert.is_nil(log[1].msg:find("\27", 1, true))
    assert.truthy(log[1].msg:match("%x+ initial"))
  end)
end)
