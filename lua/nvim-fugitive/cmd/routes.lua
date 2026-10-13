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

---@alias fugitive.RouteName "float"|"notify"|"task"|"terminal"|"editor"|"blame"

---Global git options that take a separate argument.
local global_with_arg = {
  ["-c"] = true,
  ["-C"] = true,
  ["--git-dir"] = true,
  ["--work-tree"] = true,
  ["--namespace"] = true,
  ["--config-env"] = true,
  ["--super-prefix"] = true,
  ["--exec-path"] = false, -- only the `=` form takes a value
}

---@class fugitive.ParsedArgs
---@field globals string[] options before the subcommand
---@field sub string? subcommand
---@field rest string[] arguments after the subcommand
---@field paginate boolean -p/--paginate given
---@field no_pager boolean -P/--no-pager given

---Split `args` into global options, subcommand and the rest.
---@param args string[]
---@return fugitive.ParsedArgs
function M.parse(args)
  local r = { globals = {}, rest = {}, paginate = false, no_pager = false }
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-p" or a == "--paginate" then
      r.paginate = true
      table.insert(r.globals, a)
    elseif a == "-P" or a == "--no-pager" then
      r.no_pager = true
      table.insert(r.globals, a)
    elseif global_with_arg[a] and args[i + 1] then
      vim.list_extend(r.globals, { a, args[i + 1] })
      i = i + 1
    elseif a:sub(1, 1) == "-" then
      table.insert(r.globals, a)
    else
      r.sub = a
      r.rest = vim.list_slice(args, i + 1)
      break
    end
    i = i + 1
  end
  return r
end

-- short options that take a value (`-mmsg`, `-am msg`) across the common
-- subcommands: anything after them in a cluster is the value
local value_letters =
  { m = true, F = true, C = true, c = true, u = true, S = true, t = true, n = false }

---Does `rest` contain one of `flags`? Long flags match `--flag` and
---`--flag=value`; single-letter short flags (`-m`) also match inside short
---clusters (`-am`) and with an attached value (`-mmsg`). Scanning stops at `--`.
---Entries ending in `=` match as prefixes (`--fixup=amend:`).
---@param rest string[]
---@param flags string[]
---@return boolean
function M.has_flag(rest, flags)
  for _, a in ipairs(rest) do
    if a == "--" then
      return false
    end
    for _, f in ipairs(flags) do
      if f:sub(1, 2) == "--" then
        if f:sub(-1) == "=" or f:sub(-1) == ":" then
          if a:sub(1, #f) == f then
            return true
          end
        elseif a == f or a:sub(1, #f + 1) == f .. "=" then
          return true
        end
      elseif #f == 2 and a:match("^%-[^-]") then
        -- short option: exact, attached value, or part of a cluster
        local letter = f:sub(2, 2)
        if a == f or a:sub(1, 2) == f then
          return true
        end
        -- walk the cluster; a value-taking letter swallows the rest
        for c in a:sub(2):gmatch(".") do
          if c == letter then
            return true
          end
          if not c:match("%a") or value_letters[c] then
            break
          end
        end
      elseif a == f then
        return true
      end
    end
  end
  return false
end

---Positional (non-option) arguments, up to `--`.
---@param rest string[]
---@param with_arg? table<string, boolean> options that consume the next arg
---@return string[]
function M.positionals(rest, with_arg)
  local out = {}
  local i = 1
  while i <= #rest do
    local a = rest[i]
    if a == "--" then
      break
    elseif a:sub(1, 1) == "-" and a ~= "-" then
      if with_arg and with_arg[a] then
        i = i + 1
      end
    else
      table.insert(out, a)
    end
    i = i + 1
  end
  return out
end

local function edit_route(rest, spec, default_edits)
  if spec.edit_flags and M.has_flag(rest, spec.edit_flags) then
    return "editor"
  end
  if spec.no_edit_flags and M.has_flag(rest, spec.no_edit_flags) then
    return "notify"
  end
  return default_edits and "editor" or "notify"
end

local function first_sub(rest)
  for _, a in ipairs(rest) do
    if a:sub(1, 1) ~= "-" then
      return a
    end
  end
end

---@class fugitive.SubcommandSpec
---@field route fugitive.RouteName|fun(rest: string[], spec: fugitive.SubcommandSpec): fugitive.RouteName
---@field edit_flags? string[] flags that make the command open the editor
---@field no_edit_flags? string[] flags that prevent the editor
---@field pager? boolean git pages this command by default

---The data table `{subcommand -> {edit_flags, no_edit_flags, pager, route}}`.
---@type table<string, fugitive.SubcommandSpec>
M.subcommands = {
  -- pager commands -> float
  log = { route = "float", pager = true },
  show = { route = "float", pager = true },
  diff = {
    pager = true,
    route = function(rest)
      return M.has_flag(rest, { "--quiet", "--exit-code" }) and "notify" or "float"
    end,
  },
  -- a bare `:Git blame` (flags only) opens the side window like upstream;
  -- with paths, revisions or line ranges the output goes to the float
  blame = {
    pager = true,
    route = function(rest)
      if
        #M.positionals(
          rest,
          { ["-L"] = true, ["-S"] = true, ["--contents"] = true, ["--date"] = true }
        ) > 0
      then
        return "float"
      end
      if
        M.has_flag(
          rest,
          { "-L", "-p", "--porcelain", "--line-porcelain", "--incremental", "--", "--contents" }
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
    route = function(rest)
      local s = first_sub(rest)
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
      if M.has_flag(rest, spec.edit_flags) then
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
      if M.has_flag(rest, mutate) then
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
      if M.has_flag(rest, listing) or #M.positionals(rest) == 0 then
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
      if M.has_flag(rest, { "-d", "--delete", "-v", "--verify" }) then
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
      if M.has_flag(rest, listing) then
        return "float"
      end
      local pos = M.positionals(rest, {
        ["-m"] = true,
        ["-F"] = true,
        ["-u"] = true,
        ["--local-user"] = true,
        ["--cleanup"] = true,
      })
      if #pos == 0 then
        return "float"
      end
      if M.has_flag(rest, spec.edit_flags) then
        return "editor"
      end
      if M.has_flag(rest, { "-a", "--annotate", "-s", "--sign", "-u", "--local-user" }) then
        return M.has_flag(rest, spec.no_edit_flags) and "notify" or "editor"
      end
      return "notify"
    end,
  },
  stash = {
    route = function(rest)
      local s = first_sub(rest)
      if s == "list" or s == "show" then
        return "float"
      end
      if M.has_flag(rest, { "-p", "--patch" }) then
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
      if M.has_flag(rest, { "-p", "--patch", "--interactive" }) then
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
      local s = first_sub(rest)
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
      return M.has_flag(rest, spec.edit_flags) and "editor" or "notify"
    end,
  },

  add = {
    edit_flags = { "-e", "--edit" },
    route = function(rest, spec)
      if M.has_flag(rest, { "-p", "--patch", "-i", "--interactive" }) then
        return "terminal"
      end
      return M.has_flag(rest, spec.edit_flags) and "editor" or "notify"
    end,
  },
  reset = {
    route = function(rest)
      return M.has_flag(rest, { "-p", "--patch" }) and "terminal" or "notify"
    end,
  },
  checkout = {
    route = function(rest)
      return M.has_flag(rest, { "-p", "--patch" }) and "terminal" or "notify"
    end,
  },
  restore = {
    route = function(rest)
      return M.has_flag(rest, { "-p", "--patch" }) and "terminal" or "notify"
    end,
  },
  clean = {
    route = function(rest)
      return M.has_flag(rest, { "-i", "--interactive" }) and "terminal" or "notify"
    end,
  },
}

---Does a successful run of `args` deserve a notification? `list` entries are
---a subcommand ("commit") or a subcommand plus a flag ("reset --hard").
---@param args string[]
---@param list? string[] defaults to config.notify.significant
---@return boolean
function M.is_significant(args, list)
  list = list or require("nvim-fugitive.config").get().notify.significant
  local parsed = M.parse(args)
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
  local two = sub .. " " .. (first_sub(rest) or "")
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
    return M.has_flag(rest, { word })
  end
  return first_sub(rest) == word
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
  local parsed = M.parse(args)
  local sub, rest = parsed.sub, parsed.rest
  local result = { parsed = parsed }
  if sub and not M.subcommands[sub] and opts.aliases then
    local expansion = opts.aliases(sub)
    if expansion then
      result.alias = sub
      -- `routes` keyed by the alias name win over everything else
      local chosen = M.override(overrides, sub, rest)
      local p2 = expansion[1] and M.parse(vim.list_extend(vim.deepcopy(expansion), rest))
      if chosen then
        result.sub = p2 and p2.sub or sub
        result.route = chosen
        result.explicit = true
        return result
      end
      if not p2 then
        -- a shell (`!`) alias: run it as a task, like other long commands
        result.sub = sub
        result.route = parsed.paginate and "float"
          or parsed.no_pager and "notification"
          or "overseer"
        return result
      end
      -- a simple alias is routed like the command it expands to
      if p2.sub then
        sub, rest = p2.sub, p2.rest
      end
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

---Picker input (§5.3.2): which picker, if any, should supply the ref.
---Only the exact bare forms and an explicit allow-list trigger it.
---@param args string[]
---@return {picker: "refs"|"log", sub: string, args: string[]}?
function M.picker_trigger(args)
  local n = #args
  local sub = args[1]
  if n == 1 and (sub == "checkout" or sub == "switch" or sub == "merge" or sub == "rebase") then
    return { picker = "refs", sub = sub, args = args }
  end
  -- allow-list of flag-only forms
  if n == 2 and sub == "rebase" and (args[2] == "-i" or args[2] == "--interactive") then
    return { picker = "log", sub = sub, args = args }
  end
  if
    n == 3
    and ((sub == "switch" and (args[2] == "-c" or args[2] == "--create")) or (sub == "checkout" and args[2] == "-b"))
    and args[3]:sub(1, 1) ~= "-"
  then
    return { picker = "refs", sub = sub, args = args }
  end
  return nil
end

return M
