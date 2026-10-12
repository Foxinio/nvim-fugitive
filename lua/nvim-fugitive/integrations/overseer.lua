---@mod nvim-fugitive.integrations.overseer Long-running commands (§5.2.2).
---
---Network/slow subcommands run as overseer.nvim tasks when it is installed
---(visible in the task list, cancellable, output in the task buffer). The
---fallback is our own async job with progress and completion notifications.
---Either way the editor service stays attached (e.g. a `pull` that needs a
---merge commit message), and the summary/gitsigns refresh afterwards.

local notify = require("nvim-fugitive.ui.notify")
local output = require("nvim-fugitive.ui.output")

local M = {}

---@type table<fugitive.Job, boolean>
M._running = {}

---@return table? overseer
function M.get()
  if not require("nvim-fugitive.config").get().integrations.overseer then
    return nil
  end
  local ok, overseer = pcall(require, "overseer")
  if ok and type(overseer) == "table" and overseer.new_task then
    return overseer
  end
  return nil
end

---Parse failed push/fetch/pull output into quickfix items: rejected refs,
---errors, and `remote: path:line: message` lines from server hooks.
---@param repo fugitive.Repo
---@param text string
---@return table[]
function M.parse_errors(repo, text)
  local items = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local path, lnum, msg = line:match("^remote:%s+([^%s:]+):(%d+):%d*:?%s*(.*)$")
    if path and vim.uv.fs_stat(repo:abs(path)) then
      table.insert(
        items,
        { filename = repo:abs(path), lnum = tonumber(lnum), text = msg, type = "E" }
      )
    else
      local rejected = line:match("^%s*!%s+(%[.-%].*)$")
      if rejected then
        table.insert(items, { text = rejected, type = "E", valid = 0 })
      else
        local err = line:match("^error: (.*)$") or line:match("^fatal: (.*)$")
        if err then
          table.insert(items, { text = err, type = "E", valid = 0 })
        end
      end
    end
  end
  return items
end

local quickfix_subcommands = { push = true, fetch = true, pull = true }

---After a failed push/fetch/pull: errors into quickfix.
---@return boolean filled
local function errors_to_quickfix(repo, args, text)
  local sub = require("nvim-fugitive.cmd.routes").parse(args).sub
  if not sub or not quickfix_subcommands[sub] then
    return false
  end
  local items = M.parse_errors(repo, text)
  if #items == 0 then
    return false
  end
  vim.fn.setqflist({}, " ", { title = "git " .. table.concat(args, " "), items = items })
  return true
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
  local exec = require("nvim-fugitive.git.exec")
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
    require("nvim-fugitive.buffers.editor").attach(editor_id, {
      mods = opts.mods,
      on_cancel = function()
        pcall(task.stop, task)
      end,
    })
  end
  task:subscribe("on_complete", function(t, status)
    vim.schedule(function()
      if editor_id then
        require("nvim-fugitive.buffers.editor").job_exited(editor_id)
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
        local qf = errors_to_quickfix(repo, args, res.stdout)
        notify.error(
          notify.truncate(
            label(args) .. " failed" .. (qf and " (errors in :copen)" or "") .. "\n" .. res.stdout,
            { code = res.code, is_error = true }
          )
        )
      end
      require("nvim-fugitive").changed(repo)
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
      local qf = errors_to_quickfix(repo, args, res.stdout .. "\n" .. res.stderr)
      notify.error(
        notify.truncate(
          label(args)
            .. " failed"
            .. (qf and " (errors in :copen)" or "")
            .. "\n"
            .. require("nvim-fugitive.git.exec").error_text(res),
          {
            code = res.code,
            is_error = true,
          }
        )
      )
    end
    require("nvim-fugitive").changed(repo)
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
      require("nvim-fugitive.buffers.editor").cancel(job.editor_id)
    end
    job:kill("sigterm")
  end
end

return M
