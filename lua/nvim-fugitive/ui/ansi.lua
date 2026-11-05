---@mod nvim-fugitive.ui.ansi Git's colours, through term-color-parser.nvim.
---
---With term-color-parser.nvim installed (its Lua module is `ansi-colorize`),
---pager output runs with git's colours where git would colour it in a
---terminal, and the plugin's decoder turns the escape sequences into
---highlights. Without it, git runs without colours; escape sequences that
---still arrive (an explicit `--color`) are dropped.

local M = {}

---@type table|false|nil the plugin's module; false: not installed
local lib

local function plugin()
  if lib == nil then
    local ok, mod = pcall(require, "ansi-colorize")
    lib = ok and type(mod) == "table" and mod.decoder and mod or false
  end
  return lib or nil
end

---Is term-color-parser.nvim installed (with its decoder)?
---@return boolean
function M.available()
  return plugin() ~= nil
end

---Text without escape sequences.
---@param text string
---@return string
function M.strip(text)
  if not text:find("\27", 1, true) then
    return text
  end
  local p = plugin()
  if p then
    return p.strip_text(text)
  end
  return (
    text
      :gsub("\27%[[0-?]*[ -/]*[@-~]", "")
      :gsub("\27%][^\7\27]*\7", "")
      :gsub("\27%][^\27]*\27\\", "")
      :gsub("\27.", "")
  )
end

-- without the plugin: the text without escapes, and no highlights
local Plain = {}
Plain.__index = Plain
function Plain:feed(chunk)
  return (M.strip(chunk):gsub("\r", "")), {}
end

---A decoder for one stream of output: `:feed(chunk)` returns the chunk's
---text without escape sequences and its highlight spans.
---@return {feed: fun(self, chunk: string): string, table[]}
function M.decoder()
  local p = plugin()
  return p and p.decoder() or setmetatable({}, Plain)
end

---Decode a whole text: its lines and highlight spans.
---@param text string
---@return string[] lines, table[] spans
function M.decode(text)
  local p = plugin()
  if p then
    return p.decode(text)
  end
  return vim.split((M.strip(text):gsub("\r", "")), "\n", { plain = true }), {}
end

---Highlight decoded spans in `buf`.
---@param buf integer
---@param spans table[]
function M.apply(buf, spans)
  local p = plugin()
  if p and #spans > 0 then
    p.apply(buf, spans)
  end
end

---Remove the highlights from `buf` (its text is about to be replaced).
---@param buf integer
function M.clear(buf)
  local p = plugin()
  if p then
    vim.api.nvim_buf_clear_namespace(buf, p.ns, 0, -1)
  end
end

return M
