---@mod nvim-fugitive.ui.ansi Git's colours (ANSI SGR) as highlights.
---
---Pager output is run with colours when git would colour it in a terminal;
---a decoder turns the escape sequences into plain text plus highlight spans,
---which are applied as extmarks.

local M = {}

M.ns = vim.api.nvim_create_namespace("fugitive_ansi")

-- the usual terminal palette, for colorschemes without g:terminal_color_N
local palette = {
  "#000000",
  "#cd3131",
  "#0dbc79",
  "#e5e510",
  "#2472c8",
  "#bc3fbc",
  "#11a8cd",
  "#e5e5e5",
  "#666666",
  "#f14c4c",
  "#23d18b",
  "#f5f543",
  "#3b8eea",
  "#d670d6",
  "#29b8db",
  "#ffffff",
}

---#rrggbb of a 256-colour index.
---@param n integer
---@return string
function M.hex(n)
  if n < 16 then
    return vim.g["terminal_color_" .. n] or palette[n + 1]
  elseif n < 232 then
    local levels = { 0, 95, 135, 175, 215, 255 }
    local i = n - 16
    return string.format(
      "#%02x%02x%02x",
      levels[math.floor(i / 36) + 1],
      levels[math.floor(i / 6) % 6 + 1],
      levels[i % 6 + 1]
    )
  end
  local g = 8 + (n - 232) * 10
  return string.format("#%02x%02x%02x", g, g, g)
end

local function dim(hex)
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then
    return hex
  end
  local function d(x)
    return math.floor(tonumber(x, 16) * 0.6)
  end
  return string.format("#%02x%02x%02x", d(r), d(g), d(b))
end

---@class fugitive.AnsiState
---@field fg? integer|string 256-colour index or #rrggbb
---@field bg? integer|string
---@field bold? boolean
---@field dim? boolean
---@field italic? boolean
---@field underline? boolean
---@field reverse? boolean

local groups = {}
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("fugitive_ansi", { clear = true }),
  callback = function()
    groups = {}
  end,
})

---Highlight group for a state (nil for the default look).
---@param st fugitive.AnsiState
---@return string?
function M.group(st)
  if not (st.fg or st.bg or st.bold or st.dim or st.italic or st.underline or st.reverse) then
    return nil
  end
  local key = table.concat({
    tostring(st.fg or ""),
    tostring(st.bg or ""),
    st.bold and "b" or "",
    st.dim and "d" or "",
    st.italic and "i" or "",
    st.underline and "u" or "",
    st.reverse and "r" or "",
  }, "_")
  local name = groups[key]
  if name then
    return name
  end
  name = "FugitiveAnsi_" .. key:gsub("[^%w]", "")
  local spec = {
    bold = st.bold or nil,
    italic = st.italic or nil,
    underline = st.underline or nil,
    reverse = st.reverse or nil,
    default = true,
  }
  local function color(c)
    if type(c) == "number" then
      return M.hex(c), c
    end
    return c, nil
  end
  if st.fg then
    spec.fg, spec.ctermfg = color(st.fg)
  end
  if st.bg then
    spec.bg, spec.ctermbg = color(st.bg)
  end
  if st.dim then
    if spec.fg then
      spec.fg = dim(spec.fg)
    else
      local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
      spec.fg = comment.fg
    end
  end
  vim.api.nvim_set_hl(0, name, spec)
  groups[key] = name
  return name
end

---Apply one SGR parameter string ("1;34", "38;5;208", "") to a state.
---@param st fugitive.AnsiState
---@param params string
function M.sgr(st, params)
  local codes = {}
  for p in (params:gsub(":", ";") .. ";"):gmatch("([^;]*);") do
    table.insert(codes, tonumber(p) or 0)
  end
  if #codes == 0 then
    codes = { 0 }
  end
  local i = 1
  while i <= #codes do
    local c = codes[i]
    if c == 0 then
      for k in pairs(st) do
        st[k] = nil
      end
    elseif c == 1 then
      st.bold = true
    elseif c == 2 then
      st.dim = true
    elseif c == 3 then
      st.italic = true
    elseif c == 4 then
      st.underline = true
    elseif c == 7 then
      st.reverse = true
    elseif c == 21 or c == 22 then
      st.bold, st.dim = nil, nil
    elseif c == 23 then
      st.italic = nil
    elseif c == 24 then
      st.underline = nil
    elseif c == 27 then
      st.reverse = nil
    elseif c >= 30 and c <= 37 then
      st.fg = c - 30
    elseif c >= 90 and c <= 97 then
      st.fg = c - 90 + 8
    elseif c >= 40 and c <= 47 then
      st.bg = c - 40
    elseif c >= 100 and c <= 107 then
      st.bg = c - 100 + 8
    elseif c == 39 then
      st.fg = nil
    elseif c == 49 then
      st.bg = nil
    elseif c == 38 or c == 48 then
      local field = c == 38 and "fg" or "bg"
      if codes[i + 1] == 5 and codes[i + 2] then
        st[field] = codes[i + 2]
        i = i + 2
      elseif codes[i + 1] == 2 and codes[i + 4] then
        st[field] = string.format("#%02x%02x%02x", codes[i + 2], codes[i + 3], codes[i + 4])
        i = i + 4
      end
    end
    i = i + 1
  end
end

---@class fugitive.AnsiDecoder
---@field row integer row of the next text, from 0
---@field col integer byte column of the next text
---@field state fugitive.AnsiState
---@field carry string an escape sequence cut off at the end of a chunk
---@field open {col: integer, group: string}?
local Decoder = {}
Decoder.__index = Decoder

---A decoder for one stream of text: rows and columns count from where the
---stream starts (row 0, column 0).
---@return fugitive.AnsiDecoder
function M.decoder()
  return setmetatable({ row = 0, col = 0, state = {}, carry = "" }, Decoder)
end

---Decode a chunk: its text without escape sequences, and the highlight spans
---`{row, col_start, col_end, group}` it covers.
---@param chunk string
---@return string text, {[1]: integer, [2]: integer, [3]: integer, [4]: string}[] spans
function Decoder:feed(chunk)
  local s = self.carry .. chunk
  self.carry = ""
  local out, spans = {}, {}
  local function close()
    if self.open and self.col > self.open.col then
      table.insert(spans, { self.row, self.open.col, self.col, self.open.group })
    end
    self.open = nil
  end
  local function open()
    local g = M.group(self.state)
    if g then
      self.open = { col = self.col, group = g }
    end
  end
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == 27 then
      local nb = s:sub(i + 1, i + 1)
      if nb == "" then
        self.carry = s:sub(i)
        break
      elseif nb == "[" then
        local j = i + 2
        while j <= n and s:byte(j) >= 0x20 and s:byte(j) <= 0x3f do
          j = j + 1
        end
        if j > n then
          self.carry = s:sub(i)
          break
        end
        if s:sub(j, j) == "m" then
          close()
          M.sgr(self.state, s:sub(i + 2, j - 1))
          open()
        end
        i = j + 1
      elseif nb == "]" then
        -- OSC (hyperlinks, titles): up to BEL or ST
        local bel = s:find("\7", i + 2, true)
        local st = s:find("\27\\", i + 2, true)
        local e = bel and (not st or bel < st) and bel or st
        if not e then
          self.carry = s:sub(i)
          break
        end
        i = e + (e == bel and 1 or 2)
      else
        i = i + 2
      end
    elseif b == 10 then
      close()
      table.insert(out, "\n")
      self.row = self.row + 1
      self.col = 0
      open()
      i = i + 1
    elseif b == 13 then
      i = i + 1
    else
      local j = s:find("[\27\n\r]", i) or n + 1
      local text = s:sub(i, j - 1)
      table.insert(out, text)
      self.col = self.col + #text
      i = j
    end
  end
  -- what is open so far, continued by the next chunk
  if self.open and self.col > self.open.col then
    table.insert(spans, { self.row, self.open.col, self.col, self.open.group })
    self.open.col = self.col
  end
  return table.concat(out), spans
end

---Text without escape sequences.
---@param text string
---@return string
function M.strip(text)
  if not text:find("\27", 1, true) then
    return text
  end
  return (
    text
      :gsub("\27%[[0-?]*[ -/]*[@-~]", "")
      :gsub("\27%][^\7\27]*\7", "")
      :gsub("\27%][^\27]*\27\\", "")
      :gsub("\27.", "")
  )
end

---Set decoded spans on a buffer, `row_offset` lines down.
---@param buf integer
---@param spans {[1]: integer, [2]: integer, [3]: integer, [4]: string}[]
---@param row_offset? integer
function M.apply(buf, spans, row_offset)
  row_offset = row_offset or 0
  for _, sp in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, sp[1] + row_offset, sp[2], {
      end_row = sp[1] + row_offset,
      end_col = sp[3],
      hl_group = sp[4],
      priority = 150,
    })
  end
end

---Decode a whole text: its lines and spans.
---@param text string
---@return string[] lines, {[1]: integer, [2]: integer, [3]: integer, [4]: string}[] spans
function M.decode(text)
  local clean, spans = M.decoder():feed(text)
  return vim.split(clean, "\n", { plain = true }), spans
end

return M
