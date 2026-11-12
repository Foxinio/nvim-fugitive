---@mod nvim-fugitive.cmd.routes Output routing for `:Git {args}` (§5.2).
---
---Routing is by *command type*, not output length: if git would open a pager
---for the command in normal use, its output goes to the big float; otherwise
---to a notification. Network/slow commands become overseer tasks, truly
---interactive prompts get a terminal, and commands that always edit wait for
---the editor first ("editor" route = run in the foreground, notify after).
---
---Flag classification is per subcommand, never global: `-e` means `--edit`
---only for the subcommands that list it.

local M = {}
local argv = require("nvim-fugitive.cmd.argv")

---@alias fugitive.RouteName "float"|"notify"|"task"|"terminal"|"editor"|"blame"

---The first positional argument: a subcommand's own subcommand.
local function first_sub(rest, sub)
  return argv.positionals(rest, sub)[1]
end

---`spec`'s editor route: an explicit `-e`/`--edit` or `--no-edit` decides,
---the last one given winning; then the other `edit_flags`, the
---`no_edit_flags`, and `default_edits`.
local function edit_route(rest, spec, default_edits)
  local toggle =
    argv.last_flag(rest, { editor = { "-e", "--edit" }, notify = { "--no-edit" } }, spec.name)
  if toggle then
    return toggle
  end
  if spec.edit_flags and argv.has_flag(rest, spec.edit_flags, spec.name) then
    return "editor"
  end
  if spec.no_edit_flags and argv.has_flag(rest, spec.no_edit_flags, spec.name) then
    return "notify"
  end
  return default_edits and "editor" or "notify"
end

---@class fugitive.SubcommandSpec
---@field route fugitive.RouteName|fun(rest: string[], spec: fugitive.SubcommandSpec): fugitive.RouteName
---@field edit_flags? string[] flags that make the command open the editor
---@field no_edit_flags? string[] flags that prevent the editor
---@field pager? boolean git pages this command by default
---@field name? string the subcommand (set below), for its `argv.options`

---The data table `{subcommand -> {edit_flags, no_edit_flags, pager, route}}`.
---@type table<string, fugitive.SubcommandSpec>
M.subcommands = {
  -- pager commands -> float
  log = { route = "float", pager = true },
  show = { route = "float", pager = true },
  diff = {
    pager = true,
    route = function(rest, spec)
      return argv.has_flag(rest, { "--quiet", "--exit-code" }, spec.name) and "notify" or "float"
    end,
  },
  -- a bare `:Git blame` (flags only) opens the side window like upstream;
  -- with paths, revisions or line ranges the output goes to the float
  blame = {
    pager = true,
    route = function(rest, spec)
      if #argv.positionals(rest, spec.name) > 0 then
        return "float"
      end
      if
        argv.has_flag(
          rest,
          { "-L", "-p", "--porcelain", "--line-porcelain", "--incremental", "--", "--contents" },
          spec.name
        )
      then
        return "float"
      end
      return "blame"
    end,
  },
  shortlog = { route = "float", pager = true },
  reflog = {
    pager = true,
    route = function(rest, spec)
      local s = first_sub(rest, spec.name)
      return (s == "delete" or s == "expire" or s == "exists") and "notify" or "float"
    end,
  },
  -- `-e` is a pattern for grep, never --edit
  grep = { route = "float", pager = true },
  help = { route = "float", pager = true },
  whatchanged = { route = "float", pager = true },
  ["range-diff"] = { route = "float", pager = true },
  ["cherry"] = { route = "notify" },

  branch = {
    pager = true,
    edit_flags = { "--edit-description" },
    route = function(rest, spec)
      if argv.has_flag(rest, spec.edit_flags, spec.name) then
        return "editor"
      end
      local mutate = {
        "-d",
        "-D",
        "--delete",
        "-m",
        "-M",
        "--move",
        "-c",
        "-C",
        "--copy",
        "-u",
        "--set-upstream-to",
        "--unset-upstream",
        "-f",
        "--force",
        "-t",
        "--track",
        "--no-track",
        "--show-current",
      }
      if argv.has_flag(rest, mutate, spec.name) then
        return "notify"
      end
      local listing = {
        "-l",
        "--list",
        "-a",
        "--all",
        "-r",
        "--remotes",
        "--contains",
        "--no-contains",
        "--merged",
        "--no-merged",
        "--points-at",
        "--sort",
        "--format",
        "-v",
        "--verbose",
      }
      if argv.has_flag(rest, listing, spec.name) or #argv.positionals(rest, spec.name) == 0 then
        return "float"
      end
      return "notify" -- create
    end,
  },
  tag = {
    pager = true,
    edit_flags = { "-e", "--edit" },
    no_edit_flags = { "-m", "--message", "-F", "--file" },
    route = function(rest, spec)
      if argv.has_flag(rest, { "-d", "--delete", "-v", "--verify" }, spec.name) then
        return "notify"
      end
      local listing = {
        "-l",
        "--list",
        "-n",
        "--contains",
        "--no-contains",
        "--merged",
        "--no-merged",
        "--points-at",
        "--sort",
        "--format",
      }
      if argv.has_flag(rest, listing, spec.name) then
        return "float"
      end
      if #argv.positionals(rest, spec.name) == 0 then
        return "float"
      end
      -- annotated tags open the editor unless a message is given
      local annotated = { "-a", "--annotate", "-s", "--sign", "-u", "--local-user" }
      if
        argv.has_flag(rest, annotated, spec.name) or argv.has_flag(rest, spec.edit_flags, spec.name)
      then
        return edit_route(rest, spec, true)
      end
      return "notify"
    end,
  },
  stash = {
    route = function(rest, spec)
      local s = first_sub(rest, spec.name)
      if s == "list" or s == "show" then
        return "float"
      end
      if argv.has_flag(rest, { "-p", "--patch" }, spec.name) then
        return "terminal"
      end
      return "notify"
    end,
  },

  commit = {
    -- -c/--reedit-message re-edits; --fixup=amend:/reword: open the editor
    edit_flags = { "-e", "--edit", "-c", "--reedit-message", "--fixup=amend:", "--fixup=reword:" },
    no_edit_flags = {
      "-m",
      "--message",
      "-F",
      "--file",
      "-C",
      "--reuse-message",
      "--no-edit",
      "--fixup=",
      "--dry-run",
    },
    route = function(rest, spec)
      if argv.has_flag(rest, { "-p", "--patch", "--interactive" }, spec.name) then
        return "terminal"
      end
      return edit_route(rest, spec, true)
    end,
  },
  merge = {
    edit_flags = { "-e", "--edit" },
    no_edit_flags = { "--no-edit" },
    route = function(rest, spec)
      return edit_route(rest, spec, false)
    end,
  },
  revert = {
    edit_flags = { "-e", "--edit" },
    no_edit_flags = {
      "--no-edit",
      "-n",
      "--no-commit",
      "--abort",
      "--quit",
      "--skip",
      "--continue",
    },
    route = function(rest, spec)
      return edit_route(rest, spec, true)
    end,
  },
  ["cherry-pick"] = {
    edit_flags = { "-e", "--edit" },
    no_edit_flags = { "--no-edit" },
    route = function(rest, spec)
      return edit_route(rest, spec, false)
    end,
  },
  config = {
    edit_flags = { "-e", "--edit" },
    route = function(rest, spec)
      return edit_route(rest, spec, false)
    end,
  },
  notes = {
    edit_flags = { "-e", "--edit", "-c", "--reedit-message" },
    no_edit_flags = { "-m", "--message", "-F", "--file", "-C", "--reuse-message" },
    route = function(rest, spec)
      local s = first_sub(rest, spec.name)
      if s == "show" or s == "list" or s == nil then
        return "float"
      end
      if s == "edit" then
        return "editor"
      end
      if s == "add" or s == "append" then
        return edit_route(rest, spec, true)
      end
      return "notify"
    end,
  },
  rebase = {
    edit_flags = { "-i", "--interactive", "--edit-todo" },
    route = function(rest, spec)
      return argv.has_flag(rest, spec.edit_flags, spec.name) and "editor" or "notify"
    end,
  },

  add = {
    edit_flags = { "-e", "--edit" },
    route = function(rest, spec)
      if argv.has_flag(rest, { "-p", "--patch", "-i", "--interactive" }, spec.name) then
        return "terminal"
      end
      return argv.has_flag(rest, spec.edit_flags, spec.name) and "editor" or "notify"
    end,
  },
  reset = {
    route = function(rest, spec)
      return argv.has_flag(rest, { "-p", "--patch" }, spec.name) and "terminal" or "notify"
    end,
  },
  checkout = {
    route = function(rest, spec)
      return argv.has_flag(rest, { "-p", "--patch" }, spec.name) and "terminal" or "notify"
    end,
  },
  restore = {
    route = function(rest, spec)
      return argv.has_flag(rest, { "-p", "--patch" }, spec.name) and "terminal" or "notify"
    end,
  },
  clean = {
    route = function(rest, spec)
      return argv.has_flag(rest, { "-i", "--interactive" }, spec.name) and "terminal" or "notify"
    end,
  },
}
for name, spec in pairs(M.subcommands) do
  spec.name = name
end

---Does a successful run of `args` deserve a notification? `list` entries are
---a subcommand ("commit") or a subcommand plus a flag ("reset --hard").
---@param args string[]
---@param list? string[] defaults to config.notify.significant
---@return boolean
function M.is_significant(args, list)
  list = list or require("nvim-fugitive.config").get().notify.significant
  local parsed = argv.parse(args)
  if not parsed.sub then
    return false
  end
  for _, entry in ipairs(list) do
    if M.match_entry(entry, parsed.sub, parsed.rest) then
      return true
    end
  end
  return false
end

---Is `sub rest…` a long-running command (overseer task)?
---@param sub string
---@param rest string[]
---@param list? string[] defaults to config.long_running
---@return boolean
function M.is_long_running(sub, rest, list)
  list = list or require("nvim-fugitive.config").get().long_running
  local two = sub .. " " .. (first_sub(rest, sub) or "")
  for _, entry in ipairs(list) do
    if entry == sub or entry == two then
      return true
    end
  end
  return false
end

---Output targets a command can be routed to (§5.2.3). The pager kinds
---show output in a buffer: `float` (the big float), `inplace` (the current
---window), `split`, `vert` and `tab`.
M.targets = {
  float = "pager",
  inplace = "pager",
  split = "pager",
  vert = "pager",
  tab = "pager",
  notification = "notification",
  overseer = "overseer",
  term = "term",
  -- internal: commands that always edit, and the blame side window
  editor = "notification",
  blame = "blame",
}

---Old route names, still accepted in `routes`.
M.target_aliases = { notify = "notification", task = "overseer", terminal = "term" }

---@param target string
---@return string
function M.normalize(target)
  return M.target_aliases[target] or target
end

---Is `target` a pager kind (output in a buffer)?
function M.is_pager(target)
  return M.targets[target] == "pager"
end

---Does a config key ("sub" or "sub word") match a parsed command? The
---second word matches a flag present in the arguments or the first
---positional argument ("stash list", "reset --hard").
---@param entry string
---@param sub string
---@param rest string[]
---@return boolean
function M.match_entry(entry, sub, rest)
  local name, word = entry:match("^(%S+)%s+(%S+)$")
  if not name then
    return entry == sub
  end
  if name ~= sub then
    return false
  end
  if word:sub(1, 1) == "-" then
    return argv.has_flag(rest, { word }, sub)
  end
  return first_sub(rest, sub) == word
end

---The user's route override for a command, most specific key first.
---@param overrides table<string, string>
---@param sub string
---@param rest string[]
---@return string?
function M.override(overrides, sub, rest)
  local fallback
  for key, target in pairs(overrides) do
    if M.match_entry(key, sub, rest) then
      if key:find(" ", 1, true) then
        return M.normalize(target)
      end
      fallback = M.normalize(target)
    end
  end
  return fallback
end

---@class fugitive.Classification
---@field route string an output target (see M.targets)
---@field sub string?
---@field parsed fugitive.ParsedArgs
---@field explicit boolean? the user's `routes` chose the target
---@field alias string? the git alias that was run
---@field shell boolean? a shell (`!`) alias is involved

---Classify a `:Git` argument list.
---@param args string[]
---`opts.aliases(name)` returns a git alias's expansion, or `{}` for a shell
---(`!`) alias, and nil when `name` is not an alias.
---@param opts? {overrides?: table<string, string>, long_running?: string[], aliases?: fun(name: string): string[]?}
---@return fugitive.Classification
function M.classify(args, opts)
  opts = opts or {}
  local cfg = package.loaded["nvim-fugitive.config"] and require("nvim-fugitive.config").get()
    or nil
  local overrides = opts.overrides or (cfg and cfg.routes) or {}
  local parsed = argv.parse(args)
  local sub, rest = parsed.sub, parsed.rest
  local result = { parsed = parsed }
  -- unfold aliases (of aliases …) like git does; a shell alias that runs a
  -- single git command is unfolded into that command
  local chain, seen = {}, {}
  local shell_unknown = false
  while sub and not M.subcommands[sub] and opts.aliases and not seen[sub] do
    local expansion, body = opts.aliases(sub)
    if not expansion then
      break
    end
    seen[sub] = true
    table.insert(chain, { name = sub, rest = rest })
    local words = expansion --[[@as string[]?]]
    if not expansion[1] then
      result.shell = true
      words = body and argv.shell_alias_command(body, rest)
      if not words then
        shell_unknown = true
        break
      end
    else
      words = vim.list_extend(vim.deepcopy(expansion), rest)
    end
    local p = argv.parse(words)
    if not p.sub then
      break
    end
    sub, rest = p.sub, p.rest
  end
  if #chain > 0 then
    result.alias = chain[1].name
    -- `routes` keyed by an alias name win, the name typed first
    for _, link in ipairs(chain) do
      local chosen = M.override(overrides, link.name, link.rest)
      if chosen then
        result.sub = sub
        result.route = chosen
        result.explicit = true
        return result
      end
    end
    if shell_unknown then
      -- a shell alias doing something else: run it as a task, like other
      -- long commands
      result.sub = sub
      result.route = parsed.paginate and "float" or parsed.no_pager and "notification" or "overseer"
      return result
    end
  end
  result.sub = sub
  if not sub then
    result.route = "notification"
    return result
  end
  local chosen = M.override(overrides, sub, rest)
  if chosen then
    result.route = chosen
    result.explicit = true
    return result
  end
  local route
  if M.is_long_running(sub, rest, opts.long_running) then
    route = "overseer"
  else
    local spec = M.subcommands[sub]
    if spec then
      route = type(spec.route) == "function" and spec.route(rest, spec) or spec.route
    else
      route = "notify"
    end
    route = M.normalize(route --[[@as string]])
  end
  if parsed.paginate and route == "notification" then
    route = "float"
  elseif parsed.no_pager and M.is_pager(route) then
    route = "notification"
  end
  result.route = route
  return result
end

---The commands that ask for their ref with a picker, and which one.
local pickers =
  { push = "push", checkout = "refs", switch = "refs", merge = "refs", rebase = "refs" }

---Picker input (§5.3.2): which picker, if any, should supply the ref. A
---picker command given only flags (no positional, no `--`) asks for it,
---unless a flag of its `argv.options` blockers means it wants no ref.
---@param args string[]
---@return {picker: "refs"|"log"|"push", sub: string, args: string[], set_upstream?: boolean}?
function M.picker_trigger(args)
  local parsed = argv.parse(args)
  local sub = parsed.sub
  local picker = sub and pickers[sub]
  if not picker then
    return nil
  end
  local rest = parsed.rest
  local s = argv.scan(sub, rest)
  if s.dashdash or #s.positionals > 0 then
    return nil
  end
  local blockers = argv.options[sub] and argv.options[sub].blockers
  if blockers and argv.has_flag(rest, blockers, sub) then
    return nil
  end
  local trigger = { picker = picker, sub = sub, args = args }
  if sub == "rebase" and argv.has_flag(rest, { "-i", "--interactive" }, sub) then
    trigger.picker = "log"
  elseif sub == "push" and argv.has_flag(rest, { "-u", "--set-upstream" }, sub) then
    -- choose the upstream once; later pushes use it without asking
    trigger.set_upstream = true
  end
  return trigger
end

return M
