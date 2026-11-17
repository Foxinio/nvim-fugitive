---@mod nvim-fugitive.watch Filesystem watcher (vim.uv fs_event, debounced).
---
---Watches the per-worktree git dir (HEAD, index, rebase state) and the
---common dir (refs, packed-refs, stash). Changes trigger `User
---FugitiveChanged` for that repo after a debounce.

local uv = vim.uv
local M = {}

---@class fugitive.Watcher
---@field handles {path: string, handle: uv.uv_fs_event_t}[]
---@field timer uv.uv_timer_t?
---@field refs integer
---@field fire fun()?
---@field seen string? the state fugitive last acted on (fingerprint)

---@type table<string, fugitive.Watcher>
M._watchers = {}
M._enabled = true

local function config()
  return require("nvim-fugitive.config").get().watch
end

local ignored = {
  ["objects"] = true,
  ["fugitive"] = true,
  ["FETCH_HEAD"] = false,
}

local function interesting(filename)
  if not filename then
    return true
  end
  if filename:match("%.lock$") or ignored[filename] then
    return false
  end
  if filename:match("^tmp_") or filename:match("^%.") then
    return false
  end
  return true
end

local function dirs_for(repo)
  local dirs = { repo.git_dir }
  local seen = { [repo.git_dir] = true }
  local function add(d)
    if not seen[d] and uv.fs_stat(d) then
      seen[d] = true
      table.insert(dirs, d)
    end
  end
  add(repo.common_dir)
  add(repo.common_dir .. "/refs")
  add(repo.common_dir .. "/refs/heads")
  add(repo.common_dir .. "/refs/tags")
  add(repo.common_dir .. "/refs/remotes")
  local remotes = uv.fs_scandir(repo.common_dir .. "/refs/remotes")
  if remotes then
    while true do
      local name, t = uv.fs_scandir_next(remotes)
      if not name then
        break
      end
      if t == "directory" then
        add(repo.common_dir .. "/refs/remotes/" .. name)
      end
    end
  end
  add(repo.git_dir .. "/rebase-merge")
  add(repo.git_dir .. "/rebase-apply")
  return dirs
end

---What the watcher watches, as a string that changes when any of it does:
---size and mtime of the index, HEAD, packed-refs and the merge/rebase heads,
---and the mtime of every watched directory (a ref written by git appears
---through a rename, which changes its directory).
---@param repo fugitive.Repo
---@param w fugitive.Watcher
---@return string
local function fingerprint(repo, w)
  local parts = {}
  local function add(path)
    local st = uv.fs_stat(path)
    if st then
      table.insert(parts, string.format("%s:%d.%d:%d", path, st.mtime.sec, st.mtime.nsec, st.size))
    end
  end
  for _, f in ipairs({ "index", "HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD" }) do
    add(repo.git_dir .. "/" .. f)
  end
  add(repo.common_dir .. "/packed-refs")
  for _, h in ipairs(w.handles) do
    add(h.path)
  end
  return table.concat(parts, "\n")
end

---Fugitive has acted on the repo as it is now (a command finished, a
---refresh started): what the watcher sees next is only its own echo unless
---something changes again, so a later fire with the same fingerprint is
---dropped.
---@param repo fugitive.Repo
function M.settle(repo)
  local w = M._watchers[repo.git_dir]
  if w then
    w.seen = fingerprint(repo, w)
  end
end

---Start watching a repo (ref-counted).
---@param repo fugitive.Repo
function M.watch(repo)
  if not M._enabled or not config().enabled then
    return
  end
  local w = M._watchers[repo.git_dir]
  if w then
    w.refs = w.refs + 1
    return
  end
  w = { handles = {}, refs = 1 }
  M._watchers[repo.git_dir] = w
  local function fire()
    if not w.timer then
      w.timer = uv.new_timer()
    end
    w.timer:stop()
    w.timer:start(config().debounce, 0, function()
      vim.schedule(function()
        if M._watchers[repo.git_dir] ~= w then
          return
        end
        -- new remotes/rebase dirs may have appeared: rewatch lazily
        M._rewatch(repo, w)
        -- the echo of fugitive's own change (git rewrote the index during a
        -- command or a refresh fugitive already acted on): nothing to do
        if w.seen and fingerprint(repo, w) == w.seen then
          return
        end
        require("nvim-fugitive").changed(repo)
      end)
    end)
  end
  w.fire = fire
  M._rewatch(repo, w)
end

function M._rewatch(repo, w)
  local current = {}
  for _, h in ipairs(w.handles) do
    current[h.path] = h
  end
  local handles = {}
  for _, dir in ipairs(dirs_for(repo)) do
    if current[dir] then
      table.insert(handles, current[dir])
      current[dir] = nil
    else
      local h = uv.new_fs_event()
      if h then
        local ok = h:start(dir, {}, function(err, filename)
          if not err and interesting(filename) then
            w.fire()
          end
        end)
        if ok then
          table.insert(handles, { path = dir, handle = h })
        else
          h:close()
        end
      end
    end
  end
  for _, h in pairs(current) do
    h.handle:stop()
    h.handle:close()
  end
  w.handles = handles
end

---Stop watching (ref-counted).
---@param git_dir string
function M.unwatch(git_dir)
  local w = M._watchers[git_dir]
  if not w then
    return
  end
  w.refs = w.refs - 1
  if w.refs > 0 then
    return
  end
  for _, h in ipairs(w.handles) do
    h.handle:stop()
    h.handle:close()
  end
  if w.timer then
    w.timer:stop()
    w.timer:close()
  end
  M._watchers[git_dir] = nil
end

---Globally enable/disable watching.
---@param on boolean
function M.enable(on)
  M._enabled = on
  if not on then
    for git_dir, w in pairs(M._watchers) do
      w.refs = 1
      M.unwatch(git_dir)
    end
  end
end

return M
