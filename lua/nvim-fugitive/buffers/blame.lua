---@mod nvim-fugitive.buffers.blame The `:Git blame` side window (F16).
---
---Like upstream: git's own `blame --show-number` output in a scroll-bound
---vertical split left of the file, sized to the metadata column (the code
---part of each line is cut off by the window width). Maps act on the
---commit of the cursor line.

local object = require("nvim-fugitive.object")
local notify = require("nvim-fugitive.ui.notify")

local M = {}

---@class fugitive.BlameState
---@field repo fugitive.Repo
---@field origin_buf integer the blamed buffer
---@field origin_win integer
---@field path string repo-relative path that was blamed
---@field commit string? commit blamed at (nil = work tree / buffer contents)
---@field flags string[] extra blame flags
---@field restore table window options of the origin window to restore

---@type table<integer, fugitive.BlameState> blame buffer -> state
M._state = {}

local ns = vim.api.nvim_create_namespace("fugitive_blame")

---Parse one line of `git blame --show-number` output.
---@param line string
---@return {commit: string, boundary: boolean, path: string?, orig: integer, final: integer}?
function M.parse_line(line)
  local boundary = line:sub(1, 1) == "^"
  local sha, rest = line:match("^%^?(%x+)%s+(.*)$")
  if not sha then
    return nil
  end
  -- "[path] orig (author date final) code"
  local head, meta = rest:match("^(.-)%s*%((.-)%)")
  if not head then
    return nil
  end
  local path, orig = head:match("^(.-)%s+(%d+)$")
  if not path then
    orig = head:match("^(%d+)$")
    path = nil
  end
  local final = meta:match("(%d+)%s*$")
  if not orig or not final then
    return nil
  end
  if path == "" then
    path = nil
  end
  return {
    commit = sha,
    boundary = boundary,
    path = path,
    orig = tonumber(orig),
    final = tonumber(final),
  }
end

---Display width of the text matched by a pattern on a line (for resizing).
local function width_to(line, pattern)
  local s = line:match(pattern)
  return s and vim.fn.strdisplaywidth(s) or nil
end

---Width up to the closing paren of the metadata.
function M.meta_width(line)
  return width_to(line, "^.-%s+%d+%)") or 40
end

local function hl_for_commit(sha)
  if sha:match("^0+$") then
    return "Comment"
  end
  local name = "FugitiveBlameHash" .. sha:sub(1, 6)
  if vim.fn.hlexists(name) == 0 then
    -- a stable colour per commit, like upstream's dynamic colours
    local r = tonumber(sha:sub(1, 2), 16)
    local g = tonumber(sha:sub(3, 4), 16)
    local b = tonumber(sha:sub(5, 6), 16)
    local function lift(c)
      return math.floor(80 + c * 175 / 255)
    end
    vim.api.nvim_set_hl(
      0,
      name,
      { fg = string.format("#%02x%02x%02x", lift(r), lift(g), lift(b)), default = true }
    )
  end
  return name
end

local function highlight(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local info = M.parse_line(line)
    if info then
      local len = #info.commit + (info.boundary and 1 or 0)
      pcall(
        vim.api.nvim_buf_set_extmark,
        buf,
        ns,
        i - 1,
        0,
        { end_col = len, hl_group = hl_for_commit(info.commit) }
      )
      local paren = line:find("(", 1, true)
      local close = line:find(")", paren or 1, true)
      if paren and close then
        pcall(
          vim.api.nvim_buf_set_extmark,
          buf,
          ns,
          i - 1,
          paren - 1,
          { end_col = close, hl_group = "Comment" }
        )
      end
    end
  end
end

---Blame arguments for the origin buffer; returns args and an optional temp
---file to delete afterwards.
---@param repo fugitive.Repo
---@param buf integer
---@param flags string[]
---@return string[]? args, string? path, string? commit, string? tmp, string? err
local function blame_args(repo, buf, flags)
  local name = vim.api.nvim_buf_get_name(buf)
  local obj = object.parse(name)
  local args = {
    "--literal-pathspecs",
    "-c",
    "blame.coloring=none",
    "-c",
    "blame.blankBoundary=false",
    "blame",
    "--show-number",
  }
  vim.list_extend(args, flags)
  local path, commit, tmp
  if obj then
    if not obj.path or obj.path == "" then
      return nil, nil, nil, nil, "not a file"
    end
    path = obj.path
    if obj.commit:match("^%x+$") and #obj.commit >= 40 then
      commit = obj.commit
      table.insert(args, commit)
    else
      -- index or stage buffers: blame their contents
      tmp = vim.fn.tempname()
      vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), tmp)
      vim.list_extend(args, { "--contents", tmp })
    end
  else
    path = repo:rel(name)
    if not path or path == "" then
      return nil, nil, nil, nil, "not a file in the repository"
    end
    if vim.bo[buf].modified then
      tmp = vim.fn.tempname()
      vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), tmp)
      vim.list_extend(args, { "--contents", tmp })
    end
  end
  vim.list_extend(args, { "--", path })
  return args, path, commit, tmp
end

---Close the blame window(s) of an origin buffer and restore its window.
---@param blame_buf integer
function M.close(blame_buf)
  local st = M._state[blame_buf]
  M._state[blame_buf] = nil
  if st and vim.api.nvim_win_is_valid(st.origin_win) then
    for opt, value in pairs(st.restore) do
      vim.wo[st.origin_win][opt] = value
    end
  end
  for _, win in ipairs(vim.fn.win_findbuf(blame_buf)) do
    if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    else
      -- the last window (e.g. after :only): keep it, as a normal window
      for opt, value in pairs({
        winfixbuf = false,
        winfixwidth = false,
        scrollbind = false,
        wrap = vim.go.wrap,
        number = vim.go.number,
        relativenumber = vim.go.relativenumber,
        foldenable = vim.go.foldenable,
        cursorline = vim.go.cursorline,
        signcolumn = vim.go.signcolumn,
      }) do
        pcall(function()
          vim.wo[win][opt] = value
        end)
      end
      local alt = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(win, alt)
    end
  end
  if vim.api.nvim_buf_is_valid(blame_buf) then
    pcall(vim.api.nvim_buf_delete, blame_buf, { force = true })
  end
  if st and vim.api.nvim_win_is_valid(st.origin_win) then
    vim.api.nvim_set_current_win(st.origin_win)
  end
end

---Blame buffer currently attached to `origin_buf` (or nil).
function M.for_origin(origin_buf)
  for b, st in pairs(M._state) do
    if st.origin_buf == origin_buf and vim.api.nvim_buf_is_valid(b) then
      return b
    end
  end
end

---Open the blame window for the current buffer.
---@param opts? {flags?: string[], mods?: string, repo?: fugitive.Repo}
---@return integer? blame_buf
function M.open(opts)
  opts = opts or {}
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_win = vim.api.nvim_get_current_win()
  local repo = opts.repo or require("nvim-fugitive.git.repo").require(origin_buf)
  if not repo then
    return nil
  end
  local flags = opts.flags or {}
  local args, path, commit, tmp, err = blame_args(repo, origin_buf, flags)
  if not args then
    notify.error(err or "cannot blame this buffer")
    return nil
  end
  local res = repo:sync(args)
  if tmp then
    os.remove(tmp)
  end
  require("nvim-fugitive.ui.output").record(res, repo.worktree)
  if res.code ~= 0 then
    notify.error(
      notify.truncate(
        require("nvim-fugitive.git.exec").error_text(res),
        { code = res.code, is_error = true }
      )
    )
    return nil
  end
  -- one blame window per origin buffer
  local existing = M.for_origin(origin_buf)
  if existing then
    M.close(existing)
    vim.api.nvim_set_current_win(origin_win)
  end
  local lines = vim.split((res.stdout:gsub("\n$", "")), "\n", { plain = true })

  local restore = {
    scrollbind = vim.wo[origin_win].scrollbind,
    wrap = vim.wo[origin_win].wrap,
    foldenable = vim.wo[origin_win].foldenable,
  }
  vim.wo[origin_win].scrollbind = true
  vim.wo[origin_win].wrap = false
  vim.wo[origin_win].foldenable = false
  local top = vim.fn.line("w0", origin_win)
  local cursor = vim.api.nvim_win_get_cursor(origin_win)[1]

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].git_dir = repo.git_dir
  pcall(vim.api.nvim_buf_set_name, buf, "fugitive-blame://" .. buf .. "/" .. path)

  local mods = opts.mods and opts.mods:match("%S") and opts.mods or "leftabove"
  vim.cmd(mods .. " vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  for opt, value in pairs({
    number = false,
    relativenumber = false,
    scrollbind = true,
    wrap = false,
    foldcolumn = "0",
    foldenable = false,
    winfixwidth = true,
    signcolumn = "no",
    list = false,
    cursorline = true,
  }) do
    vim.wo[win][opt] = value
  end
  pcall(function()
    vim.wo[win].winfixbuf = true
  end)
  vim.bo[buf].filetype = "fugitiveblame"
  highlight(buf, lines)
  vim.api.nvim_win_set_width(
    win,
    M.meta_width(lines[math.min(cursor, #lines)] or lines[1] or "") + 1
  )
  -- align with the file window
  vim.fn.winrestview({ topline = top, lnum = math.min(cursor, #lines) })
  vim.cmd("syncbind")

  M._state[buf] = {
    repo = repo,
    origin_buf = origin_buf,
    origin_win = origin_win,
    path = path --[[@as string]],
    commit = commit,
    flags = flags,
    restore = restore,
  }
  require("nvim-fugitive.maps").apply(buf, "blame", M.actions(buf))
  -- the blame window is useless without its file window: close it too
  -- (it has 'winfixbuf', so it could not show anything else)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(origin_win),
    once = true,
    callback = function()
      vim.schedule(function()
        if M._state[buf] then
          M.close(buf)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      -- restore right away: a blame opened next must see the real values
      local st = M._state[buf]
      if st then
        M._state[buf] = nil
        if vim.api.nvim_win_is_valid(st.origin_win) then
          for opt, value in pairs(st.restore) do
            vim.wo[st.origin_win][opt] = value
          end
        end
      end
    end,
  })
  return buf
end

---The commit, path and original line number of a blame line.
---@param buf integer blame buffer
---@param lnum? integer
---@return {commit: string, boundary: boolean, path: string, orig: integer}?
function M.line_info(buf, lnum)
  local st = M._state[buf]
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local info = M.parse_line(line)
  if not info or not st then
    return nil
  end
  return {
    commit = info.commit,
    boundary = info.boundary,
    path = info.path or st.path,
    orig = info.orig,
  }
end

---Open the commit that introduced a line, at the matching diff line (or
---the blob at a boundary commit).
---@param repo fugitive.Repo
---@param info {commit: string, boundary: boolean, path: string, orig: integer}
---@param how "edit"|"split"|"tab"|"pedit"
function M.open_commit(repo, info, how)
  local reader = require("nvim-fugitive.buffers.reader")
  if info.commit:match("^0+$") then
    notify.warn("not committed yet")
    return
  end
  local sha = repo:rev_parse(info.commit .. "^{commit}")
  if not sha then
    notify.error("unknown commit " .. info.commit)
    return
  end
  if info.boundary then
    reader.open(object.format(repo.git_dir, sha, info.path), how, info.orig)
    return
  end
  reader.open(object.format(repo.git_dir, sha), how)
  if how == "pedit" then
    return
  end
  -- find the hunk adding the line
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local in_file = false
  for i, l in ipairs(lines) do
    if l:match("^diff ") then
      in_file = l:sub(-#info.path - 2) == "b/" .. info.path
    elseif in_file then
      local new_start = l:match("^@@ %-%d+,?%d* %+(%d+)")
      if new_start then
        local n = tonumber(new_start)
        local j = i + 1
        while lines[j] and not lines[j]:match("^@@") and not lines[j]:match("^diff ") do
          local c = lines[j]:sub(1, 1)
          if c == "+" or c == " " then
            if n == info.orig then
              vim.api.nvim_win_set_cursor(0, { j, 0 })
              vim.cmd("normal! zv")
              return
            end
            n = n + 1
          end
          j = j + 1
        end
      end
    end
  end
end

---Reblame at `rev` (commit of the line, its parent, …), keeping the line.
---@param buf integer blame buffer
---@param suffix string "" (at the commit), "^N", "~N"
function M.reblame(buf, suffix)
  local st = M._state[buf]
  local info = M.line_info(buf)
  if not st or not info then
    return
  end
  local commit = info.commit
  if commit:match("^0+$") then
    commit, suffix = "HEAD", ""
  end
  local repo = st.repo
  local url, err = object.resolve(repo, commit .. suffix .. ":" .. info.path)
  if not url then
    notify.error(err or "no such revision")
    return
  end
  local origin_win, flags = st.origin_win, st.flags
  M.close(buf)
  vim.api.nvim_set_current_win(origin_win)
  require("nvim-fugitive.buffers.reader").open(url, "edit", info.orig)
  M.open({ flags = flags, repo = repo })
  pcall(vim.api.nvim_win_set_cursor, 0, { info.orig, 0 })
  vim.cmd("syncbind")
end

---Actions of the blame buffer (config.maps.blame).
---@param buf integer
function M.actions(buf)
  local function commit_action(how)
    return function()
      local st = M._state[buf]
      local info = M.line_info(buf)
      if not st or not info then
        return
      end
      if how == "edit" then
        local origin = st.origin_win
        M.close(buf)
        vim.api.nvim_set_current_win(origin)
      end
      M.open_commit(st.repo, info, how)
    end
  end
  local function resize(pattern, delta_sign)
    return function()
      local line = vim.api.nvim_get_current_line()
      local w = width_to(line, pattern)
      if w then
        vim.api.nvim_win_set_width(0, w + 1 + delta_sign * vim.v.count)
      end
    end
  end
  return {
    close = function()
      local st = M._state[buf]
      local origin = st and st.origin_buf
      M.close(buf)
      -- like upstream: return to the work-tree version
      if
        origin
        and vim.api.nvim_buf_is_valid(origin)
        and object.parse(vim.api.nvim_buf_get_name(origin))
      then
        pcall(require("nvim-fugitive.cmd.edit").open, "edit", "")
      end
    end,
    help = function()
      require("nvim-fugitive.buffers.summary").show_help("blame")
    end,
    open = commit_action("edit"),
    open_split = commit_action("split"),
    open_tab = commit_action("tab"),
    open_preview = commit_action("pedit"),
    reblame = function()
      M.reblame(buf, "")
    end,
    reblame_parent = function()
      if vim.v.count == 0 then
        notify.warn("Use ~ (or provide a count)")
        return
      end
      M.reblame(buf, "^" .. vim.v.count1)
    end,
    reblame_ancestor = function()
      M.reblame(buf, "~" .. vim.v.count1)
    end,
    resize_author = resize("^(.-)%s+%d%d%d%d%-%d%d%-%d%d", 1),
    resize_commit = resize("^(%^?%x+)", 1),
    resize_date = resize("^(.-%d%d:%d%d:%d%d%s+[+-]%d%d%d%d)", -1),
    cmdline = function()
      local info = M.line_info(buf)
      local word = info and (info.commit:match("^0+$") and "@" or info.commit) or ""
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(": " .. word .. "<Home>", true, false, true),
        "n",
        false
      )
    end,
  }
end

---Blame the line under the cursor of a blob buffer and open its commit
---(upstream's `<CR>` in blobs).
---@param how "edit"|"split"|"tab"|"pedit"
function M.line_commit(how)
  local buf = vim.api.nvim_get_current_buf()
  local repo = require("nvim-fugitive.git.repo").for_buf(buf)
  if not repo then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local args, path, _, tmp, err = blame_args(repo, buf, { "-L", lnum .. "," .. lnum })
  if not args then
    notify.error(err or "cannot blame")
    return
  end
  local res = repo:sync(args)
  if tmp then
    os.remove(tmp)
  end
  local info = res.code == 0 and M.parse_line((res.stdout:gsub("\n.*", ""))) or nil
  if not info then
    notify.error(require("nvim-fugitive.git.exec").error_text(res))
    return
  end
  M.open_commit(repo, {
    commit = info.commit,
    boundary = info.boundary,
    path = (info.path or path) --[[@as string]],
    orig = info.orig,
  }, how)
end

return M
