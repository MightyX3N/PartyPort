-- Join a party with an invite code, or start a new one.
local ui = require("ui")
local Core = require("core")
local app = require("app")
local common = require("screens.common")
local theme = require("theme")
local c = theme.c

local screen = { busy = false, preview = nil, previewFor = nil, needPassword = false }

local function normCode(s)
  local t = (s or ""):upper():gsub("[^A-Z0-9]", "")
  return t
end

local function updatePreview(code)
  if #code ~= 8 then
    screen.preview, screen.previewFor = nil, nil
    return
  end
  if screen.previewFor == code then return end
  screen.previewFor = code
  screen.preview = { loading = true }
  Core.request("previewInvite", { code = code }, function(ok, data)
    if screen.previewFor ~= code then return end
    if ok then
      screen.preview = data
      screen.needPassword = data.hasPassword
    else
      screen.preview = { error = data }
    end
  end)
end

local function doJoin(code)
  if screen.busy then return end
  screen.busy = true
  Core.request("joinParty", { code = code, password = ui.text.password or "" }, function(ok, data)
    screen.busy = false
    if ok then
      ui.text.code, ui.text.password = "", ""
      screen.preview, screen.previewFor = nil, nil
      app.openNewParty(data.partyId)
      ui.toast("You joined " .. (data.name or "the party") .. "!")
    else
      if data == "wrong_password" then screen.needPassword = true end
      ui.toast(app.errorText(data))
    end
  end)
end

local function doStart(name)
  if screen.busy then return end
  screen.busy = true
  Core.request("createParty", { name = name }, function(ok, data)
    screen.busy = false
    if ok then
      ui.text.partyName = ""
      app.openNewParty(data.id)
      app.showInvitePanel = true
    else
      ui.toast(app.errorText(data))
    end
  end)
end

function screen.draw()
  common.header("Parties", nil, function() app.go("parties") end)
  common.divider(64)
  local tab = app.joinTab or "join"
  local x, w = 16, ui.w - 32
  local y = 80

  -- Segmented control
  ui.card(x, y, w, 46, { radius = 12 })
  local half = (w - 8) / 2
  for i, t in ipairs({ { "join", "Join" }, { "start", "Start one" } }) do
    local bx = x + 4 + (i - 1) * half
    local on = tab == t[1]
    if on then
      ui.setColor(c.line)
      ui.rect("fill", bx, y + 4, half, 38, 9)
    end
    ui.label(t[2], bx, y + 4, half, 38, "semibold", on and c.text or c.muted, "center")
    if ui.clicked(bx, y + 4, half, 38) and not on then
      app.joinTab = t[1]
      ui.blur()
    end
  end
  y = y + 66

  if tab == "join" then
    ui.label("INVITE CODE", x, y, w, 18, "label", c.muted)
    y = y + 26
    local submit = ui.input("code", x, y, w, 54, { placeholder = "e.g. FRDY-7K2Q", font = "mono" })
    local code = normCode(ui.text.code)
    updatePreview(code)
    y = y + 64

    local p = screen.preview
    if p then
      if p.loading then
        ui.label("Looking up invite…", x, y, w, 20, "bodySm", c.muted)
      elseif p.error then
        ui.label(app.errorText(p.error), x, y, w, 20, "bodySm", c.danger)
      else
        ui.card(x, y - 4, w, 54, { fill = c.accentBg, border = c.accentLine, radius = 12 })
        ui.label(ui.truncate(p.name, w - 32, "semibold"), x + 16, y + 2, w - 32, 22, "semibold", c.text)
        ui.label(("%d member%s%s"):format(p.members, p.members == 1 and "" or "s", p.hasPassword and " · needs a password" or ""),
          x + 16, y + 24, w - 32, 20, "small", c.muted)
      end
      y = y + 66
    end

    if screen.needPassword then
      ui.label("PARTY PASSWORD", x, y, w, 18, "label", c.muted)
      y = y + 26
      submit = ui.input("password", x, y, w, 48, { placeholder = "Ask the party for it", password = true }) or submit
      y = y + 64
    end

    local valid = #code == 8 and not (p and p.error)
    if (ui.button(screen.busy and "Joining…" or "Join party", x, y, w, 52, "primary", { disabled = not valid or screen.busy }) or (submit and valid)) then
      doJoin(code)
    end
  else
    ui.label("PARTY NAME", x, y, w, 18, "label", c.muted)
    y = y + 26
    local submit = ui.input("partyName", x, y, w, 50, { placeholder = "e.g. Friday Gaming" })
    y = y + 62
    ui.wrapped("You'll be the owner. Invite friends with a code from the party screen.", x, y, w, "small", c.faint)
    y = y + 40
    local name = (ui.text.partyName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if (ui.button(screen.busy and "Starting…" or "Start party", x, y, w, 52, "primary", { disabled = name == "" or screen.busy }) or (submit and name ~= "")) then
      doStart(name)
    end
  end
end

return screen
