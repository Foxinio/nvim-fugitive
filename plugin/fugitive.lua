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
    return require("nvim-fugitive.cmd.complete")[kind](arglead, cmdline, pos)
  end
end

for _, name in ipairs({ "Git", "G" }) do
  cmd(
    name,
    function(c)
      require("nvim-fugitive.cmd.git").command(c)
    end,
    { nargs = "*", bang = true, range = -1, complete = complete("git"), desc = "Run a git command" }
  )
end

cmd("FugitiveOutput", function(c)
  require("nvim-fugitive.ui.output").show(tonumber(c.args), c.mods)
end, { nargs = "?", desc = "Show the full output of a recent git command" })

cmd("FugitiveRestore", function(c)
  require("nvim-fugitive.discard").pick(c.args ~= "" and c.args or nil)
end, { nargs = "?", complete = complete("discarded"), desc = "Restore a discarded change" })

for name, how in pairs({
  Gedit = "edit",
  Ge = "edit",
  Gsplit = "split",
  Gvsplit = "vsplit",
  Gtabedit = "tabedit",
  Gpedit = "pedit",
  Gdrop = "drop",
}) do
  cmd(name, function(c)
    require("nvim-fugitive.cmd.edit").command(how, c)
  end, {
    nargs = "?",
    bang = true,
    bar = true,
    complete = complete("object"),
    desc = "Open a fugitive object (" .. how .. ")",
  })
end

cmd("Gread", function(c)
  require("nvim-fugitive.cmd.edit").read(vim.trim(c.args), { range = c.range, line2 = c.line2 })
end, {
  nargs = "?",
  bar = true,
  range = true,
  complete = complete("object"),
  desc = "Read a fugitive object into the buffer",
})
cmd("Gwrite", function(c)
  require("nvim-fugitive.cmd.edit").write(vim.trim(c.args), c.bang)
end, {
  nargs = "?",
  bang = true,
  bar = true,
  complete = complete("object"),
  desc = "Write and stage the buffer",
})
cmd("Gwq", function(c)
  require("nvim-fugitive.cmd.edit").wq(vim.trim(c.args), c.bang)
end, {
  nargs = "?",
  bang = true,
  bar = true,
  complete = complete("object"),
  desc = ":Gwrite, then :quit",
})

for name, layout in pairs({
  Gdiffsplit = "auto",
  Gvdiffsplit = "vertical",
  Ghdiffsplit = "horizontal",
}) do
  cmd(name, function(c)
    require("nvim-fugitive.buffers.diffsplit").command(c, layout)
  end, { nargs = "*", bang = true, complete = complete("object"), desc = "Diff against an object" })
end

cmd("Ggrep", function(c)
  require("nvim-fugitive.cmd.grep").command(c, false)
end, {
  nargs = "*",
  bang = true,
  complete = complete("git_grep"),
  desc = "git grep into a picker/quickfix",
})
cmd("Glgrep", function(c)
  require("nvim-fugitive.cmd.grep").command(c, true)
end, {
  nargs = "*",
  bang = true,
  complete = complete("git_grep"),
  desc = "git grep into the location list",
})

cmd("GMove", function(c)
  require("nvim-fugitive.cmd.move").move(c, false)
end, { nargs = 1, bang = true, complete = complete("path"), desc = "git mv the current file" })
cmd("GRename", function(c)
  require("nvim-fugitive.cmd.move").move(c, true)
end, {
  nargs = 1,
  bang = true,
  complete = complete("sibling"),
  desc = "git mv relative to the current file",
})
cmd("GRemove", function(c)
  require("nvim-fugitive.cmd.move").remove(c, { delete_buffer = false })
end, { nargs = 0, bang = true, desc = "git rm the current file, keep the buffer" })
cmd("GDelete", function(c)
  require("nvim-fugitive.cmd.move").remove(c, { delete_buffer = true })
end, { nargs = 0, bang = true, desc = "git rm the current file and delete the buffer" })
cmd("GUnlink", function(c)
  require("nvim-fugitive.cmd.move").unlink(c)
end, { nargs = 0, bang = true, desc = "Alias of :GRemove" })

cmd("GBrowse", function(c)
  require("nvim-fugitive.cmd.browse").command(c)
end, {
  nargs = "?",
  bang = true,
  range = -1,
  complete = complete("browse"),
  desc = "Open the current object on the hosting provider",
})

local group = vim.api.nvim_create_augroup("fugitive", { clear = true })

vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "fugitive://*",
  nested = true,
  callback = function(ev)
    require("nvim-fugitive.buffers.reader").read(ev.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "fugitive://*",
  callback = function(ev)
    require("nvim-fugitive.buffers.reader").write(ev.buf)
  end,
})
vim.api.nvim_create_autocmd({ "FileWriteCmd", "FileAppendCmd" }, {
  group = group,
  pattern = "fugitive://*",
  callback = function()
    require("nvim-fugitive.ui.notify").error(
      "cannot write part of a buffer to a fugitive:// object"
    )
  end,
})

-- conflict-marker actions in work-tree files
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, {
  group = group,
  callback = function(ev)
    if vim.bo[ev.buf].buftype == "" and not ev.file:match("^%a[%w+.-]*://") then
      require("nvim-fugitive.conflict").check(ev.buf)
    end
  end,
})

vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost" }, {
  group = group,
  callback = function()
    if package.loaded["nvim-fugitive.buffers.summary"] then
      require("nvim-fugitive.buffers.summary").refresh_all()
    end
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if package.loaded["nvim-fugitive.buffers.editor"] then
      require("nvim-fugitive.buffers.editor").abort_all()
    end
    if package.loaded["nvim-fugitive.integrations.overseer"] then
      require("nvim-fugitive.integrations.overseer").cancel_all()
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
    if not package.loaded["nvim-fugitive.config"] then
      return -- nothing configured yet: default worktree table is empty
    end
    local maps = require("nvim-fugitive.config").get().maps.worktree
    if next(maps) == nil then
      return
    end
    require("nvim-fugitive.maps").apply(
      ev.buf,
      "worktree",
      require("nvim-fugitive.integrations.gitsigns").actions
    )
  end,
})

-- telescope extension is registered by lua/telescope/_extensions/fugitive.lua
