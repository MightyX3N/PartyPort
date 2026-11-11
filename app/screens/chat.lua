-- A party: chat, members and invites.
local ui = require("ui")
local Core = require("core")
local app = require("app")
local common = require("screens.common")
local theme = require("theme")
local c = theme.c

local screen = { sending = false, expanded = nil, inviteBusy = false }
local GROUP_MS = 3 * 60 * 1000

-- ---------- message layout ----------

local function layout(party, w)
  local items, total = {}, 0
  local myKey = app.myKey()
  local maxBubble = math.floor(math.min(w * 0.78, 560))
  local prev
  for _, m in ipairs(party.chat or {}) do
    local it = { m = m }
    if m.kind == "msg" then
      it.mine = m.sender == myKey
      it.showName = not it.mine and not (prev and prev.kind == "msg" and prev.sender == m.sender and m.at - prev.at < GROUP_MS)
      local f = ui.fonts.body
      local textW = maxBubble - 28
      local width, lines = f:getWrap(m.text or "", textW)
      it.textW = math.min(textW, math.max(width, 1))
      it.textH = #lines * f:getHeight() * f:getLineHeight()
      it.bw = it.textW + 28
      it.bh = it.textH + 20
      it.h = it.bh + (it.showName and 20 or 0) + 6
      local grouped = prev and prev.kind == "msg" and prev.sender == m.sender and m.at - prev.at < GROUP_MS
      it.gap = grouped and 4 or 12
    elseif m.type == "host.started" then
      it.card = true
      it.text = app.eventText(party, m)
      it.h = 56
      it.gap = 12
    else
      it.text = app.eventText(party, m)
      it.h = ui.textHeight(it.text .. " · 00:00", w - 40, "small") + 4
      it.gap = 12
    end
    total = total + it.gap + it.h
    table.insert(items, it)
    prev = m
  end
  return items, total + 12
end

local function drawMessages(party, x, top, w, h)
  local items, total = layout(party, w)
  local key = "chat:" .. party.id
  local fromBottom = ui.scroll[key] or 0
  fromBottom = fromBottom - ui.scrollDelta(key, x, top, w, h)
  fromBottom = math.max(0, math.min(fromBottom, math.max(0, total - h)))
  ui.scroll[key] = fromBottom

  ui.pushClip(x, top, w, h)
  local y = top + h + fromBottom - total
  if total < h then y = top + h - total end
  for _, it in ipairs(items) do
    y = y + it.gap
    local m = it.m
    if y + it.h >= top and y <= top + h then
      if it.card then
        ui.card(x + 16, y, w - 32, it.h, { fill = c.accentBg, border = c.accentLine, radius = 12 })
        ui.icon("server", x + 38, y + it.h / 2, 18, c.accent)
        ui.label(ui.truncate(it.text, w - 110, "bodySm"), x + 58, y, w - 90, it.h, "bodySm", c.text)
      elseif m.kind == "msg" then
        local bx = it.mine and (x + w - 16 - it.bw) or (x + 16)
        local by = y
        if it.showName then
          local name = app.displayName(party, m.sender)
          ui.font("label")
          ui.setColor(app.nameColor(m.sender))
          love.graphics.print(name, bx + 2, by)
          ui.setColor(c.faint)
          ui.font("small")
          love.graphics.print("  " .. app.timeText(m.at), bx + 2 + ui.fonts.label:getWidth(name), by)
          by = by + 20
        end
        ui.setColor(it.mine and c.mine or c.surface2)
        ui.rect("fill", bx, by, it.bw, it.bh, 14)
        ui.font("body")
        ui.setColor(c.text)
        love.graphics.printf(m.text or "", bx + 14, by + 10, it.textW, "left")
      else
        ui.label(it.text .. " · " .. app.timeText(m.at), x + 20, y, w - 40, it.h, "small", c.muted, "center")
      end
    end
    y = y + it.h
  end
  ui.popClip()
  if #items == 0 then
    ui.label("No messages yet. Say hi!", x, top + h / 2 - 12, w, 24, "bodySm", c.muted, "center")
  end
end

-- ---------- members panel ----------

local function memberActions(party, m)
  local acts = {}
  local me = party.role
  if m.key == app.myKey() or m.role == "owner" then return acts end
  if me == "owner" then
    if m.role == "admin" then
      table.insert(acts, { "Make member", "secondary", function() Core.partyOp(party.id, "member.role", { key = m.key, role = "member" }) end })
    else
      table.insert(acts, { "Make admin", "secondary", function() Core.partyOp(party.id, "member.role", { key = m.key, role = "admin" }) end })
    end
    table.insert(acts, { "Make owner", "secondary", function()
      app.confirm = {
        title = "Hand over the party?",
        text = m.name .. " becomes the owner. You'll stay in the party as an admin.",
        yes = "Make owner",
        onYes = function()
          Core.partyOp(party.id, "owner.transfer", { key = m.key }, function(ok, err) if not ok then ui.toast(app.errorText(err)) end end)
        end,
      }
    end })
  end
  if me == "owner" or (me == "admin" and m.role == "member") then
    table.insert(acts, { "Remove", "danger", function()
      app.confirm = {
        title = "Remove " .. m.name .. "?",
        text = "They'll be taken out of " .. party.name .. ". They can come back only with a new invite.",
        yes = "Remove", danger = true,
        onYes = function()
          Core.partyOp(party.id, "member.kick", { key = m.key }, function(ok, err) if not ok then ui.toast(app.errorText(err)) end end)
        end,
      }
    end })
  end
  return acts
end

local function drawMembers(party, x, top, w, h)
  ui.setColor(c.bg)
  love.graphics.rectangle("fill", x, top, w, h)
  local members = app.sortedMembers(party)
  local rows = {}
  local total = 8
  for _, m in ipairs(members) do
    local acts = (screen.expanded == m.key) and memberActions(party, m) or {}
    local rh = 60 + (#acts > 0 and 56 or 0)
    table.insert(rows, { m = m, acts = acts, h = rh })
    total = total + rh
  end
  total = total + 90

  local key = "members:" .. party.id
  local off = (ui.scroll[key] or 0) + ui.scrollDelta(key, x, top, w, h)
  off = math.max(0, math.min(off, math.max(0, total - h)))
  ui.scroll[key] = off
  ui.pushClip(x, top, w, h)
  local y = top + 8 - off
  for _, r in ipairs(rows) do
    local m = r.m
    local host = app.hostOf(party, m.key)
    ui.dot(x + 28, y + 30, (m.online or host) and "online" or "off")
    local name = m.name .. (m.key == app.myKey() and " (you)" or "")
    ui.label(ui.truncate(name, w - 170, "medium"), x + 46, y + 8, w - 170, 24, "medium", m.online and c.text or c.muted)
    local sub = host and ("Hosting " .. (host.label or host.game)) or (m.online and "Online" or app.seenText(m.lastSeen))
    ui.label(ui.truncate(sub, w - 170, "small"), x + 46, y + 30, w - 170, 20, "small", c.muted)
    local manageable = #memberActions(party, m) > 0
    local right = manageable and 44 or 20
    if m.role ~= "member" then
      local tag = m.role == "owner" and "Owner" or "Admin"
      local tw = ui.fonts.tiny:getWidth(tag) + 16
      ui.setColor(m.role == "owner" and c.accentBg or c.surface2)
      ui.rect("fill", x + w - right - tw, y + 19, tw, 22, 11)
      ui.label(tag, x + w - right - tw, y + 19, tw, 22, "tiny", m.role == "owner" and c.accent or c.text2, "center")
    end
    if #r.acts > 0 then
      local bw = (w - 32 - (#r.acts - 1) * 8) / #r.acts
      for i, a in ipairs(r.acts) do
        if ui.button(a[1], x + 16 + (i - 1) * (bw + 8), y + 60, bw, 44, a[2], { font = "semiboldSm" }) then
          screen.expanded = nil
          a[3]()
        end
      end
    end
    if manageable and screen.expanded ~= m.key then
      ui.icon("chevron", x + w - 26, y + 30, 16, c.muted)
    end
    if manageable and ui.clicked(x, y, w, 60) then
      screen.expanded = (screen.expanded ~= m.key) and m.key or nil
    end
    y = y + r.h
  end
  y = y + 16
  if ui.button("Leave party", x + 16, y, w - 32, 48, "danger", { icon = "leave" }) then
    local last = #(party.members or {}) <= 1
    app.confirm = {
      title = "Leave " .. party.name .. "?",
      text = last and "You're the last member, so the party will be deleted." or "You'll need a new invite to come back.",
      yes = last and "Delete party" or "Leave", danger = true,
      onYes = function()
        Core.request("leaveParty", { party = party.id }, function(ok, err)
          if ok then
            app.go("parties")
          else
            ui.toast(app.errorText(err))
          end
        end)
      end,
    }
  end
  ui.popClip()
end

-- ---------- invite panel ----------

local function createInvite(party)
  if screen.inviteBusy then return end
  screen.inviteBusy = true
  Core.partyOp(party.id, "invite.create", { hours = 168 }, function(ok, data)
    screen.inviteBusy = false
    if ok then
      app.inviteShown = data.invite
    else
      ui.toast(app.errorText(data))
    end
  end)
end

local function expiresText(inv)
  local left = math.floor((inv.expiresAt or 0) / 1000) - os.time()
  if left <= 0 then return "expired" end
  if left < 3600 then return ("expires in %d min"):format(math.ceil(left / 60)) end
  if left < 86400 then return ("expires in %d h"):format(math.ceil(left / 3600)) end
  return ("expires in %d days"):format(math.ceil(left / 86400))
end

local function drawInvites(party, x, top, w, h)
  ui.setColor(c.bg)
  love.graphics.rectangle("fill", x, top, w, h)
  local y = top + 16
  local px, pw = x + 16, w - 32
  ui.label("INVITE FRIENDS TO " .. party.name:upper(), px, y, pw, 18, "label", c.muted)
  y = y + 28
  local inv = app.inviteShown
  if not inv and party.invites then
    for _, i in ipairs(party.invites) do
      if not i.expired and (i.maxUses == 0 or i.uses < i.maxUses) then inv = i break end
    end
  end
  if inv then
    local uses
    if inv.maxUses > 0 then
      uses = ("%d of %d uses left"):format(inv.maxUses - inv.uses, inv.maxUses)
    elseif inv.uses == 0 then
      uses = "not used yet"
    else
      uses = inv.uses == 1 and "used once" or ("used %d times"):format(inv.uses)
    end
    local info = "Anyone with this code can join. " .. expiresText(inv):gsub("^%l", string.upper) .. " · " .. uses .. "."
    local infoH = ui.textHeight(info, pw - 32, "small")
    local cardH = 70 + infoH + 70
    ui.card(px, y, pw, cardH, { radius = 14 })
    ui.label(inv.code, px + 16, y + 14, pw - 90, 44, "mono", c.text)
    if ui.iconButton("copy", px + pw - 60, y + 14, 44, { radius = 10, fill = c.surface2 }) then
      love.system.setClipboardText(inv.code)
      ui.toast("Invite code copied.")
    end
    ui.wrapped(info, px + 16, y + 66, pw - 32, "small", c.muted)
    if ui.button("Copy invite message", px + 16, y + 66 + infoH + 14, pw - 32, 44, "secondary", { font = "semiboldSm" }) then
      love.system.setClipboardText(("Join my PartyPort party \"%s\" with the invite code %s"):format(party.name, inv.code))
      ui.toast("Invite message copied. Paste it to your friends.")
    end
    y = y + cardH + 16
    if ui.button(screen.inviteBusy and "Creating…" or "Make a new code", px, y, pw, 46, "ghost", { disabled = screen.inviteBusy }) then
      createInvite(party)
    end
    y = y + 62
  else
    ui.wrapped("Create a code and send it to your friends. They type it into PartyPort under Join.", px, y, pw, "bodySm", c.muted)
    y = y + 50
    if ui.button(screen.inviteBusy and "Creating…" or "Create invite code", px, y, pw, 50, "primary", { disabled = screen.inviteBusy }) then
      createInvite(party)
    end
    y = y + 66
  end

  local active = {}
  for _, i in ipairs(party.invites or {}) do
    if not i.expired then table.insert(active, i) end
  end
  if #active > 0 then
    ui.label("ACTIVE CODES", px, y, pw, 18, "label", c.muted)
    y = y + 26
    for _, i in ipairs(active) do
      if y + 50 > top + h then break end
      ui.label(i.code, px, y, pw - 120, 40, "semibold", c.text)
      ui.label(expiresText(i), px + 110, y, pw - 210, 40, "small", c.muted)
      if ui.button("Cancel", px + pw - 92, y + 2, 92, 36, "ghost", { font = "semiboldSm" }) then
        Core.partyOp(party.id, "invite.revoke", { code = i.code }, function(ok, err)
          if ok then
            if app.inviteShown and app.inviteShown.code == i.code then app.inviteShown = nil end
            ui.toast("Invite " .. i.code .. " cancelled.")
          else
            ui.toast(app.errorText(err))
          end
        end)
      end
      y = y + 46
    end
  end
end

-- ---------- screen ----------

function screen.draw()
  local party = app.party(app.partyId)
  if not party then
    -- Just created or joined: the core's state update can arrive a moment
    -- after its reply, so wait briefly before giving up.
    if app.waitingFor == app.partyId and love.timer.getTime() < (app.waitingUntil or 0) then
      common.header("Opening party…", nil, function() app.go("parties") end)
      return
    end
    app.go("parties")
    return
  end
  app.waitingFor = nil
  if app.showInvitePanel and party.role and party.role ~= "" then
    app.showInvitePanel = nil
    app.chatPanel = app.isAdmin(party) and "invite" or nil
  end
  local panel = app.chatPanel
  if panel == "invite" and not app.isAdmin(party) then panel, app.chatPanel = nil, nil end

  local n = #(party.members or {})
  local sub
  if party.status == "online" then
    sub = ("%d online · %d member%s"):format(app.onlineCount(party), n, n == 1 and "" or "s")
  elseif party.status == "connecting" then
    sub = "Connecting…"
  else
    sub = "Offline"
  end
  common.header(party.name, sub, function()
    if app.chatPanel then app.chatPanel = nil else app.go("parties") end
  end)
  local bx = ui.w - 60
  if ui.iconButton("people", bx, 10, 44, { fill = panel == "members" and c.surface2 or nil, border = panel == "members" and c.line2 or false, iconSize = 20 }) then
    app.chatPanel = panel ~= "members" and "members" or nil
    screen.expanded = nil
  end
  if app.isAdmin(party) then
    bx = bx - 50
    if ui.iconButton("invite", bx, 10, 44, { fill = panel == "invite" and c.surface2 or nil, border = panel == "invite" and c.line2 or false, iconSize = 20 }) then
      app.chatPanel = panel ~= "invite" and "invite" or nil
    end
  end
  common.divider(64)

  local top = 65
  if party.status ~= "online" then
    ui.setColor(c.dangerBg)
    if party.status == "connecting" then ui.setColor(c.surface) end
    love.graphics.rectangle("fill", 0, top, ui.w, 32)
    local msg = party.status == "connecting" and "Connecting to the party…"
      or (Core.state.online and "Can't reach the party right now. Retrying…" or "You're offline. Turn PartyPort on to chat.")
    ui.label(msg, 0, top, ui.w, 32, "small", party.status == "connecting" and c.muted or c.danger, "center")
    top = top + 32
  end

  local inputH = 72
  local areaH = ui.h - top - inputH
  if panel == "members" then
    drawMembers(party, 0, top, ui.w, ui.h - top)
    return
  elseif panel == "invite" then
    drawInvites(party, 0, top, ui.w, ui.h - top)
    return
  end

  drawMessages(party, 0, top, ui.w, areaH)
  app.markRead(party)

  -- Message input
  local iy = ui.h - inputH
  common.divider(iy)
  local submit = ui.input("chat", 14, iy + 12, ui.w - 84, 48, { placeholder = "Message " .. party.name, radius = 24, pad = 18 })
  local text = (ui.text.chat or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local canSend = text ~= "" and party.status == "online" and not screen.sending
  local sendCol = canSend and c.accent or c.surface2
  if (ui.iconButton("send", ui.w - 62, iy + 12, 48, { fill = sendCol, border = false, color = canSend and c.accentInk or c.muted, iconSize = 18 }) or submit) and canSend then
    screen.sending = true
    local pid = party.id
    Core.partyOp(pid, "chat", { text = text }, function(ok, err)
      screen.sending = false
      if ok then
        ui.text.chat = ""
        ui.scroll["chat:" .. pid] = 0
      else
        ui.toast(app.errorText(err))
      end
    end)
  end
end

return screen
