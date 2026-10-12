-- :GBrowse scenarios shared by the parity harness (which captures
-- upstream's dicts into tests/fixtures/browse_upstream.json) and the
-- integration test (which compares ours against that fixture).
local H = require("helpers")

-- fixed dates make commit ids reproducible across machines
local env = {
  GIT_AUTHOR_DATE = "2024-01-01T00:00:00Z",
  GIT_COMMITTER_DATE = "2024-01-01T00:00:00Z",
}

local function commit(repo, msg, files)
  for k, v in pairs(files) do
    repo:write(k, v)
  end
  repo:git("add", "-A")
  repo:git("commit", "-q", "-m", msg, { env = env })
end

local capture_handler = {
  "let g:captured = []",
  "function! Capture(opts) abort",
  "  call add(g:captured, a:opts)",
  "  return ''",
  "endfunction",
  "let g:fugitive_browse_handlers = [function('Capture')]",
}

local M = {}

M.file = "dir/my file #1 %.txt"

---Build the fixture repository (deterministic commit ids).
function M.setup()
  local repo = H.repo()
  commit(repo, "initial", { [M.file] = "one\ntwo\nthree\nfour\n", ["dir/other.txt"] = "x\n" })
  commit(repo, "second", { ["dir/other.txt"] = "y\n" })
  repo:git("remote", "add", "origin", "https://github.com/user/repo.git")
  repo:git("update-ref", "refs/remotes/origin/main", "HEAD")
  repo:git("config", "branch.main.remote", "origin")
  repo:git("config", "branch.main.merge", "refs/heads/main")
  repo:git("tag", "v1.0", "HEAD~1")
  return repo
end

-- name, file to edit (repo-relative, "" for none, ":summary" for :Git),
-- range prefix, argument
M.cases = {
  { "blob", M.file, "", "" },
  { "line", M.file, "2", "" },
  { "range", M.file, "2,3", "" },
  { "zero-range", M.file, "0", "" },
  { "tree", "", "", "dir/" },
  { "commit", "", "", "HEAD~1" },
  { "ref-branch", "", "", "main" },
  { "ref-tag", "", "", "v1.0" },
  { "rev-path", "", "", "HEAD~1:dir/other.txt" },
  { "root", ":summary", "", "" },
  { "remote", M.file, "", "@origin" },
  { "remote-ref", "", "", "origin/main" },
}

---Vimscript lines that run every case in upstream and collect dicts.
function M.upstream_script(root)
  local lines = vim.deepcopy(capture_handler)
  table.insert(lines, "let g:result = {}")
  for _, c in ipairs(M.cases) do
    local name, file, range, arg = c[1], c[2], c[3], c[4]
    table.insert(lines, "let g:captured = []")
    if file == ":summary" then
      table.insert(lines, "silent Git")
    elseif file ~= "" then
      table.insert(lines, "silent edit " .. vim.fn.fnameescape(root .. "/" .. file))
    else
      table.insert(lines, "silent enew")
    end
    table.insert(lines, "silent! exe '" .. range .. "GBrowse! " .. arg:gsub("'", "''") .. "'")
    table.insert(lines, "let g:result[" .. vim.fn.string(name) .. "] = get(g:captured, 0, v:null)")
  end
  return lines
end

---Run every case with our :GBrowse; returns name -> dict.
function M.ours(root)
  local captured = {}
  vim.cmd([[
    function! FugitiveTestCapture(opts) abort
      call add(g:fugitive_test_captured, a:opts)
      return ''
    endfunction
  ]])
  vim.cmd("let g:fugitive_browse_handlers = [function('FugitiveTestCapture')]")
  local orig = vim.notify
  vim.notify = function() end
  for _, c in ipairs(M.cases) do
    local name, file, range, arg = c[1], c[2], c[3], c[4]
    vim.g.fugitive_test_captured = {}
    H.reset_ui()
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    if file == ":summary" then
      vim.cmd("Git")
    elseif file ~= "" then
      vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. file))
    else
      vim.cmd("enew")
    end
    -- ! copies instead of opening: the dict passed to handlers is identical
    pcall(vim.cmd, range .. "GBrowse! " .. arg)
    captured[name] = vim.g.fugitive_test_captured[1] or vim.NIL
  end
  vim.notify = orig
  vim.g.fugitive_browse_handlers = nil
  return captured
end

---Replace the machine-specific repo root in captured values.
function M.normalize(value, root)
  if type(value) == "string" then
    return (value:gsub(vim.pesc(root), "<ROOT>"))
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = M.normalize(v, root)
    end
    return out
  end
  return value
end

return M
