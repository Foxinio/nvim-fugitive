local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")
local config = require("nvim-fugitive.config")
local exec = require("nvim-fugitive.git.exec")

local function open(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0
  end)
  return buf
end

---Record the git commands the summary runs while `fn` runs.
local function recorded(fn)
  local cmds = {}
  exec.set_runner(function(cmd, opts, on_exit)
    table.insert(cmds, cmd)
    return vim.system(cmd, opts, on_exit)
  end)
  local ok, err = pcall(fn)
  exec.set_runner(nil)
  assert(ok, err)
  return cmds
end

local function ran(cmds, sub)
  for _, c in ipairs(cmds) do
    for k, w in ipairs(c) do
      if w == sub then
        return vim.list_slice(c, k)
      end
    end
  end
end

describe("summary actions take git arguments as lists", function()
  local log, restore
  before_each(function()
    H.reset_ui()
    log, restore = H.capture_notify()
  end)
  after_each(function()
    restore()
    config.set({})
  end)

  it("crc off a commit warns and runs no revert", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    open(repo)
    vim.api.nvim_win_set_cursor(0, { assert(H.find_line("a$")), 0 })
    local cmds = recorded(function()
      H.feed("crc")
      vim.wait(200)
    end)
    assert.is_nil(ran(cmds, "revert"))
    assert.truthy(vim.iter(log):any(function(m)
      return m.msg == "no commit under the cursor"
    end))
  end)

  it("cm<CR> (upstream preset) calls :Git merge directly, not through the command line", function()
    config.set({ maps = { preset = "upstream" } })
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    open(repo)
    local git = require("nvim-fugitive.cmd.git")
    local orig, got = git.run, nil
    git.run = function(args)
      got = args
    end
    local hist = vim.fn.histnr(":")
    H.feed("cm<CR>")
    git.run = orig
    assert.same({ "merge" }, got)
    assert.equals(hist, vim.fn.histnr(":"))
  end)
end)
