---@mod fugitive.integrations.overseer Long-running commands (§5.2.2).
---
---Network/slow subcommands run as overseer.nvim tasks when it is installed
---(visible in the task list, cancellable, output in the task buffer). The
---fallback is our own async job with progress and completion notifications.
---Either way the editor service stays attached (e.g. a `pull` that needs a
---merge commit message), and the summary/gitsigns refresh afterwards.

local notify = require("fugitive.ui.notify")
local output = require("fugitive.ui.output")

local M = {}

---@type table<fugitive.Job, boolean>
M._running = {}

---@return table? overseer
function M.get()
  if not require("fugitive.config").get().integrations.overseer then
    return nil
  end
  local ok, overseer = pcall(require, "overseer")
  if ok and type(overseer) == "table" and overseer.new_task then
    return overseer
  end
  return nil
end

local function label(args)
  return "git " .. table.concat(args, " ")
end

local function task_output(task)
  local ok, bufnr = pcall(function()
    return task:get_bufnr()
  end)
  if not ok or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

---@param repo fugitive.Repo
---@param args string[]
---@param opts? {mods?: string, on_done?: fun(res: fugitive.ExecResult)}
function M.run(repo, args, opts)
  opts = opts or {}
  local overseer = M.get()
  if not overseer then
    return M.run_fallback(repo, args, opts)
  end
  local exec = require("fugitive.git.exec")
  local cmd, sysopts, editor_id = exec.build(args, { repo = repo, editor = true, mods = opts.mods })
  local entry = output.start(cmd, sysopts.cwd)
  local task = overseer.new_task({
    name = label(args),
    cmd = cmd,
    cwd = sysopts.cwd,
    env = sysopts.env,
    components = { "default" },
    metadata = { fugitive = true, git_dir = repo.git_dir },
  })
  if editor_id then
    require("fugitive.buffers.editor").attach(editor_id, {
      mods = opts.mods,
      on_cancel = function()
        pcall(task.stop, task)
      end,
    })
  end
  task:subscribe("on_complete", function(t, status)
    vim.schedule(function()
      if editor_id then
        require("fugitive.buffers.editor").job_exited(editor_id)
      end
      local ok = status == "SUCCESS"
      local res = {
        code = ok and 0 or (t.exit_code or 1),
        signal = 0,
        stdout = task_output(t),
        stderr = "",
        cmd = cmd,
      }
      output.finish(entry, res)
      if status == "CANCELED" then
        notify.warn(label(args) .. ": cancelled")
      elseif ok then
        notify.info(notify.truncate(label(args) .. ": done\n" .. res.stdout, {}))
      else
        notify.error(
          notify.truncate(
            label(args) .. " failed\n" .. res.stdout,
            { code = res.code, is_error = true }
          )
        )
      end
      require("fugitive").changed(repo)
      if opts.on_done then
        opts.on_done(res)
      end
    end)
    return false -- unsubscribe
  end)
  task:start()
  return task
end

---Our own runner when overseer is absent.
---@param repo fugitive.Repo
---@param args string[]
---@param opts {mods?: string, on_done?: fun(res: fugitive.ExecResult)}
---@return fugitive.Job
function M.run_fallback(repo, args, opts)
  notify.info(label(args) .. ": running…")
  local entry
  local job
  job = repo:run(args, { editor = true, mods = opts.mods, detach = true }, function(res)
    M._running[job] = nil
    output.finish(entry, res)
    if res.code == 0 then
      local text = vim.trim(res.stdout .. "\n" .. res.stderr)
      notify.info(
        notify.truncate(label(args) .. ": done" .. (text ~= "" and ("\n" .. text) or ""), {})
      )
    elseif res.signal ~= 0 then
      notify.warn(label(args) .. ": cancelled")
    else
      notify.error(
        notify.truncate(
          label(args) .. " failed\n" .. require("fugitive.git.exec").error_text(res),
          {
            code = res.code,
            is_error = true,
          }
        )
      )
    end
    require("fugitive").changed(repo)
    if opts.on_done then
      opts.on_done(res)
    end
  end)
  entry = output.start(job.cmd, repo.worktree)
  M._running[job] = true
  return job
end

---Cancel every running fallback job.
function M.cancel_all()
  for job in pairs(M._running) do
    if job.editor_id then
      require("fugitive.buffers.editor").cancel(job.editor_id)
    end
    job:kill("sigterm")
  end
end

return M
