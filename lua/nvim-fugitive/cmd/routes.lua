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

---Split a command line into words: whitespace separated, with '…', "…"
---and backslash escapes.
---@param str string
---@return string[]
function M.split_args(str)
  local args, cur, i, n = {}, nil, 1, #str
  local quote
  while i <= n do
    local c = str:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      elseif c == "\\" and quote == '"' and i < n then
        i = i + 1
        cur = cur .. str:sub(i, i)
      else
        cur = cur .. c
      end
    elseif c == "'" or c == '"' then
      quote = c
      cur = cur or ""
    elseif c == "\\" and i < n then
      i = i + 1
      cur = (cur or "") .. str:sub(i, i)
    elseif c:match("%s") then
      if cur then
        table.insert(args, cur)
        cur = nil
      end
    else
      cur = (cur or "") .. c
    end
    i = i + 1
  end
  if cur then
    table.insert(args, cur)
  end
  return args
end

---Split a shell command at `&&`, `||`, `;` and newlines outside quotes; each
---part keeps only the first stage of a `|` pipeline.
---@param str string
---@return {text: string, piped: boolean}[]
local function shell_segments(str)
  local parts, cur, quote = {}, {}, nil
  local i, n = 1, #str
  local piped = false
  local function cut()
    local part = vim.trim(table.concat(cur))
    if part ~= "" then
      table.insert(parts, { text = part, piped = piped })
    end
    cur, piped = {}, false
  end
  while i <= n do
    local c = str:sub(i, i)
    local two = str:sub(i, i + 1)
    if quote then
      if c == "\\" and quote == '"' then
        if not piped then
          table.insert(cur, str:sub(i, i + 1))
        end
        i = i + 1
      else
        if c == quote then
          quote = nil
        end
        if not piped then
          table.insert(cur, c)
        end
      end
    elseif c == "'" or c == '"' then
      quote = c
      if not piped then
        table.insert(cur, c)
      end
    elseif c == "\\" then
      if not piped then
        table.insert(cur, str:sub(i, i + 1))
      end
      i = i + 1
    elseif two == "&&" or two == "||" then
      cut()
      i = i + 1
    elseif c == ";" or c == "\n" then
      cut()
    elseif c == "|" then
      piped = true
    elseif not piped then
      table.insert(cur, c)
    end
    i = i + 1
  end
  cut()
  return parts
end

---The git command a shell (`!`) alias runs, as `:Git` arguments, when its
---body runs git exactly once (`!git log --graph`, `!f() { git log "$@"; }; f`,
---`!git log --oneline | head`); nil otherwise. `args` are the arguments the
---alias was given: they replace `"$@"`/`$1`…, or are appended like git does.
---@param body string the alias value, with or without its leading `!`
---@param args? string[]
---@return string[]?
function M.shell_alias_command(body, args)
  args = args or {}
  local s = vim.trim((body:gsub("^!", "")))
  -- the usual function wrapper: f() { …; }; f
  local name, inner, call = s:match("^([%w_]+)%s*%(%)%s*{(.*)}%s*;?%s*([%w_]+)%s*$")
  local wrapped = name ~= nil and name == call
  if wrapped then
    s = inner
  end
  if s:find("$(", 1, true) or s:find("`", 1, true) then
    -- a command substitution may run git too
    return nil
  end
  local found, last
  local parts = shell_segments(s)
  for k, part in ipairs(parts) do
    local words = M.split_args(part.text)
    if words[1] == "command" then
      table.remove(words, 1)
    end
    if words[1] == "git" then
      if found then
        return nil
      end
      found = vim.list_slice(words, 2)
      -- appended arguments reach git only at the end of the command line
      last = k == #parts and not part.piped
    end
  end
  if not found or #found == 0 then
    return nil
  end
  local out, used = {}, false
  for _, w in ipairs(found) do
    if w == "$@" or w == "$*" then
      vim.list_extend(out, args)
      used = true
    elseif w:match("^%$%d$") then
      local v = args[tonumber(w:sub(2))]
      if v then
        table.insert(out, v)
      end
      used = true
    elseif w:find("$", 1, true) then
      -- other shell variables: cannot know what runs
      return nil
    else
      table.insert(out, w)
    end
  end
  -- git appends the arguments to the command line: they reach git when it
  -- runs last, outside a function wrapper and a pipeline
  if not used and not wrapped and last then
    vim.list_extend(out, args)
  end
  return out
end

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

---@class fugitive.OptionSpec
---@field short? string letters that take a value (`-mmsg`, `-m msg`)
---@field optional? string letters with an optional attached value (`-uno`)
---@field long? string[] long options that take a value (`--x=v`, `--x v`)
---@field blockers? string[] flags that mean no ref picker (picker commands)

---The options of each subcommand that take a value: they decide where a
---short cluster ends and which words are option values, not positionals.
---Every option not listed is a switch. A subcommand without an entry has no
---value-taking options (its flags are all switches).
---@type table<string, fugitive.OptionSpec>
M.options = {
  commit = {
    short = "mFCct",
    optional = "uS",
    long = {
      "--message",
      "--file",
      "--reuse-message",
      "--reedit-message",
      "--template",
      "--author",
      "--date",
      "--cleanup",
      "--fixup",
      "--squash",
      "--trailer",
      "--pathspec-from-file",
    },
  },
  merge = {
    short = "mFsX",
    optional = "S",
    long = { "--message", "--file", "--strategy", "--strategy-option", "--into-name", "--cleanup" },
    blockers = { "--abort", "--continue", "--quit" },
  },
  revert = {
    short = "mX",
    optional = "S",
    long = { "--mainline", "--strategy", "--strategy-option", "--cleanup" },
  },
  ["cherry-pick"] = {
    short = "mX",
    optional = "S",
    long = { "--mainline", "--strategy", "--strategy-option", "--cleanup" },
  },
  tag = {
    short = "mFu",
    long = {
      "--message",
      "--file",
      "--local-user",
      "--cleanup",
      "--sort",
      "--format",
      "--points-at",
      "--contains",
      "--no-contains",
      "--merged",
      "--no-merged",
    },
  },
  -- `--ref` comes before the notes subcommand
  notes = {
    short = "mFcC",
    long = { "--ref", "--message", "--file", "--reedit-message", "--reuse-message" },
  },
  branch = {
    short = "u",
    long = {
      "--set-upstream-to",
      "--sort",
      "--format",
      "--points-at",
      "--contains",
      "--no-contains",
      "--merged",
      "--no-merged",
    },
  },
  stash = { short = "m", long = { "--message", "--pathspec-from-file" } },
  rebase = {
    short = "sXx",
    optional = "S",
    long = { "--strategy", "--strategy-option", "--onto", "--exec" },
    blockers = {
      "--continue",
      "--abort",
      "--skip",
      "--quit",
      "--edit-todo",
      "--show-current-patch",
      "--root",
    },
  },
  push = {
    short = "o",
    long = { "--repo", "--receive-pack", "--exec", "--push-option", "--recurse-submodules" },
    -- these push without a refspec of their own choosing
    blockers = { "--all", "--branches", "--mirror", "--tags", "-d", "--delete", "--prune" },
  },
  checkout = {
    short = "bB",
    long = { "--orphan", "--conflict", "--pathspec-from-file" },
    blockers = { "-b", "-B", "--orphan", "-p", "--patch", "--pathspec-from-file" },
  },
  switch = {
    short = "cC",
    long = { "--create", "--force-create", "--orphan", "--conflict" },
    blockers = { "-c", "-C", "--create", "--force-create", "--orphan" },
  },
  blame = {
    short = "LS",
    optional = "CM",
    long = { "--contents", "--date", "--encoding", "--ignore-rev", "--ignore-revs-file" },
  },
  log = {
    short = "nLSGO",
    long = {
      "--max-count",
      "--skip",
      "--since",
      "--after",
      "--until",
      "--before",
      "--author",
      "--committer",
      "--grep",
      "--date",
      "--encoding",
    },
  },
  config = { short = "f", long = { "--file", "--blob", "--type", "--default" } },
  add = { long = { "--pathspec-from-file" } },
  reset = { long = { "--pathspec-from-file" } },
  restore = { short = "s", long = { "--source", "--pathspec-from-file" } },
  clean = { short = "e", long = { "--exclude" } },
}

-- without a subcommand: the value letters common to the usual subcommands
local generic = { short = "mFCcuSt" }
local none = {}

---@type table<fugitive.OptionSpec, {short: table<string, boolean>, optional: table<string, boolean>, long: table<string, boolean>}>
local compiled = setmetatable({}, { __mode = "k" })

local function lookup(sub)
  local spec = (sub == nil and generic) or M.options[sub] or none
  local c = compiled[spec]
  if not c then
    c = { short = {}, optional = {}, long = {} }
    for ch in (spec.short or ""):gmatch(".") do
      c.short[ch] = true
    end
    for ch in (spec.optional or ""):gmatch(".") do
      c.optional[ch] = true
    end
    for _, l in ipairs(spec.long or {}) do
      c.long[l] = true
    end
    compiled[spec] = c
  end
  return c
end

---@class fugitive.Scan
---@field opts {[1]: string, [2]: string?}[] options in order: name and value
---@field positionals string[] non-option arguments before `--`
---@field at integer[] the index in `rest` of each positional
---@field dashdash boolean `--` was given
---@field after string[] the arguments after `--`

---Read the arguments of `sub` (nil: no subcommand known) the way git's
---option parser does: short clusters split by `sub`'s value letters, long
---options with `=value` or a separate value, scanning up to `--`.
---@param sub string?
---@param rest string[]
---@return fugitive.Scan
function M.scan(sub, rest)
  local spec = lookup(sub)
  local r = { opts = {}, positionals = {}, at = {}, dashdash = false, after = {} }
  local i = 1
  while i <= #rest do
    local a = rest[i]
    if a == "--" then
      r.dashdash = true
      r.after = vim.list_slice(rest, i + 1)
      break
    elseif a:sub(1, 2) == "--" then
      local name, value = a:match("^(%-%-[^=]+)=(.*)$")
      if name then
        table.insert(r.opts, { name, value })
      elseif spec.long[a] and rest[i + 1] ~= nil then
        table.insert(r.opts, { a, rest[i + 1] })
        i = i + 1
      else
        table.insert(r.opts, { a })
      end
    elseif a:sub(1, 1) == "-" and #a > 1 then
      local j = 2
      while j <= #a do
        local c = a:sub(j, j)
        if not c:match("%a") then
          -- a number (`-5`, `-U3`): the value of the letter before it
          local last = r.opts[#r.opts]
          if j == 2 or not last then
            table.insert(r.opts, { a })
          else
            last[2] = a:sub(j)
          end
          break
        elseif spec.short[c] then
          local value = a:sub(j + 1)
          if value == "" then
            value = rest[i + 1]
            if value ~= nil then
              i = i + 1
            end
          end
          table.insert(r.opts, { "-" .. c, value })
          break
        elseif spec.optional[c] then
          local value = a:sub(j + 1)
          table.insert(r.opts, { "-" .. c, value ~= "" and value or nil })
          break
        end
        table.insert(r.opts, { "-" .. c })
        j = j + 1
      end
    else
      table.insert(r.positionals, a)
      table.insert(r.at, i)
    end
    i = i + 1
  end
  return r
end

---Does option `o` match `flag`? Entries ending in `=` or `:` match the
---`--name=value` form as a prefix (`--fixup=amend:`).
local function matches(o, flag)
  local last = flag:sub(-1)
  if flag:sub(1, 2) == "--" and (last == "=" or last == ":") then
    local full = o[2] and (o[1] .. "=" .. o[2]) or o[1]
    return full:sub(1, #flag) == flag
  end
  return o[1] == flag
end

---Does `rest` contain one of `flags`? Long flags match `--flag`,
---`--flag=value` and `--flag value`; short flags also match inside clusters
---(`-am`) and with an attached value (`-mmsg`). Scanning stops at `--`;
---`"--"` itself in `flags` matches the separator. Clusters are split with
---`sub`'s value letters (`M.options`); without `sub`, the common ones.
---@param rest string[]
---@param flags string[]
---@param sub? string
---@return boolean
function M.has_flag(rest, flags, sub)
  return M.last_flag(rest, { [true] = flags }, sub) ~= nil
end

---Which group of flags appears last in `rest`? git lets the last of two
---opposite options win (`-e --no-edit`).
---@generic K
---@param rest string[]
---@param groups table<K, string[]>
---@param sub? string
---@return K?
function M.last_flag(rest, groups, sub)
  local s = M.scan(sub, rest)
  for i = #s.opts, 1, -1 do
    for key, flags in pairs(groups) do
      for _, f in ipairs(flags) do
        if matches(s.opts[i], f) then
          return key
        end
      end
    end
  end
  if s.dashdash then
    for key, flags in pairs(groups) do
      if vim.tbl_contains(flags, "--") then
        return key
      end
    end
  end
  return nil
end

---Positional (non-option) arguments of `sub`, up to `--`. Values of the
---options in `M.options[sub]` are not positionals.
---@param rest string[]
---@param sub? string
---@return string[]
function M.positionals(rest, sub)
  return M.scan(sub or "", rest).positionals
end

---The first positional argument: a subcommand's own subcommand.
local function first_sub(rest, sub)
  return M.positionals(rest, sub)[1]
end

---`spec`'s editor route: an explicit `-e`/`--edit` or `--no-edit` decides,
---the last one given winning; then the other `edit_flags`, the
---`no_edit_flags`, and `default_edits`.
local function edit_route(rest, spec, default_edits)
  local toggle =
    M.last_flag(rest, { editor = { "-e", "--edit" }, notify = { "--no-edit" } }, spec.name)
  if toggle then
    return toggle
  end
  if spec.edit_flags and M.has_flag(rest, spec.edit_flags, spec.name) then
    return "editor"
  end
  if spec.no_edit_flags and M.has_flag(rest, spec.no_edit_flags, spec.name) then
    return "notify"
  end
  return default_edits and "editor" or "notify"
end

---@class fugitive.SubcommandSpec
---@field route fugitive.RouteName|fun(rest: string[], spec: fugitive.SubcommandSpec): fugitive.RouteName
---@field edit_flags? string[] flags that make the command open the editor
---@field no_edit_flags? string[] flags that prevent the editor
---@field pager? boolean git pages this command by default
---@field name? string the subcommand (set below), for its `M.options`

---The data table `{subcommand -> {edit_flags, no_edit_flags, pager, route}}`.
---@type table<string, fugitive.SubcommandSpec>
M.subcommands = {
  -- pager commands -> float
  log = { route = "float", pager = true },
  show = { route = "float", pager = true },
  diff = {
    pager = true,
    route = function(rest, spec)
      return M.has_flag(rest, { "--quiet", "--exit-code" }, spec.name) and "notify" or "float"
    end,
  },
  -- a bare `:Git blame` (flags only) opens the side window like upstream;
  -- with paths, revisions or line ranges the output goes to the float
  blame = {
    pager = true,
    route = function(rest, spec)
      if #M.positionals(rest, spec.name) > 0 then
        return "float"
      end
      if
        M.has_flag(
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
      if M.has_flag(rest, spec.edit_flags, spec.name) then
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
      if M.has_flag(rest, mutate, spec.name) then
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
      if M.has_flag(rest, listing, spec.name) or #M.positionals(rest, spec.name) == 0 then
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
      if M.has_flag(rest, { "-d", "--delete", "-v", "--verify" }, spec.name) then
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
      if M.has_flag(rest, listing, spec.name) then
        return "float"
      end
      if #M.positionals(rest, spec.name) == 0 then
        return "float"
      end
      -- annotated tags open the editor unless a message is given
      local annotated = { "-a", "--annotate", "-s", "--sign", "-u", "--local-user" }
      if M.has_flag(rest, annotated, spec.name) or M.has_flag(rest, spec.edit_flags, spec.name) then
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
      if M.has_flag(rest, { "-p", "--patch" }, spec.name) then
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
      if M.has_flag(rest, { "-p", "--patch", "--interactive" }, spec.name) then
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
      return M.has_flag(rest, spec.edit_flags, spec.name) and "editor" or "notify"
    end,
  },

  add = {
    edit_flags = { "-e", "--edit" },
    route = function(rest, spec)
      if M.has_flag(rest, { "-p", "--patch", "-i", "--interactive" }, spec.name) then
        return "terminal"
      end
      return M.has_flag(rest, spec.edit_flags, spec.name) and "editor" or "notify"
    end,
  },
  reset = {
    route = function(rest, spec)
      return M.has_flag(rest, { "-p", "--patch" }, spec.name) and "terminal" or "notify"
    end,
  },
  checkout = {
    route = function(rest, spec)
      return M.has_flag(rest, { "-p", "--patch" }, spec.name) and "terminal" or "notify"
    end,
  },
  restore = {
    route = function(rest, spec)
      return M.has_flag(rest, { "-p", "--patch" }, spec.name) and "terminal" or "notify"
    end,
  },
  clean = {
    route = function(rest, spec)
      return M.has_flag(rest, { "-i", "--interactive" }, spec.name) and "terminal" or "notify"
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
    return M.has_flag(rest, { word }, sub)
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
  local parsed = M.parse(args)
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
      words = body and M.shell_alias_command(body, rest)
      if not words then
        shell_unknown = true
        break
      end
    else
      words = vim.list_extend(vim.deepcopy(expansion), rest)
    end
    local p = M.parse(words)
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
---unless a flag of its `M.options` blockers means it wants no ref.
---@param args string[]
---@return {picker: "refs"|"log"|"push", sub: string, args: string[], set_upstream?: boolean}?
function M.picker_trigger(args)
  local parsed = M.parse(args)
  local sub = parsed.sub
  local picker = sub and pickers[sub]
  if not picker then
    return nil
  end
  local rest = parsed.rest
  local s = M.scan(sub, rest)
  if s.dashdash or #s.positionals > 0 then
    return nil
  end
  local blockers = M.options[sub] and M.options[sub].blockers
  if blockers and M.has_flag(rest, blockers, sub) then
    return nil
  end
  local trigger = { picker = picker, sub = sub, args = args }
  if sub == "rebase" and M.has_flag(rest, { "-i", "--interactive" }, sub) then
    trigger.picker = "log"
  elseif sub == "push" and M.has_flag(rest, { "-u", "--set-upstream" }, sub) then
    -- choose the upstream once; later pushes use it without asking
    trigger.set_upstream = true
  end
  return trigger
end

return M
