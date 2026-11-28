local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")
local log = require("nvim-fugitive.log")
local output = require("nvim-fugitive.ui.output")
local config = require("nvim-fugitive.config")

local function open(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0 and not summary.state(buf).running
  end)
  return buf
end

---Entries added after `n` entries, with `sub` among their words.
local function since(n, sub)
  local out = {}
  for k = n + 1, #log._ring do
    local e = log._ring[k]
    if vim.tbl_contains(e.cmd, sub) then
      table.insert(out, e)
    end
  end
  return out
end

describe(":FugitiveLog", function()
  before_each(function()
    H.reset_ui()
    log._ring = {}
  end)
  after_each(function()
    config.set({})
  end)

  it("marks what your keys start as user, the refresh after it as background", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    local buf = open(repo)
    local st = summary.state(buf)
    local n = #log._ring
    vim.api.nvim_win_set_cursor(0, { assert(H.find_line("a$")), 0 })
    local tick = st.tick
    H.feed("s")
    H.wait(function()
      return st.tick > tick and not st.running
    end, "refresh")
    local adds = since(n, "add")
    assert.equals(1, #adds)
    assert.equals("user", adds[1].kind)
    assert.equals(0, adds[1].code)
    assert.truthy(adds[1].ms)
    local status = since(n, "status")
    assert.is_true(#status > 0)
    assert.equals("background", status[#status].kind)
  end)

  it("counts :Git as user, and records failures", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
    local n = #log._ring
    vim.cmd("Git rev-parse --verify nosuchref")
    H.wait(function()
      local e = since(n, "rev-parse")[1]
      return e and e.code ~= nil
    end, "rev-parse done")
    local e = since(n, "rev-parse")[1]
    assert.equals("user", e.kind)
    assert.is_true(e.code ~= 0)
    assert.truthy(log.format(e):match("✗ " .. e.code))
  end)

  it("keeps log.size entries", function()
    config.set({ log = { size = 3 } })
    local exec = require("nvim-fugitive.git.exec")
    for _ = 1, 5 do
      exec.sync({ "--version" })
    end
    assert.equals(3, #log._ring)
  end)

  it("shows your commands, and the background ones after a", function()
    local exec = require("nvim-fugitive.git.exec")
    exec.sync({ "--version" })
    log.user(exec.sync, { "--help" })
    local buf = log.show()
    local function body()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 1, -1, false), "\n")
    end
    assert.truthy(body():match("%-%-help"))
    assert.is_nil(body():match("%-%-version"))
    H.feed("a")
    assert.truthy(body():match("%-%-version"))
    log.user(exec.sync, { "--exec-path" })
    H.wait(function()
      return body():match("%-%-exec%-path") ~= nil
    end, "new line")
  end)
end)

describe("kept output", function()
  before_each(function()
    output._ring = {}
  end)
  after_each(function()
    config.set({})
  end)

  local function cmd(stdout, stderr)
    output.record({
      cmd = { "git" },
      code = stderr ~= "" and 1 or 0,
      stdout = stdout,
      stderr = stderr,
    })
  end

  it("keeps the latest command's output, and 20 commands' stderr", function()
    for k = 1, 21 do
      cmd("out" .. k, "err" .. k)
    end
    cmd("last", "")
    assert.equals("last", output.get(1).stdout)
    assert.equals("", output.get(2).stdout) -- stderr only
    assert.equals("err21", output.get(2).stderr)
    assert.equals(21, #output._ring) -- err1 dropped
    assert.equals("err2", output._ring[1].stderr)
  end)

  it("treats ring_size 0 as 1, and keeps more when asked", function()
    config.set({ output = { ring_size = 0 } })
    cmd("a", "")
    cmd("b", "")
    assert.equals(1, #output._ring)
    config.set({ output = { ring_size = 3 } })
    cmd("c", "")
    cmd("d", "")
    assert.same(
      { "b", "c", "d" },
      vim.tbl_map(function(e)
        return e.stdout
      end, output._ring)
    )
  end)
end)
