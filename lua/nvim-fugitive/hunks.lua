---@mod nvim-fugitive.hunks Work-tree hunks without gitsigns (§5.5 backlog).
---
---The buffer is compared with its index version (vim.text.diff), so
---unsaved changes count. Staging applies a zero-context patch of one hunk
---to the index; resetting puts the index lines back into the buffer.

local notify = require("nvim-fugitive.ui.notify")

local M = {}

---@class fugitive.WorktreeHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---Index lines and hunks of a work-tree buffer.
---@param buf integer
---@return {repo: fugitive.Repo, path: string, index: string[], hunks: fugitive.WorktreeHunk[], noeol: boolean}?, string? err
function M.compute(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return nil, "not a work-tree file"
  end
  local repo = require("nvim-fugitive.git.repo").for_buf(buf)
  if not repo then
    return nil, "not a git repository"
  end
  local path = repo:rel(name)
  if not path or path == "" then
    return nil, "not in the work tree"
  end
  local res = repo:sync({ "cat-file", "blob", ":0:" .. path })
  local index_text = res.code == 0 and res.stdout or ""
  local index = vim.split(index_text, "\n", { plain = true })
  if index[#index] == "" then
    table.remove(index)
  end
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- vim.text.diff is 0.12+; vim.diff (deprecated there) covers 0.11
  ---@diagnostic disable-next-line: deprecated
  local diff = vim.text and vim.text.diff or vim.diff
  local a = #index > 0 and (table.concat(index, "\n") .. "\n") or ""
  local b = table.concat(current, "\n") .. "\n"
  local hunks = {}
  for _, h in
    ipairs(diff(a, b, { result_type = "indices" }) --[[@as integer[][] ]])
  do
    table.insert(hunks, { old_start = h[1], old_count = h[2], new_start = h[3], new_count = h[4] })
  end
  return {
    repo = repo,
    path = path,
    index = index,
    hunks = hunks,
    noeol = index_text ~= "" and index_text:sub(-1) ~= "\n",
  }
end

---The hunk containing (or nearest after) a buffer line.
local function hunk_at(hunks, lnum)
  for _, h in ipairs(hunks) do
    -- a pure deletion (new_count 0) sits on the line before it
    local first = math.max(1, h.new_start)
    local last = h.new_count == 0 and first or (h.new_start + h.new_count - 1)
    if lnum >= first and lnum <= last then
      return h
    end
  end
end

---Jump to the next/previous hunk.
---@param dir 1|-1
function M.jump(dir)
  local data, err = M.compute(vim.api.nvim_get_current_buf())
  if not data then
    notify.warn(err or "no hunks")
    return
  end
  local lnum = vim.fn.line(".")
  local target
  local count = vim.v.count1
  local starts = {}
  for _, h in ipairs(data.hunks) do
    table.insert(starts, math.max(1, h.new_start))
  end
  if dir > 0 then
    for _, s in ipairs(starts) do
      if s > lnum then
        target = s
        count = count - 1
        if count == 0 then
          break
        end
      end
    end
  else
    for i = #starts, 1, -1 do
      if starts[i] < lnum then
        target = starts[i]
        count = count - 1
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

---Zero-context patch of one hunk (old = index, new = buffer).
local function hunk_patch(data, h, lines)
  local out = {
    "diff --git a/" .. data.path .. " b/" .. data.path,
    "--- a/" .. data.path,
    "+++ b/" .. data.path,
    string.format("@@ -%d,%d +%d,%d @@", h.old_start, h.old_count, h.new_start, h.new_count),
  }
  for i = h.old_start, h.old_start + h.old_count - 1 do
    table.insert(out, "-" .. data.index[i])
  end
  if data.noeol and h.old_count > 0 and h.old_start + h.old_count - 1 == #data.index then
    table.insert(out, "\\ No newline at end of file")
  end
  for i = h.new_start, h.new_start + h.new_count - 1 do
    table.insert(out, "+" .. lines[i])
  end
  return table.concat(out, "\n") .. "\n"
end

---Stage the hunk under the cursor (the buffer's version of it).
function M.stage()
  local buf = vim.api.nvim_get_current_buf()
  local data, err = M.compute(buf)
  if not data then
    notify.warn(err or "no hunks")
    return
  end
  local h = hunk_at(data.hunks, vim.fn.line("."))
  if not h then
    notify.warn("no hunk under the cursor")
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local res = data.repo:sync(
    { "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "-" },
    { stdin = hunk_patch(data, h, lines) }
  )
  if res.code ~= 0 then
    notify.error(require("nvim-fugitive.git.exec").error_text(res))
    return
  end
  require("nvim-fugitive").changed(data.repo)
end

---Reset the hunk under the cursor to the index version (in the buffer).
function M.reset()
  local buf = vim.api.nvim_get_current_buf()
  local data, err = M.compute(buf)
  if not data then
    notify.warn(err or "no hunks")
    return
  end
  local h = hunk_at(data.hunks, vim.fn.line("."))
  if not h then
    notify.warn("no hunk under the cursor")
    return
  end
  local old = vim.list_slice(data.index, h.old_start, h.old_start + h.old_count - 1)
  local first = h.new_count == 0 and h.new_start or h.new_start - 1
  vim.api.nvim_buf_set_lines(buf, first, first + h.new_count, false, old)
end

return M
