---@mod fugitive.cmd.complete Command-line completion (F23).
---
---Subcommands (incl. aliases), flags (`git <sub> --git-completion-helper`),
---refs, paths and the reduced object syntax.

local M = {}

local cache = { subcommands = nil, flags = {} }

local function repo()
  return require("fugitive.git.repo").for_buf(0)
end

local function filter(list, lead)
  local out, seen = {}, {}
  for _, item in ipairs(list) do
    if item:sub(1, #lead) == lead and not seen[item] then
      seen[item] = true
      table.insert(out, item)
    end
  end
  return out
end

---All git subcommands and aliases.
---@param r? fugitive.Repo
---@return string[]
function M.subcommands(r)
  if not cache.subcommands then
    local exec = require("fugitive.git.exec")
    local list = exec.lines({ "--list-cmds=main,others,nohelpers" }, {}) or {}
    table.sort(list)
    cache.subcommands = list
  end
  local list = vim.deepcopy(cache.subcommands)
  if r then
    for _, l in ipairs(r:lines({ "config", "--get-regexp", "^alias\\." }) or {}) do
      local name = l:match("^alias%.(%S+)")
      if name then
        table.insert(list, name)
      end
    end
  end
  table.insert(list, "restore-discard")
  table.sort(list)
  return list
end

---Flags of a subcommand from git's own completion helper.
---@param sub string
---@return string[]
function M.flags(sub)
  if cache.flags[sub] == nil then
    local res = require("fugitive.git.exec").sync({ sub, "--git-completion-helper" }, {})
    local flags = {}
    if res.code == 0 then
      for f in res.stdout:gmatch("%S+") do
        if f ~= "--" then
          table.insert(flags, (f:gsub("=$", "=")))
        end
      end
    end
    table.sort(flags)
    cache.flags[sub] = flags
  end
  return cache.flags[sub]
end

---Short ref names.
---@param r fugitive.Repo
---@return string[]
function M.refs(r)
  local list = r:lines({ "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes", "refs/tags" }) or {}
  vim.list_extend(list, { "HEAD", "@{upstream}", "@{push}" })
  for _, special in ipairs({ "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REBASE_HEAD", "stash" }) do
    if vim.uv.fs_stat(r:git_path(special == "stash" and "refs/stash" or special)) then
      table.insert(list, special)
    end
  end
  return list
end

---Repo paths, relative to the work tree root.
---@param r fugitive.Repo
---@param lead string
---@param others? boolean include untracked files
---@return string[]
function M.paths(r, lead, others)
  local args = { "ls-files", "--cached", "--deduplicate" }
  if others then
    vim.list_extend(args, { "--others", "--exclude-standard" })
  end
  local files = r:lines(args) or {}
  -- complete one directory level at a time
  local out, seen = {}, {}
  for _, f in ipairs(files) do
    if f:sub(1, #lead) == lead then
      local rest = f:sub(#lead + 1)
      local slash = rest:find("/", 1, true)
      local item = slash and (lead .. rest:sub(1, slash)) or f
      if not seen[item] then
        seen[item] = true
        table.insert(out, item)
      end
    end
  end
  table.sort(out)
  return out
end

---Object syntax: refs, `rev:path`, `:N:path`.
---@param r fugitive.Repo
---@param lead string
---@return string[]
function M.objects(r, lead)
  local rev, path = lead:match("^(.-):(.*)$")
  if rev then
    local stage, spath = lead:match("^:([0-3]):(.*)$")
    if stage then
      return vim.tbl_map(function(p)
        return ":" .. stage .. ":" .. p
      end, M.paths(r, spath))
    end
    if rev == "" then
      return vim.tbl_map(function(p)
        return ":" .. p
      end, M.paths(r, path))
    end
    -- paths in a revision's tree
    local dir = path:match("^(.*/)") or ""
    local res = r:sync({ "ls-tree", "--name-only", rev .. ":" .. dir })
    local out = {}
    if res.code == 0 then
      for name in res.stdout:gmatch("[^\n]+") do
        local full = dir .. name
        local kind = r:chomp({ "cat-file", "-t", rev .. ":" .. full })
        table.insert(out, rev .. ":" .. full .. (kind == "tree" and "/" or ""))
      end
    end
    return filter(out, lead)
  end
  local list = M.refs(r)
  vim.list_extend(list, M.paths(r, lead))
  return filter(list, lead)
end

local path_subcommands = {
  add = true,
  rm = true,
  mv = true,
  restore = true,
  ["check-ignore"] = true,
  ["ls-files"] = true,
  clean = true,
  blame = true,
}

---Complete `:Git` arguments.
function M.git(lead, cmdline, pos)
  local r = repo()
  local before = cmdline:sub(1, pos)
  -- strip the command name (and range/modifiers/bang)
  local args_text = before:match("^.-G%a*!?%s+(.*)$") or ""
  local words = require("fugitive.cmd.git").split_args(args_text)
  if lead ~= "" then
    table.remove(words) -- the word being completed
  end
  local parsed = require("fugitive.cmd.routes").parse(words)
  if not parsed.sub then
    if lead:sub(1, 1) == "-" then
      return filter({ "-c", "-C", "-p", "--paginate", "-P", "--no-pager", "--git-dir=", "--work-tree=" }, lead)
    end
    return filter(M.subcommands(r), lead)
  end
  local sub = parsed.sub
  if lead:sub(1, 1) == "-" then
    return filter(M.flags(sub), lead)
  end
  if not r then
    return {}
  end
  local after_dashdash = vim.tbl_contains(parsed.rest, "--")
  if path_subcommands[sub] or after_dashdash then
    return M.paths(r, lead, sub == "add" or sub == "clean" or sub == "check-ignore")
  end
  if sub == "stash" and #parsed.rest == 0 then
    return filter({ "push", "pop", "apply", "drop", "list", "show", "branch", "clear", "create", "store" }, lead)
  end
  if sub == "remote" or sub == "push" or sub == "fetch" or sub == "pull" then
    local remotes = r:lines({ "remote" }) or {}
    if #parsed.rest == 0 then
      return filter(sub == "remote" and { "add", "remove", "rename", "set-url", "show", "prune", "-v" } or remotes, lead)
    end
    return filter(vim.list_extend(remotes, M.refs(r)), lead)
  end
  return M.objects(r, lead)
end

function M.object(lead)
  local r = repo()
  return r and M.objects(r, lead) or {}
end

function M.path(lead)
  local r = repo()
  return r and M.paths(r, (lead:gsub("^/", ""))) or {}
end

---:GRename: relative to the current file's directory.
function M.sibling(lead)
  local r = repo()
  if not r then
    return {}
  end
  local name = vim.api.nvim_buf_get_name(0)
  local dir = r:rel(vim.fn.fnamemodify(name, ":h")) or ""
  local prefix = dir ~= "" and (dir .. "/") or ""
  local out = {}
  for _, p in ipairs(M.paths(r, prefix .. lead)) do
    table.insert(out, p:sub(#prefix + 1))
  end
  return out
end

function M.git_grep(lead)
  local r = repo()
  if not r then
    return {}
  end
  if lead:sub(1, 1) == "-" then
    return filter(M.flags("grep"), lead)
  end
  return M.objects(r, lead)
end

function M.browse(lead)
  local r = repo()
  if not r then
    return {}
  end
  local list = M.objects(r, lead)
  for _, remote in ipairs(r:lines({ "remote" }) or {}) do
    table.insert(list, "@" .. remote)
  end
  return filter(list, lead)
end

function M.discarded(lead)
  local r = repo()
  if not r then
    return {}
  end
  return filter(require("fugitive.discard").paths(r), lead)
end

return M
