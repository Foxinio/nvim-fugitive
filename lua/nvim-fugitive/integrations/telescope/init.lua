---@mod nvim-fugitive.integrations.telescope Pickers (§5.3).
---
---Telescope when installed, `vim.ui.select` fallback for the simple
---pickers. Pickers: `log`, `refs`, `stash` (`:Telescope fugitive <name>`),
---the `:Ggrep` results picker, and picker *input* for `:Git checkout`,
---`:Git switch`, `:Git merge`, `:Git rebase` (§5.3.2).

local M = {}

---Is telescope usable?
---@return boolean
function M.available()
  if not require("nvim-fugitive.config").get().integrations.telescope then
    return false
  end
  local ok = pcall(require, "telescope.pickers")
  return ok
end

---@param repo? fugitive.Repo
local function get_repo(repo)
  return repo or require("nvim-fugitive.git.repo").require()
end

---Local + remote branches and tags, most recent commit first.
---@param repo fugitive.Repo
---@return {ref: string, name: string, kind: "branch"|"remote"|"tag", sha: string, date: string, subject: string}[]
function M.list_refs(repo)
  local lines = repo:lines({
    "for-each-ref",
    "--sort=-committerdate",
    "--format=%(refname)%09%(refname:short)%09%(objectname:short)%09%(committerdate:relative)%09%(subject)",
    "refs/heads",
    "refs/remotes",
    "refs/tags",
  }) or {}
  local out = {}
  for _, l in ipairs(lines) do
    local ref, name, sha, date, subject = l:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if ref and not ref:match("^refs/remotes/[^/]+/HEAD$") then
      local kind = ref:match("^refs/heads/") and "branch"
        or ref:match("^refs/remotes/") and "remote"
        or "tag"
      table.insert(
        out,
        { ref = ref, name = name, kind = kind, sha = sha, date = date, subject = subject }
      )
    end
  end
  return out
end

---Commits of `git log` (newest first).
---@param repo fugitive.Repo
---@param args? string[] extra log arguments
---@return {sha: string, short: string, date: string, author: string, subject: string, refs: string}[]
function M.list_log(repo, args)
  local cmd = { "log", "-n", "1000", "--date=short", "--format=%H%x09%h%x09%ad%x09%an%x09%s%x09%D" }
  vim.list_extend(cmd, args or {})
  local out = {}
  for _, l in ipairs(repo:lines(cmd) or {}) do
    local sha, short, date, author, subject, refs =
      l:match("^(%x+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
    if sha then
      table.insert(out, {
        sha = sha,
        short = short,
        date = date,
        author = author,
        subject = subject,
        refs = refs or "",
      })
    end
  end
  return out
end

---`git stash list` entries.
---@param repo fugitive.Repo
function M.list_stash(repo)
  local out = {}
  for _, l in ipairs(repo:lines({ "stash", "list", "--format=%gd%x09%h%x09%gs" }) or {}) do
    local ref, short, subject = l:match("^([^\t]*)\t([^\t]*)\t(.*)$")
    if ref then
      table.insert(out, { ref = ref, short = short, subject = subject })
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Picker input for :Git checkout|switch|merge|rebase

---Ask for a ref (or a base commit for `rebase -i`) and call `cb(ref)`.
---@param repo fugitive.Repo
---@param trigger {picker: "refs"|"log", sub: string, args?: string[]}
---@param cb fun(ref: string)
function M.input(repo, trigger, cb)
  local prompt = "git " .. trigger.sub
  if M.available() then
    if trigger.picker == "log" then
      return require("nvim-fugitive.integrations.telescope.pickers").log({
        repo = repo,
        prompt_title = prompt .. ": base",
        on_select = function(c)
          cb(c.sha)
        end,
      })
    end
    return require("nvim-fugitive.integrations.telescope.pickers").refs({
      repo = repo,
      prompt_title = prompt,
      on_select = function(r)
        cb(M.ref_argument(trigger, r))
      end,
    })
  end
  if trigger.picker == "log" then
    local commits = M.list_log(repo, { "-n", "200" })
    vim.ui.select(commits, {
      prompt = prompt .. " (base)",
      format_item = function(c)
        return c.short .. " " .. c.subject
      end,
    }, function(choice)
      if choice then
        cb(choice.sha)
      end
    end)
    return
  end
  vim.ui.select(M.list_refs(repo), {
    prompt = prompt,
    format_item = function(r)
      return string.format("%-40s %s %s", r.name, r.sha, r.subject)
    end,
  }, function(choice)
    if choice then
      cb(M.ref_argument(trigger, choice))
    end
  end)
end

---The argument to append for a chosen ref: checkout/switch of a remote
---branch use the local name so git's DWIM creates a tracking branch; the
---start point of `switch -c`/`checkout -b` and merge/rebase keep it as is.
---@param trigger {picker: string, sub: string, args?: string[]}
---@param r {name: string, kind: string}
---@return string
function M.ref_argument(trigger, r)
  local bare = trigger.args == nil or #trigger.args <= 1
  if r.kind == "remote" and (trigger.sub == "checkout" or trigger.sub == "switch") and bare then
    return (r.name:gsub("^[^/]+/", ""))
  end
  return r.name
end

---Repo, path, line range and revision of the current buffer for the
---history pickers.
---@param opts? {line1?: integer, line2?: integer}
---@return {repo: fugitive.Repo, path: string, line1: integer, line2: integer, rev?: string}?
function M.history_context(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local repo = require("nvim-fugitive.git.repo").for_buf(buf)
  if not repo then
    require("nvim-fugitive.ui.notify").error("not a git repository")
    return nil
  end
  local object = require("nvim-fugitive.object")
  local path = object.buf_rel(buf, repo)
  if not path or path == "" then
    require("nvim-fugitive.ui.notify").error("not a file in the repository")
    return nil
  end
  local line1, line2 = opts.line1, opts.line2
  if not line1 then
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("^[vV\22]") then
      line1, line2 = vim.fn.line("v"), vim.fn.line(".")
      if line1 > line2 then
        line1, line2 = line2, line1
      end
    else
      line1 = vim.fn.line(".")
      line2 = line1
    end
  end
  local obj = object.parse(vim.api.nvim_buf_get_name(buf))
  local rev = obj and obj.commit:match("^%x+$") and #obj.commit >= 40 and obj.commit or nil
  return { repo = repo, path = path, line1 = line1, line2 = line2 or line1, rev = rev }
end

---Run a picker by name: telescope when available, vim.ui.select otherwise.
---@param name "log"|"refs"|"stash"|"file_history"|"line_history"|"blame_line"
---@param opts? table
function M.pick(name, opts)
  opts = opts or {}
  if M.available() then
    return require("nvim-fugitive.integrations.telescope.pickers")[name](opts)
  end
  local reader = require("nvim-fugitive.buffers.reader")
  local object = require("nvim-fugitive.object")
  if name == "refs" then
    local repo = get_repo(opts.repo)
    if not repo then
      return
    end
    return M.input(repo, { picker = "refs", sub = "checkout", args = { "checkout" } }, function(ref)
      require("nvim-fugitive.cmd.git").run({ "checkout", ref }, { repo = repo, skip_picker = true })
    end)
  elseif name == "stash" then
    local repo = get_repo(opts.repo)
    if not repo then
      return
    end
    return vim.ui.select(M.list_stash(repo), {
      prompt = "Apply stash",
      format_item = function(s)
        return s.ref .. " " .. s.subject
      end,
    }, function(s)
      if s then
        require("nvim-fugitive.cmd.git").run({ "stash", "apply", s.ref }, { repo = repo })
      end
    end)
  end
  local repo, args, path, lnum
  if name == "log" then
    repo = get_repo(opts.repo)
    args = {}
  else
    local ctx = M.history_context(
      name == "blame_line" and { line1 = vim.fn.line("."), line2 = vim.fn.line(".") } or opts
    )
    if not ctx then
      return
    end
    repo, path, lnum = ctx.repo, ctx.path, ctx.line1
    if name == "file_history" then
      args = { "--follow", "--", path }
    else
      args = { "-s", "-L", ctx.line1 .. "," .. ctx.line2 .. ":" .. path }
    end
  end
  if not repo then
    return
  end
  vim.ui.select(M.list_log(repo, args), {
    prompt = name:gsub("_", " "),
    format_item = function(c)
      return c.short .. " " .. c.date .. " " .. c.subject
    end,
  }, function(c)
    if c then
      reader.open(object.format(repo.git_dir, c.sha, path), "edit", lnum)
    end
  end)
end

---:Ggrep results picker. `<C-q>` (telescope default) sends to quickfix.
---@param items table[] quickfix items
---@param opts {title: string}
function M.grep(items, opts)
  return require("nvim-fugitive.integrations.telescope.pickers").grep(items, opts)
end

M.get_repo = get_repo

return M
