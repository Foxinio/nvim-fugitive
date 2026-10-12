---@mod nvim-fugitive.api Upstream-compatible Vimscript API (F25, F28).
---
---Backs FugitiveGitDir(), FugitiveHead(), FugitiveStatusline(), … (defined
---in plugin/fugitive.lua) so plugins written against vim-fugitive work.

local object = require("nvim-fugitive.object")
local repo_mod = require("nvim-fugitive.git.repo")

local M = {}

---Resolve upstream's flexible "dir" argument: nothing/-1 (current buffer),
---a buffer number, a git dir string, or a dict with git_dir.
---@param arg any
---@return fugitive.Repo?
function M.repo_of(arg)
  if arg == nil or arg == vim.NIL or arg == -1 or arg == true or arg == 0 then
    return repo_mod.for_buf(0)
  end
  if type(arg) == "number" then
    if vim.api.nvim_buf_is_valid(arg) then
      return repo_mod.for_buf(arg)
    end
    return nil
  end
  if type(arg) == "table" then
    arg = arg.git_dir or arg.fugitive_dir
  end
  if type(arg) == "string" and arg ~= "" then
    arg = arg:gsub("/$", "")
    local real = vim.uv.fs_realpath(arg)
    if real and vim.uv.fs_stat(real .. "/HEAD") then
      return repo_mod.new(real)
    end
    return repo_mod.find(arg)
  end
end

function M.git_dir(arg)
  local r = M.repo_of(arg)
  return r and r.git_dir or ""
end

function M.work_tree(arg)
  local r = M.repo_of(arg)
  return r and r.worktree or ""
end

function M.common_dir(arg)
  local r = M.repo_of(arg)
  return r and r.common_dir or ""
end

function M.is_git_dir(path)
  return type(path) == "string" and vim.uv.fs_stat(path .. "/HEAD") ~= nil and 1 or 0
end

---@param path string|integer a path or a buffer number
function M.extract_git_dir(path)
  local name = type(path) == "number" and vim.api.nvim_buf_get_name(path) or tostring(path)
  local obj = object.parse(name)
  if obj then
    return obj.git_dir
  end
  local r = repo_mod.find(name)
  return r and r.git_dir or ""
end

---fugitive#Head(len, dir): the branch, or the abbreviated detached HEAD.
---@param len integer 0: branch only; >0: short sha when detached; <0: full ref
function M.head(len, arg)
  len = tonumber(len) or 0
  local r = M.repo_of(arg)
  if not r then
    return ""
  end
  local fd = io.open(r.git_dir .. "/HEAD", "rb")
  if not fd then
    return ""
  end
  local head = vim.trim(fd:read("*l") or "")
  fd:close()
  local ref = head:match("^ref: (.*)$")
  if ref then
    if len < 0 then
      return ref
    end
    return (ref:gsub("^refs/heads/", ""):gsub("^refs/remotes/", ""):gsub("^refs/tags/", ""))
  end
  if head:match("^%x+$") then
    if len < 0 then
      return head
    end
    return head:sub(1, len)
  end
  return ""
end

---FugitiveStatusline(): "[Git(main)]" or "[Git:abc1234(main)]".
function M.statusline()
  local r = repo_mod.for_buf(0)
  if not r then
    return ""
  end
  local status = ""
  local obj = object.parse(vim.api.nvim_buf_get_name(0))
  if obj and obj.commit ~= "" then
    status = ":" .. obj.commit:sub(1, 7)
  end
  return "[Git" .. status .. "(" .. M.head(7, r.git_dir) .. ")]"
end

---FugitiveFind(object[, dir]).
function M.find(spec, arg)
  local r = M.repo_of(arg)
  if not r then
    return ""
  end
  if type(spec) == "number" then
    spec = vim.api.nvim_buf_get_name(spec)
  end
  local target = object.find(r, spec)
  return target or ""
end

---FugitiveParse([url]): [rev, dir].
function M.parse(url)
  url = url or vim.api.nvim_buf_get_name(0)
  local obj = object.parse(url)
  if not obj then
    local r = repo_mod.find(url)
    if r and url ~= "" then
      return { r:rel(url) and (":(top)" .. r:rel(url)) or url, r.git_dir }
    end
    return { "", "" }
  end
  if obj.commit == "" then
    return { ":", obj.git_dir }
  end
  return { object.git_name(obj), obj.git_dir }
end

---FugitiveReal([url]): the work-tree path a buffer stands for.
function M.real(url)
  url = url or vim.api.nvim_buf_get_name(0)
  local obj = object.parse(url)
  if obj then
    local r = repo_mod.new(obj.git_dir)
    if obj.path and obj.path ~= "" then
      return r:abs(obj.path)
    end
    return r.worktree or obj.git_dir
  end
  if url == "" then
    return ""
  end
  return vim.fn.fnamemodify(url, ":p")
end

---FugitivePath(url, prefix[, dir]).
function M.path(url, prefix, arg)
  local real = M.real(url)
  if prefix == nil then
    return real
  end
  local r = M.repo_of(arg) or repo_mod.find(real)
  if not r then
    return real
  end
  local rel = r:rel(real) or real
  if prefix:sub(-1) == "." then
    -- relative to the cwd, with the prefix minus its final "."
    local cwd_rel = r:rel(vim.fn.getcwd()) or ""
    local p = rel
    if cwd_rel ~= "" then
      if rel:sub(1, #cwd_rel + 1) == cwd_rel .. "/" then
        p = "./" .. rel:sub(#cwd_rel + 2)
      else
        local up = select(2, cwd_rel:gsub("/", "")) + 1
        p = string.rep("../", up) .. rel
      end
    else
      p = "./" .. rel
    end
    return prefix:sub(1, -2) .. p
  end
  return prefix .. rel
end

function M.config_get(name, arg)
  local r = M.repo_of(arg)
  return r and r:config(name) or ""
end

function M.config_get_all(name, arg)
  local r = M.repo_of(arg)
  return r and r:config_all(name) or {}
end

function M.remote_url(remote, arg)
  local r = M.repo_of(arg)
  if not r then
    return ""
  end
  if remote == nil or remote == "" then
    local head = r:head()
    remote = head and r:config("branch." .. head .. ".remote") or "origin"
    if remote == "." then
      remote = "origin"
    end
  end
  if not r:config("remote." .. remote .. ".url") then
    return ""
  end
  return r:chomp({ "ls-remote", "--get-url", remote }) or ""
end

local function result_dict(res)
  local function lines(s)
    local t = vim.split(s or "", "\n", { plain = true })
    return t
  end
  return {
    exit_status = res.code,
    stdout = lines(res.stdout),
    stderr = lines(res.stderr),
    args = vim.list_slice(res.cmd or {}, 2),
  }
end

---FugitiveExecute(args[, dir][, callback]): {exit_status, stdout, stderr}.
---@param args string[]
---@param arg any
---@param cb_id? integer id of a Vimscript callback (FugitiveExecuteDone)
function M.execute(args, arg, cb_id)
  if type(args) == "string" then
    args = { args }
  end
  local r = M.repo_of(arg)
  local opts = r and { repo = r } or { cwd = vim.fn.getcwd() }
  local exec = require("nvim-fugitive.git.exec")
  if cb_id and cb_id ~= vim.NIL then
    exec.run(args, opts, function(res)
      vim.fn.FugitiveExecuteDone(cb_id, result_dict(res))
    end)
    return vim.empty_dict()
  end
  return result_dict(exec.sync(args, opts))
end

---FugitiveResult(): the latest :Git invocation.
function M.result()
  local entry = require("nvim-fugitive.ui.output").get(1)
  if not entry then
    return {}
  end
  local file = vim.fn.tempname()
  vim.fn.writefile(vim.split(entry.stdout, "\n", { plain = true }), file)
  return {
    args = vim.list_slice(entry.cmd, 2),
    exit_status = entry.code or -1,
    file = file,
    cwd = entry.cwd or "",
  }
end

---FugitiveShellCommand(args...): a shell command string.
function M.shell_command(args, arg)
  local r = M.repo_of(arg)
  local cmd = { "git" }
  if r then
    table.insert(cmd, "--git-dir=" .. vim.fn.shellescape(r.git_dir))
    if r.worktree then
      table.insert(cmd, "--work-tree=" .. vim.fn.shellescape(r.worktree))
    end
  end
  for _, a in ipairs(args or {}) do
    if type(a) == "number" then
      a = r and r:rel(vim.api.nvim_buf_get_name(a)) or vim.api.nvim_buf_get_name(a)
    end
    table.insert(cmd, vim.fn.shellescape(a))
  end
  return table.concat(cmd, " ")
end

---FugitiveGitVersion([major, minor, …]): the version, or 1/0 for ">=".
---@param want integer[]
function M.git_version(want)
  local out = require("nvim-fugitive.git.exec").chomp({ "--version" }, { raw = true }) or ""
  local version = out:match("(%d+%.%d+[%.%d]*)") or ""
  want = want or {}
  if #want == 0 then
    return version
  end
  local have = vim.split(version, ".", { plain = true })
  for i, w in ipairs(want) do
    local h = tonumber(have[i]) or 0
    if h ~= tonumber(w) then
      return h > tonumber(w) and 1 or 0
    end
  end
  return 1
end

function M.did_change(arg)
  require("nvim-fugitive").changed(M.repo_of(arg))
  return ""
end

---Fire `User <name>` with the buffer's repo, like upstream.
---@param name string
---@param buf? integer
function M.event(name, buf)
  vim.api.nvim_exec_autocmds("User", {
    pattern = name,
    modeline = false,
    data = { buf = buf, git_dir = buf and vim.b[buf].git_dir or nil },
  })
end

---The object name under the cursor of a fugitive buffer (gf, <C-R><C-F>).
---@return string? target, integer? lnum
function M.cfile()
  local buf = vim.api.nvim_get_current_buf()
  local summary = require("nvim-fugitive.buffers.summary")
  if summary.state(buf) then
    local t = require("nvim-fugitive.buffers.summary.actions").target(buf, vim.fn.line("."))
    return t.target, t.lnum
  end
  local repo = repo_mod.for_buf(buf)
  if not repo then
    return nil
  end
  return require("nvim-fugitive.buffers.reader").target_under_cursor(buf, repo)
end

return M
