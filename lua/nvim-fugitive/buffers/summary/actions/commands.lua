---@mod nvim-fugitive.buffers.summary.actions.commands Ignore, patch, discard and rebase helpers.

local notify = require("nvim-fugitive.ui.notify")
local util = require("nvim-fugitive.buffers.summary.actions.util")
local state = util.state
local range = util.range
local has_head = util.has_head
local git = util.git
local split_words = util.split_words
local open = require("nvim-fugitive.buffers.summary.actions.open")
local stage = require("nvim-fugitive.buffers.summary.actions.stage")

local M = {}

function M.rebase_argument(buf)
  local c = open.cursor_commit(buf)
  return c ~= "" and (" " .. c .. "^") or ""
end

function M.rebase_retodo(buf, word)
  local arg = M.rebase_argument(buf)
  local group = vim.api.nvim_create_augroup("fugitive_rebase_retodo", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FugitiveEditor",
    once = true,
    callback = function(ev)
      local b = ev.data and ev.data.buf
      if b and vim.api.nvim_buf_get_name(b):match("git%-rebase%-todo$") then
        local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
        local new = first:gsub("^pick", word, 1)
        vim.api.nvim_buf_set_lines(b, 0, 1, false, { new })
      end
    end,
  })
  git(buf, vim.list_extend({ "rebase", "--interactive" }, split_words(arg)))
end

-- ---------------------------------------------------------------------------
-- Ignore / exclude

local function exclude_path(repo, count)
  if count and count > 0 then
    return repo:abs(".gitignore")
  end
  return repo.common_dir .. "/info/exclude"
end

function M.ignore(buf, visual)
  local st = state(buf)
  local l1, l2 = range(visual)
  local paths, seen = {}, {}
  for _, it in ipairs(stage.selection(buf, l1, l2)) do
    -- a directory line (tree view) ignores the directory, not each file
    local p = it.info and it.info.kind == "dir" and it.info.dir
      or (it.type == "file" and it.entry.path)
    if p and not seen[p] then
      seen[p] = true
      table.insert(paths, p)
    end
  end
  local file = exclude_path(st.repo, vim.v.count)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.cmd("split " .. vim.fn.fnameescape(file))
  if #paths > 0 then
    local lines = {}
    for _, p in ipairs(paths) do
      table.insert(lines, "/" .. p:gsub("([%[%]*?!#\\])", "\\%1"))
    end
    local last = vim.api.nvim_buf_line_count(0)
    if last == 1 and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "" then
      vim.api.nvim_buf_set_lines(0, 0, 1, false, lines)
    else
      vim.api.nvim_buf_set_lines(0, last, last, false, lines)
    end
    vim.cmd("silent write")
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    require("nvim-fugitive").changed(st.repo)
  end
end

function M.open_exclude(buf)
  local st = state(buf)
  local file = exclude_path(st.repo, vim.v.count)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.cmd("split " .. vim.fn.fnameescape(file))
end

-- ---------------------------------------------------------------------------
-- Patch (interactive) and discard

function M.patch(buf, visual)
  local st = state(buf)
  local l1, l2 = range(visual)
  local add, reset, intent = {}, {}, {}
  for _, it in ipairs(stage.selection(buf, l1, l2)) do
    local entries = it.type == "section" and it.entries or (it.entry and { it.entry }) or {}
    for _, e in ipairs(entries) do
      if it.section == "Staged" then
        table.insert(reset, e.path)
      elseif it.section == "Untracked" then
        table.insert(intent, e.path)
        table.insert(add, e.path)
      elseif it.section == "Unstaged" then
        table.insert(add, e.path)
      end
    end
  end
  if #intent > 0 then
    st.repo:sync(vim.list_extend({ "add", "--intent-to-add", "--" }, intent))
  end
  local term = require("nvim-fugitive.ui.terminal")
  local done = function()
    require("nvim-fugitive").changed(st.repo)
  end
  if #reset > 0 then
    term.run(st.repo, vim.list_extend({ "reset", "--patch", "--" }, reset), { on_exit = done })
  elseif #add > 0 then
    term.run(st.repo, vim.list_extend({ "add", "--patch", "--" }, add), { on_exit = done })
  else
    notify.warn("nothing to patch")
  end
end

function M.discard(buf, visual)
  local st = state(buf)
  local count = vim.v.count
  local l1, l2 = range(visual)
  local items = stage.selection(buf, l1, l2)
  require("nvim-fugitive.discard").discard(
    st.repo,
    items,
    { count = count, has_head = has_head(st), snap = st.snap }
  )
end

function M.restore_discard(buf)
  local st = state(buf)
  if vim.v.count > 0 then
    return require("nvim-fugitive.discard").pick(nil, st.repo)
  end
  require("nvim-fugitive.discard").restore_latest(st.repo)
end

return M
