---@mod fugitive.ui.terminal Interactive commands in a :terminal split (F3).

local M = {}

---Run an interactive git command (`add -p`, `rebase -i` with a terminal
---editor, …) in a terminal split. The buffer closes when git exits 0.
---@param repo fugitive.Repo
---@param args string[]
---@param opts? {mods?: string, on_exit?: fun(code: integer)}
---@return integer buf
function M.run(repo, args, opts)
  opts = opts or {}
  local exec = require("fugitive.git.exec")
  local cmd, sysopts =
    exec.build(args, { repo = repo, editor = true, interactive = true, mods = opts.mods })
  -- a terminal is a real tty: let git page/prompt as it would normally, but
  -- keep our editor so commit messages still open in this Neovim
  sysopts.env.GIT_PAGER = nil
  sysopts.env.PAGER = nil
  sysopts.env.NO_COLOR = nil
  sysopts.env.GIT_TERMINAL_PROMPT = nil
  local mods = opts.mods and opts.mods:match("%S") and opts.mods or "botright"
  vim.cmd(mods .. " new")
  local buf = vim.api.nvim_get_current_buf()
  local editor_id = sysopts.env.FUGITIVE_EDITOR_ID
  local entry = require("fugitive.ui.output").start(cmd, sysopts.cwd)
  entry.stdout = "(interactive terminal session)"
  local job = vim.fn.jobstart(cmd, {
    term = true,
    cwd = sysopts.cwd,
    env = sysopts.env,
    clear_env = sysopts.clear_env,
    on_exit = function(_, code)
      vim.schedule(function()
        entry.code = code
        entry.running = false
        if editor_id then
          require("fugitive.buffers.editor").job_exited(editor_id)
        end
        if code == 0 and vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        if opts.on_exit then
          opts.on_exit(code)
        end
      end)
    end,
  })
  if editor_id then
    require("fugitive.buffers.editor").attach(editor_id, {
      mods = opts.mods,
      on_cancel = function()
        pcall(vim.fn.jobstop, job)
      end,
    })
  end
  vim.b[buf].git_dir = repo.git_dir
  vim.cmd("startinsert")
  return buf
end

return M
