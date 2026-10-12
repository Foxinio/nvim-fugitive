---@mod nvim-fugitive.buffers.summary.render Snapshot -> buffer lines + line info.
---
---The text matches upstream's summary buffer ("Head: main", "Unstaged (2)",
---"M file", inline "@@" hunks, "Unpushed to origin/main (1)", …). Next to the
---text we keep a parallel array describing every line so actions never have
---to parse buffer text.

local status_mod = require("nvim-fugitive.git.status")

local M = {}

---@class fugitive.LineInfo
---@field kind "header"|"section"|"file"|"diffmeta"|"hunk"|"diffline"|"commit"|"rebase"|"stash"|"blank"|"discarded"
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

---Key of an expandable file.
---@param section string
---@param path string
---@return string
function M.expand_key(section, path)
  return section .. "\0" .. path
end

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
---@param expanded table<string, boolean>
---@return string[] lines, fugitive.LineInfo[] info
function M.render(snap, expanded)
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

  local function add_diff(sec, entry)
    local f = snap.diffs[sec] and snap.diffs[sec][entry.path]
    if not expanded[M.expand_key(sec, entry.path)] or not f then
      return
    end
    -- meta lines (new file mode, binary, rename, mode change) but not the
    -- diff/index/---/+++ boilerplate, then the hunks
    for _, h in ipairs(f.header) do
      if
        not (h:match("^diff ") or h:match("^index ") or h:match("^%-%-%- ") or h:match("^%+%+%+ "))
      then
        add(h, { kind = "diffmeta", section = sec, entry = entry, file = f })
      end
    end
    for hi, hunk in ipairs(f.hunks) do
      if hunk.header ~= "" then
        add(hunk.header, { kind = "hunk", section = sec, entry = entry, file = f, hunk_index = hi })
      end
      for li, l in ipairs(hunk.lines) do
        add(l, {
          kind = "diffline",
          section = sec,
          entry = entry,
          file = f,
          hunk_index = hi,
          line_index = li,
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
  local function file_section(name, list)
    if #list == 0 then
      return
    end
    section(name, name, #list)
    for _, e in ipairs(list) do
      add(
        status_mod.format(e),
        { kind = "file", section = name, entry = e, note = M.submodule_note(e) }
      )
      add_diff(name, e)
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

  for _, log in ipairs(snap.logs) do
    section(log.key, log.label, #log.entries, log.overflow and "+" or "")
    for _, e in ipairs(log.entries) do
      add(e.commit .. " " .. e.subject, {
        kind = "commit",
        section = log.key,
        commit = e.commit,
        subject = e.subject,
        label = log.label,
      })
    end
  end

  if #snap.stashes > 0 then
    section("Stash", "Stashes", #snap.stashes)
    for _, s in ipairs(snap.stashes) do
      add(
        s.ref .. " " .. s.subject,
        { kind = "stash", section = "Stash", ref = s.ref, subject = s.subject }
      )
      local files = expanded[M.expand_key("Stash", s.ref)]
        and snap.stash_diffs
        and snap.stash_diffs[s.ref]
      for _, f in ipairs(files or {}) do
        -- read-only: the stash's files with their hunks, keyed by the ref
        local entry =
          { path = s.ref, status = "", xy = "", sub = "N...", submodule = false, kind = "stash" }
        for _, h in ipairs(f.header) do
          if not (h:match("^index ") or h:match("^%-%-%- ") or h:match("^%+%+%+ ")) then
            add(h, { kind = "diffmeta", section = "Stash", entry = entry, file = f, ref = s.ref })
          end
        end
        for hi, hunk in ipairs(f.hunks) do
          add(hunk.header, {
            kind = "hunk",
            section = "Stash",
            entry = entry,
            file = f,
            hunk_index = hi,
            ref = s.ref,
          })
          for li, l in ipairs(hunk.lines) do
            add(l, {
              kind = "diffline",
              section = "Stash",
              entry = entry,
              file = f,
              hunk_index = hi,
              line_index = li,
              ref = s.ref,
            })
          end
        end
      end
    end
  end

  return lines, info
end

return M
