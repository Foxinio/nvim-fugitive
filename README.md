# nvim-fugitive

A Lua, Neovim-only rewrite of [vim-fugitive](https://github.com/tpope/vim-fugitive):
the same commands, the same `:Git` summary buffer and maps, the same
`fugitive://` URLs and Vimscript API, so your muscle memory and the plugins
built on vim-fugitive (vim-rhubarb, fugitive-gitlab, …) keep working.

On top of that:

- **Output where it belongs.** `:Git log` and friends open in a float,
  short commands report through `vim.notify` (noice, nvim-notify), long
  ones run as [overseer](https://github.com/stevearc/overseer.nvim) tasks.
  Every command can be routed elsewhere.
- **Commit messages in this Neovim, from anywhere**, including tasks and
  rebases started in the background.
- **Nothing lost to `X`.** Every discarded change is saved first and can be
  restored.
- **Pickers.** Log, refs, stashes, file and line history, and remote and
  branch pickers for `:Git push`, with
  [telescope](https://github.com/nvim-telescope/telescope.nvim) or
  `vim.ui.select`.
- **Changes as a tree.** In the summary, files that share a directory
  group under it, and a directory folds like a file's diff. Or keep
  vim-fugitive's flat list: see [Upstream parity](#upstream-parity).
- **gitsigns** shows a commit's changes in the files you open from it.
- **git's colours** in the float, with
  [term-color-parser.nvim](https://github.com/Foxinio/term-color-parser.nvim).

The manual is [`:help fugitive`](doc/fugitive.txt).

## Requirements

- Neovim 0.11 or later, git 2.40 or later, Linux or macOS.
- Nothing else. These optional plugins add to it when installed:

| Plugin | Adds |
|---|---|
| [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) | pickers (otherwise `vim.ui.select`) |
| [overseer.nvim](https://github.com/stevearc/overseer.nvim) | pull, push, fetch & co. as tasks (otherwise background jobs) |
| [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) | hunk maps, signs in `fugitive://` buffers |
| [term-color-parser.nvim](https://github.com/Foxinio/term-color-parser.nvim) | git's colours in the float |
| [noice.nvim](https://github.com/folke/noice.nvim) / [nvim-notify](https://github.com/rcarriga/nvim-notify) | nicer notifications (anything that renders `vim.notify`) |

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "Foxinio/nvim-fugitive", opts = {} }
```

Neovim 0.12's built-in `vim.pack`:

```lua
vim.pack.add({ "https://github.com/Foxinio/nvim-fugitive" })
```

There's nothing to gain from lazy-loading it on its commands. Loading takes
under a millisecond and loads none of its modules, which come in on first
use. Lazy-loading would leave `fugitive://` files unreadable and
`FugitiveHead()` undefined in your statusline until the first `:Git`.

`setup()` is optional: without it, the defaults apply.

**Coming from vim-fugitive?** Remove it: both plugins define the same
commands, and only one of them loads. Your maps, `fugitive://` URLs,
statusline and fugitive-based plugins keep working.

## Quick start

| Do this | Get this |
|---|---|
| `:Git` | the summary buffer: staged/unstaged/untracked files, unpushed commits, stashes |
| `s` / `u` / `-` on a file | stage / unstage / toggle it (in Visual mode on diff lines: just those lines) |
| `=` on a file | show its diff inline |
| `=` on a directory | fold or unfold its files (`s`, `u`, `-`, `X` on a directory act on all of them) |
| `cc` | commit: the message opens in this Neovim, `:wq` to commit, `:q!` to abort |
| `X` on a file | discard the change (it is saved first; undo with `g-` or `:Git restore-discard`) |
| `dd` on a file | `:Gdiffsplit` against the index (three-way for conflicts) |
| `:Git log`, `:Git show` | output in a big float, `<CR>` on a commit opens it |
| `:Git pull` | runs as an overseer task (or a background job) |
| `:GBrowse` | open the file on GitHub/GitLab/… (`:GBrowse!` copies the URL) |
| `g?` | every map of the buffer you are in |

### Suggested maps

fugitive maps nothing outside its own buffers. A starting point:

```lua
vim.keymap.set("n", "<leader>gg", "<Cmd>Git<CR>", { desc = "Git summary" })
vim.keymap.set("n", "<leader>gb", "<Cmd>Git blame<CR>", { desc = "Git blame" })
vim.keymap.set("n", "<leader>gl", "<Cmd>Gclog %<CR>", { desc = "File history" })
vim.keymap.set("n", "<leader>gd", "<Cmd>Gvdiffsplit<CR>", { desc = "Diff with the index" })
vim.keymap.set("n", "<leader>gp", "<Cmd>Git push<CR>", { desc = "Git push" })
```

And the branch in your statusline:

```lua
vim.o.statusline = "%f %h%m%r %{FugitiveHead()}%=%l,%c %P"
```

## Configuration

Pass only what you want to change. Tables merge with the defaults, maps key
by key, and lists replace the default list.

### Recipes

Sign off every commit (default arguments per git command,
`:h fugitive-args`):

```lua
require("nvim-fugitive").setup({
  args = { commit = { "--signoff" } },
})
```

Send a command's output somewhere else (`:h fugitive-output`): `float`,
`split`, `vert`, `tab`, `inplace`, `notification`, `overseer` or `term`:

```lua
require("nvim-fugitive").setup({
  routes = {
    status = "float", -- :Git status in the float
    ["log --graph"] = "vert", -- graphs in a vertical split
    pull = "term", -- watch pulls in a terminal
  },
})
```

Change, add or remove maps; an action name or a function
(`g?` in a buffer lists its maps):

```lua
require("nvim-fugitive").setup({
  maps = {
    summary = {
      ["X"] = false, -- no discard on X
      ["<leader>s"] = "stage",
      ["<leader>l"] = function()
        vim.cmd("Git log --oneline -20")
      end,
    },
  },
})
```

Open the summary in a tab, and commit messages in a vertical split:

```lua
require("nvim-fugitive").setup({
  summary = { window = "tab" },
  editor = { window = "vsplit" },
})
```

Show each file's status as the background colour of its name instead of a
letter (the colours are the `FugitiveStatus*` highlight groups,
`:h fugitive-summary-tree`):

```lua
require("nvim-fugitive").setup({
  summary = { status = "color" },
})
```

Full paths under the directory lines, and a line for every directory level:

```lua
require("nvim-fugitive").setup({
  summary = { paths = "full", compact = false },
})
```

A smaller float, with a square border:

```lua
require("nvim-fugitive").setup({
  float = { width = 0.7, height = 0.7, border = "single" },
})
```

Run pull and push as plain background jobs even with overseer installed:

```lua
require("nvim-fugitive").setup({
  integrations = { overseer = false },
})
```

`:GBrowse` for a self-hosted GitLab (`:h fugitive-browse`):

```lua
require("nvim-fugitive").setup({
  browse = { hosts = { ["git.example.com"] = "gitlab" } },
})
```

<details>
<summary><b>All options and their defaults</b> (key maps: <code>g?</code> in each buffer, and <code>:h fugitive-summary-maps</code>)</summary>

```lua
require("nvim-fugitive").setup({
  -- Where each command's output goes, by "subcommand" or "subcommand word"
  -- (e.g. ["stash list"], ["log --graph"]). Targets: "float", "inplace",
  -- "split", "vert", "tab" (output in a buffer), "notification", "overseer",
  -- "term". Unlisted commands use the built-in table: pager commands ->
  -- float, network commands -> overseer, `add -p` & co. -> term, git
  -- aliases like the command they unfold to (shell `!` aliases running one
  -- git command too, other ones -> overseer; key them by name here),
  -- everything else -> notification
  -- (:help fugitive-output).
  routes = {},
  notify = {
    -- notifications are cut after this many lines (:FugitiveOutput has all)
    max_lines = 10,
    -- successful commands that print nothing notify only when listed here
    -- ("sub" or "sub flag"); output and errors always notify
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
  summary = {
    -- the summary window: "split", "vsplit", "tab" or "current"
    window = "split",
    -- how many commits the Unpushed/Unpulled sections show
    log_limit = 256,
    -- files as a directory tree; = < > fold a directory (:h fugitive-summary-tree)
    tree = true,
    -- no line for a directory with one changed file, or for a directory whose
    -- only content is one subdirectory (lua/nvim-fugitive/ is one line)
    compact = true,
    -- files under a directory line: "name" (indented) or "full" (whole path)
    paths = "name",
    -- "letter" (M, A, D, ?, …) or "color" (the name's background shows it)
    status = "letter",
  },
  -- default arguments per subcommand ("sub" or "sub word"), added right
  -- after it for every command fugitive runs except :Git! (typed commands,
  -- summary maps, aliases), e.g. { commit = { "--signoff" } }
  args = {},
})
```

</details>

## Upstream parity

The commands, maps, `fugitive://` URLs and Vimscript API work as in
vim-fugitive. By default the summary shows its files as a tree. For
vim-fugitive's flat list with status letters:

```lua
require("nvim-fugitive").setup({
  summary = { tree = false, status = "letter" },
})
```

`status = "letter"` is already the default; it's there so the snippet also
undoes a `status = "color"` set elsewhere.

With these settings the summary's text is the same as vim-fugitive's; the
test suite checks it against vim-fugitive itself. The other deliberate
differences, such as where command output goes and the editor service, are
listed in `:help fugitive-differences`.

## Features

| Feature | Notes |
|---|---|
| `:Git` summary | files as a foldable directory tree (or upstream's flat list); Head/Merge/Push header, Rebasing, Bisecting, Unmerged, Untracked, Unstaged, Staged, Unpushed/Unpulled and Stashes (`=` expands a commit or stash); upstream maps plus bisect (`bg bb bs br`) and submodule (`cu cU`) maps; visual partial staging; folds; refreshed by a filesystem watcher; the cursor skips blank lines |
| `:Git {args}` | output routed by command type (configurable per command: float, inplace, split, vert, tab, notification, overseer, term); successful commands notify their output, or a short note when significant; failed pushes put rejected refs and hook errors in quickfix |
| Editor service | commit messages, rebase todo lists and merge messages open in this Neovim from every route, including overseer tasks |
| `X` with recovery | every discard is saved (`hash-object -w`) and journaled; `:Git restore-discard`, `:FugitiveRestore`, `g-` |
| `fugitive://` objects | `:Gedit`/`:Gsplit`/`:Gvsplit`/`:Gtabedit`/`:Gpedit`/`:Gdrop` with the full object syntax (`@`, `!`, `:%`, `:/message`, `main...other`, …); blobs, trees and commits with navigation (`~ P C -`) |
| `:Git blame` | upstream's scroll-bound side window; `<CR>` jumps to the commit's hunk, `-`/`~`/`P` reblame; `<CR>` in a blob opens the line's commit |
| Editable index | `:w` in an index buffer stages it; `:Gread`, `:Gwrite`, `:Gwq`; `do`/`dp` + `:w` in a `:Gdiffsplit` stage single hunks |
| Diffs & conflicts | `:Gdiffsplit` family, upstream 3-way `:Gdiffsplit!` with `d2o`/`d3o`, conflict-marker maps `]x [x co ct cb c0` |
| `:Git difftool`/`mergetool` | changed hunks or conflicts in quickfix; `-y` opens a diff per file in tabs; plus `:Gcd`/`:Glcd` |
| `:Gclog`/`:Gllog` | commit history in quickfix/loclist; `:{range}Gclog` follows lines with `git log -L` |
| `:Ggrep`/`:Glgrep` | telescope picker when available, quickfix/loclist otherwise |
| `:GMove` & co. | `:GMove :GRename :GDelete :GRemove :GUnlink` |
| `:GBrowse` | upstream-identical handler dict (vim-rhubarb, fugitive-gitlab keep working), built-in GitHub/GitLab/Bitbucket/Gitea/Forgejo/Codeberg/sourcehut providers, custom hosts |
| Pickers | `:Telescope fugitive log` / `refs` / `stash` / `file_history` / `line_history` / `blame_line`, or `:FugitivePick` (falls back to `vim.ui.select`); picker input for `:Git checkout`, `switch`, `merge` or `rebase` given only flags, and remote + branch pickers for `:Git push` without an upstream (or `:Git push -u`, which keeps the choice) |
| Work-tree hunks | opt-in maps for next/prev/stage/reset hunk, using gitsigns when installed and fugitive's own hunks otherwise |
| Repositories | work trees, linked worktrees, submodules, bare repos, `core.worktree`, `$GIT_DIR`/`$GIT_WORK_TREE` dotfile setups |
| Vimscript API | `FugitiveHead()`, `FugitiveStatusline()`, `FugitiveGitDir()`, `FugitiveFind()`, `FugitiveExecute()`, … and upstream's `User` events, so plugins written for vim-fugitive keep working; `gf` on objects |
| `:FugitiveOutput` | full output of recent commands; notifications are truncated and point here |

See `:help fugitive-differences` for the deliberate differences from
vim-fugitive.

## Troubleshooting

- `:checkhealth nvim-fugitive` shows what fugitive found: versions, your
  options, the repository, the git settings that affect it (with the file
  each comes from) and the optional plugins.
- `:FugitiveOutput` has the full output of recent commands; notifications
  are cut short.
- `:help fugitive` is the manual.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): `make deps && make test` runs the
whole (hermetic) test suite. The design notes are in [project.md](project.md).
