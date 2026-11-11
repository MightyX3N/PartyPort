local ui = require("ui")
local app = require("app")
local theme = require("theme")
local c = theme.c

local common = {}

common.NAV_H = 76

--- Screen header with a back button and title. Returns the header height.
function common.header(title, subtitle, onBack)
  local h = 64
  if onBack and ui.iconButton("back", 12, 10, 44, { border = false, iconSize = 22 }) then onBack() end
  local x = onBack and 60 or 20
  if subtitle then
    ui.label(ui.truncate(title, ui.w - x - 110, "titleSm"), x, 10, ui.w - x - 110, 26, "titleSm", c.text)
    ui.label(subtitle, x, 34, ui.w - x - 110, 18, "small", c.muted)
  else
    ui.label(title, x, 10, ui.w - x - 20, 44, onBack and "titleSm" or "title", c.text)
  end
  return h
end

function common.divider(y)
  ui.setColor(c.line)
  love.graphics.setLineWidth(1)
  love.graphics.line(0, y + 0.5, ui.w, y + 0.5)
end

--- Bottom navigation bar (narrow layout).
function common.nav(active)
  local y = ui.h - common.NAV_H
  ui.setColor(c.nav)
  love.graphics.rectangle("fill", 0, y, ui.w, common.NAV_H)
  common.divider(y)
  local items = {
    { id = "parties", label = "Parties", icon = "people" },
    { id = "chat", label = "Chat", icon = "chat" },
    { id = "settings", label = "Settings", icon = "settings" },
  }
  local w = (ui.w - 16) / #items
  for i, it in ipairs(items) do
    local x = 8 + (i - 1) * w
    local on = active == it.id
    if on then
      ui.setColor(c.mine)
      ui.rect("fill", x + w / 2 - 28, y + 10, 56, 30, 15)
    end
    ui.icon(it.icon, x + w / 2, y + 25, 20, on and c.accent or c.muted)
    ui.label(it.label, x, y + 44, w, 18, "label", on and c.text or c.muted, "center")
    if ui.clicked(x, y + 4, w, 64) and not on then
      if it.id == "chat" then
        local target = app.party(app.partyId) or app.parties()[1]
        if target then
          app.go("chat", target.id)
        else
          ui.toast("Join or start a party to chat.")
        end
      else
        app.go(it.id)
      end
    end
  end
end

return common
