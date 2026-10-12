---@mod nvim-fugitive.git.exec The single git execution layer.
---
---Every git invocation of the plugin goes through this module. It adds the
---common flags (`--no-optional-locks`, `core.quotepath=false`), a consistent
---working directory, a non-interactive environment, and – for foreground
---commands – the editor service environment (§5.2.1).
---
---The actual process spawning is done by a replaceable runner so tests can
---inject a fake one (`exec.set_runner`).

local M = {}

---@class fugitive.ExecResult
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string
---@field cmd string[]

---@class fugitive.ExecOpts
---@field cwd? string working directory (defaults to the repo work tree)
---@field repo? fugitive.Repo
---@field env? table<string, string|false> extra environment (false unsets)
---@field stdin? string|boolean
---@field editor? boolean foreground command: wire up the editor service
---@field interactive? boolean allow terminal prompts (credential helpers, …)
---@field raw? boolean do not add the common flags
---@field on_stdout? fun(err: string?, data: string?)
---@field on_stderr? fun(err: string?, data: string?)
---@field detach? boolean run in its own process group (cancellable as a group)
---@field mods? string command modifiers, used to place the editor window

M.git = "git"

---Flags put in front of every git command.
M.common_flags = { "--no-optional-locks", "-c", "core.quotepath=false", "-c", "color.ui=never" }

---`-c key=value` flags that git would otherwise let the environment override;
---we translate them into the corresponding variables, as upstream does.
local config_env = {
  ["sequence.editor"] = "GIT_SEQUENCE_EDITOR",
  ["core.editor"] = "GIT_EDITOR",
  ["core.askpass"] = "GIT_ASKPASS",
}

---@alias fugitive.Runner fun(cmd: string[], opts: table, on_exit: fun(res: vim.SystemCompleted)): table

---@type fugitive.Runner
local function system_runner(cmd, opts, on_exit)
  return vim.system(cmd, opts, on_exit)
end

---@type fugitive.Runner
local runner = system_runner

---Replace the process runner (tests). Pass nil to restore the default.
---@param fn? fugitive.Runner
function M.set_runner(fn)
  runner = fn or system_runner
end

---Build the argv and vim.system options for a git invocation.
---@param args string[]
---@param opts? fugitive.ExecOpts
---@return string[] cmd, table sysopts, string? editor_id
function M.build(args, opts)
  opts = opts or {}
  local repo = opts.repo
  local cmd = { M.git }
  ---@type table<string, string|false>
  local env = {
    GIT_TERMINAL_PROMPT = opts.interactive and nil or "0",
    GIT_PAGER = "cat",
    PAGER = "cat",
    NO_COLOR = "1",
  }
  -- Every process gets the editor shim; without an editor id (background,
  -- headless) it aborts the edit loudly instead of hanging (§5.2.1).
  local editor_env, editor_id = require("nvim-fugitive.buffers.editor").env(repo, opts.editor)
  for k, v in pairs(editor_env) do
    env[k] = v
  end
  if not opts.raw then
    vim.list_extend(cmd, M.common_flags)
  end
  local cwd = opts.cwd
  if repo then
    if repo.worktree then
      cwd = cwd or repo.worktree
      if repo.explicit then
        -- external git dir (dotfiles, core.worktree): name both
        vim.list_extend(cmd, { "--git-dir=" .. repo.git_dir, "--work-tree=" .. repo.worktree })
      end
    else
      table.insert(cmd, "--git-dir=" .. repo.git_dir)
      cwd = cwd or repo.git_dir
    end
  end
  -- never let an inherited repository selection leak into our children
  for _, var in ipairs({
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_PREFIX",
  }) do
    if env[var] == nil then
      env[var] = false
    end
  end
  -- translate -c sequence.editor=… etc. into env, keep everything else
  local i, rest = 1, {}
  while i <= #args do
    local a = args[i]
    if a == "-c" and args[i + 1] then
      local key, val = args[i + 1]:match("^([^=]+)=?(.*)$")
      local var = key and config_env[key:lower()]
      if var then
        env[var] = val
      else
        vim.list_extend(rest, { a, args[i + 1] })
      end
      i = i + 2
    else
      table.insert(rest, a)
      i = i + 1
    end
  end
  if opts.editor then
    vim.list_extend(cmd, { "-c", "advice.waitingForEditor=false" })
  end
  vim.list_extend(cmd, rest)
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  local sysenv = {}
  for k, v in pairs(env) do
    if v ~= false then
      sysenv[k] = v
    end
  end
  local sysopts = {
    cwd = cwd,
    env = sysenv,
    text = true,
    stdin = opts.stdin,
    stdout = opts.on_stdout,
    stderr = opts.on_stderr,
    detach = opts.detach or (opts.editor and true) or nil,
  }
  -- vim.system cannot unset inherited variables; do it via clear_env on a copy.
  local unset = {}
  for k, v in pairs(env) do
    if v == false and vim.env[k] ~= nil then
      unset[k] = true
    end
  end
  if next(unset) then
    local full = vim.fn.environ()
    for k in pairs(unset) do
      full[k] = nil
    end
    sysopts.env = vim.tbl_extend("force", full, sysenv)
    sysopts.clear_env = true
  end
  return cmd, sysopts, editor_id
end

---@param res vim.SystemCompleted
---@param cmd string[]
---@return fugitive.ExecResult
local function normalize(res, cmd)
  return {
    code = res.code or -1,
    signal = res.signal or 0,
    stdout = res.stdout or "",
    stderr = res.stderr or "",
    cmd = cmd,
  }
end

---@class fugitive.Job
---@field pid integer?
---@field handle vim.SystemObj?
---@field editor_id string? editor service id of a foreground process
---@field cmd string[]
---@field done boolean
---@field result fugitive.ExecResult?
---@field kill fun(self: fugitive.Job, signal?: integer|string)
---@field wait fun(self: fugitive.Job, timeout?: integer): fugitive.ExecResult

---Run git asynchronously. `cb` is called on the main loop.
---@param args string[]
---@param opts? fugitive.ExecOpts
---@param cb? fun(res: fugitive.ExecResult)
---@return fugitive.Job
function M.run(args, opts, cb)
  local cmd, sysopts, editor_id = M.build(args, opts)
  ---@type fugitive.Job
  ---@diagnostic disable-next-line: missing-fields
  local job = { cmd = cmd, done = false, editor_id = editor_id } ---@type fugitive.Job
  local ok, handle = pcall(runner, cmd, sysopts, function(res)
    local r = normalize(res, cmd)
    vim.schedule(function()
      job.done = true
      job.result = r
      if editor_id then
        require("nvim-fugitive.buffers.editor").job_exited(editor_id)
      end
      if cb then
        cb(r)
      end
    end)
  end)
  if not ok then
    local r = { code = -1, signal = 0, stdout = "", stderr = tostring(handle), cmd = cmd }
    job.done = true
    job.result = r
    if cb then
      vim.schedule(function()
        cb(r)
      end)
    end
    job.kill = function() end
    job.wait = function()
      return r
    end
    return job
  end
  job.pid = handle.pid
  job.handle = handle
  if editor_id then
    require("nvim-fugitive.buffers.editor").attach(
      editor_id,
      { job = job, mods = opts and opts.mods }
    )
  end
  function job:kill(signal)
    signal = signal or "sigterm"
    if self.done then
      return
    end
    if sysopts.detach and self.pid then
      -- whole process group: git plus anything it spawned (hooks, editor shim)
      pcall(vim.uv.kill, -self.pid, signal)
    end
    pcall(handle.kill, handle, signal)
  end
  function job:wait(timeout)
    if not self.done then
      vim.wait(timeout or 60000, function()
        return self.done
      end, 10)
    end
    return self.result
  end
  return job
end

---Run git synchronously. Only for places where Vim semantics require it
---(BufReadCmd, BufWriteCmd, completion, building the summary snapshot).
---@param args string[]
---@param opts? fugitive.ExecOpts
---@return fugitive.ExecResult
function M.sync(args, opts)
  local cmd, sysopts = M.build(args, opts)
  local ok, handle = pcall(runner, cmd, sysopts, nil)
  if not ok then
    return { code = -1, signal = 0, stdout = "", stderr = tostring(handle), cmd = cmd }
  end
  return normalize(handle:wait(), cmd)
end

---Synchronous helper: stdout split into lines (trailing newline dropped), or
---nil plus the result on failure.
---@param args string[]
---@param opts? fugitive.ExecOpts
---@return string[]? lines, fugitive.ExecResult res
function M.lines(args, opts)
  local res = M.sync(args, opts)
  if res.code ~= 0 then
    return nil, res
  end
  local out = res.stdout:gsub("\n$", "")
  if out == "" then
    return {}, res
  end
  return vim.split(out, "\n", { plain = true }), res
end

---Synchronous helper: trimmed stdout or nil.
---@param args string[]
---@param opts? fugitive.ExecOpts
---@return string?
function M.chomp(args, opts)
  local res = M.sync(args, opts)
  if res.code ~= 0 then
    return nil
  end
  return (res.stdout:gsub("\n+$", ""))
end

---Coroutine-friendly variant of `run` (plenary.async). Must be called from
---inside `require("plenary.async").run(...)`.
---@param args string[]
---@param opts? fugitive.ExecOpts
---@return fugitive.ExecResult
function M.await(args, opts)
  local async = require("plenary.async")
  M._await = M._await or async.wrap(function(a, o, cb)
    M.run(a, o, cb)
  end, 3)
  return M._await(args, opts)
end

---Format a result's error for display: stderr, or stdout, plus the exit code.
---@param res fugitive.ExecResult
---@return string
function M.error_text(res)
  local text = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  if text == "" then
    text = "git " .. table.concat(res.cmd or {}, " ", 2)
  end
  return text
end

return M
