-- Main screen: your status and the parties you're in.
local ui = require("ui")
local Core = require("core")
local app = require("app")
local common = require("screens.common")
local theme = require("theme")
local c = theme.c

local screen = {}
local MAX_ROWS = 4

local function partyHeight(p)
  local shown = math.min(#(p.members or {}), MAX_ROWS)
  local extra = #(p.members or {}) > MAX_ROWS and 34 or 0
  return 52 + shown * 52 + extra + 8
end

local function statusText(p)
  if p.status == "online" then
    return ("%d / %d online"):format(app.onlineCount(p), #(p.members or {}))
  elseif p.status == "connecting" then
    return "Connecting…"
  elseif p.status == "error" then
    return "Can't connect · retrying"
  end
  return "Offline"
end

local function drawParty(p, x, y, w)
  local h = partyHeight(p)
  ui.card(x, y, w, h)
  ui.label(ui.truncate(p.name, w - 150, "semibold"), x + 16, y + 14, w - 150, 24, "semibold", c.text)
  local unread = app.unread(p)
  local rx = x + w - 16
  if unread > 0 then
    rx = rx - ui.badge(tostring(unread), rx, y + 26) - 8
  end
  ui.label(statusText(p), x + 16, y + 14, rx - x - 16, 24, "small", p.status == "error" and c.busy or c.muted, "right")

  local rowY = y + 48
  local members = app.sortedMembers(p)
  for i = 1, math.min(#members, MAX_ROWS) do
    local m = members[i]
    local host = app.hostOf(p, m.key)
    local me = m.key == app.myKey()
    local state = host and "online" or (m.online and "online" or "off")
    ui.dot(x + 22, rowY + 26, state)
    local name = m.name .. (me and " (you)" or "")
    ui.label(ui.truncate(name, w - 150, "medium"), x + 38, rowY + 6, w - 150, 22, "medium", m.online and c.text or c.muted)
    local sub
    if host then
      sub = "Hosting " .. (host.label or host.game)
    elseif m.online then
      sub = m.role == "owner" and "Online · owner" or (m.role == "admin" and "Online · admin" or "Online")
    else
      sub = app.seenText(m.lastSeen)
    end
    ui.label(ui.truncate(sub, w - 150, "small"), x + 38, rowY + 26, w - 150, 18, "small", c.muted)
    if host and not me then
      if ui.button("Join", x + w - 84, rowY + 6, 68, 40, "join", { radius = 20, font = "semiboldSm" }) then
        ui.toast("Joining games comes in the next PartyPort update. For now you can chat and see who's hosting.", 5)
      end
    end
    rowY = rowY + 52
  end
  if #members > MAX_ROWS then
    ui.label(("+ %d more"):format(#members - MAX_ROWS), x + 38, rowY, w - 54, 26, "small", c.muted)
  end
  -- Checked last so the Join buttons inside the card get their clicks first.
  local hit = ui.clicked(x, y, w, h)
  return h, hit
end

local function drawEmpty(x, y, w)
  ui.card(x, y, w, 196)
  ui.label("You're not in any parties yet", x, y + 22, w, 24, "semibold", c.text, "center")
  ui.wrapped("Start one and invite friends, or join with an invite code someone sent you.", x + 24, y + 52, w - 48, "bodySm", c.muted, "center")
  if ui.button("Start a party", x + 16, y + 118, (w - 44) / 2, 48, "primary") then
    app.joinTab = "start"
    app.go("join")
  end
  if ui.button("Join with code", x + 28 + (w - 44) / 2, y + 118, (w - 44) / 2, 48, "secondary") then
    app.joinTab = "join"
    app.go("join")
  end
end

function screen.draw()
  local st = Core.state
  ui.label("Parties", 20, 22, ui.w - 100, 36, "title", c.text)
  if ui.iconButton("plus", ui.w - 64, 18, 44, { fill = c.surface }) then
    app.joinTab = nil
    app.go("join")
  end

  -- You: power button and status
  local x, w = 16, ui.w - 32
  local y = 76
  ui.card(x, y, w, 80)
  local online = st.online
  local btnCol = online and c.accent or c.off
  if ui.iconButton("power", x + 16, y + 14, 52, {
    fill = online and c.accentBg or c.surface2, border = btnCol, color = btnCol, iconSize = 24,
  }) then
    Core.request("setOnline", { online = not online }, function(ok, err)
      if not ok then ui.toast(app.errorText(err)) end
    end)
  end
  ui.label(ui.truncate(st.name, w - 110, "semibold"), x + 84, y + 18, w - 100, 24, "semibold", c.text)
  local n = #(st.parties or {})
  local sub = online and (n == 1 and "Online · 1 party" or ("Online · %d parties"):format(n)) or "Offline · tap to go online"
  ui.label(sub, x + 84, y + 42, w - 100, 20, "bodySm", c.muted)

  -- Party list (scrolls)
  local top = y + 96
  local bottom = ui.h - common.NAV_H
  local listH = bottom - top
  local total = 0
  for _, p in ipairs(st.parties) do total = total + partyHeight(p) + 12 end
  if #st.parties == 0 then total = 210 end
  local off = (ui.scroll.parties or 0) + ui.scrollDelta("parties", 0, top, ui.w, listH)
  off = math.max(0, math.min(off, math.max(0, total - listH + 12)))
  ui.scroll.parties = off

  ui.pushClip(0, top, ui.w, listH)
  local cy = top - off
  if #st.parties == 0 then
    drawEmpty(x, cy, w)
  end
  for _, p in ipairs(st.parties) do
    local h, hit = drawParty(p, x, cy, w)
    if hit then app.go("chat", p.id) end
    cy = cy + h + 12
  end
  ui.popClip()

  common.nav("parties")
end

return screen
