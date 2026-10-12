---@mod nvim-fugitive.integrations.gitsigns Optional gitsigns.nvim accelerator (§5.5).
---
---When gitsigns is present we reuse its hunk data for work-tree hunk
---navigation/staging and refresh it after our mutating operations. Without
---it, work-tree hunk maps say "requires gitsigns.nvim"; staging still works
---fully from the summary buffer.

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

local function unavailable(what)
  require("nvim-fugitive.ui.notify").warn(what .. " requires gitsigns.nvim")
end

---Delegated work-tree hunk actions.
M.actions = {
  next_hunk = function()
    local gs = M.get()
    if not gs then
      return unavailable("]c")
    end
    if vim.wo.diff then
      return vim.cmd("normal! ]c")
    end
    gs.nav_hunk("next")
  end,
  prev_hunk = function()
    local gs = M.get()
    if not gs then
      return unavailable("[c")
    end
    if vim.wo.diff then
      return vim.cmd("normal! [c")
    end
    gs.nav_hunk("prev")
  end,
  stage_hunk = function()
    local gs = M.get()
    if not gs then
      return unavailable("stage hunk")
    end
    gs.stage_hunk()
  end,
  reset_hunk = function()
    local gs = M.get()
    if not gs then
      return unavailable("reset hunk")
    end
    gs.reset_hunk()
  end,
}

return M
