local ansi = require("nvim-fugitive.ui.ansi")

local function decode(...)
  local d = ansi.decoder()
  local text, spans = "", {}
  for _, chunk in ipairs({ ... }) do
    local t, s = d:feed(chunk)
    text = text .. t
    vim.list_extend(spans, s)
  end
  return text, spans
end

local function hl(group)
  return vim.api.nvim_get_hl(0, { name = group })
end

describe("ansi decoder", function()
  it("turns SGR sequences into plain text and highlight spans", function()
    local text, spans = decode("* \27[1;34mabc1234\27[m - \27[32mmsg\27[m\n")
    assert.equals("* abc1234 - msg\n", text)
    assert.equals(2, #spans)
    assert.same({ 0, 2, 9 }, { spans[1][1], spans[1][2], spans[1][3] })
    assert.same({ 0, 12, 15 }, { spans[2][1], spans[2][2], spans[2][3] })
    local blue = hl(spans[1][4])
    assert.is_true(blue.bold)
    assert.equals(tonumber(ansi.hex(4):sub(2), 16), blue.fg)
    assert.equals(4, blue.ctermfg)
  end)

  it("keeps a colour open across lines and chunks", function()
    local text, spans = decode("\27[33mone\ntw", "o\27[m three")
    assert.equals("one\ntwo three", text)
    -- row 1 is split by the chunk boundary into two spans of one group
    assert.same({ 0, 0, 3 }, { spans[1][1], spans[1][2], spans[1][3] })
    assert.same({ 1, 0, 2 }, { spans[2][1], spans[2][2], spans[2][3] })
    assert.same({ 1, 2, 3 }, { spans[3][1], spans[3][2], spans[3][3] })
    assert.equals(spans[1][4], spans[3][4])
  end)

  it("waits for an escape sequence cut off at the end of a chunk", function()
    local text, spans = decode("a\27[3", "1mred\27", "[0m")
    assert.equals("ared", text)
    assert.same({ 0, 1, 4 }, { spans[1][1], spans[1][2], spans[1][3] })
  end)

  it("understands 256 colours, truecolor, backgrounds and resets", function()
    local _, spans = decode("\27[38;5;208mo\27[38;2;1;2;3mt\27[44;39mb\27[49;22mn")
    assert.equals(3, #spans)
    assert.equals(208, hl(spans[1][4]).ctermfg)
    assert.equals(tonumber("010203", 16), hl(spans[2][4]).fg)
    assert.equals(4, hl(spans[3][4]).ctermbg)
    assert.is_nil(hl(spans[3][4]).ctermfg)
  end)

  it("drops other escapes and carriage returns", function()
    local text, spans = decode("x\27[Ky\r\n\27]8;;http://x\7link\27]8;;\7")
    assert.equals("xy\nlink", text)
    assert.same({}, spans)
  end)

  it("strips text for notifications", function()
    assert.equals("plain", ansi.strip("plain"))
    assert.equals("ab c", ansi.strip("\27[1;31ma\27[mb \27[Kc"))
  end)
end)
