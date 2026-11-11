-- Settings: name, size of the interface, connection info.
local ui = require("ui")
local Core = require("core")
local app = require("app")
local common = require("screens.common")
local theme = require("theme")
local c = theme.c

local screen = { busy = false }

local function section(title, x, y, w)
  ui.label(title, x, y, w, 18, "label", c.muted)
  return y + 26
end

function screen.draw()
  local st = Core.state
  ui.label("Settings", 20, 22, ui.w - 40, 36, "title", c.text)
  local x, w = 16, ui.w - 32
  local top, bottom = 76, ui.h - common.NAV_H
  local off = math.max(0, math.min((ui.scroll.settings or 0) + ui.scrollDelta("settings", 0, top, ui.w, bottom - top), math.max(0, 560 - (bottom - top))))
  ui.scroll.settings = off
  ui.pushClip(0, top, ui.w, bottom - top)
  local y = top - off

  y = section("YOUR NAME", x, y, w)
  if ui.text.rename == nil then ui.text.rename = st.name end
  local submit = ui.input("rename", x, y, w - 96, 48)
  local name = (ui.text.rename or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local changed = name ~= "" and name ~= st.name
  if (ui.button("Save", x + w - 86, y, 86, 48, changed and "primary" or "secondary", { disabled = not changed or screen.busy }) or (submit and changed)) then
    screen.busy = true
    Core.request("setName", { name = name }, function(ok, err)
      screen.busy = false
      if ok then ui.toast("Name saved.") else ui.toast(app.errorText(err)) end
    end)
  end
  y = y + 70

  y = section("INTERFACE SIZE", x, y, w)
  local sizes = { { "Small", 0.85 }, { "Normal", 1 }, { "Large", 1.2 } }
  local bw = (w - 16) / 3
  for i, s in ipairs(sizes) do
    local on = math.abs((app.settings.scale or 1) - s[2]) < 0.01
    if ui.button(s[1], x + (i - 1) * (bw + 8), y, bw, 46, on and "primary" or "secondary") and not on then
      app.settings.scale = s[2]
      app.saveSettings()
    end
  end
  y = y + 70

  y = section("CONNECTION", x, y, w)
  ui.card(x, y, w, 132)
  local rows = {
    { "Status", st.online and "Online" or "Offline" },
    { "Party service", (st.service or ""):gsub("^https?://", "") },
    { "Your ID", (st.key or ""):sub(1, 12) .. "…" },
  }
  for i, r in ipairs(rows) do
    local ry = y + 10 + (i - 1) * 38
    ui.label(r[1], x + 16, ry, 120, 34, "bodySm", c.muted)
    ui.label(ui.truncate(r[2], w - 150, "bodySm"), x + 130, ry, w - 146, 34, "bodySm", c.text, "right")
  end
  y = y + 152

  y = section("ABOUT", x, y, w)
  ui.wrapped("PartyPort 0.1 · early preview. Hosting and joining games through playit.gg arrive in the next update.", x, y, w, "bodySm", c.muted)
  ui.popClip()

  common.nav("settings")
end

return screen
