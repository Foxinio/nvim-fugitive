-- Summary buffer (filetype=fugitive). Maps are set by the summary module;
-- this only sets presentation options users may override in after/.
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1

vim.bo.textwidth = 0
vim.opt_local.list = false
vim.opt_local.spell = false
vim.b.undo_ftplugin = "setl tw< list< spell<"
