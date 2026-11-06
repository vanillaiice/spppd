-- Online racing through the UDP relay in server/. A host opens a room and up to
-- three others join with its code. The seat numbers come from the relay, and
-- the lowest seat in the room is the leader: it sets the race and calls the start.
--
-- Nothing here waits for an answer. Everyone repeats their state four times a
-- second until it stops mattering, so a lost packet costs a quarter of a second
-- and there are no acknowledgements to track.
--
-- Packets only ever grow at the end. Every reader takes the fields it knows and
-- ignores any after them, and ignores packets it doesn't know, so a later 3.x game
-- can add to the protocol without leaving earlier ones behind. See FEATURES.
local socket = require("socket")
local config = require("src/config")
local catalog = require("src/tracks/catalog")
local wire = require("src/tracks/wire")

local network = {
  status = "idle",  -- idle | connecting | lobby | loading | racing | error
  message = "",
  roomCode = "",
  slot = nil,       -- my seat
  leader = nil,     -- the lowest seat in the room
  peers = {},       -- everyone else in the room, by seat
  setup = nil,      -- the race as the leader has set it
  round = 0,        -- which race this is. 0 until the first one starts
  ready = false,    -- true when the game should build the race
  lost = nil,       -- why the connection went, if it went during a race
  vote = 0,         -- the round this player asked for from the results
}

-- Changes only for a break, which the relay refuses to mix in one room. All of
-- 3.x is protocol 5.
network.PROTOCOL = 5
-- What this game can do on top of protocol 5. A 3.x release that adds something
-- older 3.x games can't follow raises it, and a race that needs it says so in
-- the setup's `needs`, so the host only starts it when everyone can.
network.FEATURES = 0
network.MAX_PLAYERS = 4

local RESEND = 0.25
local TIMEOUT = 6
local CHUNK_BYTES = 1000
local MAX_CHUNKS = math.ceil(wire.MAX_BYTES / CHUNK_BYTES)
local CHUNKS_PER_ASK = 8
local CLOCK_SAMPLES = 8
local CLOCK_NEEDED = 3      -- pings answered before a clock is trusted
local START_LEAD = 1        -- from calling the start to the first light
local LOAD_LIMIT = 20       -- nobody waits longer than this for a slow loader
local REGISTER_BYTES = 64   -- what the relay asks for before it answers at all
local RETRY_AFTER = 2.5     -- silence in a room before trying to get back in
local RESOCKET = 2          -- a fresh socket this often while trying, in case the network changed
local BACK_LIMIT = 35       -- the relay keeps a seat for 5 + 30 s

-- What a real car can send. Anything past these is someone's own client, and it
-- mustn't reach Box2D or a sound's pitch.
local STATE_LIMITS = {
  x = 1e7, y = 1e7, a = 100, vx = 1e5, vy = 1e5, steer = 2, rpm = 30000, distance = 1e9, finish = 1e6,
}

local function now()
  return love.timer.getTime()
end

function network.generateCode()
  local letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  local out = {}
  for i = 1, 6 do
    local n = love.math.random(1, #letters)
    out[i] = letters:sub(n, n)
  end
  return table.concat(out)
end

-- Packets -----------------------------------------------------------------

-- Splits on |, keeping empty fields.
local function split(str)
  local out = {}
  for field in (str .. "|"):gmatch("([^|]*)|") do out[#out + 1] = field end
  return out
end

-- The first n fields of a packet, or nil if it has fewer. A pattern can be
-- anchored at both ends of this and still let a later game add fields after it.
local function head(str, n)
  local parts = split(str)
  if #parts < n then return nil end
  return table.concat(parts, "|", 1, n)
end

local FLAG_HORN, FLAG_REVERSE, FLAG_BOOST, FLAG_LOW, FLAG_HIGH, FLAG_GHOST, FLAG_WRECK = 1, 2, 4, 8, 16, 32, 64

local function flagged(flags, bit)
  return flags % (bit * 2) >= bit
end

function network.packState(s)
  local flags = (s.horn and FLAG_HORN or 0) + (s.reverse and FLAG_REVERSE or 0) + (s.boost and FLAG_BOOST or 0)
    + (s.lowBeam and FLAG_LOW or 0) + (s.highBeam and FLAG_HIGH or 0) + (s.ghost and FLAG_GHOST or 0)
    + (s.wreck and FLAG_WRECK or 0)
  return string.format("sync|%d|%d|%.1f|%.1f|%.3f|%.1f|%.1f|%.3f|%d|%.2f|%.2f|%d|%d|%.2f|%.0f|%.3f",
    s.round or 0, s.seq or 0, s.x, s.y, s.a, s.vx, s.vy, s.steer, s.rpm, s.throttle, s.brake, s.gear, flags,
    s.slide or 0, s.distance or 0, s.finish or 0)
end

local STATE_FIELDS = { "round", "seq", "x", "y", "a", "vx", "vy", "steer", "rpm", "throttle", "brake", "gear",
  "flags", "slide", "distance", "finish" }

function network.unpackState(str)
  local parts = split(str)
  if parts[1] ~= "sync" or #parts < #STATE_FIELDS + 1 then return nil end
  local out = {}
  for i, name in ipairs(STATE_FIELDS) do
    local value = tonumber(parts[i + 1])
    -- Written so that NaN fails it too, and tonumber will read "inf" and "nan".
    if value == nil or not (math.abs(value) <= (STATE_LIMITS[name] or 1e15)) then return nil end
    out[name] = value
  end
  local function clamp(name, low, high) out[name] = math.max(low, math.min(high, out[name])) end
  out.gear = math.floor(out.gear)
  out.flags = math.floor(out.flags)
  clamp("gear", 0, 12)
  clamp("flags", 0, 127)
  clamp("slide", 0, 1)
  clamp("rpm", 0, 30000)
  clamp("throttle", 0, 1)
  clamp("brake", 0, 1)
  out.horn = flagged(out.flags, FLAG_HORN)
  out.reverse = flagged(out.flags, FLAG_REVERSE)
  out.boost = flagged(out.flags, FLAG_BOOST)
  out.lowBeam = flagged(out.flags, FLAG_LOW)
  out.highBeam = flagged(out.flags, FLAG_HIGH)
  out.ghost = flagged(out.flags, FLAG_GHOST)
  out.wreck = flagged(out.flags, FLAG_WRECK)
  return out
end

-- Cheat codes that change how a car looks or sounds: neon, the tune horn, and the
-- flames, as a count of how many times they've been lit and the seconds left on
-- the last. A packet of its own, so a game without them ignores it, and sent twice
-- a second, so a lost one costs half a second of fire at most.
function network.packLook(l)
  return string.format("look|%d|%d|%d|%d|%.2f", l.round or 0, l.neon and 1 or 0, l.tune and 1 or 0,
    l.flames or 0, l.flameLeft or 0)
end

function network.unpackLook(str)
  local known = head(str, 6)
  if not known then return nil end
  local round, neon, tune, flames, left = known:match("^look|(%d+)|([01])|([01])|(%d+)|([%d%.]+)$")
  if not round then return nil end
  return { round = tonumber(round), neon = neon == "1", tune = tune == "1", flames = tonumber(flames),
    flameLeft = math.min(5, tonumber(left) or 0) }
end

-- Who I am, what I've got and what I want: car, paint, whether I hold the track,
-- the round I'm ready to start, the round I've asked for, and what I can do.
function network.packHello(h)
  return string.format("hello|%s|%d|%d|%d|%d|%d", h.car, h.paint, h.have and 1 or 0, h.ready or 0, h.vote or 0,
    h.features or 0)
end

function network.unpackHello(str)
  local known = head(str, 7)
  if not known then return nil end
  local car, paint, have, ready, vote, features = known:match("^hello|([%w_%-]+)|(%d+)|([01])|(%d+)|(%d+)|(%d+)$")
  if not car then return nil end
  return { car = car, paint = tonumber(paint), have = have == "1", ready = tonumber(ready), vote = tonumber(vote),
    features = tonumber(features) }
end

-- The race, when it starts, and the FEATURES level it needs from everyone.
function network.packSetup(s)
  return string.format("setup|%d|%s|%d|%d|%s|%.3f|%s|%d", s.round, s.hash, s.chunks, s.laps, s.time, s.startAt or 0,
    s.title, s.needs or 0)
end

function network.unpackSetup(str)
  local known = head(str, 9)
  if not known then return nil end
  local round, hash, chunks, laps, time, startAt, title, needs =
    known:match("^setup|(%d+)|(%x+)|(%d+)|(%d+)|(%a+)|([%d%.]+)|([^|]*)|(%d+)$")
  if not round then return nil end
  return {
    round = tonumber(round), hash = hash, chunks = tonumber(chunks),
    laps = math.max(config.LAPS_MIN, math.min(config.LAPS_MAX, tonumber(laps))),
    time = time, startAt = tonumber(startAt) or 0, title = wire.cleanTitle(title), needs = tonumber(needs),
  }
end

-- Sending -----------------------------------------------------------------

local function send(data)
  if network.udp then network.udp:send(data) end
end

local function myHello()
  local me = network.me
  return {
    car = me.car, paint = me.paint, have = network.def ~= nil,
    ready = network.loaded and network.clockReady() and network.round or 0,
    vote = network.vote, features = network.FEATURES,
  }
end

-- Asks the relay for a seat: a new one to host or join, or my own one back. The
-- relay answers the first ask with a cookie, and seats whoever repeats it.
local function register(intent)
  local text = string.format("event|%s|%d|%s|%s|%s|", intent, network.PROTOCOL, network.roomCode,
    network.cookie or "", network.token or "")
  -- Padded, so the relay's answer to someone who isn't listening is never bigger
  -- than what was sent to it.
  send(text .. string.rep(".", REGISTER_BYTES - #text))
end

local function publish()
  local setup = network.setup
  send(network.packSetup({
    round = network.round, hash = setup.hash, chunks = setup.chunks, laps = setup.laps,
    time = setup.time, startAt = network.startLocal, title = setup.title, needs = setup.needs,
  }))
end

-- The clock ---------------------------------------------------------------

-- Everyone counts down on the leader's clock. Half a ping is the best guess at
-- how long a packet took, and the quickest ping is the one least held up.
function network.clockReady()
  return network.isLeader() or #network.clock >= CLOCK_NEEDED
end

local function clockOffset()
  if network.isLeader() then return 0 end
  local best
  for _, sample in ipairs(network.clock) do
    if not best or sample.rtt < best.rtt then best = sample end
  end
  return best and best.offset
end

local function onPong(sentAt, leaderTime)
  local t = now()
  local rtt = t - sentAt
  if rtt < 0 then return end
  local clock = network.clock
  clock[#clock + 1] = { rtt = rtt, offset = leaderTime + rtt / 2 - t }
  if #clock > CLOCK_SAMPLES then table.remove(clock, 1) end
end

-- Seconds until lights out on this machine, or nil before the start is called.
-- Goes negative once the race is under way, which makes it the race clock too.
function network.startIn()
  return network.startLocal and network.startLocal - now()
end

-- Rooms and rounds ---------------------------------------------------------

function network.isLeader()
  return network.slot ~= nil and network.slot == network.leader
end

local function peerList()
  local out = {}
  for slot, peer in pairs(network.peers) do
    peer.slot = slot
    out[#out + 1] = peer
  end
  table.sort(out, function(a, b) return a.slot < b.slot end)
  return out
end
network.peerList = peerList

function network.statusText()
  if network.status == "connecting" then return "Connecting..." end
  if network.backSince then return "Lost the server. Getting back in..." end
  if network.status == "lobby" then
    if network.download then
      return string.format("Getting the track: %d%%", 100 * network.download.got / network.download.count)
    end
    if not next(network.peers) then return "Waiting for drivers. Room code: " .. network.roomCode end
    if network.isLeader() then
      return network.canStart() and "Everyone's here. Start when you're ready." or "Drivers are getting the track..."
    end
    return "Waiting for the host to start."
  end
  if network.status == "loading" then return "Starting..." end
  if network.status == "error" then return network.message end
  return ""
end

-- The FEATURES level everyone in the room has, as far as their hellos say.
function network.roomFeatures()
  local level = network.FEATURES
  for _, peer in pairs(network.peers) do level = math.min(level, peer.features or 0) end
  return level
end

-- Everyone needs to be known, here, holding the track and able to run the race
-- before the host can start.
function network.canStart()
  if network.status ~= "lobby" or not network.isLeader() or not next(network.peers) then return false end
  local needs = network.setup and network.setup.needs or 0
  for _, peer in pairs(network.peers) do
    if not peer.have or peer.away or (peer.features or 0) < needs then return false end
  end
  return true
end

local function beginRound(round)
  network.round = round
  network.startLocal = nil
  network.loaded = false
  network.vote = 0
  network.loadingSince = now()
  network.status = "loading"
  network.pending = true
  -- Whoever left before now isn't on this grid, and their seat may be someone else's.
  network.departures = {}
  for _, peer in pairs(network.peers) do peer.state, peer.look = nil, nil end
end

function network.startRace()
  if not network.canStart() then return end
  send("event|lock|")
  beginRound(1)
  publish()
end

-- The race is built and on the grid.
function network.raceLoaded()
  network.loaded = true
  network.status = "racing"
end

-- What the game needs to build the race.
function network.raceConfig()
  local setup = network.setup
  return {
    def = network.def, title = setup.title, laps = setup.laps, time = setup.time,
    slot = network.slot, peers = peerList(),
  }
end

-- A rematch needs someone to race, and everyone still here to agree to it.
function network.canRematch()
  return network.status == "racing" and next(network.peers) ~= nil
end

function network.voteRematch()
  if network.canRematch() then network.vote = network.round + 1 end
end

function network.hasVoted()
  return network.vote > network.round
end

-- How many of the others have asked for the rematch, out of how many.
function network.rematchCount()
  local voted, total = 0, 0
  for _, peer in pairs(network.peers) do
    total = total + 1
    if peer.vote and peer.vote > network.round then voted = voted + 1 end
  end
  return voted, total
end

-- Who has left since this was last asked.
function network.takeDepartures()
  local out = network.departures
  network.departures = {}
  return out
end

-- What the race should tell the player about connections since this was last
-- asked: { kind = "away" | "back" } for this game, and { kind = "peerAway" |
-- "peerBack", slot } for the others.
function network.takeNotices()
  local out = network.notices
  network.notices = {}
  return out
end

local function notice(kind, slot)
  network.notices[#network.notices + 1] = { kind = kind, slot = slot }
end

-- Connecting --------------------------------------------------------------

-- Lets go of the socket without telling the relay, which keeps the seat.
local function dropSocket()
  if network.udp then
    network.udp:close()
    network.udp = nil
  end
end

local function closeSocket()
  if network.udp then network.udp:send("event|leave|") end
  dropSocket()
end

local function reset()
  network.peers = {}
  network.departures = {}
  network.notices = {}
  network.cookie, network.token = nil, nil
  network.backSince, network.resocketAt = nil, nil
  network.slot, network.leader = nil, nil
  network.setup, network.def, network.download = nil, nil, nil
  network.clock = {}
  network.round = 0
  network.startLocal = nil
  network.loaded = false
  network.pending = false
  network.ready = false
  network.vote = 0
  network.lost = nil
end

function network.fail(message)
  closeSocket()
  reset()
  network.status = "error"
  network.message = message
end

-- `me` is { car, paint }. A host also passes `race`: { def, title, laps, time }.
function network.connect(host, port, role, code, me, race)
  network.disconnect()
  if race then
    local text, hash = catalog.fingerprint(race.def)
    if #text > wire.MAX_BYTES or not wire.decode(text) then
      network.fail("That track is too big to share")
      return
    end
    network.def = race.def
    network.setup = {
      hash = hash, chunks = math.ceil(#text / CHUNK_BYTES), laps = race.laps,
      time = race.time, title = wire.cleanTitle(race.title), needs = race.needs or 0,
    }
  end

  local udp = socket.udp()
  udp:settimeout(0)
  local ok, err = udp:setpeername(host, port)
  if not ok then
    network.fail("Can't reach " .. tostring(host) .. ": " .. tostring(err))
    return
  end
  network.udp = udp
  -- Kept as a number, so getting back in never waits on a name lookup.
  network.address = { (udp:getpeername()) or host, port }
  network.role = role
  network.roomCode = code
  network.me = me
  network.status = "connecting"
  network.lastHeard = now()
  network.resendTimer = 0
  register(role)
end

function network.disconnect()
  closeSocket()
  reset()
  network.status = "idle"
  network.message = ""
end

local function connectionLost(reason)
  if network.round > 0 then
    -- The race can finish without anyone else, so only the others go.
    network.lost = reason
    for slot in pairs(network.peers) do network.departures[#network.departures + 1] = slot end
    network.peers = {}
    closeSocket()
    network.vote = 0
    -- And there's no getting back in.
    network.backSince, network.token = nil, nil
  else
    network.fail(reason)
  end
end

-- Starts trying to get back into the room from a fresh socket. The race goes on
-- meanwhile, and the others see this car as a ghost until it's back.
local function startBack()
  network.backSince = now()
  network.resocketAt = now()
  notice("away")
end

local function resocket()
  network.resocketAt = now() + RESOCKET
  dropSocket()
  local udp = socket.udp()
  udp:settimeout(0)
  if not udp:setpeername(network.address[1], network.address[2]) then
    udp:close()
    return
  end
  network.udp = udp
  -- A cookie belongs to an address, and this is a new one.
  network.cookie = nil
  register("back")
end

local function onRoom(rest)
  local fields = split(rest)
  local slot, seats = (fields[1] or ""):match("^%d+$"), (fields[3] or ""):match("^[%d,]*$")
  if not slot or not seats or not (fields[4] or ""):match("^[01]$") then return end
  network.slot = tonumber(slot)
  if fields[5] and fields[5]:match("^[%w_%-]+$") then network.token = fields[5] end
  if network.backSince then
    network.backSince = nil
    notice("back")
  end

  local away = {}
  for seat in (fields[6] or ""):gmatch("%d+") do away[tonumber(seat)] = true end

  local present, leader = {}, nil
  for seat in seats:gmatch("%d+") do
    seat = tonumber(seat)
    present[seat] = true
    if not leader or seat < leader then leader = seat end
  end
  for seat in pairs(network.peers) do
    if not present[seat] then
      network.peers[seat] = nil
      network.departures[#network.departures + 1] = seat
    end
  end
  for seat in pairs(present) do
    if seat ~= network.slot and not network.peers[seat] then network.peers[seat] = {} end
  end
  for seat, peer in pairs(network.peers) do
    if away[seat] and not peer.away then notice("peerAway", seat) end
    if peer.away and not away[seat] then notice("peerBack", seat) end
    peer.away = away[seat] or nil
  end
  if network.leader and network.leader ~= leader then network.clock = {} end
  network.leader = leader

  if network.status == "connecting" then network.status = "lobby" end
end

local function handleEvent(data)
  local kind, rest = data:match("^event|([^|]+)|?(.*)$")
  if kind == "room" then
    onRoom(rest)
  elseif kind == "cookie" then
    local cookie = rest:match("^[%w_%-]+")
    if not cookie then return end
    network.cookie = cookie
    if network.status == "connecting" then
      register(network.role)
    elseif network.backSince then
      register("back")
    end
  elseif kind == "error" then
    -- Refused a seat, or my own seat back. A race goes on alone either way.
    connectionLost(rest ~= "" and rest or "The server refused the connection")
  elseif kind == "closed" then
    connectionLost(rest ~= "" and rest or "The server closed the room")
  end
end

-- Sharing the track ---------------------------------------------------------

local function adoptSetup(setup)
  if (setup.needs or 0) > network.FEATURES then
    network.fail("The host's race needs a newer version of the game")
    return false
  end
  local current = network.setup
  if not current or current.hash ~= setup.hash then
    local entry = catalog.findByHash(setup.hash)
    network.def = entry and entry.def or nil
    network.download = nil
    if not entry then
      if setup.chunks < 1 or setup.chunks > MAX_CHUNKS then
        network.fail("That track is too big to share")
        return false
      end
      network.download = { hash = setup.hash, count = setup.chunks, got = 0, parts = {} }
    end
  end
  network.setup = setup
  return true
end

local function askForChunks()
  local download = network.download
  local missing = {}
  for i = 1, download.count do
    if not download.parts[i] then
      missing[#missing + 1] = i
      if #missing >= CHUNKS_PER_ASK then break end
    end
  end
  send(string.format("need|%s|%s", download.hash, table.concat(missing, ",")))
end

local function onNeed(rest)
  local setup = network.setup
  local hash, list = (head(rest, 2) or ""):match("^(%x+)|([%d,]+)$")
  if not hash or not network.isLeader() or not setup or setup.hash ~= hash or not network.def then return end
  -- From the track itself, because the leader may have inherited the job.
  local text = catalog.fingerprint(network.def)
  local sent = 0
  for index in list:gmatch("%d+") do
    index = tonumber(index)
    if index >= 1 and index <= setup.chunks and sent < CHUNKS_PER_ASK then
      local from = (index - 1) * CHUNK_BYTES + 1
      send(string.format("chunk|%s|%d|%s", hash, index, text:sub(from, from + CHUNK_BYTES - 1)))
      sent = sent + 1
    end
  end
end

local function onChunk(rest)
  local download = network.download
  local hash, index, body = rest:match("^(%x+)|(%d+)|(.*)$")
  if not download or hash ~= download.hash then return end
  index = tonumber(index)
  if index < 1 or index > download.count or download.parts[index] or #body > CHUNK_BYTES then return end
  download.parts[index] = body
  download.got = download.got + 1
  if download.got < download.count then return end

  network.download = nil
  local text = table.concat(download.parts)
  local digest = love.data.encode("string", "hex", love.data.hash("md5", text)):sub(1, 16)
  local def = digest == hash and wire.decode(text)
  if not def then
    network.fail("The host's track didn't arrive in one piece")
    return
  end
  network.def = def
end

-- Receiving ---------------------------------------------------------------

local function handlePeer(from, data)
  local peer = network.peers[from]
  if not peer then return end
  local kind, rest = data:match("^(%a+)|(.*)$")
  if kind == "sync" then
    local s = network.unpackState(data)
    -- A late packet would drag the car backwards, and a stale one is from the last race.
    if s and s.round == network.round and s.seq > (peer.seq or -1) then
      s.at = now()
      peer.seq = s.seq
      peer.state = s
    end
  elseif kind == "look" then
    local look = network.unpackLook(data)
    if look and look.round == network.round then peer.look = look end
  elseif kind == "hello" then
    local hello = network.unpackHello(data)
    if hello then
      peer.car, peer.paint, peer.have = hello.car, hello.paint, hello.have
      peer.ready, peer.vote, peer.features = hello.ready, hello.vote, hello.features
    end
  elseif kind == "setup" then
    if from ~= network.leader then return end
    local setup = network.unpackSetup(data)
    if not setup or not adoptSetup(setup) then return end
    if setup.round > network.round then beginRound(setup.round) end
    if setup.round == network.round and setup.startAt > 0 and not network.startLocal then
      local offset = clockOffset()
      if offset then network.startLocal = setup.startAt - offset end
    end
  elseif kind == "ping" then
    if network.isLeader() then send(string.format("pong|%d|%s|%.4f", from, rest, now())) end
  elseif kind == "pong" then
    local slot, sentAt, leaderTime = (head(rest, 3) or ""):match("^(%d+)|([%d%.]+)|([%d%.]+)$")
    if tonumber(slot) == network.slot and from == network.leader then
      onPong(tonumber(sentAt), tonumber(leaderTime))
    end
  elseif kind == "need" then
    onNeed(rest)
  elseif kind == "chunk" then
    onChunk(rest)
  end
end

local function receive()
  -- An event can close the connection, so check it each time round.
  while network.udp do
    local data = network.udp:receive()
    if not data then break end
    network.lastHeard = now()
    if data:sub(1, 6) == "event|" then
      handleEvent(data)
    else
      local from, rest = data:match("^(%d)|(.*)$")
      if from then handlePeer(tonumber(from), rest) end
    end
  end
end

-- The leader's jobs ---------------------------------------------------------

local function everyoneReady()
  for _, peer in pairs(network.peers) do
    if peer.ready ~= network.round then return false end
  end
  return true
end

local function everyoneVoted()
  if not network.hasVoted() then return false end
  local voted, total = network.rematchCount()
  return total > 0 and voted == total
end

local function lead()
  if network.round > 0 and not network.startLocal and network.loaded
    and (everyoneReady() or now() - network.loadingSince > LOAD_LIMIT) then
    network.startLocal = now() + START_LEAD + config.START_DELAY
  end
  if network.status == "racing" and everyoneVoted() then beginRound(network.round + 1) end
end

-- Update --------------------------------------------------------------------

local function allKnown()
  for _, peer in pairs(network.peers) do
    if not peer.car then return false end
  end
  return true
end

local function tick()
  if network.status == "connecting" then
    register(network.role)
    return
  end
  -- Nothing else reaches the others until the relay knows this address.
  if network.backSince then
    register("back")
    return
  end
  send(network.packHello(myHello()))
  if network.isLeader() then
    if network.setup then publish() end
  elseif network.status ~= "racing" or not network.startLocal or network.hasVoted() then
    send(string.format("ping|%.4f", now()))
  end
  if network.download then askForChunks() end
end

function network.update(dt)
  -- Between sockets while getting back in, there may be none for a moment.
  if not network.udp and not network.backSince then return end
  receive()
  if not network.udp and not network.backSince then return end

  if network.isLeader() then lead() end
  if network.pending and network.def and allKnown() then
    network.pending = false
    network.ready = true
  end

  network.resendTimer = network.resendTimer - dt
  if network.resendTimer <= 0 then
    network.resendTimer = RESEND
    tick()
  end

  local silent = now() - network.lastHeard
  if network.status == "connecting" then
    if silent > TIMEOUT then network.fail("No answer from the server. Check the address.") end
  elseif network.token then
    -- The relay keeps the seat a while, so try to get back into it: the phone
    -- may have changed networks, or been in the background.
    if not network.backSince and silent > RETRY_AFTER then startBack() end
    if network.backSince then
      if now() - network.backSince > BACK_LIMIT then
        connectionLost("Lost the connection to the server")
      elseif now() >= network.resocketAt then
        resocket()
      end
    end
  elseif silent > TIMEOUT then
    connectionLost("Lost the connection to the server")
  end
end

-- Whether this game is trying to get back into its room.
function network.reconnecting()
  return network.backSince ~= nil
end

function network.sendLook(look)
  if not network.udp or network.status ~= "racing" then return end
  look.round = network.round
  send(network.packLook(look))
end

-- How one driver's car looks, or nil if their game hasn't said.
function network.lookOf(slot)
  local peer = network.peers[slot]
  return peer and peer.look
end

-- The freshest state from one driver and how old it is, in seconds.
function network.stateOf(slot)
  return function()
    local peer = network.peers[slot]
    local s = peer and peer.state
    if not s then return nil end
    return s, now() - s.at
  end
end

function network.sendCar(car)
  if not network.udp or network.status ~= "racing" then return end
  network.seq = (network.seq or 0) + 1
  local model = car.model
  local slide = 0
  for i = 1, 4 do slide = math.max(slide, model.wheels[i].slide or 0) end
  local vx, vy = car.body:getLinearVelocity()
  send(network.packState({
    round = network.round, seq = network.seq,
    x = car.curX, y = car.curY, a = car.curA, vx = vx, vy = vy,
    steer = model.steer, rpm = model.rpm, throttle = model.throttle, brake = model.brake, gear = model.gear,
    horn = car.horn, reverse = model.reverse, boost = model.boostState == "active",
    lowBeam = car.lowBeam, highBeam = car.highBeam, ghost = car.ghostTimer > 0, wreck = car.wreck ~= nil,
    slide = slide, distance = car.distance, finish = car.finishTime,
  }))
end

reset()

return network
