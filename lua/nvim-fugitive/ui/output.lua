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
---@field trimmed? boolean only its stderr is kept (output.ring_size)

---@type fugitive.OutputEntry[]
M._ring = {}
local next_id = 0

---How many recent commands keep their whole output (0 or unset: 1), and
---how many of the commands that wrote to stderr keep that.
local function caps()
  local o = require("nvim-fugitive.config").get().output or {}
  return math.max(1, o.ring_size or 1), math.max(0, o.errors or 20)
end

---Drop what is no longer kept: newest first, the latest `full` commands
---keep everything; older ones keep only their stderr, for as long as they
---are among the latest `errors` that have one; the rest go. A command still
---running is always kept.
function M.prune()
  local full, errors = caps()
  local kept_full, kept_err = 0, 0
  for k = #M._ring, 1, -1 do
    local e = M._ring[k]
    if e.running or kept_full < full then
      kept_full = kept_full + 1
      if e.stderr ~= "" then
        kept_err = kept_err + 1
      end
    elseif e.stderr ~= "" and kept_err < errors then
      kept_err = kept_err + 1
      e.stdout, e.trimmed = "", true
    else
      table.remove(M._ring, k)
    end
  end
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
  M.prune()
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
  M.prune()
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

---The entry of a command, by its argv table (the log links to it this way).
---@param cmd string[]
---@return fugitive.OutputEntry?
function M.of_cmd(cmd)
  for k = #M._ring, 1, -1 do
    if M._ring[k].cmd == cmd then
      return M._ring[k]
    end
  end
end

---@param entry fugitive.OutputEntry
---@param mods? string
function M.show_entry(entry, mods)
  -- with git's colours, as the command printed them
  local ansi = require("nvim-fugitive.ui.ansi")
  local lines, spans = ansi.decode(table.concat(M.lines(entry), "\n"))
  local buf, win = require("nvim-fugitive.ui.float").show(lines, {
    title = "git output #" .. entry.id,
    mods = mods,
    filetype = "fugitiveoutput",
    name = "fugitive-output://" .. entry.id,
  })
  ansi.apply(buf, spans)
  return buf, win
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
  if entry.trimmed then
    table.insert(lines, "# stdout not kept (output.ring_size)")
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
  return M.show_entry(entry, mods)
end

return M
