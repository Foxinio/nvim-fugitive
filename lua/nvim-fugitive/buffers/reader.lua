---@mod nvim-fugitive.buffers.reader Read-only fugitive:// buffers (F12, MVP).
---
---Blobs (`sha:path`, `:N:path`), trees and commits. Only what the diff,
---summary and navigation features need; `:Gedit` & co. are backlog.

local object = require("nvim-fugitive.object")
local repo_mod = require("nvim-fugitive.git.repo")
local notify = require("nvim-fugitive.ui.notify")

local M = {}

local pending_lines

---Internal: the set_lines body, run under :lockmarks.
---@param buf integer
function M._apply_pending(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pending_lines or {})
  pending_lines = nil
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  -- :lockmarks like upstream's read: filling a fresh buffer must not shift
  -- marks or quickfix entries that already point into it (:Gclog, :Ggrep)
  pending_lines = lines
  vim.cmd(("lockmarks lua require('nvim-fugitive.buffers.reader')._apply_pending(%d)"):format(buf))
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
end

local function split(text)
  text = text:gsub("\n$", "")
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

---Content of a commit object as upstream shows it: raw header, message,
---then the diff against its parent(s).
---@param repo fugitive.Repo
---@param sha string
---@return string[]? lines, string? err
function M.commit_lines(repo, sha)
  local raw = repo:sync({ "cat-file", "commit", sha })
  if raw.code ~= 0 then
    return nil, require("nvim-fugitive.git.exec").error_text(raw)
  end
  local lines = split(raw.stdout)
  local d = repo:sync({
    "diff-tree",
    "--no-color",
    "--no-ext-diff",
    "--no-commit-id",
    "-p",
    "--cc",
    "--root",
    "-M",
    sha,
  })
  local dl = split(d.stdout)
  if #dl > 0 then
    table.insert(lines, "")
    vim.list_extend(lines, dl)
  end
  return lines
end

---@param repo fugitive.Repo
---@param treeish string
---@return string[]? lines, string? err
function M.tree_lines(repo, treeish, header)
  local res = repo:sync({ "ls-tree", "-z", treeish })
  if res.code ~= 0 then
    return nil, require("nvim-fugitive.git.exec").error_text(res)
  end
  local lines = { "tree " .. header, "" }
  for entry in res.stdout:gmatch("([^%z]+)") do
    local mode, kind, _, name = entry:match("^(%d+) (%S+) (%x+)\t(.*)$")
    if name then
      table.insert(lines, name .. ((kind == "tree" or mode == "040000") and "/" or ""))
    end
  end
  return lines
end

---BufReadCmd handler for fugitive://*
---@param buf integer
function M.read(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local obj = object.parse(name)
  if not obj then
    notify.error("invalid fugitive URL: " .. name)
    return
  end
  local repo = repo_mod.new(obj.git_dir)
  vim.b[buf].git_dir = repo.git_dir
  if obj.commit == "" then
    return require("nvim-fugitive.buffers.summary").load(buf, repo)
  end

  vim.bo[buf].swapfile = false
  vim.bo[buf].buftype = "nowrite"
  vim.bo[buf].bufhidden = vim.bo[buf].bufhidden ~= "" and vim.bo[buf].bufhidden or "hide"

  local lines, err, ftype, filetype, noeol
  local stage = obj.commit:match("^[0-3]$")
  if stage and (obj.path == nil or obj.path == "") then
    local ls = repo:sync({ "ls-files", "--stage" })
    lines = split(ls.stdout)
    ftype, filetype = "index", "git"
  elseif obj.path == nil then
    local kind = repo:chomp({ "cat-file", "-t", obj.commit })
    if kind == "commit" then
      lines, err = M.commit_lines(repo, obj.commit)
      ftype, filetype = "commit", "git"
    elseif kind == "tree" then
      lines, err = M.tree_lines(repo, obj.commit, obj.commit)
      ftype, filetype = "tree", "git"
    elseif kind == "tag" then
      local res = repo:sync({ "cat-file", "tag", obj.commit })
      lines, ftype, filetype = split(res.stdout), "tag", "git"
    elseif kind == "blob" then
      local res = repo:sync({ "cat-file", "blob", obj.commit })
      lines, ftype = split(res.stdout), "blob"
    else
      err = "not a valid object: " .. obj.commit
    end
  else
    local name_ = object.git_name(obj)
    local kind = repo:chomp({ "cat-file", "-t", name_ })
    if kind == "tree" then
      lines, err = M.tree_lines(repo, name_, name_)
      ftype, filetype = "tree", "git"
    elseif kind == "blob" then
      local res = repo:sync({ "cat-file", "blob", name_ })
      if res.code ~= 0 then
        err = require("nvim-fugitive.git.exec").error_text(res)
      else
        lines, ftype = split(res.stdout), "blob"
        noeol = res.stdout ~= "" and res.stdout:sub(-1) ~= "\n"
      end
    elseif kind == "commit" then
      -- a submodule entry
      lines, ftype, filetype = { "commit " .. repo:chomp({ "rev-parse", name_ }) }, "commit", "git"
    else
      err = "path not found: " .. object.describe(obj)
    end
  end

  if err then
    set_lines(buf, {})
    vim.b[buf].fugitive_type = "missing"
    notify.error(err)
    return
  end
  set_lines(buf, lines or {})
  vim.b[buf].fugitive_type = ftype
  if noeol then
    vim.bo[buf].eol = false
    vim.bo[buf].fixeol = false
  end
  if ftype == "blob" and obj.commit == "0" then
    -- the index is writable: :w stages the buffer (BufWriteCmd)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
  end
  if ftype == "blob" then
    filetype = obj.path and vim.filetype.match({ filename = obj.path, buf = buf }) or nil
  end
  M.setup_object(buf, repo)
  if filetype then
    -- a broken ftplugin (e.g. a missing treesitter parser) must not break
    -- reading the object
    local ok, ft_err = pcall(function()
      vim.bo[buf].filetype = filetype
    end)
    if not ok then
      notify.warn("filetype " .. filetype .. ": " .. tostring(ft_err))
    end
  end
  -- upstream's User events for extensions
  local api = require("nvim-fugitive.api")
  api.event("FugitiveObject", buf)
  local per_type =
    { commit = "FugitiveCommit", tree = "FugitiveTree", blob = "FugitiveBlob", tag = "FugitiveTag" }
  if per_type[ftype] then
    api.event(per_type[ftype], buf)
  end
end

-- ---------------------------------------------------------------------------
-- Navigation in object and pager buffers

---Open a fugitive URL or path.
---@param target string
---@param how? "edit"|"split"|"vsplit"|"tab"|"pedit"
---@param lnum? integer
function M.open(target, how, lnum)
  if how == "float" then
    return M.open_float(target, lnum)
  end
  local cmds =
    { edit = "edit", split = "split", vsplit = "vsplit", tab = "tabedit", pedit = "pedit" }
  local cmd = cmds[how or "edit"] or "edit"
  -- leave a float before opening a real window
  local win = vim.api.nvim_get_current_win()
  if how ~= "pedit" and vim.api.nvim_win_get_config(win).relative ~= "" then
    pcall(vim.api.nvim_win_close, win, false)
  end
  vim.cmd(cmd .. " " .. vim.fn.fnameescape(target))
  if lnum and how ~= "pedit" then
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, lnum), 0 })
    vim.cmd("normal! zv")
  end
end

---Open a file or fugitive object in the big float (`config.float`). It closes
---with `:q` or when another window is entered, like a preview.
---@param target string path or fugitive:// URL
---@param lnum? integer
---@return integer win
function M.open_float(target, lnum)
  local float = require("nvim-fugitive.ui.float")
  local obj = object.parse(target)
  local title = obj and object.git_name(obj) or vim.fn.fnamemodify(target, ":~:.")
  -- a float in a float: replace it
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(current).relative ~= "" then
    pcall(vim.api.nvim_win_close, current, false)
  end
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(scratch, true, float.window_config(title))
  vim.cmd("edit " .. vim.fn.fnameescape(target))
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, lnum), 0 })
    vim.cmd("normal! zv")
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    callback = function()
      if vim.api.nvim_get_current_win() ~= win then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, false)
        end
      end)
      return true
    end,
  })
  return win
end

---First parent of a commit (or nil for root commits).
local function first_parent(repo, sha)
  return repo:rev_parse(sha .. "^")
end

---The commit a line of a pager/commit buffer belongs to.
local function containing_commit(buf, lnum, repo)
  local obj = object.parse(vim.api.nvim_buf_get_name(buf))
  if obj and obj.commit:match("^%x+$") and #obj.commit >= 40 and obj.path == nil then
    return obj.commit
  end
  for l = lnum, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
    local sha = line:match("^commit (%x+)")
    if sha then
      return repo:rev_parse(sha)
    end
  end
end

---What the cursor line of a git-ish buffer points to.
---@param buf integer
---@param repo fugitive.Repo
---@return string? url, integer? lnum
function M.target_under_cursor(buf, repo)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local obj = object.parse(vim.api.nvim_buf_get_name(buf))
  local ftype = vim.b[buf].fugitive_type

  if ftype == "tree" and obj and lnum > 2 and line ~= "" then
    local base = obj.path and (obj.path ~= "" and obj.path .. "/" or "") or ""
    local entry = line:gsub("/$", "")
    if obj.commit:match("^[0-3]$") then
      return object.format(repo.git_dir, obj.commit, base .. entry)
    end
    if obj.path == nil then
      -- a bare tree id
      local sha = repo:rev_parse(obj.commit .. ":" .. entry)
      return sha and object.format(repo.git_dir, sha) or nil
    end
    return object.format(repo.git_dir, obj.commit, base .. entry)
  end

  local sha = line:match("^tree (%x+)$")
    or line:match("^parent (%x+)$")
    or line:match("^object (%x+)$")
  if sha then
    return object.format(repo.git_dir, sha)
  end
  sha = line:match("^commit (%x+)")
    or line:match("^(%x%x%x%x%x%x%x+) ")
    or line:match("^[|*\\/ ]+(%x%x%x%x%x%x%x+) ")
  if sha then
    local full = repo:rev_parse(sha .. "^{commit}")
    if full then
      return object.format(repo.git_dir, full)
    end
  end

  -- inside a diff: find the file header and hunk
  local commit = containing_commit(buf, lnum, repo)
  if not commit then
    return nil
  end
  local path, old_path
  local hunk_line, hunk_old, hunk_new
  for l = lnum, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
    if not hunk_line and text:match("^@@") then
      hunk_line = l
      hunk_old, hunk_new = text:match("^@@ %-(%d+),?%d* %+(%d+)")
    end
    local p = text:match("^%+%+%+ b/(.*)$")
    if p and not path then
      path = p
    end
    local o = text:match("^%-%-%- a/(.*)$")
    if o and not old_path then
      old_path = o
    end
    if text:match("^diff ") then
      if not path and not old_path then
        local rest = text:match("^diff %-%-git (.*)$")
        if rest and #rest % 2 == 1 then
          path = rest:sub((#rest + 1) / 2 + 3)
        end
      end
      break
    end
  end
  if not path and not old_path then
    return object.format(repo.git_dir, commit)
  end
  local c = line:sub(1, 1)
  local on_old = line:match("^%-%-%- ") or (c == "-" and hunk_line)
  if on_old then
    local parent = first_parent(repo, commit)
    if not parent or not old_path then
      return nil
    end
    local target_l
    if hunk_line and lnum > hunk_line then
      target_l = tonumber(hunk_old)
      for l = hunk_line + 1, lnum - 1 do
        local t = (vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""):sub(1, 1)
        if t ~= "+" then
          target_l = target_l + 1
        end
      end
    end
    return object.format(repo.git_dir, parent, old_path), target_l
  end
  local target_l
  if hunk_line and lnum >= hunk_line then
    target_l = tonumber(hunk_new)
    for l = hunk_line + 1, lnum - 1 do
      local t = (vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""):sub(1, 1)
      if t ~= "-" then
        target_l = target_l + 1
      end
    end
  end
  if not path then
    return nil
  end
  return object.format(repo.git_dir, commit, path), target_l
end

local function jump(pattern, dir, count)
  count = count or vim.v.count1
  local flags = dir > 0 and "W" or "bW"
  for _ = 1, count do
    if vim.fn.search(pattern, flags) == 0 then
      break
    end
  end
end

local item_pattern = [[\v^(diff |commit \x|\x{7,} |\@\@)]]

---Actions of object/pager buffers.
---@param buf integer
---@param repo fugitive.Repo
function M.actions(buf, repo)
  local cfile = require("nvim-fugitive.maps").cfile_actions(buf)
  local function open(how)
    return function()
      local target, lnum = M.target_under_cursor(buf, repo)
      if not target then
        notify.warn("nothing to open under the cursor")
        return
      end
      M.open(target, how, lnum)
    end
  end
  return {
    cfile_edit = cfile.cfile_edit,
    cfile_split = cfile.cfile_split,
    cfile_tab = cfile.cfile_tab,
    open = open("edit"),
    open_split = open("split"),
    open_vsplit = open("vsplit"),
    open_tab = open("tab"),
    prev_item = function()
      jump(item_pattern, -1)
    end,
    next_item = function()
      jump(item_pattern, 1)
    end,
    prev_hunk = function()
      if vim.wo.diff then
        return vim.cmd("normal! " .. vim.v.count1 .. "[c")
      end
      jump([[^@@]], -1)
    end,
    next_hunk = function()
      if vim.wo.diff then
        return vim.cmd("normal! " .. vim.v.count1 .. "]c")
      end
      jump([[^@@]], 1)
    end,
    diff_close = function()
      require("nvim-fugitive.buffers.diffsplit").close()
    end,
    close = function()
      local win = vim.api.nvim_get_current_win()
      if
        vim.api.nvim_win_get_config(win).relative ~= "" or #vim.api.nvim_tabpage_list_wins(0) > 1
      then
        pcall(vim.api.nvim_win_close, win, false)
      else
        pcall(vim.cmd.bdelete)
      end
    end,
    help = function()
      require("nvim-fugitive.buffers.summary").show_help("object")
    end,
    ancestor = function()
      M.navigate(buf, "ancestor", vim.v.count1)
    end,
    parent = function()
      if vim.v.count == 0 then
        notify.warn("Use ~ (or provide a count)")
        return
      end
      M.navigate(buf, "parent", vim.v.count1)
    end,
    containing_commit = function()
      M.navigate(buf, "commit")
    end,
    navigate_up = function()
      M.navigate(buf, "up", vim.v.count1)
    end,
    cmdline = function()
      local obj = object.parse(vim.api.nvim_buf_get_name(buf))
      local word = obj and (obj.path and object.git_name(obj) or obj.commit) or ""
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(
          ": " .. vim.fn.fnameescape(word) .. "<Home>",
          true,
          false,
          true
        ),
        "n",
        false
      )
    end,
  }
end

---Object-buffer navigation (upstream `~`, `P`, `C`, `-`).
---@param buf integer
---@param how "ancestor"|"parent"|"commit"|"up"
---@param count? integer
function M.navigate(buf, how, count)
  local obj = object.parse(vim.api.nvim_buf_get_name(buf))
  if not obj or not obj.commit:match("^%x+$") or #obj.commit < 40 then
    notify.warn("not a commit, tree or blob at a commit")
    return
  end
  local repo = repo_mod.new(obj.git_dir)
  local suffix = obj.path and (":" .. obj.path) or ""
  local spec
  if how == "ancestor" then
    spec = obj.commit .. "~" .. (count or 1) .. suffix
  elseif how == "parent" then
    spec = obj.commit .. "^" .. (count or 1) .. suffix
  elseif how == "commit" then
    spec = obj.commit
  else
    -- blob -> its tree -> parent tree -> root tree -> commit
    local path = obj.path
    for _ = 1, count or 1 do
      if path == nil then
        break
      elseif path == "" then
        path = nil
      else
        local parent = path:gsub("/$", ""):match("^(.*)/[^/]*$")
        path = parent and (parent .. "/") or ""
      end
    end
    if path == nil then
      spec = obj.commit
    else
      local url = object.format(repo.git_dir, obj.commit, path)
      local child = obj.path and obj.path:gsub("/$", ""):match("([^/]+)$")
      M.open(url, "edit")
      if child then
        vim.fn.search("^" .. vim.fn.escape(child, "\\.*$^~[]") .. "/\\=$", "wc")
      end
      return
    end
  end
  local url, err = object.resolve(repo, spec)
  if not url then
    notify.error(err or ("no such object: " .. spec))
    return
  end
  M.open(url, "edit")
end

---Folding of diffs in commit/pager buffers (F26): one fold per file.
---@param lnum integer
---@return string
function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match("^diff ") then
    return ">1"
  end
  if line:match("^commit %x") then
    return "0"
  end
  return "="
end

local function setup_folds(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win][0].foldmethod = "expr"
    vim.wo[win][0].foldexpr = "v:lua.require'nvim-fugitive.buffers.reader'.foldexpr(v:lnum)"
    vim.wo[win][0].foldlevel = 99
  end
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      vim.wo[0][0].foldmethod = "expr"
      vim.wo[0][0].foldexpr = "v:lua.require'nvim-fugitive.buffers.reader'.foldexpr(v:lnum)"
      vim.wo[0][0].foldlevel = 99
    end,
  })
end

---Bytes of a buffer as they would be written to a file.
---@param buf integer
---@return string
function M.buffer_bytes(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if
    #lines > 0
    and (vim.bo[buf].eol or vim.bo[buf].fixeol)
    and not (#lines == 1 and lines[1] == "")
  then
    text = text .. "\n"
  end
  return text
end

---Write `content` as the stage-0 index entry of `rel` (resolving any
---conflict stages). Keeps the existing mode.
---@param repo fugitive.Repo
---@param rel string
---@param content string
---@return boolean ok, string? err
function M.write_index(repo, rel, content)
  local hash = repo:sync({ "hash-object", "-w", "--stdin", "--no-filters" }, { stdin = content })
  if hash.code ~= 0 then
    return false, require("nvim-fugitive.git.exec").error_text(hash)
  end
  local sha = vim.trim(hash.stdout)
  local mode = "100644"
  local ls = repo:sync({ "ls-files", "-s", "-z", "--", rel })
  for rec in ls.stdout:gmatch("([^%z]+)") do
    local m, _, stage = rec:match("^(%d+) (%x+) (%d)\t")
    if m and (stage == "0" or stage == "2") then
      mode = m
    end
  end
  if mode == "160000" or mode == "120000" and content:find("\n") then
    return false, "refusing to write " .. rel .. " (mode " .. mode .. ")"
  end
  local info = "0 "
    .. string.rep("0", 40)
    .. "\t"
    .. rel
    .. "\n"
    .. mode
    .. " "
    .. sha
    .. " 0\t"
    .. rel
    .. "\n"
  local res = repo:sync({ "update-index", "--index-info" }, { stdin = info })
  if res.code ~= 0 then
    return false, require("nvim-fugitive.git.exec").error_text(res)
  end
  return true
end

---BufWriteCmd for fugitive:// buffers: stage-0 blobs write to the index,
---everything else is read-only.
---@param buf integer
function M.write(buf)
  local obj = object.parse(vim.api.nvim_buf_get_name(buf))
  if not obj or obj.commit ~= "0" or not obj.path or obj.path == "" then
    notify.error("this fugitive:// buffer is read-only; only the index (//0/) is writable")
    return
  end
  local repo = repo_mod.new(obj.git_dir)
  local ok, err = M.write_index(repo, obj.path, M.buffer_bytes(buf))
  if not ok then
    notify.error(err or "could not write the index")
    return
  end
  vim.bo[buf].modified = false
  require("nvim-fugitive").changed(repo)
end

---Maps and folds for fugitive:// object buffers.
---@param buf integer
---@param repo fugitive.Repo
function M.setup_object(buf, repo)
  if vim.b[buf].fugitive_object_setup then
    return
  end
  vim.b[buf].fugitive_object_setup = true
  local ftype = vim.b[buf].fugitive_type
  local actions = M.actions(buf, repo)
  if ftype == "blob" and vim.bo[buf].modifiable then
    -- the editable index keeps every editing key
    actions = { diff_close = actions.diff_close, close = actions.close, help = actions.help }
  elseif ftype == "blob" then
    -- blob buffers keep the user's normal editing maps; navigation only.
    -- <CR>/o/gO/O/p open the commit that introduced the cursor line.
    local blame = require("nvim-fugitive.buffers.blame")
    local function line_commit(how)
      return function()
        blame.line_commit(how)
      end
    end
    actions = {
      open = line_commit("edit"),
      open_split = line_commit("split"),
      open_vsplit = line_commit("vsplit"),
      open_tab = line_commit("tab"),
      open_preview = line_commit("pedit"),
      diff_close = actions.diff_close,
      close = actions.close,
      help = actions.help,
      ancestor = actions.ancestor,
      parent = actions.parent,
      containing_commit = actions.containing_commit,
      navigate_up = actions.navigate_up,
      cmdline = actions.cmdline,
    }
  end
  require("nvim-fugitive.maps").apply(buf, "object", actions)
  if ftype == "commit" then
    setup_folds(buf)
  end
end

---Maps and folds for pager output buffers (`:Git log`, `:Git show`, …).
---@param buf integer
---@param repo fugitive.Repo
function M.setup_pager(buf, repo)
  local actions = M.actions(buf, repo)
  actions.close = nil -- the pager table owns q/<Esc>
  local cfg = require("nvim-fugitive.config").get().maps
  -- object maps, but never shadow the pager's own keys
  local pager_keys = {}
  for lhs in pairs(cfg.pager) do
    pager_keys[lhs] = true
  end
  for lhs, name in pairs(cfg.object) do
    local fn = name and (type(name) == "function" and name or actions[name])
    if fn and not pager_keys[lhs] then
      vim.keymap.set(
        "n",
        lhs,
        fn,
        { buffer = buf, nowait = true, silent = true, desc = "fugitive: " .. tostring(name) }
      )
    end
  end
  setup_folds(buf)
end

return M
