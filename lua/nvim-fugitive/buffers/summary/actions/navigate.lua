---@mod nvim-fugitive.buffers.summary.actions.navigate Moving between items, files, sections and hunks.

local render = require("nvim-fugitive.buffers.summary.render")
local util = require("nvim-fugitive.buffers.summary.actions.util")
local summary = util.summary
local state = util.state

local M = {}

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

local item_kinds = {
  file = true,
  dir = true,
  commit = true,
  rebase = true,
  stash = true,
  hunk = true,
  submodule = true,
}

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
function M.stage_jump(buf, sections)
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

return M
