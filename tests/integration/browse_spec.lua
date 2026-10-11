local H = require("helpers")
local B = require("fixtures.browse_cases")

local function fixture()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local f = assert(io.open(root .. "/fixtures/browse_upstream.json"))
  local data = vim.json.decode(f:read("*a"))
  f:close()
  return data
end

describe(":GBrowse", function()
  before_each(function()
    H.reset_ui()
  end)

  it("passes Vimscript handlers exactly upstream's dict (captured fixture)", function()
    local expected = fixture()
    local repo = B.setup()
    local ours = B.normalize(B.ours(repo.root), repo.root)
    for _, c in ipairs(B.cases) do
      assert.same(expected[c[1]], ours[c[1]], c[1])
    end
  end)

  it("gives every handler its own copy and takes the first URL", function()
    local repo = B.setup()
    vim.cmd([[
      function! FugitiveTestMutate(opts) abort
        let a:opts.path = 'mutated'
        return 'not a url'
      endfunction
      function! FugitiveTestUrl(opts) abort
        return 'https://example.com/' . a:opts.path
      endfunction
      let g:fugitive_browse_handlers = [function('FugitiveTestMutate'), function('FugitiveTestUrl')]
    ]])
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit " .. vim.fn.fnameescape(repo:path("dir/other.txt")))
    local log, restore = H.capture_notify()
    vim.cmd("GBrowse!")
    restore()
    vim.g.fugitive_browse_handlers = nil
    assert.equals("https://example.com/dir/other.txt", vim.fn.getreg('"'))
    assert.truthy(log[#log].msg:match("example.com"))
  end)

  it("builds URLs with the built-in providers and yanks with !", function()
    local repo = B.setup()
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit " .. vim.fn.fnameescape(repo:path("dir/other.txt")))
    local orig_open = vim.ui.open
    local opened
    vim.ui.open = function(url)
      opened = url
    end
    local log, restore = H.capture_notify()
    vim.cmd("GBrowse")
    vim.cmd("1GBrowse!")
    restore()
    vim.ui.open = orig_open
    assert.equals("https://github.com/user/repo/blob/main/dir/other.txt", opened)
    -- a range pins the URL to a commit
    assert.equals("https://github.com/user/repo/blob/" .. repo:rev("HEAD") .. "/dir/other.txt#L1", vim.fn.getreg('"'))
    local _ = log
  end)

  it("supports custom hosts and providers through setup()", function()
    local repo = B.setup()
    repo:git("remote", "set-url", "origin", "git@git.corp:team/proj.git")
    require("fugitive").setup({ browse = { hosts = { ["git.corp"] = "gitlab" } } })
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit " .. vim.fn.fnameescape(repo:path("dir/other.txt")))
    local log, restore = H.capture_notify()
    vim.cmd("GBrowse!")
    assert.equals("https://git.corp/team/proj/-/blob/main/dir/other.txt", vim.fn.getreg('"'))
    require("fugitive").setup({
      browse = {
        hosts = { ["git.corp"] = "mine" },
        providers = {
          mine = function(o)
            return o.base .. "/view/" .. o.commit .. "/" .. o.path
          end,
        },
      },
    })
    vim.cmd("GBrowse!")
    restore()
    require("fugitive").setup({})
    assert.equals("https://git.corp/team/proj/view/main/dir/other.txt", vim.fn.getreg('"'))
    local _ = log
  end)

  it("reports a missing handler", function()
    local repo = B.setup()
    repo:git("remote", "set-url", "origin", "https://unknown.example/x.git")
    vim.cmd("cd " .. repo.root)
    vim.cmd("edit " .. vim.fn.fnameescape(repo:path("dir/other.txt")))
    local log, restore = H.capture_notify()
    vim.cmd("GBrowse")
    restore()
    assert.truthy(log[#log].msg:match("no GBrowse handler installed for 'https://unknown.example/x.git'"))
  end)
end)

describe("browse providers", function()
  local providers = require("fugitive.integrations.browse")

  it("parses remote URLs", function()
    assert.same({ host = "github.com", path = "u/r", scheme = "https" }, providers.parse_remote("https://github.com/u/r.git"))
    assert.same({ host = "github.com", path = "u/r", scheme = "ssh" }, providers.parse_remote("git@github.com:u/r.git"))
    assert.same({ host = "gitlab.example.com", path = "g/s/r", scheme = "ssh" }, providers.parse_remote("ssh://git@gitlab.example.com:2222/g/s/r.git"))
    assert.same({ host = "git.sr.ht", path = "~u/r", scheme = "https" }, providers.parse_remote("https://git.sr.ht/~u/r"))
  end)

  local function url(remote, o)
    return providers.url(vim.tbl_extend("force", { remote = remote, commit = "abc", path = "f.txt", type = "blob", line1 = 0, line2 = 0 }, o or {}))
  end

  it("builds provider URLs", function()
    assert.equals("https://github.com/u/r/blob/abc/f.txt#L1-L2", url("git@github.com:u/r.git", { line1 = 1, line2 = 2 }))
    assert.equals("https://github.com/u/r/commit/abc", url("git@github.com:u/r.git", { type = "commit", path = "" }))
    assert.equals("https://github.com/u/r/tree/abc/d", url("git@github.com:u/r.git", { type = "tree", path = "d/" }))
    assert.equals("https://github.com/u/r", url("git@github.com:u/r.git", { type = "", path = ".git/index" }))
    assert.equals("https://github.com/u/r/releases/tag/v1", url("git@github.com:u/r.git", { type = "", path = ".git/refs/tags/v1" }))
    assert.equals("https://gitlab.com/u/r/-/blob/abc/f.txt#L3", url("https://gitlab.com/u/r", { line1 = 3, line2 = 3 }))
    assert.equals("https://bitbucket.org/u/r/src/abc/f.txt#lines-1:2", url("https://bitbucket.org/u/r", { line1 = 1, line2 = 2 }))
    assert.equals("https://codeberg.org/u/r/src/branch/abc/f.txt", url("https://codeberg.org/u/r.git"))
    assert.equals("https://git.sr.ht/~u/r/tree/abc/item/f.txt#L1-2", url("https://git.sr.ht/~u/r", { line1 = 1, line2 = 2 }))
    assert.is_nil(url("https://unknown.example/u/r"))
  end)
end)
