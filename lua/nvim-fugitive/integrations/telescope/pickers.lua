---@mod nvim-fugitive.integrations.telescope.pickers Telescope pickers (§5.3.1).
---
--- log:   <CR> open commit · <M-d> diff current file vs commit (:Gdiffsplit)
---        <M-c> checkout (detached) · <M-r> revert · <M-p> cherry-pick
---        <C-y> yank short SHA · <M-y> yank full SHA · <M-b> :GBrowse
--- refs:  <CR> checkout (remote: create a tracking branch) · <M-m> merge
---        <M-r> rebase HEAD onto · <M-d> diff vs ref (changed files -> quickfix)
--- stash: <CR> apply · <M-p> pop · <M-d> drop (confirm) · <M-b> stash branch
---        <M-o> open as commit buffer

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local base = require("nvim-fugitive.integrations.telescope")
local object = require("nvim-fugitive.object")
local notify = require("nvim-fugitive.ui.notify")

local M = {}

local function git(repo, args, opts)
  opts = vim.tbl_extend("force", { repo = repo, skip_picker = true }, opts or {})
  return require("nvim-fugitive.cmd.git").run(args, opts)
end

local function command_previewer(repo, title, argv_of)
  return previewers.new_buffer_previewer({
    title = title,
    define_preview = function(self, entry)
      local res = repo:sync(argv_of(entry))
      local text = (res.code == 0 and res.stdout or res.stderr):gsub("\n$", "")
      vim.api.nvim_buf_set_lines(
        self.state.bufnr,
        0,
        -1,
        false,
        vim.split(text, "\n", { plain = true })
      )
      vim.bo[self.state.bufnr].filetype = "git"
    end,
  })
end

local function selected(prompt_bufnr)
  local entry = action_state.get_selected_entry()
  actions.close(prompt_bufnr)
  return entry and entry.value
end

local function map_actions(map, list)
  for _, def in ipairs(list) do
    map("i", def[1], def[2])
    map("n", def[1], def[2])
  end
end

---@param opts? {repo?: fugitive.Repo, args?: string[], prompt_title?: string, on_select?: fun(c: table), origin_buf?: integer}
function M.log(opts)
  opts = opts or {}
  local repo = base.get_repo(opts.repo)
  if not repo then
    return
  end
  local origin = opts.origin_buf or vim.api.nvim_get_current_buf()
  local commits = base.list_log(repo, opts.args)
  local displayer = entry_display.create({
    separator = " ",
    items = { { width = 9 }, { width = 10 }, { width = 16 }, { remaining = true } },
  })
  pickers
    .new(opts, {
      prompt_title = opts.prompt_title or "Git log",
      finder = finders.new_table({
        results = commits,
        entry_maker = function(c)
          return {
            value = c,
            ordinal = c.short .. " " .. c.author .. " " .. c.subject .. " " .. c.refs,
            display = function()
              return displayer({
                { c.short, "TelescopeResultsIdentifier" },
                { c.date, "TelescopeResultsComment" },
                { c.author, "TelescopeResultsConstant" },
                c.subject .. (c.refs ~= "" and (" (" .. c.refs .. ")") or ""),
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = command_previewer(repo, "git show", function(e)
        return { "show", "--stat", "-p", "--no-color", e.value.sha }
      end),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local c = selected(prompt_bufnr)
          if not c then
            return
          end
          if opts.on_select then
            return opts.on_select(c)
          end
          require("nvim-fugitive.buffers.reader").open(object.format(repo.git_dir, c.sha), "edit")
        end)
        map_actions(map, {
          {
            "<M-d>",
            function()
              local c = selected(prompt_bufnr)
              if c and vim.api.nvim_buf_is_valid(origin) then
                vim.api.nvim_set_current_buf(origin)
                require("nvim-fugitive.buffers.diffsplit").split({ against = c.sha })
              end
            end,
          },
          {
            "<M-c>",
            function()
              local c = selected(prompt_bufnr)
              if c then
                git(repo, { "checkout", "--detach", c.sha })
              end
            end,
          },
          {
            "<M-r>",
            function()
              local c = selected(prompt_bufnr)
              if c then
                git(repo, { "revert", c.sha })
              end
            end,
          },
          {
            "<M-p>",
            function()
              local c = selected(prompt_bufnr)
              if c then
                git(repo, { "cherry-pick", c.sha })
              end
            end,
          },
          {
            "<C-y>",
            function()
              local c = selected(prompt_bufnr)
              if c then
                vim.fn.setreg(vim.v.register, c.short)
                notify.info("yanked " .. c.short)
              end
            end,
          },
          {
            "<M-y>",
            function()
              local c = selected(prompt_bufnr)
              if c then
                vim.fn.setreg(vim.v.register, c.sha)
                notify.info("yanked " .. c.sha)
              end
            end,
          },
          {
            "<M-b>",
            function()
              local c = selected(prompt_bufnr)
              if c then
                require("nvim-fugitive.cmd.browse").browse(
                  { arg = c.sha, count = -1, line1 = 0, range = 0, buf = origin },
                  false
                )
              end
            end,
          },
        })
        return true
      end,
    })
    :find()
end

---@param opts? {repo?: fugitive.Repo, prompt_title?: string, on_select?: fun(r: table)}
function M.refs(opts)
  opts = opts or {}
  local repo = base.get_repo(opts.repo)
  if not repo then
    return
  end
  local refs = base.list_refs(repo)
  local displayer = entry_display.create({
    separator = " ",
    items = { { width = 7 }, { width = 36 }, { width = 9 }, { width = 16 }, { remaining = true } },
  })
  pickers
    .new(opts, {
      prompt_title = opts.prompt_title or "Git refs",
      finder = finders.new_table({
        results = refs,
        entry_maker = function(r)
          return {
            value = r,
            ordinal = r.name .. " " .. r.subject,
            display = function()
              return displayer({
                { r.kind, "TelescopeResultsComment" },
                {
                  r.name,
                  r.kind == "branch" and "TelescopeResultsIdentifier" or "TelescopeResultsConstant",
                },
                { r.sha, "TelescopeResultsNumber" },
                { r.date, "TelescopeResultsComment" },
                r.subject,
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = command_previewer(repo, "HEAD...ref", function(e)
        return {
          "log",
          "--oneline",
          "--graph",
          "--left-right",
          "--boundary",
          "-n",
          "200",
          "HEAD..." .. e.value.ref,
          "--",
        }
      end),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local r = selected(prompt_bufnr)
          if not r then
            return
          end
          if opts.on_select then
            return opts.on_select(r)
          end
          if r.kind == "remote" then
            local localname = r.name:gsub("^[^/]+/", "")
            if repo:rev_parse("refs/heads/" .. localname) then
              git(repo, { "checkout", localname })
            else
              git(repo, { "checkout", "--track", r.name })
            end
          else
            git(repo, { "checkout", r.name })
          end
        end)
        map_actions(map, {
          {
            "<M-m>",
            function()
              local r = selected(prompt_bufnr)
              if r then
                git(repo, { "merge", r.name })
              end
            end,
          },
          {
            "<M-r>",
            function()
              local r = selected(prompt_bufnr)
              if r then
                git(repo, { "rebase", r.name })
              end
            end,
          },
          {
            "<M-d>",
            function()
              local r = selected(prompt_bufnr)
              if not r then
                return
              end
              local files = repo:lines({ "diff", "--name-only", r.ref, "--" }) or {}
              local items = {}
              for _, f in ipairs(files) do
                table.insert(
                  items,
                  { filename = repo:abs(f), lnum = 1, text = "changed vs " .. r.name }
                )
              end
              vim.fn.setqflist(
                {},
                " ",
                { title = "git diff --name-only " .. r.name, items = items }
              )
              vim.cmd("copen")
            end,
          },
        })
        return true
      end,
    })
    :find()
end

---@param opts? {repo?: fugitive.Repo, prompt_title?: string}
function M.stash(opts)
  opts = opts or {}
  local repo = base.get_repo(opts.repo)
  if not repo then
    return
  end
  local stashes = base.list_stash(repo)
  pickers
    .new(opts, {
      prompt_title = opts.prompt_title or "Git stash",
      finder = finders.new_table({
        results = stashes,
        entry_maker = function(s)
          return {
            value = s,
            ordinal = s.ref .. " " .. s.subject,
            display = s.ref .. " " .. s.subject,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = command_previewer(repo, "git stash show", function(e)
        return { "stash", "show", "-p", "--include-untracked", "--no-color", e.value.ref }
      end),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local s = selected(prompt_bufnr)
          if s then
            git(repo, { "stash", "apply", s.ref })
          end
        end)
        map_actions(map, {
          {
            "<M-p>",
            function()
              local s = selected(prompt_bufnr)
              if s then
                git(repo, { "stash", "pop", s.ref })
              end
            end,
          },
          {
            "<M-d>",
            function()
              local s = selected(prompt_bufnr)
              if s and vim.fn.confirm("Drop " .. s.ref .. "?", "&Yes\n&No", 2) == 1 then
                git(repo, { "stash", "drop", s.ref })
              end
            end,
          },
          {
            "<M-b>",
            function()
              local s = selected(prompt_bufnr)
              if not s then
                return
              end
              vim.ui.input({ prompt = "Branch name: " }, function(name)
                if name and name ~= "" then
                  git(repo, { "stash", "branch", name, s.ref })
                end
              end)
            end,
          },
          {
            "<M-o>",
            function()
              local s = selected(prompt_bufnr)
              if s then
                local url = object.resolve(repo, s.ref)
                if url then
                  require("nvim-fugitive.buffers.reader").open(url, "edit")
                end
              end
            end,
          },
        })
        return true
      end,
    })
    :find()
end

---:Ggrep results.
---@param items table[]
---@param opts {title: string}
function M.grep(items, opts)
  local make_entry = require("telescope.make_entry")
  local maker = make_entry.gen_from_quickfix({})
  pickers
    .new({}, {
      prompt_title = opts.title,
      finder = finders.new_table({ results = items, entry_maker = maker }),
      sorter = conf.generic_sorter({}),
      previewer = conf.qflist_previewer({}),
    })
    :find()
end

return M
