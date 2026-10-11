-- nvim-fugitive: commands and autocommands. Everything else loads lazily.
if vim.g.loaded_fugitive then
  return
end
vim.g.loaded_fugitive = 1

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("nvim-fugitive requires Neovim 0.11+", vim.log.levels.ERROR, { title = "Fugitive" })
  return
end

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts)
end

local function complete(kind)
  return function(arglead, cmdline, pos)
    return require("fugitive.cmd.complete")[kind](arglead, cmdline, pos)
  end
end

for _, name in ipairs({ "Git", "G" }) do
  cmd(name, function(c)
    require("fugitive.cmd.git").command(c)
  end, { nargs = "*", bang = true, range = -1, complete = complete("git"), desc = "Run a git command" })
end

cmd("FugitiveOutput", function(c)
  require("fugitive.ui.output").show(tonumber(c.args), c.mods)
end, { nargs = "?", desc = "Show the full output of a recent git command" })

cmd("FugitiveRestore", function(c)
  require("fugitive.discard").pick(c.args ~= "" and c.args or nil)
end, { nargs = "?", complete = complete("discarded"), desc = "Restore a discarded change" })

for name, layout in pairs({ Gdiffsplit = "auto", Gvdiffsplit = "vertical", Ghdiffsplit = "horizontal" }) do
  cmd(name, function(c)
    require("fugitive.buffers.diffsplit").command(c, layout)
  end, { nargs = "*", bang = true, complete = complete("object"), desc = "Diff against an object" })
end

cmd("Ggrep", function(c)
  require("fugitive.cmd.grep").command(c, false)
end, { nargs = "*", bang = true, complete = complete("git_grep"), desc = "git grep into a picker/quickfix" })
cmd("Glgrep", function(c)
  require("fugitive.cmd.grep").command(c, true)
end, { nargs = "*", bang = true, complete = complete("git_grep"), desc = "git grep into the location list" })

cmd("GMove", function(c)
  require("fugitive.cmd.move").move(c, false)
end, { nargs = 1, bang = true, complete = complete("path"), desc = "git mv the current file" })
cmd("GRename", function(c)
  require("fugitive.cmd.move").move(c, true)
end, { nargs = 1, bang = true, complete = complete("sibling"), desc = "git mv relative to the current file" })
cmd("GRemove", function(c)
  require("fugitive.cmd.move").remove(c, { delete_buffer = false })
end, { nargs = 0, bang = true, desc = "git rm the current file, keep the buffer" })
cmd("GDelete", function(c)
  require("fugitive.cmd.move").remove(c, { delete_buffer = true })
end, { nargs = 0, bang = true, desc = "git rm the current file and delete the buffer" })
cmd("GUnlink", function(c)
  require("fugitive.cmd.move").unlink(c)
end, { nargs = 0, bang = true, desc = "Alias of :GRemove" })

cmd("GBrowse", function(c)
  require("fugitive.cmd.browse").command(c)
end, { nargs = "?", bang = true, range = -1, complete = complete("browse"), desc = "Open the current object on the hosting provider" })

local group = vim.api.nvim_create_augroup("fugitive", { clear = true })

vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "fugitive://*",
  nested = true,
  callback = function(ev)
    require("fugitive.buffers.reader").read(ev.buf)
  end,
})

vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }, {
  group = group,
  pattern = "fugitive://*",
  callback = function()
    require("fugitive.ui.notify").error("fugitive:// buffers are read-only (editable index: backlog)")
  end,
})

-- conflict-marker actions in work-tree files
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, {
  group = group,
  callback = function(ev)
    if vim.bo[ev.buf].buftype == "" and not ev.file:match("^%a[%w+.-]*://") then
      require("fugitive.conflict").check(ev.buf)
    end
  end,
})

vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost" }, {
  group = group,
  callback = function()
    if package.loaded["fugitive.buffers.summary"] then
      require("fugitive.buffers.summary").refresh_all()
    end
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if package.loaded["fugitive.buffers.editor"] then
      require("fugitive.buffers.editor").abort_all()
    end
    if package.loaded["fugitive.integrations.overseer"] then
      require("fugitive.integrations.overseer").cancel_all()
    end
  end,
})

-- work-tree hunk maps (opt-in, delegated to gitsigns)
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(ev)
    if vim.g.fugitive_no_maps or vim.bo[ev.buf].buftype ~= "" then
      return
    end
    if not package.loaded["fugitive.config"] then
      return -- nothing configured yet: default worktree table is empty
    end
    local maps = require("fugitive.config").get().maps.worktree
    if next(maps) == nil then
      return
    end
    require("fugitive.maps").apply(ev.buf, "worktree", require("fugitive.integrations.gitsigns").actions)
  end,
})

-- telescope extension is registered by lua/telescope/_extensions/fugitive.lua
