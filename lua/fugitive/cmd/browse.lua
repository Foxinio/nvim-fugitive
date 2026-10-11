---@mod fugitive.cmd.browse :GBrowse and the URL provider API (F21, §5.4).
---
---The options dict passed to providers is built exactly like upstream's
---`fugitive#BrowseCommand`, so existing Vimscript handlers in
---`g:fugitive_browse_handlers` (vim-rhubarb, fugitive-gitlab, …) keep
---working. They run first; built-in Lua providers are the fallback.

local object = require("fugitive.object")
local notify = require("fugitive.ui.notify")

local M = {}

local url_encode = object.url_encode

---@class fugitive.BrowseOpts
---@field git_dir string
---@field repo {git_dir: string}
---@field remote string
---@field remote_name string
---@field commit string
---@field path string
---@field type string
---@field line1 integer
---@field line2 integer

local function chomp(repo, args)
  local res = repo:sync(args)
  if res.code ~= 0 then
    return nil
  end
  return (res.stdout:gsub("\n.*$", ""))
end

---Upstream's s:RemoteDefault.
local function remote_default(repo)
  local head = repo:head() or ""
  local remote = head ~= "" and (repo:config("branch." .. head .. ".remote") or "") or ""
  local i = 10
  while remote == "." and i > 0 do
    head = (repo:config("branch." .. head .. ".merge") or ""):match("refs/heads/(.*)") or ""
    remote = head ~= "" and (repo:config("branch." .. head .. ".remote") or "") or ""
    i = i - 1
  end
  if remote == "" or remote == "." then
    return "origin"
  end
  return remote
end

---URL of a remote with insteadOf rewriting applied (or "").
local function remote_url(repo, remote)
  if remote == "" then
    return ""
  end
  if not repo:config("remote." .. remote .. ".url") then
    return ""
  end
  return chomp(repo, { "ls-remote", "--get-url", remote }) or ""
end

---Upstream's s:Owner for fugitive:// buffers of this repo.
local function owner(repo, bufname)
  local obj = object.parse(bufname)
  if not obj or obj.git_dir ~= repo.git_dir then
    return ""
  end
  if obj.commit:match("^%x+$") and #obj.commit >= 40 then
    return obj.commit
  elseif obj.commit == "2" then
    return "@"
  elseif obj.commit == "0" then
    return ""
  end
  return ""
end

---Map lines of the local file to the merge-base commit with `git blame`
---(upstream behaviour for line ranges).
local function blame_lines(repo, commit, path, line1, line2, buf)
  local list = vim.fn.tempname()
  local fd = assert(io.open(list, "wb"))
  fd:write(commit .. "\n\n")
  fd:close()
  local args = { "-c", "blame.coloring=none", "blame", "-L", line1 .. "," .. line2, "-S", list, "-s", "--show-number" }
  local contents
  if buf and vim.bo[buf].modified then
    contents = vim.fn.tempname()
    vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), contents)
    vim.list_extend(args, { "--contents", contents })
  end
  vim.list_extend(args, { "./" .. path })
  local res = repo:sync(args)
  os.remove(list)
  if contents then
    os.remove(contents)
  end
  if res.code ~= 0 then
    return line1, line2
  end
  local lines = vim.split((res.stdout:gsub("\n$", "")), "\n", { plain = true })
  local first = lines[1] and lines[1]:match("^%^%x+%s+(%d+)%s")
  local last = lines[#lines] and lines[#lines]:match("^%^%x+%s+(%d+)%s")
  if first and last then
    return tonumber(first), tonumber(last)
  end
  error("fugitive: can't browse to unpushed change", 0)
end

---@class fugitive.BrowseRequest
---@field arg string
---@field count integer -1 without range, else the last line (0 for :0GBrowse)
---@field line1 integer
---@field range integer number of range items given (0, 1, 2)
---@field buf integer

---Build upstream's options dict.
---@param req fugitive.BrowseRequest
---@return fugitive.BrowseOpts|string|nil opts (a string is a direct URL), string? err
function M.build(req)
  local repo = require("fugitive.git.repo").for_buf(req.buf)
  if not repo then
    return nil, "not a git repository"
  end
  local arg = req.arg or ""
  local remote
  local rm = arg:match("^%+%+[Gg]?i?t?[Rr]emote=(%S+)")
  if rm then
    remote = rm
    arg = arg:match("%s(%S.*)$") or ""
  end
  local rev
  if not remote then
    -- trailing @remote / !remote
    local r = arg:match("[!@](%a[%w_-]*)$") or arg:match("[!@](%.git)$") or arg:match("[!@](%.)$")
      or arg:match("[!@](%.?/.*)$") or arg:match("[!@](%a[%w_-]*://.-)$")
    if r and not arg:match("@{") then
      remote = r
      rev = arg:sub(1, #arg - #r - 1)
    else
      remote = ""
      rev = arg
    end
  else
    rev = arg
  end
  local expanded = rev
  if expanded == "%" then
    expanded = ""
  end
  if expanded:match("^%a%a+:[/\\][/\\]") and not expanded:match("^fugitive:") then
    return expanded
  end
  -- a bare remote name
  if remote == "" and expanded:match("^[^-./:^~][^:^~]*$") and repo:config("remote." .. expanded .. ".url") then
    remote = expanded
    expanded = ""
  end

  local bufname = vim.bo[req.buf].buftype:match("^nofile$") and "" or vim.api.nvim_buf_get_name(req.buf)
  local full -- {kind = "object", obj} | {kind = "worktree", path} | {kind = "gitdir", rel}
  if expanded == "" then
    local obj = object.parse(bufname)
    if obj and obj.git_dir == repo.git_dir then
      if obj.commit == "" then
        full = { kind = "gitdir", rel = "index" }
      else
        full = { kind = "object", obj = obj }
        expanded = object.git_name(obj)
        if obj.commit:match("^[0-3]$") then
          expanded = ":" .. (obj.path or "")
        end
      end
    elseif bufname ~= "" then
      local rel = repo:rel(bufname)
      if rel then
        full = { kind = "worktree", rel = rel, abs = bufname }
      else
        local gd = repo.git_dir .. "/"
        if bufname:sub(1, #gd) == gd then
          full = { kind = "gitdir", rel = bufname:sub(#gd + 1) }
        end
      end
    end
    if not full then
      full = { kind = "worktree", rel = "", abs = repo.worktree }
    end
  else
    local r = object.parse_rev(expanded)
    if r and (r.kind == "rev" or r.kind == "commit" or r.kind == "stage") then
      local url
      if r.kind == "commit" then
        local sha = repo:rev_parse(expanded)
        if sha then
          url = object.format(repo.git_dir, sha)
        end
      else
        url = object.resolve(repo, expanded)
      end
      if url then
        full = { kind = "object", obj = object.parse(url) }
      end
    end
    if not full then
      -- a work tree path
      local abs = expanded:sub(1, 1) == "/" and expanded or repo:abs(expanded)
      full = { kind = "worktree", rel = repo:rel(abs) or expanded, abs = abs }
    end
  end

  local commit, ref, path, typ = "", "", "", ""
  local forbid_ref_as_commit = false
  if full.kind == "object" then
    local obj = full.obj
    commit = obj.commit
    path = obj.path
    if commit:match("^%d?$") then
      commit = ""
      typ = (path == nil or path == "") and "tree" or "blob"
    else
      -- upstream: matchlist(expanded, '^\(@{\@!\|[^:~^@]\+\)\(:\%(//\)\@!\|[~^@]\|$\)')
      local m_ref, m_sep
      do
        local a, b = expanded:match("^([^:~^@]+)([:~^@]?)")
        if a then
          m_ref, m_sep = a, b
          local after = expanded:sub(#a + 1)
          if after:sub(1, 3) == "://" then
            m_ref = nil
          end
        elseif expanded:match("^@") and not expanded:match("^@{") then
          m_ref, m_sep = "@", expanded:sub(2, 2)
        end
      end
      ref = m_ref or ""
      forbid_ref_as_commit = ref == "" or ref == "@" or not (m_sep == ":" or m_sep == "" or m_sep == nil)
      if (path == nil or path == "") and not forbid_ref_as_commit then
        typ = "ref"
      else
        local name = commit .. ((path and path ~= "") and (":" .. path) or "")
        typ = chomp(repo, { "cat-file", "-t", name }) or ((path == nil or path == "") and "commit" or "blob")
      end
    end
    path = path or ""
  elseif full.kind == "worktree" then
    path = full.rel
    if path == "" or vim.fn.isdirectory(full.abs) == 1 then
      typ = "tree"
    else
      typ = "blob"
    end
  else
    path = ".git/" .. full.rel
    typ = ""
  end

  if path:match("^%.git/") then
    ref = path:match("^%.git/(refs/[^/]+/[^/].*)$") or path:match("^%.git/(%w*HEAD)$") or ""
    typ = ref == "" and "root" or "ref"
    path = ""
  end
  if ref == "" or ref == "HEAD" or ref == "@" then
    local content = io.open(repo.git_dir .. "/HEAD", "rb")
    local head = content and content:read("*l") or ""
    if content then
      content:close()
    end
    ref = head:match("^ref: (.*)$") or head
  end
  if ref:match("^%x+$") and #ref >= 40 then
    ref = ""
  elseif ref ~= "" and not ref:match("^refs/") then
    ref = chomp(repo, { "rev-parse", "--symbolic-full-name", ref }) or ""
    if not ref:match("^refs/") then
      ref = ""
    end
  end

  local merge = ""
  if remote ~= "" and (ref:match("^refs/remotes/[^/]+/[^/]") or ref:match("^refs/heads/[^/]")) then
    merge = ref:match("^refs/heads/(.+)$") or ref:match("^refs/remotes/[^/]+/(.+)$")
    ref = "refs/heads/" .. merge
  elseif ref:match("^refs/remotes/[^/]+/[^/]") then
    remote = ref:match("^refs/remotes/([^/]+)")
    merge = ref:match("^refs/remotes/[^/]+/(.+)$")
    ref = "refs/heads/" .. merge
  elseif ref:match("^refs/heads/[^/]") then
    merge = ref:sub(12)
    local r = repo:config("branch." .. merge .. ".remote") or ""
    local m = (repo:config("branch." .. merge .. ".merge") or ""):sub(12)
    if r == "." and m ~= "" then
      local r2 = repo:config("branch." .. m .. ".remote") or ""
      if not (r2 == "" or r2 == ".") then
        r = r2
        m = (repo:config("branch." .. m .. ".merge") or ""):sub(12)
      end
    end
    if not (r == "" or r == ".") then
      remote = r
    end
    if remote ~= "" then
      local remote_ref = "refs/remotes/" .. remote .. "/" .. merge
      if
        repo:config("push.default") == "upstream"
        or (not vim.uv.fs_stat(repo:git_path(remote_ref)) and not repo:rev_parse(remote_ref))
      then
        merge = m
        ref = "refs/heads/" .. merge
      end
    end
  end

  if remote == "" or remote == "." then
    remote = remote_default(repo)
  end
  local provider_ref
  if merge == "" or remote == "" then
    provider_ref = ref
  else
    provider_ref = "refs/remotes/" .. remote .. "/" .. merge
  end
  if forbid_ref_as_commit or req.count >= 0 then
    ref = ""
    if typ == "ref" then
      typ = "commit"
    end
  elseif typ == "ref" and (ref:match("^refs/heads/[^/]") or ref:match("^refs/tags/[^/]")) then
    commit = ref:match("^refs/[^/]+/(.*)$")
  end

  local line1 = (req.count > 0 and typ == "blob") and req.line1 or 0
  local line2 = (req.count > 0 and typ == "blob") and req.count or 0
  if commit == "" and (typ == "tree" or typ == "blob") then
    if req.count < 0 then
      commit = ref:match("^refs/heads/(.*)$") or ref:match("^refs/tags/(.*)$") or ""
    elseif provider_ref ~= "" then
      local own = owner(repo, bufname)
      commit = chomp(repo, { "merge-base", provider_ref, own == "" and "@" or own, "--" }) or ""
      if line2 > 0 and arg == "" and commit:match("^%x+$") and #commit >= 40 and typ == "blob" then
        line1, line2 = blame_lines(repo, commit, path, line1, line2, req.buf)
      end
    end
    if commit == "" then
      commit = repo:rev_parse(ref == "" and "HEAD" or ref) or ""
    end
  end

  local rurl = remote:find(":", 1, true) and remote or remote_url(repo, remote)
  local raw = rurl == "" and remote or rurl
  ---@type fugitive.BrowseOpts
  local opts = {
    git_dir = repo.git_dir,
    repo = { git_dir = repo.git_dir },
    remote = raw,
    remote_name = remote,
    commit = url_encode(commit),
    path = (url_encode(path):gsub("%%20", " ")),
    type = typ,
    line1 = line1,
    line2 = line2,
  }
  if path == "" then
    if typ == "ref" and ref:match("^refs/") then
      opts.path = ".git/" .. url_encode(ref)
      opts.type = ""
    elseif typ == "root" then
      opts.path = ".git/index"
      opts.type = ""
    end
  elseif typ == "tree" then
    opts.path = opts.path:gsub("/?$", "/")
  end
  return opts, nil, rurl
end

---Call `g:fugitive_browse_handlers`, each with a fresh copy of `opts`.
---@param opts fugitive.BrowseOpts
---@return string?
function M.call_vim_handlers(opts)
  local n = vim.fn.eval("len(get(g:, 'fugitive_browse_handlers', []))")
  for i = 0, n - 1 do
    vim.g._fugitive_browse_opts = opts
    local ok, url = pcall(vim.fn.eval, string.format("call(g:fugitive_browse_handlers[%d], [copy(g:_fugitive_browse_opts)])", i))
    vim.g._fugitive_browse_opts = nil
    if ok and type(url) == "string" and url:find("://", 1, true) then
      return url
    end
  end
end

---Open (or yank) a URL like upstream's s:BrowserOpen.
---@param url string
---@param yank boolean
function M.open_url(url, yank)
  local main, query, anchor = url:match("^([^#?]*)(%??[^#]*)(#?.*)$")
  url = main .. query:gsub(" ", "+") .. anchor
  url = url:gsub('[ <>|"]', function(c)
    return string.format("%%%02X", c:byte())
  end)
  if yank then
    pcall(vim.fn.setreg, "+", url)
    vim.fn.setreg('"', url)
    notify.info(url)
    return url
  end
  notify.info(url)
  local ok, err = pcall(vim.ui.open, url)
  if not ok then
    notify.error("could not open " .. url .. ": " .. tostring(err))
  end
  return url
end

---@param req fugitive.BrowseRequest
---@param yank boolean
---@return string? url
function M.browse(req, yank)
  local ok, opts, err, rurl = pcall(M.build, req)
  if not ok then
    notify.error((tostring(opts):gsub("^fugitive: ", "")))
    return
  end
  if not opts then
    notify.error(err)
    return
  end
  if type(opts) == "string" then
    return M.open_url(opts, yank)
  end
  local url = M.call_vim_handlers(opts) or require("fugitive.integrations.browse").url(opts)
  if url then
    return M.open_url(url, yank)
  end
  if rurl and rurl ~= "" then
    notify.error("no GBrowse handler installed for '" .. rurl .. "'")
  else
    notify.error("could not find remote named '" .. opts.remote_name .. "'")
  end
end

---:GBrowse user command
function M.command(cmd)
  local count
  if cmd.range == 0 then
    count = -1
  elseif cmd.range == 1 then
    count = cmd.line1 -- :5GBrowse / :0GBrowse
  else
    count = cmd.line2
  end
  return M.browse({
    arg = vim.trim(cmd.args or ""),
    count = count,
    line1 = cmd.line1,
    range = cmd.range,
    buf = vim.api.nvim_get_current_buf(),
  }, cmd.bang)
end

return M
