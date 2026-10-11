local exec = require("fugitive.git.exec")

describe("exec.build", function()
  it("adds the common flags and a non-interactive env", function()
    local cmd, opts = exec.build({ "status" }, { cwd = "/tmp" })
    assert.same({ "git", "--no-optional-locks", "-c", "core.quotepath=false", "-c", "color.ui=never", "status" }, cmd)
    assert.equals("0", opts.env.GIT_TERMINAL_PROMPT)
    assert.equals("/tmp", opts.cwd)
    assert.truthy(opts.env.GIT_EDITOR:match("editor%.sh"))
  end)

  it("translates -c sequence.editor into the environment", function()
    local cmd, opts = exec.build({ "-c", "sequence.editor=true", "rebase", "-i" }, {})
    assert.equals("true", opts.env.GIT_SEQUENCE_EDITOR)
    assert.is_nil(vim.tbl_contains(cmd, "sequence.editor=true") and true or nil)
    assert.equals("rebase", cmd[#cmd - 1])
  end)

  it("wires the editor service for foreground commands", function()
    local cmd, opts, id = exec.build({ "commit" }, { editor = true })
    assert.truthy(vim.tbl_contains(cmd, "advice.waitingForEditor=false"))
    assert.equals("1", opts.env.GIT_MERGE_AUTOEDIT)
    assert.equals(id, opts.env.FUGITIVE_EDITOR_ID)
    assert.equals(vim.v.servername, opts.env.NVIM)
    assert.is_true(opts.detach)
  end)

  it("uses an injectable runner", function()
    local seen
    exec.set_runner(function(cmd, _, on_exit)
      seen = cmd
      local res = { code = 0, signal = 0, stdout = "fake\n", stderr = "" }
      if on_exit then
        on_exit(res)
      end
      return {
        pid = 1,
        wait = function()
          return res
        end,
        kill = function() end,
      }
    end)
    local ok, err = pcall(function()
      assert.equals("fake", exec.chomp({ "rev-parse", "HEAD" }))
      assert.equals("rev-parse", seen[#seen - 1])
    end)
    exec.set_runner(nil)
    assert(ok, err)
  end)
end)
