# nvim-fugitive — Lua rewrite of vim-fugitive

> Living design document. Sections marked **OPEN** are still under discussion.

## 1. Goals

- Rewrite vim-fugitive (upstream: tpope/vim-fugitive, ~10k lines of Vimscript,
  `autoload/fugitive.vim` alone is 8.4k) as an idiomatic **Lua, Neovim-only** plugin.
- **Drop-in compatible for core features**: same command names, the same
  status-buffer maps and the same `fugitive://` URL scheme for every feature we keep.
  Deprecated aliases (`:Gstatus`, `:Gblame`, `:Gcommit`, …) are dropped.
- Integrate with the modern Neovim ecosystem: **noice / vim.notify**, **telescope**,
  and optionally **gitsigns**, without making any of them hard requirements.

## 2. Non-goals

- Vim (non-Neovim) support, and compatibility shims for old Neovim versions.
- Reproducing upstream internals (`s:` functions, the Vimscript-era job/tempfile
  plumbing) one-to-one.

## 3. Decisions so far

| Topic        | Decision                                                  |
|--------------|-----------------------------------------------------------|
| Language     | Lua, Neovim-only                                          |
| Compat level | Drop-in for core; no deprecated aliases                   |
| Neovim       | 0.11+                                                     |
| Platforms    | Linux, macOS (CI-tested). Windows/WSL not supported for now |
| Runtime deps | plenary.nvim (async, Job, path). Everything else optional |
| Exec model   | Async by default; sync only where Vim semantics require it (BufReadCmd, BufWriteCmd, :Gwrite) |
| Summary buffer | `:Git` must keep the upstream interface (window, sections, staging, upstream status); only tweak: bindings are configurable |
| Conflict resolution | Required: upstream 3-way `:Gdiffsplit!`, conflict-marker actions in the work tree, an "Unmerged" UX in the summary buffer (§4.3) |
| Object buffers | Only the parts other features need (diff/status/blame navigation); the rest goes to the backlog |
| Blame | Backlog. When implemented: the upstream side window                     |
| Output routing | By **command type**, not length (§5.2)                  |
| git          | ≥ 2.40 only                                               |
| Config       | `require("nvim-fugitive").setup(opts)`, optional; per-buffer-type remappable maps (`false` disables a map); honour `g:fugitive_no_maps` |
| Refresh      | Filesystem watcher (`vim.uv` fs_event on index/HEAD/refs, debounced) + FocusGained/BufEnter |
| Docs         | Handwritten `doc/fugitive.txt`, **not** copied from upstream |
| Long-running ops | Run as **overseer.nvim** tasks (pull, fetch, push, submodule update, …) |

## 4. Upstream feature inventory

Taken from `doc/fugitive.txt` and the sections of `autoload/fugitive.vim`.
Each feature gets a status: **MVP**, **M2** (second milestone), **Backlog**, or **OPEN**.

| # | Feature | Upstream | Status |
|---|---------|----------|--------|
| F1 | Repo detection, `b:git_dir`, worktrees, submodules | Git / Repository Object | MVP: worktrees, symlinks, submodules (§4.1) |
| F2 | `:Git {args}` passthrough (output, `:Git!` bg, `-p`/`--paginate`) | :Git | MVP |
| F3 | Interactive commands in terminal (`:Git rebase -i`, `add -p`) | :Git | MVP (`:terminal` split) |
| F4 | Editor integration (`GIT_EDITOR` → commit msg/rebase todo in a buffer) | :Git | MVP |
| F5 | Summary/status buffer (`:Git` with no args) | :Gstatus | MVP |
| F6 | Staging maps: `s u - U X` (X recovery: §4.2), inline diffs `= < >`, partial-hunk staging (visual) | Maps | MVP (summary buffer incl. visual partial staging of inline diffs; work-tree hunk staging → gitsigns) |
| F7 | Navigation maps: `<CR> o gO O p ( ) [c ]c [[ ]] gu gs gp …` | Maps | MVP |
| F8 | Commit maps `cc ca ce cw cf cF cs cS cn …`, revert `crc crn` | Maps | MVP |
| F9 | Checkout/branch maps `coo cb co` | Maps | M2 |
| F10 | Stash maps `czz czw czs cza czA czp czP` | Maps | M2 |
| F11 | Rebase maps `ri rf ru rp rr rs ra re rw rm rd` | Maps | M2 |
| F12 | `fugitive://` object buffers, `:Gedit/:Gsplit/:Gvsplit/:Gtabedit/:Gpedit/:Gdrop` | File API, :Gedit | MVP: internal reader for `fugitive://` (needed by diff/summary `<CR>`). `:Gedit` family → Backlog |
| F13 | Object syntax (`:0:file`, `HEAD~3:file`, `!`, `@`, `:/` …) | fugitive-object | MVP reduced (`rev:path`, `:N:path`, commit, tree); `!`, `@`, `:/msg` … → Backlog |
| F14 | `:Gread`, `:Gwrite`, `:Gwq` (write to index/work tree) | :Gwrite | Backlog |
| F15 | `:Gdiffsplit` / `:Gvdiffsplit` / `:Ghdiffsplit`, 3-way conflict diffs, `dq` | :Gdiff | MVP read-only splits + 3-way conflict; editable index side → Backlog |
| F16 | `:Git blame` (scroll-bound blame window, maps, reblame) | :Git blame | Backlog (side window when done) |
| F17 | `:Ggrep` / `:Glgrep` → quickfix/loclist | :Ggrep | MVP (telescope-first, quickfix fallback) |
| F18 | `:Gclog` / `:Gllog` (commit history → quickfix, ranged line log `:{range}Gclog`) | :Glog | Backlog (low priority) |
| F19 | `:Git difftool` / `:Git mergetool` → quickfix | difftool | Backlog |
| F20 | `:GMove` / `:GRename` / `:GDelete` / `:GRemove` / `:GUnlink` | :GMove | MVP |
| F21 | `:GBrowse` + URL provider API (rhubarb, fugitive-gitlab …) | :GBrowse | MVP |
| F22 | `:Gcd` / `:Glcd` | :Gcd | Backlog |
| F23 | Command-line completion (refs, paths, subcommands, flags) | Completion | MVP |
| F24 | `gf` / `<Plug><cfile>` on objects in any git buffer | Maps | Backlog |
| F25 | Statusline `FugitiveStatusline()` / `FugitiveHead()` | Statusline | Backlog |
| F26 | Folding of diffs in commit/status buffers | Folding | MVP |
| F27 | `:Git bisect` helpers | :Git bisect | Backlog |
| F28 | Public Vimscript API (`FugitiveGitDir`, `FugitiveFind`, `FugitiveExecute`, User autocmds) | plugin/fugitive.vim | Backlog (GBrowse handler compat is covered in §5.4) |
| F29 | Push/fetch with quickfix error parsing | :Git push | Backlog (overseer covers output) |
| F30 | `.git/info/exclude` / `.gitignore` helpers (`gI`, `gi`) | Maps | MVP (part of the summary maps) |
| F31 | Stash entries in the summary expand inline with `=` (like files) | — | Backlog (user request) |
| F32 | Unified output configuration (§5.2.3) | — | Backlog (user request) |

### 4.1 Repository layouts
- **MVP**
  - *Worktrees*: `.git` may be a file (`gitdir: …`). Resolve both the per-worktree
    git dir (HEAD, index) and the common dir (refs, objects, config). The watcher
    watches both.
  - *Symlinked paths*: two separate things that must not be conflated.
    - **Repository identity** (cache key, watcher target, `fugitive://` URL
      prefix) uses the canonical (`realpath`) git dir and work tree, so a repo reached
      through a symlinked directory is still one repo.
    - **File identity** inside the repo is the repository-relative path *as git
      tracks it*. Only directory components are resolved (realpath of the parent
      dir, then re-relativized against the canonical work tree). The final component
      is **never** dereferenced. A tracked symlink `link -> target` stays the entry
      `link` (mode 120000), so its stage/discard/diff/object URL address `link`, not
      `target`. Dangling symlinks work the same way because nothing needs the target to exist.
    - A link inside repo A pointing into repo B belongs to A, because the link is what A tracks.
    - Fixtures: tracked symlink to a file, tracked symlink to a dir, dangling
      symlink, repo opened through a symlinked parent directory.
  - *Submodules*: buffers inside a submodule resolve to the submodule repo, so `:Git`
    there operates on it. The parent's summary buffer shows submodules as entries;
    actions on them are in §4.1.1.
- **Backlog**: bare repos, and explicit `$GIT_DIR`/`$GIT_WORK_TREE` (dotfile setups).

#### 4.1.1 Submodule behaviour
- Summary entry `<CR>` → open the submodule's own `:Git` summary (stage/commit
  inside it, then return).
- `=` → inline `git diff --submodule=log` shortlog (commits between recorded and
  checked-out SHA). `s` → `git add <path>` (stages the new pointer).
- **Backlog**: dirty/uninitialized indicators, `submodule update --init` maps,
  recursive status.

### 4.2 Discard (`X`) and recovery (MVP)
Upstream saves the file with `git hash-object -w` and prints
`:Gsplit path|Gread <blob>`. `:Gsplit`/`:Gread` are in the backlog here, so we
define our own recovery path:

1. **Save before destroying.** For each selected entry, before any destructive call:
   - the work-tree content: `git hash-object -w -- <path>` (untracked, modified,
     added, or the whole file before a partial-hunk discard);
   - the index entry when the discard touches the index (`Staged` section,
     `rm -f`, `checkout @`): mode + blob from `git ls-files -s`.
   - symlinks: hash the link text (`hash-object -w --stdin` of `readlink`), so the
     link is restored as a link (mode 120000).
   If **any** save fails, the whole `X` operation is **refused** with an error, and
   nothing is touched. Directories and submodules are refused as upstream does.
2. **Journal.** Each discard appends `{time, repo, path, worktree_blob, index_entry,
   mode, kind}` to `<git-common-dir>/fugitive/discard.json`. It survives restarts
   and is capped at N entries (configurable).
3. **Recovery UI.**
   - The notification after `X` names the exact command: `:Git restore-discard`
     (most recent) and the blob SHA. Also `:FugitiveRestore [path]`
     (picker/`vim.ui.select` over journal entries), and a summary-buffer
     map (`u` on the "Discarded" hint line, or `g-` — key OPEN).
   - Restore writes the blob back (`git cat-file blob <sha>` → file, chmod from
     mode; `update-index --cacheinfo` for index entries), then refreshes.
   - Upstream's `D` → undo `GRemove` case (discard restored a deleted file):
     recovery deletes it again.
4. **Caveat in docs**: the saved blobs are unreachable loose objects, so `git gc`
   prunes them after `gc.pruneExpire` (default 2 weeks).
5. **Tests**: discard + restore of an untracked file, an unstaged modification, a
   staged-only change (index restored), a partial-hunk discard, a tracked
   symlink, and the refusal path when `hash-object` fails (read-only object dir).

### 4.3 Conflict resolution (MVP)
1. **3-way `:Gdiffsplit!`**: ours (`//2`) | working | theirs (`//3`), with `d2o`/`d3o`
   and `dp`, exactly as upstream.
2. **Conflict-marker actions in the work tree**: `]x`/`[x` jump between conflict blocks,
   and choose ours / theirs / both / none per block. Extmark highlighting of the regions.
3. **Summary "Unmerged" section**: `2X`/`3X` take ours/theirs for the whole file,
   `s` marks it resolved, and `dd`/`dv` open the 3-way diff.

## 5. Dependencies & integrations

### 5.1 Required
- Neovim ≥ 0.11, git ≥ 2.40, plenary.nvim.

### 5.1.1 Optional
- noice.nvim (indirectly, via `vim.notify`), telescope.nvim, gitsigns.nvim,
  overseer.nvim.

### 5.2 Messages / noice
Two output channels, chosen per message:
- **`vim.notify`** (rendered by noice when installed): errors, warnings, short
  info (e.g. "Staged foo.lua", the undo hint after `X`, push/fetch results).
  Every notification carries `title = "Fugitive"` so users can route them.
- **Large float** (covers most of the screen): long output that you read and
  then dismiss, e.g. `:Git show`/`log` output, help (`g?`), long command errors.
- **Routing rule** — by command type, not output length:
  *if git would open a pager for this command in normal use → float;
  otherwise → notification.* Implemented as an explicit subcommand table that
  can be overridden in config:

  | Channel | Subcommands (initial table) |
  |---------|-----------------------------|
  | Float (pager) | `log show diff blame shortlog reflog grep help`, `branch`/`tag` listing, `stash list`/`stash show` |
  | Notify | `add rm mv reset commit`(non-editing) `checkout switch branch -d tag`(create) `stash push/pop cherry-pick revert` |
  | Overseer task | `pull fetch push clone submodule update lfs` |
  | `:terminal` | truly interactive prompts: `add -p`, `reset -p`, `checkout -p`, `stash -p`, `clean -i` |
  | Editor-first (no output route until the editor closes) | commands that *always* edit: `commit` without `-m/-F/-C/--no-edit`, `rebase -i`, `config -e`, `notes add/edit` without `-m/-F`, `tag -a/-s` without `-m/-F` |

  The editor is **not** an exclusive route (§5.2.1): any route may end up
  invoking the editor (e.g. `pull` creating a merge commit inside an overseer task).

- **Flag classification is per subcommand**, never global. `-e` means
  `--edit` only for `commit merge tag revert cherry-pick config notes` (the table
  lists each). For `grep`, `-e` is a pattern. Classification is a data table
  `{subcommand → {edit_flags, no_edit_flags, pager, route}}`, unit-tested
  against fixtures such as `grep -e foo`, `commit -m x`, `commit --amend`,
  `merge --no-edit`, `config -e` and `config --get x`.

- **Window modifiers**: float-routed output honours command modifiers.
  `:vert Git log`, `:split Git log`, `:tab Git log` (also `:topleft`, `:botright`, …)
  open the output in a regular split/tab buffer instead of the float. Same for
  `:Git -p`/`--paginate`.
- **Notification length limit**: configurable max lines. `vim.notify` gets one
  string, so whatever we pass is all that `:messages`/`:Noice history` will ever
  hold. We therefore **keep the full output ourselves**:
  - Every command's complete stdout/stderr is stored in an output ring (last N
    commands, configurable) and viewable as a read-only scratch buffer via
    `:FugitiveOutput [n]` (default: the latest; it opens in the big float, and
    modifiers such as `:vert` work).
  - A truncated notification ends with `… (+K lines) — :FugitiveOutput`, so the
    pointer to the full text survives in any history.
  - Errors are never truncated below the first error line plus the exit code.
  - Test: with **no** notify plugin installed (plain `vim.notify` → `:messages`),
    run a command with long failing output, assert the truncated message and that
    `:FugitiveOutput` shows the full text.
- No direct noice API dependency. Everything goes through `vim.notify` and our own
  float.

### 5.2.3 Configurable output targets (Backlog, user request)
- Which command produces which kind of output is configurable per subcommand,
  with the targets `inplace`, `float`, `term`, `vert`, `split`, `tab`,
  `notification` and `overseer`. The current routing (§5.2) is the default;
  the old route names stay accepted as aliases.
- Already configurable and to be documented under the same schema: the
  overseer integration (on by default, graceful fallback when not
  installed), the float's size and border (to be extended with style, title
  and z-index), and the summary-buffer keybindings (`maps.summary`).

### 5.2.1 Editor service (orthogonal to routes)
- **Every** foreground git process we spawn, on any route, gets
  `GIT_EDITOR` *and* `GIT_SEQUENCE_EDITOR` (interactive rebase todo) pointing to
  our editor shim, plus `GIT_MERGE_AUTOEDIT=1` for foreground commands (as upstream
  does), and `-c advice.waitingForEditor=false`.
- **Shim protocol** (POSIX sh, modelled on upstream's sentinel script):
  1. git runs `shim <file>`. The shim calls back into the running Neovim via
     `$NVIM` (`nvim --server "$NVIM" --remote-expr
     'v:lua.require"nvim-fugitive.editor".request(<id>, <file>)'`) and then blocks
     waiting on `<state>.done` or `<state>.abort`.
  2. Neovim opens `<file>` in a buffer (commit/rebase-todo filetype) in the
     configured window style, in the foreground, even if the command came from an
     overseer task or the float route.
  3. `:w` + close the buffer (`:wq`, `:x`, `ZZ`) → write `.done` → shim exits 0 →
     git continues.
  4. Close without writing, `:q!`, `bwipeout`, or `:cq` → write `.abort` → shim
     exits 1 → git aborts the operation ("there was a problem with the editor"),
     e.g. a commit is not created and a rebase does not start.
  5. **Cancellation of the git process** (overseer stop, `<C-c>` in the float, job
     killed, Neovim exit): we write `.abort`, kill the process group, and close the
     editor buffer with a notification. On `VimLeavePre`, all pending editors are aborted
     so no shim is left waiting forever.
  6. **Background / non-interactive** (`:Git!`, headless tests without `$NVIM`):
     the shim exits 1 immediately with "fugitive: aborting edit due to background
     operation" (upstream behaviour). The command fails loudly instead of hanging.
  7. One editor request at a time per repo. Concurrent requests are queued.
- **Tests** (integration, real git): `commit` (save → commit exists; `:q!` →
  no commit), `rebase -i` (edit todo to `drop` a commit → history changes;
  abort → unchanged), `pull` from a fixture remote that requires a merge commit
  (runs as task with the overseer stub *and* the fallback runner; editor appears;
  save → merge commit exists), cancellation mid-edit (process killed, buffer closed,
  repo unchanged), and the `:Git!` background abort.

### 5.2.2 Long-running commands → overseer.nvim
- Network/slow subcommands (`pull fetch push clone submodule update
  lfs …`, configurable list) run as overseer tasks: visible in the task list,
  cancellable, with output in the task buffer and the result notified on completion.
- Fallback when overseer is absent: our own async job + a `vim.notify` progress
  message and a completion message.
- After completion: refresh the summary buffer and gitsigns.

### 5.3 Pickers / telescope
- Telescope when installed, `vim.ui.select` fallback for the simple pickers.
- Wanted areas: log/commits, branches/refs/stash, blame/file history.
- Commands may *take input from* a picker (e.g. `:Git checkout` with no ref)
  or *show output in* one.

#### 5.3.1 Pickers (`:Telescope fugitive <name>`)

| Picker | Entries | Preview | `<CR>` | Extra actions |
|--------|---------|---------|--------|---------------|
| `log` | `git log` entries: hash, date, author, subject, ref decorations | `git show --stat -p` | open commit as `fugitive://` buffer | diff current file vs commit (`:Gdiffsplit`); checkout (detached) / revert / cherry-pick; yank short/full SHA; `:GBrowse` |
| `refs` | local + remote branches, tags; sorted by most recent commit | `git log --oneline --graph` of ref vs HEAD (ahead/behind) | checkout (remote → create tracking branch) | merge into HEAD; rebase HEAD onto; diff vs ref (changed files → picker/quickfix) |
| `stash` | `git stash list` | `git stash show -p --include-untracked` | apply | pop; drop (with confirm); `stash branch`; open as commit buffer |

Deferred: file-history picker, line-range (`log -L`) picker, blame-line picker.

#### 5.3.2 Commands that use pickers
- Input: the picker opens **only for the exact bare forms** `:Git checkout`,
  `:Git switch`, `:Git merge` and `:Git rebase` (no arguments at all), plus an explicit,
  documented allow-list of flag-only forms (initially: `rebase -i` → pick the
  base, `switch -c`/`checkout -b` → pick the start point). The selection is
  appended as the ref (`vim.ui.select` fallback).
  **Every other invocation passes through unchanged**, e.g. `rebase --continue`,
  `rebase --abort`, `merge --abort`, `checkout -- file` and `switch -`.
  Unit tests cover the trigger predicate for both lists.
- Output: **`:Ggrep` is telescope-first**. With telescope installed it opens a
  picker over the `git grep` results, and telescope's own `<C-q>` sends them to
  quickfix. Without telescope it falls back to quickfix (upstream behaviour);
  `:Glgrep` → loclist. This deliberately deviates from upstream, where `:Ggrep` always
  fills quickfix. `:Gclog` has low priority because the user never uses it.

### 5.4 :GBrowse providers
- Built-in Lua URL builders: GitHub, GitLab, Bitbucket, Codeberg/Gitea/Forgejo,
  sourcehut. Users can register custom hosts (e.g. self-hosted GitLab) through
  `setup({ browse = { hosts = { ["git.corp"] = "gitlab" }, providers = {…} } })`.
- **Compatibility**: also call existing `g:fugitive_browse_handlers` (vim-rhubarb,
  fugitive-gitlab, …), each with a *copy* of exactly the dict upstream's
  `fugitive#BrowseCommand` builds (`autoload/fugitive.vim` ~L7669):

  | Key | Value |
  |-----|-------|
  | `git_dir` | the repo's git dir (string) |
  | `repo` | **dict** `{ 'git_dir': git_dir }` (not a string) |
  | `remote` | the remote URL (from `remote.<name>.url`, including `insteadOf` rewriting), or the raw argument if it contained `:` |
  | `remote_name` | the remote name as given or resolved (e.g. `origin`) |
  | `commit` | resolved full SHA, **URL-encoded** |
  | `path` | repo-relative path, URL-encoded, then `%20` turned back into a space |
  | `type` | `blob` / `tree` / `commit` / `ref` / `root` / … |
  | `line1`, `line2` | numbers (0 when there is no range) |

  Special cases are preserved too: a ref with no path → `path = '.git/' . encoded ref`
  and `type = ''`; root → `path = '.git/index'`, `type = ''`; a tree path gets a trailing `/`.
  The URL encoding replicates upstream's `s:UrlEncode`.
  A handler result is accepted only if it is a string containing `://`. The first one wins.
  Vim handlers run before the built-ins so user plugins can override.
- **Test**: register a Vimscript handler that stores its argument, run
  `:GBrowse` for blob, line range, tree, commit, ref and root cases (including
  paths with spaces and `#`/`%`), and assert the received dict field-for-field
  against values captured from upstream fugitive by the parity harness.
- Opens with `vim.ui.open`. `:GBrowse!` yanks the URL instead (upstream behaviour).

### 5.5 gitsigns
- Optional accelerator. When present: reuse its hunk data for work-tree
  stage/reset hunk and `]c`/`[c`, and call its refresh after our mutating ops.
  When absent: work-tree hunk maps/commands are **unavailable** and say so via
  `vim.notify` ("requires gitsigns.nvim"). Staging still works fully from the
  summary buffer (inline diffs + visual `s`). Our own work-tree hunk staging is in
  the backlog.

## 6. Architecture (proposal)

```
plugin/fugitive.lua          -- commands, autocmds (BufReadCmd fugitive://*), lazy entry
lua/nvim-fugitive/
  init.lua                   -- setup(), public Lua API
  config.lua                 -- defaults, validation, merge; keymap tables
  git/
    exec.lua                 -- plenary.Job/vim.system wrapper: async (coroutine) + sync
    repo.lua                 -- detection & caching: worktree, common dir, submodule, symlinks
    status.lua               -- `status --porcelain=v2 -z --branch --show-stash` parser
    diff.lua                 -- unified diff parsing, hunk math, partial-patch building
    log.lua, refs.lua, stash.lua
  object.lua                 -- fugitive:// URL <-> (repo, rev, path) parsing/formatting
  buffers/
    reader.lua               -- BufReadCmd for blobs/trees/commits (read-only MVP)
    summary/                 -- :Git summary: render, sections, maps, inline diffs, folds
    editor.lua               -- editor service: shim, request queue, done/abort (§5.2.1)
    diffsplit.lua            -- :Gdiffsplit family, 3-way conflict layout
  discard.lua                -- save-before-destroy, journal, restore (§4.2)
  conflict.lua               -- marker parsing, ]x/[x, choose ours/theirs/both/none, extmarks
  cmd/
    git.lua                  -- :Git dispatcher: per-subcommand flag table → route; picker trigger
    grep.lua, move.lua, browse.lua, complete.lua
  ui/
    notify.lua               -- vim.notify wrapper (title, max-lines truncation)
    float.lua                -- big pager float
    output.lua               -- full-output ring + :FugitiveOutput (§5.2)
    terminal.lua             -- interactive commands
  watch.lua                  -- vim.uv fs_event on index/HEAD/refs (+common dir), debounce
  integrations/
    telescope/               -- _extensions/fugitive.lua + log/refs/stash pickers
    overseer.lua             -- task template + fallback job runner
    gitsigns.lua             -- detect, refresh, hunk delegation
    browse/                  -- github.lua, gitlab.lua, … + vim-handler bridge
lua/telescope/_extensions/fugitive.lua
syntax/ ftplugin/            -- fugitive (summary), git commit/rebase reuse runtime syntax
doc/fugitive.txt             -- handwritten
tests/{unit,integration,fixtures,parity}/
```

Key principles:
- **One git execution layer** (`git/exec.lua`). Every call goes through it, with
  `--no-optional-locks`, `-c core.quotepath=false`, `GIT_TERMINAL_PROMPT=0` for
  non-interactive calls, and a consistent cwd/`-C`. Testable by injecting a fake runner.
- **Pure parsers separate from UI**, so the unit tests need no buffers.
- **Repo object cached per git dir** and invalidated by the watcher.
- **Integrations are lazy** (`pcall(require, …)` at use time) and never loaded at startup.
- **Events**: emit `User FugitiveChanged` (upstream name) after mutations, so the
  summary, gitsigns and statuslines refresh from one signal.

## 7. Testing strategy

- **Unit (plenary-busted)**: pure modules such as object/URL parsing, the
  porcelain-v2 status parser, diff/hunk math, config merging and the output-routing table.
- **Integration on fixture repos**: every test scripts a throwaway repo in a
  tmpdir (commits, branches, conflicts, stash, upstream remote), drives commands
  and maps in headless nvim, and asserts buffer text and the resulting `git status`.
  Optional integrations are tested both with the plugin present (stubbed) and absent.
- **Upstream parity harness, only at the start**: while the summary buffer and
  maps are being built, run the same scenario against upstream vim-fugitive and
  diff the buffer text and repo state. Drop it once our own integration suite
  covers the behaviour.

### 7.1 CI & tooling
- GitHub Actions matrix: Neovim 0.11 stable + nightly × Linux/macOS; a job
  pinned to git 2.40.
- stylua + selene/luacheck gates.
- LuaCATS annotations everywhere, checked with `lua-language-server --check`.

## 8. Milestones (proposal — awaiting user review)

**M0 — Skeleton**: repo layout, CI matrix, stylua/selene/luals, test harness
(plenary-busted + fixture-repo builder), parity harness against upstream.

**M1 — Core (MVP)**
1. `git/exec`, `repo` (worktrees, symlinks, submodules), `object`, config/setup.
2. `:Git {args}` dispatcher with per-subcommand routing (notify / float / terminal /
   overseer), the editor service on every route, the output ring. Completion.
3. `fugitive://` reader (read-only blobs/trees/commits).
4. Summary buffer (incl. `X` with save-before-destroy + recovery, §4.2): sections (Head/Push/Merge/Rebase, Untracked, Unstaged,
   Staged, Unmerged, Unpushed/Unpulled, Stash), staging + navigation + inline diff +
   commit/revert maps, folding, watcher refresh, submodule entries.
5. `:Gdiffsplit` family (read-only) + 3-way conflict + conflict-marker actions.
6. `:Ggrep` (telescope-first, quickfix fallback), `:GMove/:GRename/:GDelete/:GRemove`, `:GBrowse`.
7. Integrations: notify routing, overseer, gitsigns refresh/delegation.

**M2**: stash, checkout/branch and rebase maps; telescope `log`/`refs`/`stash`
pickers; picker input for `:Git checkout|switch|merge|rebase`.

**Backlog**: blame side window, `:Gedit` family + full object syntax, `:Gread`/
`:Gwrite`/editable index, `:Gclog`, difftool/mergetool, `:Gcd`, `gf`, statusline/
Vimscript API, bisect, push quickfix, submodule maintenance, bare/`$GIT_DIR`,
file-history pickers, `=` on stash entries (F31), configurable output targets
(F32, §5.2.3).
