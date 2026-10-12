---@mod nvim-fugitive.integrations.browse Built-in :GBrowse URL providers (§5.4).
---
---Providers receive upstream's options dict (see fugitive.cmd.browse) plus
---the parsed remote (`host`, `repo_path`, `base`) and return a URL or nil.
---Hosts map to providers by name; users add self-hosted instances with
---`setup({ browse = { hosts = { ["git.corp"] = "gitlab" } } })` and custom
---providers with `browse.providers = { name = function(opts) ... end }`.

local M = {}

---Default host -> provider table.
M.hosts = {
  ["github.com"] = "github",
  ["gitlab.com"] = "gitlab",
  ["bitbucket.org"] = "bitbucket",
  ["codeberg.org"] = "gitea",
  ["gitea.com"] = "gitea",
  ["git.sr.ht"] = "sourcehut",
}

---Parse a remote URL into host and repository path.
---@param url string
---@return {host: string, path: string, scheme: string}?
function M.parse_remote(url)
  if not url or url == "" then
    return nil
  end
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  local host, path
  if scheme then
    rest = rest:gsub("^[^@/]*@", "") -- user@
    host, path = rest:match("^([^/]+)/(.*)$")
    if host then
      host = host:gsub(":%d+$", "") -- port
    end
  else
    -- scp-like: [user@]host:path
    host, path = url:match("^[^@/:]*@?([^@/:]+):(.*)$")
    scheme = "ssh"
  end
  if not host or not path then
    return nil
  end
  path = path:gsub("%.git/?$", ""):gsub("/+$", ""):gsub("^/+", "")
  return { host = host:lower(), path = path, scheme = scheme }
end

local function anchor_github(o)
  if o.line2 > 0 and o.line1 > 0 then
    if o.line1 == o.line2 then
      return "#L" .. o.line1
    end
    return "#L" .. o.line1 .. "-L" .. o.line2
  end
  return ""
end

---Shared handling of ref/root paths; returns kind, name.
local function ref_kind(o)
  local heads = o.path:match("^%.git/refs/heads/(.+)$")
  if heads then
    return "branch", heads
  end
  local remote = o.path:match("^%.git/refs/remotes/[^/]+/(.+)$")
  if remote then
    return "branch", remote
  end
  local tag = o.path:match("^%.git/refs/tags/(.+)$")
  if tag then
    return "tag", tag
  end
  if o.path:match("^%.git/") then
    return "root"
  end
end

---@type table<string, fun(o: table, base: string): string?>
M.providers = {
  github = function(o, base)
    local kind, name = ref_kind(o)
    if kind == "root" then
      return base
    elseif kind == "branch" then
      return base .. "/commits/" .. name
    elseif kind == "tag" then
      return base .. "/releases/tag/" .. name
    end
    if o.type == "commit" or (o.path == "" and o.type ~= "tree") then
      return base .. "/commit/" .. o.commit
    elseif o.type == "tree" then
      return base .. "/tree/" .. o.commit .. "/" .. o.path:gsub("/$", "")
    end
    return base .. "/blob/" .. o.commit .. "/" .. o.path .. anchor_github(o)
  end,
  gitlab = function(o, base)
    local kind, name = ref_kind(o)
    if kind == "root" then
      return base
    elseif kind == "branch" then
      return base .. "/-/commits/" .. name
    elseif kind == "tag" then
      return base .. "/-/tags/" .. name
    end
    if o.type == "commit" or (o.path == "" and o.type ~= "tree") then
      return base .. "/-/commit/" .. o.commit
    elseif o.type == "tree" then
      return base .. "/-/tree/" .. o.commit .. "/" .. o.path:gsub("/$", "")
    end
    local anchor = ""
    if o.line1 > 0 then
      anchor = o.line1 == o.line2 and ("#L" .. o.line1) or ("#L" .. o.line1 .. "-" .. o.line2)
    end
    return base .. "/-/blob/" .. o.commit .. "/" .. o.path .. anchor
  end,
  bitbucket = function(o, base)
    local kind, name = ref_kind(o)
    if kind == "root" then
      return base
    elseif kind == "branch" then
      return base .. "/branch/" .. name
    elseif kind == "tag" then
      return base .. "/src/" .. name
    end
    if o.type == "commit" or (o.path == "" and o.type ~= "tree") then
      return base .. "/commits/" .. o.commit
    end
    local anchor = ""
    if o.line1 > 0 then
      anchor = o.line1 == o.line2 and ("#lines-" .. o.line1)
        or ("#lines-" .. o.line1 .. ":" .. o.line2)
    end
    return base .. "/src/" .. o.commit .. "/" .. o.path .. anchor
  end,
  gitea = function(o, base)
    local kind, name = ref_kind(o)
    if kind == "root" then
      return base
    elseif kind == "branch" then
      return base .. "/src/branch/" .. name
    elseif kind == "tag" then
      return base .. "/src/tag/" .. name
    end
    if o.type == "commit" or (o.path == "" and o.type ~= "tree") then
      return base .. "/commit/" .. o.commit
    end
    local sub = o.commit:match("^%x+$") and #o.commit >= 40 and "commit" or "branch"
    return base
      .. "/src/"
      .. sub
      .. "/"
      .. o.commit
      .. "/"
      .. o.path:gsub("/$", "")
      .. anchor_github(o)
  end,
  sourcehut = function(o, base)
    local kind, name = ref_kind(o)
    if kind == "root" then
      return base
    elseif kind == "branch" then
      return base .. "/log/" .. name
    elseif kind == "tag" then
      return base .. "/refs/" .. name
    end
    if o.type == "commit" or (o.path == "" and o.type ~= "tree") then
      return base .. "/commit/" .. o.commit
    end
    local anchor = ""
    if o.line1 > 0 then
      anchor = o.line1 == o.line2 and ("#L" .. o.line1) or ("#L" .. o.line1 .. "-" .. o.line2)
    end
    return base .. "/tree/" .. o.commit .. "/item/" .. o.path:gsub("/$", "") .. anchor
  end,
}
M.providers.forgejo = M.providers.gitea
M.providers.codeberg = M.providers.gitea

---URL for upstream's options dict, or nil when no provider matches.
---@param opts table
---@return string?
function M.url(opts)
  local remote = M.parse_remote(opts.remote)
  if not remote then
    return nil
  end
  local cfg = require("nvim-fugitive.config").get().browse
  local name = cfg.hosts[remote.host] or M.hosts[remote.host]
  if not name then
    -- subdomain match: e.g. gitlab.example.com configured as example.com
    for host, provider in pairs(cfg.hosts) do
      if remote.host:sub(-#host - 1) == "." .. host then
        name = provider
        break
      end
    end
  end
  if not name then
    return nil
  end
  local provider = cfg.providers[name] or M.providers[name]
  if not provider then
    return nil
  end
  local base = "https://" .. remote.host .. "/" .. remote.path
  local o =
    vim.tbl_extend("force", opts, { host = remote.host, repo_path = remote.path, base = base })
  return provider(o, base)
end

return M
