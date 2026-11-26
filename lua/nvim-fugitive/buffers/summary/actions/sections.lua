---@mod nvim-fugitive.buffers.summary.actions.sections Keys that act per section.
---
---Each per-section action names the sections it works on; for each, the
---word its hint shows and what it does there. A section that is not listed
---is not bound: the key then says where it works. The summary hints are
---built from this table too, so a hint never names a section the key does
---nothing in. Used by the default preset; the upstream preset keeps
---vim-fugitive's actions (the `fallback` of each entry, for its hints).

local M = {}

---@class fugitive.SectionCtx
---@field buf integer
---@field a table<string, fugitive.Action> the buffer's actions
---@field info table the line under the cursor
---@field warn fun() say where the key works

---@class fugitive.SectionEntry
---@field word string the hint's word
---@field run fun(ctx: fugitive.SectionCtx)
---@field fallback? {[1]: string, count?: integer} the upstream action for the hint
---@field hint? false no hint in this section (a key only some of its lines take)

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

local function choose(choice)
  return function(ctx)
    require("nvim-fugitive.buffers.summary.actions").choose(ctx.buf, choice)
  end
end

local function call(name)
  return function(ctx)
    ctx.a[name]()
  end
end

---On a file line: only for a submodule.
local function on_submodule(name)
  return function(ctx)
    if ctx.info.entry and ctx.info.entry.submodule then
      return ctx.a[name]()
    end
    ctx.warn()
  end
end

---`git stash <verb>` on the stash under the cursor.
local function stash(args)
  return function(ctx)
    local util = require("nvim-fugitive.buffers.summary.actions.util")
    util.git(ctx.buf, vim.list_extend(vim.deepcopy(args), { ctx.info.ref }))
  end
end

local function stash_view(ctx)
  local st = require("nvim-fugitive.buffers.summary.actions.util").state(ctx.buf)
  local url = require("nvim-fugitive.object").resolve(st.repo, ctx.info.ref)
  if url then
    require("nvim-fugitive.buffers.reader").open(url, "edit")
  end
end

local function retodo(word)
  return function(ctx)
    require("nvim-fugitive.buffers.summary.actions").rebase_retodo(ctx.buf, word)
  end
end

---The per-section actions, in the order their hints show.
---@type {name: string, sections: table<string, fugitive.SectionEntry>}[]
M.actions = {
  {
    name = "choose_ours",
    sections = {
      Unmerged = { word = "ours", run = choose("ours"), fallback = { "discard", count = 2 } },
      Unpushed = { word = "checkout", run = call("checkout"), fallback = { "checkout" } },
      Unpulled = { word = "checkout", run = call("checkout"), fallback = { "checkout" } },
    },
  },
  {
    name = "choose_theirs",
    sections = {
      Unmerged = { word = "theirs", run = choose("theirs"), fallback = { "discard", count = 3 } },
    },
  },
  { name = "choose_both", sections = { Unmerged = { word = "both", run = choose("both") } } },
  { name = "choose_none", sections = { Unmerged = { word = "neither", run = choose("none") } } },
  {
    name = "submodule_init",
    sections = {
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
    sections = {
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
    sections = {
      Unpushed = { word = "reword", run = retodo("reword"), fallback = { "rebase_reword" } },
    },
  },
  {
    name = "rebase_drop_line",
    sections = {
      Unpushed = { word = "drop", run = retodo("drop"), fallback = { "rebase_drop" } },
    },
  },
  {
    name = "rebase_edit_line",
    sections = {
      Unpushed = { word = "edit", run = retodo("edit"), fallback = { "rebase_edit" } },
    },
  },
  {
    name = "stash_pop_line",
    sections = {
      Stash = {
        word = "pop",
        run = stash({ "stash", "pop", "--quiet", "--index" }),
        fallback = { "stash_pop_index" },
      },
    },
  },
  {
    name = "stash_apply_line",
    sections = {
      Stash = {
        word = "apply",
        run = stash({ "stash", "apply", "--quiet", "--index" }),
        fallback = { "stash_apply_index" },
      },
    },
  },
  {
    name = "stash_view_line",
    sections = { Stash = { word = "view", run = stash_view, fallback = { "stash_view" } } },
  },
}

return M
