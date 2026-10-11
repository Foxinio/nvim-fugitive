---@mod fugitive.cmd.move :GMove, :GRename, :GDelete, :GRemove, :GUnlink (F20).

local notify = require("fugitive.ui.notify")
local object = require("fugitive.object")

local M = {}

---The current buffer as (repo, absolute path, object) if it is a work-tree
---file or an index (stage 0) blob.
local function current()
  local buf = vim.api.nvim_get_current_buf()
  local repo = require("fugitive.git.repo").for_buf(buf)
  if not repo then
    return nil, "not a git repository"
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local obj = object.parse(name)
  if obj then
    if obj.commit ~= "0" or not obj.path or obj.path == "" then
      return nil, "not supported for this buffer"
    end
    return repo, repo:abs(obj.path), obj
  end
  if name == "" or vim.bo[buf].buftype ~= "" then
    return nil, "not supported for this buffer"
  end
  return repo, vim.fn.fnamemodify(name, ":p"), nil
end

---Resolve a :GMove/:GRename destination like upstream: `/abs` stays,
---`./` and `../` are relative to the cwd (GMove) and everything else to the
---work tree root (GMove) or the file's directory (GRename).
---@param repo fugitive.Repo
---@param src string absolute source
---@param dest string
---@param rename boolean
---@return string absolute destination
function M.destination(repo, src, dest, rename)
  local root = rename and vim.fn.fnamemodify(src:gsub("/$", ""), ":h") or repo.worktree
  if dest:match("^:/:?") then
    return vim.fs.normalize(repo.worktree .. "/" .. dest:gsub("^:/:?", ""))
  end
  if dest:sub(1, 1) == "/" then
    return vim.fs.normalize(dest)
  end
  if (dest:match("^%.%.?/") or dest == "." or dest == "..") and not rename then
    return vim.fs.normalize(vim.fn.getcwd() .. "/" .. dest)
  end
  return vim.fs.normalize(root .. "/" .. dest)
end

---@param cmd table user command argument
---@param rename boolean
function M.move(cmd, rename)
  local repo, src, obj = current()
  if not repo then
    notify.error("mv " .. src)
    return
  end
  local dest = M.destination(repo, src, vim.trim(cmd.args), rename)
  local args = { "mv" }
  if cmd.bang then
    table.insert(args, "-f")
  end
  vim.list_extend(args, { "--", src, dest })
  local buf = vim.api.nvim_get_current_buf()
  repo:run(args, {}, function(res)
    require("fugitive.ui.output").record(res, repo.worktree)
    if res.code ~= 0 then
      notify.error(require("fugitive.git.exec").error_text(res))
      return
    end
    if vim.fn.isdirectory(dest) == 1 then
      dest = dest .. "/" .. vim.fn.fnamemodify(src, ":t")
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_call(buf, function()
        if obj then
          vim.cmd("file " .. vim.fn.fnameescape(object.format(repo.git_dir, "0", repo:rel(dest))))
        else
          -- keepalt saveas!: rename the buffer, write it to the new name
          vim.cmd("keepalt saveas! " .. vim.fn.fnameescape(dest))
          -- drop the stale buffer of the old name saveas leaves behind
          local old = vim.fn.bufnr("^" .. vim.fn.escape(src, "\\/.*$^~[]") .. "$")
          if old > 0 and old ~= buf then
            pcall(vim.api.nvim_buf_delete, old, { force = true })
          end
        end
      end)
    end
    notify.info("Moved " .. (repo:rel(src) or src) .. " → " .. (repo:rel(dest) or dest))
    require("fugitive").changed(repo)
  end)
end

---@param cmd table user command argument
---@param opts {delete_buffer: boolean}
function M.remove(cmd, opts)
  local repo, path, obj = current()
  if not repo then
    notify.error("rm " .. path)
    return
  end
  local args = { "rm" }
  if obj then
    table.insert(args, "--cached")
  end
  if cmd.bang then
    table.insert(args, "--force")
  end
  vim.list_extend(args, { "--", path })
  local buf = vim.api.nvim_get_current_buf()
  repo:run(args, {}, function(res)
    require("fugitive.ui.output").record(res, repo.worktree)
    if res.code ~= 0 then
      local msg = require("fugitive.git.exec").error_text(res)
      if msg:match("%-f") then
        msg = msg:gsub("\n.*", "") .. " (add ! to force)"
      end
      notify.error(msg)
      return
    end
    if vim.api.nvim_buf_is_valid(buf) then
      if opts.delete_buffer then
        pcall(vim.api.nvim_buf_delete, buf, { force = cmd.bang })
      else
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("edit" .. (cmd.bang and "!" or ""))
        end)
      end
    end
    notify.info("Removed " .. (repo:rel(path) or path))
    require("fugitive").changed(repo)
  end)
end

---:GUnlink is an alias of :GRemove upstream.
function M.unlink(cmd)
  return M.remove(cmd, { delete_buffer = false })
end

return M
