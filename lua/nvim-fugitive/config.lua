---@mod nvim-fugitive.config Defaults, validation and merging of user options.

local M = {}

---@alias fugitive.Route "float"|"notify"|"task"|"terminal"|"editor"

---@class fugitive.StatusStyle how the summary shows a file's status
---@field letters boolean M, A, D, ?, … before each file
---@field color {enabled: boolean, from: "name"|"line", to: "name"|"line"} as the name's background

---@class fugitive.Config
---@field maps table<string, table<string, string|false>> per-buffer-type `lhs -> action` tables
---@field routes table<string, fugitive.Route> per-subcommand route overrides
---@field notify {max_lines: integer, significant: string[]}
---@field output {ring_size: integer}
---@field float {width: number, height: number, border: string|string[], style: string, title: boolean, title_pos: string, zindex: integer, winblend: integer}
---@field editor {window: "split"|"vsplit"|"tab"|"current"}
---@field discard {journal_size: integer}
---@field watch {enabled: boolean, debounce: integer, recheck: integer}
---@field long_running string[] subcommands that run as overseer tasks
---@field browse {hosts: table<string, string>, providers: table<string, function>}
---@field integrations {telescope: boolean, overseer: boolean, gitsigns: boolean}
---@field summary {window: "split"|"vsplit"|"tab"|"current", log_limit: integer, tree: boolean, compact: boolean, paths: "name"|"full", status: fugitive.StatusStyle, hints: boolean}
---@field args table<string, string[]> default arguments per subcommand ("sub" or "sub word")

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
      ["<BS>"] = "fold_dir",
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
      ["f"] = "open_float",
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
      ["gf"] = "cfile_edit",
      ["<C-W>f"] = "cfile_split",
      ["<C-W><C-F>"] = "cfile_split",
      ["<C-W>gf"] = "cfile_tab",
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
      -- by section: ours/theirs/both/neither on an Unmerged file; co checks
      -- out a commit. No key may extend them, so coo, co<Space>, co<CR>,
      -- cb<Space> and cb<CR> are upstream preset only
      ["co"] = "choose_ours",
      ["ct"] = "choose_theirs",
      ["cb"] = "choose_both",
      ["c0"] = "choose_none",
      -- M2: stash
      ["czz"] = "stash_push",
      ["czw"] = "stash_push_keep_index",
      ["czs"] = "stash_push_staged",
      ["cza"] = "stash_apply_line",
      ["czA"] = "stash_apply",
      ["czp"] = "stash_pop_line",
      ["czP"] = "stash_pop",
      ["czv"] = "stash_view_line",
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
      ["rw"] = "rebase_reword_line",
      ["rm"] = "rebase_edit_line",
      ["rd"] = "rebase_drop_line",
      ["r<Space>"] = "rebase_prompt",
      ["r<CR>"] = "rebase_bare",
      -- submodules
      ["cu"] = "submodule_init",
      ["cU"] = "submodule_init_recursive",
      -- bisect
      ["bg"] = "bisect_good",
      ["bb"] = "bisect_bad",
      ["bs"] = "bisect_skip",
      ["br"] = "bisect_reset",
    },
    -- fugitive:// object buffers (commits, trees, blobs)
    object = {
      ["<CR>"] = "open",
      ["o"] = "open_split",
      ["gO"] = "open_vsplit",
      ["O"] = "open_tab",
      ["p"] = "open_preview",
      ["("] = "prev_item",
      [")"] = "next_item",
      ["[c"] = "prev_hunk",
      ["]c"] = "next_hunk",
      ["dq"] = "diff_close",
      ["gq"] = "close",
      ["g?"] = "help",
      ["~"] = "ancestor",
      ["P"] = "parent",
      ["C"] = "containing_commit",
      ["-"] = "navigate_up",
      ["."] = "cmdline",
      ["gf"] = "cfile_edit",
      ["<C-W>f"] = "cfile_split",
      ["<C-W><C-F>"] = "cfile_split",
      ["<C-W>gf"] = "cfile_tab",
    },
    -- the :Git blame side window
    blame = {
      ["g?"] = "help",
      ["<F1>"] = "help",
      ["gq"] = "close",
      ["<CR>"] = "open",
      ["<2-LeftMouse>"] = "open",
      ["o"] = "open_split",
      ["O"] = "open_tab",
      ["p"] = "open_preview",
      ["-"] = "reblame",
      ["~"] = "reblame_ancestor",
      ["P"] = "reblame_parent",
      ["A"] = "resize_author",
      ["C"] = "resize_commit",
      ["D"] = "resize_date",
      ["."] = "cmdline",
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
  notify = {
    max_lines = 10,
    -- Successful commands that print nothing notify only when they are
    -- significant: a subcommand name, or "sub flag" to require a flag.
    -- Output and errors always notify, and the full output of every command
    -- is in :FugitiveOutput.
    significant = {
      "commit",
      "merge",
      "rebase",
      "revert",
      "cherry-pick",
      "pull",
      "push",
      "fetch",
      "clone",
      "checkout",
      "switch",
      "stash",
      "am",
      "bisect",
      "tag",
      "branch",
      "reset --hard",
      "reset --keep",
      "reset --merge",
      "restore-discard",
    },
  },
  output = { ring_size = 20 },
  float = {
    -- fractions of the editor (<= 1) or absolute cells (> 1)
    width = 0.9,
    height = 0.85,
    border = "rounded",
    style = "minimal", -- "" for Neovim's default window style
    title = true, -- show the command as the float title
    title_pos = "center",
    zindex = 50,
    winblend = 0,
  },
  editor = { window = "split" },
  discard = { journal_size = 200 },
  watch = { enabled = true, debounce = 150, recheck = 5000 },
  long_running = { "pull", "fetch", "push", "clone", "submodule update", "lfs" },
  browse = { hosts = {}, providers = {} },
  integrations = { telescope = true, overseer = true, gitsigns = true },
  summary = {
    window = "split",
    log_limit = 256,
    tree = true,
    compact = true,
    paths = "full",
    status = {
      letters = false,
      color = { enabled = true, from = "name", to = "line" },
    },
    -- greyed key hints after section headings
    hints = true,
  },
  -- default arguments per subcommand ("sub" or "sub word"), added right
  -- after it, e.g. { commit = { "--signoff" } }; not for :Git!
  args = {},
}

---The key presets (`maps.preset`): "upstream" is vim-fugitive's keys,
---frozen; "default" is this plugin's own, free to change. M.defaults.maps
---is the default preset.
M.presets = {}

---vim-fugitive's keys, frozen: a copy of the key tables as they were when
---the presets came in. Never edit it along with M.defaults.maps.
M.presets.upstream = {
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
    ["<BS>"] = "fold_dir",
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
    ["f"] = "open_float",
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
    ["gf"] = "cfile_edit",
    ["<C-W>f"] = "cfile_split",
    ["<C-W><C-F>"] = "cfile_split",
    ["<C-W>gf"] = "cfile_tab",
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
    -- submodules
    ["cu"] = "submodule_update",
    ["cU"] = "submodule_update_recursive",
    -- bisect
    ["bg"] = "bisect_good",
    ["bb"] = "bisect_bad",
    ["bs"] = "bisect_skip",
    ["br"] = "bisect_reset",
  },
  -- fugitive:// object buffers (commits, trees, blobs)
  object = {
    ["<CR>"] = "open",
    ["o"] = "open_split",
    ["gO"] = "open_vsplit",
    ["O"] = "open_tab",
    ["p"] = "open_preview",
    ["("] = "prev_item",
    [")"] = "next_item",
    ["[c"] = "prev_hunk",
    ["]c"] = "next_hunk",
    ["dq"] = "diff_close",
    ["gq"] = "close",
    ["g?"] = "help",
    ["~"] = "ancestor",
    ["P"] = "parent",
    ["C"] = "containing_commit",
    ["-"] = "navigate_up",
    ["."] = "cmdline",
    ["gf"] = "cfile_edit",
    ["<C-W>f"] = "cfile_split",
    ["<C-W><C-F>"] = "cfile_split",
    ["<C-W>gf"] = "cfile_tab",
  },
  -- the :Git blame side window
  blame = {
    ["g?"] = "help",
    ["<F1>"] = "help",
    ["gq"] = "close",
    ["<CR>"] = "open",
    ["<2-LeftMouse>"] = "open",
    ["o"] = "open_split",
    ["O"] = "open_tab",
    ["p"] = "open_preview",
    ["-"] = "reblame",
    ["~"] = "reblame_ancestor",
    ["P"] = "reblame_parent",
    ["A"] = "resize_author",
    ["C"] = "resize_commit",
    ["D"] = "resize_date",
    ["."] = "cmdline",
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
}

M.presets.default = M.defaults.maps

---@type fugitive.Config
M.values = vim.deepcopy(M.defaults)

---Is `key` a "sub" or "sub word" key (of `routes` or `args`)? `flag_word`
---allows a flag as the word ("reset --hard").
local function sub_key(key, flag_word)
  if type(key) ~= "string" then
    return false
  end
  local word = key:match("^%S+%s+(%S+)$")
  if not word then
    return key:match("^%S+$") ~= nil
  end
  return flag_word or word:sub(1, 1) ~= "-"
end

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
    args = "table",
  }) do
    vim.validate("opts." .. key, opts[key], spec, true)
  end
  local routes = require("nvim-fugitive.cmd.routes")
  for key, target in pairs(opts.routes or {}) do
    if not sub_key(key, true) then
      error(
        string.format('fugitive: invalid routes key %q (use "sub" or "sub word")', tostring(key))
      )
    end
    if type(target) ~= "string" or not routes.targets[routes.normalize(target)] then
      error(string.format("fugitive: invalid output target %q for %q", tostring(target), key))
    end
  end
  local preset = opts.maps and opts.maps.preset
  if preset ~= nil and not M.presets[preset] then
    error(
      string.format(
        'fugitive: maps.preset must be "default" or "upstream", not %s',
        vim.inspect(preset)
      )
    )
  end
  for buftype, maps in pairs(opts.maps or {}) do
    if buftype ~= "preset" and not M.defaults.maps[buftype] then
      error(string.format("fugitive: unknown map table %q", buftype))
    end
    for lhs, action in pairs(buftype ~= "preset" and maps or {}) do
      if action ~= false and type(action) ~= "string" and type(action) ~= "function" then
        error(
          string.format(
            "fugitive: maps.%s[%q] must be an action name, a function or false",
            buftype,
            lhs
          )
        )
      end
    end
  end
  for key, list in pairs(opts.args or {}) do
    -- arguments go right after the last word, which a flag cannot be
    if not sub_key(key, false) then
      error(string.format('fugitive: invalid args key %q (use "sub" or "sub word")', tostring(key)))
    end
    if type(list) ~= "table" or not vim.islist(list) then
      error(string.format("fugitive: args[%q] must be a list of strings", key))
    end
    for _, a in ipairs(list) do
      if type(a) ~= "string" then
        error(string.format("fugitive: args[%q] must be a list of strings", key))
      end
    end
  end
  local summary = opts.summary or {}
  for key, kind in pairs({ tree = "boolean", compact = "boolean" }) do
    if summary[key] ~= nil then
      vim.validate("opts.summary." .. key, summary[key], kind)
    end
  end
  local function one_of(name, value, allowed)
    if value ~= nil and not vim.tbl_contains(allowed, value) then
      error(
        string.format(
          'fugitive: %s must be "%s", not %s',
          name,
          table.concat(allowed, '" or "'),
          vim.inspect(value)
        )
      )
    end
  end
  one_of("summary.paths", summary.paths, { "name", "full" })
  local status = summary.status
  if type(status) == "string" then
    error(
      "fugitive: summary.status is now a table: { letters = true } or"
        .. " { color = { ... } } (:h fugitive-summary-tree)"
    )
  end
  if status ~= nil then
    vim.validate("opts.summary.status", status, "table")
    vim.validate("opts.summary.status.letters", status.letters, "boolean", true)
    local color = status.color
    if color ~= nil then
      vim.validate("opts.summary.status.color", color, "table")
      vim.validate("opts.summary.status.color.enabled", color.enabled, "boolean", true)
      one_of("summary.status.color.from", color.from, { "name", "line" })
      one_of("summary.status.color.to", color.to, { "name", "line" })
    end
  end
  vim.validate("opts.summary.hints", summary.hints, "boolean", true)
  local recheck = opts.watch and opts.watch.recheck
  if recheck ~= nil and (type(recheck) ~= "number" or recheck < 0) then
    error(
      "fugitive: watch.recheck must be a number of ms (0 turns it off), not "
        .. vim.inspect(recheck)
    )
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
  local preset = opts.maps and opts.maps.preset or "default"
  merged.maps = vim.deepcopy(M.presets[preset])
  for key, value in pairs(opts) do
    if key == "maps" then
      for buftype, maps in pairs(value) do
        if buftype ~= "preset" then
          for lhs, action in pairs(maps) do
            merged.maps[buftype][lhs] = action
          end
        end
      end
    elseif type(value) ~= "table" or vim.islist(M.defaults[key]) then
      -- a list option (long_running) is replaced; tables merge, an empty
      -- one included (vim.islist({}) is true)
      merged[key] = value
    else
      merged[key] = vim.tbl_deep_extend("force", merged[key] or {}, value)
    end
  end
  return merged
end

---The options of the last `set()` and its validation error, for
---`:checkhealth nvim-fugitive`.
---@type table?
M.user = nil
---@type string?
M.error = nil

---Keys that hide longer ones: maps are nowait, so with "co" mapped "coo"
---can never be typed. Disabled (false) keys don't count.
---@param maps table<string, table<string, any>> map tables by buffer type
---@return string[] messages like 'maps.summary: "co" hides "coo"'
function M.prefix_conflicts(maps)
  local out = {}
  for buftype, tbl in pairs(maps) do
    if type(tbl) == "table" then
      local keys = {}
      for lhs, action in pairs(tbl) do
        if action then
          table.insert(keys, lhs)
        end
      end
      table.sort(keys)
      -- compare the keys typed, not their notation ("<" is no prefix of "<CR>")
      local typed = {}
      for _, lhs in ipairs(keys) do
        typed[lhs] = vim.keycode(lhs)
      end
      for _, short in ipairs(keys) do
        for _, long in ipairs(keys) do
          local s, l = typed[short], typed[long]
          if #l > #s and l:sub(1, #s) == s then
            table.insert(out, string.format('maps.%s: "%s" hides "%s"', buftype, short, long))
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

---@param opts? table
function M.set(opts)
  M.user, M.error = opts, nil
  local ok, merged = pcall(M.merge, opts)
  if not ok then
    M.error = tostring(merged)
    error(merged, 0)
  end
  local conflicts = M.prefix_conflicts(merged.maps)
  if #conflicts > 0 then
    vim.notify(
      "nvim-fugitive: " .. table.concat(conflicts, "; ") .. " (maps don't wait for a longer key)",
      vim.log.levels.WARN
    )
  end
  M.values = merged
  return M.values
end

---@return fugitive.Config
function M.get()
  return M.values
end

return M
