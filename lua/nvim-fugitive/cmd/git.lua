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

-- blame options that take the next argument as their value
local blame_with_arg = {
  ["-L"] = true,
  ["-S"] = true,
  ["--contents"] = true,
  ["--date"] = true,
  ["--encoding"] = true,
  ["--ignore-rev"] = true,
  ["--ignore-revs-file"] = true,
}

---`:Git blame -L 1,5` or a blame routed to a pager names no file: blame the
---current buffer's like upstream, instead of letting git print its usage.
---@param repo fugitive.Repo
---@param args string[] full `:Git` arguments
---@param rest string[] the arguments after `blame`
---@return string[]
function M.blame_file_args(repo, args, rest)
  if vim.tbl_contains(rest, "--") then
    return args
  end
  local positionals = routes.positionals(rest, blame_with_arg)
  for _, p in ipairs(positionals) do
    local abs = p:match("^/") and p or (repo.worktree and repo.worktree .. "/" .. p)
    if (abs and vim.uv.fs_stat(abs)) or vim.uv.fs_stat(p) then
      return args
    end
  end
  local buf = vim.api.nvim_get_current_buf()
  local object = require("nvim-fugitive.object")
  local obj = object.parse(vim.api.nvim_buf_get_name(buf))
  local out = vim.deepcopy(args)
  if obj then
    if not obj.path or obj.path == "" then
      return args
    end
    -- a blob at a commit: blame at that commit unless a revision was given
    if #positionals == 0 and obj.commit:match("^%x+$") and #obj.commit >= 40 then
      table.insert(out, obj.commit)
    end
    vim.list_extend(out, { "--", obj.path })
    return out
  end
  local path = M.buf_path(repo, buf)
  if not path or path == "" then
    return args
  end
  vim.list_extend(out, { "--", path })
  return out
end

---Expansion of a git alias: its words, `{}` for a shell (`!`) alias, nil
---when `name` is not an alias.
---@param repo fugitive.Repo
---@return fun(name: string): string[]?
function M.alias_resolver(repo)
  return function(name)
    local value = repo:config("alias." .. name)
    -- git ignores aliases that would hide one of its own commands
    if not value or vim.tbl_contains(require("nvim-fugitive.cmd.complete").commands(), name) then
      return nil
    end
    if value:sub(1, 1) == "!" then
      return {}
    end
    return M.split_args(value)
  end
end

---Is `name` something git can run: a builtin, a `git-<name>` on PATH or an
---alias? (Unknown when git cannot list its commands.)
---@param repo fugitive.Repo
---@param name string
---@return boolean
function M.is_command(repo, name)
  if routes.subcommands[name] or repo:config("alias." .. name) then
    return true
  end
  local commands = require("nvim-fugitive.cmd.complete").commands()
  return #commands == 0 or vim.tbl_contains(commands, name)
end

---Notify-style completion of a finished command.
---@param repo fugitive.Repo
---@param res fugitive.ExecResult
---@param significant boolean notify a success too (errors always notify)
local function finish_notify(repo, res, entry, significant)
  output.finish(entry, res)
  -- a routine command stays silent, but not when it printed something: the
  -- output of `:Git status`, `:Git rev-parse HEAD`, an alias, … is the point
  local printed = vim.trim((res.stdout or "") .. (res.stderr or "")) ~= ""
  notify.result(res, { significant = significant or printed })
  require("nvim-fugitive").changed(repo)
end

---Run a foreground command and notify its output (notify + editor routes).
---@param repo fugitive.Repo
---@param args string[]
---@param opts {mods?: string, on_done?: fun(res: fugitive.ExecResult), significant?: boolean}
---@return fugitive.Job
function M.run_notify(repo, args, opts)
  local job
  local entry
  -- `--no-pager` explicitly asks for the output as a notification
  local significant = opts.significant or routes.is_significant(args) or routes.parse(args).no_pager
  job = repo:run(args, { editor = true, mods = opts.mods }, function(res)
    finish_notify(repo, res, entry, significant)
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
  -- a background run was asked for explicitly: always report its result
  local job = repo:run(args, { editor = false }, function(res)
    finish_notify(repo, res, entry, true)
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
---@param opts {mods?: string, sub?: string, window?: string}
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
          float.dismiss(buf)
        end
        notify.result(res)
      end
    elseif
      buf
      and vim.api.nvim_buf_is_valid(buf)
      and vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "")) == ""
    then
      -- nothing to page: just close the empty float
      float.dismiss(buf)
    end
  end)
  entry = output.start(job.cmd, repo.worktree)
  buf = float.show({}, {
    title = "git " .. table.concat(args, " "),
    mods = opts.mods,
    window = opts.window,
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
  require("nvim-fugitive.api").event("FugitivePager", buf)
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

  -- subcommands fugitive implements itself (! = do not jump, like upstream)
  if args[1] == "difftool" or args[1] == "mergetool" then
    local dt = require("nvim-fugitive.cmd.difftool")
    return dt[args[1]](repo, vim.list_slice(args, 2), { bang = opts.bang })
  end
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

  local sub = routes.parse(args).sub
  if sub and not M.is_command(repo, sub) then
    notify.error(string.format("'%s' is not a git command or a defined alias (alias.%s)", sub, sub))
    return nil
  end

  if opts.bang then
    return M.run_background(repo, args, { on_done = opts.on_done })
  end

  local cls = routes.classify(args, { aliases = M.alias_resolver(repo) })
  if cls.route == "blame" then
    return require("nvim-fugitive.buffers.blame").open({
      flags = cls.parsed.rest,
      mods = opts.mods,
      repo = repo,
    })
  elseif routes.is_pager(cls.route) then
    if cls.sub == "blame" then
      args = M.blame_file_args(repo, args, cls.parsed.rest)
    end
    return M.run_float(repo, args, { mods = opts.mods, sub = cls.sub, window = cls.route })
  elseif cls.route == "overseer" then
    return require("nvim-fugitive.integrations.overseer").run(
      repo,
      args,
      { mods = opts.mods, on_done = opts.on_done }
    )
  elseif cls.route == "term" then
    return require("nvim-fugitive.ui.terminal").run(repo, args, {
      mods = opts.mods,
      on_exit = function()
        require("nvim-fugitive").changed(repo)
      end,
    })
  else
    -- "notification" and "editor": both run in the foreground with the
    -- editor service; editor-first commands report once the editor closed.
    -- A command the user routed here explicitly always shows its output.
    return M.run_notify(
      repo,
      args,
      { mods = opts.mods, on_done = opts.on_done, significant = cls.explicit }
    )
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
