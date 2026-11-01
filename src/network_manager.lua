-- Two-player racing through the UDP relay in server/. The first player hosts
-- a room, the second joins with its code, and each sends its car to the other.
local socket = require("socket")

local network = {
  status = "idle",  -- idle | connecting | waiting | pairing | racing | error
  message = "",
  roomCode = "",
  role = nil,
  ready = false,
  session = nil,
  peerState = nil,
  peerSeen = 0,
}

local TICK = 1 / 20
local RESEND = 0.25
local TIMEOUT = 6

function network.generateCode()
  local letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  local out = {}
  for i = 1, 6 do
    local n = love.math.random(1, #letters)
    out[i] = letters:sub(n, n)
  end
  return table.concat(out)
end

function network.packState(s)
  return string.format("sync|%.1f|%.1f|%.3f|%.1f|%.1f|%.3f|%d|%.2f|%.2f|%d",
    s.x, s.y, s.a, s.vx, s.vy, s.steer, s.rpm, s.throttle, s.brake, s.gear)
end

function network.unpackState(str)
  local parts = {}
  for chunk in str:gmatch("[^|]+") do parts[#parts + 1] = chunk end
  if parts[1] ~= "sync" or #parts < 11 then return nil end
  local fields = { "x", "y", "a", "vx", "vy", "steer", "rpm", "throttle", "brake", "gear" }
  local out = {}
  for i, name in ipairs(fields) do
    local value = tonumber(parts[i + 1])
    if value == nil or value ~= value then return nil end
    out[name] = value
  end
  return out
end

function network.packHello(h)
  return string.format("event|hello|%s|%d|%s|%d|%s|%d", h.car, h.paint, h.track, h.laps, h.time, h.seen and 1 or 0)
end

function network.unpackHello(str)
  local car, paint, track, laps, time, seen = str:match("^event|hello|([^|]+)|(%d+)|([^|]+)|(%d+)|([^|]+)|(%d)$")
  if not car then return nil end
  return { car = car, paint = tonumber(paint), track = track, laps = tonumber(laps), time = time, seen = seen == "1" }
end

function network.statusText()
  if network.status == "connecting" then return "Connecting..." end
  if network.status == "waiting" then return "Waiting for a driver. Room code: " .. network.roomCode end
  if network.status == "pairing" then return "Driver found. Starting..." end
  if network.status == "error" then return network.message end
  return ""
end

function network.fail(message)
  network.status = "error"
  network.message = message
  if network.udp then
    network.udp:close()
    network.udp = nil
  end
end

function network.connect(host, port, role, code, hello)
  network.disconnect()
  local udp = socket.udp()
  udp:settimeout(0)
  local ok, err = udp:setpeername(host, port)
  if not ok then
    network.fail("Can't reach " .. tostring(host) .. ": " .. tostring(err))
    return
  end
  network.udp = udp
  network.role = role
  network.roomCode = code
  network.hello = hello
  network.status = "connecting"
  network.ready = false
  network.peerHello = nil
  network.lastHeard = socket.gettime()
  network.resendTimer = 0
  network.tickTimer = 0
  network.onMessage = nil
  udp:send(string.format("event|%s|%s", role, code))
end

function network.disconnect()
  if network.udp then
    network.udp:send("event|leave|")
    network.udp:close()
    network.udp = nil
  end
  network.status = "idle"
  network.message = ""
  network.peerState = nil
  network.peerGone = false
  network.ready = false
end

local function handleEvent(data)
  local kind, rest = data:match("^event|([^|]+)|?(.*)$")
  if kind == "joined" or kind == "hosting" then
    network.status = "waiting"
  elseif kind == "start_race" then
    network.status = "pairing"
  elseif kind == "error" then
    if network.status == "racing" then
      network.peerGone = true
    else
      network.fail(rest ~= "" and rest or "The server refused the connection")
    end
  elseif kind == "hello" then
    local hello = network.unpackHello(data)
    if hello then
      network.status = network.status == "racing" and "racing" or "pairing"
      network.peerHello = hello
      -- The host's track and laps win; only the car comes from the joiner.
      local config = network.role == "host" and network.hello or hello
      network.session = {
        track = config.track, laps = config.laps, time = config.time,
        peerCar = hello.car, peerPaint = hello.paint,
        slot = network.role == "host" and 1 or 2,
      }
      if hello.seen and network.status ~= "racing" then
        network.status = "racing"
        network.ready = true
      end
    end
  end
end

function network.update(dt)
  local udp = network.udp
  if not udp then return end

  -- An event can close the connection, so check it each time round.
  while network.udp do
    local data = network.udp:receive()
    if not data then break end
    network.lastHeard = socket.gettime()
    if data:sub(1, 5) == "sync|" then
      local s = network.unpackState(data)
      if s then
        s.at = socket.gettime()
        network.peerState = s
      end
    elseif data:sub(1, 6) == "event|" then
      handleEvent(data)
    end
  end
  udp = network.udp
  if not udp then return end

  network.resendTimer = network.resendTimer - dt
  if network.resendTimer <= 0 then
    network.resendTimer = RESEND
    if network.status == "connecting" or network.status == "waiting" then
      udp:send(string.format("event|%s|%s", network.role, network.roomCode))
    elseif network.status == "pairing" then
      local hello = network.hello
      hello.seen = network.peerHello ~= nil
      udp:send(network.packHello(hello))
    elseif network.status == "racing" then
      -- Keep answering until the other side has clearly started too.
      network.hello.seen = true
      if not network.peerState then udp:send(network.packHello(network.hello)) end
    end
  end

  if network.status == "connecting" and socket.gettime() - network.lastHeard > TIMEOUT then
    network.fail("No answer from the server. Check the address.")
  elseif network.status == "racing" and socket.gettime() - network.lastHeard > TIMEOUT then
    network.peerGone = true
  end
end

-- The freshest state from the other player and how old it is, in seconds.
function network.latestPeerState()
  local s = network.peerState
  if not s then return nil end
  return s, socket.gettime() - s.at
end

function network.sendCar(car)
  if not network.udp or network.status ~= "racing" then return end
  local vx, vy = car.body:getLinearVelocity()
  network.udp:send(network.packState({
    x = car.curX, y = car.curY, a = car.curA, vx = vx, vy = vy,
    steer = car.model.steer, rpm = car.model.rpm,
    throttle = car.model.throttle, brake = car.model.brake, gear = car.model.gear,
  }))
end

return network
