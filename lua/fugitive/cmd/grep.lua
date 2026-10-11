---@mod fugitive.cmd.grep :Ggrep / :Glgrep (F17).
---
---Telescope-first: with telescope installed, `:Ggrep` opens a picker over
---the `git grep` results (telescope's `<C-q>` sends them to quickfix).
---Without telescope it fills the quickfix list like upstream; `:Glgrep`
---always fills the location list. `!` does not jump to the first match.

local notify = require("fugitive.ui.notify")
local object = require("fugitive.object")

local M = {}

---Parse `git grep -n --column -z --full-name` output into qf items.
---@param repo fugitive.Repo
---@param out string
---@return table[] items
function M.parse(repo, out)
  local items = {}
  local revs = {}
  local function filename(name)
    if vim.uv.fs_lstat(repo:abs(name)) then
      return repo:abs(name)
    end
    -- "<rev>:<path>" when grepping a tree
    local start = 1
    while true do
      local colon = name:find(":", start, true)
      if not colon then
        break
      end
      local rev = name:sub(1, colon - 1)
      if revs[rev] == nil then
        revs[rev] = repo:rev_parse(rev .. "^{tree}") and (repo:rev_parse(rev .. "^{commit}") or false) or false
      end
      if revs[rev] then
        return object.format(repo.git_dir, revs[rev], name:sub(colon + 1))
      end
      start = colon + 1
    end
    return repo:abs(name)
  end
  for line in out:gmatch("[^\n]+") do
    local name, lnum, col, text = line:match("^(.-)%z(%d+)%z(%d+)%z(.*)$")
    if not name then
      name, lnum, text = line:match("^(.-)%z(%d+)%z(.*)$")
    end
    if name then
      table.insert(items, {
        filename = filename(name),
        lnum = tonumber(lnum),
        col = tonumber(col) or 1,
        text = text,
      })
    end
  end
  return items
end

local function fill_list(items, loclist, bang, title)
  local what = { title = title, items = items }
  vim.api.nvim_exec_autocmds("QuickFixCmdPre", { pattern = loclist and "Glgrep" or "Ggrep", modeline = false })
  if loclist then
    vim.fn.setloclist(0, {}, " ", what)
  else
    vim.fn.setqflist({}, " ", what)
  end
  vim.api.nvim_exec_autocmds("QuickFixCmdPost", { pattern = loclist and "Glgrep" or "Ggrep", modeline = false })
  if #items == 0 then
    notify.info("no matches")
    return
  end
  if not bang then
    vim.cmd(loclist and "lfirst" or "cfirst")
  end
end

---@param args string[] user arguments (pattern, pathspecs, revs, …)
---@param opts {loclist: boolean, bang: boolean, repo?: fugitive.Repo}
function M.grep(args, opts)
  local repo = opts.repo or require("fugitive.git.repo").require()
  if not repo then
    return
  end
  if #args == 0 then
    notify.error("usage: :Ggrep {pattern} [pathspec…]")
    return
  end
  local cmd = { "grep", "-n", "--column", "-z", "--full-name", "--no-color", "-I" }
  vim.list_extend(cmd, args)
  local title = ":Ggrep " .. table.concat(args, " ")
  repo:run(cmd, {}, function(res)
    require("fugitive.ui.output").record(res, repo.worktree)
    -- exit 1 means "no matches"
    if res.code ~= 0 and res.code ~= 1 then
      notify.error(notify.truncate(require("fugitive.git.exec").error_text(res), { code = res.code, is_error = true }))
      return
    end
    local items = M.parse(repo, res.stdout)
    local tele = require("fugitive.integrations.telescope")
    if not opts.loclist and tele.available() and #items > 0 then
      tele.grep(items, { title = title })
      return
    end
    fill_list(items, opts.loclist, opts.bang, title)
  end)
end

---@param cmd table user command argument
---@param loclist boolean
function M.command(cmd, loclist)
  local args = require("fugitive.cmd.git").split_args(cmd.args or "")
  M.grep(args, { loclist = loclist, bang = cmd.bang })
end

return M
