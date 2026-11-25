local H = require("helpers")
local summary = require("nvim-fugitive.buffers.summary")
local config = require("nvim-fugitive.config")

---The eol virtual text on each line, by line text.
local function eol_marks(buf)
  local ns = vim.api.nvim_get_namespaces().fugitive_summary
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local d = m[4]
    if d.virt_text and d.virt_text_pos == "eol" then
      local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
      out[line] = d.virt_text[1][1]
    end
  end
  return out
end

local function open(opts)
  config.set(opts or {})
  local repo = H.repo({ files = { ["a"] = "a\n", ["b"] = "b\n" } })
  repo:write("a", "A\n")
  repo:write("b", "B\n")
  repo:git("add", "b")
  repo:write("new", "n\n")
  vim.cmd("cd " .. repo.root)
  vim.cmd("Git")
  local buf = vim.api.nvim_get_current_buf()
  H.wait(function()
    return summary.state(buf) ~= nil and summary.state(buf).tick > 0
  end, "summary render")
  return buf
end

describe("summary title and hints", function()
  before_each(function()
    H.reset_ui()
  end)
  after_each(function()
    config.set({})
  end)

  it("shows the title above the first line, out of the cursor's reach", function()
    local buf = open()
    assert.truthy(H.lines(buf)[1]:match("^Head: "))
    assert.equals(1, vim.fn.winsaveview().topfill)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.feed("k")
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("puts the section's keys after its heading", function()
    local buf = open()
    local marks = eol_marks(buf)
    assert.equals("(s: stage) (gI: ignore) (X: delete)", marks["Untracked (1)"])
    assert.equals("(s: stage) (dv: diff) (X: discard)", marks["Unstaged (1)"])
    assert.equals("(u: unstage) (cc: commit) (ca: amend)", marks["Staged (1)"])
  end)

  it("covers every section, counts included", function()
    config.set({})
    local k = summary.hint_keys()
    assert.equals(
      "(dv: 3-way diff) (co: ours) (ct: theirs) (cb: both) (c0: neither) (s: resolved)",
      k.Unmerged
    )
    assert.equals("(cu: init) (cU: recursive)", k.Uninitialized)
    assert.equals("(rr: continue) (rs: skip) (ra: abort)", k.Rebasing)
    assert.equals(k.Rebasing, k.Sequencing)
    assert.equals("(bg: good) (bb: bad) (br: reset)", k.Bisecting)
    assert.equals("(co: checkout) (ri: rebase) (rw: reword) (rd: drop)", k.Unpushed)
    assert.equals("(co: checkout) (ru: rebase)", k.Unpulled)
    assert.equals("(czp: pop) (cza: apply) (czv: view)", k.Stash)
    for _, text in pairs(k) do
      assert.is_nil(text:find("(=", 1, true))
      assert.is_nil(text:find("(-", 1, true))
      assert.is_nil(text:find("<CR>", 1, true))
    end
  end)

  it("shows remapped keys, and none when turned off", function()
    local buf = open({ maps = { summary = { X = false, D = "discard" } } })
    assert.equals("(s: stage) (dv: diff) (D: discard)", eol_marks(buf)["Unstaged (1)"])
    H.reset_ui()
    buf = open({ summary = { hints = false } })
    assert.is_nil(eol_marks(buf)["Unstaged (1)"])
  end)
end)
