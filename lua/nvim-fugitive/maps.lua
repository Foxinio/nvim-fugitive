---@mod nvim-fugitive.maps Apply the configurable per-buffer-type map tables.
---
---An action is a function (normal mode) or a table `{ n = fn, x = fn }`.
---Map tables come from `config.maps[buftype]`: `lhs -> action name`,
---`lhs -> function`, or `lhs -> false` (disabled).

local M = {}

---@alias fugitive.Action fun()|{n?: fun(), x?: fun(), desc?: string}

---@param buf integer
---@param buftype string key of config.maps
---@param actions table<string, fugitive.Action>
function M.apply(buf, buftype, actions)
  local maps = require("nvim-fugitive.config").get().maps[buftype] or {}
  for lhs, name in pairs(maps) do
    if name then
      local action = type(name) == "function" and name or actions[name]
      if action then
        local modes = type(action) == "function" and { n = action } or action --[[@as table]]
        for mode, fn in pairs(modes) do
          if mode == "n" or mode == "x" then
            vim.keymap.set(mode, lhs, fn, {
              buffer = buf,
              nowait = true,
              silent = true,
              desc = "fugitive: " .. (type(name) == "string" and name or "custom"),
            })
          end
        end
      end
    end
  end
end

---Reverse lookup for help texts: action name -> list of lhs.
---@param buftype string
---@return table<string, string[]>
function M.keys_for(buftype)
  local out = {}
  for lhs, name in pairs(require("nvim-fugitive.config").get().maps[buftype] or {}) do
    if type(name) == "string" then
      out[name] = out[name] or {}
      table.insert(out[name], lhs)
    end
  end
  for _, list in pairs(out) do
    table.sort(list)
  end
  return out
end

return M
