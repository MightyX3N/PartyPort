-- Connection from the UI to the PartyPort core (a separate background
-- program that does all networking). One JSON object per line over a local
-- TCP socket; see core/control.go.
local socket = require("socket")
local json = require("lib.json")

local Core = {
  status = "starting", -- starting, connecting, ready, failed
  error = nil,
  state = nil, -- latest full state from the core
  onEvent = nil, -- function(ev) for "chat" and "party.gone" events
}

local sock, buffer, token
local nextId, pending = 1, {}
local spawnedAt, lastAttempt = nil, -10
local isWindows = love.system.getOS() == "Windows"

local function joinPath(...)
  return table.concat({ ... }, isWindows and "\\" or "/")
end

-- Same folder the core uses (Go's os.UserConfigDir()/PartyPort).
function Core.dataDir()
  local override = os.getenv("PARTYPORT_DATA")
  if override and override ~= "" then return override end
  local os_ = love.system.getOS()
  if os_ == "Windows" then
    return joinPath(os.getenv("APPDATA") or ".", "PartyPort")
  elseif os_ == "OS X" then
    return joinPath(os.getenv("HOME") or ".", "Library", "Application Support", "PartyPort")
  end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then return joinPath(xdg, "PartyPort") end
  return joinPath(os.getenv("HOME") or ".", ".config", "PartyPort")
end

local function readControl()
  local f = io.open(joinPath(Core.dataDir(), "control.json"), "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(json.decode, text)
  if ok and type(data) == "table" and data.port then return data end
  return nil
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- Where the core program lives: next to the app, or in the repo during development.
local function findCoreBinary()
  local env = os.getenv("PARTYPORT_CORE")
  if env and env ~= "" then return env end
  local name = isWindows and "partyport-core.exe" or "partyport-core"
  local base = love.filesystem.getSourceBaseDirectory()
  local src = love.filesystem.getSource()
  for _, p in ipairs({ joinPath(base, name), joinPath(src, name), joinPath(src, "..", "core", name) }) do
    if fileExists(p) then return p end
  end
  return nil
end

local function spawnCore()
  local bin = findCoreBinary()
  if not bin then
    Core.status = "failed"
    Core.error = "Couldn't find the PartyPort core program next to the app."
    return
  end
  if isWindows then
    os.execute('start "" /B "' .. bin .. '"')
  else
    os.execute('"' .. bin .. '" >/dev/null 2>&1 &')
  end
  spawnedAt = love.timer.getTime()
end

local function send(obj)
  if not sock then return false end
  local ok = sock:send(json.encode(obj) .. "\n")
  return ok ~= nil
end

local function disconnect(reason)
  if sock then sock:close() end
  sock = nil
  buffer = ""
  for id, cb in pairs(pending) do
    pending[id] = nil
    if cb then pcall(cb, false, reason or "core_disconnected") end
  end
  Core.status = "connecting"
end

local function tryConnect()
  local ctl = readControl()
  if not ctl then return false end
  local s = socket.tcp()
  s:settimeout(1)
  local ok = s:connect("127.0.0.1", ctl.port)
  if not ok then
    s:close()
    return false
  end
  s:settimeout(0)
  s:setoption("tcp-nodelay", true)
  sock, buffer, token = s, "", ctl.token
  Core.status = "connecting"
  local id = nextId
  nextId = nextId + 1
  pending[id] = function(okHello, data)
    if okHello then
      Core.status = "ready"
      Core.error = nil
    else
      Core.status = "failed"
      Core.error = "The core refused the connection (" .. tostring(data) .. ")."
      disconnect()
    end
  end
  send({ id = id, op = "hello", token = token })
  return true
end

local function handleLine(line)
  local ok, msg = pcall(json.decode, line)
  if not ok or type(msg) ~= "table" then return end
  if msg.ev then
    if msg.ev == "state" then
      Core.state = msg
    end
    if Core.onEvent then Core.onEvent(msg) end
  elseif msg.id and pending[msg.id] then
    local cb = pending[msg.id]
    pending[msg.id] = nil
    cb(msg.ok, msg.ok and msg.data or msg.error)
  end
end

function Core.update()
  if not sock then
    local now = love.timer.getTime()
    if now - lastAttempt < 0.5 then return end
    lastAttempt = now
    if tryConnect() then return end
    if not spawnedAt then
      spawnCore()
    elseif now - spawnedAt > 8 and Core.status ~= "failed" then
      Core.status = "failed"
      Core.error = Core.error or "The PartyPort core didn't start."
    end
    return
  end
  while true do
    local line, err, partial = sock:receive("*l", buffer)
    if line then
      buffer = ""
      handleLine(line)
    elseif err == "timeout" then
      buffer = partial or buffer
      return
    else
      disconnect("core_disconnected")
      spawnedAt = nil -- core went away: start it again
      return
    end
  end
end

--- Send a request to the core. cb(ok, dataOrError) is called with the reply.
function Core.request(op, args, cb)
  if not sock or Core.status ~= "ready" then
    if cb then cb(false, "core_not_ready") end
    return
  end
  local id = nextId
  nextId = nextId + 1
  local msg = { id = id, op = op }
  for k, v in pairs(args or {}) do msg[k] = v end
  pending[id] = cb or false
  if not send(msg) then
    pending[id] = nil
    if cb then cb(false, "core_not_ready") end
  end
end

--- Shortcut for an operation inside a party (chat, invites, kicks...).
function Core.partyOp(partyId, t, data, cb)
  Core.request("partyOp", { party = partyId, t = t, data = data or {} }, cb)
end

function Core.quit()
  if sock then
    send({ id = nextId, op = "quit" })
    socket.sleep(0.05)
  end
end

function Core.restart()
  Core.status, Core.error, spawnedAt = "starting", nil, nil
  disconnect()
end

return Core
