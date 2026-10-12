---@mod nvim-fugitive.cmd.edit :Gedit family, :Gread, :Gwrite, :Gwq.

local object = require("nvim-fugitive.object")
local notify = require("nvim-fugitive.ui.notify")

local M = {}

---The default object of a buffer: the index version of a work-tree file,
---the work-tree file of anything else (upstream's rule).
---@param repo fugitive.Repo
---@param buf integer
---@return string spec
function M.default_spec(repo, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local obj = object.parse(name)
  if obj then
    if obj.path and obj.path ~= "" then
      return ":(top)" .. obj.path
    end
    return ":"
  end
  local rel = name ~= "" and repo:rel(name)
  if rel and rel ~= "" then
    return ":0:" .. rel
  end
  return ":"
end

---Resolve a user-typed object for the current buffer.
---@param repo fugitive.Repo
---@param spec string? nil or "" means the default object
---@return string? target, string? err
function M.target(repo, spec)
  local buf = vim.api.nvim_get_current_buf()
  if not spec or spec == "" then
    spec = M.default_spec(repo, buf)
  end
  return object.find(repo, object.expand(spec, repo))
end

---Show the output of the latest :Git invocation in a scratch buffer (`-`).
---@param cmd string ex command used to open it
local function open_last_output(cmd)
  local output = require("nvim-fugitive.ui.output")
  local entry = output.get(1)
  if not entry then
    notify.warn("no :Git output recorded")
    return
  end
  local name = "fugitive-output://" .. entry.id
  local existing = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\/.*$^~[]") .. "$")
  if cmd ~= "edit" then
    vim.cmd(cmd == "tabedit" and "tab split" or cmd == "pedit" and "pedit" or cmd)
  end
  if existing > 0 then
    vim.api.nvim_win_set_buf(0, existing)
    return
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, output.lines(entry))
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_win_set_buf(0, buf)
end

local ex = {
  edit = "edit",
  split = "split",
  vsplit = "vsplit",
  tabedit = "tabedit",
  pedit = "pedit",
  drop = "drop",
}

---Open an object.
---@param how "edit"|"split"|"vsplit"|"tabedit"|"pedit"|"drop"
---@param spec string?
---@param opts? {bang?: boolean, mods?: string}
function M.open(how, spec, opts)
  opts = opts or {}
  local repo = require("nvim-fugitive.git.repo").require()
  if not repo then
    return
  end
  if spec == "-" then
    return open_last_output(ex[how])
  end
  local target, err = M.target(repo, spec)
  if not target then
    notify.error(err or ("cannot open " .. tostring(spec)))
    return
  end
  local cmd = ex[how] .. ((opts.bang and how ~= "pedit") and "!" or "")
  local mods = opts.mods and opts.mods ~= "" and (opts.mods .. " ") or ""
  vim.cmd(mods .. cmd .. " " .. vim.fn.fnameescape(target))
  return target
end

---Content of a blob object or a file.
---@param repo fugitive.Repo
---@param target string fugitive URL or path
---@return string? content, string? err
function M.content(repo, target)
  local obj = object.parse(target)
  if obj then
    if obj.commit == "" or not obj.path or obj.path == "" then
      return nil, "not a file: " .. target
    end
    local name = object.git_name(obj)
    local kind = repo:chomp({ "cat-file", "-t", name })
    if kind ~= "blob" then
      return nil, "not a blob: " .. object.describe(obj)
    end
    local res = repo:sync({ "cat-file", "blob", name })
    if res.code ~= 0 then
      return nil, require("nvim-fugitive.git.exec").error_text(res)
    end
    return res.stdout
  end
  local fd = io.open(target, "rb")
  if not fd then
    return nil, "cannot read " .. target
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

local function to_lines(content)
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---:Gread [object] — replace the buffer (or insert after {range}) with an
---object; undoable, nothing is written.
---@param spec string?
---@param opts? {range?: integer, line2?: integer}
---@return boolean
function M.read(spec, opts)
  opts = opts or {}
  local repo = require("nvim-fugitive.git.repo").require()
  if not repo then
    return false
  end
  local target, err = M.target(repo, spec)
  if not target then
    notify.error(err or "no such object")
    return false
  end
  local content
  content, err = M.content(repo, target)
  if not content then
    notify.error(err or "cannot read")
    return false
  end
  local buf = vim.api.nvim_get_current_buf()
  if not vim.bo[buf].modifiable then
    notify.error("buffer is not modifiable")
    return false
  end
  local lines = to_lines(content)
  if opts.range and opts.range > 0 then
    vim.api.nvim_buf_set_lines(buf, opts.line2, opts.line2, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return true
end

---Where :Gwrite writes the current buffer: the work-tree file (then
---staged) or only the index for a `:0:path` destination.
---@param repo fugitive.Repo
---@param spec string?
---@return {index_only: boolean, rel: string, abs: string}? dest, string? err
local function write_destination(repo, spec)
  local buf = vim.api.nvim_get_current_buf()
  if spec and spec ~= "" then
    local target, err = object.find(repo, object.expand(spec, repo))
    if not target then
      return nil, err
    end
    local obj = object.parse(target)
    if obj then
      if obj.commit ~= "0" or not obj.path or obj.path == "" then
        return nil, "can only write to the work tree or the index (:0:path)"
      end
      return { index_only = true, rel = obj.path, abs = repo:abs(obj.path) }
    end
    local rel = repo:rel(target)
    if not rel or rel == "" then
      return nil, "not in the work tree: " .. target
    end
    return { index_only = false, rel = rel, abs = target }
  end
  local rel = object.buf_rel(buf, repo)
  if not rel or rel == "" then
    return nil, "nothing to write: not a file in the repository"
  end
  return { index_only = false, rel = rel, abs = repo:abs(rel) }
end

---:Gwrite [path] — write the buffer to the work tree (or the index) and
---stage it. In a work-tree file this is `git add`; in any other object
---buffer it is effectively `git checkout` of that version.
---@param spec string?
---@param bang boolean?
---@return boolean ok
function M.write(spec, bang)
  local repo = require("nvim-fugitive.git.repo").require()
  if not repo then
    return false
  end
  local dest, err = write_destination(repo, spec)
  if not dest then
    notify.error(err or "cannot write")
    return false
  end
  local reader = require("nvim-fugitive.buffers.reader")
  local buf = vim.api.nvim_get_current_buf()
  local content = reader.buffer_bytes(buf)
  if dest.index_only then
    local ok, werr = reader.write_index(repo, dest.rel, content)
    if not ok then
      notify.error(werr or "could not write the index")
      return false
    end
    require("nvim-fugitive").changed(repo)
    return true
  end
  local own = vim.api.nvim_buf_get_name(buf) == dest.abs
  if own then
    local ok, werr = pcall(vim.api.nvim_command, "write" .. (bang and "!" or ""))
    if not ok then
      notify.error(tostring(werr))
      return false
    end
  else
    local other = vim.fn.bufnr("^" .. vim.fn.escape(dest.abs, "\\/.*$^~[]") .. "$")
    if other > 0 and vim.bo[other].modified and not bang then
      notify.error(dest.rel .. " has unsaved changes in another buffer (add ! to override)")
      return false
    end
    vim.fn.mkdir(vim.fn.fnamemodify(dest.abs, ":h"), "p")
    local fd = io.open(dest.abs, "wb")
    if not fd then
      notify.error("cannot write " .. dest.abs)
      return false
    end
    fd:write(content)
    fd:close()
    if other > 0 and vim.api.nvim_buf_is_loaded(other) then
      vim.api.nvim_buf_call(other, function()
        vim.cmd("silent edit!")
      end)
    end
  end
  local res = repo:sync({ "add", "--", dest.rel })
  if res.code ~= 0 then
    notify.error(require("nvim-fugitive.git.exec").error_text(res))
    return false
  end
  -- an open index buffer for the path now shows stale content
  local idx = vim.fn.bufnr(
    "^" .. vim.fn.escape(object.format(repo.git_dir, "0", dest.rel), "\\/.*$^~[]") .. "$"
  )
  if idx > 0 and idx ~= buf and vim.api.nvim_buf_is_loaded(idx) and not vim.bo[idx].modified then
    vim.api.nvim_buf_call(idx, function()
      vim.cmd("silent edit!")
    end)
  end
  require("nvim-fugitive").changed(repo)
  return true
end

---:Gwq [path] — :Gwrite, then :quit when it succeeded.
---@param spec string?
---@param bang boolean?
function M.wq(spec, bang)
  if M.write(spec, bang) then
    vim.cmd("quit" .. (bang and "!" or ""))
  end
end

---User command entry point for the :Gedit family.
---@param how string
---@param c table
function M.command(how, c)
  local ok, err = pcall(M.open, how, vim.trim(c.args or ""), { bang = c.bang, mods = c.mods })
  if not ok then
    notify.error(tostring(err))
  end
end

return M
