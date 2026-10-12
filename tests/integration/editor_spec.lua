local H = require("helpers")
local editor = require("nvim-fugitive.buffers.editor")
local output = require("nvim-fugitive.ui.output")

---Wait for an editor buffer whose name matches `pattern`.
local function wait_editor(pattern)
  local found
  H.wait(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_loaded(b)
        and vim.api.nvim_buf_get_name(b):match(pattern)
        and vim.b[b].fugitive_editor
      then
        found = b
        return true
      end
    end
  end, "editor buffer " .. pattern, 10000)
  return found
end

local function focus(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  vim.api.nvim_set_current_win(win)
end

local function wait_done(entry_before)
  H.wait(function()
    local e = output.get(1)
    return e and e ~= entry_before and not e.running
  end, "command completion", 10000)
  return output.get(1)
end

---Overseer stub: runs the command with vim.system and reports like overseer.
local function overseer_stub()
  local created = {}
  local stub = {}
  function stub.new_task(def)
    local task = { def = def, subs = {}, status = "PENDING" }
    table.insert(created, task)
    function task:subscribe(event, cb)
      self.subs[event] = self.subs[event] or {}
      table.insert(self.subs[event], cb)
    end
    function task:start()
      self.status = "RUNNING"
      self.proc = vim.system(def.cmd, { cwd = def.cwd, env = def.env, text = true }, function(res)
        vim.schedule(function()
          if self.status == "CANCELED" then
            res.code = -1
          end
          self.output = (res.stdout or "") .. (res.stderr or "")
          self.exit_code = res.code
          if self.status ~= "CANCELED" then
            self.status = res.code == 0 and "SUCCESS" or "FAILURE"
          end
          for _, cb in ipairs(self.subs.on_complete or {}) do
            cb(self, self.status)
          end
        end)
      end)
    end
    function task:stop()
      self.status = "CANCELED"
      if self.proc then
        self.proc:kill("sigterm")
      end
    end
    function task:get_bufnr()
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(self.output or "", "\n"))
      return b
    end
    return task
  end
  return stub, created
end

describe("editor service", function()
  local log, restore
  before_each(function()
    H.reset_ui()
    log, restore = H.capture_notify()
    package.loaded.overseer = nil
  end)
  after_each(function()
    restore()
    package.loaded.overseer = nil
    package.preload.overseer = nil
  end)

  it("has a server to call back into", function()
    assert.is_true(editor.available())
  end)

  it("commit: :wq creates the commit", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    repo:git("add", "a")
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git commit")
    local buf = wait_editor("COMMIT_EDITMSG$")
    assert.equals("gitcommit", vim.bo[buf].filetype)
    focus(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "my message" })
    vim.cmd("wq")
    local e = wait_done(before)
    assert.equals(0, e.code)
    assert.equals("my message", vim.trim(repo:git("log", "-1", "--format=%s")))
    assert.equals(0, editor.pending())
  end)

  it("commit: :q! aborts, no commit is created", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local head = repo:rev("HEAD")
    repo:write("a", "A\n")
    repo:git("add", "a")
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git commit")
    local buf = wait_editor("COMMIT_EDITMSG$")
    focus(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "never" })
    vim.cmd("q!")
    local e = wait_done(before)
    assert.are_not.equals(0, e.code)
    assert.equals(head, repo:rev("HEAD"))
    assert.equals("M  a\n", repo:status())
  end)

  it("commit: a bare :q refuses to close (buffer counts as modified)", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:write("a", "A\n")
    repo:git("add", "a")
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git commit -v")
    local buf = wait_editor("COMMIT_EDITMSG$")
    focus(buf)
    assert.has_error(function()
      vim.cmd("q")
    end)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "via ZZ" })
    vim.cmd("x")
    wait_done(before)
    assert.equals("via ZZ", vim.trim(repo:git("log", "-1", "--format=%s")))
  end)

  it("rebase -i: dropping a commit in the todo changes history", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:commit("second", { ["b"] = "b\n" })
    repo:commit("third", { ["c"] = "c\n" })
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git rebase -i HEAD~2")
    local buf = wait_editor("git%-rebase%-todo$")
    assert.equals("gitrebase", vim.bo[buf].filetype)
    focus(buf)
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.truthy(first:match("^pick %x+ #? ?second"))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { (first:gsub("^pick", "drop")) })
    vim.cmd("wq")
    local e = wait_done(before)
    assert.equals(0, e.code, e.stderr)
    assert.equals("third\ninitial\n", repo:git("log", "--format=%s"))
  end)

  it("rebase -i: aborting the todo leaves history unchanged", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    repo:commit("second", { ["b"] = "b\n" })
    local head = repo:rev("HEAD")
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git rebase -i HEAD~1")
    local buf = wait_editor("git%-rebase%-todo$")
    focus(buf)
    vim.cmd("bwipeout!")
    wait_done(before)
    assert.equals(head, repo:rev("HEAD"))
    assert.is_nil(vim.uv.fs_stat(repo.root .. "/.git/rebase-merge"))
  end)

  local function diverged()
    local origin = H.repo({ files = { ["f"] = "1\n" } })
    local clone = H.clone(origin)
    clone:git("config", "pull.rebase", "false")
    origin:commit("remote side", { ["r"] = "r\n" })
    clone:commit("local side", { ["l"] = "l\n" })
    return origin, clone
  end

  it("pull: the merge commit editor appears for an overseer task", function()
    local stub, created = overseer_stub()
    package.loaded.overseer = stub
    local _, clone = diverged()
    vim.cmd("cd " .. clone.root)
    vim.cmd("Git pull")
    assert.equals(1, #created)
    assert.equals("git pull", created[1].def.name)
    local buf = wait_editor("MERGE_MSG$")
    focus(buf)
    vim.cmd("wq")
    H.wait(function()
      return created[1].status == "SUCCESS"
    end, "overseer task", 10000)
    assert.equals(2, #vim.split(vim.trim(clone:git("log", "-1", "--format=%P")), " "))
    H.wait(function()
      return vim.iter(log):any(function(m)
        return m.msg:match("git pull: done")
      end)
    end, "completion notification")
  end)

  it("pull: works with the fallback runner when overseer is absent", function()
    package.preload.overseer = function()
      error("not installed")
    end
    local _, clone = diverged()
    vim.cmd("cd " .. clone.root)
    vim.cmd("Git pull")
    assert.truthy(vim.iter(log):any(function(m)
      return m.msg:match("git pull: running")
    end))
    local buf = wait_editor("MERGE_MSG$")
    focus(buf)
    vim.cmd("wq")
    H.wait(function()
      return #vim.split(vim.trim(clone:git("log", "-1", "--format=%P")), " ") == 2
    end, "merge commit", 10000)
  end)

  it("cancellation mid-edit kills git, closes the buffer, leaves the repo unchanged", function()
    local stub, created = overseer_stub()
    package.loaded.overseer = stub
    local _, clone = diverged()
    local head = clone:rev("HEAD")
    vim.cmd("cd " .. clone.root)
    vim.cmd("Git pull")
    local buf = wait_editor("MERGE_MSG$")
    local id = vim.b[buf].fugitive_editor
    editor.cancel(id)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    H.wait(function()
      return created[1].status == "CANCELED" and created[1].exit_code ~= nil
    end, "task stopped", 10000)
    -- git aborted the merge: HEAD unchanged
    assert.equals(head, clone:rev("HEAD"))
    assert.truthy(vim.iter(log):any(function(m)
      return m.msg:match("editor closed")
    end))
  end)

  it("cancellation of a foreground job closes its editor", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local head = repo:rev("HEAD")
    repo:write("a", "A\n")
    repo:git("add", "a")
    vim.cmd("cd " .. repo.root)
    local job = require("nvim-fugitive").git("commit")
    local buf = wait_editor("COMMIT_EDITMSG$")
    editor.cancel(job.editor_id)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    H.wait(function()
      return job.done
    end, "job killed", 10000)
    assert.equals(head, repo:rev("HEAD"))
  end)

  it(":Git! aborts edits instead of hanging", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    local head = repo:rev("HEAD")
    repo:write("a", "A\n")
    repo:git("add", "a")
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git! commit")
    local e = wait_done(before)
    assert.are_not.equals(0, e.code)
    assert.truthy(e.stderr:match("aborting edit due to background operation"))
    assert.equals(head, repo:rev("HEAD"))
    assert.equals(0, editor.pending())
  end)

  it("queues concurrent requests per repository", function()
    local repo = H.repo({ files = { ["a"] = "a\n" } })
    vim.cmd("cd " .. repo.root)
    local before = output.get(1)
    vim.cmd("Git config --edit")
    local b1 = wait_editor("config$")
    -- a second request for the same repo waits for the first
    vim.cmd("Git notes add HEAD")
    vim.wait(300)
    local open = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.b[b].fugitive_editor then
        open = open + 1
      end
    end
    assert.equals(1, open)
    assert.equals(2, editor.pending())
    focus(b1)
    vim.cmd("wq")
    local b2 = wait_editor("NOTES_EDITMSG$")
    focus(b2)
    vim.api.nvim_buf_set_lines(b2, 0, 0, false, { "a note" })
    vim.cmd("wq")
    H.wait(function()
      return editor.pending() == 0 and output.get(1) ~= before and not output.get(1).running
    end, "both done", 10000)
    H.wait(function()
      return vim.trim(repo:git("notes", "show", "HEAD", { allow_fail = true })) == "a note"
    end, "note", 5000)
  end)
end)

describe("editor queue keys", function()
  it("keeps one queue per repository", function()
    local exec = require("nvim-fugitive.git.exec")
    local a = H.repo({ files = { ["a"] = "a\n" } })
    local b = H.repo({ files = { ["b"] = "b\n" } })
    local ra = require("nvim-fugitive.git.repo").find(a.root)
    local rb = require("nvim-fugitive.git.repo").find(b.root)
    local _, _, ida = exec.build({ "commit" }, { repo = ra, editor = true })
    local _, _, idb = exec.build({ "commit" }, { repo = rb, editor = true })
    assert.equals(ra, editor._jobs[ida].repo)
    assert.equals(rb, editor._jobs[idb].repo)
    editor._jobs[ida], editor._jobs[idb] = nil, nil
  end)
end)
