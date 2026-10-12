# Contributing to nvim-fugitive

## Setup

```sh
make deps    # clones plenary.nvim and telescope.nvim into .deps/ (git-ignored)
```

Requirements for development: Neovim ≥ 0.11, git ≥ 2.40, and for linting
[stylua](https://github.com/JohnnyMorganz/StyLua) **2.0.2** (CI pins this
version, newer releases format differently),
[selene](https://github.com/Kampfkarren/selene) and
[lua-language-server](https://github.com/LuaLS/lua-language-server).

## Make targets

```sh
make test     # unit + integration suites (plenary-busted, headless)
make unit     # tests/unit only: pure modules, no buffers
make integration
make parity   # compare with upstream vim-fugitive: UPSTREAM=../vim-fugitive
make lint     # stylua --check, selene, lua-language-server on lua/
make format   # stylua
```

Pass `NVIM=/path/to/nvim` to run the suites with another Neovim binary.

Run a single test file with the same isolated configuration:

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/integration/summary_spec.lua"
```

## The test suite is hermetic

Running the tests must never touch anything outside a temporary directory:

- every test builds throwaway repositories (`tests/helpers.lua`: `H.repo`,
  `H.clone`) and drives real git against them; remotes are local paths;
- `tests/minimal_init.lua` clears inherited `GIT_*` variables, points `HOME`
  and `XDG_CONFIG_HOME` at a temporary directory, disables the global and
  system git config, credential prompts and askpass helpers, and sets
  `BROWSER=true`;
- `vim.ui.open` is replaced by a stub that records URLs in
  `_G.fugitive_test_opened` — assert on that instead of opening anything;
- child Neovims (the plenary runner, the parity harness) use the same init
  or equivalent stubs.

If you add a feature that launches an external program, stub it in
`tests/minimal_init.lua` and add an assertion to `tests/unit/smoke_spec.lua`.

## Parity harness

`tests/parity/` runs the same scenarios against upstream vim-fugitive in a
child Neovim and compares the summary buffer text, the repository state
after maps, and `:GBrowse` handler dictionaries. Refresh the captured
dictionaries in `tests/fixtures/browse_upstream.json` with:

```sh
make parity UPSTREAM=../vim-fugitive UPDATE_FIXTURES=1
```

The regular integration suite compares ours against that fixture, so it
does not need upstream.

## Layout

```
plugin/fugitive.lua        commands and autocommands
lua/nvim-fugitive/
  init.lua                 setup(), public Lua API
  config.lua               defaults, validation, map tables
  git/{exec,repo,status,diff}.lua
  object.lua               fugitive:// URLs and object names
  buffers/{reader,editor,diffsplit,blame}.lua, buffers/summary/
  cmd/{git,routes,grep,move,browse,complete,edit,log,difftool}.lua
  ui/{notify,float,output,terminal}.lua
  discard.lua conflict.lua hunks.lua watch.lua maps.lua
  api.lua                  the upstream-compatible Vimscript API
  integrations/{overseer,gitsigns}.lua, integrations/{telescope,browse}/
lua/telescope/_extensions/fugitive.lua
autoload/fugitive.vim      fugitive#Head() & co. for statusline plugins
doc/fugitive.txt           the user manual (handwritten)
tests/{unit,integration,parity,fixtures}/
```

Principles (see [project.md](project.md) §6): one git execution layer
(`git/exec.lua`), pure parsers separate from UI so unit tests need no
buffers, integrations loaded lazily with `pcall(require, …)`, and every
mutation ends in `User FugitiveChanged`.

## Commits

Small commits, one topic each, with tests and `doc/fugitive.txt` updated in
the same commit. `make test` and `make lint` must pass. CI runs the suites
on Neovim stable and nightly (Linux and macOS), a job pinned to git 2.40,
the parity harness and lint.
