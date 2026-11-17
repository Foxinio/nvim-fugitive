---@mod nvim-fugitive.buffers.summary.fold What is open in the summary.
---
---One record for every foldable node: directories (open by default), and
---files, commits and stashes, whose inline diff (or listing) is closed by
---default. Only nodes the user changed are stored: directories in one table,
---the others in another, so a directory and a file with the same path never
---share an entry (files, commits and stashes cannot clash: their sections
---differ). The renderer tags each line with its node (`fold`) and the line it
---sits under (`parent`); the actions work on those, never on keys or line
---positions.

local M = {}

---@alias fugitive.FoldKind "dir"|"file"|"commit"|"stash"

---@class fugitive.FoldNode
---@field kind fugitive.FoldKind
---@field id string section .. "\0" .. path (or commit, or stash ref)

---@class fugitive.FoldState
---@field dir table<string, boolean> directories the user folded or unfolded
---@field diff table<string, boolean> files, commits and stashes opened or closed

---@param kind fugitive.FoldKind
---@param section string
---@param id string path, commit or stash ref
---@return fugitive.FoldNode
function M.node(kind, section, id)
  return { kind = kind, id = section .. "\0" .. id }
end

---@return fugitive.FoldState
function M.new()
  return { dir = {}, diff = {} }
end

local function store(open, node)
  return node.kind == "dir" and open.dir or open.diff
end

---Whether `node` is open: what the user set, else its kind's default.
---@param open fugitive.FoldState
---@param node fugitive.FoldNode
---@return boolean
function M.is_open(open, node)
  local v = store(open, node)[node.id]
  if v == nil then
    return node.kind == "dir"
  end
  return v
end

---@param open fugitive.FoldState
---@param node fugitive.FoldNode
---@param value boolean
function M.set(open, node, value)
  store(open, node)[node.id] = value
end

---Back to the kind's default.
---@param open fugitive.FoldState
---@param node fugitive.FoldNode
function M.reset(open, node)
  store(open, node)[node.id] = nil
end

---Whether line `l` sits under line `ancestor` (through `parent` links).
local function under(l, ancestor)
  local p = l.parent
  while p do
    if p == ancestor then
      return true
    end
    p = p.parent
  end
  return false
end

---Close a line's node, and close what was opened under it (the diffs of its
---files, its expanded untracked directories), so that opening it again
---shows them closed. Directories under it keep their own state.
---@param open fugitive.FoldState
---@param info fugitive.LineInfo[] the rendered lines
---@param line fugitive.LineInfo
function M.close(open, info, line)
  M.set(open, line.fold, false)
  for _, l in ipairs(info) do
    if l.fold and l.fold.kind ~= "dir" and under(l, line) then
      M.reset(open, l.fold)
    end
  end
end

---What the snapshot needs: the files, commits and stashes set open (true)
---or closed (false), by section .. "\0" .. id. The table itself, not a
---copy: something opened while a refresh runs is picked up by it.
---@param open fugitive.FoldState
---@return table<string, boolean>
function M.expansions(open)
  return open.diff
end

return M
