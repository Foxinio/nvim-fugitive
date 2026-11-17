---@mod nvim-fugitive.buffers.summary.colors The colour style's highlight groups, from the colorscheme.
---
---Each status colour is taken from the colorscheme, from the group the inline
---diff uses for the same kind of change (diffAdded, diffChanged, diffRemoved,
---then Added, Changed, Removed, then gitsigns'), as gitsigns, neo-tree and
---nvim-tree relate a file's status to its diff. It fills the name's
---background, with the editor's background colour as the text, as Neogit does
---for its coloured blocks. Untracked files get grey text and no background.
---
---The groups are derived again on ColorScheme, except those the user or the
---colorscheme set themselves.

local M = {}

---Where each status colour comes from: the first group with a colour wins;
---`fallback` is linked when none has one.
local sources = {
  FugitiveStatusAdded = { "diffAdded", "Added", "GitSignsAdd", fallback = "DiffAdd" },
  FugitiveStatusModified = {
    "diffChanged",
    "Changed",
    "GitSignsChange",
    fallback = "DiffChange",
  },
  FugitiveStatusDeleted = {
    "diffRemoved",
    "Removed",
    "GitSignsDelete",
    fallback = "DiffDelete",
  },
  FugitiveStatusUnmerged = { "DiagnosticWarn", "WarningMsg", fallback = "DiffText" },
}
-- renames and type changes are modifications (neo-tree does the same)
sources.FugitiveStatusRenamed = sources.FugitiveStatusModified
sources.FugitiveStatusTypechange = sources.FugitiveStatusModified

---What we set each group to last; a group holding anything else was set by
---someone else and is left alone.
---@type table<string, table>
local ours = {}

---The resolved highlight of `name` (links followed).
local function get(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and h or {}
end

---Black or white, whichever reads better on `rgb`.
local function contrast(rgb)
  local r, g, b = math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
  return (0.299 * r + 0.587 * g + 0.114 * b) > 140 and 0x000000 or 0xffffff
end

---Light or dark cterm text for a 0-255 colour (0-15: the bright half is 8-15,
---minus the dark blue/black ones; the cube and grey ramp by lightness).
local function cterm_contrast(c)
  if c < 16 then
    local light = { [3] = true, [7] = true, [10] = true, [11] = true, [14] = true, [15] = true }
    return light[c] and 0 or 15
  end
  if c >= 232 then
    return c >= 244 and 0 or 15
  end
  c = c - 16
  local r, g, b = math.floor(c / 36), math.floor(c / 6) % 6, c % 6
  return (0.299 * r + 0.587 * g + 0.114 * b) > 2.5 and 0 or 15
end

---The spec a group gets from the current colorscheme.
local function derive(chain)
  local fg, ctermfg
  for _, name in ipairs(chain) do
    local h = get(name)
    fg = fg or h.fg
    ctermfg = ctermfg or h.ctermfg
    if fg and ctermfg then
      break
    end
  end
  if not fg and not ctermfg then
    return { link = chain.fallback }
  end
  local spec = {}
  if fg then
    spec.bg = fg
    spec.fg = get("Normal").bg or contrast(fg)
  end
  if ctermfg then
    spec.ctermbg = ctermfg
    spec.ctermfg = cterm_contrast(ctermfg)
  end
  return spec
end

---The group as nvim_get_hl reports it, comparable with what we set.
local function current(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name })
  return ok and h or {}
end

local function same(a, b)
  return vim.deep_equal(a, b)
end

---Set `name` to `spec` unless someone else has set it since we last did.
local function set(name, spec)
  local now = current(name)
  if next(now) ~= nil and not (ours[name] and same(now, ours[name])) then
    return
  end
  vim.api.nvim_set_hl(0, name, spec)
  ours[name] = current(name)
end

---Define (or re-derive) the groups.
function M.define()
  for name, chain in pairs(sources) do
    set(name, derive(chain))
  end
  set("FugitiveStatusUntracked", { link = "Comment" })
end

local augroup
---Define the groups now and on every colorscheme change.
function M.setup()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("fugitive_status_colors", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = M.define,
  })
  M.define()
end

return M
