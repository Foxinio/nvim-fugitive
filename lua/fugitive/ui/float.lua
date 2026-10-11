---@mod fugitive.ui.float Big pager float, or a regular window with modifiers.
---
---Used for pager-type output (`:Git log`, `:Git show`, help, long errors).
---Command modifiers (`:vert`, `:tab`, `:horizontal`, `:topleft`, …) open the
---output in a split/tab instead of the float (§5.2).

local M = {}

-- `opts.mods` of a user command always spells modifiers out in full
local window_mod_words = {
  vertical = true,
  horizontal = true,
  tab = true,
  topleft = true,
  botright = true,
  aboveleft = true,
  belowright = true,
  leftabove = true,
  rightbelow = true,
}

---Do these command modifiers ask for a regular window?
---@param mods? string
---@return boolean
function M.wants_window(mods)
  if not mods or mods == "" then
    return false
  end
  for word in mods:gmatch("%S+") do
    if window_mod_words[word] or word:match("^%d+tab$") then
      return true
    end
  end
  return false
end

local function float_config(title)
  local cfg = require("fugitive.config").get().float
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(20, math.floor(cols * cfg.width))
  local height = math.max(5, math.floor(rows * cfg.height))
  return {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((cols - width) / 2),
    row = math.floor((rows - height) / 2) - 1,
    style = "minimal",
    border = cfg.border,
    title = title and (" " .. title .. " ") or nil,
    title_pos = title and "center" or nil,
  }
end

---@class fugitive.ShowOpts
---@field title? string
---@field mods? string
---@field filetype? string
---@field name? string buffer name
---@field on_cancel? fun() called by the pager `cancel` map (<C-c>) while running
---@field enter? boolean default true

local function set_maps(buf, opts)
  local maps = require("fugitive.config").get().maps.pager
  local actions = {
    close = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      elseif #vim.api.nvim_list_wins() > 1 then
        pcall(vim.api.nvim_win_close, win, false)
      else
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end,
    cancel = function()
      local cancel = vim.b[buf].fugitive_running and opts.on_cancel
      if cancel then
        cancel()
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "n", false)
      end
    end,
  }
  for lhs, action in pairs(maps) do
    local fn = type(action) == "function" and action or actions[action]
    if fn then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "fugitive: " .. tostring(action) })
    end
  end
end

---Show lines in the pager float (or a split with window modifiers).
---@param lines string[]
---@param opts? fugitive.ShowOpts
---@return integer buf, integer win
function M.show(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if opts.name then
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end
  local win
  if M.wants_window(opts.mods) then
    vim.cmd(opts.mods .. " split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  else
    win = vim.api.nvim_open_win(buf, opts.enter ~= false, float_config(opts.title))
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
  end
  vim.wo[win].foldmethod = "manual"
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  set_maps(buf, opts)
  return buf, win
end

---Append text (streaming output) to a pager buffer.
---@param buf integer
---@param text string
function M.append(buf, text)
  if not vim.api.nvim_buf_is_valid(buf) or text == "" then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  vim.bo[buf].modifiable = true
  local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
  local count = vim.api.nvim_buf_line_count(buf)
  -- continue a partial last line
  lines[1] = last .. lines[1]
  vim.api.nvim_buf_set_lines(buf, count - 1, count, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---Replace the content of a pager buffer.
---@param buf integer
---@param lines string[]
function M.set(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

return M
