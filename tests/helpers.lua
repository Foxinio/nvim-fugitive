-- Shared helpers for unit and integration tests: throwaway fixture repos,
-- synchronous git, and waiting on async work.
local H = {}

local counter = 0

---@return string
function H.tmpdir()
  counter = counter + 1
  local base = vim.env.FUGITIVE_TEST_TMP or vim.fn.tempname()
  local dir = string.format("%s-fx%d", base, counter)
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

---Run git synchronously; error on failure unless `allow_fail`.
---@param cwd string
---@param args string[]
---@param opts? {allow_fail?: boolean, stdin?: string, env?: table}
---@return string stdout, integer code, string stderr
function H.git(cwd, args, opts)
  opts = opts or {}
  local cmd = { "git", "-c", "init.defaultBranch=main", "-c", "advice.detachedHead=false" }
  vim.list_extend(cmd, args)
  local env = vim.tbl_extend("force", {
    GIT_AUTHOR_NAME = "Test",
    GIT_AUTHOR_EMAIL = "test@example.com",
    GIT_COMMITTER_NAME = "Test",
    GIT_COMMITTER_EMAIL = "test@example.com",
    GIT_EDITOR = "false",
    GIT_CONFIG_NOSYSTEM = "1",
    GIT_CONFIG_GLOBAL = "/dev/null",
  }, opts.env or {})
  local res = vim.system(cmd, { cwd = cwd, text = true, stdin = opts.stdin, env = env }):wait()
  if res.code ~= 0 and not opts.allow_fail then
    error(string.format("git %s failed (%d): %s", table.concat(args, " "), res.code, res.stderr))
  end
  return res.stdout or "", res.code, res.stderr or ""
end

---@class FixtureRepo
---@field root string
local Repo = {}
Repo.__index = Repo

function Repo:git(...)
  local args = { ... }
  local opts
  if type(args[#args]) == "table" then
    opts = table.remove(args)
  end
  return (H.git(self.root, args, opts))
end

function Repo:path(rel)
  return self.root .. "/" .. rel
end

function Repo:write(rel, content)
  local p = self:path(rel)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local f = assert(io.open(p, "wb"))
  f:write(content)
  f:close()
  return p
end

function Repo:read(rel)
  local f = io.open(self:path(rel), "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

function Repo:commit(msg, files)
  if files then
    for rel, content in pairs(files) do
      self:write(rel, content)
    end
  end
  self:git("add", "-A")
  self:git("commit", "-q", "--allow-empty", "-m", msg)
  return vim.trim(self:git("rev-parse", "HEAD"))
end

function Repo:rev(rev)
  return vim.trim(self:git("rev-parse", rev))
end

---Porcelain v1 short status, for asserting repo state.
function Repo:status()
  return self:git("status", "--porcelain=v1", "--untracked-files=all")
end

---Create a fixture repo. `opts.files` seeds an initial commit.
---@param opts? {files?: table<string,string>, bare?: boolean, dir?: string}
---@return FixtureRepo
function H.repo(opts)
  opts = opts or {}
  local root = opts.dir or H.tmpdir()
  vim.fn.mkdir(root, "p")
  H.git(root, { "init", "-q", opts.bare and "--bare" or nil })
  H.git(root, { "config", "user.name", "Test" })
  H.git(root, { "config", "user.email", "test@example.com" })
  H.git(root, { "config", "commit.gpgsign", "false" })
  local repo = setmetatable({ root = vim.uv.fs_realpath(root) }, Repo)
  if opts.files then
    repo:commit("initial", opts.files)
  end
  return repo
end

---Clone `src` (a FixtureRepo) into a new tmpdir; returns the clone.
function H.clone(src)
  local dir = H.tmpdir()
  H.git(dir, { "clone", "-q", src.root, "." })
  H.git(dir, { "config", "user.name", "Test" })
  H.git(dir, { "config", "user.email", "test@example.com" })
  return setmetatable({ root = dir }, Repo)
end

---Wait for `cond` (pumping the event loop); error with `msg` on timeout.
function H.wait(cond, msg, timeout)
  local ok = vim.wait(timeout or 5000, cond, 10)
  if not ok then
    error("timed out waiting for: " .. (msg or "condition"), 2)
  end
end

---Lines of a buffer.
function H.lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

---Find the first line matching a Lua pattern; returns its 1-based index.
function H.find_line(pattern, buf)
  for i, l in ipairs(H.lines(buf)) do
    if l:find(pattern) then
      return i
    end
  end
end

---Feed keys as typed and process them.
function H.feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mtx", false)
end

---Close every window but one and wipe all buffers.
function H.reset_ui()
  -- floats first: :only refuses to run from a floating window
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  pcall(vim.cmd, "silent! tabonly!")
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "silent! enew!")
  local keep = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= keep then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

---Capture vim.notify calls while `fn` runs (or until restore()).
function H.capture_notify()
  local log = {}
  local orig = vim.notify
  vim.notify = function(msg, level, opts)
    table.insert(log, { msg = msg, level = level, opts = opts or {} })
  end
  return log, function()
    vim.notify = orig
  end
end

return H
