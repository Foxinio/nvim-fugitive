---@mod nvim-fugitive.buffers.summary The `:Git` summary buffer (F5–F8, F26).
---
---Named `fugitive://<git_dir>//` like upstream. The first read is
---synchronous (BufReadCmd semantics); every later refresh is async and
---keeps the cursor on the same item.

local object = require("nvim-fugitive.object")
local render = require("nvim-fugitive.buffers.summary.render")
local snapshot = require("nvim-fugitive.buffers.summary.snapshot")

local M = {}

---@class fugitive.SummaryState
---@field repo fugitive.Repo
---@field info fugitive.LineInfo[]
---@field expanded table<string, boolean>
---@field generation integer
---@field running boolean
---@field dirty boolean
---@field tick integer completed renders
---@field snap fugitive.Snapshot?
---@field waiters fun()[]? callbacks waiting for the running refresh

---@type table<integer, fugitive.SummaryState>
M._state = {}

local ns = vim.api.nvim_create_namespace("fugitive_summary")

---@param buf? integer
---@return fugitive.SummaryState?
function M.state(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return M._state[buf]
end

---Buffer name of a repo's summary.
---@param repo fugitive.Repo
function M.bufname(repo)
  return object.format(repo.git_dir, "")
end

---Identity of a line for cursor restoration.
local function identity(i)
  if not i then
    return nil
  end
  local path = i.entry and i.entry.path
  return {
    kind = i.kind,
    section = i.section,
    path = path,
    hunk_index = i.hunk_index,
    line_index = i.line_index,
    commit = i.commit,
    ref = i.ref,
    key = i.key,
  }
end

local function find_identity(info, id)
  if not id then
    return nil
  end
  local fallback
  for lnum, i in ipairs(info) do
    local path = i.entry and i.entry.path
    if i.section == id.section and path == id.path then
      if
        i.kind == id.kind
        and i.hunk_index == id.hunk_index
        and i.line_index == id.line_index
        and i.commit == id.commit
        and i.ref == id.ref
        and i.key == id.key
      then
        return lnum
      end
      if i.kind == "file" and id.path then
        fallback = fallback or lnum
      end
    end
  end
  if fallback then
    return fallback
  end
  -- the file moved to another section (staged → unstaged): follow the path
  if id.path then
    for lnum, i in ipairs(info) do
      if i.kind == "file" and i.entry.path == id.path then
        return lnum
      end
    end
  end
end

---Write lines + info into the buffer, preserving cursor positions.
---@param buf integer
---@param st fugitive.SummaryState
---@param snap fugitive.Snapshot
local function apply(buf, st, snap)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- prune expansion state of files that are gone
  local lines, info = render.render(snap, st.expanded)
  local wins = vim.fn.win_findbuf(buf)
  local cursors = {}
  for _, win in ipairs(wins) do
    local c = vim.api.nvim_win_get_cursor(win)
    cursors[win] =
      { lnum = c[1], col = c[2], id = identity(st.info[c[1]]), topline = vim.fn.line("w0", win) }
  end
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
  st.info = info
  st.snap = snap
  M.highlight(buf, info)
  for win, c in pairs(cursors) do
    local lnum = find_identity(info, c.id) or math.min(c.lnum, #lines)
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, lnum), c.col })
  end
  st.tick = st.tick + 1
  vim.b[buf].fugitive_tick = st.tick
  vim.api.nvim_exec_autocmds(
    "User",
    { pattern = "FugitiveSummaryRendered", modeline = false, data = { buf = buf } }
  )
end

---Extmark highlights for sigils and diff lines (the syntax file covers the
---rest; extmarks are robust against text that looks like a header).
function M.highlight(buf, info)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { "(new)", "Comment" } },
    virt_text_pos = "eol",
  })
  for lnum, i in ipairs(info) do
    local group
    if i.kind == "diffline" then
      local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
      local c = line:sub(1, 1)
      group = c == "+" and "DiffAdded" or c == "-" and "DiffRemoved" or nil
    elseif i.kind == "hunk" then
      group = "DiffLine"
    elseif i.kind == "diffmeta" then
      group = "DiffFile"
    end
    if group then
      pcall(
        vim.api.nvim_buf_set_extmark,
        buf,
        ns,
        lnum - 1,
        0,
        { line_hl_group = group, priority = 100 }
      )
    end
  end
end

---Synchronous (re)load; used by BufReadCmd and `R`.
---@param buf integer
---@param repo fugitive.Repo
function M.load(buf, repo)
  local st = M._state[buf]
  if not st then
    st = {
      repo = repo,
      info = {},
      expanded = {},
      generation = 0,
      running = false,
      dirty = false,
      tick = 0,
    }
    M._state[buf] = st
    M.setup_buffer(buf, repo)
  end
  st.generation = st.generation + 1
  local snap = snapshot.gather(repo, function(args)
    return repo:sync(args)
  end, st.expanded)
  apply(buf, st, snap)
  if snap.error then
    require("nvim-fugitive.ui.notify").error(snap.error)
  end
end

---Async refresh. Coalesces concurrent requests.
---@param buf integer
---@param cb? fun()
function M.refresh(buf, cb)
  local st = M._state[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if st.running then
    st.dirty = true
    if cb then
      st.waiters = st.waiters or {}
      table.insert(st.waiters, cb)
    end
    return
  end
  st.running = true
  st.generation = st.generation + 1
  local generation = st.generation
  local exec = require("nvim-fugitive.git.exec")
  local repo = st.repo
  require("plenary.async").run(function()
    return pcall(snapshot.gather, repo, function(args)
      return exec.await(args, { repo = repo })
    end, st.expanded)
  end, function(ok, snap)
    vim.schedule(function()
      st.running = false
      if not ok then
        require("nvim-fugitive.ui.notify").error("summary refresh failed: " .. tostring(snap))
        snap = nil
      end
      if st.generation == generation and snap then
        apply(buf, st, snap)
      end
      if st.dirty then
        st.dirty = false
        M.refresh(buf, cb)
        return
      end
      local waiters = st.waiters or {}
      st.waiters = nil
      if cb then
        cb()
      end
      for _, w in ipairs(waiters) do
        w()
      end
    end)
  end)
end

---Refresh every summary buffer (of `git_dir`, or all).
---@param git_dir? string
function M.refresh_all(git_dir)
  for buf, st in pairs(M._state) do
    if not vim.api.nvim_buf_is_valid(buf) then
      M._state[buf] = nil
    elseif not git_dir or st.repo.git_dir == git_dir then
      M.refresh(buf)
    end
  end
end

---Folding (F26): sections and each expanded file's inline diff.
---@param lnum integer
---@return string|integer
function M.foldexpr(lnum)
  local st = M._state[vim.api.nvim_get_current_buf()]
  local i = st and st.info[lnum]
  if not i then
    return 0
  end
  if i.kind == "section" then
    return ">1"
  elseif i.kind == "blank" or i.kind == "header" or i.kind == "discarded" then
    return 0
  elseif i.kind == "file" or i.kind == "stash" then
    local nxt = st.info[lnum + 1]
    if nxt and (nxt.kind == "hunk" or nxt.kind == "diffmeta" or nxt.kind == "diffline") then
      return ">2"
    end
    return 1
  elseif i.kind == "hunk" or i.kind == "diffline" or i.kind == "diffmeta" then
    return 2
  end
  return 1
end

function M.setup_buffer(buf, repo)
  vim.bo[buf].buftype = "nowrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  vim.b[buf].git_dir = repo.git_dir
  vim.b[buf].fugitive_type = "index"
  vim.bo[buf].filetype = "fugitive"
  require("nvim-fugitive.maps").apply(
    buf,
    "summary",
    require("nvim-fugitive.buffers.summary.actions").actions(buf)
  )
  local group = vim.api.nvim_create_augroup("fugitive_summary_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FugitiveChanged",
    callback = function(ev)
      if not vim.api.nvim_buf_is_valid(buf) then
        return true
      end
      local gd = ev.data and ev.data.git_dir
      if gd == nil or gd == repo.git_dir or gd == repo.common_dir then
        M.refresh(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      M.snap_cursor(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      M.setup_window(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      M._state[buf] = nil
      require("nvim-fugitive.watch").unwatch(repo.git_dir)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  require("nvim-fugitive.watch").watch(repo)
  require("nvim-fugitive.api").event("FugitiveIndex", buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    M.setup_window(win)
  end
end

function M.setup_window(win)
  vim.wo[win][0].foldmethod = "expr"
  vim.wo[win][0].foldexpr = "v:lua.require'nvim-fugitive.buffers.summary'.foldexpr(v:lnum)"
  vim.wo[win][0].foldlevel = 99
  vim.wo[win][0].foldenable = true
  vim.wo[win][0].number = false
  vim.wo[win][0].relativenumber = false
  vim.wo[win][0].list = false
  vim.wo[win][0].spell = false
end

---Keep the cursor on actionable lines: when a motion lands on a blank
---separator, continue in the direction of travel (or back, at the edge).
---Visual mode is left alone so selections can span sections.
---@param buf integer
function M.snap_cursor(buf)
  local st = M._state[buf]
  if not st or vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  if vim.api.nvim_get_mode().mode:match("^[vV\22]") then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local last = vim.w[win].fugitive_summary_line or lnum
  local info = st.info
  local target = lnum
  local i = info[lnum]
  if i and i.kind == "blank" then
    local dir = lnum >= last and 1 or -1
    local function scan(d)
      local l = lnum + d
      while l >= 1 and l <= #info do
        if info[l].kind ~= "blank" then
          return l
        end
        l = l + d
      end
    end
    target = scan(dir) or scan(-dir) or lnum
    if target ~= lnum then
      vim.api.nvim_win_set_cursor(win, { target, 0 })
    end
  end
  vim.w[win].fugitive_summary_line = target
end

---Open (or focus) the summary of `repo`.
---@param repo fugitive.Repo
---@param opts? {mods?: string}
---@return integer buf
function M.open(repo, opts)
  opts = opts or {}
  local name = M.bufname(repo)
  local existing = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\/.*$^~[]") .. "$")
  -- already visible in this tab: focus it
  if existing > 0 and not (opts.mods and opts.mods:match("%S")) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == existing then
        vim.api.nvim_set_current_win(win)
        M.refresh(existing)
        return existing
      end
    end
  end
  local style = require("nvim-fugitive.config").get().summary.window
  local cmd
  local cur = vim.api.nvim_get_current_buf()
  local reuse = vim.api.nvim_buf_get_name(cur) == ""
    and vim.bo[cur].buftype == ""
    and not vim.bo[cur].modified
    and vim.api.nvim_buf_line_count(cur) <= 1
  if opts.mods and opts.mods:match("%S") then
    cmd = opts.mods .. " split"
  elseif reuse or style == "current" then
    cmd = "edit"
  elseif style == "vsplit" then
    cmd = "vertical split"
  elseif style == "tab" then
    cmd = "tab split"
  else
    cmd = "split"
  end
  local before = existing > 0 and M._state[existing] and M._state[existing].tick or -1
  vim.cmd(cmd .. " " .. vim.fn.fnameescape(name))
  local buf = vim.api.nvim_get_current_buf()
  if not M._state[buf] then
    -- BufReadCmd did not fire (buffer already loaded): load explicitly
    M.load(buf, repo)
  elseif M._state[buf].tick == before then
    M.refresh(buf)
  end
  M.setup_window(vim.api.nvim_get_current_win())
  -- start on the first file, like upstream
  local st = M._state[buf]
  if st then
    for lnum, i in ipairs(st.info) do
      if i.kind == "file" or i.kind == "commit" or i.kind == "rebase" then
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
        break
      end
    end
  end
  return buf
end

---Help float for a buffer type: map table grouped by action.
---@param buftype string a key of config.maps
function M.show_help(buftype)
  local keys = require("nvim-fugitive.maps").keys_for(buftype)
  local names = vim.tbl_keys(keys)
  table.sort(names)
  local lines =
    { "nvim-fugitive " .. buftype .. " maps (see :help fugitive-" .. buftype .. "-maps)", "" }
  for _, n in ipairs(names) do
    table.insert(lines, string.format("  %-28s %s", table.concat(keys[n], " "), n:gsub("_", " ")))
  end
  require("nvim-fugitive.ui.float").show(
    lines,
    { title = "Fugitive help", filetype = "fugitivehelp" }
  )
end

return M
