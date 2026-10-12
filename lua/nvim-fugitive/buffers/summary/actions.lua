---@mod nvim-fugitive.buffers.summary.actions Summary buffer actions (F6–F11, F30).

local object = require("nvim-fugitive.object")
local diff_mod = require("nvim-fugitive.git.diff")
local notify = require("nvim-fugitive.ui.notify")
local render = require("nvim-fugitive.buffers.summary.render")

local M = {}

local function summary()
  return require("nvim-fugitive.buffers.summary")
end

---State of a summary buffer; actions only run in summary buffers.
---@param buf integer
---@return fugitive.SummaryState
local function state(buf)
  return assert(summary().state(buf), "not a summary buffer")
end

-- ---------------------------------------------------------------------------
-- Selection

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
    local i = st.info[l1]
    if not i then
      return {}
    end
    if i.kind == "section" then
      return {
        {
          type = "section",
          section = i.section,
          entries = section_entries(st, i.section),
          info = i,
        },
      }
    elseif i.kind == "file" or i.kind == "diffmeta" then
      return { { type = "file", section = i.section, entry = i.entry, info = i } }
    elseif i.kind == "hunk" or i.kind == "diffline" then
      return {
        {
          type = "patch",
          section = i.section,
          entry = i.entry,
          file = i.file,
          hunks = { { hunk = i.file.hunks[i.hunk_index] } },
          info = i,
        },
      }
    elseif i.kind == "commit" or i.kind == "rebase" then
      return { { type = "commit", section = i.section, info = i } }
    elseif i.kind == "stash" then
      return { { type = "stash", section = i.section, info = i } }
    elseif i.kind == "header" then
      return { { type = "header", info = i } }
    elseif i.kind == "discarded" then
      return { { type = "discarded", info = i } }
    end
    return {}
  end
  -- a range: whole files if any file line is included, else selected lines
  local files, seen = {}, {}
  local patches, order = {}, {}
  for lnum = l1, l2 do
    local i = st.info[lnum]
    if i and i.kind == "file" then
      local k = i.section .. "\0" .. i.entry.path
      if not seen[k] then
        seen[k] = true
        table.insert(files, { type = "file", section = i.section, entry = i.entry, info = i })
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

local function range(visual)
  if visual then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return math.min(a, b), math.max(a, b)
  end
  local l = vim.fn.line(".")
  return l, l
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

local function has_head(st)
  return st.snap and st.snap.status and st.snap.status.oid ~= nil
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
  M.run_chain(st.repo, cmds)
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
-- Inline diffs

local function file_item_at(st, lnum)
  local i = st.info[lnum]
  if
    i
    and (
      i.kind == "file"
      or i.kind == "stash"
      or i.kind == "hunk"
      or i.kind == "diffline"
      or i.kind == "diffmeta"
    )
  then
    return i
  end
end

---What `=` expands for a line: a file path, or a stash ref.
local function expand_id(i)
  if i.section == "Stash" then
    return i.ref
  end
  return i.entry.path
end

---@param mode "toggle"|"show"|"hide"
function M.inline(buf, mode, visual)
  local st = state(buf)
  if not st then
    return
  end
  local l1, l2 = range(visual)
  local changed = false
  local cursor_to_file
  for lnum = l1, l2 do
    local i = file_item_at(st, lnum)
    if i then
      local key = render.expand_key(i.section, expand_id(i))
      local want
      if mode == "toggle" then
        want = not st.expanded[key]
      else
        want = mode == "show"
      end
      if (st.expanded[key] or false) ~= want then
        st.expanded[key] = want or nil
        changed = true
        if not want and i.kind ~= "file" and i.kind ~= "stash" then
          cursor_to_file = expand_id(i)
        end
      end
    end
  end
  if changed then
    summary().refresh(buf, function()
      if cursor_to_file then
        for lnum, i in ipairs(st.info) do
          if (i.kind == "file" or i.kind == "stash") and expand_id(i) == cursor_to_file then
            pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
            break
          end
        end
      end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Navigation

local function jump_kind(buf, kinds, dir, count)
  local st = state(buf)
  if not st then
    return
  end
  count = count or vim.v.count1
  local lnum = vim.fn.line(".")
  local found
  for _ = 1, count do
    local l = lnum + dir
    while l >= 1 and l <= #st.info do
      if kinds[st.info[l].kind] then
        found = l
        lnum = l
        break
      end
      l = l + dir
    end
    if l < 1 or l > #st.info then
      break
    end
  end
  if found then
    vim.api.nvim_win_set_cursor(0, { found, 0 })
  end
  return found
end

local item_kinds = { file = true, commit = true, rebase = true, stash = true, hunk = true }

function M.next_item(buf)
  jump_kind(buf, item_kinds, 1)
end

function M.prev_item(buf)
  jump_kind(buf, item_kinds, -1)
end

function M.next_file(buf)
  jump_kind(buf, { file = true }, 1)
end

function M.prev_file(buf)
  jump_kind(buf, { file = true }, -1)
end

function M.next_section(buf)
  jump_kind(buf, { section = true }, 1)
end

function M.prev_section(buf)
  jump_kind(buf, { section = true }, -1)
end

local function section_ends(st)
  local ends = {}
  for l, i in ipairs(st.info) do
    local nxt = st.info[l + 1]
    if
      i.kind ~= "blank"
      and i.kind ~= "header"
      and i.kind ~= "discarded"
      and (not nxt or nxt.kind == "blank")
    then
      table.insert(ends, l)
    end
  end
  return ends
end

function M.next_section_end(buf)
  local st = state(buf)
  local cur = vim.fn.line(".")
  local n = vim.v.count1
  for _, l in ipairs(section_ends(st)) do
    if l > cur then
      n = n - 1
      if n == 0 then
        return vim.api.nvim_win_set_cursor(0, { l, 0 })
      end
    end
  end
end

function M.prev_section_end(buf)
  local st = state(buf)
  local cur = vim.fn.line(".")
  local ends = section_ends(st)
  local n = vim.v.count1
  for k = #ends, 1, -1 do
    if ends[k] < cur then
      n = n - 1
      if n == 0 then
        return vim.api.nvim_win_set_cursor(0, { ends[k], 0 })
      end
    end
  end
end

---Next/previous hunk; on an unexpanded file, expand it first (upstream).
function M.next_hunk(buf, dir)
  dir = dir or 1
  if vim.wo.diff then
    return vim.cmd("normal! " .. vim.v.count1 .. (dir > 0 and "]c" or "[c"))
  end
  local st = state(buf)
  if not st then
    return
  end
  local lnum = vim.fn.line(".")
  local i = st.info[lnum]
  if
    dir > 0
    and i
    and i.kind == "file"
    and not st.expanded[render.expand_key(i.section, i.entry.path)]
  then
    local path, section = i.entry.path, i.section --[[@as string]]
    st.expanded[render.expand_key(section, path)] = true
    summary().refresh(buf, function()
      for l, x in ipairs(st.info) do
        if x.kind == "hunk" and x.section == section and x.entry.path == path then
          pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
          return
        end
      end
    end)
    return
  end
  jump_kind(buf, { hunk = true }, dir)
end

---`i`: next file or hunk, expanding inline diffs automatically.
function M.next_expanded_hunk(buf)
  local st = state(buf)
  if not st then
    return
  end
  local count = vim.v.count1
  local function step(n)
    if n == 0 then
      return
    end
    local cur = vim.fn.line(".")
    local ci = st.info[cur]
    if
      ci
      and ci.kind == "file"
      and not st.expanded[render.expand_key(ci.section, ci.entry.path)]
    then
      local path, section = ci.entry.path, ci.section --[[@as string]]
      st.expanded[render.expand_key(section, path)] = true
      summary().refresh(buf, function()
        for l, x in ipairs(st.info) do
          if x.kind == "hunk" and x.section == section and x.entry.path == path then
            pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
            return step(n - 1)
          end
        end
        jump_kind(buf, { file = true, hunk = true }, 1, 1)
        step(n - 1)
      end)
      return
    end
    jump_kind(buf, { file = true, hunk = true }, 1, 1)
    local ni = st.info[vim.fn.line(".")]
    if
      ni
      and ni.kind == "file"
      and not st.expanded[render.expand_key(ni.section, ni.entry.path)]
    then
      return step(n) -- expand the file we landed on
    end
    step(n - 1)
  end
  step(count)
end

---gu / gU / gs / gp / gP / gr
local function stage_jump(buf, sections)
  local st = state(buf)
  if not st then
    return
  end
  local count = vim.v.count
  for _, name in ipairs(sections) do
    local n = 0
    for l, i in ipairs(st.info) do
      if
        i.section == name
        and i.kind ~= "section"
        and i.kind ~= "hunk"
        and i.kind ~= "diffline"
        and i.kind ~= "diffmeta"
      then
        n = n + 1
        if count == 0 or n == count then
          return vim.api.nvim_win_set_cursor(0, { l, 0 })
        end
      end
    end
    -- count past the end: last item of the section
    if n > 0 and count > 0 then
      for l = #st.info, 1, -1 do
        local i = st.info[l]
        if i.section == name and i.kind ~= "section" then
          return vim.api.nvim_win_set_cursor(0, { l, 0 })
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Opening things

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
  if i.section == "Stash" and i.file then
    -- a line of an expanded stash: the stashed file at that line
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

function M.open(buf, how)
  local t = M.target(buf, vim.fn.line("."))
  if t.submodule then
    local sub = require("nvim-fugitive.git.repo").find(t.submodule)
    if not sub or sub.worktree ~= t.submodule then
      notify.warn("submodule is not checked out: " .. t.submodule)
      return
    end
    local mods = ({ split = "", vsplit = "vertical", tab = "tab" })[how]
    if how == "edit" then
      vim.cmd("edit " .. vim.fn.fnameescape(summary().bufname(sub)))
      return
    end
    return summary().open(sub, { mods = mods ~= "" and mods or "aboveleft" })
  end
  if not t.target then
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
  require("nvim-fugitive.buffers.reader").open(t.target, how, t.lnum)
end

-- ---------------------------------------------------------------------------
-- Diffs

function M.diff(buf, layout)
  local st = state(buf)
  local i = st.info[vim.fn.line(".")]
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
  end
  require("nvim-fugitive.cmd.git").run(args, { repo = st.repo })
end

-- ---------------------------------------------------------------------------
-- Commands on the cursor commit

---Commit under the cursor (upstream's s:SquashArgument).
function M.cursor_commit(buf)
  local st = state(buf)
  local i = st and st.info[vim.fn.line(".")]
  if i and (i.kind == "commit" or i.kind == "rebase") then
    return i.commit
  end
  return ""
end

local function rebase_argument(buf)
  local c = M.cursor_commit(buf)
  return c ~= "" and (" " .. c .. "^") or ""
end

local function git(buf, args, opts)
  local st = state(buf)
  opts = vim.tbl_extend("force", { repo = st and st.repo, skip_picker = true }, opts or {})
  return require("nvim-fugitive.cmd.git").run(args, opts)
end

---Put a command on the command line for the user to complete/confirm.
local function cmdline(text, home)
  local keys = ":" .. text
  if home then
    keys = keys .. "<Home>"
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

local function split_words(s)
  return vim.split(s, " ", { trimempty = true })
end

---Start an interactive rebase and turn the first "pick" of the todo list
---into `word` (rw/rm/rd).
local function rebase_retodo(buf, word)
  local arg = rebase_argument(buf)
  local group = vim.api.nvim_create_augroup("fugitive_rebase_retodo", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FugitiveEditor",
    once = true,
    callback = function(ev)
      local b = ev.data and ev.data.buf
      if b and vim.api.nvim_buf_get_name(b):match("git%-rebase%-todo$") then
        local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
        local new = first:gsub("^pick", word, 1)
        vim.api.nvim_buf_set_lines(b, 0, 1, false, { new })
      end
    end,
  })
  git(buf, vim.list_extend({ "rebase", "--interactive" }, split_words(arg)))
end

-- ---------------------------------------------------------------------------
-- Ignore / exclude

local function exclude_path(repo, count)
  if count and count > 0 then
    return repo:abs(".gitignore")
  end
  return repo.common_dir .. "/info/exclude"
end

function M.ignore(buf, visual)
  local st = state(buf)
  local l1, l2 = range(visual)
  local paths = {}
  for _, it in ipairs(M.selection(buf, l1, l2)) do
    if it.type == "file" then
      table.insert(paths, it.entry.path)
    end
  end
  local file = exclude_path(st.repo, vim.v.count)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.cmd("split " .. vim.fn.fnameescape(file))
  if #paths > 0 then
    local lines = {}
    for _, p in ipairs(paths) do
      table.insert(lines, "/" .. p:gsub("([%[%]*?!#\\])", "\\%1"))
    end
    local last = vim.api.nvim_buf_line_count(0)
    if last == 1 and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "" then
      vim.api.nvim_buf_set_lines(0, 0, 1, false, lines)
    else
      vim.api.nvim_buf_set_lines(0, last, last, false, lines)
    end
    vim.cmd("silent write")
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    require("nvim-fugitive").changed(st.repo)
  end
end

function M.open_exclude(buf)
  local st = state(buf)
  local file = exclude_path(st.repo, vim.v.count)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.cmd("split " .. vim.fn.fnameescape(file))
end

-- ---------------------------------------------------------------------------
-- Patch (interactive) and discard

function M.patch(buf, visual)
  local st = state(buf)
  local l1, l2 = range(visual)
  local add, reset, intent = {}, {}, {}
  for _, it in ipairs(M.selection(buf, l1, l2)) do
    local entries = it.type == "section" and it.entries or (it.entry and { it.entry }) or {}
    for _, e in ipairs(entries) do
      if it.section == "Staged" then
        table.insert(reset, e.path)
      elseif it.section == "Untracked" then
        table.insert(intent, e.path)
        table.insert(add, e.path)
      elseif it.section == "Unstaged" then
        table.insert(add, e.path)
      end
    end
  end
  if #intent > 0 then
    st.repo:sync(vim.list_extend({ "add", "--intent-to-add", "--" }, intent))
  end
  local term = require("nvim-fugitive.ui.terminal")
  local done = function()
    require("nvim-fugitive").changed(st.repo)
  end
  if #reset > 0 then
    term.run(st.repo, vim.list_extend({ "reset", "--patch", "--" }, reset), { on_exit = done })
  elseif #add > 0 then
    term.run(st.repo, vim.list_extend({ "add", "--patch", "--" }, add), { on_exit = done })
  else
    notify.warn("nothing to patch")
  end
end

function M.discard(buf, visual)
  local st = state(buf)
  local count = vim.v.count
  local l1, l2 = range(visual)
  local items = M.selection(buf, l1, l2)
  require("nvim-fugitive.discard").discard(
    st.repo,
    items,
    { count = count, has_head = has_head(st), snap = st.snap }
  )
end

function M.restore_discard(buf)
  local st = state(buf)
  if vim.v.count > 0 then
    return require("nvim-fugitive.discard").pick(nil, st.repo)
  end
  require("nvim-fugitive.discard").restore_latest(st.repo)
end

-- ---------------------------------------------------------------------------
-- The action table

---@param buf integer
---@return table<string, fugitive.Action>
function M.actions(buf)
  local function nx(fn)
    return {
      n = function()
        fn(buf, false)
      end,
      x = function()
        fn(buf, true)
      end,
    }
  end
  local function n(fn, ...)
    local extra = { ... }
    return function()
      fn(buf, unpack(extra))
    end
  end
  local function run(args, mods)
    return function()
      git(buf, args, { mods = mods })
    end
  end
  local function count_ref()
    return "stash@{" .. vim.v.count .. "}"
  end
  local a = {
    stage = nx(M.stage),
    unstage = nx(M.unstage),
    toggle = nx(M.toggle),
    unstage_all = function()
      local st = state(buf)
      M.run_chain(st.repo, {
        {
          args = has_head(st) and { "reset", "-q" } or { "rm", "--cached", "-r", "-q", "--", "." },
        },
      })
    end,
    discard = nx(M.discard),
    restore_discard = n(M.restore_discard),
    inline_toggle = nx(function(b, v)
      M.inline(b, "toggle", v)
    end),
    inline_show = nx(function(b, v)
      M.inline(b, "show", v)
    end),
    inline_hide = nx(function(b, v)
      M.inline(b, "hide", v)
    end),
    patch = nx(M.patch),
    ignore = nx(M.ignore),
    open_exclude = n(M.open_exclude),
    open = n(M.open, "edit"),
    open_split = n(M.open, "split"),
    open_vsplit = n(M.open, "vsplit"),
    open_tab = n(M.open, "tab"),
    open_preview = n(M.open, "pedit"),
    prev_item = n(M.prev_item),
    next_item = n(M.next_item),
    prev_hunk = n(M.next_hunk, -1),
    next_hunk = n(M.next_hunk, 1),
    next_expanded_hunk = n(M.next_expanded_hunk),
    prev_file = n(M.prev_file),
    next_file = n(M.next_file),
    prev_section = n(M.prev_section),
    next_section = n(M.next_section),
    prev_section_end = n(M.prev_section_end),
    next_section_end = n(M.next_section_end),
    jump_untracked = n(stage_jump, { "Untracked", "Unstaged" }),
    jump_unstaged = n(stage_jump, { "Unstaged", "Untracked" }),
    jump_staged = n(stage_jump, { "Staged" }),
    jump_unpushed = n(stage_jump, { "Unpushed" }),
    jump_unpulled = n(stage_jump, { "Unpulled" }),
    jump_rebasing = n(stage_jump, { "Rebasing" }),
    close = function()
      local listed = vim.fn.getbufinfo({ buflisted = 1 })
      if #vim.api.nvim_list_wins() == 1 and #listed <= 1 then
        vim.cmd("quit")
      elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(0, false)
      else
        vim.cmd("bdelete")
      end
    end,
    help = function()
      summary().show_help("summary")
    end,
    reload = function()
      local st = state(buf)
      summary().load(buf, st.repo)
    end,
    cmdline = function()
      local st = state(buf)
      local i = st.info[vim.fn.line(".")]
      local word = ""
      if i and i.entry then
        word = vim.fn.fnameescape(i.entry.path)
      elseif i and i.commit then
        word = i.commit
      elseif i and i.ref then
        word = i.ref
      end
      cmdline(" " .. word, true)
    end,
    diff = n(M.diff, "auto"),
    diff_vertical = n(M.diff, "vertical"),
    diff_horizontal = n(M.diff, "horizontal"),
    diff_close = function()
      require("nvim-fugitive.buffers.diffsplit").close()
    end,
    diff_patch = n(M.diff_patch),
    -- commit
    commit = run({ "commit" }),
    commit_amend = run({ "commit", "--amend" }),
    commit_extend = run({ "commit", "--amend", "--no-edit" }),
    commit_reword = run({ "commit", "--amend", "--only" }),
    commit_verbose = run({ "commit", "-v" }, "tab"),
    commit_amend_verbose = run({ "commit", "-v", "--amend" }, "tab"),
    commit_reset_author = run({ "commit", "--reset-author", "--amend" }),
    commit_reset_author_extend = run({ "commit", "--reset-author", "--amend", "--no-edit" }),
    commit_reset_author_reword = run({ "commit", "--reset-author", "--amend", "--only" }),
    commit_fixup = function()
      cmdline("Git commit --fixup=" .. M.cursor_commit(buf))
    end,
    commit_fixup_rebase = function()
      local c = M.cursor_commit(buf)
      cmdline(
        "Git commit --fixup="
          .. c
          .. " | Git -c sequence.editor=true rebase --interactive --autosquash"
          .. rebase_argument(buf)
      )
    end,
    commit_squash = function()
      cmdline("Git commit --no-edit --squash=" .. M.cursor_commit(buf))
    end,
    commit_squash_rebase = function()
      local c = M.cursor_commit(buf)
      cmdline(
        "Git commit --no-edit --squash="
          .. c
          .. " | Git -c sequence.editor=true rebase --interactive --autosquash"
          .. rebase_argument(buf)
      )
    end,
    commit_squash_edit = function()
      cmdline("Git commit --edit --squash=" .. M.cursor_commit(buf))
    end,
    commit_prompt = function()
      cmdline("Git commit ")
    end,
    commit_verbose_prompt = function()
      cmdline("tab Git commit -v ")
    end,
    -- revert / merge
    revert = function()
      git(buf, { "revert", M.cursor_commit(buf) })
    end,
    revert_no_commit = function()
      git(buf, { "revert", "--no-commit", M.cursor_commit(buf) })
    end,
    revert_prompt = function()
      cmdline("Git revert ")
    end,
    revert_bare = function()
      cmdline("Git revert\r")
    end,
    merge_prompt = function()
      cmdline("Git merge ")
    end,
    merge_bare = function()
      cmdline("Git merge\r")
    end,
    -- checkout / branch (M2)
    checkout = function()
      local c = M.cursor_commit(buf)
      if c == "" then
        notify.warn("no commit under the cursor")
        return
      end
      git(buf, { "checkout", c, "--" })
    end,
    checkout_prompt = function()
      cmdline("Git checkout ")
    end,
    checkout_bare = function()
      cmdline("Git checkout\r")
    end,
    branch_prompt = function()
      cmdline("Git branch ")
    end,
    branch_bare = function()
      cmdline("Git branch\r")
    end,
    -- stash (M2)
    stash_push = function()
      local extra = vim.v.count > 1 and { "--all" }
        or vim.v.count > 0 and { "--include-untracked" }
        or {}
      git(buf, vim.list_extend({ "stash", "push" }, extra))
    end,
    stash_push_keep_index = function()
      local extra = vim.v.count > 1 and { "--all" }
        or vim.v.count > 0 and { "--include-untracked" }
        or {}
      git(buf, vim.list_extend({ "stash", "push", "--keep-index" }, extra))
    end,
    stash_push_staged = run({ "stash", "push", "--staged" }),
    stash_apply_index = function()
      git(buf, { "stash", "apply", "--quiet", "--index", count_ref() })
    end,
    stash_apply = function()
      git(buf, { "stash", "apply", "--quiet", count_ref() })
    end,
    stash_pop_index = function()
      git(buf, { "stash", "pop", "--quiet", "--index", count_ref() })
    end,
    stash_pop = function()
      git(buf, { "stash", "pop", "--quiet", count_ref() })
    end,
    stash_view = function()
      local st = state(buf)
      local url = object.resolve(st.repo, count_ref())
      if not url then
        notify.error("no stash " .. count_ref())
        return
      end
      require("nvim-fugitive.buffers.reader").open(url, "edit")
    end,
    stash_prompt = function()
      cmdline("Git stash ")
    end,
    stash_bare = function()
      cmdline("Git stash\r")
    end,
    -- rebase (M2)
    rebase_interactive = function()
      git(buf, vim.list_extend({ "rebase", "--interactive" }, split_words(rebase_argument(buf))))
    end,
    rebase_autosquash = function()
      git(
        buf,
        vim.list_extend(
          { "-c", "sequence.editor=true", "rebase", "--interactive", "--autosquash" },
          split_words(rebase_argument(buf))
        )
      )
    end,
    rebase_upstream = run({ "rebase", "--interactive", "@{upstream}" }),
    rebase_push = run({ "rebase", "--interactive", "@{push}" }),
    rebase_continue = run({ "rebase", "--continue" }),
    rebase_skip = run({ "rebase", "--skip" }),
    rebase_abort = run({ "rebase", "--abort" }),
    rebase_edit_todo = run({ "rebase", "--edit-todo" }),
    rebase_reword = function()
      rebase_retodo(buf, "reword")
    end,
    rebase_edit = function()
      rebase_retodo(buf, "edit")
    end,
    rebase_drop = function()
      rebase_retodo(buf, "drop")
    end,
    rebase_prompt = function()
      cmdline("Git rebase ")
    end,
    rebase_bare = function()
      cmdline("Git rebase\r")
    end,
    -- bisect: on the commit under the cursor, else on HEAD
    bisect_good = function()
      git(buf, vim.list_extend({ "bisect", "good" }, split_words(M.cursor_commit(buf))))
    end,
    bisect_bad = function()
      git(buf, vim.list_extend({ "bisect", "bad" }, split_words(M.cursor_commit(buf))))
    end,
    bisect_skip = function()
      git(buf, vim.list_extend({ "bisect", "skip" }, split_words(M.cursor_commit(buf))))
    end,
    bisect_reset = run({ "bisect", "reset" }),
  }
  for name, fn in pairs(require("nvim-fugitive.maps").cfile_actions(buf)) do
    a[name] = fn
  end
  return a
end

return M
