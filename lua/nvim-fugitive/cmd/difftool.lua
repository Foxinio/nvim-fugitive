---@mod nvim-fugitive.cmd.difftool :Git difftool / :Git mergetool (F19), :Gcd.

local object = require("nvim-fugitive.object")
local notify = require("nvim-fugitive.ui.notify")
local diff_mod = require("nvim-fugitive.git.diff")

local M = {}

---Which two sides `git diff [args]` compares: nil means the work tree,
---":0" the index, anything else a revision.
---@param repo fugitive.Repo
---@param args string[]
---@return {old: string, new: string?, cached: boolean}
function M.sides(repo, args)
  local cached = false
  local revs = {}
  for _, a in ipairs(args) do
    if a == "--" then
      break
    elseif a == "--cached" or a == "--staged" then
      cached = true
    elseif a:sub(1, 1) ~= "-" then
      local x, y = a:match("^(.-)%.%.%.?(.*)$")
      if x then
        table.insert(revs, x == "" and "HEAD" or x)
        table.insert(revs, y == "" and "HEAD" or y)
      elseif repo:rev_parse(a) then
        table.insert(revs, a)
      end
    end
  end
  if cached then
    return { old = revs[1] or "HEAD", new = ":0", cached = true }
  end
  if #revs >= 2 then
    return { old = revs[1], new = revs[2], cached = false }
  end
  if #revs == 1 then
    return { old = revs[1], new = nil, cached = false }
  end
  return { old = ":0", new = nil, cached = false }
end

---Where `path` lives on a side: a work-tree file or a fugitive:// URL.
---@param repo fugitive.Repo
---@param side string? nil = work tree
---@param path string
---@return string?
local function locate(repo, side, path)
  if side == nil then
    return repo:abs(path)
  end
  if side == ":0" then
    return object.format(repo.git_dir, "0", path)
  end
  return object.resolve(repo, side .. ":" .. path)
end

---The old side as an object spec for :Gdiffsplit.
local function old_spec(side, path)
  if side == ":0" then
    return ":0:" .. path
  end
  return side
end

local function fill(items, bang, title)
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if #items == 0 then
    notify.info("nothing to show")
  elseif not bang then
    vim.cmd("silent cfirst")
  end
end

---:Git difftool [-y] [args]
---@param repo fugitive.Repo
---@param args string[] arguments after "difftool"
---@param opts {bang?: boolean}
function M.difftool(repo, args, opts)
  local tabs = false
  local rest = {}
  for _, a in ipairs(args) do
    if a == "-y" or a == "--no-prompt" then
      tabs = true
    else
      table.insert(rest, a)
    end
  end
  local sides = M.sides(repo, rest)
  local names = vim.tbl_contains(rest, "--name-only") or vim.tbl_contains(rest, "--name-status")
  local cmd = { "diff", "--no-color", "--no-ext-diff" }
  vim.list_extend(cmd, rest)
  repo:run(cmd, {}, function(res)
    require("nvim-fugitive.ui.output").record(res, repo.worktree)
    if res.code ~= 0 then
      notify.error(require("nvim-fugitive.git.exec").error_text(res))
      return
    end
    local items = {}
    local files = {}
    if names then
      for line in res.stdout:gmatch("[^\n]+") do
        local status, path = line:match("^(%u%d*)\t(.-)$")
        path = path and (path:match("\t(.*)$") or path) or line
        status = status or "M"
        table.insert(files, { path = path, status = status })
        local target = locate(repo, sides.new, path)
        if target then
          table.insert(items, { filename = target, lnum = 1, text = status })
        end
      end
    else
      for _, f in ipairs(diff_mod.parse(res.stdout)) do
        table.insert(files, { path = f.path, old_path = f.old_path })
        local target = locate(repo, sides.new, f.path)
        if target then
          if #f.hunks == 0 then
            table.insert(items, { filename = target, lnum = 1, text = f.header[2] or "" })
          end
          for _, h in ipairs(f.hunks) do
            table.insert(
              items,
              { filename = target, lnum = math.max(1, h.new_start), text = h.header }
            )
          end
        end
      end
    end
    if tabs then
      local ds = require("nvim-fugitive.buffers.diffsplit")
      for _, f in ipairs(files) do
        local target = locate(repo, sides.new, f.path)
        if target then
          vim.cmd("tabedit " .. vim.fn.fnameescape(target))
          pcall(
            ds.split,
            { against = old_spec(sides.old, f.old_path or f.path), keep_focus = true }
          )
        end
      end
      return
    end
    fill(items, opts.bang, ":Git difftool " .. table.concat(args, " "))
  end)
end

---:Git mergetool [-y] [paths]: conflicted files, each at its first marker.
---@param repo fugitive.Repo
---@param args string[]
---@param opts {bang?: boolean}
function M.mergetool(repo, args, opts)
  local tabs = vim.tbl_contains(args, "-y") or vim.tbl_contains(args, "--no-prompt")
  local cmd = { "diff", "--name-only", "--diff-filter=U" }
  local paths = vim.tbl_filter(function(a)
    return a:sub(1, 1) ~= "-"
  end, args)
  if #paths > 0 then
    table.insert(cmd, "--")
    vim.list_extend(cmd, paths)
  end
  repo:run(cmd, {}, function(res)
    if res.code ~= 0 then
      notify.error(require("nvim-fugitive.git.exec").error_text(res))
      return
    end
    local items = {}
    local seen = {}
    for path in res.stdout:gmatch("[^\n]+") do
      if not seen[path] then
        seen[path] = true
        local abs = repo:abs(path)
        local lnum = 1
        local ok, lines = pcall(vim.fn.readfile, abs)
        if ok then
          for i, l in ipairs(lines) do
            if l:match("^<<<<<<<") then
              lnum = i
              break
            end
          end
        end
        table.insert(items, { filename = abs, lnum = lnum, text = "unmerged" })
      end
    end
    if tabs then
      local ds = require("nvim-fugitive.buffers.diffsplit")
      for _, it in ipairs(items) do
        vim.cmd("tabedit " .. vim.fn.fnameescape(it.filename))
        pcall(ds.split, { three_way = true })
      end
      return
    end
    fill(items, opts.bang, ":Git mergetool " .. table.concat(args, " "))
  end)
end

---:Gcd / :Glcd [dir] relative to the work tree.
---@param c table user command argument
---@param cmd "cd"|"lcd"
function M.cd(c, cmd)
  local repo = require("nvim-fugitive.git.repo").require()
  if not repo then
    return
  end
  if not repo.worktree then
    notify.error("no work tree (bare repository)")
    return
  end
  local dir = vim.trim(c.args or "")
  dir = dir:gsub("^:/:?", ""):gsub("^/", "")
  local target = dir == "" and repo.worktree or vim.fs.normalize(repo.worktree .. "/" .. dir)
  vim.cmd(cmd .. " " .. vim.fn.fnameescape(target))
end

return M
