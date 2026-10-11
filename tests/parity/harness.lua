-- Upstream parity harness (M0/M1): run the same scenario against upstream
-- vim-fugitive in a child Neovim and compare buffer text, repo state and
-- :GBrowse handler dicts with ours. Drop once the integration suite covers
-- the behaviour (see project.md §7).
local H = require("helpers")

local M = {}

---Path of the upstream checkout, or nil (tests become pending).
function M.upstream()
  local dir = vim.env.UPSTREAM
  if dir and vim.uv.fs_stat(dir .. "/autoload/fugitive.vim") then
    return dir
  end
end

---Run Vimscript `lines` in a child Neovim with only upstream fugitive
---loaded, cwd = `cwd`. Returns the decoded JSON written to g:out.
---@param cwd string
---@param lines string[]
---@return any
function M.run_upstream(cwd, lines)
  local out = vim.fn.tempname()
  local script = vim.fn.tempname() .. ".vim"
  local body = {
    "set nomore shortmess+=F",
    "let g:out = " .. vim.fn.string(out),
    "let g:result = v:null",
    "try",
  }
  vim.list_extend(body, lines)
  vim.list_extend(body, {
    "catch",
    "  let g:result = {'error': v:exception}",
    "endtry",
    "call writefile([json_encode(g:result)], g:out)",
    "qa!",
  })
  vim.fn.writefile(body, script)
  local res = vim.system({
    vim.v.progpath,
    "--headless",
    "--clean",
    "-n",
    "-i",
    "NONE",
    "--cmd",
    "set rtp^=" .. M.upstream(),
    "--cmd",
    "runtime plugin/fugitive.vim",
    "-S",
    script,
  }, { cwd = cwd, text = true, env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" } }):wait(30000)
  local f = io.open(out)
  if not f then
    error("upstream run produced no output: " .. (res.stderr or ""))
  end
  local text = f:read("*a")
  f:close()
  return vim.json.decode(text)
end

---Deterministic commit environment so object ids are reproducible.
M.env = {
  GIT_AUTHOR_DATE = "2024-01-01T00:00:00Z",
  GIT_COMMITTER_DATE = "2024-01-01T00:00:00Z",
}

---A repo whose commits have fixed ids.
function M.repo(files)
  local repo = H.repo()
  if files then
    for k, v in pairs(files) do
      repo:write(k, v)
    end
    repo:git("add", "-A")
    repo:git("commit", "-q", "-m", "initial", { env = M.env })
  end
  return repo
end

function M.commit(repo, msg, files)
  for k, v in pairs(files or {}) do
    repo:write(k, v)
  end
  repo:git("add", "-A")
  repo:git("commit", "-q", "--allow-empty", "-m", msg, { env = M.env })
end

---Our summary lines for `repo`.
function M.our_summary(repo)
  H.reset_ui()
  vim.cmd("cd " .. vim.fn.fnameescape(repo.root))
  vim.cmd("Git")
  return H.lines(0)
end

---Upstream's summary lines.
function M.upstream_summary(repo)
  return M.run_upstream(repo.root, { "Git", "let g:result = getline(1, '$')" })
end

return M.run_upstream(repo.root, { "Git", "let g:result = getline(1, '$')" })
end

---Vimscript that registers a capturing GBrowse handler.
M.capture_handler = {
  "let g:captured = []",
  "function! Capture(opts) abort",
  "  call add(g:captured, a:opts)",
  "  return ''",
  "endfunction",
  "let g:fugitive_browse_handlers = [function('Capture')]",
}

---Normalise machine-specific values in a dict (the repo root).
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
