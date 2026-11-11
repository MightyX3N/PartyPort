-- Shared app state and helpers used by all screens.
local json = require("lib.json")
local Core = require("core")
local ui = require("ui")

local app = {
  screen = "parties", -- setup, parties, join, chat, settings
  partyId = nil, -- party shown on the chat screen
  settings = { scale = nil, keepRunning = false, lastRead = {} },
  confirm = nil, -- { text, yes, onYes } for a confirmation dialog
  inviteShown = nil, -- invite to show on the chat screen
}

-- Friendly text for errors from the core or the service.
local ERRORS = {
  invite_not_found = "That invite code doesn't exist or was cancelled.",
  invite_expired = "That invite has expired. Ask for a new one.",
  invite_used_up = "That invite has already been used.",
  wrong_password = "Wrong party password.",
  banned = "You've been banned from that party.",
  party_full = "That party is full.",
  bad_name = "Please type a name.",
  set_name_first = "Choose a name first.",
  forbidden = "Only admins can do that.",
  not_connected = "Not connected to the party right now. Try again in a moment.",
  core_not_ready = "PartyPort is still starting. Try again in a moment.",
  core_disconnected = "Lost connection to the PartyPort core. Reconnecting…",
  slow_down = "You're sending messages too fast.",
  bad_text = "Message can't be empty.",
  timeout = "The party didn't answer in time. Try again.",
}

function app.errorText(err)
  if type(err) ~= "string" then return "Something went wrong." end
  if ERRORS[err] then return ERRORS[err] end
  if err:find("can't reach") or err:find("can't connect") then
    return "Can't reach the PartyPort service. Check your internet connection."
  end
  return "Something went wrong (" .. err .. ")."
end

-- ---------- settings (stored in LÖVE's save folder) ----------

function app.loadSettings()
  local data = love.filesystem.read("settings.json")
  if data then
    local ok, s = pcall(json.decode, data)
    if ok and type(s) == "table" then
      for k, v in pairs(s) do app.settings[k] = v end
    end
  end
  app.settings.lastRead = app.settings.lastRead or {}
end

function app.saveSettings()
  love.filesystem.write("settings.json", json.encode(app.settings))
end

-- ---------- state helpers ----------

function app.state()
  return Core.state
end

function app.myKey()
  return Core.state and Core.state.key
end

function app.parties()
  return (Core.state and Core.state.parties) or {}
end

function app.party(id)
  for _, p in ipairs(app.parties()) do
    if p.id == id then return p end
  end
  return nil
end

function app.member(party, key)
  for _, m in ipairs(party.members or {}) do
    if m.key == key then return m end
  end
  return nil
end

function app.hostOf(party, key)
  for _, h in ipairs(party.hosts or {}) do
    if h.key == key then return h end
  end
  return nil
end

function app.isAdmin(party)
  return party.role == "owner" or party.role == "admin"
end

function app.onlineCount(party)
  local n = 0
  for _, m in ipairs(party.members or {}) do
    if m.online then n = n + 1 end
  end
  return n
end

-- Members sorted: hosting first, then online, then offline; by name.
function app.sortedMembers(party)
  local list = {}
  for _, m in ipairs(party.members or {}) do table.insert(list, m) end
  local function rank(m)
    if app.hostOf(party, m.key) then return 0 end
    if m.online then return 1 end
    return 2
  end
  table.sort(list, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

function app.unread(party)
  local last = app.settings.lastRead[party.id] or 0
  local n = 0
  for _, m in ipairs(party.chat or {}) do
    if m.id and m.id > last and m.kind == "msg" and m.sender ~= app.myKey() then n = n + 1 end
  end
  return n
end

function app.markRead(party)
  local chat = party.chat or {}
  local last = chat[#chat]
  if last and last.id and (app.settings.lastRead[party.id] or 0) < last.id then
    app.settings.lastRead[party.id] = last.id
    app.saveSettings()
  end
end

function app.displayName(party, key, fallback)
  if key == app.myKey() then return "You" end
  local m = app.member(party, key)
  return (m and m.name) or fallback or "Someone"
end

-- Stable colour per member for chat names.
function app.nameColor(key)
  local theme = require("theme")
  local h = 0
  for i = 1, #(key or "") do h = (h * 31 + key:byte(i)) % 997 end
  return theme.c.names[(h % #theme.c.names) + 1]
end

function app.timeText(ms)
  if not ms then return "" end
  local t = math.floor(ms / 1000)
  local now = os.time()
  if os.date("%Y%m%d", t) == os.date("%Y%m%d", now) then return os.date("%H:%M", t) end
  return os.date("%d %b %H:%M", t)
end

function app.seenText(ms)
  if not ms or ms == 0 then return "Offline" end
  local d = os.time() - math.floor(ms / 1000)
  if d < 120 then return "Offline · just now" end
  if d < 3600 then return ("Offline · seen %d min ago"):format(math.floor(d / 60)) end
  if d < 86400 then return ("Offline · seen %d h ago"):format(math.floor(d / 3600)) end
  local days = math.floor(d / 86400)
  return ("Offline · seen %d day%s ago"):format(days, days == 1 and "" or "s")
end

-- Readable line for an event message in the chat.
function app.eventText(party, msg)
  local who = app.displayName(party, msg.sender, msg.name)
  -- "You" at the start of a sentence, "you" anywhere else.
  local byWho = who == "You" and "you" or who
  local t = msg.type
  if t == "party.created" then return who .. " started the party"
  elseif t == "member.joined" then return (msg.sender == app.myKey() and "You" or (msg.name or who)) .. " joined the party"
  elseif t == "member.left" then return (msg.name or who) .. " left the party"
  elseif t == "member.kicked" then return (msg.name or "Someone") .. " was removed by " .. byWho
  elseif t == "member.banned" then return (msg.name or "Someone") .. " was banned by " .. byWho
  elseif t == "member.role" then
    return (msg.key == app.myKey() and "You are" or ((msg.name or "Someone") .. " is")) .. " now " .. (msg.role == "admin" and "an admin" or "a member")
  elseif t == "owner.handover" then
    local to = app.displayName(party, msg.to, "Someone")
    return (to == "You" and "You are" or (to .. " is")) .. " now the party owner"
  elseif t == "party.renamed" then return who .. " renamed the party to " .. (msg.name or "")
  elseif t == "host.started" then return who .. " started hosting " .. (msg.label or msg.game or "a game")
  elseif t == "host.stopped" then return who .. " stopped hosting " .. (msg.label or msg.game or "")
  end
  return t or ""
end

--- Open a party that the core may not have reported yet (just created/joined).
function app.openNewParty(partyId)
  app.waitingFor = partyId
  app.waitingUntil = love.timer.getTime() + 5
  app.go("chat", partyId)
end

function app.go(screen, partyId)
  ui.blur()
  app.screen = screen
  if partyId then app.partyId = partyId end
  app.inviteShown = nil
end

return app
