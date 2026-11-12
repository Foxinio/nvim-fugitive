---@mod nvim-fugitive.health :checkhealth nvim-fugitive
---
---What fugitive needs, how it is set up, and the git settings that change
---what it does: the first place to look when something doesn't work.

local M = {}

local h = vim.health

---Run git outside fugitive's own `-c` overrides.
---@param args string[]
---@param repo? fugitive.Repo
---@return fugitive.ExecResult
local function git(args, repo)
  if repo then
    return repo:sync(args, { raw = true })
  end
  return require("nvim-fugitive.git.exec").sync(args, { raw = true, cwd = vim.uv.cwd() })
end

local function version_at_least(have, want)
  local a = vim.split(have, ".", { plain = true })
  for i, w in ipairs(want) do
    local n = tonumber(a[i]) or 0
    if n ~= w then
      return n > w
    end
  end
  return true
end

local function requirements()
  h.start("Requirements")
  local v = vim.version()
  local nvim = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. nvim)
  else
    h.error("Neovim " .. nvim .. ": 0.11 or later is required")
  end
  local exe = vim.fn.exepath("git")
  if exe == "" then
    h.error("git not found in $PATH", "Install git 2.40 or later.")
    return false
  end
  local out = (git({ "--version" }).stdout or ""):gsub("\n$", "")
  local version = out:match("(%d+%.%d+[%.%d]*)") or "?"
  if version_at_least(version, { 2, 40 }) then
    h.ok(string.format("git %s (%s)", version, exe))
  else
    h.error(string.format("git %s (%s): 2.40 or later is required", version, exe))
  end
  local os = vim.uv.os_uname().sysname
  if os == "Linux" or os == "Darwin" then
    h.ok("OS: " .. os)
  else
    h.warn("OS: " .. os .. ": only Linux and macOS are supported")
  end
  return true
end

---`maps.summary["X"]`-style path of a config key.
local function path_of(parts)
  local out = ""
  for _, p in ipairs(parts) do
    if type(p) == "string" and p:match("^[%a_][%w_]*$") then
      out = out == "" and p or (out .. "." .. p)
    else
      out = out .. "[" .. vim.inspect(p) .. "]"
    end
  end
  return out
end

---The options that differ from the defaults, one `path = value` each.
---@return string[]
function M.changed(values, defaults)
  local lines = {}
  local function walk(v, d, parts)
    if type(v) == "table" and type(d) == "table" and not vim.islist(v) and not vim.islist(d) then
      local keys = {}
      for k in pairs(v) do
        keys[k] = true
      end
      for k in pairs(d) do
        keys[k] = true
      end
      local sorted = vim.tbl_keys(keys)
      table.sort(sorted, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for _, k in ipairs(sorted) do
        local sub = vim.list_extend(vim.deepcopy(parts), { k })
        walk(v[k], d[k], sub)
      end
    elseif not vim.deep_equal(v, d) then
      local shown = v == nil and "nil (removed)"
        or type(v) == "function" and "<function>"
        or vim.inspect(v, { newline = " ", indent = "" })
      table.insert(lines, path_of(parts) .. " = " .. shown)
    end
  end
  walk(values, defaults, {})
  return lines
end

local function setup()
  h.start("Setup")
  local config = require("nvim-fugitive.config")
  if config.error then
    h.error(
      "the last setup() failed: " .. config.error,
      "Fix the option it names: :help fugitive-config"
    )
  end
  if require("nvim-fugitive")._setup_done then
    h.ok("setup() was called")
  else
    h.info("setup() was not called: the defaults apply (setup is optional)")
  end
  local changed = M.changed(config.get(), config.defaults)
  if #changed == 0 then
    h.info("all options have their default values")
  else
    h.info("changed from the defaults:\n" .. table.concat(changed, "\n"))
  end
end

---@return fugitive.Repo?
local function repository()
  h.start("Repository (current directory)")
  local cwd = vim.uv.cwd() or "."
  local repo = require("nvim-fugitive.git.repo").find(cwd)
  if not repo then
    h.info("not in a git repository: " .. cwd)
  else
    local head = repo:head()
    h.ok(table.concat({
      "work tree: " .. (repo.worktree or "(bare)"),
      "git dir: " .. repo.git_dir,
      "common dir: " .. repo.common_dir,
      "HEAD: " .. ((head and head ~= "") and head or "(detached or unborn)"),
    }, "\n"))
    local watch = require("nvim-fugitive.watch")
    local cfg = require("nvim-fugitive.config").get().watch
    if not cfg.enabled or watch._enabled == false then
      h.info(
        "watching .git is off (watch.enabled): the summary refreshes on focus and after commands"
      )
    elseif watch._watchers[repo.git_dir] then
      h.ok(".git is watched: the summary refreshes when it changes")
    else
      h.info(".git is watched once a summary or file of this repository is open")
    end
  end
  local env = {}
  for name, value in pairs(vim.fn.environ()) do
    if name:match("^GIT_") then
      table.insert(env, name .. "=" .. value)
    end
  end
  table.sort(env)
  if #env > 0 then
    h.warn(
      "git environment variables are set in Neovim:\n" .. table.concat(env, "\n"),
      "They apply to every git command fugitive runs. Unset them unless you mean that\n"
        .. "(e.g. a dotfiles setup with $GIT_DIR and $GIT_WORK_TREE)."
    )
  end
  return repo
end

local function editor()
  h.start("Editor service")
  local service = require("nvim-fugitive.buffers.editor")
  if service.available() then
    h.ok("Neovim server: " .. vim.v.servername)
  else
    h.error(
      "Neovim has no server address (v:servername is empty)",
      "Commit messages and rebase todo lists cannot open in Neovim; start it normally,\n"
        .. "or call vim.fn.serverstart()."
    )
  end
  local ok, shim = pcall(service.shim)
  if ok and vim.fn.executable(shim) == 1 then
    h.ok("editor shim: " .. shim)
  else
    h.error("the editor shim could not be written: " .. tostring(shim))
  end
end

---`key -> {value, origin}[]` from `git config --list --show-origin`.
local function git_config(repo)
  local res = git({ "config", "--list", "--show-origin", "-z" }, repo)
  local cfg = {}
  local fields = vim.split(res.stdout or "", "\0", { plain = true })
  for i = 1, #fields - 1, 2 do
    local origin, entry = fields[i], fields[i + 1]
    local key, value = entry:match("^([^\n]*)\n?(.*)$")
    if key then
      key = key:lower()
      cfg[key] = cfg[key] or {}
      table.insert(cfg[key], { value = value, origin = origin:gsub("^file:", "") })
    end
  end
  return cfg
end

local function config_line(cfg, key)
  local e = cfg[key:lower()]
  if not e then
    return nil
  end
  local last = e[#e]
  return string.format("%s = %s (%s)", key, last.value, last.origin)
end

local function gitconfig(repo)
  h.start("Git configuration" .. (repo and "" or " (global)"))
  local cfg = git_config(repo)
  for _, key in ipairs({ "user.name", "user.email" }) do
    local line = config_line(cfg, key)
    if line then
      h.ok(line)
    else
      h.warn(key .. " is not set", "Commits fail without it: git config --global " .. key .. " ...")
    end
  end
  local editors = {}
  for _, key in ipairs({ "core.editor", "sequence.editor" }) do
    table.insert(editors, config_line(cfg, key))
  end
  if vim.env.GIT_EDITOR then
    table.insert(editors, "$GIT_EDITOR = " .. vim.env.GIT_EDITOR)
  end
  if #editors > 0 then
    h.info(
      table.concat(editors, "\n")
        .. "\nfugitive replaces the editor for the commands it runs (messages open in this Neovim)"
    )
  end
  local gpg = config_line(cfg, "commit.gpgsign")
  if gpg and cfg["commit.gpgsign"][#cfg["commit.gpgsign"]].value == "true" then
    h.info(
      gpg
        .. (config_line(cfg, "gpg.program") and ("\n" .. config_line(cfg, "gpg.program")) or "")
        .. "\nsigning needs a pinentry that works without a terminal (e.g. pinentry-gnome3/mac)"
    )
  end
  local behaviour = {}
  for _, key in ipairs({
    "pull.rebase",
    "push.default",
    "push.autoSetupRemote",
    "merge.conflictStyle",
  }) do
    table.insert(behaviour, config_line(cfg, key))
  end
  if #behaviour > 0 then
    h.info(table.concat(behaviour, "\n"))
  end
  for _, key in ipairs({ "core.pager", "diff.external" }) do
    local line = config_line(cfg, key)
    if line then
      h.info(line .. ": not used; fugitive shows output itself")
    end
  end
  local colours = {}
  for _, key in ipairs({ "color.ui", "color.pager" }) do
    table.insert(colours, config_line(cfg, key))
  end
  if #colours > 0 then
    h.info(
      table.concat(colours, "\n")
        .. "\ncolours in the float need term-color-parser.nvim: :help fugitive-colours"
    )
  end

  local aliases = {}
  for key, e in pairs(cfg) do
    local name = key:match("^alias%.(.+)$")
    if name then
      aliases[name] = e[#e]
    end
  end
  local names = vim.tbl_keys(aliases)
  table.sort(names)
  if #names > 0 then
    h.info(#names .. " git aliases (fugitive routes each like the command it runs)")
    local builtins = {}
    for _, b in
      ipairs(vim.split(git({ "--list-cmds=builtins" }).stdout or "", "\n", { trimempty = true }))
    do
      builtins[b] = true
    end
    for _, name in ipairs(names) do
      if builtins[name] then
        h.warn(
          string.format(
            "alias.%s = %s (%s) is ignored",
            name,
            aliases[name].value,
            aliases[name].origin
          ),
          "git ignores an alias named like a built-in command, and so does fugitive. Use git's\n"
            .. "own config keys, another alias name, or fugitive's `args`: :help fugitive-args"
        )
      end
    end
  end
end

local function installed(module)
  return #vim.api.nvim_get_runtime_file("lua/" .. module .. "/init.lua", false) > 0
    or #vim.api.nvim_get_runtime_file("lua/" .. module .. ".lua", false) > 0
end

local function integrations()
  h.start("Integrations (all optional)")
  local enabled = require("nvim-fugitive.config").get().integrations
  for _, i in ipairs({
    { "telescope.nvim", "telescope", "telescope", "pickers use vim.ui.select" },
    { "overseer.nvim", "overseer", "overseer", "long commands run as plain jobs" },
    { "gitsigns.nvim", "gitsigns", "gitsigns", "hunk maps use fugitive's own hunks" },
  }) do
    local name, module, key, what = i[1], i[2], i[3], i[4]
    if not installed(module) then
      h.info(name .. ": not installed; " .. what)
    elseif enabled[key] == false then
      h.info(name .. ": installed, disabled by integrations." .. key)
    else
      h.ok(name .. ": installed and used")
    end
  end
  if not installed("ansi-colorize") then
    h.info("term-color-parser.nvim: not installed; the float shows git output without colours")
  elseif require("nvim-fugitive.ui.ansi").available() then
    h.ok("term-color-parser.nvim: installed; the float shows git's colours")
  else
    h.warn(
      "term-color-parser.nvim: installed without decoder()",
      "Update it; until then git output is not coloured."
    )
  end
  local notifier = package.loaded["noice"] and "noice.nvim"
    or package.loaded["notify"] and "nvim-notify"
    or nil
  h.info("notifications: " .. (notifier or "vim.notify"))
end

function M.check()
  if not requirements() then
    return
  end
  setup()
  local repo = repository()
  editor()
  gitconfig(repo)
  integrations()
end

return M
