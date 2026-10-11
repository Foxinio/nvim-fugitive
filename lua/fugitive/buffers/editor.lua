---@mod fugitive.buffers.editor Editor service (§5.2.1).
---
---Every git process we spawn gets GIT_EDITOR and GIT_SEQUENCE_EDITOR pointing
---at a small POSIX sh shim. For foreground processes the shim calls back into
---this Neovim (`--remote-expr`) and blocks until the edit is finished
---(`<state>.done`, exit 0) or abandoned (`<state>.abort`, exit 1). Background
---processes, and headless runs without a server, get no editor id: the shim
---then aborts immediately so the command fails loudly instead of hanging.

local M = {}

local SHIM = [=[
#!/bin/sh
# nvim-fugitive editor shim. See :help fugitive-editor.
if [ -z "$NVIM" ] || [ -z "$FUGITIVE_EDITOR_ID" ]; then
  echo "fugitive: aborting edit due to background operation" >&2
  exit 1
fi
file=$1
case $file in /*) ;; *) file=$PWD/$file ;; esac
state=$FUGITIVE_EDITOR_STATE.$$
esc() { printf '%s' "$1" | sed "s/'/''/g"; }
expr="v:lua.require'fugitive.buffers.editor'.request('$(esc "$FUGITIVE_EDITOR_ID")','$(esc "$file")','$(esc "$state")')"
res=$("${FUGITIVE_NVIM:-nvim}" --headless --server "$NVIM" --remote-expr "$expr" 2>&1)
if [ "$res" != "ok" ]; then
  echo "fugitive: could not open the editor in Neovim: $res" >&2
  exit 1
fi
while [ ! -e "$state.done" ] && [ ! -e "$state.abort" ]; do
  if [ -n "$FUGITIVE_NVIM_PID" ] && ! kill -0 "$FUGITIVE_NVIM_PID" 2>/dev/null; then
    echo "fugitive: Neovim went away" >&2
    exit 1
  fi
  sleep 0.05 2>/dev/null || sleep 1
done
if [ -e "$state.done" ]; then
  rm -f "$state.done"
  exit 0
fi
rm -f "$state.abort"
exit 1
]=]

---@class fugitive.EditorJob
---@field id string
---@field repo fugitive.Repo?
---@field job fugitive.Job?
---@field mods string? command modifiers of the originating :Git invocation
---@field on_cancel fun()? how to kill the process (overseer tasks, …)

---@class fugitive.EditorRequest
---@field id string
---@field file string
---@field state string
---@field key string queue key (repo git dir)
---@field buf integer?
---@field written boolean
---@field finished boolean

---@type table<string, fugitive.EditorJob>
M._jobs = {}
---@type table<string, fugitive.EditorRequest>
M._active = {}
---@type table<string, fugitive.EditorRequest[]>
M._queue = {}

local shim_path
local state_dir
local counter = 0

---Path of the shim script (written once per session).
---@return string
function M.shim()
  if shim_path and vim.uv.fs_stat(shim_path) then
    return shim_path
  end
  local dir = vim.fn.tempname() .. "-fugitive"
  vim.fn.mkdir(dir, "p")
  state_dir = dir
  shim_path = dir .. "/editor.sh"
  local fd = assert(io.open(shim_path, "wb"))
  fd:write(SHIM)
  fd:close()
  vim.uv.fs_chmod(shim_path, tonumber("755", 8))
  return shim_path
end

---Is a foreground editor possible in this session (a server to call back)?
function M.available()
  return vim.v.servername ~= nil and vim.v.servername ~= ""
end

---Environment for a git process.
---@param repo fugitive.Repo?
---@param foreground boolean?
---@return table<string, string|false> env, string? id
function M.env(repo, foreground)
  local shim = M.shim()
  local cmd = "sh " .. vim.fn.shellescape(shim)
  local env = {
    GIT_EDITOR = cmd,
    GIT_SEQUENCE_EDITOR = cmd,
    FUGITIVE_NVIM = vim.v.progpath,
    FUGITIVE_NVIM_PID = tostring(vim.fn.getpid()),
  }
  if foreground and M.available() then
    counter = counter + 1
    local id = string.format("%d-%d", vim.fn.getpid(), counter)
    env.NVIM = vim.v.servername
    env.FUGITIVE_EDITOR_ID = id
    env.FUGITIVE_EDITOR_STATE = state_dir .. "/" .. id
    env.GIT_MERGE_AUTOEDIT = "1"
    M._jobs[id] = { id = id, repo = repo }
    return env, id
  end
  env.NVIM = false
  env.FUGITIVE_EDITOR_ID = false
  env.FUGITIVE_EDITOR_STATE = false
  return env, nil
end

---Associate a spawned process with an editor id.
---@param id string
---@param fields {job?: fugitive.Job, mods?: string, on_cancel?: fun()}
function M.attach(id, fields)
  local j = M._jobs[id]
  if j then
    for k, v in pairs(fields) do
      j[k] = v
    end
  end
end

local function touch(path)
  local fd = io.open(path, "wb")
  if fd then
    fd:close()
  end
end

local function key_of(job)
  return job and job.repo and job.repo.git_dir or "global"
end

local pump

---@param req fugitive.EditorRequest
---@param done boolean
local function finish(req, done)
  if req.finished then
    return
  end
  req.finished = true
  touch(req.state .. (done and ".done" or ".abort"))
  if M._active[req.key] == req then
    M._active[req.key] = nil
  end
  vim.schedule(function()
    pump(req.key)
  end)
end

local function open_window(mods)
  local cfg = require("fugitive.config").get()
  local style = cfg.editor.window
  if mods and mods ~= "" and mods:match("%S") then
    return mods .. " split"
  elseif style == "vsplit" then
    return "vertical split"
  elseif style == "tab" then
    return "tab split"
  elseif style == "current" then
    return "edit"
  end
  return "split"
end

---@param req fugitive.EditorRequest
local function open(req)
  local job = M._jobs[req.id]
  local cmd = open_window(job and job.mods)
  local ok, err = pcall(function()
    if cmd == "edit" then
      vim.cmd("edit " .. vim.fn.fnameescape(req.file))
    else
      vim.cmd(cmd .. " " .. vim.fn.fnameescape(req.file))
    end
  end)
  if not ok then
    require("fugitive.ui.notify").error("could not open editor: " .. tostring(err))
    finish(req, false)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  req.buf = buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].fugitive_editor = req.id
  if job and job.repo then
    vim.b[buf].git_dir = job.repo.git_dir
  end
  -- Mark as modified so that `:x`/`ZZ` always write and a bare `:q` refuses:
  -- `:w` + close means "done", closing without writing means "abort".
  vim.bo[buf].modified = true
  local group = vim.api.nvim_create_augroup("fugitive_editor_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      req.written = true
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload", "BufDelete" }, {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      finish(req, req.written)
    end,
  })
  vim.api.nvim_exec_autocmds("User", { pattern = "FugitiveEditor", modeline = false, data = { buf = buf } })
end

pump = function(key)
  if M._active[key] then
    return
  end
  local q = M._queue[key]
  while q and #q > 0 do
    local req = table.remove(q, 1)
    if not req.finished then
      M._active[key] = req
      open(req)
      return
    end
  end
end

---Called by the shim through `--remote-expr`. Must return quickly.
---@param id string
---@param file string
---@param state string
---@return string
function M.request(id, file, state)
  local job = M._jobs[id]
  if not job then
    return "unknown editor id " .. tostring(id)
  end
  local req = { id = id, file = file, state = state, key = key_of(job), written = false, finished = false }
  M._queue[req.key] = M._queue[req.key] or {}
  table.insert(M._queue[req.key], req)
  vim.schedule(function()
    pump(req.key)
  end)
  return "ok"
end

---Abort every request of an editor id and close its buffer.
---@param id string
---@param reason? string
local function abort_requests(id, reason)
  local closed = false
  for key, req in pairs(M._active) do
    if req.id == id and not req.finished then
      finish(req, false)
      if req.buf and vim.api.nvim_buf_is_valid(req.buf) then
        pcall(vim.api.nvim_buf_delete, req.buf, { force = true })
      end
      M._active[key] = nil
      closed = true
    end
  end
  for _, q in pairs(M._queue) do
    for _, req in ipairs(q) do
      if req.id == id and not req.finished then
        finish(req, false)
      end
    end
  end
  if closed and reason then
    require("fugitive.ui.notify").warn(reason)
  end
end

---The git process of `id` exited (normally or killed): close any editor that
---is still open for it.
---@param id string
function M.job_exited(id)
  if not M._jobs[id] then
    return
  end
  abort_requests(id, "git process ended; editor closed")
  M._jobs[id] = nil
end

---Cancel the git process of `id`: abort its edits, kill the process group.
---@param id string
function M.cancel(id)
  local job = M._jobs[id]
  if not job then
    return
  end
  abort_requests(id, "git command cancelled; editor closed")
  if job.on_cancel then
    pcall(job.on_cancel)
  elseif job.job then
    job.job:kill("sigterm")
  end
end

---Editor id of a buffer, if it is an editor buffer.
---@param buf? integer
---@return string?
function M.buf_id(buf)
  local ok, id = pcall(vim.api.nvim_buf_get_var, buf or 0, "fugitive_editor")
  return ok and id or nil
end

---Pending (open or queued) request count, for tests and statuslines.
function M.pending()
  local n = 0
  for _, req in pairs(M._active) do
    if not req.finished then
      n = n + 1
    end
  end
  for _, q in pairs(M._queue) do
    for _, req in ipairs(q) do
      if not req.finished then
        n = n + 1
      end
    end
  end
  return n
end

---Abort everything (VimLeavePre): no shim may be left waiting.
function M.abort_all()
  for id in pairs(M._jobs) do
    M.cancel(id)
  end
end

return M
