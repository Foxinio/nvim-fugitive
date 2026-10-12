---@mod nvim-fugitive.git.diff Unified diff parsing, hunk math and partial patches.

local M = {}

---@class fugitive.Hunk
---@field header string the "@@ … @@" line
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field lines string[] body lines (" ", "+", "-", "\\" prefixed)
---@field combined boolean? a --cc hunk (read-only)
---@field submodule boolean? a `--submodule=log` shortlog pseudo-hunk

---@class fugitive.FileDiff
---@field path string new path (old path for deletions)
---@field old_path string?
---@field header string[] lines from "diff --git" up to the first hunk
---@field hunks fugitive.Hunk[]
---@field binary boolean
---@field new_file boolean
---@field deleted_file boolean

---Undo git's C-style quoting of a path ("a\tb" -> a<TAB>b).
---@param s string
---@return string
function M.unquote(s)
  if s:sub(1, 1) ~= '"' or s:sub(-1) ~= '"' then
    return s
  end
  s = s:sub(2, -2)
  local map = {
    a = "\a",
    b = "\b",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
    v = "\v",
    ['"'] = '"',
    ["\\"] = "\\",
  }
  return (
    s:gsub("\\(%d%d%d)", function(oct)
      return string.char(tonumber(oct, 8))
    end):gsub("\\(.)", function(c)
      return map[c] or c
    end)
  )
end

local function strip_prefix(p)
  p = M.unquote(p)
  return (p:gsub("^[abciow12]/", "", 1))
end

---Parse a hunk header.
---@param line string
---@return fugitive.Hunk?
function M.parse_hunk_header(line)
  local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if os then
    return {
      header = line,
      old_start = tonumber(os),
      old_count = oc == "" and 1 or tonumber(oc),
      new_start = tonumber(ns),
      new_count = nc == "" and 1 or tonumber(nc),
      lines = {},
    }
  end
  if line:match("^@@@+ ") then
    return {
      header = line,
      old_start = 0,
      old_count = 0,
      new_start = 0,
      new_count = 0,
      lines = {},
      combined = true,
    }
  end
end

---Parse `git diff` output (one or many files).
---@param text string|string[]
---@return fugitive.FileDiff[]
function M.parse(text)
  local lines
  if type(text) == "table" then
    lines = text
  else
    lines = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
  end
  local files = {}
  local file, hunk
  for _, line in ipairs(lines) do
    if line:match("^diff ") then
      file =
        { header = { line }, hunks = {}, binary = false, new_file = false, deleted_file = false }
      hunk = nil
      table.insert(files, file)
      -- "diff --git a/x b/x": recover the path when both sides are equal
      local rest = line:match("^diff %-%-git (.*)$")
      if rest and not rest:find('"') and #rest % 2 == 1 then
        local half = (#rest - 1) / 2
        local a, b = rest:sub(1, half), rest:sub(half + 2)
        if a:sub(3) == b:sub(3) then
          file.path = strip_prefix(b)
        end
      elseif rest then
        local a, b = rest:match('^(".-[^\\]") (".*")$')
        if a then
          file.old_path, file.path = strip_prefix(a), strip_prefix(b)
        end
      end
      local cc = line:match("^diff %-%-cc (.*)$") or line:match("^diff %-%-combined (.*)$")
      if cc then
        file.path = M.unquote(cc)
      end
    elseif file and not hunk then
      table.insert(file.header, line)
      if line:match("^%-%-%- ") then
        local p = line:sub(5)
        if p ~= "/dev/null" then
          file.old_path = strip_prefix(p)
        end
      elseif line:match("^%+%+%+ ") then
        local p = line:sub(5)
        if p ~= "/dev/null" then
          file.path = strip_prefix(p)
        end
      elseif line:match("^rename from ") then
        file.old_path = M.unquote(line:sub(13))
      elseif line:match("^rename to ") then
        file.path = M.unquote(line:sub(11))
      elseif line:match("^new file mode") then
        file.new_file = true
      elseif line:match("^deleted file mode") then
        file.deleted_file = true
      elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
        file.binary = true
      end
      local h = M.parse_hunk_header(line)
      if h then
        table.remove(file.header)
        hunk = h
        table.insert(file.hunks, h)
      end
    elseif file and hunk then
      local h = M.parse_hunk_header(line)
      if h then
        hunk = h
        table.insert(file.hunks, h)
      else
        table.insert(hunk.lines, line)
      end
    end
  end
  for _, f in ipairs(files) do
    f.path = f.path or f.old_path
    -- a trailing empty line produced by splitting is not part of a hunk
    for _, h in ipairs(f.hunks) do
      while #h.lines > 0 and h.lines[#h.lines] == "" do
        table.remove(h.lines)
      end
    end
  end
  return files
end

---Index files by path.
---@param files fugitive.FileDiff[]
---@return table<string, fugitive.FileDiff>
function M.by_path(files)
  local out = {}
  for _, f in ipairs(files) do
    if f.path then
      out[f.path] = f
    end
  end
  return out
end

---Old/new line numbers of each body line of a hunk (nil where absent).
---@param hunk fugitive.Hunk
---@return {old: integer?, new: integer?}[]
function M.line_numbers(hunk)
  local out = {}
  local o, n = hunk.old_start, hunk.new_start
  for i, l in ipairs(hunk.lines) do
    local c = l:sub(1, 1)
    if c == "-" then
      out[i] = { old = o }
      o = o + 1
    elseif c == "+" then
      out[i] = { new = n }
      n = n + 1
    elseif c == "\\" then
      out[i] = {}
    else
      out[i] = { old = o, new = n }
      o = o + 1
      n = n + 1
    end
  end
  return out
end

---Build a patch containing the selected lines of some hunks of one file.
---
---`reverse = false` builds a patch to apply forwards (staging the selected
---lines of an unstaged diff): unselected "-" lines become context and
---unselected "+" lines are dropped. `reverse = true` builds a patch meant for
---`git apply --reverse` (unstaging from a staged diff, or discarding from
---the work tree): unselected "+" lines become context and unselected "-"
---lines are dropped.
---@param file fugitive.FileDiff
---@param selections {hunk: fugitive.Hunk, lines?: table<integer, boolean>}[] lines=nil means the whole hunk
---@param reverse boolean
---@return string? patch nil when nothing is selected
function M.build_patch(file, selections, reverse)
  local out = {}
  for _, l in ipairs(file.header) do
    table.insert(out, l)
  end
  local any = false
  for _, sel in ipairs(selections) do
    local hunk = sel.hunk
    if hunk.combined then
      return nil
    end
    if not sel.lines then
      table.insert(out, hunk.header)
      vim.list_extend(out, hunk.lines)
      any = true
    else
      local body = {}
      local old_c, new_c = 0, 0
      local changed = false
      local prev_kept = true
      for idx, l in ipairs(hunk.lines) do
        local c = l:sub(1, 1)
        local selected = sel.lines[idx]
        if c == "\\" then
          if prev_kept then
            table.insert(body, l)
          end
        elseif c == "-" then
          if selected then
            table.insert(body, l)
            old_c = old_c + 1
            changed = true
            prev_kept = true
          elseif reverse then
            prev_kept = false
          else
            table.insert(body, " " .. l:sub(2))
            old_c, new_c = old_c + 1, new_c + 1
            prev_kept = true
          end
        elseif c == "+" then
          if selected then
            table.insert(body, l)
            new_c = new_c + 1
            changed = true
            prev_kept = true
          elseif reverse then
            table.insert(body, " " .. l:sub(2))
            old_c, new_c = old_c + 1, new_c + 1
            prev_kept = true
          else
            prev_kept = false
          end
        else
          table.insert(body, l)
          old_c, new_c = old_c + 1, new_c + 1
          prev_kept = true
        end
      end
      if changed then
        any = true
        table.insert(
          out,
          string.format("@@ -%d,%d +%d,%d @@", hunk.old_start, old_c, hunk.new_start, new_c)
        )
        vim.list_extend(out, body)
      end
    end
  end
  if not any then
    return nil
  end
  return table.concat(out, "\n") .. "\n"
end

return M
