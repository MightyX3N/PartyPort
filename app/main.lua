-- PartyPort UI. All networking happens in the PartyPort core (core/),
-- which this app starts and talks to; see core.lua.
local Core = require("core")
local ui = require("ui")
local app = require("app")
local theme = require("theme")

local screens = {
  setup = require("screens.setup"),
  parties = require("screens.parties"),
  join = require("screens.join"),
  chat = require("screens.chat"),
  settings = require("screens.settings"),
}
local c = theme.c

local function makeIcon()
  local size = 64
  local canvas = love.graphics.newCanvas(size, size)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  ui.setColor(c.bg)
  love.graphics.rectangle("fill", 0, 0, size, size, 14, 14)
  ui.logo(size / 2, size / 2, 44, c.accent)
  love.graphics.setCanvas()
  love.window.setIcon(canvas:newImageData())
end

function love.load()
  love.keyboard.setKeyRepeat(true)
  ui.load()
  app.loadSettings()
  pcall(makeIcon)
  ui.maxLen = { name = 32, partyName = 40, code = 12, password = 64, chat = 1000, rename = 32 }
  Core.onEvent = function(ev)
    if ev.ev == "party.gone" then
      local reasons = {
        removed = "You were removed from %s.",
        not_a_member = "You're no longer a member of %s.",
        deleted = "%s no longer exists.",
        left = "You left %s.",
      }
      ui.toast((reasons[ev.reason] or "%s is gone."):format(ev.name or "the party"), 5)
      if app.partyId == ev.party and app.screen == "chat" then app.go("parties") end
    end
  end
end

function love.update(dt)
  Core.update()
  local w, h = love.graphics.getDimensions()
  local scale = app.settings.scale or 1
  ui.scale = scale
  ui.w, ui.h = w / scale, h / scale
end

local function drawSplash()
  local cx, cy = ui.w / 2, ui.h / 2
  ui.logo(cx, cy - 60, 56, c.accent)
  ui.label("PartyPort", 0, cy - 20, ui.w, 34, "title", c.text, "center")
  if Core.status == "failed" then
    ui.wrapped(Core.error or "PartyPort couldn't start.", 32, cy + 26, ui.w - 64, "bodySm", c.muted, "center")
    if ui.button("Try again", cx - 80, cy + 80, 160, 46, "secondary") then Core.restart() end
  else
    local dots = string.rep(".", math.floor(love.timer.getTime() * 2.5) % 4)
    ui.label("Starting" .. dots, 0, cy + 22, ui.w, 24, "bodySm", c.muted, "center")
  end
end

local function drawConfirm()
  local d = app.confirm
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", 0, 0, ui.w, ui.h)
  local w = math.min(ui.w - 40, 360)
  local th = ui.textHeight(d.text, w - 40, "body")
  local h = th + 140
  local x, y = (ui.w - w) / 2, (ui.h - h) / 2
  ui.card(x, y, w, h, { fill = c.surface, border = c.line2 })
  ui.label(d.title or "Are you sure?", x + 20, y + 18, w - 40, 26, "titleSm", c.text)
  ui.wrapped(d.text, x + 20, y + 52, w - 40, "body", c.text2)
  local bw = (w - 52) / 2
  if ui.button("Cancel", x + 20, y + h - 64, bw, 44, "ghost") then app.confirm = nil end
  if ui.button(d.yes or "OK", x + 32 + bw, y + h - 64, bw, 44, d.danger and "danger" or "primary") then
    local fn = d.onYes
    app.confirm = nil
    if fn then fn() end
  end
  -- Clicks outside the dialog do nothing.
  ui.click = nil
end

function love.draw()
  ui.setColor(c.bg)
  love.graphics.rectangle("fill", 0, 0, love.graphics.getDimensions())
  love.graphics.push()
  love.graphics.scale(ui.scale)
  ui.cursorHand = false

  local modalClick
  if app.confirm then
    -- Hold the click for the dialog; the screen below must not see it.
    modalClick, ui.click = ui.click, nil
  end

  local st = Core.state
  if Core.status ~= "ready" or not st then
    drawSplash()
  elseif not st.name or st.name == "" then
    screens.setup.draw()
  else
    if app.screen == "setup" then app.screen = "parties" end
    (screens[app.screen] or screens.parties).draw()
  end

  if app.confirm then
    ui.click = modalClick
    drawConfirm()
  end
  ui.drawToast()
  love.graphics.pop()

  ui.click = nil
  ui.wheel = 0
  local cursor = ui.cursorHand and love.mouse.getSystemCursor("hand") or nil
  pcall(love.mouse.setCursor, cursor)
end

-- ---------- input ----------

local function toDesign(x, y)
  return x / ui.scale, y / ui.scale
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  local dx, dy = toDesign(x, y)
  ui.drag = { sx = dx, sy = dy, lx = dx, ly = dy, dy = 0, moved = false }
end

function love.mousemoved(x, y)
  local dx, dy = toDesign(x, y)
  ui.mx, ui.my = dx, dy
  local d = ui.drag
  if d then
    if not d.moved and (math.abs(dy - d.sy) > 8 or math.abs(dx - d.sx) > 8) then d.moved = true end
    if d.moved then d.dy = d.dy + (dy - d.ly) end
    d.lx, d.ly = dx, dy
  end
end

function love.mousereleased(x, y, button)
  if button ~= 1 then return end
  local dx, dy = toDesign(x, y)
  local d = ui.drag
  ui.drag = nil
  if d and not d.moved then
    local hadFocus = ui.focus
    ui.click = { x = dx, y = dy }
    -- Tapping anywhere else drops keyboard focus (inputs re-take it when hit).
    if hadFocus then ui.blur() end
  end
end

function love.wheelmoved(_, y)
  ui.wheel = ui.wheel + y
end

function love.textinput(t)
  ui.onTextInput(t)
end

function love.keypressed(key)
  if key == "q" and love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui") then
    love.event.quit()
    return
  end
  if ui.onKey(key) then return end
  if key == "escape" then
    if app.confirm then
      app.confirm = nil
    elseif app.screen ~= "parties" then
      app.go("parties")
    end
  end
end

function love.quit()
  if not app.settings.keepRunning then Core.quit() end
  return false
end
