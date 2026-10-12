---@mod nvim-fugitive.integrations.gitsigns Optional gitsigns.nvim accelerator (§5.5).
---
---When gitsigns is present we reuse its hunk data for work-tree hunk
---navigation/staging and refresh it after our mutating operations. Without
---it the same actions use our own hunks (nvim-fugitive.hunks).

local M = {}

---@return table?
function M.get()
  if not require("nvim-fugitive.config").get().integrations.gitsigns then
    return nil
  end
  -- a failed require can leave a non-table sentinel in package.loaded
  local loaded = package.loaded["gitsigns"]
  if type(loaded) == "table" then
    return loaded
  end
  -- only use gitsigns if the user has it; never force-load at startup
  local ok, gs = pcall(require, "gitsigns")
  return ok and type(gs) == "table" and gs or nil
end

---Refresh gitsigns after a mutation (no-op without gitsigns).
function M.refresh()
  local gs = package.loaded["gitsigns"]
  if type(gs) ~= "table" or not require("nvim-fugitive.config").get().integrations.gitsigns then
    return
  end
  if gs.refresh then
    pcall(gs.refresh)
  end
end

-- Without gitsigns the built-in hunks (lua/nvim-fugitive/hunks.lua) take
-- over: same actions, computed against the index on demand.

---Delegated work-tree hunk actions.
M.actions = {
  next_hunk = function()
    if vim.wo.diff then
      return vim.cmd("normal! " .. vim.v.count1 .. "]c")
    end
    local gs = M.get()
    if gs and gs.nav_hunk then
      return gs.nav_hunk("next")
    end
    require("nvim-fugitive.hunks").jump(1)
  end,
  prev_hunk = function()
    if vim.wo.diff then
      return vim.cmd("normal! " .. vim.v.count1 .. "[c")
    end
    local gs = M.get()
    if gs and gs.nav_hunk then
      return gs.nav_hunk("prev")
    end
    require("nvim-fugitive.hunks").jump(-1)
  end,
  stage_hunk = function()
    local gs = M.get()
    if gs and gs.stage_hunk then
      return gs.stage_hunk()
    end
    require("nvim-fugitive.hunks").stage()
  end,
  reset_hunk = function()
    local gs = M.get()
    if gs and gs.reset_hunk then
      return gs.reset_hunk()
    end
    require("nvim-fugitive.hunks").reset()
  end,
}

return M
