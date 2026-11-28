---@mod nvim-fugitive.buffers.summary.actions.stage Staging, unstaging and inline diffs in the summary.

local diff_mod = require("nvim-fugitive.git.diff")
local notify = require("nvim-fugitive.ui.notify")
local fold = require("nvim-fugitive.buffers.summary.fold")
local summary_items = require("nvim-fugitive.buffers.summary.items")
local util = require("nvim-fugitive.buffers.summary.actions.util")
local summary = util.summary
local state = util.state
local range = util.range
local has_head = util.has_head

local M = {}
---@class fugitive.Selection
---@field type "section"|"file"|"patch"|"commit"|"stash"|"header"|"discarded"
---@field section? string
---@field entry? fugitive.StatusEntry
---@field entries? fugitive.StatusEntry[]
---@field file? fugitive.FileDiff
---@field hunks? {hunk: fugitive.Hunk, lines?: table<integer, boolean>}[]
---@field info? fugitive.LineInfo

---Entries of a section in the current snapshot.
local function section_entries(st, section)
  local s = st.snap and st.snap.status
  if not s then
    return {}
  end
  return ({
    Untracked = s.untracked,
    Unstaged = s.unstaged,
    Staged = s.staged,
    Unmerged = s.unmerged,
  })[section] or {}
end

---The selection one item stands for, by its kind. `line` is the line the
---cursor is on (the record's `info`, for moving the cursor afterwards).
local selection_of = {
  section = function(st, it, line)
    local rec = { type = "section", section = it.section, info = line }
    rec.entries = section_entries(st, it.section)
    return { rec }
  end,
  file = function(_, it, line)
    return { { type = "file", section = it.section, entry = it.entry, info = line } }
  end,
  -- a directory: each of its files, shown or folded
  dir = function(_, it)
    return vim.tbl_map(function(e)
      return { type = "file", section = it.section, entry = e, info = it }
    end, it.entries)
  end,
  hunk = function(_, it, line)
    local rec =
      { type = "patch", section = it.section, entry = it.entry, file = it.file, info = line }
    rec.hunks = { { hunk = it.file.hunks[it.hunk_index] } }
    return { rec }
  end,
  commit = function(_, it, line)
    return { { type = "commit", section = it.section, info = line } }
  end,
  stash = function(_, it, line)
    return { { type = "stash", section = it.section, info = line } }
  end,
  header = function(_, _, line)
    return { { type = "header", info = line } }
  end,
  discarded = function(_, _, line)
    return { { type = "discarded", info = line } }
  end,
}
selection_of.rebase = selection_of.commit
selection_of.diffline = selection_of.hunk

---Items addressed by lines l1..l2 (normal mode: l1 == l2).
---@param buf integer
---@param l1 integer
---@param l2 integer
---@return fugitive.Selection[]
function M.selection(buf, l1, l2)
  local st = state(buf)
  if not st then
    return {}
  end
  local items = {}
  if l1 == l2 then
    local line = st.info[l1]
    local it = line and line.item
    if not it then
      return {}
    end
    -- a diff line with no hunk heading of its own still stages as a patch
    if line.kind == "diffline" and it.kind ~= "hunk" then
      it = line
    end
    local one = selection_of[it.kind]
    return one and one(st, it, line) or {}
  end
  -- a range: whole files if any file line is included, else selected lines
  local files, seen = {}, {}
  local patches, order = {}, {}
  for lnum = l1, l2 do
    local i = st.info[lnum]
    if i and (i.kind == "file" or i.kind == "dir") then
      for _, e in ipairs(i.kind == "dir" and i.entries or { i.entry }) do
        local k = i.section .. "\0" .. e.path
        if not seen[k] then
          seen[k] = true
          table.insert(files, { type = "file", section = i.section, entry = e, info = i })
        end
      end
    elseif i and i.kind == "section" then
      table.insert(files, {
        type = "section",
        section = i.section,
        entries = section_entries(st, i.section),
        info = i,
      })
    elseif i and (i.kind == "hunk" or i.kind == "diffline") then
      local k = i.section .. "\0" .. i.entry.path
      local p = patches[k]
      if not p then
        p = {
          type = "patch",
          section = i.section,
          entry = i.entry,
          file = i.file,
          by_hunk = {},
          info = i,
        }
        patches[k] = p
        table.insert(order, k)
      end
      local h = p.by_hunk[i.hunk_index]
      if not h then
        h = { hunk = i.file.hunks[i.hunk_index], lines = {}, index = i.hunk_index }
        p.by_hunk[i.hunk_index] = h
      end
      if i.kind == "hunk" then
        h.lines = nil -- header selected: whole hunk
      elseif h.lines then
        h.lines[i.line_index] = true
      end
    elseif i and (i.kind == "commit" or i.kind == "rebase") then
      table.insert(items, { type = "commit", section = i.section, info = i })
    end
  end
  if #files > 0 then
    return files
  end
  for _, k in ipairs(order) do
    local p = patches[k]
    local idx = vim.tbl_keys(p.by_hunk)
    table.sort(idx)
    p.hunks = {}
    for _, hi in ipairs(idx) do
      table.insert(p.hunks, p.by_hunk[hi])
    end
    p.by_hunk = nil
    table.insert(items, p)
  end
  return items
end

-- ---------------------------------------------------------------------------
-- Running git commands in sequence

---@param repo fugitive.Repo
---@param cmds {args: string[], stdin?: string}[]
---@param cb? fun(ok: boolean)
function M.run_chain(repo, cmds, cb)
  local output = require("nvim-fugitive.ui.output")
  local i = 0
  local function step()
    i = i + 1
    local c = cmds[i]
    if not c then
      require("nvim-fugitive").changed(repo)
      if cb then
        cb(true)
      end
      return
    end
    repo:run(c.args, { stdin = c.stdin }, function(res)
      output.record(res, repo.worktree)
      if res.code ~= 0 then
        notify.error(
          notify.truncate(
            require("nvim-fugitive.git.exec").error_text(res),
            { code = res.code, is_error = true }
          )
        )
        require("nvim-fugitive").changed(repo)
        if cb then
          cb(false)
        end
        return
      end
      step()
    end)
  end
  step()
end

local function apply_patch_cmd(item, reverse, extra)
  local sels = {}
  for _, h in ipairs(item.hunks) do
    if h.hunk.submodule or h.hunk.combined then
      return nil, "cannot stage part of a submodule or conflict diff"
    end
    table.insert(sels, { hunk = h.hunk, lines = h.lines })
  end
  if item.file.binary then
    return nil, "cannot apply part of a binary diff"
  end
  local patch = diff_mod.build_patch(item.file, sels, reverse)
  if not patch then
    return nil, "no changes selected"
  end
  local args = { "apply", "--recount", "--whitespace=nowarn" }
  vim.list_extend(args, extra or {})
  if reverse then
    table.insert(args, "--reverse")
  end
  table.insert(args, "-")
  return { args = args, stdin = patch }
end

-- ---------------------------------------------------------------------------
-- Stage / unstage / toggle

local function stage_cmds(_, items)
  local cmds, staged = {}, {}
  for _, it in ipairs(items) do
    if it.type == "section" then
      if it.section == "Unstaged" then
        table.insert(cmds, { args = { "add", "-u" } })
        for _, e in ipairs(it.entries) do
          table.insert(staged, e.path)
        end
      elseif it.section == "Untracked" or it.section == "Unmerged" then
        local args = { "add", "--" }
        for _, e in ipairs(it.entries) do
          table.insert(args, e.path)
          table.insert(staged, e.path)
        end
        if #args > 2 then
          table.insert(cmds, { args = args })
        end
      end
    elseif it.type == "file" then
      local p = it.entry.path
      if it.section == "Untracked" or it.section == "Unmerged" then
        table.insert(cmds, { args = { "add", "--", p } })
        table.insert(staged, p)
      elseif it.section == "Unstaged" then
        table.insert(cmds, { args = { "add", "-A", "--", p } })
        table.insert(staged, p)
      end
    elseif it.type == "patch" then
      if it.section == "Unstaged" then
        local cmd, err = apply_patch_cmd(it, false, { "--cached" })
        if not cmd then
          return nil, err
        end
        table.insert(cmds, cmd)
        table.insert(staged, it.entry.path .. " (partial)")
      elseif it.section == "Untracked" then
        table.insert(cmds, { args = { "add", "--", it.entry.path } })
        table.insert(staged, it.entry.path)
      end
    end
  end
  return cmds, nil, staged
end

local function unstage_cmds(st, items)
  local cmds, unstaged = {}, {}
  local head = has_head(st)
  for _, it in ipairs(items) do
    if it.type == "section" and it.section == "Staged" then
      if head then
        table.insert(cmds, { args = { "reset", "-q" } })
      else
        table.insert(cmds, { args = { "rm", "--cached", "-r", "-q", "--", "." } })
      end
      for _, e in ipairs(it.entries) do
        table.insert(unstaged, e.path)
      end
    elseif it.type == "file" and it.section == "Staged" then
      local paths = { it.entry.path }
      if it.entry.orig then
        table.insert(paths, it.entry.orig)
      end
      local args = head and { "reset", "-q", "--" } or { "rm", "--cached", "-q", "--" }
      vim.list_extend(args, paths)
      table.insert(cmds, { args = args })
      table.insert(unstaged, it.entry.path)
    elseif it.type == "patch" and it.section == "Staged" then
      local cmd, err = apply_patch_cmd(it, true, { "--cached" })
      if not cmd then
        return nil, err
      end
      table.insert(cmds, cmd)
      table.insert(unstaged, it.entry.path .. " (partial)")
    end
  end
  return cmds, nil, unstaged
end

local file_sections = { "Untracked", "Unstaged", "Staged", "Unmerged" }
local file_sections_set = { Untracked = true, Unstaged = true, Staged = true, Unmerged = true }

---Whole files moved by a stage/unstage: collapse them in every section, so
---one comes back folded wherever it lands, now or after moving back.
---@param st fugitive.SummaryState
---@param items table[] selection items
---@return table<string, true> paths
local function fold_moved(st, items)
  local paths = {}
  for _, it in ipairs(items) do
    if it.type == "file" then
      paths[it.entry.path] = true
      if it.entry.orig then
        paths[it.entry.orig] = true
      end
    elseif it.type == "section" then
      for _, e in ipairs(it.entries or {}) do
        paths[e.path] = true
      end
    end
  end
  for path in pairs(paths) do
    for _, sec in ipairs(file_sections) do
      fold.reset(st.open, fold.node("file", sec, path))
    end
  end
  return paths
end

---Where the cursor goes once files (or the hunks emptying them) left their
---section: the next file of that section, else the previous one, else the
---first file of another section the files do not land in (the next ones
---first), not the moved file.
---@param st fugitive.SummaryState
---@param items table[]
---@param l1 integer
---@param l2 integer
---@return {section: string, paths: table<string, true>, target: {section: string, path: string}?}?
local function cursor_after_move(st, items, l1, l2)
  local section
  local moved = {}
  for _, it in ipairs(items) do
    if it.type ~= "file" and it.type ~= "patch" then
      return nil
    end
    section = section or it.section
    if it.section ~= section then
      return nil
    end
    moved[it.entry.path] = true
  end
  if not section then
    return nil
  end
  -- hunks: only of one file
  if items[1].type == "patch" and vim.tbl_count(moved) > 1 then
    return nil
  end
  local before, after
  local firsts, order = {}, {}
  for lnum, i in ipairs(st.info) do
    if i.kind == "file" and file_sections_set[i.section] then
      if not firsts[i.section] then
        firsts[i.section] = i.entry.path
        table.insert(order, i.section)
      end
      if i.section == section and not moved[i.entry.path] then
        if lnum < l1 then
          before = i.entry.path
        elseif lnum > l2 and not after then
          after = i.entry.path
        end
      end
    end
  end
  local target = after or before
  if target then
    return { section = section, paths = moved, target = { section = section, path = target } }
  end
  -- the section is empty now: the first file of another section, the ones
  -- below first, skipping where the files land
  local lands = section == "Staged" and { Unstaged = true, Untracked = true } or { Staged = true }
  local here
  for k, sec in ipairs(order) do
    if sec == section then
      here = k
    end
  end
  local candidates = {}
  for k = (here or 0) + 1, #order do
    table.insert(candidates, order[k])
  end
  for k = (here or #order + 1) - 1, 1, -1 do
    table.insert(candidates, order[k])
  end
  for _, sec in ipairs(candidates) do
    if not lands[sec] then
      return {
        section = section,
        paths = moved,
        target = { section = sec, path = firsts[sec] },
      }
    end
  end
  return { section = section, paths = moved }
end

-- Staging is routine: errors notify (from run_chain), success is silent and
-- shows in the refreshed summary.
local function do_cmds(buf, builder, visual)
  local st = state(buf)
  local l1, l2 = range(visual)
  local items = M.selection(buf, l1, l2)
  local cmds, err = builder(st, items)
  if not cmds then
    notify.error(err)
    return
  end
  if #cmds == 0 then
    return
  end
  fold_moved(st, items)
  st.pending_cursor = cursor_after_move(st, items, l1, l2)
  local pending = st.pending_cursor
  M.run_chain(st.repo, cmds, function()
    -- drop it once the summary shows the result (or the command failed)
    summary().refresh(buf, function()
      if st.pending_cursor == pending then
        st.pending_cursor = nil
      end
    end)
  end)
end

function M.stage(buf, visual)
  do_cmds(buf, stage_cmds, visual)
end

function M.unstage(buf, visual)
  local st = state(buf)
  local i = st and not visual and st.info[vim.fn.line(".")]
  if i and i.kind == "discarded" then
    -- `u` on the "Discarded:" hint line restores it (§4.2)
    return require("nvim-fugitive.discard").restore_latest(st.repo)
  end
  do_cmds(buf, unstage_cmds, visual)
end

function M.toggle(buf, visual)
  do_cmds(buf, function(st, items)
    local to_stage, to_unstage = {}, {}
    for _, it in ipairs(items) do
      if it.section == "Staged" then
        table.insert(to_unstage, it)
      else
        table.insert(to_stage, it)
      end
    end
    local c1, e1, p1 = stage_cmds(st, to_stage)
    if not c1 then
      return nil, e1
    end
    local c2, e2, p2 = unstage_cmds(st, to_unstage)
    if not c2 then
      return nil, e2
    end
    return vim.list_extend(c1 --[[@as table]], c2 --[[@as table]]),
      nil,
      vim.list_extend(p1 or {}, p2 or {})
  end, visual)
end

-- ---------------------------------------------------------------------------
-- Inline diffs and folds

---The foldable item a line belongs to: itself (a directory, file, commit
---or stash), or, on an inline diff, the file (commit, stash) the diff is of.
---@param i fugitive.LineInfo?
---@return fugitive.LineInfo?
local function node_of(i)
  return summary_items.foldable(i and i.item)
end

---Whether a foldable line shows what is under it.
local function shown(line)
  if line.kind == "dir" then
    return not line.collapsed
  end
  return line.open or false
end

---Refresh, then put the cursor on the line of `node`, if given.
---@param node fugitive.FoldNode?
local function refresh_to(buf, st, node)
  summary().refresh(buf, function()
    if not node then
      return
    end
    for lnum, i in ipairs(st.info) do
      if i.fold and i.fold.kind == node.kind and i.fold.id == node.id then
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
        return
      end
    end
  end)
end

---`=`, `<`, `>`: open, close or toggle the node of each line (a directory,
---or a file's, commit's or stash's diff). Closing one from inside its diff
---moves the cursor to it.
---@param mode "toggle"|"show"|"hide"
function M.inline(buf, mode, visual)
  local st = state(buf)
  if not st then
    return
  end
  local l1, l2 = range(visual)
  local changed, cursor_to = false, nil
  local done = {}
  for lnum = l1, l2 do
    local i = st.info[lnum]
    local node = node_of(i)
    if node and not done[node] then
      done[node] = true
      local want = mode == "show"
      if mode == "toggle" then
        want = not shown(node)
      end
      if want ~= shown(node) then
        if want then
          fold.set(st.open, node.fold, true)
        else
          fold.close(st.open, st.info, node)
          if node ~= i then
            cursor_to = node.fold
          end
        end
        changed = true
      end
    end
  end
  if changed then
    refresh_to(buf, st, cursor_to)
  end
end

---<BS>: on an inline diff, close that diff; on an open directory, fold it;
---anywhere else (a file, a folded directory), fold what it sits under: its
---directory, or the expanded untracked directory listing it.
function M.fold_dir(buf, visual)
  local st = state(buf)
  if not st then
    return
  end
  local l1, l2 = range(visual)
  local target
  for lnum = l1, l2 do
    local i = st.info[lnum]
    local node
    if i and i.kind == "dir" and not i.collapsed then
      node = i -- this directory
    elseif i then
      node = i.parent -- the diff's file, or what the line sits under
    end
    if node then
      fold.close(st.open, st.info, node)
      target = node.fold
    end
  end
  if target then
    refresh_to(buf, st, target)
  end
end

return M
