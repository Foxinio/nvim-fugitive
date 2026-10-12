---@mod nvim-fugitive.ui.output Full-output ring and :FugitiveOutput (§5.2).
---
---`vim.notify` only ever receives one (possibly truncated) string, so the
---complete stdout/stderr of every command is stored here.

local M = {}

---@class fugitive.OutputEntry
---@field id integer
---@field cmd string[]
---@field cwd string?
---@field stdout string
---@field stderr string
---@field code integer?
---@field time integer
---@field running boolean

---@type fugitive.OutputEntry[]
M._ring = {}
local next_id = 0

local function cap()
  return require("nvim-fugitive.config").get().output.ring_size
end

---Start recording a command; returns the entry to update.
---@param cmd string[]
---@param cwd? string
---@return fugitive.OutputEntry
function M.start(cmd, cwd)
  next_id = next_id + 1
  local entry = {
    id = next_id,
    cmd = cmd,
    cwd = cwd,
    stdout = "",
    stderr = "",
    time = os.time(),
    running = true,
  }
  table.insert(M._ring, entry)
  while #M._ring > cap() do
    table.remove(M._ring, 1)
  end
  return entry
end

---Record a finished command.
---@param entry fugitive.OutputEntry
---@param res fugitive.ExecResult
function M.finish(entry, res)
  entry.stdout = res.stdout or entry.stdout
  entry.stderr = res.stderr or entry.stderr
  entry.code = res.code
  entry.running = false
end

---Record a completed command in one go.
---@param res fugitive.ExecResult
---@param cwd? string
---@return fugitive.OutputEntry
function M.record(res, cwd)
  local entry = M.start(res.cmd or {}, cwd)
  M.finish(entry, res)
  return entry
end

---n = 1 is the latest command, 2 the one before, …
---@param n? integer
---@return fugitive.OutputEntry?
function M.get(n)
  n = n or 1
  return M._ring[#M._ring - n + 1]
end

---Text of an entry as shown by :FugitiveOutput.
---@param entry fugitive.OutputEntry
---@return string[]
function M.lines(entry)
  local cmd = {}
  for i, a in ipairs(entry.cmd) do
    if i == 1 or not a:match("^[%w%-%._/=:@,+]+$") then
      cmd[#cmd + 1] = i == 1 and a or vim.fn.shellescape(a)
    else
      cmd[#cmd + 1] = a
    end
  end
  local lines = { "$ " .. table.concat(cmd, " ") }
  if entry.running then
    table.insert(lines, "# running…")
  else
    table.insert(lines, string.format("# exit code %d", entry.code or -1))
  end
  table.insert(lines, "")
  local function add(s)
    s = s:gsub("\n$", "")
    if s ~= "" then
      vim.list_extend(lines, vim.split(s, "\n", { plain = true }))
    end
  end
  add(entry.stdout)
  if entry.stderr ~= "" and entry.stdout ~= "" then
    table.insert(lines, "")
    table.insert(lines, "# stderr")
  end
  add(entry.stderr)
  return lines
end

---:FugitiveOutput [n]
---@param n? integer
---@param mods? string
function M.show(n, mods)
  local entry = M.get(n)
  if not entry then
    require("nvim-fugitive.ui.notify").warn("no command output recorded")
    return
  end
  return require("nvim-fugitive.ui.float").show(M.lines(entry), {
    title = "git output #" .. entry.id,
    mods = mods,
    filetype = "fugitiveoutput",
    name = "fugitive-output://" .. entry.id,
  })
end

return M
