---@mod nvim-fugitive.conflict Conflict-marker actions in the work tree (§4.3).
---
---Buffers of files containing conflict markers get `]x`/`[x` to jump
---between conflict blocks and maps to choose ours / theirs / both / none
---for the block under the cursor. Regions are highlighted with extmarks.
---Supports the "merge" and "diff3"/"zdiff3" marker styles.

local M = {}

local ns = vim.api.nvim_create_namespace("fugitive_conflict")

---@class fugitive.Conflict
---@field start integer 1-based line of "<<<<<<<"
---@field base integer? line of "|||||||" (diff3)
---@field mid integer line of "======="
---@field finish integer line of ">>>>>>>"

---Find conflict blocks in a list of lines.
---@param lines string[]
---@return fugitive.Conflict[]
function M.parse(lines)
  local out = {}
  local cur
  for i, l in ipairs(lines) do
    if l:match("^<<<<<<<") and (l == "<<<<<<<" or l:sub(8, 8) == " ") then
      cur = { start = i }
    elseif cur and not cur.mid and l:match("^|||||||") then
      cur.base = i
    elseif cur and not cur.mid and (l == "=======" or l:match("^======= ")) then
      cur.mid = i
    elseif cur and cur.mid and l:match("^>>>>>>>") and (l == ">>>>>>>" or l:sub(8, 8) == " ") then
      cur.finish = i
      table.insert(out, cur)
      cur = nil
    end
  end
  return out
end

---Resolution of a block as lines.
---@param lines string[]
---@param c fugitive.Conflict
---@param choice "ours"|"theirs"|"both"|"none"|"base"
---@return string[]
function M.resolve_block(lines, c, choice)
  local ours = vim.list_slice(lines, c.start + 1, (c.base or c.mid) - 1)
  local theirs = vim.list_slice(lines, c.mid + 1, c.finish - 1)
  if choice == "ours" then
    return ours
  elseif choice == "theirs" then
    return theirs
  elseif choice == "both" then
    return vim.list_extend(ours, theirs)
  elseif choice == "base" and c.base then
    return vim.list_slice(lines, c.base + 1, c.mid - 1)
  end
  return {}
end

---@param buf integer
---@return fugitive.Conflict[]
function M.conflicts(buf)
  return M.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

---Block containing `lnum` (or nil).
function M.at(buf, lnum)
  for _, c in ipairs(M.conflicts(buf)) do
    if lnum >= c.start and lnum <= c.finish then
      return c
    end
  end
end

---Highlight conflict regions.
---@param buf integer
function M.highlight(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, c in ipairs(M.conflicts(buf)) do
    local function hl(from, to, group)
      for l = from, to do
        pcall(
          vim.api.nvim_buf_set_extmark,
          buf,
          ns,
          l - 1,
          0,
          { line_hl_group = group, priority = 90 }
        )
      end
    end
    hl(c.start, c.start, "FugitiveConflictMarker")
    hl(c.start + 1, (c.base or c.mid) - 1, "FugitiveConflictOurs")
    if c.base then
      hl(c.base, c.base, "FugitiveConflictMarker")
      hl(c.base + 1, c.mid - 1, "FugitiveConflictBase")
    end
    hl(c.mid, c.mid, "FugitiveConflictMarker")
    hl(c.mid + 1, c.finish - 1, "FugitiveConflictTheirs")
    hl(c.finish, c.finish, "FugitiveConflictMarker")
  end
end

local function define_highlights()
  local set = function(name, link)
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  set("FugitiveConflictMarker", "DiffText")
  set("FugitiveConflictOurs", "DiffAdd")
  set("FugitiveConflictTheirs", "DiffChange")
  set("FugitiveConflictBase", "DiffDelete")
end

---Replace the block under the cursor with `choice`.
---@param choice "ours"|"theirs"|"both"|"none"|"base"
function M.choose(choice, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local c = M.at(buf, lnum)
  if not c then
    require("nvim-fugitive.ui.notify").warn("no conflict under the cursor")
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local repl = M.resolve_block(lines, c, choice)
  vim.api.nvim_buf_set_lines(buf, c.start - 1, c.finish, false, repl)
  pcall(
    vim.api.nvim_win_set_cursor,
    0,
    { math.max(1, math.min(c.start, vim.api.nvim_buf_line_count(buf))), 0 }
  )
  M.highlight(buf)
end

---Jump to the next/previous conflict block (wraps like `]c` does not).
---@param dir 1|-1
function M.jump(dir, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local blocks = M.conflicts(buf)
  local count = vim.v.count1
  local target
  if dir > 0 then
    for _, c in ipairs(blocks) do
      if c.start > lnum then
        count = count - 1
        target = c.start
        if count == 0 then
          break
        end
      end
    end
  else
    for i = #blocks, 1, -1 do
      if blocks[i].start < lnum then
        count = count - 1
        target = blocks[i].start
        if count == 0 then
          break
        end
      end
    end
  end
  if target then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

---Action table for the conflict map table.
function M.actions(buf)
  return {
    next_conflict = function()
      M.jump(1, buf)
    end,
    prev_conflict = function()
      M.jump(-1, buf)
    end,
    choose_ours = function()
      M.choose("ours", buf)
    end,
    choose_theirs = function()
      M.choose("theirs", buf)
    end,
    choose_both = function()
      M.choose("both", buf)
    end,
    choose_none = function()
      M.choose("none", buf)
    end,
    choose_base = function()
      M.choose("base", buf)
    end,
  }
end

---Attach maps and highlights to a buffer that has conflict markers.
---Called on BufReadPost/BufWritePost for work-tree files.
---@param buf integer
function M.check(buf)
  if vim.g.fugitive_no_maps and vim.g.fugitive_no_maps ~= 0 then
    -- global maps disabled: still highlight
    if #M.conflicts(buf) > 0 then
      define_highlights()
      M.highlight(buf)
    end
    return
  end
  local has = false
  local n = math.min(vim.api.nvim_buf_line_count(buf), 100000)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, n, false)) do
    if l:match("^<<<<<<< ") or l == "<<<<<<<" then
      has = true
      break
    end
  end
  if not has then
    if vim.b[buf].fugitive_conflict then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    return
  end
  define_highlights()
  M.highlight(buf)
  if not vim.b[buf].fugitive_conflict then
    vim.b[buf].fugitive_conflict = true
    require("nvim-fugitive.maps").apply(buf, "conflict", M.actions(buf))
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
      buffer = buf,
      callback = function()
        M.highlight(buf)
      end,
    })
  end
end

return M
