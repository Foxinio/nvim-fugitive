# nvim-fugitive

A Lua, Neovim-only rewrite of [vim-fugitive](https://github.com/tpope/vim-fugitive).
The core is drop-in compatible: the same commands, the same `:Git` summary
buffer and maps, and the same `fugitive://` URLs. On top of that it
integrates with `vim.notify`/noice, telescope.nvim, overseer.nvim and
gitsigns.nvim, none of which is required.

The design document is [project.md](project.md); the user manual is
[`:help fugitive`](doc/fugitive.txt).

## Requirements

- Neovim ≥ 0.11, git ≥ 2.40, Linux or macOS
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- optional: telescope.nvim, overseer.nvim, gitsigns.nvim, noice.nvim

## Installation

With lazy.nvim:

```lua
{
  "Foxinio/nvim-fugitive",
  dependencies = { "nvim-lua/plenary.nvim" },
  cmd = { "Git", "G", "Gdiffsplit", "Gvdiffsplit", "Ghdiffsplit", "Ggrep", "Glgrep",
          "GMove", "GRename", "GDelete", "GRemove", "GUnlink", "GBrowse",
          "FugitiveOutput", "FugitiveRestore" },
  opts = {}, -- optional, see :help fugitive-config
}
```

`require("nvim-fugitive").setup()` is optional. Everything loads lazily on first use.

## What's in it

| Feature | Notes |
|---|---|
| `:Git` summary | Head/Merge/Push header, Rebasing, Unmerged, Untracked, Unstaged, Staged, Unpushed/Unpulled, Stashes; upstream maps (`s u - U X = < > I P gI gi`, `<CR> o gO O p ( ) [c ]c i [[ ]] gu gs gp …`, `cc ca ce cw cf cF cs cS cn crc crn`, `coo`, `cz*`, `r*`); visual partial staging; folds; refreshed by a filesystem watcher |
| `:Git {args}` | routed by command type: pager commands → float, others → `vim.notify`, network commands → overseer task, `add -p` & co. → terminal, always-editing commands → editor first. `:Git!` runs in the background, `:vert`/`:tab` open output in a window |
| Editor service | commit messages, rebase todo lists and merge messages open in this Neovim from every route, including overseer tasks; `:wq` continues, `:q!` aborts |
| `X` with recovery | every discard is saved (`hash-object -w`) and journaled; `:Git restore-discard`, `:FugitiveRestore`, `g-` |
| `fugitive://` objects | read-only blobs, trees and commits with navigation |
| Diffs & conflicts | `:Gdiffsplit` family, upstream 3-way `:Gdiffsplit!` with `d2o`/`d3o`, conflict-marker maps `]x [x co ct cb c0` |
| `:Ggrep`/`:Glgrep` | telescope picker when available, quickfix/loclist otherwise |
| `:GMove` & co. | `:GMove :GRename :GDelete :GRemove :GUnlink` |
| `:GBrowse` | upstream-identical handler dict (rhubarb, fugitive-gitlab keep working), built-in GitHub/GitLab/Bitbucket/Gitea/Forgejo/Codeberg/sourcehut providers, custom hosts |
| Pickers | `:Telescope fugitive log` / `refs` / `stash`; picker input for a bare `:Git checkout`, `switch`, `merge` or `rebase` |
| `:FugitiveOutput` | full output of recent commands; notifications are truncated and point here |

Not implemented yet: `:Git blame` side window, `:Gedit`/`:Gread`/`:Gwrite`
and the editable index, `:Gclog`, difftool/mergetool, `:Gcd`, statusline
and Vimscript API, bisect, bare repositories. See
`:help fugitive-differences`.

## Development

```sh
make deps         # clones plenary.nvim and telescope.nvim into .deps/
make test         # unit + integration suites (plenary-busted, headless)
make parity       # compare with upstream: UPSTREAM=../vim-fugitive
make lint         # stylua, selene, lua-language-server
```

Tests build throwaway repositories in a temporary directory and drive real
git. The parity harness runs the same scenarios against upstream
vim-fugitive in a child Neovim and compares the summary text, the
repository state after maps, and `:GBrowse` handler dictionaries; the
captured dictionaries live in `tests/fixtures/browse_upstream.json` so the
regular suite checks them without upstream.

Layout:

```
plugin/fugitive.lua        commands and autocommands
lua/nvim-fugitive/
  config.lua               defaults, validation, map tables
  git/{exec,repo,status,diff}.lua
  object.lua               fugitive:// URLs and object names
  buffers/{reader,editor,diffsplit}.lua, buffers/summary/
  cmd/{git,routes,grep,move,browse,complete}.lua
  ui/{notify,float,output,terminal}.lua
  discard.lua conflict.lua watch.lua maps.lua
  integrations/{overseer,gitsigns}.lua, integrations/{telescope,browse}/
lua/telescope/_extensions/fugitive.lua
tests/{unit,integration,parity,fixtures}/
```
