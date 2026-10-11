---@mod fugitive.config Defaults, validation and merging of user options.

local M = {}

---@alias fugitive.Route "float"|"notify"|"task"|"terminal"|"editor"

---@class fugitive.Config
---@field maps table<string, table<string, string|false>> per-buffer-type `lhs -> action` tables
---@field routes table<string, fugitive.Route> per-subcommand route overrides
---@field notify {max_lines: integer}
---@field output {ring_size: integer}
---@field float {width: number, height: number, border: string|string[]}
---@field editor {window: "split"|"vsplit"|"tab"|"current"}
---@field discard {journal_size: integer}
---@field watch {enabled: boolean, debounce: integer}
---@field long_running string[] subcommands that run as overseer tasks
---@field browse {hosts: table<string, string>, providers: table<string, function>}
---@field integrations {telescope: boolean, overseer: boolean, gitsigns: boolean}
---@field summary {window: "split"|"vsplit"|"tab"|"current", log_limit: integer}

---@type fugitive.Config
M.defaults = {
  -- Each buffer type has its own table. `false` disables a map; users can add
  -- new lhs entries pointing at any action name of that buffer type.
  maps = {
    summary = {
      -- staging
      ["s"] = "stage",
      ["u"] = "unstage",
      ["-"] = "toggle",
      ["U"] = "unstage_all",
      ["X"] = "discard",
      ["g-"] = "restore_discard",
      ["="] = "inline_toggle",
      ["<"] = "inline_hide",
      [">"] = "inline_show",
      ["I"] = "patch",
      ["P"] = "patch",
      ["gI"] = "ignore",
      ["gi"] = "open_exclude",
      -- navigation
      ["<CR>"] = "open",
      ["<2-LeftMouse>"] = "open",
      ["o"] = "open_split",
      ["gO"] = "open_vsplit",
      ["O"] = "open_tab",
      ["p"] = "open_preview",
      ["("] = "prev_item",
      [")"] = "next_item",
      ["[c"] = "prev_hunk",
      ["]c"] = "next_hunk",
      ["K"] = "prev_hunk",
      ["J"] = "next_hunk",
      ["i"] = "next_expanded_hunk",
      ["[/"] = "prev_file",
      ["]/"] = "next_file",
      ["[m"] = "prev_file",
      ["]m"] = "next_file",
      ["[["] = "prev_section",
      ["]]"] = "next_section",
      ["[]"] = "prev_section_end",
      ["]["] = "next_section_end",
      ["gu"] = "jump_untracked",
      ["gU"] = "jump_unstaged",
      ["gs"] = "jump_staged",
      ["gp"] = "jump_unpushed",
      ["gP"] = "jump_unpulled",
      ["gr"] = "jump_rebasing",
      ["gq"] = "close",
      ["g?"] = "help",
      ["<F1>"] = "help",
      ["R"] = "reload",
      ["."] = "cmdline",
      -- diff
      ["dd"] = "diff",
      ["dv"] = "diff_vertical",
      ["ds"] = "diff_horizontal",
      ["dh"] = "diff_horizontal",
      ["dq"] = "diff_close",
      ["dp"] = "diff_patch",
      -- commit
      ["cc"] = "commit",
      ["ca"] = "commit_amend",
      ["ce"] = "commit_extend",
      ["cw"] = "commit_reword",
      ["cva"] = "commit_amend_verbose",
      ["cvc"] = "commit_verbose",
      ["cRa"] = "commit_reset_author",
      ["cRe"] = "commit_reset_author_extend",
      ["cRw"] = "commit_reset_author_reword",
      ["cf"] = "commit_fixup",
      ["cF"] = "commit_fixup_rebase",
      ["cs"] = "commit_squash",
      ["cS"] = "commit_squash_rebase",
      ["cn"] = "commit_squash_edit",
      ["c<Space>"] = "commit_prompt",
      ["c<CR>"] = "commit",
      ["cv<Space>"] = "commit_verbose_prompt",
      ["cv<CR>"] = "commit_verbose",
      -- revert
      ["crc"] = "revert",
      ["crn"] = "revert_no_commit",
      ["cr<Space>"] = "revert_prompt",
      ["cr<CR>"] = "revert_bare",
      -- merge
      ["cm<Space>"] = "merge_prompt",
      ["cm<CR>"] = "merge_bare",
      -- M2: checkout / branch
      ["coo"] = "checkout",
      ["co<Space>"] = "checkout_prompt",
      ["co<CR>"] = "checkout_bare",
      ["cb<Space>"] = "branch_prompt",
      ["cb<CR>"] = "branch_bare",
      -- M2: stash
      ["czz"] = "stash_push",
      ["czw"] = "stash_push_keep_index",
      ["czs"] = "stash_push_staged",
      ["cza"] = "stash_apply_index",
      ["czA"] = "stash_apply",
      ["czp"] = "stash_pop_index",
      ["czP"] = "stash_pop",
      ["czv"] = "stash_view",
      ["cz<Space>"] = "stash_prompt",
      ["cz<CR>"] = "stash_bare",
      -- M2: rebase
      ["ri"] = "rebase_interactive",
      ["rf"] = "rebase_autosquash",
      ["ru"] = "rebase_upstream",
      ["rp"] = "rebase_push",
      ["rr"] = "rebase_continue",
      ["rs"] = "rebase_skip",
      ["ra"] = "rebase_abort",
      ["re"] = "rebase_edit_todo",
      ["rw"] = "rebase_reword",
      ["rm"] = "rebase_edit",
      ["rd"] = "rebase_drop",
      ["r<Space>"] = "rebase_prompt",
      ["r<CR>"] = "rebase_bare",
    },
    -- fugitive:// object buffers (commits, trees, blobs)
    object = {
      ["<CR>"] = "open",
      ["o"] = "open_split",
      ["gO"] = "open_vsplit",
      ["O"] = "open_tab",
      ["("] = "prev_item",
      [")"] = "next_item",
      ["[c"] = "prev_hunk",
      ["]c"] = "next_hunk",
      ["dq"] = "diff_close",
      ["gq"] = "close",
      ["g?"] = "help",
    },
    -- work-tree files that contain conflict markers
    conflict = {
      ["]x"] = "next_conflict",
      ["[x"] = "prev_conflict",
      ["co"] = "choose_ours",
      ["ct"] = "choose_theirs",
      ["cb"] = "choose_both",
      ["c0"] = "choose_none",
    },
    -- work-tree hunk maps, delegated to gitsigns.nvim. Empty by default so we
    -- never clobber the user's own gitsigns maps; actions: next_hunk,
    -- prev_hunk, stage_hunk, reset_hunk.
    worktree = {},
    -- pager-style output (float or split) and editor buffers
    pager = {
      ["q"] = "close",
      ["<Esc>"] = "close",
      ["<C-c>"] = "cancel",
    },
  },
  routes = {},
  notify = { max_lines = 10 },
  output = { ring_size = 20 },
  float = { width = 0.9, height = 0.85, border = "rounded" },
  editor = { window = "split" },
  discard = { journal_size = 200 },
  watch = { enabled = true, debounce = 150 },
  long_running = { "pull", "fetch", "push", "clone", "submodule update", "lfs" },
  browse = { hosts = {}, providers = {} },
  integrations = { telescope = true, overseer = true, gitsigns = true },
  summary = { window = "split", log_limit = 256 },
}

---@type fugitive.Config
M.values = vim.deepcopy(M.defaults)

local function validate(opts)
  vim.validate("opts", opts, "table")
  for key, spec in pairs({
    maps = "table",
    routes = "table",
    notify = "table",
    output = "table",
    float = "table",
    editor = "table",
    discard = "table",
    watch = "table",
    long_running = "table",
    browse = "table",
    integrations = "table",
    summary = "table",
  }) do
    vim.validate("opts." .. key, opts[key], spec, true)
  end
  local valid_routes = { float = true, notify = true, task = true, terminal = true, editor = true }
  for sub, route in pairs(opts.routes or {}) do
    if not valid_routes[route] then
      error(string.format("fugitive: invalid route %q for subcommand %q", tostring(route), sub))
    end
  end
  for buftype, maps in pairs(opts.maps or {}) do
    if not M.defaults.maps[buftype] then
      error(string.format("fugitive: unknown map table %q", buftype))
    end
    for lhs, action in pairs(maps) do
      if action ~= false and type(action) ~= "string" and type(action) ~= "function" then
        error(string.format("fugitive: maps.%s[%q] must be an action name, a function or false", buftype, lhs))
      end
    end
  end
  if opts.notify and opts.notify.max_lines ~= nil then
    vim.validate("opts.notify.max_lines", opts.notify.max_lines, "number")
  end
end

---Merge `opts` over the defaults. Lists (e.g. `long_running`) are replaced,
---not merged; map tables are merged key by key so a single map can be changed.
---@param opts? table
---@return fugitive.Config
function M.merge(opts)
  opts = opts or {}
  validate(opts)
  local merged = vim.deepcopy(M.defaults)
  for key, value in pairs(opts) do
    if key == "maps" then
      for buftype, maps in pairs(value) do
        for lhs, action in pairs(maps) do
          merged.maps[buftype][lhs] = action
        end
      end
    elseif vim.islist(value) or type(value) ~= "table" then
      merged[key] = value
    else
      merged[key] = vim.tbl_deep_extend("force", merged[key] or {}, value)
    end
  end
  return merged
end

---@param opts? table
function M.set(opts)
  M.values = M.merge(opts)
  return M.values
end

---@return fugitive.Config
function M.get()
  return M.values
end

return M
