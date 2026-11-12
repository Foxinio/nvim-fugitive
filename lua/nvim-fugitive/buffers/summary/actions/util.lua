---@mod nvim-fugitive.buffers.summary.actions.util Helpers shared by the summary actions.

local M = {}

function M.summary()
  return require("nvim-fugitive.buffers.summary")
end

---State of a summary buffer; actions only run in summary buffers.
---@param buf integer
---@return fugitive.SummaryState
function M.state(buf)
  return assert(M.summary().state(buf), "not a summary buffer")
end

function M.range(visual)
  if visual then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return math.min(a, b), math.max(a, b)
  end
  local l = vim.fn.line(".")
  return l, l
end

function M.has_head(st)
  return st.snap and st.snap.status and st.snap.status.oid ~= nil
end

function M.git(buf, args, opts)
  local st = M.state(buf)
  opts = vim.tbl_extend("force", { repo = st and st.repo, skip_picker = true }, opts or {})
  return require("nvim-fugitive.cmd.git").run(args, opts)
end

---Put a command on the command line for the user to complete/confirm.
function M.cmdline(text, home)
  local keys = ":" .. text
  if home then
    keys = keys .. "<Home>"
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

function M.split_words(s)
  return vim.split(s, " ", { trimempty = true })
end

return M
