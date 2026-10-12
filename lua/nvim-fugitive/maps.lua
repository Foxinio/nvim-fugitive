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
  local no_maps = vim.g.fugitive_no_maps and vim.g.fugitive_no_maps ~= 0
  for lhs, name in pairs(maps) do
    -- like upstream, g:fugitive_no_maps also drops the gf-style maps
    if name and not (no_maps and type(name) == "string" and name:match("^cfile_")) then
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

---gf-style actions for buffers whose cursor can name an object, plus the
---command-line <C-R><C-F> that inserts that object.
---@param buf integer
---@return table<string, fun()>
function M.cfile_actions(buf)
  local function open(how)
    return function()
      local target, lnum = require("nvim-fugitive.api").cfile()
      if not target then
        require("nvim-fugitive.ui.notify").warn("no object under the cursor")
        return
      end
      require("nvim-fugitive.buffers.reader").open(target, how, lnum)
    end
  end
  if not (vim.g.fugitive_no_maps and vim.g.fugitive_no_maps ~= 0) then
    vim.keymap.set("c", "<C-R><C-F>", function()
      local target = require("nvim-fugitive.api").cfile()
      return target and vim.fn.fnameescape(target) or vim.fn.expand("<cfile>")
    end, { buffer = buf, expr = true, desc = "fugitive: object under the cursor" })
  end
  return {
    cfile_edit = open("edit"),
    cfile_split = open("split"),
    cfile_tab = open("tab"),
  }
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
