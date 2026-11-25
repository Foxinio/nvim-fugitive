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
    for _, bad in ipairs({ { recheck = -1 }, { recheck = "5s" } }) do
      assert.is_false(pcall(config.merge, { watch = bad }), vim.inspect(bad))
    end
    assert.equals(5000, config.merge().watch.recheck)
    assert.equals(0, config.merge({ watch = { recheck = 0 } }).watch.recheck)
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

describe("config key presets", function()
  local config = require("nvim-fugitive.config")

  it("differ only in the summary's co/cb keys, and default is the default", function()
    for buftype, maps in pairs(config.presets.upstream) do
      if buftype ~= "summary" then
        assert.same(maps, config.presets.default[buftype])
      end
    end
    local up, def = config.presets.upstream.summary, config.presets.default.summary
    for _, lhs in ipairs({ "coo", "co<Space>", "co<CR>", "cb<Space>", "cb<CR>" }) do
      assert.is_not_nil(up[lhs])
      assert.is_nil(def[lhs])
    end
    assert.same(
      { "choose_ours", "choose_theirs", "choose_both", "choose_none" },
      { def.co, def.ct, def.cb, def.c0 }
    )
    assert.is_nil(up.co)
    assert.same(config.presets.default, config.merge({}).maps)
    assert.same(config.presets.upstream, config.merge({ maps = { preset = "upstream" } }).maps)
  end)

  it("upstream maps vim-fugitive's keys to the right actions", function()
    local up = config.presets.upstream.summary
    local expect = {
      s = "stage",
      u = "unstage",
      ["-"] = "toggle",
      U = "unstage_all",
      X = "discard",
      ["="] = "inline_toggle",
      ["<"] = "inline_hide",
      [">"] = "inline_show",
      I = "patch",
      P = "patch",
      ["<CR>"] = "open",
      o = "open_split",
      gO = "open_vsplit",
      O = "open_tab",
      dd = "diff",
      dv = "diff_vertical",
      cc = "commit",
      ca = "commit_amend",
      cf = "commit_fixup",
      crc = "revert",
      coo = "checkout",
      ["co<Space>"] = "checkout_prompt",
      ["co<CR>"] = "checkout_bare",
      ["cb<Space>"] = "branch_prompt",
      ["cb<CR>"] = "branch_bare",
      czz = "stash_push",
      czp = "stash_pop_index",
      ri = "rebase_interactive",
      rr = "rebase_continue",
      gq = "close",
      ["g?"] = "help",
    }
    for lhs, action in pairs(expect) do
      assert.equals(action, up[lhs], lhs)
    end
    assert.same(
      { co = "choose_ours", ct = "choose_theirs", cb = "choose_both", c0 = "choose_none" },
      {
        co = config.presets.upstream.conflict.co,
        ct = config.presets.upstream.conflict.ct,
        cb = config.presets.upstream.conflict.cb,
        c0 = config.presets.upstream.conflict.c0,
      }
    )
  end)

  it("upstream names only actions that exist", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local tables = {
      summary = require("nvim-fugitive.buffers.summary.actions").actions(buf),
      blame = require("nvim-fugitive.buffers.blame").actions(buf),
      conflict = require("nvim-fugitive.conflict").actions(buf),
      pager = { close = true, cancel = true },
    }
    -- object actions are put together per object type in reader.lua
    local f = assert(io.open("lua/nvim-fugitive/buffers/reader.lua"))
    local reader = f:read("*a")
    f:close()
    for buftype, maps in pairs(config.presets.upstream) do
      for lhs, action in pairs(maps) do
        if type(action) == "string" then
          local ok
          if tables[buftype] then
            ok = tables[buftype][action] ~= nil
          else
            ok = reader:find("%f[%w_]" .. action .. "%s*=") ~= nil
          end
          assert.is_true(ok, string.format("maps.%s[%q] = %q has no action", buftype, lhs, action))
        end
      end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("take the user's maps on top, false included", function()
    for _, preset in ipairs({ "default", "upstream" }) do
      local maps =
        config.merge({ maps = { preset = preset, summary = { X = false, D = "discard" } } }).maps
      assert.is_false(maps.summary.X)
      assert.equals("discard", maps.summary.D)
      assert.equals("stage", maps.summary.s)
    end
  end)

  it("reject an unknown preset", function()
    local ok, err = pcall(config.merge, { maps = { preset = "vim" } })
    assert.is_false(ok)
    assert.truthy(tostring(err):match('maps%.preset must be "default" or "upstream"'))
  end)

  it("give the summary hints the preset's keys", function()
    local saved = config.presets.upstream.summary.X
    config.presets.upstream.summary.X = nil
    config.presets.upstream.summary.Q = "discard"
    config.set({ maps = { preset = "upstream" } })
    local ok, k = pcall(require("nvim-fugitive.buffers.summary").hint_keys)
    config.presets.upstream.summary.Q = nil
    config.presets.upstream.summary.X = saved
    config.set({})
    assert.is_true(ok, k)
    assert.equals("(s: stage) (dv: diff) (Q: discard)", k.Unstaged)
  end)
end)
