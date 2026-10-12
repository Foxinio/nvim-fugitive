local object = require("nvim-fugitive.object")

describe("object URLs", function()
  it("round-trips commit, stage and path", function()
    local sha = string.rep("a", 40)
    local url = object.format("/r/.git", sha, "dir/file.lua")
    assert.equals("fugitive:///r/.git//" .. sha .. "/dir/file.lua", url)
    assert.same({ git_dir = "/r/.git", commit = sha, path = "dir/file.lua" }, object.parse(url))
    assert.same(
      { git_dir = "/r/.git", commit = "0", path = "x" },
      object.parse("fugitive:///r/.git//0/x")
    )
    assert.same({ git_dir = "/r/.git", commit = sha }, object.parse("fugitive:///r/.git//" .. sha))
  end)

  it("treats a trailing slash as the root tree", function()
    local sha = string.rep("b", 40)
    assert.same(
      { git_dir = "/r/.git", commit = sha, path = nil },
      object.parse("fugitive:///r/.git//" .. sha)
    )
    assert.equals("", object.parse("fugitive:///r/.git//" .. sha .. "/").path)
  end)

  it("encodes %, #, ? and control characters like upstream", function()
    local url = object.format("/a b/.git", "0", "50% #1?.txt")
    assert.equals("fugitive:///a b/.git//0/50%25 %231%3F.txt", url)
    assert.equals("50% #1?.txt", object.parse(url).path)
  end)

  it("handles git dirs containing //-like segments and sha256", function()
    local sha = string.rep("c", 64)
    local p = object.parse("fugitive:///x/y/.git//" .. sha .. "/f")
    assert.equals(sha, p.commit)
  end)

  it("rejects non-fugitive and malformed URLs", function()
    assert.is_nil(object.parse("/tmp/file"))
    assert.is_nil(object.parse("fugitive:///r/.git//zz/file"))
    assert.is_nil(object.parse("fugitive:///r/.git//7/file"))
  end)

  it("url_encode matches upstream s:UrlEncode", function()
    assert.equals(
      "a%20b%23c%3Fd%26e%3Bf%2Bg%3Dh%5Ci%3Cj%3Ek%25",
      object.url_encode("a b#c?d&e;f+g=h\\i<j>k%")
    )
  end)
end)

describe("object.parse_rev", function()
  it("parses the reduced syntax", function()
    assert.same({ kind = "stage", stage = 0, path = "f" }, object.parse_rev(":f"))
    assert.same({ kind = "stage", stage = 2, path = "a/b" }, object.parse_rev(":2:a/b"))
    assert.same({ kind = "rev", rev = "HEAD~3", path = "f" }, object.parse_rev("HEAD~3:f"))
    assert.same({ kind = "rev", rev = "main", path = "" }, object.parse_rev("main:"))
    assert.same({ kind = "commit", rev = "v1.0" }, object.parse_rev("v1.0"))
    assert.same({ kind = "rev", rev = "@{u}", path = "x" }, object.parse_rev("@{u}:x"))
    assert.same(
      { kind = "rev", rev = "HEAD@{1.day.ago}", path = "x" },
      object.parse_rev("HEAD@{1.day.ago}:x")
    )
  end)

  it("returns nil for unexpanded and empty forms", function()
    assert.same({ kind = "commit", rev = ":/fix bug" }, object.parse_rev(":/fix bug"))
    assert.is_nil(object.parse_rev("!"))
    assert.is_nil(object.parse_rev(""))
  end)

  it("names git objects from parsed URLs", function()
    assert.equals(":0:f", object.git_name({ git_dir = "", commit = "0", path = "f" }))
    assert.equals("abc:f", object.git_name({ git_dir = "", commit = "abc", path = "f" }))
    assert.equals("abc", object.git_name({ git_dir = "", commit = "abc" }))
  end)
end)
