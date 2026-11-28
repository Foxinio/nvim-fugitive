---@mod nvim-fugitive.buffers.summary.actions.registry Every action of the summary, declared once.
---
---Each entry is one action: its name (what maps.summary binds keys to), a
---one-line description (for g?), what it does (`run`, given a context:
---the buffer and whether a selection is being acted on), and the words its
---key shows in the section hints. An action that only makes sense in some
---sections lists them in `on`, each with its hint word and what it does
---there; elsewhere its key says where it works. The keys themselves are in
---config.lua's presets.

local util = require("nvim-fugitive.buffers.summary.actions.util")
local notify = require("nvim-fugitive.ui.notify")
local object = require("nvim-fugitive.object")
local state = util.state
local has_head = util.has_head
local git = util.git
local cmdline = util.cmdline

local M = {}

---The actions module (staging, navigation, opening, commands).
local A = setmetatable({}, {
  __index = function(_, k)
    return require("nvim-fugitive.buffers.summary.actions")[k]
  end,
})
local function summary()
  return require("nvim-fugitive.buffers.summary")
end

---@class fugitive.ActionCtx
---@field buf integer the summary buffer
---@field visual boolean acting on a visual selection
---@field info? fugitive.LineInfo per-section actions: the item under the cursor
---@field warn? fun() per-section actions: say where the key works

---@class fugitive.SectionEntry
---@field word string the hint's word
---@field run fun(ctx: fugitive.ActionCtx)
---@field fallback? {[1]: string, count?: integer} the upstream action for the hint
---@field hint? false no hint in this section (a key only some of its lines take)

---@class fugitive.RegistryEntry
---@field name string
---@field desc string
---@field run? fun(ctx: fugitive.ActionCtx)
---@field hint? table<string, {[1]: string, [2]: integer}> section -> { word, position }
---@field on? table<string, fugitive.SectionEntry> per-section action: where it works

---Actions that also work on a visual selection.
local visual = setmetatable({}, { __mode = "k" })

---`fn(buf, visual)`, in normal and visual mode.
local function nx(fn)
  local run = function(ctx)
    fn(ctx.buf, ctx.visual)
  end
  visual[run] = true
  return run
end

---`fn(buf, ...)`.
local function n(fn, ...)
  local extra = { ... }
  return function(ctx)
    fn(ctx.buf, unpack(extra))
  end
end

---`git {args}` in the background of the summary.
local function run(args, mods)
  return function(ctx)
    git(ctx.buf, args, { mods = mods })
  end
end

---`fn(commit, buf)` on the commit under the cursor; elsewhere a warning.
local function on_commit(fn)
  return function(ctx)
    local c = A.cursor_commit(ctx.buf)
    if not c then
      notify.warn("no commit under the cursor")
      return
    end
    fn(c, ctx.buf)
  end
end

---`:Git {args}`, run as it is (no command line typed).
local function git_cmd(args)
  return function(ctx)
    require("nvim-fugitive.cmd.git").run(vim.deepcopy(args), { buf = ctx.buf })
  end
end

---The prompt of cF/cS: commit, then an autosquash rebase from the parent.
local function fixup_then_rebase(buf, flag)
  local c = A.cursor_commit(buf)
  local text = "Git commit "
    .. flag
    .. (c or "")
    .. " | Git -c sequence.editor=true rebase --interactive --autosquash"
  return c and (text .. " " .. c .. "^") or text
end

local function count_ref()
  return "stash@{" .. vim.v.count .. "}"
end

-- helpers of the per-section actions

local function choose(choice)
  return function(ctx)
    A.choose(ctx.buf, choice)
  end
end

---Another action, as it is.
local function call(name)
  return function(ctx)
    M.get(name).run(ctx)
  end
end

---On a file line: only for a submodule.
local function on_submodule(name)
  return function(ctx)
    if ctx.info.entry and ctx.info.entry.submodule then
      return M.get(name).run(ctx)
    end
    ctx.warn()
  end
end

---`git stash <verb>` on the stash under the cursor.
local function stash(args)
  return function(ctx)
    git(ctx.buf, vim.list_extend(vim.deepcopy(args), { ctx.info.ref }))
  end
end

local function stash_view(ctx)
  local url = object.resolve(state(ctx.buf).repo, ctx.info.ref)
  if url then
    require("nvim-fugitive.buffers.reader").open(url, "edit")
  end
end

local function retodo(word)
  return function(ctx)
    A.rebase_retodo(ctx.buf, word)
  end
end

---Every action, in the order their hints show within a section.
---@type fugitive.RegistryEntry[]
M.list = {
  {
    name = "stage",
    desc = "Stage the file, directory, section or hunk (on an unmerged file: mark it resolved)",
    hint = { Untracked = { "stage", 1 }, Unstaged = { "stage", 1 }, Unmerged = { "resolved", 2 } },
    run = nx(A.stage),
  },
  {
    name = "unstage",
    desc = "Unstage the file, directory, section or hunk",
    hint = { Staged = { "unstage", 1 } },
    run = nx(A.unstage),
  },
  {
    name = "toggle",
    desc = "Stage or unstage, whichever applies",
    run = nx(A.toggle),
  },
  {
    name = "unstage_all",
    desc = "Unstage everything",
    run = function(ctx)
      local buf = ctx.buf
      local st = state(buf)
      A.run_chain(st.repo, {
        {
          args = has_head(st) and { "reset", "-q" } or { "rm", "--cached", "-r", "-q", "--", "." },
        },
      })
    end,
  },
  {
    name = "discard",
    desc = "Discard the change (saved first; 2X / 3X take ours / theirs)",
    hint = { Untracked = { "delete", 3 }, Unstaged = { "discard", 3 } },
    run = nx(A.discard),
  },
  {
    name = "restore_discard",
    desc = "Restore the latest discard (with a count, pick one)",
    run = n(A.restore_discard),
  },
  {
    name = "inline_toggle",
    desc = "Toggle the inline diff, directory or listing",
    run = nx(function(b, v)
      A.inline(b, "toggle", v)
    end),
  },
  {
    name = "inline_show",
    desc = "Show the inline diff, directory or listing",
    run = nx(function(b, v)
      A.inline(b, "show", v)
    end),
  },
  {
    name = "inline_hide",
    desc = "Hide the inline diff, directory or listing",
    run = nx(function(b, v)
      A.inline(b, "hide", v)
    end),
  },
  {
    name = "fold_dir",
    desc = "Fold the directory around the cursor, or close the diff",
    run = nx(A.fold_dir),
  },
  {
    name = "patch",
    desc = "Stage or unstage interactively (add --patch / reset --patch)",
    run = nx(A.patch),
  },
  {
    name = "ignore",
    desc = "Add the path to .git/info/exclude (with a count, .gitignore)",
    hint = { Untracked = { "ignore", 2 } },
    run = nx(A.ignore),
  },
  {
    name = "open_exclude",
    desc = "Open .git/info/exclude (with a count, .gitignore)",
    run = n(A.open_exclude),
  },
  {
    name = "open",
    desc = "Open the file, commit or stash",
    run = n(A.open, "edit"),
  },
  {
    name = "open_split",
    desc = "Open in a split",
    run = n(A.open, "split"),
  },
  {
    name = "open_vsplit",
    desc = "Open in a vertical split",
    run = n(A.open, "vsplit"),
  },
  {
    name = "open_tab",
    desc = "Open in a tab",
    run = n(A.open, "tab"),
  },
  {
    name = "open_preview",
    desc = "Open in the preview window",
    run = n(A.open, "pedit"),
  },
  {
    name = "open_float",
    desc = "Open in a float",
    run = n(A.open, "float"),
  },
  {
    name = "prev_item",
    desc = "Previous file, directory, hunk or commit",
    run = n(A.prev_item),
  },
  {
    name = "next_item",
    desc = "Next file, directory, hunk or commit",
    run = n(A.next_item),
  },
  {
    name = "prev_hunk",
    desc = "Previous hunk",
    run = n(A.next_hunk, -1),
  },
  {
    name = "next_hunk",
    desc = "Next hunk (opening the file's diff)",
    run = n(A.next_hunk, 1),
  },
  {
    name = "next_expanded_hunk",
    desc = "Next file or hunk, opening diffs on the way",
    run = n(A.next_expanded_hunk),
  },
  {
    name = "prev_file",
    desc = "Previous file",
    run = n(A.prev_file),
  },
  {
    name = "next_file",
    desc = "Next file",
    run = n(A.next_file),
  },
  {
    name = "prev_section",
    desc = "Previous section",
    run = n(A.prev_section),
  },
  {
    name = "next_section",
    desc = "Next section",
    run = n(A.next_section),
  },
  {
    name = "prev_section_end",
    desc = "End of the previous section",
    run = n(A.prev_section_end),
  },
  {
    name = "next_section_end",
    desc = "End of the next section",
    run = n(A.next_section_end),
  },
  {
    name = "jump_untracked",
    desc = "Jump to Untracked",
    run = n(A.stage_jump, { "Untracked", "Unstaged" }),
  },
  {
    name = "jump_unstaged",
    desc = "Jump to Unstaged",
    run = n(A.stage_jump, { "Unstaged", "Untracked" }),
  },
  {
    name = "jump_staged",
    desc = "Jump to Staged",
    run = n(A.stage_jump, { "Staged" }),
  },
  {
    name = "jump_unpushed",
    desc = "Jump to Unpushed (again: the next Unpushed section)",
    run = n(A.stage_jump, { "Unpushed" }),
  },
  {
    name = "jump_unpulled",
    desc = "Jump to Unpulled (again: the next Unpulled section)",
    run = n(A.stage_jump, { "Unpulled" }),
  },
  {
    name = "jump_rebasing",
    desc = "Jump to Rebasing",
    run = n(A.stage_jump, { "Rebasing" }),
  },
  {
    name = "close",
    desc = "Close the summary",
    run = function()
      local listed = vim.fn.getbufinfo({ buflisted = 1 })
      if #vim.api.nvim_list_wins() == 1 and #listed <= 1 then
        vim.cmd("quit")
      elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(0, false)
      else
        vim.cmd("bdelete")
      end
    end,
  },
  {
    name = "help",
    desc = "This help",
    run = function()
      summary().show_help("summary")
    end,
  },
  {
    name = "reload",
    desc = "Reload the summary",
    run = function(ctx)
      local buf = ctx.buf
      local st = state(buf)
      summary().load(buf, st.repo)
    end,
  },
  {
    name = "cmdline",
    desc = "Start a command line with the path, commit or stash under the cursor",
    run = function(ctx)
      local buf = ctx.buf
      local st = state(buf)
      local i = st.info[vim.fn.line(".")]
      local word = ""
      if i and i.entry then
        word = vim.fn.fnameescape(i.entry.path)
      elseif i and i.commit then
        word = i.commit
      elseif i and i.ref then
        word = i.ref
      end
      cmdline(" " .. word, true)
    end,
  },
  {
    name = "diff",
    desc = "Diff the file against the index or HEAD",
    run = n(A.diff, "auto"),
  },
  {
    name = "diff_vertical",
    desc = "Diff in a vertical split (three-way for an unmerged file)",
    hint = { Unstaged = { "diff", 2 }, Unmerged = { "3-way diff", 1 } },
    run = n(A.diff, "vertical"),
  },
  {
    name = "diff_horizontal",
    desc = "Diff in a horizontal split",
    run = n(A.diff, "horizontal"),
  },
  {
    name = "diff_close",
    desc = "Close the diff windows",
    run = function()
      require("nvim-fugitive.buffers.diffsplit").close()
    end,
  },
  {
    name = "diff_patch",
    desc = "Diff the file, directory or section in a patch buffer",
    run = n(A.diff_patch),
  },
  {
    name = "commit",
    desc = "Commit",
    hint = { Staged = { "commit", 2 } },
    run = run({ "commit" }),
  },
  {
    name = "commit_amend",
    desc = "Amend the last commit",
    hint = { Staged = { "amend", 3 } },
    run = run({ "commit", "--amend" }),
  },
  {
    name = "commit_extend",
    desc = "Amend the last commit without editing the message",
    run = run({ "commit", "--amend", "--no-edit" }),
  },
  {
    name = "commit_reword",
    desc = "Reword the last commit",
    run = run({ "commit", "--amend", "--only" }),
  },
  {
    name = "commit_verbose",
    desc = "Commit with the diff in the message buffer",
    run = run({ "commit", "-v" }, "tab"),
  },
  {
    name = "commit_amend_verbose",
    desc = "Amend with the diff in the message buffer",
    run = run({ "commit", "-v", "--amend" }, "tab"),
  },
  {
    name = "commit_reset_author",
    desc = "Amend, resetting the author",
    run = run({ "commit", "--reset-author", "--amend" }),
  },
  {
    name = "commit_reset_author_extend",
    desc = "Amend without editing, resetting the author",
    run = run({ "commit", "--reset-author", "--amend", "--no-edit" }),
  },
  {
    name = "commit_reset_author_reword",
    desc = "Reword, resetting the author",
    run = run({ "commit", "--reset-author", "--amend", "--only" }),
  },
  {
    name = "commit_fixup",
    desc = "Prompt: commit --fixup of the commit under the cursor",
    run = function(ctx)
      local buf = ctx.buf
      cmdline("Git commit --fixup=" .. (A.cursor_commit(buf) or ""))
    end,
  },
  {
    name = "commit_fixup_rebase",
    desc = "Commit --fixup, then autosquash rebase",
    run = function(ctx)
      local buf = ctx.buf
      cmdline(fixup_then_rebase(buf, "--fixup="))
    end,
  },
  {
    name = "commit_squash",
    desc = "Prompt: commit --squash of the commit under the cursor",
    run = function(ctx)
      local buf = ctx.buf
      cmdline("Git commit --no-edit --squash=" .. (A.cursor_commit(buf) or ""))
    end,
  },
  {
    name = "commit_squash_rebase",
    desc = "Commit --squash, then autosquash rebase",
    run = function(ctx)
      local buf = ctx.buf
      cmdline(fixup_then_rebase(buf, "--no-edit --squash="))
    end,
  },
  {
    name = "commit_squash_edit",
    desc = "Prompt: commit --squash, editing the message",
    run = function(ctx)
      local buf = ctx.buf
      cmdline("Git commit --edit --squash=" .. (A.cursor_commit(buf) or ""))
    end,
  },
  {
    name = "commit_prompt",
    desc = "Prompt: :Git commit",
    run = function()
      cmdline("Git commit ")
    end,
  },
  {
    name = "commit_verbose_prompt",
    desc = "Prompt: :Git commit -v in a tab",
    run = function()
      cmdline("tab Git commit -v ")
    end,
  },
  {
    name = "revert",
    desc = "Revert the commit under the cursor",
    run = on_commit(function(c, buf)
      git(buf, { "revert", c })
    end),
  },
  {
    name = "revert_no_commit",
    desc = "Revert the commit under the cursor without committing",
    run = on_commit(function(c, buf)
      git(buf, { "revert", "--no-commit", c })
    end),
  },
  {
    name = "revert_prompt",
    desc = "Prompt: :Git revert",
    run = function()
      cmdline("Git revert ")
    end,
  },
  {
    name = "revert_bare",
    desc = "Run :Git revert",
    run = git_cmd({ "revert" }),
  },
  {
    name = "merge_prompt",
    desc = "Prompt: :Git merge",
    run = function()
      cmdline("Git merge ")
    end,
  },
  {
    name = "merge_bare",
    desc = "Run :Git merge",
    run = git_cmd({ "merge" }),
  },
  {
    name = "checkout",
    desc = "Check out the commit under the cursor",
    run = on_commit(function(c, buf)
      git(buf, { "checkout", c, "--" })
    end),
  },
  {
    name = "checkout_prompt",
    desc = "Prompt: :Git checkout",
    run = function()
      cmdline("Git checkout ")
    end,
  },
  {
    name = "checkout_bare",
    desc = "Run :Git checkout",
    run = git_cmd({ "checkout" }),
  },
  {
    name = "branch_prompt",
    desc = "Prompt: :Git branch",
    run = function()
      cmdline("Git branch ")
    end,
  },
  {
    name = "branch_bare",
    desc = "Run :Git branch",
    run = git_cmd({ "branch" }),
  },
  {
    name = "stash_push",
    desc = "Stash (count 1: with untracked, 2: with ignored)",
    run = function(ctx)
      local buf = ctx.buf
      local extra = vim.v.count > 1 and { "--all" }
        or vim.v.count > 0 and { "--include-untracked" }
        or {}
      git(buf, vim.list_extend({ "stash", "push" }, extra))
    end,
  },
  {
    name = "stash_push_keep_index",
    desc = "Stash, keeping the index",
    run = function(ctx)
      local buf = ctx.buf
      local extra = vim.v.count > 1 and { "--all" }
        or vim.v.count > 0 and { "--include-untracked" }
        or {}
      git(buf, vim.list_extend({ "stash", "push", "--keep-index" }, extra))
    end,
  },
  {
    name = "stash_push_staged",
    desc = "Stash only what is staged",
    run = run({ "stash", "push", "--staged" }),
  },
  {
    name = "stash_apply_index",
    desc = "Apply stash@{count} with its index",
    run = function(ctx)
      local buf = ctx.buf
      git(buf, { "stash", "apply", "--quiet", "--index", count_ref() })
    end,
  },
  {
    name = "stash_apply",
    desc = "Apply stash@{count}",
    run = function(ctx)
      local buf = ctx.buf
      git(buf, { "stash", "apply", "--quiet", count_ref() })
    end,
  },
  {
    name = "stash_pop_index",
    desc = "Pop stash@{count} with its index",
    run = function(ctx)
      local buf = ctx.buf
      git(buf, { "stash", "pop", "--quiet", "--index", count_ref() })
    end,
  },
  {
    name = "stash_pop",
    desc = "Pop stash@{count}",
    run = function(ctx)
      local buf = ctx.buf
      git(buf, { "stash", "pop", "--quiet", count_ref() })
    end,
  },
  {
    name = "stash_view",
    desc = "Open stash@{count} as a commit",
    run = function(ctx)
      local buf = ctx.buf
      local st = state(buf)
      local url = object.resolve(st.repo, count_ref())
      if not url then
        notify.error("no stash " .. count_ref())
        return
      end
      require("nvim-fugitive.buffers.reader").open(url, "edit")
    end,
  },
  {
    name = "stash_prompt",
    desc = "Prompt: :Git stash",
    run = function()
      cmdline("Git stash ")
    end,
  },
  {
    name = "stash_bare",
    desc = "Run :Git stash",
    run = git_cmd({ "stash" }),
  },
  {
    name = "rebase_interactive",
    desc = "Interactive rebase from the commit under the cursor (or the upstream)",
    hint = { Unpushed = { "rebase", 1 } },
    run = function(ctx)
      local buf = ctx.buf
      git(buf, vim.list_extend({ "rebase", "--interactive" }, A.rebase_base(buf)))
    end,
  },
  {
    name = "rebase_autosquash",
    desc = "Autosquash rebase, without the editor",
    run = function(ctx)
      local buf = ctx.buf
      git(
        buf,
        vim.list_extend(
          { "-c", "sequence.editor=true", "rebase", "--interactive", "--autosquash" },
          A.rebase_base(buf)
        )
      )
    end,
  },
  {
    name = "rebase_upstream",
    desc = "Interactive rebase onto @{upstream}",
    hint = { Unpulled = { "rebase", 1 } },
    run = run({ "rebase", "--interactive", "@{upstream}" }),
  },
  {
    name = "rebase_push",
    desc = "Interactive rebase onto @{push}",
    run = run({ "rebase", "--interactive", "@{push}" }),
  },
  {
    name = "rebase_continue",
    desc = "rebase --continue",
    hint = { Rebasing = { "continue", 1 }, Sequencing = { "continue", 1 } },
    run = run({ "rebase", "--continue" }),
  },
  {
    name = "rebase_skip",
    desc = "rebase --skip",
    hint = { Rebasing = { "skip", 2 }, Sequencing = { "skip", 2 } },
    run = run({ "rebase", "--skip" }),
  },
  {
    name = "rebase_abort",
    desc = "rebase --abort",
    hint = { Rebasing = { "abort", 3 }, Sequencing = { "abort", 3 } },
    run = run({ "rebase", "--abort" }),
  },
  {
    name = "rebase_edit_todo",
    desc = "rebase --edit-todo",
    run = run({ "rebase", "--edit-todo" }),
  },
  {
    name = "rebase_reword",
    desc = "Rebase with the first commit set to reword",
    run = function(ctx)
      local buf = ctx.buf
      A.rebase_retodo(buf, "reword")
    end,
  },
  {
    name = "rebase_edit",
    desc = "Rebase with the first commit set to edit",
    run = function(ctx)
      local buf = ctx.buf
      A.rebase_retodo(buf, "edit")
    end,
  },
  {
    name = "rebase_drop",
    desc = "Rebase with the first commit set to drop",
    run = function(ctx)
      local buf = ctx.buf
      A.rebase_retodo(buf, "drop")
    end,
  },
  {
    name = "rebase_prompt",
    desc = "Prompt: :Git rebase",
    run = function()
      cmdline("Git rebase ")
    end,
  },
  {
    name = "rebase_bare",
    desc = "Run :Git rebase",
    run = git_cmd({ "rebase" }),
  },
  {
    name = "submodule_update",
    desc = "git submodule update --init (the one under the cursor, or all)",
    run = function(ctx)
      local buf = ctx.buf
      git(buf, vim.list_extend({ "submodule", "update", "--init" }, A.cursor_submodule(buf)))
    end,
  },
  {
    name = "submodule_update_recursive",
    desc = "The same, with --recursive",
    run = function(ctx)
      local buf = ctx.buf
      git(
        buf,
        vim.list_extend({ "submodule", "update", "--init", "--recursive" }, A.cursor_submodule(buf))
      )
    end,
  },
  {
    name = "bisect_good",
    desc = "git bisect good (the commit under the cursor, or HEAD)",
    hint = { Bisecting = { "good", 1 } },
    run = function(ctx)
      local buf = ctx.buf
      git(buf, { "bisect", "good", A.cursor_commit(buf) })
    end,
  },
  {
    name = "bisect_bad",
    desc = "git bisect bad",
    hint = { Bisecting = { "bad", 2 } },
    run = function(ctx)
      local buf = ctx.buf
      git(buf, { "bisect", "bad", A.cursor_commit(buf) })
    end,
  },
  {
    name = "bisect_skip",
    desc = "git bisect skip",
    run = function(ctx)
      local buf = ctx.buf
      git(buf, { "bisect", "skip", A.cursor_commit(buf) })
    end,
  },
  {
    name = "bisect_reset",
    desc = "git bisect reset",
    hint = { Bisecting = { "reset", 3 } },
    run = run({ "bisect", "reset" }),
  },
  {
    name = "choose_ours",
    desc = "Take ours (unmerged file), or check out the commit (Unpushed, Unpulled)",
    on = {
      Unmerged = { word = "ours", run = choose("ours"), fallback = { "discard", count = 2 } },
      Unpushed = { word = "checkout", run = call("checkout"), fallback = { "checkout" } },
      Unpulled = { word = "checkout", run = call("checkout"), fallback = { "checkout" } },
    },
  },
  {
    name = "choose_theirs",
    desc = "Take theirs for the unmerged file",
    on = {
      Unmerged = { word = "theirs", run = choose("theirs"), fallback = { "discard", count = 3 } },
    },
  },
  {
    name = "choose_both",
    desc = "Keep both sides of every conflict block of the unmerged file",
    on = { Unmerged = { word = "both", run = choose("both") } },
  },
  {
    name = "choose_none",
    desc = "Keep neither side of every conflict block of the unmerged file",
    on = { Unmerged = { word = "neither", run = choose("none") } },
  },
  {
    name = "submodule_init",
    desc = "Initialise the submodule under the cursor",
    on = {
      Uninitialized = {
        word = "init",
        run = call("submodule_update"),
        fallback = { "submodule_update" },
      },
      Unstaged = { word = "init", run = on_submodule("submodule_update"), hint = false },
      Staged = { word = "init", run = on_submodule("submodule_update"), hint = false },
    },
  },
  {
    name = "submodule_init_recursive",
    desc = "Initialise the submodule under the cursor, recursively",
    on = {
      Uninitialized = {
        word = "recursive",
        run = call("submodule_update_recursive"),
        fallback = { "submodule_update_recursive" },
      },
      Unstaged = {
        word = "recursive",
        run = on_submodule("submodule_update_recursive"),
        hint = false,
      },
      Staged = {
        word = "recursive",
        run = on_submodule("submodule_update_recursive"),
        hint = false,
      },
    },
  },
  {
    name = "rebase_reword_line",
    desc = "Rebase from the Unpushed commit under the cursor, set to reword",
    on = {
      Unpushed = { word = "reword", run = retodo("reword"), fallback = { "rebase_reword" } },
    },
  },
  {
    name = "rebase_drop_line",
    desc = "Rebase from the Unpushed commit under the cursor, set to drop",
    on = {
      Unpushed = { word = "drop", run = retodo("drop"), fallback = { "rebase_drop" } },
    },
  },
  {
    name = "rebase_edit_line",
    desc = "Rebase from the Unpushed commit under the cursor, set to edit",
    on = {
      Unpushed = { word = "edit", run = retodo("edit"), fallback = { "rebase_edit" } },
    },
  },
  {
    name = "stash_pop_line",
    desc = "Pop the stash under the cursor, with its index",
    on = {
      Stash = {
        word = "pop",
        run = stash({ "stash", "pop", "--quiet", "--index" }),
        fallback = { "stash_pop_index" },
      },
    },
  },
  {
    name = "stash_apply_line",
    desc = "Apply the stash under the cursor, with its index",
    on = {
      Stash = {
        word = "apply",
        run = stash({ "stash", "apply", "--quiet", "--index" }),
        fallback = { "stash_apply_index" },
      },
    },
  },
  {
    name = "stash_view_line",
    desc = "Open the stash under the cursor as a commit",
    on = { Stash = { word = "view", run = stash_view, fallback = { "stash_view" } } },
  },
}

local by_name = {}
for _, e in ipairs(M.list) do
  by_name[e.name] = e
end

---@param name string
---@return fugitive.RegistryEntry?
function M.get(name)
  return by_name[name]
end

---The order sections are listed in, and how a warning names each.
M.order = {
  "Unmerged",
  "Untracked",
  "Unstaged",
  "Staged",
  "Uninitialized",
  "Rebasing",
  "Unpushed",
  "Unpulled",
  "Stash",
}
M.what = {
  Untracked = "Untracked files",
  Unstaged = "Unstaged files",
  Staged = "Staged files",
  Unmerged = "Unmerged files",
  Uninitialized = "submodules",
  Rebasing = "Rebasing commits",
  Unpushed = "Unpushed commits",
  Unpulled = "Unpulled commits",
  Stash = "stashes",
}

---The key bound to `name` (the shortest), or the name itself.
function M.key_of(name)
  local key
  for lhs, action in pairs(require("nvim-fugitive.config").get().maps.summary or {}) do
    if action == name and (not key or #lhs < #key) then
      key = lhs
    end
  end
  return key or name
end

---What a per-section action does: the entry for the cursor line's section,
---or else a warning naming where it works.
local function dispatch(entry)
  local function warn()
    local where = {}
    for _, s in ipairs(M.order) do
      if entry.on[s] then
        table.insert(where, M.what[s] or s)
      end
    end
    notify.warn(string.format("%s: works on %s", M.key_of(entry.name), table.concat(where, ", ")))
  end
  return function(ctx)
    local st = state(ctx.buf)
    local info =
      require("nvim-fugitive.buffers.summary.items").at(st, vim.api.nvim_win_get_cursor(0)[1])
    local e = info and entry.on[info.section]
    if not e then
      return warn()
    end
    e.run(vim.tbl_extend("force", ctx, { info = info, warn = warn }))
  end
end

---What the gf-style actions do (they come from maps.cfile_actions, shared
---with the object buffers).
M.cfile_desc = {
  cfile_edit = "Open the file or object under the cursor",
  cfile_split = "The same, in a split",
  cfile_tab = "The same, in a tab",
}

---The summary's actions for maps.apply: name -> function, or { n, x } for
---the ones that also take a selection.
---@param buf integer
---@return table<string, fugitive.Action>
function M.actions_for(buf)
  local out = {}
  for _, e in ipairs(M.list) do
    local fn = e.on and dispatch(e) or e.run
    if fn then
      local function call_in(v)
        return function()
          fn({ buf = buf, visual = v })
        end
      end
      out[e.name] = visual[fn] and { n = call_in(false), x = call_in(true) } or call_in(false)
    end
  end
  for name, fn in pairs(require("nvim-fugitive.maps").cfile_actions(buf)) do
    out[name] = fn
  end
  return out
end

return M
