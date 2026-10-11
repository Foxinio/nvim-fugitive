---@mod fugitive.buffers.summary.snapshot Gather everything the summary shows.
---
---Written against an abstract `run(args) -> ExecResult` so the same code
---serves the synchronous first read (BufReadCmd) and async refreshes
---(plenary.async + exec.await).

local status_mod = require("fugitive.git.status")
local diff_mod = require("fugitive.git.diff")

local M = {}

---@class fugitive.LogEntry
---@field commit string abbreviated id
---@field subject string

---@class fugitive.LogSection
---@field label string full heading text without the count
---@field key "Unpushed"|"Unpulled"
---@field entries fugitive.LogEntry[]
---@field overflow boolean

---@class fugitive.RebaseEntry
---@field status string pick/reword/…/done
---@field commit string
---@field subject string

---@class fugitive.Snapshot
---@field status fugitive.Status
---@field error string?
---@field head string displayed head (branch or abbreviated id)
---@field headers {key: string, value: string}[]
---@field rebasing {label: string, entries: fugitive.RebaseEntry[]}?
---@field sequencing {label: string, entries: fugitive.RebaseEntry[]}?
---@field logs fugitive.LogSection[]
---@field stashes {ref: string, subject: string}[]
---@field diffs table<string, table<string, fugitive.FileDiff>> section -> path -> diff
---@field discarded table? latest discard journal entry of this session

local function lines_of(res)
  if not res or res.code ~= 0 then
    return {}
  end
  local out = res.stdout:gsub("\n$", "")
  if out == "" then
    return {}
  end
  return vim.split(out, "\n", { plain = true })
end

local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

local function falsy(v)
  return v ~= nil and (v == "false" or v == "no" or v == "off" or v == "0" or v == "")
end

---Query `limit` commits of a range (upstream's s:QueryLog).
local function query_log(run, range, limit)
  local args = { "log", "-n", tostring(limit), "--pretty=format:%h%x09%s" }
  vim.list_extend(args, type(range) == "table" and range or { range })
  table.insert(args, "--")
  local res = run(args)
  local entries = {}
  for _, l in ipairs(lines_of(res)) do
    local c, s = l:match("^(%S+)\t(.*)$")
    if c then
      table.insert(entries, { commit = c, subject = s })
    end
  end
  local overflow = false
  if #entries == limit then
    table.remove(entries)
    overflow = true
  end
  return { entries = entries, overflow = overflow, error = res.code ~= 0 }
end

local function short_ref(ref)
  return (ref:gsub("^refs/%w+/", ""))
end

local rebase_abbrevs = {
  p = "pick",
  r = "reword",
  e = "edit",
  s = "squash",
  f = "fixup",
  x = "exec",
  d = "drop",
  l = "label",
  t = "reset",
  m = "merge",
  b = "break",
}

local function parse_todo_lines(lines, len)
  local out = {}
  for _, line in ipairs(lines) do
    local cmd, commit, subject = line:match("^(%l+)%s+(%x%x%x%x+)%s+(.*)$")
    if cmd and not (cmd:match("exec") or cmd:match("merge") or cmd:match("label")) then
      table.insert(out, {
        status = rebase_abbrevs[cmd] or cmd,
        commit = len and commit:sub(1, len) or commit,
        subject = subject,
      })
    end
  end
  return out
end

local function file_lines(path)
  local content = read_file(path)
  if not content then
    return nil
  end
  return vim.split((content:gsub("\n$", "")), "\n", { plain = true })
end

---Rebase state from <git_dir>/rebase-merge or rebase-apply (upstream rules).
local function rebase_state(repo, short_len)
  local dir
  for _, d in ipairs({ "rebase-merge", "rebase-apply" }) do
    if vim.uv.fs_stat(repo.git_dir .. "/" .. d .. "/git-rebase-todo") then
      dir = repo.git_dir .. "/" .. d
      break
    end
  end
  if not dir then
    return nil
  end
  local head_name = (file_lines(dir .. "/head-name") or { "detached HEAD" })[1]:gsub("^refs/heads/", "")
  local lines = file_lines(dir .. "/git-rebase-todo") or {}
  local done = file_lines(dir .. "/done")
  if done and #done > 0 and done[1] ~= "" then
    for i, l in ipairs(done) do
      done[i] = l:gsub("^%l+", i == #done and "stop" or "done", 1)
    end
    lines = vim.list_extend(done, lines)
  end
  local reversed = {}
  for i = #lines, 1, -1 do
    table.insert(reversed, lines[i])
  end
  return { label = "Rebasing " .. head_name, entries = parse_todo_lines(reversed, short_len) }
end

---Cherry-pick / revert in progress (sequencer todo, or a single pick).
local function sequencer_state(repo, run)
  local todo = file_lines(repo.git_dir .. "/sequencer/todo")
  if todo then
    local reversed = {}
    for i = #todo, 1, -1 do
      table.insert(reversed, todo[i])
    end
    local entries = parse_todo_lines(reversed)
    if #entries > 0 then
      local label = entries[1].status == "revert" and "Reverting" or "Cherry Picking"
      return { label = label, entries = entries }
    end
    return nil
  end
  for _, kind in ipairs({ "CHERRY_PICK_HEAD", "REVERT_HEAD" }) do
    if vim.uv.fs_stat(repo.git_dir .. "/" .. kind) then
      local short = lines_of(run({ "rev-parse", "--short", kind, "--" }))[1]
      if short then
        local msg = (file_lines(repo.git_dir .. "/MERGE_MSG") or { "" })[1]
        local status = kind == "REVERT_HEAD" and "revert" or "pick"
        return {
          label = status == "revert" and "Reverting" or "Cherry Picking",
          entries = { { status = status, commit = short, subject = msg } },
        }
      end
    end
  end
end

---Upstream-compatible pull and push refs (s:StatusRetrieve/s:StatusRender).
---@return string pull_ref, string pull_type, string push_ref, string fetch_remote, string push_remote
local function tracking_refs(repo, branch)
  branch = branch or ""
  local fetch_remote = repo:config("branch." .. branch .. ".remote") or "origin"
  local push_remote = repo:config("branch." .. branch .. ".pushRemote") or repo:config("remote.pushDefault") or fetch_remote
  if fetch_remote ~= "." and (repo:config("remote." .. fetch_remote .. ".fetch") or "") == "" then
    fetch_remote = ""
  end
  if push_remote ~= "." and (repo:config("remote." .. push_remote .. ".push") or repo:config("remote." .. push_remote .. ".fetch") or "") == "" then
    push_remote = ""
  end
  local merge = ""
  if fetch_remote ~= "" and branch ~= "" then
    merge = repo:config("branch." .. branch .. ".merge") or ""
  end
  local push_default = repo:config("push.default") or "simple"
  local push
  if push_default == "upstream" then
    push = merge
  elseif push_remote == "" or branch == "" then
    push = ""
  else
    push = "refs/heads/" .. branch
  end
  local pull_type = "Pull"
  if merge ~= "" then
    local rebase = repo:config("branch." .. branch .. ".rebase") or repo:config("pull.rebase") or ""
    local r = rebase:lower()
    if r == "true" or r == "yes" or r == "on" or r == "1" or r == "interactive" or r == "merges" or r == "preserve" then
      pull_type = "Rebase"
    elseif r == "false" or r == "no|off" or r == "0" or r == "" then
      pull_type = "Merge"
    end
  end
  local pull_ref = merge
  if fetch_remote ~= "." then
    pull_ref = pull_ref:gsub("^refs/heads/", "refs/remotes/" .. fetch_remote .. "/")
  end
  local push_ref = push
  if push_remote ~= "." then
    push_ref = push_ref:gsub("^refs/heads/", "refs/remotes/" .. push_remote .. "/")
  end
  return pull_ref, pull_type, push_ref, fetch_remote, push_remote
end

---Diffs of the expanded files, per section.
local function inline_diffs(repo, run, st, expanded)
  local diffs = { Unstaged = {}, Staged = {}, Untracked = {}, Unmerged = {} }
  local want = { Unstaged = {}, Staged = {}, Untracked = {}, Unmerged = {} }
  local any = false
  for key in pairs(expanded) do
    local section, path = key:match("^(%w+)%z(.*)$")
    if section and want[section] then
      table.insert(want[section], path)
      any = true
    end
  end
  if not any then
    return diffs
  end
  local function by_path(list)
    local m = {}
    for _, e in ipairs(list) do
      m[e.path] = e
    end
    return m
  end
  local entries = {
    Unstaged = by_path(st.unstaged),
    Staged = by_path(st.staged),
    Untracked = by_path(st.untracked),
    Unmerged = by_path(st.unmerged),
  }
  for _, section in ipairs({ "Unstaged", "Staged" }) do
    local paths, subs = {}, {}
    for _, p in ipairs(want[section]) do
      local e = entries[section][p]
      if e then
        if e.submodule then
          table.insert(subs, p)
        else
          table.insert(paths, p)
          if e.orig then
            table.insert(paths, e.orig)
          end
        end
      end
    end
    local base = { "diff", "--no-ext-diff", "--no-color", "-M" }
    if section == "Staged" then
      table.insert(base, "--cached")
    end
    if #paths > 0 then
      local args = vim.list_extend(vim.deepcopy(base), { "--" })
      vim.list_extend(args, paths)
      for _, f in ipairs(diff_mod.parse(run(args).stdout)) do
        diffs[section][f.path] = f
      end
    end
    for _, p in ipairs(subs) do
      local args = vim.list_extend(vim.deepcopy(base), { "--submodule=log", "--", p })
      local text = run(args).stdout
      diffs[section][p] = {
        path = p,
        header = {},
        hunks = { { header = "", lines = lines_of({ code = 0, stdout = text }), submodule = true } },
        binary = false,
        submodule = true,
      }
    end
  end
  for _, p in ipairs(want.Untracked) do
    if entries.Untracked[p] and not p:match("/$") then
      local res = run({ "diff", "--no-ext-diff", "--no-color", "--no-index", "--", "/dev/null", p })
      local f = diff_mod.parse(res.stdout)[1]
      if f then
        f.path = p
        diffs.Untracked[p] = f
      end
    end
  end
  for _, p in ipairs(want.Unmerged) do
    if entries.Unmerged[p] then
      local f = diff_mod.parse(run({ "diff", "--no-ext-diff", "--no-color", "--", p }).stdout)[1]
      if f then
        diffs.Unmerged[p] = f
      end
    end
  end
  return diffs
end

---@param repo fugitive.Repo
---@param run fun(args: string[]): fugitive.ExecResult
---@param expanded table<string, boolean> "Section\0path" keys
---@return fugitive.Snapshot
function M.gather(repo, run, expanded)
  ---@type fugitive.Snapshot
  local snap = { headers = {}, logs = {}, stashes = {}, diffs = {} }
  local res = run(status_mod.args)
  if res.code ~= 0 then
    snap.error = require("fugitive.git.exec").error_text(res)
    snap.status = status_mod.parse("")
    snap.head = "?"
    return snap
  end
  local st = status_mod.parse(res.stdout)
  snap.status = st

  local branch = st.head
  local short_head = lines_of(run({ "rev-parse", "--short", "HEAD", "--" }))[1]
  local head = branch or short_head or ""
  snap.head = head

  local pull_ref, pull_type, push_ref, fetch_remote, push_remote = tracking_refs(repo, branch)
  local push_short = short_ref(push_ref)
  local pull_short = short_ref(pull_ref)
  local function header(key, value)
    if value and value ~= "" then
      table.insert(snap.headers, { key = key, value = value })
    end
  end
  header("Head", head)
  header(pull_type, pull_short)
  if push_ref ~= pull_ref then
    header("Push", push_short)
  end
  local hints = repo:config("advice.statusHints")
  if not (hints and (falsy(hints:lower()) or hints == "no|off")) then
    header("Help", "g?")
  end

  snap.rebasing = rebase_state(repo, short_head and #short_head or nil)
  snap.sequencing = sequencer_state(repo, run)
  snap.diffs = inline_diffs(repo, run, st, expanded or {})

  -- Unpushed / Unpulled, following upstream's rules
  local limit = require("fugitive.config").get().summary.log_limit
  local function range_log(old, new)
    if not old or old == "" or not new or new == "" then
      return { entries = {}, overflow = false, error = 2 }
    end
    return query_log(run, old .. ".." .. new, limit)
  end
  local function add(key, label, log)
    if log and #log.entries > 0 then
      table.insert(snap.logs, { key = key, label = label, entries = log.entries, overflow = log.overflow })
    end
  end
  local head_rev = st.oid and head or ""
  local unique_push = push_ref == pull_ref and "" or push_ref
  local unpushed_push = range_log(unique_push, head_rev)
  local unpushed_pull
  if st.ahead == 0 then
    unpushed_pull = { entries = {}, overflow = false, error = false }
  else
    unpushed_pull = range_log(pull_ref, head_rev)
  end
  -- a push ref that does not exist at the remote: use the pull ref
  if unpushed_push.error == true then
    unpushed_push = unpushed_pull
  end
  add("Unpushed", "Unpushed to " .. push_short, unpushed_push)
  add("Unpushed", "Unpushed to " .. pull_short, unpushed_pull)
  if unpushed_push.error and unpushed_pull.error and not snap.rebasing and (push_remote .. fetch_remote) ~= "" and head_rev ~= "" then
    add("Unpushed", "Unpushed to *", query_log(run, { head_rev, "--not", "--remotes" }, limit))
  end
  add("Unpulled", "Unpulled from " .. push_short, range_log(head_rev, unique_push))
  if pull_ref ~= "" and st.behind ~= 0 then
    add("Unpulled", "Unpulled from " .. pull_short, range_log(head_rev, pull_ref))
  end

  if st.stash > 0 then
    for _, l in ipairs(lines_of(run({ "stash", "list", "--format=%gd%x09%gs" }))) do
      local ref, subject = l:match("^(%S+)\t(.*)$")
      if ref then
        table.insert(snap.stashes, { ref = ref, subject = subject })
      end
    end
  end

  snap.discarded = require("fugitive.discard").session_latest(repo)
  return snap
end

return M
