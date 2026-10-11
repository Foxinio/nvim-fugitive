---@mod fugitive.git.status `git status --porcelain=v2 -z --branch --show-stash` parser.

local M = {}

---Arguments for the status call this parser understands.
M.args = { "status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all", "--ignore-submodules=none" }

---@class fugitive.StatusEntry
---@field status string one-letter status shown in its section
---@field xy string the raw XY field ("." = unmodified)
---@field path string repo-relative path
---@field orig? string original path for renames/copies
---@field sub string submodule field ("N..." or "S<c><m><u>")
---@field submodule boolean
---@field mode_head? string
---@field mode_index? string
---@field mode_worktree? string
---@field kind "ordinary"|"rename"|"unmerged"|"untracked"|"ignored"

---@class fugitive.Status
---@field oid string? commit id, nil for an unborn branch
---@field head string? branch name, nil when detached
---@field upstream string?
---@field ahead integer?
---@field behind integer?
---@field stash integer
---@field untracked fugitive.StatusEntry[]
---@field unstaged fugitive.StatusEntry[]
---@field staged fugitive.StatusEntry[]
---@field unmerged fugitive.StatusEntry[]
---@field ignored fugitive.StatusEntry[]

---@param out string raw NUL separated output
---@return fugitive.Status
function M.parse(out)
  ---@type fugitive.Status
  local st = { stash = 0, untracked = {}, unstaged = {}, staged = {}, unmerged = {}, ignored = {} }
  local records = vim.split(out, "\0", { plain = true })
  local i = 1
  while i <= #records do
    local rec = records[i]
    local t = rec:sub(1, 1)
    if t == "#" then
      local key, value = rec:match("^# (%S+) (.*)$")
      if key == "branch.oid" then
        st.oid = value ~= "(initial)" and value or nil
      elseif key == "branch.head" then
        st.head = value ~= "(detached)" and value or nil
      elseif key == "branch.upstream" then
        st.upstream = value
      elseif key == "branch.ab" then
        local a, b = value:match("^%+(%d+) %-(%d+)$")
        st.ahead, st.behind = tonumber(a), tonumber(b)
      elseif key == "stash" then
        st.stash = tonumber(value) or 0
      end
    elseif t == "1" or t == "2" then
      -- 1 XY sub mH mI mW hH hI path
      -- 2 XY sub mH mI mW hH hI Xscore path NUL origPath
      local fields = {}
      local n = t == "1" and 8 or 9
      local pos = 3
      for _ = 1, n - 1 do
        local s, e = rec:find(" ", pos, true)
        table.insert(fields, rec:sub(pos, s - 1))
        pos = e + 1
      end
      local path = rec:sub(pos)
      local orig
      if t == "2" then
        i = i + 1
        orig = records[i]
      end
      local xy, sub = fields[1], fields[2]
      local entry = {
        xy = xy,
        path = path,
        orig = orig,
        sub = sub,
        submodule = sub:sub(1, 1) == "S",
        mode_head = fields[3],
        mode_index = fields[4],
        mode_worktree = fields[5],
        kind = t == "1" and "ordinary" or "rename",
      }
      local x, y = xy:sub(1, 1), xy:sub(2, 2)
      if x ~= "." then
        table.insert(st.staged, vim.tbl_extend("force", entry, { status = x }))
      end
      if y ~= "." then
        -- the work tree side of a rename has no "orig"; submodules show
        -- M for a moved commit and ? for dirty content, like upstream
        local status = y
        local flag = sub:match("^S%.*([CMU])")
        if flag then
          status = ({ C = "M", M = "?", U = "?" })[flag]
        end
        table.insert(st.unstaged, vim.tbl_extend("force", entry, { status = status, orig = nil }))
      end
    elseif t == "u" then
      -- u XY sub m1 m2 m3 mW h1 h2 h3 path
      local pos = 3
      local fields = {}
      for _ = 1, 9 do
        local s, e = rec:find(" ", pos, true)
        table.insert(fields, rec:sub(pos, s - 1))
        pos = e + 1
      end
      table.insert(st.unmerged, {
        status = "U",
        xy = fields[1],
        path = rec:sub(pos),
        sub = fields[2],
        submodule = fields[2]:sub(1, 1) == "S",
        mode_worktree = fields[6],
        kind = "unmerged",
      })
    elseif t == "?" then
      table.insert(st.untracked, { status = "?", xy = "??", path = rec:sub(3), sub = "N...", submodule = false, kind = "untracked" })
    elseif t == "!" then
      table.insert(st.ignored, { status = "!", xy = "!!", path = rec:sub(3), sub = "N...", submodule = false, kind = "ignored" })
    end
    i = i + 1
  end
  return st
end

---How an unmerged XY code reads (for messages).
M.unmerged_names = {
  DD = "both deleted",
  AU = "added by us",
  UD = "deleted by them",
  UA = "added by them",
  DU = "deleted by us",
  AA = "both added",
  UU = "both modified",
}

---Display text of an entry: "<status> <path>" (renames as "old -> new").
---@param e fugitive.StatusEntry
---@return string
function M.format(e)
  if e.orig then
    return e.status .. " " .. e.orig .. " -> " .. e.path
  end
  return e.status .. " " .. e.path
end

return M
