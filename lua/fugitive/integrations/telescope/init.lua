---@mod fugitive.integrations.telescope Pickers (§5.3).
---
---Telescope when installed, `vim.ui.select` fallback for the simple
---pickers. Pickers: `log`, `refs`, `stash` (`:Telescope fugitive <name>`),
---the `:Ggrep` results picker, and picker *input* for `:Git checkout`,
---`:Git switch`, `:Git merge`, `:Git rebase` (§5.3.2).

local M = {}

---Is telescope usable?
---@return boolean
function M.available()
  if not require("fugitive.config").get().integrations.telescope then
    return false
  end
  local ok = pcall(require, "telescope.pickers")
  return ok
end

---@param repo? fugitive.Repo
local function get_repo(repo)
  return repo or require("fugitive.git.repo").require()
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
      local kind = ref:match("^refs/heads/") and "branch" or ref:match("^refs/remotes/") and "remote" or "tag"
      table.insert(out, { ref = ref, name = name, kind = kind, sha = sha, date = date, subject = subject })
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
    local sha, short, date, author, subject, refs = l:match("^(%x+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
    if sha then
      table.insert(out, { sha = sha, short = short, date = date, author = author, subject = subject, refs = refs or "" })
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
---@param trigger {picker: "refs"|"log", sub: string}
---@param cb fun(ref: string)
function M.input(repo, trigger, cb)
  local prompt = "git " .. trigger.sub
  if M.available() then
    if trigger.picker == "log" then
      return require("fugitive.integrations.telescope.pickers").log({ repo = repo, prompt_title = prompt .. ": base", on_select = function(c)
        cb(c.sha)
      end })
    end
    return require("fugitive.integrations.telescope.pickers").refs({ repo = repo, prompt_title = prompt, on_select = function(r)
      cb(M.ref_argument(trigger, r))
    end })
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
---@param trigger {picker: string, sub: string}
---@param r {name: string, kind: string}
---@return string
function M.ref_argument(trigger, r)
  local bare = trigger.args == nil or #trigger.args <= 1
  if r.kind == "remote" and (trigger.sub == "checkout" or trigger.sub == "switch") and bare then
    return (r.name:gsub("^[^/]+/", ""))
  end
  return r.name
end

---:Ggrep results picker. `<C-q>` (telescope default) sends to quickfix.
---@param items table[] quickfix items
---@param opts {title: string}
function M.grep(items, opts)
  return require("fugitive.integrations.telescope.pickers").grep(items, opts)
end

M.get_repo = get_repo

return M
