---@mod nvim-fugitive.buffers.summary.actions Summary buffer actions (F6–F11, F30).
---
---The functions behind the summary's actions, from the modules next to this
---one (staging, navigation, opening, commands); registry.lua declares the
---actions themselves.

local M = {}
for _, part in ipairs({ "stage", "navigate", "open", "commands" }) do
  for k, v in pairs(require("nvim-fugitive.buffers.summary.actions." .. part)) do
    M[k] = v
  end
end
---The summary's actions for maps.apply (actions/registry.lua declares them).
---@param buf integer
---@return table<string, fugitive.Action>
function M.actions(buf)
  return require("nvim-fugitive.buffers.summary.actions.registry").actions_for(buf)
end

return M
