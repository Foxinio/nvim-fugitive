---@mod nvim-fugitive.git.repo Repository detection and caching.
---
---Two identities are kept apart (§4.1):
--- * the *repository* is identified by its canonical (realpath) git dir, so a
---   repo reached through a symlinked directory is still one repo;
--- * a *file* inside it is the repo-relative path as git tracks it: directory
---   components are resolved, the final component is never dereferenced.

local exec = require("nvim-fugitive.git.exec")

local uv = vim.uv
local M = {}

---@class fugitive.Repo
---@field git_dir string canonical per-worktree git dir (HEAD, index)
---@field common_dir string canonical common dir (refs, objects, config)
---@field worktree string? canonical work tree (nil for bare repos)
---@field is_submodule boolean
---@field explicit boolean git must be told --git-dir/--work-tree (external git dir)
---@field bare boolean
---@field _config table<string, string[]>?
local Repo = {}
Repo.__index = Repo

---@type table<string, fugitive.Repo>
M._cache = {}

local function realpath(p)
  return p and uv.fs_realpath(p) or nil
end

local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

local function is_abs(p)
  return p:sub(1, 1) == "/"
end

local function join(a, b)
  if is_abs(b) then
    return b
  end
  return (a:gsub("/+$", "")) .. "/" .. b
end

local function dirname(p)
  if p == "/" then
    return "/"
  end
  local d = p:gsub("/+$", ""):match("^(.*)/[^/]*$")
  if d == nil or d == "" then
    return "/"
  end
  return d
end

local function basename(p)
  return (p:gsub("/+$", ""):match("([^/]*)$"))
end

M.dirname = dirname
M.basename = basename

---Is `dir` a git dir (has HEAD and objects or a commondir file)?
local function looks_like_git_dir(dir)
  local st = uv.fs_stat(dir .. "/HEAD")
  if not st then
    return false
  end
  return uv.fs_stat(dir .. "/commondir") ~= nil or uv.fs_stat(dir .. "/objects") ~= nil
end

---Resolve the `.git` entry found in `dir`, which may be a directory or a
---`gitdir: …` file (worktrees, submodules).
---@return string? git_dir
local function resolve_dot_git(dir)
  local dotgit = dir .. "/.git"
  local st = uv.fs_stat(dotgit)
  if not st then
    return nil
  end
  if st.type == "directory" then
    return looks_like_git_dir(dotgit) and realpath(dotgit) or nil
  end
  local content = read_file(dotgit)
  local target = content and content:match("^gitdir:%s*(.-)%s*$")
  if not target then
    return nil
  end
  target = join(dir, target)
  return looks_like_git_dir(target) and realpath(target) or nil
end

---@param git_dir string canonical
---@param worktree string? canonical
---@return fugitive.Repo
function M.new(git_dir, worktree)
  local cached = M._cache[git_dir]
  if cached then
    return cached
  end
  local common = git_dir
  local cd = read_file(git_dir .. "/commondir")
  if cd then
    common = realpath(join(git_dir, vim.trim(cd))) or git_dir
  end
  local bare = false
  if not worktree then
    -- linked worktrees record their checkout in <git_dir>/gitdir
    local gd = read_file(git_dir .. "/gitdir")
    local core_wt = exec.chomp(
      { "config", "-f", git_dir .. "/config", "core.worktree" },
      { raw = true, cwd = git_dir }
    )
    if gd then
      worktree = realpath(dirname(vim.trim(gd)))
    elseif core_wt and core_wt ~= "" then
      worktree = realpath(join(git_dir, core_wt))
    elseif basename(git_dir) == ".git" then
      worktree = realpath(dirname(git_dir))
    else
      local is_bare = exec.chomp(
        { "config", "-f", git_dir .. "/config", "--bool", "core.bare" },
        { raw = true, cwd = git_dir }
      )
      if is_bare == "true" then
        bare = true
      else
        local wt = exec.chomp({ "rev-parse", "--show-toplevel" }, { cwd = git_dir })
        worktree = wt and wt ~= "" and realpath(wt) or nil
      end
    end
  end
  -- git finds the repo from the work tree only through <worktree>/.git
  local explicit = false
  if worktree then
    local dotgit = worktree .. "/.git"
    local st = uv.fs_stat(dotgit)
    if not st then
      explicit = true
    elseif st.type == "directory" then
      explicit = realpath(dotgit) ~= git_dir
    else
      explicit = resolve_dot_git(worktree) ~= git_dir
    end
  end
  local repo = setmetatable({
    git_dir = git_dir,
    common_dir = common,
    worktree = worktree,
    is_submodule = git_dir:find("/modules/", 1, true) ~= nil,
    explicit = explicit,
    bare = bare,
  }, Repo)
  M._cache[git_dir] = repo
  return repo
end

---Find the repository containing `path` (file or directory; need not exist).
---Only directory components are resolved; see module docs.
---@param path string
---@return fugitive.Repo?
function M.find(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fn.fnamemodify(path, ":p")
  ---@diagnostic disable-next-line: param-type-mismatch
  local st = uv.fs_lstat(path)
  local dir
  if st and st.type == "directory" then
    dir = realpath(path)
  else
    -- walk up to the first existing parent directory
    dir = dirname(path)
    while dir ~= "/" and not uv.fs_stat(dir) do
      dir = dirname(dir)
    end
    dir = realpath(dir)
  end
  while dir do
    if
      basename(dir) == ".git" or looks_like_git_dir(dir) and basename(dirname(dir)) == "modules"
    then
      -- inside a git dir itself: the repo is that git dir
      local gd = realpath(dir)
      if gd then
        return M.new(gd)
      end
    end
    local gd = resolve_dot_git(dir)
    if gd then
      return M.new(gd, dir)
    end
    if looks_like_git_dir(dir) and uv.fs_stat(dir .. "/refs") then
      -- a bare repository (or any git dir) entered directly
      return M.new(realpath(dir) or dir)
    end
    if dir == "/" then
      break
    end
    dir = dirname(dir)
  end
  return M.from_env(path)
end

---An external git dir from $GIT_DIR (+ $GIT_WORK_TREE or core.worktree),
---e.g. a dotfiles repository, when `path` lies in its work tree.
---@param path string
---@return fugitive.Repo?
function M.from_env(path)
  local env_dir = vim.env.GIT_DIR
  if not env_dir or env_dir == "" then
    return nil
  end
  local gd = realpath(env_dir)
  if not gd or not looks_like_git_dir(gd) then
    return nil
  end
  local wt = vim.env.GIT_WORK_TREE
      and vim.env.GIT_WORK_TREE ~= ""
      and realpath(vim.env.GIT_WORK_TREE)
    or nil
  local repo = M.new(gd, wt)
  if repo.worktree then
    local p = realpath(path) or path
    if p ~= repo.worktree and p:sub(1, #repo.worktree + 1) ~= repo.worktree .. "/" then
      return nil
    end
  end
  return repo
end

---Repository for a buffer: fugitive:// buffers, regular files, or the cwd for
---special buffers. Sets `b:git_dir` for compatibility.
---@param buf? integer
---@return fugitive.Repo?
function M.for_buf(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf --[[@as integer]]
  local ok, gd = pcall(vim.api.nvim_buf_get_var, buf, "git_dir")
  if ok and type(gd) == "string" and gd ~= "" and M._cache[gd] then
    return M._cache[gd]
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local repo
  if name:match("^fugitive://") then
    local obj = require("nvim-fugitive.object").parse(name)
    if obj then
      repo = M.new(obj.git_dir)
    end
  elseif name ~= "" and vim.bo[buf].buftype == "" then
    repo = M.find(name)
  end
  if not repo then
    repo = M.find(vim.fn.getcwd())
  end
  if repo then
    pcall(vim.api.nvim_buf_set_var, buf, "git_dir", repo.git_dir)
  end
  return repo
end

---Like for_buf but notifies an error when there is no repository.
---@param buf? integer
---@return fugitive.Repo?
function M.require(buf)
  local repo = M.for_buf(buf)
  if not repo then
    require("nvim-fugitive.ui.notify").error("not a git repository")
  end
  return repo
end

---Drop cached data (config) for a repo; called by the watcher.
---@param git_dir string
function M.invalidate(git_dir)
  local repo = M._cache[git_dir]
  if repo then
    repo._config = nil
  end
end

---Repository-relative path of an absolute path, as git tracks it: the parent
---directory is canonicalised, the final component is kept verbatim.
---@param path string
---@return string? rel nil if outside the work tree
function Repo:rel(path)
  if not self.worktree then
    return nil
  end
  path = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  if path == self.worktree then
    return ""
  end
  local parent = dirname(path)
  local name = basename(path)
  local real_parent = realpath(parent)
  if not real_parent then
    -- parent does not exist (deleted file): resolve the nearest existing ancestor
    local missing = {}
    local d = parent
    while d ~= "/" and not uv.fs_stat(d) do
      table.insert(missing, 1, basename(d))
      d = dirname(d)
    end
    real_parent = realpath(d) or d
    if #missing > 0 then
      real_parent = real_parent .. "/" .. table.concat(missing, "/")
    end
  end
  local full = real_parent == "/" and ("/" .. name) or (real_parent .. "/" .. name)
  local prefix = self.worktree .. "/"
  if full:sub(1, #prefix) == prefix then
    return full:sub(#prefix + 1)
  end
  return nil
end

---Absolute path of a repo-relative path.
---@param rel string
---@return string
function Repo:abs(rel)
  if rel == "" then
    return self.worktree or self.git_dir
  end
  return (self.worktree or self.git_dir) .. "/" .. rel
end

---Path of a file inside the git dir; refs/objects/config live in the common
---dir, HEAD/index/MERGE_HEAD/rebase state in the per-worktree dir.
---@param rel string e.g. "HEAD", "index", "refs/heads/main", "info/exclude"
---@return string
function Repo:git_path(rel)
  local per_worktree = rel == "HEAD"
    or rel == "index"
    or rel:match("^[A-Z_]+HEAD$")
    or rel:match("^rebase%-")
    or rel:match("^sequencer")
    or rel == "MERGE_MSG"
    or rel == "COMMIT_EDITMSG"
    or rel == "logs/HEAD"
    or rel:match("^refs/bisect")
    or rel == "BISECT_LOG"
  if per_worktree then
    return self.git_dir .. "/" .. rel
  end
  return self.common_dir .. "/" .. rel
end

---Run git asynchronously in this repo.
---@param args string[]
---@param opts? fugitive.ExecOpts
---@param cb? fun(res: fugitive.ExecResult)
---@return fugitive.Job
function Repo:run(args, opts, cb)
  opts = vim.tbl_extend("force", { repo = self }, opts or {})
  return exec.run(args, opts, cb)
end

---Run git synchronously in this repo.
---@param args string[]
---@param opts? fugitive.ExecOpts
---@return fugitive.ExecResult
function Repo:sync(args, opts)
  opts = vim.tbl_extend("force", { repo = self }, opts or {})
  return exec.sync(args, opts)
end

---@param args string[]
---@param opts? fugitive.ExecOpts
---@return string[]?, fugitive.ExecResult
function Repo:lines(args, opts)
  opts = vim.tbl_extend("force", { repo = self }, opts or {})
  return exec.lines(args, opts)
end

---@param args string[]
---@param opts? fugitive.ExecOpts
---@return string?
function Repo:chomp(args, opts)
  opts = vim.tbl_extend("force", { repo = self }, opts or {})
  return exec.chomp(args, opts)
end

---All values of a config key (cached until the watcher invalidates).
---@param key string
---@return string[]
function Repo:config_all(key)
  if not self._config then
    local res = self:sync({ "config", "--list", "-z" })
    local cfg = {}
    for entry in (res.stdout or ""):gmatch("([^%z]+)") do
      local k, v = entry:match("^([^\n]*)\n(.*)$")
      if not k then
        k, v = entry, ""
      end
      -- section and key names are case-insensitive, subsection names are not
      local section, sub, name = k:match("^([^.]+)%.(.+)%.([^.]+)$")
      if section then
        k = section:lower() .. "." .. sub .. "." .. name:lower()
      else
        k = k:lower()
      end
      cfg[k] = cfg[k] or {}
      table.insert(cfg[k], v)
    end
    self._config = cfg
  end
  local section, sub, name = key:match("^([^.]+)%.(.+)%.([^.]+)$")
  if section then
    key = section:lower() .. "." .. sub .. "." .. name:lower()
  else
    key = key:lower()
  end
  return self._config[key] or {}
end

---Last value of a config key.
---@param key string
---@return string?
function Repo:config(key)
  local all = self:config_all(key)
  return all[#all]
end

---Current branch name, or nil when detached (reads HEAD directly).
---@return string? branch, string? detached_sha
function Repo:head()
  local content = read_file(self.git_dir .. "/HEAD")
  if not content then
    return nil
  end
  local ref = content:match("^ref:%s*(%S+)")
  if ref then
    return (ref:gsub("^refs/heads/", "")), nil
  end
  return nil, vim.trim(content)
end

---Resolve a revision to a full object id.
---@param rev string
---@return string?
function Repo:rev_parse(rev)
  local out = self:chomp({ "rev-parse", "--verify", "--quiet", rev })
  if out and out:match("^%x+$") then
    return out
  end
  return nil
end

---Short identifier of the repo for messages.
function Repo:name()
  return basename(self.worktree or self.git_dir)
end

M.Repo = Repo

return M
