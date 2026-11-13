---@mod nvim-fugitive.buffers.summary.tree A section's files as a directory tree.
---
---Turns the entries of one summary section (sorted by path, as git lists
---them) into the lines of a tree: directory nodes and file nodes in display
---order, each with its depth. With `compact`, a directory with only one
---changed file is not a level of its own (the file keeps its path), and a
---directory with no files of its own and one subdirectory merges with it
---(`lua/nvim-fugitive/`).

local M = {}

---@class fugitive.TreeNode
---@field type "dir"|"file"
---@field depth integer how many directory lines enclose it
---@field name string path relative to the enclosing directory line
---@field base string path of the enclosing directory line ("" at the top)
---@field dir? string directory: its path, with a trailing slash
---@field entries? fugitive.StatusEntry[] directory: every file under it
---@field entry? fugitive.StatusEntry file

local function new_dir(path)
  return { path = path, files = {}, dirs = {}, count = 0 }
end

---@param entries fugitive.StatusEntry[]
---@param opts {compact: boolean}
---@return fugitive.TreeNode[]
function M.build(entries, opts)
  local root = new_dir("")
  for _, e in ipairs(entries) do
    -- an untracked directory git reports as "dir/" is a leaf like a file
    local segs = vim.split((e.path:gsub("/$", "")), "/", { plain = true })
    local node = root
    node.count = node.count + 1
    for k = 1, #segs - 1 do
      local child = node.dirs[segs[k]]
      if not child then
        child = new_dir(node.path .. segs[k] .. "/")
        node.dirs[segs[k]] = child
      end
      child.count = child.count + 1
      node = child
    end
    table.insert(node.files, { key = e.path:sub(#node.path + 1), entry = e })
  end

  local function under(dir)
    return vim.tbl_filter(function(e)
      return e.path:sub(1, #dir) == dir
    end, entries)
  end
  local function only_file(dir)
    while #dir.files == 0 do
      local _, child = next(dir.dirs)
      dir = child
    end
    return dir.files[1].entry
  end

  local out = {}
  local function emit(dir, depth, base)
    -- files and directories in git's order: a directory sorts as "name/"
    local children = {}
    for _, f in ipairs(dir.files) do
      table.insert(children, { key = f.key, entry = f.entry })
    end
    for name, d in pairs(dir.dirs) do
      table.insert(children, { key = name .. "/", dir = d })
    end
    table.sort(children, function(a, b)
      return a.key < b.key
    end)
    for _, c in ipairs(children) do
      if c.entry then
        table.insert(out, {
          type = "file",
          depth = depth,
          base = base,
          name = c.entry.path:sub(#base + 1),
          entry = c.entry,
        })
      elseif opts.compact and c.dir.count == 1 then
        local e = only_file(c.dir)
        table.insert(
          out,
          { type = "file", depth = depth, base = base, name = e.path:sub(#base + 1), entry = e }
        )
      else
        local d = c.dir
        if opts.compact then
          while #d.files == 0 and vim.tbl_count(d.dirs) == 1 do
            local _, child = next(d.dirs)
            d = child
          end
        end
        table.insert(out, {
          type = "dir",
          depth = depth,
          base = base,
          name = d.path:sub(#base + 1),
          dir = d.path,
          entries = under(d.path),
        })
        emit(d, depth + 1, d.path)
      end
    end
  end
  emit(root, 0, "")
  return out
end

---`target` relative to the directory `base` ("" for the top), with `../`
---where it lies outside it.
---@param target string
---@param base string
---@return string
function M.relative(target, base)
  if target:sub(1, #base) == base then
    return target:sub(#base + 1)
  end
  local b = vim.split(base:gsub("/$", ""), "/", { plain = true })
  local t = vim.split(target, "/", { plain = true })
  local common = 0
  while common < #b and common < #t - 1 and b[common + 1] == t[common + 1] do
    common = common + 1
  end
  return string.rep("../", #b - common) .. table.concat(t, "/", common + 1)
end

---The text a node shows: its name relative to its directory line, or its
---full path; a rename shows both sides.
---@param node fugitive.TreeNode
---@param paths "name"|"full"
---@return string
function M.label(node, paths)
  if node.type == "dir" then
    return paths == "full" and node.dir or node.name
  end
  local e = assert(node.entry, "a file node has an entry")
  local name = paths == "full" and e.path or node.name
  if e.orig then
    local old = paths == "full" and e.orig or M.relative(e.orig, node.base)
    return old .. " -> " .. name
  end
  return name
end

return M
