---@mod nvim-fugitive.discard `X` with save-before-destroy and recovery (§4.2).
---
---1. Before anything destructive, every selected entry is saved: the work
---   tree content (`hash-object -w`, symlinks as their link text) and, when
---   the discard touches the index, the index entries (`ls-files -s`). If any
---   save fails, nothing is touched.
---2. Each discard is journaled in `<git-common-dir>/fugitive/discard.json`.
---3. `:Git restore-discard`, `:FugitiveRestore [path]`, `g-`/`u` restore.
---
---Saved blobs are unreachable loose objects: `git gc` prunes them after
---`gc.pruneExpire` (two weeks by default).

local bit = require("bit")
local notify = require("nvim-fugitive.ui.notify")

local M = {}

---@class fugitive.DiscardEntry
---@field time integer
---@field repo string work tree
---@field git_dir string
---@field path string
---@field worktree_blob string|false|nil blob of the work tree content; false = file was absent
---@field mode string? work tree mode (100644, 100755, 120000)
---@field index_entry {mode: string, sha: string, stage: integer}[]|nil nil = index untouched; {} = path was absent
---@field kind string untracked|modified|deleted|staged|added|partial|ours|theirs|unmerged
---@field session integer? set for entries made in this Neovim session

local session_id = vim.fn.getpid() * 1000 + (vim.uv.hrtime() % 1000)

local function journal_path(repo)
  return repo.common_dir .. "/fugitive/discard.json"
end

---@param repo fugitive.Repo
---@return fugitive.DiscardEntry[]
function M.read_journal(repo)
  local fd = io.open(journal_path(repo), "rb")
  if not fd then
    return {}
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, text)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

---@param repo fugitive.Repo
---@param entries fugitive.DiscardEntry[]
local function write_journal(repo, entries)
  local cap = require("nvim-fugitive.config").get().discard.journal_size
  while #entries > cap do
    table.remove(entries, 1)
  end
  vim.fn.mkdir(repo.common_dir .. "/fugitive", "p")
  local tmp = journal_path(repo) .. ".tmp"
  local fd = assert(io.open(tmp, "wb"))
  fd:write(vim.json.encode(entries))
  fd:close()
  assert(vim.uv.fs_rename(tmp, journal_path(repo)))
end

---Most recent entry made in this session for `repo` (summary hint line).
---@param repo fugitive.Repo
---@return fugitive.DiscardEntry?
function M.session_latest(repo)
  local entries = M.read_journal(repo)
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.session == session_id and e.git_dir == repo.git_dir then
      return e
    end
  end
end

local function lstat(path)
  return vim.uv.fs_lstat(path)
end

---Save the work tree content of `path`; returns blob, mode or an error.
---@param repo fugitive.Repo
---@param rel string
---@return string|false|nil blob, string? mode, string? err
local function save_worktree(repo, rel)
  local abs = repo:abs(rel)
  local st = lstat(abs)
  if not st then
    return false, nil
  end
  if st.type == "link" then
    local target = vim.uv.fs_readlink(abs)
    local res = repo:sync({ "hash-object", "-w", "--stdin" }, { stdin = target })
    if res.code ~= 0 then
      return nil, nil, require("nvim-fugitive.git.exec").error_text(res)
    end
    return vim.trim(res.stdout), "120000"
  end
  if st.type == "directory" then
    return nil, nil, "will not delete directory " .. rel
  end
  local res = repo:sync({ "hash-object", "-w", "--", rel })
  if res.code ~= 0 then
    return nil, nil, require("nvim-fugitive.git.exec").error_text(res)
  end
  local exec_bit = bit.band(st.mode, tonumber("111", 8)) ~= 0
  return vim.trim(res.stdout), exec_bit and "100755" or "100644"
end

---Index entries of `path` (all stages).
---@return {mode: string, sha: string, stage: integer}[]?, string? err
local function save_index(repo, rel)
  local res = repo:sync({ "ls-files", "-s", "-z", "--", rel })
  if res.code ~= 0 then
    return nil, require("nvim-fugitive.git.exec").error_text(res)
  end
  local out = {}
  for rec in res.stdout:gmatch("([^%z]+)") do
    local mode, sha, stage, p = rec:match("^(%d+) (%x+) (%d)\t(.*)$")
    if p == rel then
      table.insert(out, { mode = mode, sha = sha, stage = tonumber(stage) })
    end
  end
  return out
end

local function status_in(snap, section, path)
  if not snap or not snap.status then
    return nil
  end
  local list = ({ Staged = snap.status.staged, Unstaged = snap.status.unstaged })[section] or {}
  for _, e in ipairs(list) do
    if e.path == path then
      return e.status
    end
  end
end

---A plan: the commands that destroy, run after everything is saved.
---@alias fugitive.DiscardPlan {cmds: {args: string[], stdin?: string}[], delete?: boolean, write?: fun(), kind: string, touches_index: boolean}

---Discard the selected hunks of a file.
---@return fugitive.DiscardPlan?, string? err
local function plan_patch(item)
  local sels = {}
  for _, h in ipairs(item.hunks) do
    if h.hunk.combined or h.hunk.submodule then
      return nil, "cannot discard part of a conflict or submodule diff"
    end
    table.insert(sels, { hunk = h.hunk, lines = h.lines })
  end
  if item.section ~= "Unstaged" and item.section ~= "Staged" then
    return nil, "cannot discard part of an " .. item.section:lower() .. " file"
  end
  local patch = require("nvim-fugitive.git.diff").build_patch(item.file, sels, true)
  if not patch then
    return nil, "no changes selected"
  end
  local args = { "apply", "--recount", "--whitespace=nowarn", "--reverse" }
  if item.section == "Staged" then
    table.insert(args, "--index")
  end
  table.insert(args, "-")
  return {
    cmds = { { args = args, stdin = patch } },
    kind = "partial",
    touches_index = item.section == "Staged",
  }
end

---Keep both sides, or neither, of every conflict block of the file: git
---has no --both or --none for a whole file.
---@return fugitive.DiscardPlan?, string? err
local function plan_rewrite(path, side, opts)
  local abs = opts.repo and opts.repo:abs(path) or path
  local f = io.open(abs, "r")
  if not f then
    return nil, "cannot read " .. path
  end
  local lines = vim.split(f:read("*a"), "\n", { plain = true })
  f:close()
  local conflict = require("nvim-fugitive.conflict")
  local blocks = conflict.parse(lines)
  if #blocks == 0 then
    return nil, "no conflict markers in " .. path
  end
  -- from the last block, so earlier line numbers stay valid
  for k = #blocks, 1, -1 do
    local c = blocks[k]
    local repl = conflict.resolve_block(lines, c, side)
    for _ = c.start, c.finish do
      table.remove(lines, c.start)
    end
    for n, l in ipairs(repl) do
      table.insert(lines, c.start + n - 1, l)
    end
  end
  local out = table.concat(lines, "\n")
  return {
    cmds = {},
    write = function()
      local w = assert(io.open(abs, "w"))
      w:write(out)
      w:close()
    end,
    kind = side,
    touches_index = false,
  }
end

---For each side: git's flag, the section a deletion on that side shows in,
---and which character of the status pair is that side's.
local sides = {
  ours = { flag = "--ours", other = "Staged", xy = 1 },
  theirs = { flag = "--theirs", other = "Unstaged", xy = 2 },
}

---Take one side of the file: checkout --ours/--theirs, or delete it when
---that side deleted it.
---@return fugitive.DiscardPlan
local function plan_side(item, side, opts)
  local e, s = item.entry, sides[side]
  local deleted = status_in(opts.snap, s.other, e.path) == "D"
    or (e.xy and e.xy:sub(s.xy, s.xy) == "D")
  if deleted then
    return { cmds = {}, delete = true, kind = side, touches_index = false }
  end
  return {
    cmds = { { args = { "checkout", s.flag, "--", e.path } } },
    kind = side,
    touches_index = false,
  }
end

---Throw away the file's change, by its section.
---@return fugitive.DiscardPlan?, string? err
local function plan_file(item, opts)
  local e = item.entry
  local path = e.path
  if item.section == "Unmerged" then
    return nil, "Use co / ct (or 2X / 3X) to take ours / theirs"
  end
  if e.status == "U" then
    return { cmds = {}, delete = true, kind = "unmerged", touches_index = false }
  end
  if e.status == "A" and item.section == "Staged" then
    return { cmds = { { args = { "rm", "-f", "--", path } } }, kind = "added", touches_index = true }
  end
  if item.section == "Unstaged" then
    return {
      cmds = { { args = { "checkout", "--", path } } },
      kind = e.status == "D" and "deleted" or "modified",
      touches_index = false,
    }
  end
  if item.section == "Staged" then
    if not opts.has_head then
      return nil, "nothing to restore from: no commits yet"
    end
    local cmds = { { args = { "checkout", "@", "--", path } } }
    if e.orig then
      table.insert(cmds, 1, { args = { "rm", "-f", "-q", "--", path } })
      cmds[2] = { args = { "checkout", "@", "--", e.orig } }
    end
    return { cmds = cmds, kind = "staged", touches_index = true }
  end
  return nil
end

---Plan the destructive commands for one selection item. `opts.resolve`
---("ours", "theirs", "both", "none") resolves a file instead of discarding
---its change.
---@return fugitive.DiscardPlan?, string? err
local function plan(item, opts)
  local e = item.entry
  if not e then
    return nil
  end
  if e.submodule then
    return nil, "will not touch submodule " .. e.path
  end
  if e.path:sub(-1) == "/" then
    return nil, "will not delete directory " .. e.path
  end
  local resolve = opts.resolve
  if item.type == "patch" then
    return plan_patch(item)
  elseif resolve == "both" or resolve == "none" then
    return plan_rewrite(e.path, resolve, opts)
  elseif item.section == "Untracked" then
    return {
      cmds = { { args = { "clean", "-f", "--", e.path } } },
      kind = "untracked",
      touches_index = false,
    }
  elseif resolve == "ours" or resolve == "theirs" then
    return plan_side(item, resolve, opts)
  end
  return plan_file(item, opts)
end

---Discard the selected items. Refuses everything if any save fails.
---@param repo fugitive.Repo
---@param items fugitive.Selection[]
---@param opts {count?: integer, has_head?: boolean, snap?: fugitive.Snapshot}
---@param cb? fun(ok: boolean)
function M.discard(repo, items, opts, cb)
  -- expand sections into their files
  local flat = {}
  for _, it in ipairs(items) do
    if it.type == "section" then
      for _, e in ipairs(it.entries or {}) do
        table.insert(flat, { type = "file", section = it.section, entry = e })
      end
    elseif it.type == "file" or it.type == "patch" then
      table.insert(flat, it)
    end
  end
  if #flat == 0 then
    notify.warn("nothing to discard")
    if cb then
      cb(false)
    end
    return
  end

  -- 1. plan and save everything before touching anything
  local plans, journal_new = {}, {}
  for _, it in ipairs(flat) do
    local p, err = plan(it, vim.tbl_extend("force", opts, { repo = repo }))
    if not p then
      notify.error(err or ("cannot discard " .. it.entry.path))
      if cb then
        cb(false)
      end
      return
    end
    local paths = { it.entry.path }
    if it.entry.orig and it.section == "Staged" then
      table.insert(paths, it.entry.orig)
    end
    for _, path in ipairs(paths) do
      local blob, mode, err2 = save_worktree(repo, path)
      if blob == nil then
        notify.error(
          "discard refused, could not save " .. path .. ": " .. (err2 or "unknown error")
        )
        if cb then
          cb(false)
        end
        return
      end
      local index_entry
      if p.touches_index then
        local idx, err3 = save_index(repo, path)
        if not idx then
          notify.error(
            "discard refused, could not save the index entry of " .. path .. ": " .. err3
          )
          if cb then
            cb(false)
          end
          return
        end
        index_entry = idx
      end
      table.insert(journal_new, {
        time = os.time(),
        repo = repo.worktree,
        git_dir = repo.git_dir,
        path = path,
        worktree_blob = blob,
        mode = mode,
        index_entry = index_entry,
        kind = p.kind,
        section = it.section,
        status = it.entry.status,
        session = session_id,
      })
    end
    table.insert(plans, { item = it, plan = p })
  end

  -- 2. journal first, so a crash mid-way still leaves a recovery path
  local journal = M.read_journal(repo)
  vim.list_extend(journal, journal_new)
  local ok_j, err_j = pcall(write_journal, repo, journal)
  if not ok_j then
    notify.error("discard refused, could not write the journal: " .. tostring(err_j))
    if cb then
      cb(false)
    end
    return
  end

  -- 3. destroy
  local cmds = {}
  for _, pl in ipairs(plans) do
    if pl.plan.delete then
      os.remove(repo:abs(pl.item.entry.path))
    end
    if pl.plan.write then
      pl.plan.write()
    end
    vim.list_extend(cmds, pl.plan.cmds)
  end
  require("nvim-fugitive.buffers.summary.actions").run_chain(repo, cmds, function(ok)
    if ok then
      local last = journal_new[#journal_new]
      local blob = last.worktree_blob and last.worktree_blob:sub(1, 7) or "-"
      local what = #journal_new == 1 and last.path or (#journal_new .. " files")
      notify.info(
        string.format("Discarded %s (saved as %s). Undo: :Git restore-discard", what, blob)
      )
    end
    if cb then
      cb(ok)
    end
  end)
end

local function write_blob(repo, entry)
  local abs = repo:abs(entry.path)
  if entry.worktree_blob == false then
    os.remove(abs)
    return true
  end
  local res = repo:sync({ "cat-file", "blob", entry.worktree_blob })
  if res.code ~= 0 then
    return nil, "blob " .. entry.worktree_blob .. " is gone (pruned by git gc?)"
  end
  vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
  if lstat(abs) then
    os.remove(abs)
  end
  if entry.mode == "120000" then
    local ok, err = vim.uv.fs_symlink(res.stdout, abs)
    if not ok then
      return nil, err
    end
    return true
  end
  local fd = io.open(abs, "wb")
  if not fd then
    return nil, "cannot write " .. abs
  end
  fd:write(res.stdout)
  fd:close()
  vim.uv.fs_chmod(abs, tonumber(entry.mode == "100755" and "755" or "644", 8))
  return true
end

---Restore one journal entry.
---@param repo fugitive.Repo
---@param entry fugitive.DiscardEntry
---@param cb? fun(ok: boolean)
function M.restore(repo, entry, cb)
  local ok, err
  if entry.kind == "deleted" then
    -- discarding a work-tree deletion restored the file: delete it again
    ok = os.remove(repo:abs(entry.path)) ~= nil or not lstat(repo:abs(entry.path))
  else
    ok, err = write_blob(repo, entry)
  end
  if not ok then
    notify.error("restore failed: " .. tostring(err))
    if cb then
      cb(false)
    end
    return
  end
  if entry.index_entry then
    local lines = { "0 " .. string.rep("0", 40) .. "\t" .. entry.path }
    for _, ie in ipairs(entry.index_entry) do
      table.insert(lines, string.format("%s %s %d\t%s", ie.mode, ie.sha, ie.stage, entry.path))
    end
    local res = repo:sync(
      { "update-index", "--index-info" },
      { stdin = table.concat(lines, "\n") .. "\n" }
    )
    if res.code ~= 0 then
      notify.error(
        "restore of the index entry failed: " .. require("nvim-fugitive.git.exec").error_text(res)
      )
      if cb then
        cb(false)
      end
      return
    end
  end
  -- drop it from the journal
  local journal = M.read_journal(repo)
  for i = #journal, 1, -1 do
    local j = journal[i]
    if
      j.time == entry.time
      and j.path == entry.path
      and j.worktree_blob == entry.worktree_blob
      and j.kind == entry.kind
    then
      table.remove(journal, i)
      break
    end
  end
  pcall(write_journal, repo, journal)
  notify.info("Restored " .. entry.path)
  require("nvim-fugitive").changed(repo)
  if cb then
    cb(true)
  end
end

---Restore the most recent discard of `repo` (optionally of `path`).
---@param repo fugitive.Repo
---@param path? string
function M.restore_latest(repo, path)
  local journal = M.read_journal(repo)
  for i = #journal, 1, -1 do
    local e = journal[i]
    if e.git_dir == repo.git_dir and (not path or e.path == path) then
      return M.restore(repo, e)
    end
  end
  notify.warn("nothing to restore" .. (path and (" for " .. path) or ""))
end

---Picker over journal entries (`:FugitiveRestore [path]`).
---@param path? string
---@param repo? fugitive.Repo
function M.pick(path, repo)
  repo = repo or require("nvim-fugitive.git.repo").require()
  if not repo then
    return
  end
  local entries = {}
  for _, e in ipairs(M.read_journal(repo)) do
    if e.git_dir == repo.git_dir and (not path or e.path == path) then
      table.insert(entries, 1, e)
    end
  end
  if #entries == 0 then
    notify.warn("nothing to restore" .. (path and (" for " .. path) or ""))
    return
  end
  vim.ui.select(entries, {
    prompt = "Restore discarded change",
    format_item = function(e)
      return string.format(
        "%s  %-9s %s  %s",
        os.date("%Y-%m-%d %H:%M:%S", e.time),
        e.kind,
        e.path,
        e.worktree_blob and e.worktree_blob:sub(1, 7) or ""
      )
    end,
  }, function(choice)
    if choice then
      M.restore(repo, choice)
    end
  end)
end

---Completion for :FugitiveRestore.
function M.paths(repo)
  local seen, out = {}, {}
  for _, e in ipairs(M.read_journal(repo)) do
    if not seen[e.path] then
      seen[e.path] = true
      table.insert(out, e.path)
    end
  end
  return out
end

return M
