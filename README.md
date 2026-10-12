# nvim-fugitive

A Lua, Neovim-only rewrite of [vim-fugitive](https://github.com/tpope/vim-fugitive).
The core is drop-in compatible: the same commands, the same `:Git` summary
buffer and maps, and the same `fugitive://` URLs. On top of that it
integrates with `vim.notify`/noice, telescope.nvim, overseer.nvim and
gitsigns.nvim, none of which is required.

The user manual is [`:help fugitive`](doc/fugitive.txt); the design document
is [project.md](project.md); development notes are in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Requirements

- Neovim ≥ 0.11, git ≥ 2.40, Linux or macOS
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- optional: telescope.nvim, overseer.nvim, gitsigns.nvim, noice.nvim

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Foxinio/nvim-fugitive",
  dependencies = { "nvim-lua/plenary.nvim" },
  cmd = { "Git", "G", "Gedit", "Gsplit", "Gvsplit", "Gtabedit", "Gpedit", "Gdrop",
          "Gread", "Gwrite", "Gwq",
          "Gdiffsplit", "Gvdiffsplit", "Ghdiffsplit", "Ggrep", "Glgrep",
          "GMove", "GRename", "GDelete", "GRemove", "GUnlink", "GBrowse",
          "FugitiveOutput", "FugitiveRestore" },
  opts = {}, -- optional, see "Configuration" below
}
```

Calling `require("nvim-fugitive").setup()` is optional; everything loads
lazily on first use.

## Quick start

| Do this | Get this |
|---|---|
| `:Git` | the summary buffer: staged/unstaged/untracked files, unpushed commits, stashes |
| `s` / `u` / `-` on a file | stage / unstage / toggle it (in Visual mode on diff lines: just those lines) |
| `=` on a file | show its diff inline |
| `cc` | commit: the message opens in this Neovim, `:wq` to commit, `:q!` to abort |
| `X` on a file | discard the change (it is saved first; undo with `g-` or `:Git restore-discard`) |
| `dd` on a file | `:Gdiffsplit` against the index (three-way for conflicts) |
| `:Git log`, `:Git show` | output in a big float, `<CR>` on a commit opens it |
| `:Git pull` | runs as an overseer task (or a background job) |
| `:GBrowse` | open the file on GitHub/GitLab/… (`:GBrowse!` copies the URL) |
| `g?` | every map of the buffer you are in |

## Features

| Feature | Notes |
|---|---|
| `:Git` summary | Head/Merge/Push header, Rebasing, Unmerged, Untracked, Unstaged, Staged, Unpushed/Unpulled, Stashes; upstream maps; visual partial staging; folds; refreshed by a filesystem watcher; the cursor skips blank lines |
| `:Git {args}` | output routed by command type: pager commands → float, others → notification, network commands → overseer task, `add -p` & co. → terminal; only significant commands notify on success |
| Editor service | commit messages, rebase todo lists and merge messages open in this Neovim from every route, including overseer tasks |
| `X` with recovery | every discard is saved (`hash-object -w`) and journaled; `:Git restore-discard`, `:FugitiveRestore`, `g-` |
| `fugitive://` objects | `:Gedit`/`:Gsplit`/`:Gvsplit`/`:Gtabedit`/`:Gpedit`/`:Gdrop` with the full object syntax (`@`, `!`, `:%`, `:/message`, `main...other`, …); blobs, trees and commits with navigation (`~ P C -`) |
| `:Git blame` | upstream's scroll-bound side window; `<CR>` jumps to the commit's hunk, `-`/`~`/`P` reblame; `<CR>` in a blob opens the line's commit |
| Editable index | `:w` in an index buffer stages it; `:Gread`, `:Gwrite`, `:Gwq`; `do`/`dp` + `:w` in a `:Gdiffsplit` stage single hunks |
| Diffs & conflicts | `:Gdiffsplit` family, upstream 3-way `:Gdiffsplit!` with `d2o`/`d3o`, conflict-marker maps `]x [x co ct cb c0` |
| `:Ggrep`/`:Glgrep` | telescope picker when available, quickfix/loclist otherwise |
| `:GMove` & co. | `:GMove :GRename :GDelete :GRemove :GUnlink` |
| `:GBrowse` | upstream-identical handler dict (vim-rhubarb, fugitive-gitlab keep working), built-in GitHub/GitLab/Bitbucket/Gitea/Forgejo/Codeberg/sourcehut providers, custom hosts |
| Pickers | `:Telescope fugitive log` / `refs` / `stash`; picker input for a bare `:Git checkout`, `switch`, `merge` or `rebase` |
| `:FugitiveOutput` | full output of recent commands; notifications are truncated and point here |

See `:help fugitive-differences` for what is not implemented yet.

## Configuration

Everything is optional. Pass only what you want to change; tables are merged
with the defaults, map tables key by key, and lists replace the default
list. A few common changes:

```lua
require("nvim-fugitive").setup({
  maps = {
    summary = {
      ["X"] = false,        -- disable a map
      ["<leader>s"] = "stage", -- add a map for any action name
    },
  },
  routes = {
    status = "float",                     -- show `:Git status` in the float
    ["log --graph"] = "vert",             -- graphs in a vertical split
    pull = "term",                        -- watch pulls in a terminal
  },
  notify = { max_lines = 5 },
  float = { width = 0.8, height = 0.8, border = "single" },
  integrations = { overseer = false },    -- run pull/push as plain jobs
  browse = { hosts = { ["git.example.com"] = "gitlab" } },
})
```

<details>
<summary><b>Default configuration</b> (every option with its default)</summary>

```lua
require("nvim-fugitive").setup({
  -- Map tables per buffer type: lhs = action name. `false` disables a map;
  -- `g?` in a buffer lists its maps. :help fugitive-summary-maps
  maps = {
    summary = {
      ["cb<CR>"] = "branch_bare",
      ["cb<Space>"] = "branch_prompt",
      ["coo"] = "checkout",
      ["co<CR>"] = "checkout_bare",
      ["co<Space>"] = "checkout_prompt",
      ["gq"] = "close",
      ["."] = "cmdline",
      ["c<CR>"] = "commit",
      ["cc"] = "commit",
      ["ca"] = "commit_amend",
      ["cva"] = "commit_amend_verbose",
      ["ce"] = "commit_extend",
      ["cf"] = "commit_fixup",
      ["cF"] = "commit_fixup_rebase",
      ["c<Space>"] = "commit_prompt",
      ["cRa"] = "commit_reset_author",
      ["cRe"] = "commit_reset_author_extend",
      ["cRw"] = "commit_reset_author_reword",
      ["cw"] = "commit_reword",
      ["cs"] = "commit_squash",
      ["cn"] = "commit_squash_edit",
      ["cS"] = "commit_squash_rebase",
      ["cv<CR>"] = "commit_verbose",
      ["cvc"] = "commit_verbose",
      ["cv<Space>"] = "commit_verbose_prompt",
      ["dd"] = "diff",
      ["dq"] = "diff_close",
      ["dh"] = "diff_horizontal",
      ["ds"] = "diff_horizontal",
      ["dp"] = "diff_patch",
      ["dv"] = "diff_vertical",
      ["X"] = "discard",
      ["<F1>"] = "help",
      ["g?"] = "help",
      ["gI"] = "ignore",
      ["<"] = "inline_hide",
      [">"] = "inline_show",
      ["="] = "inline_toggle",
      ["gr"] = "jump_rebasing",
      ["gs"] = "jump_staged",
      ["gP"] = "jump_unpulled",
      ["gp"] = "jump_unpushed",
      ["gU"] = "jump_unstaged",
      ["gu"] = "jump_untracked",
      ["cm<CR>"] = "merge_bare",
      ["cm<Space>"] = "merge_prompt",
      ["i"] = "next_expanded_hunk",
      ["]/"] = "next_file",
      ["]m"] = "next_file",
      ["J"] = "next_hunk",
      ["]c"] = "next_hunk",
      [")"] = "next_item",
      ["]]"] = "next_section",
      ["]["] = "next_section_end",
      ["<2-LeftMouse>"] = "open",
      ["<CR>"] = "open",
      ["gi"] = "open_exclude",
      ["p"] = "open_preview",
      ["o"] = "open_split",
      ["O"] = "open_tab",
      ["gO"] = "open_vsplit",
      ["I"] = "patch",
      ["P"] = "patch",
      ["[/"] = "prev_file",
      ["[m"] = "prev_file",
      ["K"] = "prev_hunk",
      ["[c"] = "prev_hunk",
      ["("] = "prev_item",
      ["[["] = "prev_section",
      ["[]"] = "prev_section_end",
      ["ra"] = "rebase_abort",
      ["rf"] = "rebase_autosquash",
      ["r<CR>"] = "rebase_bare",
      ["rr"] = "rebase_continue",
      ["rd"] = "rebase_drop",
      ["rm"] = "rebase_edit",
      ["re"] = "rebase_edit_todo",
      ["ri"] = "rebase_interactive",
      ["r<Space>"] = "rebase_prompt",
      ["rp"] = "rebase_push",
      ["rw"] = "rebase_reword",
      ["rs"] = "rebase_skip",
      ["ru"] = "rebase_upstream",
      ["R"] = "reload",
      ["g-"] = "restore_discard",
      ["crc"] = "revert",
      ["cr<CR>"] = "revert_bare",
      ["crn"] = "revert_no_commit",
      ["cr<Space>"] = "revert_prompt",
      ["s"] = "stage",
      ["czA"] = "stash_apply",
      ["cza"] = "stash_apply_index",
      ["cz<CR>"] = "stash_bare",
      ["czP"] = "stash_pop",
      ["czp"] = "stash_pop_index",
      ["cz<Space>"] = "stash_prompt",
      ["czz"] = "stash_push",
      ["czw"] = "stash_push_keep_index",
      ["czs"] = "stash_push_staged",
      ["czv"] = "stash_view",
      ["-"] = "toggle",
      ["u"] = "unstage",
      ["U"] = "unstage_all",
    },
    object = {
      ["~"] = "ancestor",
      ["gq"] = "close",
      ["."] = "cmdline",
      ["C"] = "containing_commit",
      ["dq"] = "diff_close",
      ["g?"] = "help",
      ["-"] = "navigate_up",
      ["]c"] = "next_hunk",
      [")"] = "next_item",
      ["<CR>"] = "open",
      ["p"] = "open_preview",
      ["o"] = "open_split",
      ["O"] = "open_tab",
      ["gO"] = "open_vsplit",
      ["P"] = "parent",
      ["[c"] = "prev_hunk",
      ["("] = "prev_item",
    },
    blame = {
      ["gq"] = "close",
      ["."] = "cmdline",
      ["<F1>"] = "help",
      ["g?"] = "help",
      ["<2-LeftMouse>"] = "open",
      ["<CR>"] = "open",
      ["p"] = "open_preview",
      ["o"] = "open_split",
      ["O"] = "open_tab",
      ["-"] = "reblame",
      ["~"] = "reblame_ancestor",
      ["P"] = "reblame_parent",
      ["A"] = "resize_author",
      ["C"] = "resize_commit",
      ["D"] = "resize_date",
    },
    conflict = {
      ["cb"] = "choose_both",
      ["c0"] = "choose_none",
      ["co"] = "choose_ours",
      ["ct"] = "choose_theirs",
      ["]x"] = "next_conflict",
      ["[x"] = "prev_conflict",
    },
    worktree = {},
    pager = {
      ["<C-c>"] = "cancel",
      ["<Esc>"] = "close",
      ["q"] = "close",
    },
  },
  -- Where each command's output goes, by "subcommand" or "subcommand word"
  -- (e.g. ["stash list"], ["log --graph"]). Targets: "float", "inplace",
  -- "split", "vert", "tab" (output in a buffer), "notification", "overseer",
  -- "term". Unlisted commands use the built-in table: pager commands ->
  -- float, network commands -> overseer, `add -p` & co. -> term, everything
  -- else -> notification (:help fugitive-output).
  routes = {},
  notify = {
    -- notifications are cut after this many lines (:FugitiveOutput has all)
    max_lines = 10,
    -- successful commands notify only when listed here ("sub" or "sub flag");
    -- errors always notify
    significant = {
      "commit", "merge", "rebase", "revert", "cherry-pick", "pull", "push",
      "fetch", "clone", "checkout", "switch", "stash", "am", "bisect", "tag",
      "branch", "reset --hard", "reset --keep", "reset --merge", "restore-discard",
    },
  },
  -- how many commands :FugitiveOutput remembers
  output = { ring_size = 20 },
  -- the pager float
  float = {
    width = 0.9, -- fraction of the editor (<= 1) or columns (> 1)
    height = 0.85, -- fraction of the editor (<= 1) or lines (> 1)
    border = "rounded", -- any 'winborder' value or a list of 8 chars
    style = "minimal", -- "" for Neovim's default window style
    title = true, -- show the command as the float title
    title_pos = "center",
    zindex = 50,
    winblend = 0,
  },
  -- where commit messages and rebase todo lists open:
  -- "split", "vsplit", "tab" or "current"
  editor = { window = "split" },
  -- discard journal length (.git/fugitive/discard.json)
  discard = { journal_size = 200 },
  -- refresh the summary when .git changes on disk (debounce in ms)
  watch = { enabled = true, debounce = 150 },
  -- subcommands run as overseer tasks (or background jobs without overseer)
  long_running = { "pull", "fetch", "push", "clone", "submodule update", "lfs" },
  -- :GBrowse: host -> provider name, and custom providers
  browse = { hosts = {}, providers = {} },
  -- optional plugins; each falls back gracefully when not installed
  integrations = { telescope = true, overseer = true, gitsigns = true },
  -- the summary window ("split", "vsplit", "tab", "current") and how many
  -- commits the Unpushed/Unpulled sections show
  summary = { window = "split", log_limit = 256 },
})
```

</details>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): `make deps && make test` runs the
whole (hermetic) test suite.
