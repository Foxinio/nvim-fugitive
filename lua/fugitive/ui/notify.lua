---@mod fugitive.ui.notify vim.notify wrapper (§5.2).
---
---Every message carries `title = "Fugitive"` so notification plugins (noice,
---nvim-notify, …) can route them. Long messages are truncated to
---`notify.max_lines`; the full text is always kept in the output ring
---(`:FugitiveOutput`).

local M = {}

local TITLE = "Fugitive"

---@param msg string
---@param level? integer
---@param opts? table
function M.notify(msg, level, opts)
  opts = vim.tbl_extend("keep", opts or {}, { title = TITLE })
  vim.notify(msg, level or vim.log.levels.INFO, opts)
end

function M.info(msg, opts)
  M.notify(msg, vim.log.levels.INFO, opts)
end

function M.warn(msg, opts)
  M.notify(msg, vim.log.levels.WARN, opts)
end

function M.error(msg, opts)
  M.notify(msg, vim.log.levels.ERROR, opts)
end

local error_pattern = { "^error:", "^fatal:", "^E%d+:", "^CONFLICT", "^hint:.*error", "^! %[", "[Ee]rror" }

---Find the first line that looks like an error.
---@param lines string[]
---@return integer?
function M.first_error_line(lines)
  for i, l in ipairs(lines) do
    for _, p in ipairs(error_pattern) do
      if l:find(p) then
        return i
      end
    end
  end
end

---Truncate `text` for a notification.
---Errors are never cut before their first error line, and always mention
---the exit code. A truncated message points at :FugitiveOutput.
---@param text string
---@param opts {max_lines?: integer, code?: integer, is_error?: boolean}
---@return string
function M.truncate(text, opts)
  local max = opts.max_lines or require("fugitive.config").get().notify.max_lines
  local lines = vim.split((text:gsub("\n+$", "")), "\n", { plain = true })
  local keep = max
  if opts.is_error then
    local first = M.first_error_line(lines) or 1
    keep = math.max(keep, first)
  end
  local out
  local hidden = 0
  if #lines > keep then
    hidden = #lines - keep
    out = vim.list_slice(lines, 1, keep)
  else
    out = lines
  end
  if opts.is_error and opts.code and opts.code ~= 0 then
    table.insert(out, string.format("(exit code %d)", opts.code))
  end
  if hidden > 0 then
    table.insert(out, string.format("… (+%d lines) — :FugitiveOutput", hidden))
  end
  return table.concat(out, "\n")
end

---Notify the result of a command: stdout/stderr, truncated.
---@param res fugitive.ExecResult
---@param opts? {label?: string, success?: string}
function M.result(res, opts)
  opts = opts or {}
  local ok = res.code == 0
  local text = vim.trim(table.concat(
    vim.tbl_filter(function(s)
      return s ~= ""
    end, { vim.trim(res.stdout or ""), vim.trim(res.stderr or "") }),
    "\n"
  ))
  if text == "" then
    text = ok and (opts.success or ((opts.label or "git") .. ": done")) or ((opts.label or "git") .. " failed")
  end
  text = M.truncate(text, { code = res.code, is_error = not ok })
  if ok then
    M.info(text)
  else
    M.error(text)
  end
end

return M
