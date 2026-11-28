---@mod nvim-fugitive.buffers.summary.items What the lines of the summary are.
---
---The renderer decides once what each line belongs to (render.link_items):
---every line has an `item` (a heading, file, directory, hunk, commit,
---stash, …), and every item knows its lines and what encloses it. Actions
---ask here instead of looking at neighbouring lines.

local M = {}

---The item of line `lnum`, or nil (a blank line).
---@param st fugitive.SummaryState
---@param lnum integer
---@return fugitive.LineInfo?
function M.at(st, lnum)
  local i = st and st.info[lnum]
  return i and i.item
end

---The distinct items of lines l1..l2, in order.
---@param st fugitive.SummaryState
---@return fugitive.LineInfo[]
function M.in_range(st, l1, l2)
  local out, seen = {}, {}
  for l = l1, l2 do
    local it = M.at(st, l)
    if it and not seen[it] then
      seen[it] = true
      table.insert(out, it)
    end
  end
  return out
end

---The item that folds or opens for `item`: itself (a directory, file,
---commit or stash), or the file (commit, stash) a hunk is part of.
---@param item fugitive.LineInfo?
---@return fugitive.LineInfo?
function M.foldable(item)
  while item and not item.fold do
    item = item.parent
  end
  return item
end

---What encloses `item`: its directory, file or listing parent, else its
---section heading.
---@param item fugitive.LineInfo
---@return fugitive.LineInfo?
function M.enclosing(item)
  if item.kind == "section" then
    return nil
  end
  return item.parent or item.section_item
end

---How deep `item` is: 1 for a section heading, one more per enclosing item.
---@param item fugitive.LineInfo
---@return integer
function M.depth(item)
  local n = 1
  local it = M.enclosing(item)
  while it do
    n = n + 1
    it = M.enclosing(it)
  end
  return n
end

return M
