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
package.path = root .. "/tests/?.lua;" .. package.path

-- Tests run without a live editor client: make sure we never inherit one.
vim.env.GIT_EDITOR = nil
vim.env.GIT_SEQUENCE_EDITOR = nil

vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime! plugin/fugitive.lua")
