---@mod fugitive.object fugitive:// URLs <-> (repo, commit, path).
---
---URL scheme (identical to upstream):
---  fugitive://<git_dir>//<commit>[/<path>]
---where <commit> is a full object id or a stage number 0-3 (0 = index,
---1 = common ancestor, 2 = ours, 3 = theirs). Path components are
---percent-encoded only for `%`, `#`, `?` and control characters.
---
---Object syntax supported in the MVP (§F13, reduced):
---  rev:path   blob/tree at a revision      (HEAD:foo.c, main~2:lib/)
---  :N:path    index stage N                (:0:foo.c, :2:foo.c)
---  :path      index stage 0
---  rev        commit (or tree with a trailing ':')

local M = {}

---Upstream's s:PathUrlEncode.
---@param s string
---@return string
function M.path_encode(s)
  return (s:gsub("[%%#?%c]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

---Upstream's s:UrlEncode (used by :GBrowse).
---@param s string
---@return string
function M.url_encode(s)
  return (s:gsub("[%%#?&;+=\\<> %c]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

---@param s string
---@return string
function M.url_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---@class fugitive.Object
---@field git_dir string
---@field commit string full object id or "0".."3"; "" for the git dir itself
---@field path string? repo-relative path ("" = root tree); nil = the commit itself

---@param git_dir string
---@param commit string
---@param path? string
---@return string
function M.format(git_dir, commit, path)
  local url = "fugitive://" .. M.path_encode(git_dir) .. "//" .. commit
  if path then
    url = url .. "/" .. M.path_encode(path)
  end
  return url
end

---@param url string
---@return fugitive.Object?
function M.parse(url)
  if type(url) ~= "string" then
    return nil
  end
  local rest = url:match("^[Ff][Uu][Gg][Ii][Tt][Ii][Vv][Ee]://(.*)$")
  if not rest then
    return nil
  end
  -- the git dir is everything up to the first "//" that is followed by a
  -- commit or stage, or the end
  local start = 1
  while true do
    local s, e = rest:find("//", start, true)
    if not s then
      return nil
    end
    local dir, tail = rest:sub(1, s - 1), rest:sub(e + 1)
    if dir ~= "" then
      if tail == "" then
        return { git_dir = M.url_decode(dir), commit = "", path = nil }
      end
      local commit, path = tail:match("^(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x*)(.*)$")
      if not commit then
        commit, path = tail:match("^([0-3])(.*)$")
      end
      if commit and (path == "" or path:sub(1, 1) == "/") and not path:find("[?#]") then
        return {
          git_dir = M.url_decode(dir),
          commit = commit,
          path = path ~= "" and M.url_decode(path:sub(2)) or nil,
        }
      end
    end
    start = e + 1
  end
end

---@class fugitive.Rev
---@field kind "stage"|"rev"|"commit"
---@field rev string? revision part ("HEAD", "main~2", …); nil for stages
---@field stage integer? index stage for kind == "stage"
---@field path string? repo-relative path ("" for the root tree)

---Parse the reduced object syntax. Returns nil for unsupported forms
---(`!`, `@` alone, `:/msg`, …) which are backlog.
---@param spec string
---@return fugitive.Rev?
function M.parse_rev(spec)
  if spec == nil or spec == "" then
    return nil
  end
  local stage, path = spec:match("^:([0-3]):(.*)$")
  if stage then
    return { kind = "stage", stage = tonumber(stage), path = path }
  end
  if spec:match("^:/") then
    return nil -- :/message search: backlog
  end
  path = spec:match("^:(.+)$")
  if path then
    return { kind = "stage", stage = 0, path = path }
  end
  -- rev:path – the first ':' not inside a "@{...}" or "^{...}" group
  local depth, colon = 0, nil
  for i = 1, #spec do
    local c = spec:sub(i, i)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
    elseif c == ":" and depth == 0 then
      colon = i
      break
    end
  end
  if colon then
    return { kind = "rev", rev = spec:sub(1, colon - 1), path = spec:sub(colon + 1) }
  end
  if spec == "!" or spec:match("^!") then
    return nil
  end
  return { kind = "commit", rev = spec }
end

---Resolve an object spec to a fugitive:// URL, relative paths being taken
---relative to `cwd_rel` (repo-relative directory, "" = root).
---@param repo fugitive.Repo
---@param spec string
---@param cwd_rel? string
---@return string? url, string? err
function M.resolve(repo, spec, cwd_rel)
  local r = M.parse_rev(spec)
  if not r then
    return nil, "unsupported object: " .. spec
  end
  local function fix_path(p)
    if p:sub(1, 2) == "./" or p:sub(1, 3) == "../" then
      local base = cwd_rel and cwd_rel ~= "" and (cwd_rel .. "/") or ""
      p = vim.fs.normalize(base .. p)
      p = p:gsub("^%./", "")
      if p == "." then
        p = ""
      end
    end
    return p
  end
  if r.kind == "stage" then
    return M.format(repo.git_dir, tostring(r.stage), fix_path(r.path))
  end
  local rev = r.rev == "" and "HEAD" or r.rev
  if r.kind == "commit" then
    local sha = repo:rev_parse(rev .. "^{commit}") or repo:rev_parse(rev)
    if not sha then
      return nil, "invalid object: " .. spec
    end
    return M.format(repo.git_dir, sha)
  end
  local sha = repo:rev_parse(rev .. "^{commit}")
  if not sha then
    return nil, "invalid revision: " .. rev
  end
  return M.format(repo.git_dir, sha, fix_path(r.path))
end

---The git object name addressed by a parsed URL (`sha:path`, `:N:path`, `sha`).
---@param obj fugitive.Object
---@return string
function M.git_name(obj)
  if obj.commit:match("^[0-3]$") then
    return ":" .. obj.commit .. ":" .. (obj.path or "")
  end
  if obj.path == nil then
    return obj.commit
  end
  return obj.commit .. ":" .. obj.path
end

---Human readable form of a URL for statuslines/messages.
---@param obj fugitive.Object
---@return string
function M.describe(obj)
  if obj.commit:match("^[0-3]$") then
    return ":" .. obj.commit .. ":" .. (obj.path or "")
  end
  local short = obj.commit:sub(1, 7)
  if obj.path == nil then
    return short
  end
  return short .. ":" .. obj.path
end

return M
