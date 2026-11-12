---@mod nvim-fugitive.buffers.summary.actions Summary buffer actions (F6–F11, F30).
---
---The map table; the actions themselves live in the modules next to this one
---(staging, navigation, opening, commands), and are all reachable from here.

local object = require("nvim-fugitive.object")
local notify = require("nvim-fugitive.ui.notify")
local util = require("nvim-fugitive.buffers.summary.actions.util")
local summary = util.summary
local state = util.state
local has_head = util.has_head
local git = util.git
local cmdline = util.cmdline
local split_words = util.split_words

local M = {}
for _, part in ipairs({ "stage", "navigate", "open", "commands" }) do
  for k, v in pairs(require("nvim-fugitive.buffers.summary.actions." .. part)) do
    M[k] = v
  end
end
---@param buf integer
---@return table<string, fugitive.Action>
function M.actions(buf)
  local function nx(fn)
    return {
      n = function()
        fn(buf, false)
      end,
      x = function()
        fn(buf, true)
      end,
    }
  end
  local function n(fn, ...)
    local extra = { ... }
    return function()
      fn(buf, unpack(extra))
    end
  end
  local function run(args, mods)
    return function()
      git(buf, args, { mods = mods })
    end
  end
  local function count_ref()
    return "stash@{" .. vim.v.count .. "}"
  end
  local a = {
    stage = nx(M.stage),
    unstage = nx(M.unstage),
    toggle = nx(M.toggle),
    unstage_all = function()
      local st = state(buf)
      M.run_chain(st.repo, {
        {
          args = has_head(st) and { "reset", "-q" } or { "rm", "--cached", "-r", "-q", "--", "." },
        },
      })
    end,
    discard = nx(M.discard),
    restore_discard = n(M.restore_discard),
    inline_toggle = nx(function(b, v)
      M.inline(b, "toggle", v)
    end),
    inline_show = nx(function(b, v)
      M.inline(b, "show", v)
    end),
    inline_hide = nx(function(b, v)
      M.inline(b, "hide", v)
    end),
    patch = nx(M.patch),
    ignore = nx(M.ignore),
    open_exclude = n(M.open_exclude),
    open = n(M.open, "edit"),
    open_split = n(M.open, "split"),
    open_vsplit = n(M.open, "vsplit"),
    open_tab = n(M.open, "tab"),
    open_preview = n(M.open, "pedit"),
    open_float = n(M.open, "float"),
    prev_item = n(M.prev_item),
    next_item = n(M.next_item),
    prev_hunk = n(M.next_hunk, -1),
    next_hunk = n(M.next_hunk, 1),
    next_expanded_hunk = n(M.next_expanded_hunk),
    prev_file = n(M.prev_file),
    next_file = n(M.next_file),
    prev_section = n(M.prev_section),
    next_section = n(M.next_section),
    prev_section_end = n(M.prev_section_end),
    next_section_end = n(M.next_section_end),
    jump_untracked = n(M.stage_jump, { "Untracked", "Unstaged" }),
    jump_unstaged = n(M.stage_jump, { "Unstaged", "Untracked" }),
    jump_staged = n(M.stage_jump, { "Staged" }),
    jump_unpushed = n(M.stage_jump, { "Unpushed" }),
    jump_unpulled = n(M.stage_jump, { "Unpulled" }),
    jump_rebasing = n(M.stage_jump, { "Rebasing" }),
    close = function()
      local listed = vim.fn.getbufinfo({ buflisted = 1 })
      if #vim.api.nvim_list_wins() == 1 and #listed <= 1 then
        vim.cmd("quit")
      elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(0, false)
      else
        vim.cmd("bdelete")
      end
    end,
    help = function()
      summary().show_help("summary")
    end,
    reload = function()
      local st = state(buf)
      summary().load(buf, st.repo)
    end,
    cmdline = function()
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
    diff = n(M.diff, "auto"),
    diff_vertical = n(M.diff, "vertical"),
    diff_horizontal = n(M.diff, "horizontal"),
    diff_close = function()
      require("nvim-fugitive.buffers.diffsplit").close()
    end,
    diff_patch = n(M.diff_patch),
    -- commit
    commit = run({ "commit" }),
    commit_amend = run({ "commit", "--amend" }),
    commit_extend = run({ "commit", "--amend", "--no-edit" }),
    commit_reword = run({ "commit", "--amend", "--only" }),
    commit_verbose = run({ "commit", "-v" }, "tab"),
    commit_amend_verbose = run({ "commit", "-v", "--amend" }, "tab"),
    commit_reset_author = run({ "commit", "--reset-author", "--amend" }),
    commit_reset_author_extend = run({ "commit", "--reset-author", "--amend", "--no-edit" }),
    commit_reset_author_reword = run({ "commit", "--reset-author", "--amend", "--only" }),
    commit_fixup = function()
      cmdline("Git commit --fixup=" .. M.cursor_commit(buf))
    end,
    commit_fixup_rebase = function()
      local c = M.cursor_commit(buf)
      cmdline(
        "Git commit --fixup="
          .. c
          .. " | Git -c sequence.editor=true rebase --interactive --autosquash"
          .. M.rebase_argument(buf)
      )
    end,
    commit_squash = function()
      cmdline("Git commit --no-edit --squash=" .. M.cursor_commit(buf))
    end,
    commit_squash_rebase = function()
      local c = M.cursor_commit(buf)
      cmdline(
        "Git commit --no-edit --squash="
          .. c
          .. " | Git -c sequence.editor=true rebase --interactive --autosquash"
          .. M.rebase_argument(buf)
      )
    end,
    commit_squash_edit = function()
      cmdline("Git commit --edit --squash=" .. M.cursor_commit(buf))
    end,
    commit_prompt = function()
      cmdline("Git commit ")
    end,
    commit_verbose_prompt = function()
      cmdline("tab Git commit -v ")
    end,
    -- revert / merge
    revert = function()
      git(buf, { "revert", M.cursor_commit(buf) })
    end,
    revert_no_commit = function()
      git(buf, { "revert", "--no-commit", M.cursor_commit(buf) })
    end,
    revert_prompt = function()
      cmdline("Git revert ")
    end,
    revert_bare = function()
      cmdline("Git revert\r")
    end,
    merge_prompt = function()
      cmdline("Git merge ")
    end,
    merge_bare = function()
      cmdline("Git merge\r")
    end,
    -- checkout / branch (M2)
    checkout = function()
      local c = M.cursor_commit(buf)
      if c == "" then
        notify.warn("no commit under the cursor")
        return
      end
      git(buf, { "checkout", c, "--" })
    end,
    checkout_prompt = function()
      cmdline("Git checkout ")
    end,
    checkout_bare = function()
      cmdline("Git checkout\r")
    end,
    branch_prompt = function()
      cmdline("Git branch ")
    end,
    branch_bare = function()
      cmdline("Git branch\r")
    end,
    -- stash (M2)
    stash_push = function()
      local extra = vim.v.count > 1 and { "--all" }
        or vim.v.count > 0 and { "--include-untracked" }
        or {}
      git(buf, vim.list_extend({ "stash", "push" }, extra))
    end,
    stash_push_keep_index = function()
      local extra = vim.v.count > 1 and { "--all" }
        or vim.v.count > 0 and { "--include-untracked" }
        or {}
      git(buf, vim.list_extend({ "stash", "push", "--keep-index" }, extra))
    end,
    stash_push_staged = run({ "stash", "push", "--staged" }),
    stash_apply_index = function()
      git(buf, { "stash", "apply", "--quiet", "--index", count_ref() })
    end,
    stash_apply = function()
      git(buf, { "stash", "apply", "--quiet", count_ref() })
    end,
    stash_pop_index = function()
      git(buf, { "stash", "pop", "--quiet", "--index", count_ref() })
    end,
    stash_pop = function()
      git(buf, { "stash", "pop", "--quiet", count_ref() })
    end,
    stash_view = function()
      local st = state(buf)
      local url = object.resolve(st.repo, count_ref())
      if not url then
        notify.error("no stash " .. count_ref())
        return
      end
      require("nvim-fugitive.buffers.reader").open(url, "edit")
    end,
    stash_prompt = function()
      cmdline("Git stash ")
    end,
    stash_bare = function()
      cmdline("Git stash\r")
    end,
    -- rebase (M2)
    rebase_interactive = function()
      git(buf, vim.list_extend({ "rebase", "--interactive" }, split_words(M.rebase_argument(buf))))
    end,
    rebase_autosquash = function()
      git(
        buf,
        vim.list_extend(
          { "-c", "sequence.editor=true", "rebase", "--interactive", "--autosquash" },
          split_words(M.rebase_argument(buf))
        )
      )
    end,
    rebase_upstream = run({ "rebase", "--interactive", "@{upstream}" }),
    rebase_push = run({ "rebase", "--interactive", "@{push}" }),
    rebase_continue = run({ "rebase", "--continue" }),
    rebase_skip = run({ "rebase", "--skip" }),
    rebase_abort = run({ "rebase", "--abort" }),
    rebase_edit_todo = run({ "rebase", "--edit-todo" }),
    rebase_reword = function()
      M.rebase_retodo(buf, "reword")
    end,
    rebase_edit = function()
      M.rebase_retodo(buf, "edit")
    end,
    rebase_drop = function()
      M.rebase_retodo(buf, "drop")
    end,
    rebase_prompt = function()
      cmdline("Git rebase ")
    end,
    rebase_bare = function()
      cmdline("Git rebase\r")
    end,
    -- submodules: init/update the one under the cursor (all elsewhere)
    submodule_update = function()
      git(buf, vim.list_extend({ "submodule", "update", "--init" }, M.cursor_submodule(buf)))
    end,
    submodule_update_recursive = function()
      git(
        buf,
        vim.list_extend({ "submodule", "update", "--init", "--recursive" }, M.cursor_submodule(buf))
      )
    end,
    -- bisect: on the commit under the cursor, else on HEAD
    bisect_good = function()
      git(buf, vim.list_extend({ "bisect", "good" }, split_words(M.cursor_commit(buf))))
    end,
    bisect_bad = function()
      git(buf, vim.list_extend({ "bisect", "bad" }, split_words(M.cursor_commit(buf))))
    end,
    bisect_skip = function()
      git(buf, vim.list_extend({ "bisect", "skip" }, split_words(M.cursor_commit(buf))))
    end,
    bisect_reset = run({ "bisect", "reset" }),
  }
  for name, fn in pairs(require("nvim-fugitive.maps").cfile_actions(buf)) do
    a[name] = fn
  end
  return a
end

return M
