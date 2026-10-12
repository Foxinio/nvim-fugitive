---@mod nvim-fugitive.cmd.log :Gclog / :Gllog (F18).
---
---Commit history into the quickfix or location list. With a single path
---argument (or `%`), entries are that file at each commit; with a range,
---`git log -L` history of those lines, positioned on each hunk.

local object = require("nvim-fugitive.object")
local notify = require("nvim-fugitive.ui.notify")

local M = {}

local SEP = "\31" -- unit separator, never in subjects

---Parse `git log --format=<SEP>%H<SEP>%s [-L…|-p]` output.
---@param repo fugitive.Repo
---@param out string
---@param opts {path?: string, line_log?: boolean}
---@return table[] quickfix items
function M.parse(repo, out, opts)
  local items = {}
  local current
  local path = opts.path
  local new_path
  for line in (out .. "\n"):gmatch("(.-)\n") do
    local sha, subject = line:match("^" .. SEP .. "(%x+)" .. SEP .. "(.*)$")
    if sha then
      current = { sha = sha, subject = subject, hunk = false }
      new_path = nil
      if not opts.line_log then
        local item = {
          filename = path and object.format(repo.git_dir, sha, path)
            or object.format(repo.git_dir, sha),
          module = sha:sub(1, 7) .. (path and (":" .. path) or ""),
          text = subject,
        }
        table.insert(items, item)
      end
    elseif current and opts.line_log then
      local p = line:match("^%+%+%+ b/(.*)$")
      if p then
        new_path = p
      end
      local start = line:match("^@@ [^@]*%+(%d+)")
      if start and not current.hunk then
        current.hunk = true
        local file = new_path or path
        table.insert(items, {
          filename = object.format(repo.git_dir, current.sha, file),
          module = current.sha:sub(1, 7) .. ":" .. file,
          lnum = tonumber(start),
          text = current.subject
            .. (line:match(" @@+ (.+)$") and (" " .. line:match(" @@+ (.+)$")) or ""),
        })
      end
    end
  end
  return items
end

---@param opts {args: string[], loclist: boolean, bang: boolean, line1?: integer, line2?: integer, range?: integer}
function M.log(opts)
  local repo = require("nvim-fugitive.git.repo").require()
  if not repo then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local args = { "log", "--no-color", "--no-ext-diff", "--format=" .. SEP .. "%H" .. SEP .. "%s" }
  local path, line_log
  local user = require("nvim-fugitive.cmd.git").expand(opts.args, repo)
  if opts.range and opts.range > 0 then
    path = object.buf_rel(buf, repo)
    if not path or path == "" then
      notify.error(":{range}Gclog needs a file")
      return
    end
    local commit = object.parse(vim.api.nvim_buf_get_name(buf))
    if opts.line1 == 0 then
      -- :0Gclog: the whole file's history
      vim.list_extend(args, { "--follow" })
      vim.list_extend(args, user)
      if commit and commit.commit:match("^%x+$") and #commit.commit >= 40 then
        table.insert(args, commit.commit)
      end
      vim.list_extend(args, { "--", path })
    else
      line_log = true
      table.insert(args, string.format("-L%d,%d:%s", opts.line1, opts.line2, path))
      vim.list_extend(args, user)
      if commit and commit.commit:match("^%x+$") and #commit.commit >= 40 then
        table.insert(args, commit.commit)
      end
    end
  else
    vim.list_extend(args, user)
    -- a single path argument: entries are that file at each commit
    local dashdash = vim.tbl_contains(user, "--")
    local positional = require("nvim-fugitive.cmd.routes").positionals(user)
    if dashdash then
      local after = {}
      local seen = false
      for _, a in ipairs(user) do
        if seen then
          table.insert(after, a)
        elseif a == "--" then
          seen = true
        end
      end
      if #after == 1 then
        path = after[1]
      end
    elseif
      #positional == 1
      and not repo:rev_parse(positional[1])
      and vim.uv.fs_stat(repo:abs(positional[1]))
    then
      path = positional[1]
      for i, a in ipairs(args) do
        if a == path then
          table.remove(args, i)
          break
        end
      end
      vim.list_extend(args, { "--", path })
    end
  end
  local title = ":G" .. (opts.loclist and "l" or "c") .. "log " .. table.concat(opts.args, " ")
  repo:run(args, {}, function(res)
    require("nvim-fugitive.ui.output").record(res, repo.worktree)
    if res.code ~= 0 then
      notify.error(require("nvim-fugitive.git.exec").error_text(res))
      return
    end
    local items = M.parse(repo, res.stdout, { path = path, line_log = line_log })
    local what = { title = title, items = items }
    local event = opts.loclist and "Gllog" or "Gclog"
    vim.api.nvim_exec_autocmds("QuickFixCmdPre", { pattern = event, modeline = false })
    if opts.loclist then
      vim.fn.setloclist(0, {}, " ", what)
    else
      vim.fn.setqflist({}, " ", what)
    end
    vim.api.nvim_exec_autocmds("QuickFixCmdPost", { pattern = event, modeline = false })
    if #items == 0 then
      notify.warn("no commits")
    elseif not opts.bang then
      vim.cmd(opts.loclist and "silent lfirst" or "silent cfirst")
    end
  end)
end

---User command entry point.
---@param c table
---@param loclist boolean
function M.command(c, loclist)
  M.log({
    args = require("nvim-fugitive.cmd.git").split_args(c.args or ""),
    loclist = loclist,
    bang = c.bang,
    range = c.range,
    -- count-style range (-range=-1): :0Gclog has line1 0, :N one line
    line1 = c.line1,
    line2 = c.range == 2 and c.line2 or c.line1,
  })
end

return M
