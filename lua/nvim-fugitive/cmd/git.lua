---@mod nvim-fugitive.cmd.git The `:Git` dispatcher.
---
---`:Git` with no arguments opens the summary buffer. Otherwise the argument
---list is classified (fugitive.cmd.routes) and sent down one of the routes:
---notify, float, task (overseer), terminal or editor-first. `:Git!` runs in
---the background, where the editor shim refuses to edit.

local routes = require("nvim-fugitive.cmd.routes")
local notify = require("nvim-fugitive.ui.notify")
local output = require("nvim-fugitive.ui.output")

local M = {}

---Split a command line into words: whitespace separated, with '…', "…"
---and backslash escapes.
---@param str string
---@return string[]
function M.split_args(str)
  local args, cur, i, n = {}, nil, 1, #str
  local quote
  while i <= n do
    local c = str:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      elseif c == "\\" and quote == '"' and i < n then
        i = i + 1
        cur = cur .. str:sub(i, i)
      else
        cur = cur .. c
      end
    elseif c == "'" or c == '"' then
      quote = c
      cur = cur or ""
    elseif c == "\\" and i < n then
      i = i + 1
      cur = (cur or "") .. str:sub(i, i)
    elseif c:match("%s") then
      if cur then
        table.insert(args, cur)
        cur = nil
      end
    else
      cur = (cur or "") .. c
    end
    i = i + 1
  end
  if cur then
    table.insert(args, cur)
  end
  return args
end

---The current buffer's path as git sees it: repo-relative work-tree path, or
---the object name for fugitive:// buffers.
---@param repo fugitive.Repo
---@param buf integer
---@return string?
function M.buf_path(repo, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local obj = require("nvim-fugitive.object").parse(name)
  if obj then
    return obj.path and require("nvim-fugitive.object").git_name(obj) or obj.commit
  end
  return repo:rel(name)
end

---Expand `%` and `#` words.
---@param args string[]
---@param repo fugitive.Repo
---@return string[]
function M.expand(args, repo)
  local out = {}
  for _, a in ipairs(args) do
    if a == "%" then
      table.insert(out, M.buf_path(repo, vim.api.nvim_get_current_buf()) or a)
    elseif a == "#" then
      local alt = vim.fn.bufnr("#")
      table.insert(out, alt > 0 and M.buf_path(repo, alt) or a)
    else
      table.insert(out, a)
    end
  end
  return out
end

---Expansion of a git alias (nil for shell aliases or unknown names).
---@param repo fugitive.Repo
---@return fun(name: string): string[]?
function M.alias_resolver(repo)
  return function(name)
    local value = repo:config("alias." .. name)
    if not value or value:sub(1, 1) == "!" then
      return nil
    end
    return M.split_args(value)
  end
end

---Notify-style completion of a finished command.
---@param repo fugitive.Repo
---@param res fugitive.ExecResult
local function finish_notify(repo, res, entry)
  output.finish(entry, res)
  notify.result(res)
  require("nvim-fugitive").changed(repo)
end

---Run a foreground command and notify its output (notify + editor routes).
---@param repo fugitive.Repo
---@param args string[]
---@param opts {mods?: string, on_done?: fun(res: fugitive.ExecResult)}
---@return fugitive.Job
function M.run_notify(repo, args, opts)
  local job
  local entry
  job = repo:run(args, { editor = true, mods = opts.mods }, function(res)
    finish_notify(repo, res, entry)
    if opts.on_done then
      opts.on_done(res)
    end
  end)
  entry = output.start(job.cmd, repo.worktree)
  return job
end

---Run in the background (`:Git!`): no editor, notify when done.
---@param repo fugitive.Repo
---@param args string[]
---@param opts table
---@return fugitive.Job
function M.run_background(repo, args, opts)
  local entry
  local job = repo:run(args, { editor = false }, function(res)
    finish_notify(repo, res, entry)
    if opts.on_done then
      opts.on_done(res)
    end
  end)
  entry = output.start(job.cmd, repo.worktree)
  return job
end

local pager_filetypes = {
  log = "git",
  show = "git",
  diff = "git",
  reflog = "git",
  whatchanged = "git",
  ["range-diff"] = "git",
  stash = "git",
  grep = "git",
  blame = "fugitiveblame",
}

---Run a pager-type command; stream its output into the float (or a split
---with window modifiers). `<C-c>` in the pager cancels it.
---@param repo fugitive.Repo
---@param args string[]
---@param opts {mods?: string, sub?: string}
---@return fugitive.Job
function M.run_float(repo, args, opts)
  local float = require("nvim-fugitive.ui.float")
  local buf
  local entry
  local pending = {}
  local scheduled = false
  local function flush()
    scheduled = false
    if #pending > 0 and buf then
      float.append(buf, table.concat(pending))
      pending = {}
    end
  end
  local env = {}
  if vim.fn.executable("col") == 1 then
    env.MANPAGER = "col -b"
  else
    env.MANPAGER = "cat"
  end
  local job
  job = repo:run(args, {
    editor = true,
    mods = opts.mods,
    env = env,
    on_stdout = function(_, data)
      if data then
        table.insert(pending, data)
        if not scheduled then
          scheduled = true
          vim.schedule(flush)
        end
      end
    end,
  }, function(res)
    flush()
    -- the streamed text is authoritative; vim.system returns nil stdout
    -- when a callback consumed it
    if res.stdout == "" and buf and vim.api.nvim_buf_is_valid(buf) then
      res.stdout = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    output.finish(entry, res)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].fugitive_running = false
      -- drop the trailing empty line left by the final newline
      local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]
      if last == "" and vim.api.nvim_buf_line_count(buf) > 1 then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, -2, -1, false, {})
        vim.bo[buf].modifiable = false
        vim.bo[buf].modified = false
      end
    end
    if res.code ~= 0 then
      local text = vim.trim(res.stderr)
      local lines = vim.split(text, "\n", { plain = true })
      local max = require("nvim-fugitive.config").get().notify.max_lines
      local empty = buf
        and vim.api.nvim_buf_is_valid(buf)
        and vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "")) == ""
      if empty and #lines > max then
        -- long command errors go to the float
        float.set(buf, vim.list_extend({ "# exit code " .. res.code }, lines))
      else
        if empty and buf and vim.api.nvim_buf_is_valid(buf) then
          for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
        notify.result(res)
      end
    elseif
      buf
      and vim.api.nvim_buf_is_valid(buf)
      and vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "")) == ""
    then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_close, win, true)
      end
      notify.info("git " .. table.concat(args, " ") .. ": no output")
    end
  end)
  entry = output.start(job.cmd, repo.worktree)
  buf = float.show({}, {
    title = "git " .. table.concat(args, " "),
    mods = opts.mods,
    filetype = pager_filetypes[opts.sub or ""],
    on_cancel = function()
      if job.editor_id then
        require("nvim-fugitive.buffers.editor").cancel(job.editor_id)
      end
      job:kill("sigterm")
      notify.warn("git " .. table.concat(args, " ") .. ": cancelled")
    end,
  })
  vim.b[buf].fugitive_running = true
  vim.b[buf].git_dir = repo.git_dir
  require("nvim-fugitive.buffers.reader").setup_pager(buf, repo)
  return job
end

---Dispatch `:Git {args}`.
---@param args string[]
---@param opts? {bang?: boolean, mods?: string, buf?: integer, repo?: fugitive.Repo, skip_picker?: boolean, on_done?: fun(res: fugitive.ExecResult)}
---@return fugitive.Job|integer|nil
function M.run(args, opts)
  opts = opts or {}
  local repo = opts.repo or require("nvim-fugitive.git.repo").require(opts.buf)
  if not repo then
    return nil
  end
  if #args == 0 then
    return require("nvim-fugitive.buffers.summary").open(repo, { mods = opts.mods })
  end
  args = M.expand(args, repo)

  -- fugitive's own pseudo subcommands
  if args[1] == "restore-discard" then
    return require("nvim-fugitive.discard").restore_latest(repo, args[2])
  end

  if not opts.bang and not opts.skip_picker then
    local trigger = routes.picker_trigger(args)
    if trigger then
      return require("nvim-fugitive.integrations.telescope").input(repo, trigger, function(ref)
        local full = vim.list_extend(vim.deepcopy(args), { ref })
        M.run(full, vim.tbl_extend("force", opts, { repo = repo, skip_picker = true }))
      end)
    end
  end

  if opts.bang then
    return M.run_background(repo, args, { on_done = opts.on_done })
  end

  local cls = routes.classify(args, { aliases = M.alias_resolver(repo) })
  if cls.route == "float" then
    return M.run_float(repo, args, { mods = opts.mods, sub = cls.sub })
  elseif cls.route == "task" then
    return require("nvim-fugitive.integrations.overseer").run(
      repo,
      args,
      { mods = opts.mods, on_done = opts.on_done }
    )
  elseif cls.route == "terminal" then
    return require("nvim-fugitive.ui.terminal").run(repo, args, {
      mods = opts.mods,
      on_exit = function()
        require("nvim-fugitive").changed(repo)
      end,
    })
  else
    -- "notify" and "editor": both run in the foreground with the editor
    -- service; editor-first commands simply report once the editor closed
    return M.run_notify(repo, args, { mods = opts.mods, on_done = opts.on_done })
  end
end

---Split a command line at the first unquoted, unescaped `|` (upstream
---lets `:Git` chain commands that way; `\|` is a literal bar).
---@param str string
---@return string first, string? rest
function M.split_bar(str)
  local quote
  local i = 1
  while i <= #str do
    local c = str:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif quote then
      if c == quote then
        quote = nil
      end
    elseif c == "'" or c == '"' then
      quote = c
    elseif c == "|" then
      return str:sub(1, i - 1), vim.trim(str:sub(i + 1))
    end
    i = i + 1
  end
  return str, nil
end

---Entry point of the :Git user command.
---@param cmd table nvim_create_user_command callback argument
function M.command(cmd)
  local first, rest = M.split_bar(cmd.args or "")
  local args = M.split_args(first)
  local on_done
  if rest and rest ~= "" then
    on_done = function(res)
      if res.code == 0 then
        vim.cmd(rest)
      end
    end
  end
  local ok, job = pcall(M.run, args, { bang = cmd.bang, mods = cmd.mods, on_done = on_done })
  if not ok then
    notify.error(tostring(job))
    return
  end
  -- routes without completion callbacks: run the rest right away
  if rest and rest ~= "" and (type(job) ~= "table" or not job.cmd) then
    vim.cmd(rest)
  end
end

return M
