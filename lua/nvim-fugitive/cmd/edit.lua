---@mod nvim-fugitive.cmd.edit :Gedit family, :Gread, :Gwrite, :Gwq.

local object = require("nvim-fugitive.object")
local notify = require("nvim-fugitive.ui.notify")

local M = {}

---The default object of a buffer: the index version of a work-tree file,
---the work-tree file of anything else (upstream's rule).
---@param repo fugitive.Repo
---@param buf integer
---@return string spec
function M.default_spec(repo, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local obj = object.parse(name)
  if obj then
    if obj.path and obj.path ~= "" then
      return ":(top)" .. obj.path
    end
    return ":"
  end
  local rel = name ~= "" and repo:rel(name)
  if rel and rel ~= "" then
    return ":0:" .. rel
  end
  return ":"
end

---Resolve a user-typed object for the current buffer.
---@param repo fugitive.Repo
---@param spec string? nil or "" means the default object
---@return string? target, string? err
function M.target(repo, spec)
  local buf = vim.api.nvim_get_current_buf()
  if not spec or spec == "" then
    spec = M.default_spec(repo, buf)
  end
  return object.find(repo, object.expand(spec, repo))
end

---Show the output of the latest :Git invocation in a scratch buffer (`-`).
---@param cmd string ex command used to open it
local function open_last_output(cmd)
  local output = require("nvim-fugitive.ui.output")
  local entry = output.get(1)
  if not entry then
    notify.warn("no :Git output recorded")
    return
  end
  local name = "fugitive-output://" .. entry.id
  local existing = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\/.*$^~[]") .. "$")
  if cmd ~= "edit" then
    vim.cmd(cmd == "tabedit" and "tab split" or cmd == "pedit" and "pedit" or cmd)
  end
  if existing > 0 then
    vim.api.nvim_win_set_buf(0, existing)
    return
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, output.lines(entry))
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_win_set_buf(0, buf)
end

local ex = {
  edit = "edit",
  split = "split",
  vsplit = "vsplit",
  tabedit = "tabedit",
  pedit = "pedit",
  drop = "drop",
}

---Open an object.
---@param how "edit"|"split"|"vsplit"|"tabedit"|"pedit"|"drop"
---@param spec string?
---@param opts? {bang?: boolean, mods?: string}
function M.open(how, spec, opts)
  opts = opts or {}
  local repo = require("nvim-fugitive.git.repo").require()
  if not repo then
    return
  end
  if spec == "-" then
    return open_last_output(ex[how])
  end
  local target, err = M.target(repo, spec)
  if not target then
    notify.error(err or ("cannot open " .. tostring(spec)))
    return
  end
  local cmd = ex[how] .. ((opts.bang and how ~= "pedit") and "!" or "")
  local mods = opts.mods and opts.mods ~= "" and (opts.mods .. " ") or ""
  vim.cmd(mods .. cmd .. " " .. vim.fn.fnameescape(target))
  return target
end

---User command entry point for the :Gedit family.
---@param how string
---@param c table
function M.command(how, c)
  local ok, err = pcall(M.open, how, vim.trim(c.args or ""), { bang = c.bang, mods = c.mods })
  if not ok then
    notify.error(tostring(err))
  end
end

return M
