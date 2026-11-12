---@mod nvim-fugitive.cmd.argv Reading `:Git` arguments the way git does.
---
---Splitting a command line into words, unfolding shell aliases, global
---options before the subcommand, and each subcommand's own options
---(`M.options`): which take a value, so clusters (`-uf`) and positionals
---are read right. Flag classification is per subcommand, never global.

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
  local r = { opts = {}, positionals = {}, dashdash = false, after = {} }
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

return M
