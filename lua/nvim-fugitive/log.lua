---@mod nvim-fugitive.log Every git command fugitive runs, for :FugitiveLog.
---
---git/exec.lua reports each command here as it starts and when it ends. A
---command is "user" when it starts while one of your keys or commands is
---running (`M.user` wraps those), and "background" otherwise: the summary's
---refresh, the watcher, completion, the statusline. Only the command line,
---its duration and its exit code are kept; output lives in ui/output.lua.

local M = {}

---@class fugitive.LogEntry
---@field id integer
---@field time integer os.time() when it started
---@field kind "user"|"background"
---@field cmd string[]
---@field cwd? string
---@field ms? integer how long it ran
---@field code? integer exit code, nil while running
---@field started integer hrtime at the start

---@type fugitive.LogEntry[]
M._ring = {}
local next_id = 0
local depth = 0 -- > 0 while a key or command of the user runs
local listeners = {}

local function size()
  local l = require("nvim-fugitive.config").get().log or {}
  return l.size or 100
end

local function changed()
  for _, fn in pairs(listeners) do
    pcall(fn)
  end
end

---Run `fn`, counting the git commands it starts as the user's.
---@param fn function
function M.user(fn, ...)
  depth = depth + 1
  local ok, a, b = pcall(fn, ...)
  depth = depth - 1
  if not ok then
    error(a, 0)
  end
  return a, b
end

---A command starts.
---@param cmd string[]
---@param cwd? string
---@return fugitive.LogEntry
function M.start(cmd, cwd)
  next_id = next_id + 1
  local entry = {
    id = next_id,
    time = os.time(),
    kind = depth > 0 and "user" or "background",
    cmd = cmd,
    cwd = cwd,
    started = vim.uv.hrtime(),
  }
  table.insert(M._ring, entry)
  while #M._ring > size() do
    table.remove(M._ring, 1)
  end
  changed()
  return entry
end

---It ends.
---@param entry fugitive.LogEntry
---@param code integer
function M.finish(entry, code)
  entry.code = code
  entry.ms = math.floor((vim.uv.hrtime() - entry.started) / 1e6)
  changed()
end

---The entries of `level` ("user" or "all"), oldest first.
---@param level "user"|"all"
---@return fugitive.LogEntry[]
function M.entries(level)
  return vim.tbl_filter(function(e)
    return level == "all" or e.kind == "user"
  end, M._ring)
end

---One line of the log.
---@param e fugitive.LogEntry
---@return string
function M.format(e)
  local status
  if e.code == nil then
    status = "…"
  elseif e.code == 0 then
    status = "ok"
  else
    status = "✗ " .. e.code
  end
  return string.format(
    "%s  %-10s  %6s  %-5s  %s",
    os.date("%H:%M:%S", e.time),
    e.kind,
    e.ms and (e.ms .. "ms") or "",
    status,
    table.concat(e.cmd, " ")
  )
end

---Call `fn` whenever the log changes, until `M.unlisten(key)`.
function M.listen(key, fn)
  listeners[key] = fn
end

function M.unlisten(key)
  listeners[key] = nil
end

---:FugitiveLog [all]: a buffer that follows the log.
---@param level? "user"|"all"
---@param mods? string
function M.show(level, mods)
  level = level or (require("nvim-fugitive.config").get().log or {}).level or "user"
  vim.cmd((mods and mods ~= "" and mods or "botright") .. " new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "fugitivelog"
  pcall(vim.api.nvim_buf_set_name, buf, "fugitive://log")
  local shown = {}
  local function draw()
    if not vim.api.nvim_buf_is_valid(buf) then
      return M.unlisten(buf)
    end
    shown = M.entries(level)
    local lines = { "git commands (" .. level .. "; a: switch, <CR>: output, q: close)" }
    for _, e in ipairs(shown) do
      table.insert(lines, M.format(e))
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_set_cursor, w, { #lines, 0 })
      end
    end
  end
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("a", function()
    level = level == "all" and "user" or "all"
    draw()
  end)
  map("q", "<Cmd>close<CR>")
  map("<CR>", function()
    local e = shown[vim.fn.line(".") - 1]
    if not e then
      return
    end
    local out = require("nvim-fugitive.ui.output")
    local entry = out.of_cmd(e.cmd)
    if entry then
      return out.show_entry(entry)
    end
    require("nvim-fugitive.ui.notify").info("output not kept (output.ring_size, output.errors)")
  end)
  M.listen(buf, function()
    vim.schedule(draw)
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      M.unlisten(buf)
    end,
  })
  draw()
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  return buf
end

return M
