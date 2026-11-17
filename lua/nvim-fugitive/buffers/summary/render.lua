---@mod nvim-fugitive.buffers.summary.render Snapshot -> buffer lines + line info.
---
---The text matches upstream's summary buffer ("Head: main", "Unstaged (2)",
---"M file", inline "@@" hunks, "Unpushed to origin/main (1)", …). Next to the
---text we keep a parallel array describing every line so actions never have
---to parse buffer text.

local fold = require("nvim-fugitive.buffers.summary.fold")
local tree = require("nvim-fugitive.buffers.summary.tree")

local M = {}

---@class fugitive.LineInfo
---@field kind "header"|"section"|"file"|"dir"|"diffmeta"|"hunk"|"diffline"|"commit"|"rebase"|"stash"|"blank"|"discarded"
---@field section? string Untracked/Unstaged/Staged/Unmerged/Unpushed/Unpulled/Rebasing/Sequencing/Stash
---@field key? string header key
---@field value? string header value
---@field entry? fugitive.StatusEntry
---@field file? fugitive.FileDiff
---@field hunk_index? integer
---@field line_index? integer
---@field commit? string
---@field subject? string
---@field ref? string stash ref
---@field label? string section heading text
---@field note? string virtual text shown after the line (submodule state)
---@field path? string submodule path (uninitialized section)
---@field depth? integer file or directory: how many directory lines enclose it
---@field dir? string directory: its path, with a trailing slash
---@field entries? fugitive.StatusEntry[] directory: every file under it
---@field collapsed? boolean directory: folded, its files not shown
---@field fold? fugitive.FoldNode directory, file, commit or stash: its node
---@field open? boolean file, commit or stash: its diff (or files) shown
---@field parent? fugitive.LineInfo the line this one sits under: a file's
---directory line or expanded untracked directory, a diff line's file
---@field name_col? integer file or directory: byte column where its name starts
---@field name_end? integer file or directory: byte column after its name
---@field marker_col? integer directory: byte column of its ▾/▸ marker

---@class fugitive.RenderOpts
---@field tree? boolean files as a directory tree
---@field compact? boolean no level for a lone file or a single-subdirectory chain
---@field paths? "name"|"full" files under a directory: name only, or full path
---@field letters? boolean a status letter before each file (else two blanks)

M.marker_open = "▾"
M.marker_closed = "▸"

---State of a submodule entry from its "S<c><m><u>" field, like git status.
---@param e fugitive.StatusEntry
---@return string?
function M.submodule_note(e)
  if not e.submodule or not e.sub then
    return nil
  end
  local parts = {}
  if e.sub:sub(2, 2) == "C" then
    table.insert(parts, "new commits")
  end
  if e.sub:sub(3, 3) == "M" then
    table.insert(parts, "modified content")
  end
  if e.sub:sub(4, 4) == "U" then
    table.insert(parts, "untracked content")
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, ", ")
end

---@param snap fugitive.Snapshot
---@param open fugitive.FoldState what is open (buffers/summary/fold.lua)
---@param opts? fugitive.RenderOpts
---@return string[] lines, fugitive.LineInfo[] info
function M.render(snap, open, opts)
  opts = opts or {}
  local letters = opts.letters
  local full = opts.paths == "full"
  local lines, info = {}, {}
  local function add(text, i)
    table.insert(lines, text)
    table.insert(info, i)
  end

  if snap.error then
    add("Error: " .. snap.error, { kind = "header", key = "Error", value = snap.error })
    return lines, info
  end

  for _, h in ipairs(snap.headers) do
    add(h.key .. ": " .. h.value, { kind = "header", key = h.key, value = h.value })
  end
  if snap.discarded then
    local d = snap.discarded --[[@as fugitive.DiscardEntry]]
    add(
      string.format(
        "Discarded: %s (%s) — u or g- restores",
        d.path,
        (d.worktree_blob or d.kind or ""):sub(1, 7)
      ),
      { kind = "discarded", entry = nil, value = d.path }
    )
  end

  local function section(name, label, n, suffix)
    add("", { kind = "blank" })
    add(
      string.format("%s (%d%s)", label, n, suffix or ""),
      { kind = "section", section = name, label = label }
    )
  end

  ---The inline diff of a file line, when it is open.
  local function add_diff(file)
    local sec, entry, depth = file.section, file.entry, file.depth
    local f = snap.diffs[sec] and snap.diffs[sec][entry.path]
    if not fold.is_open(open, file.fold) or not f then
      return
    end
    file.open = true
    -- meta lines (new file mode, binary, rename, mode change) but not the
    -- diff/index/---/+++ boilerplate, then the hunks
    for _, h in ipairs(f.header) do
      if
        not (h:match("^diff ") or h:match("^index ") or h:match("^%-%-%- ") or h:match("^%+%+%+ "))
      then
        add(h, {
          kind = "diffmeta",
          section = sec,
          entry = entry,
          file = f,
          depth = depth,
          parent = file,
        })
      end
    end
    for hi, hunk in ipairs(f.hunks) do
      if hunk.header ~= "" then
        add(hunk.header, {
          kind = "hunk",
          section = sec,
          entry = entry,
          file = f,
          hunk_index = hi,
          depth = depth,
          parent = file,
        })
      end
      for li, l in ipairs(hunk.lines) do
        add(l, {
          kind = "diffline",
          section = sec,
          entry = entry,
          file = f,
          hunk_index = hi,
          line_index = li,
          depth = depth,
          parent = file,
        })
      end
    end
  end

  local function rebase_section(name, data)
    if data and #data.entries > 0 then
      section(name, data.label, #data.entries)
      for _, e in ipairs(data.entries) do
        add(e.status .. " " .. e.commit .. " " .. e.subject, {
          kind = "rebase",
          section = name,
          commit = e.commit,
          subject = e.subject,
          value = e.status,
        })
      end
    end
  end
  rebase_section("Rebasing", snap.rebasing)
  rebase_section("Sequencing", snap.sequencing)
  rebase_section("Bisecting", snap.bisecting)

  local st = snap.status
  ---A file line: the status letter (or, coloured, two blanks), the indent,
  ---then its name; `name_col`/`name_end` mark the name for highlighting.
  local function add_file(name, e, depth, label, parent)
    -- the flat (upstream) list never indents
    local indent = string.rep("  ", (opts.tree and not full) and depth or 0)
    local prefix = (letters and (e.status .. " ") or "  ") .. indent
    local line = {
      kind = "file",
      section = name,
      entry = e,
      note = M.submodule_note(e),
      depth = depth,
      name_col = #prefix,
      name_end = #prefix + #label,
      fold = fold.node("file", name, e.path),
      parent = parent,
    }
    add(prefix .. label, line)
    add_diff(line)
    return line
  end
  local function flat_label(e)
    return e.orig and (e.orig .. " -> " .. e.path) or e.path
  end
  ---An untracked directory expanded with `=`: its files, each its own entry.
  local function add_children(line)
    local name, e, depth = line.section, line.entry, line.depth
    local children = snap.untracked_children and snap.untracked_children[e.path]
    if name ~= "Untracked" or not children then
      return
    end
    line.open = true
    for _, c in ipairs(children) do
      local label = (opts.tree and not full) and c.path:sub(#e.path + 1) or c.path
      add_file(name, c, depth + 1, label, line)
    end
  end
  local function file_section(name, list)
    if #list == 0 then
      return
    end
    section(name, name, #list)
    if not opts.tree then
      for _, e in ipairs(list) do
        add_children(add_file(name, e, 0, flat_label(e)))
      end
      return
    end
    local hidden_below -- depth under a folded directory: its lines are skipped
    local dir_at = {} -- the directory line last shown at each depth
    for _, node in ipairs(tree.build(list, { compact = opts.compact ~= false })) do
      if hidden_below and node.depth <= hidden_below then
        hidden_below = nil
      end
      if not hidden_below then
        local label = tree.label(node, full and "full" or "name")
        local parent = node.depth > 0 and dir_at[node.depth - 1] or nil
        if node.type == "dir" then
          local node_fold = fold.node("dir", name, node.dir)
          local folded = not fold.is_open(open, node_fold)
          local indent = string.rep("  ", node.depth)
          local marker = folded and M.marker_closed or M.marker_open
          local text = indent .. marker .. " " .. label
          local line = {
            kind = "dir",
            section = name,
            dir = node.dir,
            depth = node.depth,
            entries = node.entries,
            collapsed = folded,
            marker_col = #indent,
            name_col = #indent + #marker + 1,
            name_end = #text,
            fold = node_fold,
            parent = parent,
          }
          add(text .. (folded and string.format(" (%d)", #node.entries) or ""), line)
          dir_at[node.depth] = line
          if folded then
            hidden_below = node.depth
          end
        else
          add_children(add_file(name, node.entry, node.depth, label, parent))
        end
      end
    end
  end
  file_section("Unmerged", st.unmerged)
  file_section("Untracked", st.untracked)
  file_section("Unstaged", st.unstaged)
  file_section("Staged", st.staged)

  if snap.uninitialized and #snap.uninitialized > 0 then
    section("Uninitialized", "Uninitialized submodules", #snap.uninitialized)
    for _, p in ipairs(snap.uninitialized) do
      add("- " .. p, { kind = "submodule", section = "Uninitialized", path = p, note = "cu: init" })
    end
  end

  ---Read-only diff of a stash or commit expanded with `=`: its files with
  ---their hunks, keyed by the revision (`ref`).
  local function add_rev_diff(sec, rev, files, parent)
    local entry =
      { path = rev, status = "", xy = "", sub = "N...", submodule = false, kind = "stash" }
    for _, f in ipairs(files or {}) do
      for _, h in ipairs(f.header) do
        if not (h:match("^index ") or h:match("^%-%-%- ") or h:match("^%+%+%+ ")) then
          add(h, {
            kind = "diffmeta",
            section = sec,
            entry = entry,
            file = f,
            ref = rev,
            parent = parent,
          })
        end
      end
      for hi, hunk in ipairs(f.hunks) do
        add(hunk.header, {
          kind = "hunk",
          section = sec,
          entry = entry,
          file = f,
          hunk_index = hi,
          ref = rev,
          parent = parent,
        })
        for li, l in ipairs(hunk.lines) do
          add(l, {
            kind = "diffline",
            section = sec,
            entry = entry,
            file = f,
            hunk_index = hi,
            line_index = li,
            ref = rev,
            parent = parent,
          })
        end
      end
    end
  end

  for _, log in ipairs(snap.logs) do
    section(log.key, log.label, #log.entries, log.overflow and "+" or "")
    for _, e in ipairs(log.entries) do
      local line = {
        kind = "commit",
        section = log.key,
        commit = e.commit,
        subject = e.subject,
        label = log.label,
        fold = fold.node("commit", log.key, e.commit),
      }
      add(e.commit .. " " .. e.subject, line)
      if fold.is_open(open, line.fold) then
        line.open = true
        add_rev_diff(log.key, e.commit, snap.commit_diffs and snap.commit_diffs[e.commit], line)
      end
    end
  end

  if #snap.stashes > 0 then
    section("Stash", "Stashes", #snap.stashes)
    for _, s in ipairs(snap.stashes) do
      local line = {
        kind = "stash",
        section = "Stash",
        ref = s.ref,
        subject = s.subject,
        fold = fold.node("stash", "Stash", s.ref),
      }
      add(s.ref .. " " .. s.subject, line)
      if fold.is_open(open, line.fold) then
        line.open = true
        add_rev_diff("Stash", s.ref, snap.stash_diffs and snap.stash_diffs[s.ref], line)
      end
    end
  end

  return lines, info
end

return M
