-- PartyPort default theme. Colours are the ones from the mockups.
local function hex(h, a)
  h = h:gsub("#", "")
  return {
    tonumber(h:sub(1, 2), 16) / 255,
    tonumber(h:sub(3, 4), 16) / 255,
    tonumber(h:sub(5, 6), 16) / 255,
    a or 1,
  }
end

local theme = {
  name = "PartyPort",
  c = {
    bg = hex("#111418"),
    bgDeep = hex("#0B0E12"),
    nav = hex("#0E1115"),
    surface = hex("#161B21"),
    surface2 = hex("#1F252D"),
    line = hex("#2A313A"),
    line2 = hex("#3A4350"),
    text = hex("#E7EBF0"),
    text2 = hex("#C4CCD6"),
    muted = hex("#9AA4B2"),
    faint = hex("#8590A0"),
    accent = hex("#4ADE80"),
    accentInk = hex("#0B1A10"),
    accentBg = hex("#12261A"),
    accentLine = hex("#23462F"),
    mine = hex("#1E3B2A"),
    busy = hex("#F5B83D"),
    off = hex("#5B6573"),
    joinBg = hex("#1D3A5C"),
    joinText = hex("#BFDBFE"),
    danger = hex("#FCA5A5"),
    dangerBg = hex("#2A1515"),
    dangerLine = hex("#5C2A2A"),
    names = { hex("#93C5FD"), hex("#FCD34D"), hex("#F9A8D4"), hex("#86EFAC"), hex("#C4B5FD"), hex("#FDBA74"), hex("#67E8F9") },
  },
  radius = { card = 16, button = 12, pill = 999, input = 10 },
}

theme.hex = hex
return theme
