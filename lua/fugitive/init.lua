---@mod fugitive nvim-fugitive: a Lua, Neovim-only rewrite of vim-fugitive.
---
---`require("fugitive").setup(opts)` is optional; everything works with the
---defaults (see `:help fugitive-config`).

local M = {}

---@param opts? table see fugitive.config.defaults
function M.setup(opts)
  require("fugitive.config").set(opts)
  M._setup_done = true
  require("fugitive.watch").enable(require("fugitive.config").get().watch.enabled)
end

---Signal that `repo` changed: drop cached data, refresh summaries,
---gitsigns and statuslines via `User FugitiveChanged`.
---@param repo? fugitive.Repo
function M.changed(repo)
  if repo then
    require("fugitive.git.repo").invalidate(repo.git_dir)
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "FugitiveChanged",
    modeline = false,
    data = { git_dir = repo and repo.git_dir },
  })
  require("fugitive.integrations.gitsigns").refresh()
end

---Run `:Git {args}` programmatically.
---@param args string|string[]
---@param opts? {bang?: boolean, mods?: string}
function M.git(args, opts)
  if type(args) == "string" then
    args = require("fugitive.cmd.git").split_args(args)
  end
  return require("fugitive.cmd.git").run(args, opts)
end

---The repository of a buffer (or nil).
---@param buf? integer
---@return fugitive.Repo?
function M.repo(buf)
  return require("fugitive.git.repo").for_buf(buf)
end

---Open the summary buffer of the current repository.
function M.summary(opts)
  local repo = require("fugitive.git.repo").require()
  if repo then
    return require("fugitive.buffers.summary").open(repo, opts)
  end
end

return M
