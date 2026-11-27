local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")

local function open(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) and summary.state(buf).tick > 0 and not summary.state(buf).running
  end)
  return buf
end

local function after(buf, fn)
  local st = summary.state(buf)
  H.wait(function()
    return not st.running
  end, "summary idle")
  local tick = st.tick
  fn()
  H.wait(function()
    return st.tick > tick and not st.running
  end, "refresh")
end

---A clone whose upstream (origin) and push remote (fork) are both behind
---its one local commit, so the commit is listed in two Unpushed sections.
local function two_unpushed()
  local origin = H.repo({ files = { ["f"] = "1\n" } })
  local fork = H.clone(origin)
  local clone = H.clone(origin)
  clone:git("remote", "add", "fork", fork.root)
  clone:git("fetch", "-q", "fork")
  clone:git("config", "remote.pushDefault", "fork")
  clone:commit("local work", { ["g"] = "g\n" })
  return clone
end

---The lines of each section, by heading.
local function sections(buf)
  local out, cur = {}, nil
  for _, l in ipairs(H.lines(buf)) do
    if l:match("%(%d+%)$") then
      cur = l
      out[cur] = {}
    elseif l == "" then
      cur = nil
    elseif cur then
      table.insert(out[cur], l)
    end
  end
  return out
end

describe("summary sections of the same kind", function()
  before_each(function()
    H.reset_ui()
  end)

  it("are told apart: = opens a commit in one Unpushed section only", function()
    local repo = two_unpushed()
    local buf = open(repo)
    local heads = vim.tbl_filter(function(l)
      return l:match("^Unpushed to ")
    end, H.lines(buf))
    assert.equals(2, #heads)
    -- the commit line in the second section
    local second = assert(H.find_line("^" .. vim.pesc(heads[2]) .. "$"))
    vim.api.nvim_win_set_cursor(0, { second + 1, 0 })
    after(buf, function()
      H.feed("=")
    end)
    local s = sections(buf)
    assert.equals(1, #s[heads[1]])
    assert.is_true(#s[heads[2]] > 1)
    -- after a refresh the cursor stays in the second section
    after(buf, function()
      summary.refresh(buf)
    end)
    assert.equals(
      summary.state(buf).info[second].section_id,
      summary.state(buf).info[vim.fn.line(".")].section_id
    )
  end)

  it("gp goes on to the next Unpushed section", function()
    local repo = two_unpushed()
    local buf = open(repo)
    local st = summary.state(buf)
    H.feed("gp")
    local first = st.info[vim.fn.line(".")].section_id
    H.feed("gp")
    local second = st.info[vim.fn.line(".")].section_id
    assert.truthy(first:match("^Unpushed:"))
    assert.truthy(second:match("^Unpushed:"))
    assert.are_not.equal(first, second)
  end)
end)
