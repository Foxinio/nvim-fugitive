local config = require("nvim-fugitive.config")

describe("config.merge", function()
  it("returns defaults without options", function()
    local c = config.merge()
    assert.equals("stage", c.maps.summary["s"])
    assert.equals(10, c.notify.max_lines)
    assert.same({}, c.args)
  end)

  it("merges map tables key by key and keeps false", function()
    local c = config.merge({ maps = { summary = { s = false, a = "stage" } } })
    assert.is_false(c.maps.summary["s"])
    assert.equals("stage", c.maps.summary["a"])
    assert.equals("unstage", c.maps.summary["u"])
  end)

  it("replaces lists and deep-merges tables", function()
    local c = config.merge({ long_running = { "fetch" }, float = { width = 0.5 } })
    assert.same({ "fetch" }, c.long_running)
    assert.equals(0.5, c.float.width)
    assert.equals(0.85, c.float.height)
  end)

  it("keeps the defaults of an option given as an empty table", function()
    local c = config.merge({ summary = {}, float = {} })
    assert.equals(256, c.summary.log_limit)
    assert.equals(0.85, c.float.height)
    assert.same({}, config.merge({ long_running = {} }).long_running)
  end)

  it("does not mutate the defaults", function()
    config.merge({ maps = { summary = { s = false } } })
    assert.equals("stage", config.defaults.maps.summary["s"])
  end)

  it("rejects invalid input", function()
    assert.has_error(function()
      config.merge({ routes = { log = "printer" } })
    end)
    assert.has_error(function()
      config.merge({ maps = { nope = {} } })
    end)
    assert.has_error(function()
      config.merge({ maps = { summary = { s = 42 } } })
    end)
    assert.has_error(function()
      config.merge({ notify = { max_lines = "ten" } })
    end)
    for _, bad in ipairs({
      { commit = "--signoff" },
      { commit = { 1 } },
      { ["reset --hard"] = { "-q" } },
      { ["remote add origin"] = { "-f" } },
    }) do
      assert.is_false(pcall(config.merge, { args = bad }), vim.inspect(bad))
    end
    for _, bad in ipairs({
      { tree = "yes" },
      { compact = 1 },
      { paths = "relative" },
      { status = "letter" },
      { status = { letters = "yes" } },
      { status = { color = "on" } },
      { status = { color = { enabled = 1 } } },
      { status = { color = { from = "text" } } },
      { status = { color = { to = "eol" } } },
    }) do
      assert.is_false(pcall(config.merge, { summary = bad }), vim.inspect(bad))
    end
  end)

  it("defaults to the tree look, and takes the upstream one", function()
    local s = config.merge().summary
    assert.same({
      tree = true,
      compact = true,
      paths = "full",
      status = { letters = false, color = { enabled = true, from = "name", to = "line" } },
    }, { tree = s.tree, compact = s.compact, paths = s.paths, status = s.status })
    s = config.merge({
      summary = {
        tree = false,
        paths = "name",
        status = { letters = true, color = { enabled = false } },
      },
    }).summary
    assert.is_false(s.tree)
    assert.equals("name", s.paths)
    assert.same(
      { letters = true, color = { enabled = false, from = "name", to = "line" } },
      s.status
    )
    assert.equals("split", s.window)
  end)

  it("merges a partial status table with the defaults", function()
    local s = config.merge({ summary = { status = { color = { to = "name" } } } }).summary
    assert.same(
      { letters = false, color = { enabled = true, from = "name", to = "name" } },
      s.status
    )
  end)

  it("says the string form of status was replaced", function()
    local ok, err = pcall(config.merge, { summary = { status = "letter" } })
    assert.is_false(ok)
    assert.truthy(tostring(err):match("summary%.status is now a table"))
  end)
end)
