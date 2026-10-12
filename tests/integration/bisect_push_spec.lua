local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")
local output = require("nvim-fugitive.ui.output")

local function open(repo)
  vim.cmd("cd " .. repo.root)
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0
  end)
  return buf
end

local function run_and_wait(keys)
  local before = output.get(1)
  H.feed(keys)
  H.wait(function()
    local e = output.get(1)
    return e and e ~= before and not e.running
  end, keys, 10000)
end

describe("bisect helpers", function()
  local log, restore
  before_each(function()
    H.reset_ui()
    log, restore = H.capture_notify()
  end)
  after_each(function()
    restore()
  end)

  it("shows the bisect state and bg/bb/br drive it", function()
    local repo = H.repo({ files = { ["n"] = "0\n" } })
    for i = 1, 6 do
      repo:commit("c" .. i, { ["n"] = i .. "\n" })
    end
    repo:git("bisect", "start")
    repo:git("bisect", "bad")
    repo:git("bisect", "good", "HEAD~6")
    local buf = open(repo)
    assert.truthy(H.find_line("^Bisect: %d+ left to test$", buf))
    assert.truthy(H.find_line("^Bisecting %(2%)$", buf))
    assert.truthy(H.find_line("^good %x+ initial$", buf))
    local st = summary.state(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local tick = st.tick
    run_and_wait("bg")
    H.wait(function()
      return st.tick > tick and H.find_line("^Bisecting %(3%)$", buf) ~= nil
    end, "bisect refresh")
    run_and_wait("br")
    H.wait(function()
      return H.find_line("^Bisect", buf) == nil
    end, "bisect reset")
    assert.is_nil(vim.uv.fs_stat(repo.root .. "/.git/BISECT_LOG"))
  end)
end)

describe("push errors", function()
  local overseer = require("nvim-fugitive.integrations.overseer")

  it("parses rejections, errors and hook messages", function()
    local repo = H.repo({ files = { ["src/a.c"] = "x\n" } })
    local r = require("nvim-fugitive.git.repo").find(repo.root)
    local items = overseer.parse_errors(
      r,
      table.concat({
        "To example.com:r.git",
        " ! [rejected]        main -> main (fetch first)",
        "error: failed to push some refs to 'example.com:r.git'",
        "remote: src/a.c:1: trailing whitespace",
        "hint: Updates were rejected",
      }, "\n")
    )
    assert.equals(3, #items)
    assert.equals("[rejected]        main -> main (fetch first)", items[1].text)
    assert.equals(repo:path("src/a.c"), items[3].filename)
    assert.equals(1, items[3].lnum)
  end)

  it("a rejected push fills quickfix (fallback runner)", function()
    H.reset_ui()
    package.preload.overseer = function()
      error("not installed")
    end
    local origin = H.repo({ files = { ["f"] = "1\n" } })
    origin:git("config", "receive.denyCurrentBranch", "ignore")
    local clone = H.clone(origin)
    origin:commit("upstream", { ["g"] = "g\n" })
    clone:commit("local", { ["h"] = "h\n" })
    vim.fn.setqflist({}, "r")
    local log, restore = H.capture_notify()
    vim.cmd("cd " .. clone.root)
    vim.cmd("Git push origin main")
    H.wait(function()
      return #vim.fn.getqflist() > 0
    end, "quickfix", 10000)
    restore()
    package.preload.overseer = nil
    assert.truthy(vim.fn.getqflist()[1].text:match("rejected"))
    assert.truthy(vim.iter(log):any(function(m)
      return m.msg:match(":copen")
    end))
  end)
end)
