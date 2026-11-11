-- First run: pick the name friends will see.
local ui = require("ui")
local Core = require("core")
local app = require("app")
local theme = require("theme")
local c = theme.c

local screen = { busy = false }

function screen.draw()
  local w = math.min(ui.w, 460)
  local x0 = (ui.w - w) / 2
  local y = math.max(40, ui.h * 0.12)
  ui.logo(ui.w / 2, y + 22, 48, c.accent)
  ui.label("Welcome to PartyPort", x0, y + 60, w, 34, "hero", c.text, "center")
  y = y + 104
  y = y + ui.wrapped("Play LAN games with friends over the internet. No port forwarding.", x0 + 28, y, w - 56, "body", c.muted, "center") + 34

  local px = x0 + 20
  local pw = w - 40
  ui.label("YOUR NAME", px, y, pw, 18, "label", c.muted)
  y = y + 26
  local submit = ui.input("name", px, y, pw, 48, { placeholder = "What should friends see?" })
  y = y + 58
  ui.wrapped("You can change it later in Settings. You'll link playit.gg only when you host a game.", px, y, pw, "small", c.faint)

  local name = (ui.text.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local by = ui.h - 92
  if (ui.button(screen.busy and "Saving…" or "Continue", px, by, pw, 52, "primary", { disabled = name == "" or screen.busy }) or (submit and name ~= ""))
    and not screen.busy then
    screen.busy = true
    Core.request("setName", { name = name }, function(ok, err)
      screen.busy = false
      if ok then
        ui.blur()
        app.go("parties")
      else
        ui.toast(app.errorText(err))
      end
    end)
  end
end

return screen
