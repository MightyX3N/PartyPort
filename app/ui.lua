-- Tiny immediate-mode UI toolkit: buttons, text inputs, icons, scrolling,
-- toasts. Coordinates are in "design pixels" (the mockup's 390-wide layout);
-- ui.scale maps them to the window.
local utf8 = require("utf8")
local theme = require("theme")

local ui = {
  scale = 1,
  w = 390,
  h = 760,
  mx = -1,
  my = -1,
  click = nil, -- pending click {x, y}
  focus = nil, -- id of the focused text input
  text = {}, -- text input contents by id
  submitted = {}, -- inputs where Enter was pressed this frame
  scroll = {}, -- scroll offsets by id
  wheel = 0,
  drag = nil,
  toastText = nil,
  toastUntil = 0,
  cursorHand = false,
}
local c = theme.c
local fonts = {}

function ui.load()
  local function f(file, size)
    return love.graphics.newFont("assets/fonts/" .. file, size)
  end
  fonts = {
    body = f("Inter-Regular.otf", 15),
    bodySm = f("Inter-Regular.otf", 13),
    small = f("Inter-Regular.otf", 12),
    tiny = f("Inter-Medium.otf", 11),
    medium = f("Inter-Medium.otf", 15),
    semibold = f("Inter-SemiBold.otf", 15),
    semiboldSm = f("Inter-SemiBold.otf", 13),
    bold = f("Inter-Bold.otf", 15),
    label = f("Inter-SemiBold.otf", 12),
    title = f("SpaceGrotesk-Bold.ttf", 24),
    titleSm = f("SpaceGrotesk-Bold.ttf", 19),
    hero = f("SpaceGrotesk-Bold.ttf", 26),
    mono = f("SpaceGrotesk-Medium.ttf", 22),
  }
  ui.fonts = fonts
end

function ui.setColor(col, alpha)
  love.graphics.setColor(col[1], col[2], col[3], (col[4] or 1) * (alpha or 1))
end

function ui.font(name)
  love.graphics.setFont(fonts[name])
  return fonts[name]
end

function ui.inside(x, y, w, h, px, py)
  px, py = px or ui.mx, py or ui.my
  return px >= x and px <= x + w and py >= y and py <= y + h
end

--- True once if the pending click/tap landed in the rectangle.
function ui.clicked(x, y, w, h)
  local cl = ui.click
  if cl and ui.inside(x, y, w, h, cl.x, cl.y) and not ui.clipBlocked(cl.x, cl.y) then
    ui.click = nil
    return true
  end
  if ui.inside(x, y, w, h) then ui.cursorHand = true end
  return false
end

-- Clipping (scissor) in design pixels, with click blocking outside the clip.
local clipStack = {}
function ui.pushClip(x, y, w, h)
  table.insert(clipStack, { x, y, w, h })
  local s = ui.scale
  love.graphics.setScissor(math.floor(x * s), math.floor(y * s), math.ceil(w * s), math.ceil(h * s))
end
function ui.popClip()
  table.remove(clipStack)
  local top = clipStack[#clipStack]
  if top then
    local s = ui.scale
    love.graphics.setScissor(math.floor(top[1] * s), math.floor(top[2] * s), math.ceil(top[3] * s), math.ceil(top[4] * s))
  else
    love.graphics.setScissor()
  end
end
function ui.clipBlocked(px, py)
  local top = clipStack[#clipStack]
  return top and not ui.inside(top[1], top[2], top[3], top[4], px, py)
end

function ui.rect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r or 0, r or 0, 12)
end

function ui.card(x, y, w, h, opts)
  opts = opts or {}
  ui.setColor(opts.fill or c.surface)
  ui.rect("fill", x, y, w, h, opts.radius or theme.radius.card)
  ui.setColor(opts.border or c.line)
  love.graphics.setLineWidth(opts.borderWidth or 1)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, opts.radius or theme.radius.card)
end

--- Draw text vertically centred in a box. align: left/center/right.
function ui.label(text, x, y, w, h, fontName, col, align)
  local f = ui.font(fontName or "body")
  ui.setColor(col or c.text)
  local ty = y + math.floor((h - f:getHeight()) / 2)
  love.graphics.printf(text, x, ty, w, align or "left")
end

--- Draw wrapped text; returns height used.
function ui.wrapped(text, x, y, w, fontName, col, align)
  local f = ui.font(fontName or "body")
  ui.setColor(col or c.text)
  local _, lines = f:getWrap(text, w)
  love.graphics.printf(text, x, y, w, align or "left")
  return #lines * f:getHeight() * f:getLineHeight()
end

function ui.textHeight(text, w, fontName)
  local f = fonts[fontName or "body"]
  local _, lines = f:getWrap(text, w)
  return #lines * f:getHeight() * f:getLineHeight()
end

function ui.truncate(text, w, fontName)
  local f = fonts[fontName or "body"]
  if f:getWidth(text) <= w then return text end
  local out = text
  while #out > 0 and f:getWidth(out .. "…") > w do
    local off = utf8.offset(out, -1)
    out = out:sub(1, (off or 1) - 1)
  end
  return out .. "…"
end

-- ---------- buttons ----------

--- kind: primary, secondary, ghost, join, danger. Returns true when pressed.
function ui.button(text, x, y, w, h, kind, opts)
  opts = opts or {}
  kind = kind or "secondary"
  local disabled = opts.disabled
  local hot = not disabled and ui.inside(x, y, w, h) and not ui.clipBlocked(ui.mx, ui.my)
  local r = opts.radius or theme.radius.button
  local fill, border, ink
  if kind == "primary" then
    fill, border, ink = c.accent, nil, c.accentInk
  elseif kind == "join" then
    fill, border, ink = c.joinBg, nil, c.joinText
  elseif kind == "danger" then
    fill, border, ink = c.dangerBg, c.dangerLine, c.danger
  elseif kind == "ghost" then
    fill, border, ink = nil, c.line, c.text
  else
    fill, border, ink = c.surface, c.line, c.text
  end
  local a = disabled and 0.45 or 1
  if fill then
    ui.setColor(fill, a)
    ui.rect("fill", x, y, w, h, r)
    if hot then
      love.graphics.setColor(1, 1, 1, 0.07)
      ui.rect("fill", x, y, w, h, r)
    end
  elseif hot then
    love.graphics.setColor(1, 1, 1, 0.05)
    ui.rect("fill", x, y, w, h, r)
  end
  if border then
    ui.setColor(border, a)
    love.graphics.setLineWidth(1)
    ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, r)
  end
  local f = fonts[opts.font or (kind == "primary" and "bold" or "semibold")]
  local iconW = opts.icon and 26 or 0
  local tw = f:getWidth(text) + iconW
  local tx = x + (w - tw) / 2
  if opts.icon then
    ui.setColor(ink, a)
    ui.icon(opts.icon, tx + 9, y + h / 2, 17, ink)
  end
  love.graphics.setFont(f)
  ui.setColor(ink, a)
  love.graphics.print(text, math.floor(tx + iconW), math.floor(y + (h - f:getHeight()) / 2))
  if disabled then return false end
  return ui.clicked(x, y, w, h)
end

--- Round or square icon button with an outline.
function ui.iconButton(name, x, y, size, opts)
  opts = opts or {}
  local hot = ui.inside(x, y, size, size)
  if opts.fill then
    ui.setColor(opts.fill)
    ui.rect("fill", x, y, size, size, opts.radius or size / 2)
  end
  if opts.border ~= false then
    ui.setColor(opts.border or c.line)
    love.graphics.setLineWidth(1)
    ui.rect("line", x + 0.5, y + 0.5, size - 1, size - 1, opts.radius or size / 2)
  end
  if hot then
    love.graphics.setColor(1, 1, 1, 0.06)
    ui.rect("fill", x, y, size, size, opts.radius or size / 2)
  end
  ui.icon(name, x + size / 2, y + size / 2, opts.iconSize or 20, opts.color or c.text)
  return ui.clicked(x, y, size, size)
end

-- ---------- icons (drawn, centred on cx, cy) ----------

function ui.icon(name, cx, cy, s, col)
  ui.setColor(col or c.text)
  local lw = math.max(1.6, s / 10)
  love.graphics.setLineWidth(lw)
  love.graphics.setLineJoin("bevel")
  local h = s / 2
  if name == "plus" then
    love.graphics.line(cx - h * 0.7, cy, cx + h * 0.7, cy)
    love.graphics.line(cx, cy - h * 0.7, cx, cy + h * 0.7)
  elseif name == "back" then
    love.graphics.line(cx + h * 0.25, cy - h * 0.6, cx - h * 0.35, cy, cx + h * 0.25, cy + h * 0.6)
  elseif name == "chevron" then
    love.graphics.line(cx - h * 0.2, cy - h * 0.5, cx + h * 0.3, cy, cx - h * 0.2, cy + h * 0.5)
  elseif name == "power" then
    love.graphics.arc("line", "open", cx, cy + h * 0.08, h * 0.68, -math.pi / 2 + 0.75, math.pi * 1.5 - 0.75, 24)
    love.graphics.line(cx, cy - h * 0.8, cx, cy - h * 0.05)
  elseif name == "send" then
    love.graphics.polygon("line", cx - h * 0.75, cy - h * 0.65, cx + h * 0.75, cy, cx - h * 0.75, cy + h * 0.65, cx - h * 0.4, cy)
  elseif name == "people" then
    love.graphics.circle("line", cx - h * 0.25, cy - h * 0.35, h * 0.32, 20)
    love.graphics.arc("line", "open", cx - h * 0.25, cy + h * 0.75, h * 0.62, math.pi, 2 * math.pi, 16)
    love.graphics.arc("line", "open", cx + h * 0.42, cy - h * 0.3, h * 0.3, -math.pi / 2, math.pi / 2, 12)
    love.graphics.line(cx + h * 0.55, cy + h * 0.2, cx + h * 0.8, cy + h * 0.72)
  elseif name == "chat" then
    love.graphics.circle("line", cx, cy - h * 0.05, h * 0.78, 28)
    love.graphics.line(cx - h * 0.62, cy + h * 0.45, cx - h * 0.85, cy + h * 0.85, cx - h * 0.3, cy + h * 0.68)
  elseif name == "settings" then
    love.graphics.line(cx - h * 0.8, cy - h * 0.4, cx + h * 0.8, cy - h * 0.4)
    love.graphics.line(cx - h * 0.8, cy + h * 0.4, cx + h * 0.8, cy + h * 0.4)
    ui.setColor(c.nav)
    love.graphics.circle("fill", cx + h * 0.25, cy - h * 0.4, h * 0.25, 16)
    love.graphics.circle("fill", cx - h * 0.3, cy + h * 0.4, h * 0.25, 16)
    ui.setColor(col or c.text)
    love.graphics.circle("line", cx + h * 0.25, cy - h * 0.4, h * 0.25, 16)
    love.graphics.circle("line", cx - h * 0.3, cy + h * 0.4, h * 0.25, 16)
  elseif name == "copy" then
    ui.rect("line", cx - h * 0.35, cy - h * 0.35, h * 1.05, h * 1.05, 2)
    love.graphics.line(cx - h * 0.75, cy + h * 0.35, cx - h * 0.75, cy - h * 0.75, cx + h * 0.35, cy - h * 0.75)
  elseif name == "check" then
    love.graphics.line(cx - h * 0.65, cy, cx - h * 0.15, cy + h * 0.5, cx + h * 0.7, cy - h * 0.5)
  elseif name == "link" then
    love.graphics.circle("line", cx - h * 0.55, cy, h * 0.3, 16)
    love.graphics.circle("line", cx + h * 0.55, cy - h * 0.5, h * 0.3, 16)
    love.graphics.circle("line", cx + h * 0.55, cy + h * 0.5, h * 0.3, 16)
    love.graphics.line(cx - h * 0.28, cy - h * 0.12, cx + h * 0.28, cy - h * 0.38)
    love.graphics.line(cx - h * 0.28, cy + h * 0.12, cx + h * 0.28, cy + h * 0.38)
  elseif name == "invite" then
    love.graphics.circle("line", cx - h * 0.2, cy - h * 0.35, h * 0.32, 20)
    love.graphics.arc("line", "open", cx - h * 0.2, cy + h * 0.75, h * 0.62, math.pi, 2 * math.pi, 16)
    love.graphics.line(cx + h * 0.65, cy - h * 0.55, cx + h * 0.65, cy + h * 0.05)
    love.graphics.line(cx + h * 0.35, cy - h * 0.25, cx + h * 0.95, cy - h * 0.25)
  elseif name == "leave" then
    love.graphics.line(cx - h * 0.1, cy - h * 0.8, cx - h * 0.8, cy - h * 0.8, cx - h * 0.8, cy + h * 0.8, cx - h * 0.1, cy + h * 0.8)
    love.graphics.line(cx - h * 0.25, cy, cx + h * 0.8, cy)
    love.graphics.line(cx + h * 0.4, cy - h * 0.4, cx + h * 0.8, cy, cx + h * 0.4, cy + h * 0.4)
  elseif name == "server" then
    ui.rect("line", cx - h * 0.85, cy - h * 0.7, h * 1.7, h * 1.1, 2)
    love.graphics.line(cx - h * 0.45, cy + h * 0.8, cx + h * 0.45, cy + h * 0.8)
    love.graphics.line(cx, cy + h * 0.4, cx, cy + h * 0.8)
  end
end

--- The PartyPort logo (three linked nodes).
function ui.logo(cx, cy, s, col)
  ui.setColor(col or c.accent)
  love.graphics.setLineWidth(math.max(1.6, s / 11))
  local k = s / 24
  love.graphics.circle("line", cx + (6 - 12) * k, cy + (12 - 12) * k, 3 * k, 20)
  love.graphics.circle("line", cx + (18 - 12) * k, cy + (6 - 12) * k, 3 * k, 20)
  love.graphics.circle("line", cx + (18 - 12) * k, cy + (18 - 12) * k, 3 * k, 20)
  love.graphics.line(cx + (8.6 - 12) * k, cy + (10.6 - 12) * k, cx + (15.4 - 12) * k, cy + (7.4 - 12) * k)
  love.graphics.line(cx + (8.6 - 12) * k, cy + (13.4 - 12) * k, cx + (15.4 - 12) * k, cy + (16.6 - 12) * k)
end

function ui.dot(cx, cy, state)
  if state == "online" then
    ui.setColor(c.accent)
    love.graphics.circle("fill", cx, cy, 5, 20)
  elseif state == "busy" then
    ui.setColor(c.busy)
    love.graphics.circle("fill", cx, cy, 5, 20)
  else
    ui.setColor(c.off)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", cx, cy, 4, 20)
  end
end

function ui.badge(text, rx, cy)
  local f = fonts.tiny
  local w = math.max(22, f:getWidth(text) + 14)
  ui.setColor(c.accent)
  ui.rect("fill", rx - w, cy - 11, w, 22, 11)
  love.graphics.setFont(f)
  ui.setColor(c.accentInk)
  love.graphics.printf(text, rx - w, cy - f:getHeight() / 2, w, "center")
  return w
end

-- ---------- text input ----------

function ui.input(id, x, y, w, h, opts)
  opts = opts or {}
  local value = ui.text[id] or ""
  local focused = ui.focus == id
  if ui.clicked(x, y, w, h) then
    ui.focus = id
    focused = true
    love.keyboard.setTextInput(true, x * ui.scale, y * ui.scale, w * ui.scale, h * ui.scale)
  end
  ui.setColor(c.bgDeep)
  ui.rect("fill", x, y, w, h, opts.radius or theme.radius.input)
  ui.setColor(focused and c.accent or c.line, focused and 0.9 or 1)
  love.graphics.setLineWidth(focused and 1.5 or 1)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, opts.radius or theme.radius.input)
  local f = fonts[opts.font or "body"]
  love.graphics.setFont(f)
  local pad = opts.pad or 14
  local shown = value
  if opts.password then shown = string.rep("•", utf8.len(value) or 0) end
  ui.pushClip(x + 2, y, w - 4, h)
  local ty = y + (h - f:getHeight()) / 2
  local tw = f:getWidth(shown)
  local offset = math.max(0, tw - (w - pad * 2 - 4))
  if shown == "" and opts.placeholder then
    ui.setColor(c.faint)
    love.graphics.print(opts.placeholder, x + pad, ty)
  else
    ui.setColor(c.text)
    love.graphics.print(shown, x + pad - offset, ty)
  end
  if focused and (love.timer.getTime() % 1) < 0.55 then
    ui.setColor(c.accent)
    love.graphics.rectangle("fill", x + pad - offset + tw + 1, ty + 1, 1.5, f:getHeight() - 2)
  end
  ui.popClip()
  if ui.submitted[id] then
    ui.submitted[id] = nil
    return true
  end
  return false
end

function ui.onTextInput(t)
  if not ui.focus then return end
  local cur = ui.text[ui.focus] or ""
  if utf8.len(cur .. t) and utf8.len(cur .. t) <= (ui.maxLen[ui.focus] or 200) then
    ui.text[ui.focus] = cur .. t
  end
end
ui.maxLen = {}

function ui.onKey(key)
  if not ui.focus then return false end
  local id = ui.focus
  local cur = ui.text[id] or ""
  local ctrl = love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")
  if key == "backspace" then
    if ctrl then
      ui.text[id] = cur:gsub("%s*[^%s]*$", "")
    else
      local off = utf8.offset(cur, -1)
      if off then ui.text[id] = cur:sub(1, off - 1) end
    end
    return true
  elseif key == "return" or key == "kpenter" then
    ui.submitted[id] = true
    return true
  elseif key == "v" and ctrl then
    local clip = love.system.getClipboardText() or ""
    clip = clip:gsub("[\r\n]+", " ")
    ui.onTextInput(clip)
    return true
  elseif key == "escape" then
    ui.blur()
    return true
  end
  return false
end

function ui.blur()
  ui.focus = nil
  love.keyboard.setTextInput(false)
end

-- ---------- scrolling ----------

--- How far the user scrolled inside this box this frame (mouse wheel or
--- touch drag). Positive means "towards the end of the list".
function ui.scrollDelta(id, x, y, w, h)
  local d = 0
  if ui.wheel ~= 0 and ui.inside(x, y, w, h) then
    d = d - ui.wheel * 48
    ui.wheel = 0
  end
  local dr = ui.drag
  if dr and dr.moved and (dr.id == id or (dr.id == nil and ui.inside(x, y, w, h, dr.sx, dr.sy))) then
    dr.id = id
    d = d - dr.dy
    dr.dy = 0
  end
  return d
end

-- ---------- toast ----------

function ui.toast(text, seconds)
  ui.toastText = text
  ui.toastUntil = love.timer.getTime() + (seconds or 3.5)
end

function ui.drawToast()
  if not ui.toastText or love.timer.getTime() > ui.toastUntil then return end
  local f = fonts.medium
  local maxW = math.min(ui.w - 32, 420)
  local th = ui.textHeight(ui.toastText, maxW - 32, "medium")
  local h = th + 24
  local x = (ui.w - maxW) / 2
  local y = ui.h - h - 96
  ui.setColor(c.surface2)
  ui.rect("fill", x, y, maxW, h, 12)
  ui.setColor(c.line2)
  love.graphics.setLineWidth(1)
  ui.rect("line", x + 0.5, y + 0.5, maxW - 1, h - 1, 12)
  love.graphics.setFont(f)
  ui.setColor(c.text)
  love.graphics.printf(ui.toastText, x + 16, y + 12, maxW - 32, "center")
end

return ui
