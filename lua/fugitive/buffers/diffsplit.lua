---@mod fugitive.buffers.diffsplit :Gdiffsplit family (F15, MVP read-only).
---
---The other side of the diff is a read-only fugitive:// buffer (editing the
---index side is backlog). During a merge conflict `:Gdiffsplit!` opens the
---upstream 3-way layout: ours (//2) | working | theirs (//3), with `dp` in
---the side windows and `d2o`/`d3o` in the working copy.

local object = require("fugitive.object")
local notify = require("fugitive.ui.notify")

local M = {}

---Where the current buffer lives: work tree path or fugitive object.
---@param buf integer
---@return fugitive.Repo?, string? rel, fugitive.Object? obj
local function locate(buf)
  local repo = require("fugitive.git.repo").for_buf(buf)
  if not repo then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local obj = object.parse(name)
  if obj then
    return repo, obj.path, obj
  end
  if name == "" then
    return repo, nil
  end
  return repo, repo:rel(name)
end

---Is `rel` unmerged (has stage 2/3 entries)?
---@param repo fugitive.Repo
---@param rel string
function M.is_conflicted(repo, rel)
  local res = repo:sync({ "ls-files", "--unmerged", "-z", "--", rel })
  return res.code == 0 and res.stdout ~= ""
end

local function modifier(count, layout, mods)
  if mods and mods:match("vertical") then
    return "vertical"
  end
  if layout == "vertical" then
    return "vertical"
  elseif layout == "horizontal" then
    return ""
  end
  local diffopt = vim.o.diffopt
  if diffopt:match("horizontal") and not diffopt:match("vertical") then
    return ""
  elseif diffopt:match("vertical") then
    return "vertical"
  end
  local fdc = tonumber(diffopt:match("foldcolumn:(%d+)")) or 2
  local tw = vim.bo.textwidth > 0 and vim.bo.textwidth or 80
  if vim.api.nvim_win_get_width(0) <= count * (tw + fdc) then
    return ""
  end
  return "vertical"
end

local function diffthis(win)
  vim.api.nvim_win_call(win, function()
    if not vim.wo.diff then
      vim.w.fugitive_diff_restore = true
      vim.cmd("diffthis")
    end
  end)
end

local function map(buf, lhs, rhs)
  vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = "fugitive diff" })
end

---Open `url` in a split next to the current window, diff both.
---@return integer win
local function open_side(url, mods)
  vim.cmd(mods .. " split " .. vim.fn.fnameescape(url))
  local win = vim.api.nvim_get_current_win()
  vim.w.fugitive_diff_side = true
  return win
end

---@class fugitive.DiffOpts
---@field against? string object spec (commit or rev:path, :N:path)
---@field three_way? boolean
---@field keep_focus? boolean
---@field layout? "auto"|"vertical"|"horizontal"
---@field mods? string

---Diff the current buffer.
---@param opts fugitive.DiffOpts
function M.split(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local cur_win = vim.api.nvim_get_current_win()
  local repo, rel, obj = locate(buf)
  if not repo or not rel or rel == "" then
    notify.error("not a file in a git repository")
    return
  end
  local mods_extra = (opts.mods or ""):gsub("vertical", ""):gsub("horizontal", "")

  -- three-way conflict layout
  if opts.three_way or (opts.keep_focus and not opts.against and not obj and M.is_conflicted(repo, rel)) then
    if not M.is_conflicted(repo, rel) then
      notify.warn(rel .. " has no conflicts; diffing against the index")
    else
      local dir = modifier(3, opts.layout, opts.mods)
      local ours = object.format(repo.git_dir, "2", rel)
      local theirs = object.format(repo.git_dir, "3", rel)
      local ow = open_side(ours, vim.trim(mods_extra .. " " .. dir .. " leftabove"))
      local obuf = vim.api.nvim_get_current_buf()
      map(obuf, "dp", "<Cmd>diffput " .. buf .. "<Bar>diffupdate<CR>")
      diffthis(ow)
      vim.api.nvim_set_current_win(cur_win)
      local tw = open_side(theirs, vim.trim(mods_extra .. " " .. dir .. " rightbelow"))
      local tbuf = vim.api.nvim_get_current_buf()
      map(tbuf, "dp", "<Cmd>diffput " .. buf .. "<Bar>diffupdate<CR>")
      diffthis(tw)
      vim.api.nvim_set_current_win(cur_win)
      map(buf, "d2o", "<Cmd>diffget " .. obuf .. "<Bar>diffupdate<CR>")
      map(buf, "d3o", "<Cmd>diffget " .. tbuf .. "<Bar>diffupdate<CR>")
      diffthis(cur_win)
      vim.b[buf].fugitive_diff_3way = true
      vim.cmd("wincmd =")
      return
    end
  end

  -- two-way
  local target
  if opts.against and opts.against ~= "" then
    local spec = opts.against
    local r = object.parse_rev(spec)
    if r and r.kind == "commit" then
      spec = spec .. ":" .. rel
    end
    local err
    target, err = object.resolve(repo, spec)
    if not target then
      notify.error(err)
      return
    end
  elseif obj then
    -- index, stage or commit blob: against the work tree
    target = repo:abs(rel)
  elseif M.is_conflicted(repo, rel) then
    target = object.format(repo.git_dir, "1", rel)
    notify.warn("Use :Gdiffsplit! for 3 way diff")
  else
    target = object.format(repo.git_dir, "0", rel)
  end

  local dir = modifier(2, opts.layout, opts.mods)
  -- the work tree version is always placed to the right or bottom
  local target_is_worktree = not target:match("^fugitive://")
  local side = target_is_worktree and "rightbelow" or "leftabove"
  local win = open_side(target, vim.trim(mods_extra .. " " .. dir .. " " .. side))
  diffthis(win)
  if not target_is_worktree then
    vim.bo.bufhidden = "wipe"
  end
  diffthis(cur_win)
  -- like upstream: focus the new window unless ! (keep focus) was given
  vim.api.nvim_set_current_win(opts.keep_focus and cur_win or win)
end

---Close the diff: wipe the fugitive side windows, diffoff the rest (dq).
function M.close()
  local cur = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.w[win].fugitive_diff_side then
      if win == cur then
        -- closing from a side window: return to the work tree window
        cur = nil
      end
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[win].diff then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffoff")
        vim.w.fugitive_diff_restore = nil
      end)
    end
  end
  if cur and vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
end

---:Gdiffsplit / :Gvdiffsplit / :Ghdiffsplit
---@param cmd table user command argument
---@param layout "auto"|"vertical"|"horizontal"
function M.command(cmd, layout)
  local arg = vim.trim(cmd.args or "")
  if arg == "" then
    arg = nil
  end
  local ok, err = pcall(M.split, {
    against = arg,
    keep_focus = cmd.bang,
    three_way = cmd.bang and not arg and nil,
    layout = layout,
    mods = cmd.mods,
  })
  if not ok then
    notify.error(tostring(err))
  end
end

return M
