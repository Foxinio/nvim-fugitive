-- Minimal init for headless test runs: this plugin + plenary, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local deps = vim.env.FUGITIVE_TEST_DEPS or (root .. "/.deps")

-- keep Neovim's own lib dir (bundled treesitter parsers) like a real install
local libdir = vim.fn.fnamemodify(vim.v.progpath, ":p:h:h") .. "/lib/nvim"
vim.opt.runtimepath = { root, deps .. "/plenary.nvim", vim.env.VIMRUNTIME, libdir }
vim.opt.packpath = {}
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.more = false
package.path = root .. "/tests/?.lua;" .. root .. "/tests/?/init.lua;" .. package.path

-- Keep inherited Git paths, config, hooks and editors out of fixture repositories.
for name in pairs(vim.fn.environ()) do
  if name:match("^GIT_") then
    vim.env[name] = nil
  end
end
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_TEMPLATE_DIR = ""
-- never prompt for credentials or start helpers that talk to the desktop
vim.env.GIT_TERMINAL_PROMPT = "0"
vim.env.GIT_ASKPASS = "true"
vim.env.SSH_ASKPASS = "true"
vim.env.BROWSER = "true"

-- A private HOME/XDG tree: no user git config, credential store or pager.
local home = vim.fn.tempname() .. "-home"
vim.fn.mkdir(home .. "/config", "p")
vim.env.HOME = home
vim.env.XDG_CONFIG_HOME = home .. "/config"

-- URL assertions can replace this stub; no test should launch a real browser.
-- Every attempt is recorded so tests can assert on it.
_G.fugitive_test_opened = {}
vim.ui.open = function(url)
  table.insert(_G.fugitive_test_opened, url)
end

vim.cmd("runtime plugin/plenary.vim")
-- PlenaryBustedFile otherwise starts its child with the user's init.lua.
vim.api.nvim_create_user_command("PlenaryBustedFile", function(opts)
  require("plenary.test_harness").test_directory(opts.args, {
    minimal_init = root .. "/tests/minimal_init.lua",
    sequential = true,
    timeout = 60000,
  })
end, { nargs = 1, complete = "file", force = true })
vim.cmd("runtime! plugin/fugitive.lua")
