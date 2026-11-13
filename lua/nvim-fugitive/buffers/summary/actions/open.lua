---@mod nvim-fugitive.buffers.summary.actions.open Opening the item under the cursor, and diffs.

local object = require("nvim-fugitive.object")
local diff_mod = require("nvim-fugitive.git.diff")
local notify = require("nvim-fugitive.ui.notify")
local util = require("nvim-fugitive.buffers.summary.actions.util")
local summary = util.summary
local state = util.state

local M = {}

---Target under the cursor: path/URL, line, and special handling.
---@return {target?: string, lnum?: integer, submodule?: string, err?: string}
function M.target(buf, lnum)
  local st = state(buf)
  local repo = st.repo
  local i = st.info[lnum]
  if not i then
    return {}
  end
  local function at_index(path)
    return object.format(repo.git_dir, "0", path)
  end
  local function at_head(path)
    local url = object.resolve(repo, "HEAD:" .. path)
    return url
  end
  if i.ref and i.file then
    -- a line of an expanded stash or commit: its file at that line
    local file = i.file --[[@as fugitive.FileDiff]]
    local at
    if i.kind ~= "diffmeta" then
      local hunk = file.hunks[i.hunk_index]
      local nums = i.kind == "diffline" and diff_mod.line_numbers(hunk)[i.line_index]
        or { new = hunk.new_start }
      at = nums.new or nums.old
      if nums.new == nil and nums.old then
        return {
          target = object.resolve(repo, i.ref .. "^:" .. (file.old_path or file.path)),
          lnum = at,
        }
      end
    end
    return { target = object.resolve(repo, i.ref .. ":" .. file.path), lnum = at }
  end
  if i.kind == "file" or i.kind == "diffmeta" then
    local e = i.entry --[[@as fugitive.StatusEntry]]
    if e.submodule then
      return { submodule = repo:abs(e.path) }
    end
    if i.section == "Staged" then
      if e.status == "D" then
        return { target = at_head(e.path) }
      end
      return { target = at_index(e.path) }
    end
    if i.section == "Unstaged" and e.status == "D" then
      return { target = at_index(e.path) }
    end
    return { target = repo:abs(e.path) }
  end
  if i.kind == "hunk" or i.kind == "diffline" then
    local e = i.entry --[[@as fugitive.StatusEntry]]
    local file = i.file --[[@as fugitive.FileDiff]]
    local hunk = file.hunks[i.hunk_index]
    if hunk.submodule or hunk.combined then
      return { target = repo:abs(e.path) }
    end
    local nums = i.kind == "diffline" and diff_mod.line_numbers(hunk)[i.line_index]
      or { new = hunk.new_start, old = hunk.old_start }
    local minus = i.kind == "diffline" and nums.new == nil
    if i.section == "Staged" then
      if minus then
        return { target = at_head(file.old_path or e.path), lnum = nums.old }
      end
      return { target = at_index(e.path), lnum = nums.new }
    end
    if minus then
      return { target = at_index(file.old_path or e.path), lnum = nums.old }
    end
    return { target = repo:abs(e.path), lnum = nums.new }
  end
  if i.kind == "commit" or i.kind == "rebase" then
    return { target = object.resolve(repo, i.commit) }
  end
  if i.kind == "stash" then
    return { target = object.resolve(repo, i.ref) }
  end
  if i.kind == "header" and i.key ~= "Help" and i.key ~= "Error" then
    local rev = i.key == "Head" and "HEAD" or i.value
    return {
      target = object.resolve(repo, rev --[[@as string]]),
    }
  end
  return {}
end

---Make the window that opening from the summary should use current: the
---last window visited in this tab, or a new split below the summary when
---there is none to reuse (only the summary, or a float/blame window).
---@param buf integer summary buffer
---@return integer win
function M.edit_window(buf)
  local summary_win = vim.api.nvim_get_current_win()
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if
    prev ~= 0
    and prev ~= summary_win
    and vim.api.nvim_win_is_valid(prev)
    and vim.api.nvim_win_get_config(prev).relative == ""
    and vim.api.nvim_win_get_buf(prev) ~= buf
    and not vim.wo[prev].winfixbuf
  then
    vim.api.nvim_set_current_win(prev)
    return prev
  end
  vim.cmd("belowright split")
  return vim.api.nvim_get_current_win()
end

function M.open(buf, how)
  local t = M.target(buf, vim.fn.line("."))
  if t.submodule then
    local sub = require("nvim-fugitive.git.repo").find(t.submodule)
    if not sub or sub.worktree ~= t.submodule then
      notify.warn("submodule is not checked out: " .. t.submodule)
      return
    end
    local mods = ({ split = "", vsplit = "vertical", tab = "tab" })[how]
    if how == "float" then
      return summary().open(sub, { mods = "aboveleft" })
    end
    if how == "edit" then
      vim.cmd("edit " .. vim.fn.fnameescape(summary().bufname(sub)))
      return
    end
    return summary().open(sub, { mods = mods ~= "" and mods or "aboveleft" })
  end
  if not t.target then
    local d = state(buf).info[vim.fn.line(".")]
    if d and d.kind == "dir" then
      notify.warn(d.dir .. " is a directory: open one of its files (= folds it)")
      return
    end
    if how == "edit" then
      local i = state(buf).info[vim.fn.line(".")]
      if i and i.kind == "header" and i.key == "Help" then
        return summary().show_help("summary")
      end
      if i and i.kind == "discarded" then
        return require("nvim-fugitive.discard").restore_latest(state(buf).repo)
      end
    end
    notify.warn("nothing to open under the cursor")
    return
  end
  if how == "edit" then
    M.edit_window(buf)
  elseif how == "split" then
    -- below the summary, whatever 'splitbelow' says
    how = "below"
  end
  require("nvim-fugitive.buffers.reader").open(t.target, how, t.lnum)
end

-- ---------------------------------------------------------------------------
-- Diffs

function M.diff(buf, layout)
  local st = state(buf)
  local i = st.info[vim.fn.line(".")]
  if i and i.kind == "dir" then
    notify.warn(i.dir .. " is a directory: diff one of its files, or dp for all of them")
    return
  end
  if not i or not i.entry then
    notify.warn("no file under the cursor")
    return
  end
  local e = i.entry --[[@as fugitive.StatusEntry]]
  local ds = require("nvim-fugitive.buffers.diffsplit")
  local repo = st.repo
  if i.section == "Untracked" or e.submodule then
    notify.warn("nothing to diff for " .. e.path)
    return
  end
  -- in a new split below, like `o`: the summary and the other windows stay;
  -- the next diff closes this one (diffsplit.close_others)
  vim.cmd("belowright split")
  vim.w.fugitive_diff_owned = true
  if i.section == "Unmerged" then
    vim.cmd("edit " .. vim.fn.fnameescape(repo:abs(e.path)))
    return ds.split({ three_way = true, layout = layout })
  end
  if i.section == "Staged" then
    if e.status == "D" then
      local url = object.resolve(repo, "HEAD:" .. e.path)
      if url then
        require("nvim-fugitive.buffers.reader").open(url, "edit")
      end
      return
    end
    require("nvim-fugitive.buffers.reader").open(object.format(repo.git_dir, "0", e.path), "edit")
    return ds.split({ against = "HEAD", layout = layout })
  end
  if e.status == "D" then
    require("nvim-fugitive.buffers.reader").open(object.format(repo.git_dir, "0", e.path), "edit")
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(repo:abs(e.path)))
  return ds.split({ layout = layout })
end

function M.diff_patch(buf)
  local st = state(buf)
  local i = st.info[vim.fn.line(".")]
  local args = { "diff" }
  if i and i.section == "Staged" then
    table.insert(args, "--cached")
  end
  if i and i.entry then
    vim.list_extend(args, { "--", i.entry.path })
  elseif i and i.kind == "dir" then
    vim.list_extend(args, { "--", i.dir })
  end
  require("nvim-fugitive.cmd.git").run(args, { repo = st.repo })
end

-- ---------------------------------------------------------------------------
-- Commands on the cursor commit

---`-- <path>` of the submodule under the cursor, or {} when not on one.
---@param buf integer
---@return string[]
function M.cursor_submodule(buf)
  local st = state(buf)
  local i = st.info[vim.fn.line(".")]
  if i and i.kind == "submodule" and i.path then
    return { "--", i.path }
  end
  if i and i.entry and i.entry.submodule then
    return { "--", i.entry.path }
  end
  return {}
end

---Commit under the cursor (upstream's s:SquashArgument).
function M.cursor_commit(buf)
  local st = state(buf)
  local i = st and st.info[vim.fn.line(".")]
  if i and (i.kind == "commit" or i.kind == "rebase") then
    return i.commit
  end
  return ""
end

return M
