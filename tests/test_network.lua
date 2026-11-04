local h = require("tests/harness")
local network = require("src/network_manager")
local wire = require("src/tracks/wire")
local Race = require("src/sim/race")
local Track = require("src/sim/track")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")
local socket = require("socket")

-- Independent clients for the live relay tests.
local function freshClient()
  return love.filesystem.load("src/network_manager.lua")()
end

local function relayAddress()
  local relay = os.getenv("SPPPD_RELAY")
  if not relay then
    print("        skipped: set SPPPD_RELAY=host:port to run against a live server")
    return nil
  end
  local host, port = relay:match("^(.+):(%d+)$")
  return host, tonumber(port)
end

-- Runs clients together until `done`, as frames of a game would.
local function pump(clients, seconds, done, each)
  local deadline = socket.gettime() + seconds
  while socket.gettime() < deadline do
    for _, client in ipairs(clients) do client.update(0.02) end
    if each then each() end
    if done() then return true end
    socket.sleep(0.01)
  end
  return false
end

local function codeFor(name)
  return name .. love.math.random(1000, 9999)
end

local function hostRace(def)
  local entry = catalog.builtin()[1]
  return { def = def or entry.def, title = "TEST", laps = 4, time = "night" }
end

local function stateOf(overrides)
  local s = { x = 100.5, y = -20.25, a = 1.5, vx = 3, vy = 4, steer = -0.2, rpm = 5000, throttle = 1, brake = 0, gear = 3 }
  for k, v in pairs(overrides or {}) do s[k] = v end
  return s
end

-- A saved track only the host has.
local function ownTrack()
  local nodes = {}
  for i = 1, 200 do
    local a = i / 200 * math.pi * 2
    nodes[i] = { x = math.cos(a) * 900 + 7.5, y = math.sin(a) * 620, wl = 34, wr = 30 }
  end
  return { title = "My Own Oval", theme = "desert", scale = 3, nodes = nodes,
    startPoint = { x = 907.5, y = 0, angle = math.pi / 2 } }
end

-- Fills a room: a host and joiners, all in the lobby.
local function fillRoom(host, port, count, race)
  local code = codeFor("R")
  local clients = {}
  clients[1] = freshClient()
  clients[1].connect(host, port, "host", code, { car = "rocket", paint = 2 }, race or hostRace())
  h.assertTrue(pump(clients, 2, function() return clients[1].status == "lobby" end), "host should get a room")
  for i = 2, count do
    clients[i] = freshClient()
    clients[i].connect(host, port, "join", code, { car = garage[i].id, paint = i }, nil)
  end
  h.assertTrue(pump(clients, 8, function()
    local have = 0
    for _, peer in pairs(clients[1].peers) do
      if peer.have then have = have + 1 end
    end
    return have == count - 1
  end), "everyone should arrive with the track")
  return clients
end

-- Pretends each game loaded as soon as it was told to.
local function loadWhenReady(clients)
  return function()
    for _, client in ipairs(clients) do
      if client.ready then
        client.ready = false
        client.raceLoaded()
      end
    end
  end
end

local function fakeCar(distance, finish)
  local wheels = { { slide = 0 }, { slide = 0 }, { slide = 0.5 }, { slide = 0 } }
  return { curX = 10, curY = 20, curA = 1, ghostTimer = 0, body = { getLinearVelocity = function() return 1, 2 end },
    model = { steer = 0, rpm = 3000, throttle = 1, brake = 0, gear = 2, wheels = wheels, boostState = "active", reverse = false },
    distance = distance or 0, finishTime = finish, horn = true, lowBeam = true, highBeam = false }
end

-- Loses a share of what it sends and receives. A receive that's lost is simply a
-- datagram nobody reads, which is what the game would see.
local function lossy(client, share)
  local real = client.udp
  client.udp = {
    send = function(_, data)
      if love.math.random() >= share then return real:send(data) end
    end,
    receive = function()
      while true do
        local data = real:receive()
        if not data or love.math.random() >= share then return data end
      end
    end,
    close = function() real:close() end,
  }
end

h.describe("network", function()
  h.it("car state survives the trip through a packet", function()
    local s = network.unpackState(network.packState(stateOf({ round = 3, seq = 41, distance = 1234, finish = 61.25 })))
    h.assertEq(s.round, 3)
    h.assertEq(s.seq, 41)
    h.assertNear(s.x, 100.5, 0.1)
    h.assertNear(s.a, 1.5, 0.01)
    h.assertEq(s.gear, 3)
    h.assertEq(s.rpm, 5000)
    h.assertEq(s.distance, 1234)
    h.assertEq(s.finish, 61.25)
    h.assertTrue(not s.horn and not s.boost and not s.reverse)
  end)

  h.it("flags carry what the rival's car is doing", function()
    local s = network.unpackState(network.packState(stateOf({ horn = true, boost = true, highBeam = true, slide = 0.75 })))
    h.assertTrue(s.horn and s.boost and s.highBeam)
    h.assertTrue(not s.reverse and not s.lowBeam)
    h.assertEq(s.slide, 0.75)
    h.assertTrue(network.unpackState(network.packState(stateOf({ reverse = true, lowBeam = true }))).reverse)
  end)

  h.it("a rival back on the road is a ghost here too", function()
    h.assertTrue(network.unpackState(network.packState(stateOf({ ghost = true }))).ghost)
    h.assertTrue(not network.unpackState(network.packState(stateOf({}))).ghost)
  end)

  h.it("a rival wrecked on their screen is wrecked here too", function()
    local s = network.unpackState(network.packState(stateOf({ wreck = true, horn = true })))
    h.assertTrue(s.wreck and s.horn and not s.boost and not s.ghost)
    h.assertTrue(not network.unpackState(network.packState(stateOf({}))).wreck)
  end)

  h.it("rejects malformed packets", function()
    h.assertEq(network.unpackState("sync|1|2"), nil)
    h.assertEq(network.unpackState("sync|a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p"), nil)
    h.assertEq(network.unpackState("nonsense"), nil)
    h.assertEq(network.unpackHello("hello|broken"), nil)
    h.assertEq(network.unpackHello("hello|bad|car|1|0|0|0"), nil)
    h.assertEq(network.unpackSetup("setup|broken"), nil)
  end)

  h.it("rejects numbers that would break the game", function()
    local base = network.packState(stateOf())
    for _, bad in ipairs({ "inf", "-inf", "nan", "1e308", "0x1p1024" }) do
      local parts = {}
      for chunk in base:gmatch("[^|]+") do parts[#parts + 1] = chunk end
      parts[4] = bad  -- x
      h.assertEq(network.unpackState(table.concat(parts, "|")), nil, bad .. " as a position")
    end
    local wild = network.unpackState(network.packState(stateOf({ rpm = 29000, throttle = 5, brake = -3, gear = 900 })))
    h.assertEq(wild.throttle, 1, "pedals stay pedals")
    h.assertEq(wild.brake, 0)
    h.assertEq(wild.gear, 12, "and gears stay gears")
  end)

  h.it("hello carries a driver's state", function()
    local hello = network.unpackHello(network.packHello({ car = "4wd_monster", paint = 3, have = true, ready = 2, vote = 3 }))
    h.assertEq(hello.car, "4wd_monster")
    h.assertEq(hello.paint, 3)
    h.assertTrue(hello.have)
    h.assertEq(hello.ready, 2)
    h.assertEq(hello.vote, 3)
  end)

  h.it("setup carries the race, and clamps what it's told", function()
    local setup = network.unpackSetup(network.packSetup({ round = 2, hash = "abc123", chunks = 3, laps = 5, time = "dusk",
      startAt = 123.456, title = "HARBOUR" }))
    h.assertEq(setup.round, 2)
    h.assertEq(setup.hash, "abc123")
    h.assertEq(setup.chunks, 3)
    h.assertEq(setup.laps, 5)
    h.assertEq(setup.time, "dusk")
    h.assertNear(setup.startAt, 123.456, 0.001)
    h.assertEq(setup.title, "HARBOUR")
    h.assertEq(network.unpackSetup("setup|1|ab|1|999|day|0|X").laps, 20, "laps stay in range")
  end)

  h.it("room codes are readable", function()
    for _ = 1, 50 do
      local code = network.generateCode()
      h.assertEq(#code, 6)
      h.assertTrue(not code:find("[01OI]"), "ambiguous character in " .. code)
    end
  end)

  h.it("every built-in track survives the wire", function()
    for _, entry in ipairs(catalog.builtin()) do
      local text = wire.encode(entry.def)
      h.assertTrue(#text < wire.MAX_BYTES, entry.name .. " is too big to send")
      local def, why = wire.decode(text)
      h.assertTrue(def, entry.name .. ": " .. tostring(why))
      h.assertEq(wire.encode(def), text, entry.name .. " should encode the same both ways")
      local original, copy = Track.new(entry.def), Track.new(def)
      h.assertEq(copy.count, original.count, entry.name .. " has the same samples")
      h.assertNear(copy.length, original.length, 1, entry.name .. " is the same length")
      h.assertEq(copy.theme, original.theme)
    end
  end)

  h.it("a track from a stranger is checked before it's built", function()
    local good = wire.encode(ownTrack())
    h.assertTrue(wire.decode(good), "a normal track passes")
    local node = "node 0 0 30 30\n"
    local cases = {
      { "return os.exit()", "Lua isn't a track" },
      { "\27LJ\2bytecode", "and nor is bytecode" },
      { string.rep("x", wire.MAX_BYTES + 1), "too big" },
      { "spppd-track 1\n", "empty" },
      { "spppd-track 1\n" .. node:rep(2), "too few nodes" },
      { "spppd-track 1\n" .. node:rep(1501), "too many nodes" },
      { "spppd-track 1\nnode 1e308 0 30 30\n" .. node:rep(4), "a position out of range" },
      { "spppd-track 1\nnode nan 0 30 30\n" .. node:rep(4), "NaN" },
      { "spppd-track 1\nnode 0 0 0 30\n" .. node:rep(4), "no width" },
      { "spppd-track 1\nscale 900\n" .. node:rep(4), "a silly scale" },
      { "spppd-track 1\nrunoff 900\n" .. node:rep(4), "silly runoff" },
      { "spppd-track 1\nnode 0 0 30 30\nnode 90000 0 30 30\nnode 90000 90000 30 30\nnode 0 90000 30 30\n", "a lap too long to build" },
      { "spppd-track 1\nseg left curve " .. string.rep("1 1 ", 65) .. "\nseg right line 0 0 1 1\n", "a curve of too many points" },
      { "spppd-track 1\nseg top line 0 0 1 1\nseg right line 0 0 1 1\n", "a made-up side" },
    }
    for _, case in ipairs(cases) do
      h.assertEq(wire.decode(case[1]), nil, case[2])
    end
  end)

  h.it("what comes off the wire can only be plain values", function()
    local def = wire.decode("spppd-track 1\ntitle Bad\xff|Name\nnode 0 0 30 30\nnode 1 0 30 30\nnode 1 1 30 30\nnode 0 1 30 30\ntheme lava\n")
    h.assertEq(def.title, "BadName", "stripped to what the font can print")
    h.assertEq(def.theme, "meadow", "an unknown theme falls back")
  end)

  h.it("same shape, same hash, whatever the track is called", function()
    local a, b = ownTrack(), ownTrack()
    local _, hashA = catalog.fingerprint(a)
    local _, hashB = catalog.fingerprint(b)
    h.assertEq(hashA, hashB)
    local c = ownTrack()
    c.nodes[50].x = c.nodes[50].x + 12
    local _, hashC = catalog.fingerprint(c)
    h.assertTrue(hashC ~= hashA, "a different road is a different track")
    local entry = catalog.builtin()[3]
    local _, hash = catalog.fingerprint(entry.def)
    h.assertEq(catalog.findByHash(hash).name, entry.name, "built-ins are found by shape")
    h.assertEq(catalog.findByHash("0000000000000000"), nil)
  end)

  h.it("hosting always makes a new room code, and joining uses the one entered", function()
    local menu = require("src/menu")
    local connect = network.connect
    local sent
    network.connect = function(_, _, role, code, me, race) sent = { role = role, code = code, me = me, race = race } end
    network.roomCode = "OLD123"
    menu.connect("host")
    h.assertEq(sent.role, "host")
    h.assertEq(#sent.code, 6)
    h.assertTrue(sent.code ~= "OLD123", "a stale code was reused")
    h.assertEq(sent.race.def, catalog.find(require("src/settings").track).def)
    network.roomCode = "FRIEND"
    menu.connect("join")
    h.assertEq(sent.code, "FRIEND")
    h.assertEq(sent.race, nil, "a joiner brings no race")
    network.connect = connect
    network.roomCode = ""
  end)

  h.it("only the host sets the race, and everyone picks a car", function()
    local menu = require("src/menu")
    local function labels(rows)
      local found = {}
      for _, row in ipairs(rows) do found[row.label] = row end
      return found
    end
    network.status = "idle"
    local online = labels(menu.onlineRows())
    for _, label in ipairs({ "CAR", "PAINT", "HOST A ROOM", "ROOM CODE", "JOIN A ROOM", "PRIVACY & TERMS" }) do
      h.assertTrue(online[label], label .. " is missing")
    end
    for _, label in ipairs({ "TRACK", "LAPS", "TIME" }) do
      h.assertTrue(not online[label], "a joiner can see " .. label)
    end
    local host = labels(menu.hostRows())
    for _, label in ipairs({ "TRACK", "LAPS", "TIME", "START ROOM" }) do
      h.assertTrue(host[label], label .. " is missing")
    end
    network.status = "lobby"
    local joiner = labels(menu.onlineRows())
    h.assertTrue(joiner.CANCEL and not joiner.CAR and not joiner["HOST A ROOM"], "still choosing while connected")
    h.assertTrue(not joiner["START RACE"], "a joiner can't start the race")
    network.slot, network.leader = 1, 1
    local alone = labels(menu.onlineRows())
    h.assertTrue(alone["START RACE"] and alone["START RACE"].disabled, "a host can't race alone")
    network.peers = { [2] = { have = false } }
    h.assertTrue(labels(menu.onlineRows())["START RACE"].disabled, "or before everyone has the track")
    network.peers = { [2] = { have = true } }
    h.assertTrue(not labels(menu.onlineRows())["START RACE"].disabled, "and can once they do")
    network.peers, network.slot, network.leader = {}, nil, nil
    network.status = "idle"
  end)

  h.it("warns players about what online can't do", function()
    local notes = table.concat(require("src/menu").ONLINE_NOTES, " ")
    for _, word in ipairs({ "new", "way back in", "cheat", "connection", "same version", "IP address" }) do
      h.assertTrue(notes:find(word, 1, true), "the notes should mention " .. word)
    end
  end)

  h.it("online doesn't touch the player's saved race", function()
    local menu = require("src/menu")
    local settings = require("src/settings")
    local rm = require("src/race_manager")
    local before = { settings.track, settings.laps, settings.time, settings.mode }
    local start, raceConfig, loaded = rm.start, network.raceConfig, network.raceLoaded
    local got
    rm.start = function(opts) got = opts end
    network.raceLoaded = function() end
    network.raceConfig = function()
      return { def = catalog.builtin()[2].def, title = "HIGHLANDS", laps = 9, time = "midnight", slot = 2,
        peers = { { slot = 1, car = "no-such-car", paint = 99 } } }
    end
    settings.mode = "freestyle"
    menu.startOnline()
    rm.start, network.raceConfig, network.raceLoaded = start, raceConfig, loaded
    h.assertEq(got.mode, "race", "an online race is a race, whatever the menu last showed")
    h.assertEq(got.laps, 9)
    h.assertEq(got.time, "midnight")
    h.assertEq(settings.track, before[1])
    h.assertEq(settings.laps, before[2])
    h.assertEq(settings.time, before[3])
    h.assertEq(got.online.peers[1].spec, garage[1], "an unknown car falls back rather than crashing")
    settings.mode = before[4]
  end)

  h.it("a track that won't build reports it rather than throwing", function()
    local menu = require("src/menu")
    local raceConfig = network.raceConfig
    local message
    local fail = network.fail
    network.fail = function(text) message = text end
    network.raceConfig = function() return { def = { nodes = {} }, title = "X", laps = 1, time = "day", slot = 2, peers = {} } end
    menu.startOnline()
    network.raceConfig, network.fail = raceConfig, fail
    h.assertTrue(message and message:find("couldn't be built"), tostring(message))
  end)

  h.it("a remote car follows its packets without running its own physics", function()
    local track = Track.new(catalog.builtin()[1].def)
    local s = track.samples[20]
    local state = { x = s.x, y = s.y, a = 0.5, vx = 50, vy = 0, steer = 0.1, rpm = 4000, throttle = 1, brake = 0, gear = 2 }
    local race = Race.new({
      mode = "race", track = track, laps = 2, seed = 1, startDelay = 0.05,
      online = { slot = 1, peers = { { slot = 2, spec = garage[2], color = { 1, 0, 0 }, state = function() return state, 0.05 end } } },
    })
    local peer = race.cars[2]
    h.assertTrue(peer.remote and #race.cars == 2, "two cars")
    for _ = 1, 120 do race:step(1 / 120) end
    h.assertNear(peer.curX, s.x + 2.5, 8, "tracked the packet")
    h.assertNear(peer.body:getAngle(), 0.5, 0.05, "tracked the angle")
    h.assertEq(peer.model.gear, 2)
    race:destroy()
  end)

  h.it("a remote car shows what its driver is doing", function()
    local track = Track.new(catalog.builtin()[1].def)
    local state = { x = 0, y = 0, a = 0, vx = 0, vy = 0, steer = 0, rpm = 4000, throttle = 1, brake = 0, gear = 2,
      boost = true, reverse = true, slide = 0.6, lowBeam = false, highBeam = true, horn = true }
    local race = Race.new({ mode = "race", track = track, laps = 2, seed = 1, startDelay = 0.01,
      online = { slot = 1, peers = { { slot = 2, spec = garage[2], state = function() return state, 0 end } } } })
    local peer = race.cars[2]
    state.x, state.y = peer.curX, peer.curY
    for _ = 1, 4 do race:step(1 / 120) end
    h.assertEq(peer.model.boostState, "active", "boost")
    h.assertTrue(peer.model.reverse, "reverse lamps")
    h.assertEq(peer.model.wheels[1].slide, 0.6, "tyre smoke")
    h.assertTrue(peer.highBeam and not peer.lowBeam, "their choice of headlights")
    h.assertTrue(peer.horn)
    race:destroy()
  end)

  h.it("a driver who stops sending stops moving", function()
    local track = Track.new(catalog.builtin()[1].def)
    local state = { x = 0, y = 0, a = 0, vx = 500, vy = 0, steer = 0, rpm = 4000, throttle = 1, brake = 0, gear = 2 }
    local age = 0
    local race = Race.new({ mode = "race", track = track, laps = 2, seed = 1, startDelay = 0.01,
      online = { slot = 1, peers = { { slot = 2, spec = garage[2], state = function() return state, age end } } } })
    local peer = race.cars[2]
    state.x, state.y = peer.curX, peer.curY
    for _ = 1, 4 do race:step(1 / 120) end
    age = 3
    for _ = 1, 60 do race:step(1 / 120) end
    local vx = peer.body:getLinearVelocity()
    h.assertEq(vx, 0, "it isn't still doing their last speed")
    h.assertNear(peer.curX, state.x, 1, "or carried off down the road")
    race:destroy()
  end)

  -- Everything below talks to a real relay.

  h.it("two clients pair through the real relay", function()
    local host, port = relayAddress()
    if not host then return end
    local c = fillRoom(host, port, 2)
    local a, b = c[1], c[2]
    h.assertEq(a.slot, 1)
    h.assertEq(b.slot, 2)
    h.assertTrue(a.isLeader() and not b.isLeader(), "the host leads")
    h.assertEq(b.setup.title, "TEST", "the joiner hears the host's race")
    h.assertEq(b.setup.laps, 4)
    h.assertEq(a.peers[2].car, garage[2].id, "host sees the joiner's car")
    h.assertEq(b.peers[1].car, "rocket", "joiner sees the host's car")
    h.assertTrue(b.def == catalog.builtin()[1].def, "a track both have needs no download")
    a.disconnect()
    h.assertTrue(pump({ b }, 3, function() return b.status == "error" end), "joiner should hear the host left")
    h.assertTrue(b.message:find("host left"), b.message)
  end)

  h.it("the lights go out together across two very different clocks", function()
    local host, port = relayAddress()
    if not host then return end
    local c = fillRoom(host, port, 2)
    local a, b = c[1], c[2]
    -- love.timer is shared in this process, so give b a clock of its own.
    local skew = 1234.5
    local timer = love.timer.getTime
    local aStartIn = a.startIn
    love.timer.getTime = function() return timer() + (rawget(_G, "__onB") and skew or 0) end
    local function asB(fn, ...)
      _G.__onB = true
      local out = fn(...)
      _G.__onB = false
      return out
    end
    b.clock = {}
    b.lastHeard = b.lastHeard + skew
    local update = b.update
    b.update = function(dt) asB(update, dt) end
    local bStartIn = function() return asB(b.startIn) end

    h.assertTrue(pump(c, 3, function() return #b.clock >= 3 end), "b should have a clock")
    a.startRace()
    local loaded = loadWhenReady(c)
    h.assertTrue(pump(c, 4, function() return a.startIn() and bStartIn() end, loaded), "both should be told the start")
    love.timer.getTime = timer
    b.update = update
    local gap = math.abs(aStartIn() - (b.startLocal - skew - timer()))
    h.assertTrue(gap < 0.03, string.format("the starts should agree, off by %.3f s", gap))
    h.assertTrue(aStartIn() > 3.6, "with time for everyone to get ready")
    a.disconnect()
    b.disconnect()
  end)

  h.it("a track only the host has reaches everyone intact, over a bad line", function()
    local host, port = relayAddress()
    if not host then return end
    local own = ownTrack()
    local code = codeFor("T")
    local a, b, c = freshClient(), freshClient(), freshClient()
    a.connect(host, port, "host", code, { car = "rocket", paint = 2 }, { def = own, title = "My Own Oval", laps = 2, time = "day" })
    h.assertTrue(pump({ a }, 2, function() return a.status == "lobby" end), "host should get a room")
    b.connect(host, port, "join", code, { car = "samurai", paint = 5 }, nil)
    c.connect(host, port, "join", code, { car = "cyber", paint = 1 }, nil)
    h.assertTrue(pump({ a, b, c }, 2, function() return b.status == "lobby" and c.status == "lobby" end), "joiners should arrive")
    lossy(a, 0.15)
    lossy(b, 0.15)
    lossy(c, 0.15)
    h.assertTrue(pump({ a, b, c }, 20, function() return b.def and c.def end), "the track should get through")
    local text = catalog.fingerprint(own)
    h.assertEq(wire.encode(b.def), text:gsub("title [^\n]*", "title My Own Oval"), "and arrive whole")
    h.assertEq(b.def.title, "My Own Oval")
    h.assertTrue(Track.new(b.def).count > 100, "and build")
    h.assertTrue(pump({ a, b, c }, 5, function() return a.canStart() end), "then the host can start")
    a.disconnect()
    b.disconnect()
    c.disconnect()
  end)

  h.it("four drivers start together, and one leaving doesn't stop the rest", function()
    local host, port = relayAddress()
    if not host then return end
    local c = fillRoom(host, port, 4)
    h.assertEq(c[4].slot, 4)
    c[1].startRace()
    local loaded = loadWhenReady(c)
    h.assertTrue(pump(c, 5, function()
      for _, client in ipairs(c) do
        if not client.startIn() then return false end
      end
      return true
    end, loaded), "everyone should get the start")

    local fifth = freshClient()
    fifth.connect(host, port, "join", c[1].roomCode, { car = "rocket", paint = 1 }, nil)
    h.assertTrue(pump({ fifth }, 2, function() return fifth.status == "error" end), "a started race takes nobody")
    h.assertTrue(fifth.message:find("started"), fifth.message)

    local car = fakeCar(5000)
    car.wreck = 0.8
    h.assertTrue(pump(c, 2, function()
      c[1].sendCar(car)
      return c[2].peers[1].state and c[3].peers[1].state and c[4].peers[1].state
    end), "a car should reach everyone")
    h.assertEq(c[4].peers[1].state.distance, 5000)
    h.assertTrue(c[4].peers[1].state.boost and c[4].peers[1].state.wreck, "flags and all")
    h.assertEq(c[4].peers[1].state.slide, 0.5)

    c[3].disconnect()
    h.assertTrue(pump({ c[1], c[2], c[4] }, 3, function() return c[1].peers[3] == nil and c[4].peers[3] == nil end),
      "the others should hear")
    local gone = c[1].takeDepartures()
    h.assertEq(#gone, 1)
    h.assertEq(gone[1], 3)

    -- The host leaving a race passes the room to the next seat.
    c[1].disconnect()
    h.assertTrue(pump({ c[2], c[4] }, 3, function() return c[2].isLeader() and c[4].leader == 2 end), "the next seat takes over")
    c[2].disconnect()
    c[4].disconnect()
  end)

  h.it("a rematch runs when everyone has asked, on the same room", function()
    local host, port = relayAddress()
    if not host then return end
    local c = fillRoom(host, port, 3)
    c[1].startRace()
    local loaded = loadWhenReady(c)
    h.assertTrue(pump(c, 5, function() return c[1].startIn() and c[2].startIn() and c[3].startIn() end, loaded), "first race")
    local firstStart = c[2].startLocal

    c[2].voteRematch()
    h.assertTrue(c[2].hasVoted())
    c[3].voteRematch()
    h.assertTrue(pump(c, 1, function() return select(1, c[1].rematchCount()) == 2 end, loaded), "the host hears the votes")
    h.assertEq(c[1].round, 1, "but one driver still hasn't asked")
    c[1].voteRematch()
    h.assertTrue(pump(c, 5, function()
      return c[2].round == 2 and c[3].round == 2 and c[1].startIn() and c[2].startIn() and c[3].startIn()
    end, loaded), "the second race should start")
    h.assertTrue(c[2].startLocal > firstStart, "on a new start time")
    h.assertTrue(not c[2].hasVoted(), "with the votes used up")
    h.assertEq(c[2].status, "racing")

    -- A packet from the race before doesn't count in this one.
    local old = network.packState(stateOf({ round = 1, seq = 999999 }))
    c[1].udp:send(old)
    socket.sleep(0.05)
    pump(c, 0.2, function() return false end)
    h.assertEq(c[2].peers[1].state, nil, "a stale round is ignored")
    for _, client in ipairs(c) do client.disconnect() end
  end)

  h.it("the host leaving between races doesn't strand a rematch", function()
    local host, port = relayAddress()
    if not host then return end
    local c = fillRoom(host, port, 3)
    c[1].startRace()
    local loaded = loadWhenReady(c)
    h.assertTrue(pump(c, 5, function() return c[2].startIn() and c[3].startIn() end, loaded), "first race")
    c[1].disconnect()
    local rest = { c[2], c[3] }
    h.assertTrue(pump(rest, 3, function() return c[2].isLeader() end), "seat 2 takes over")

    -- A driver still fetching the track gets it from whoever leads now.
    local setup = c[2].setup
    c[3].def = nil
    c[3].download = { hash = setup.hash, count = setup.chunks, got = 0, parts = {} }
    h.assertTrue(pump(rest, 4, function() return c[3].def ~= nil end), "the new leader can hand out the track")
    h.assertEq(select(2, catalog.fingerprint(c[3].def)), setup.hash, "and it's the same one")

    c[2].voteRematch()
    c[3].voteRematch()
    h.assertTrue(pump(rest, 6, function() return c[3].round == 2 and c[2].startIn() and c[3].startIn() end, loadWhenReady(rest)),
      "and calls the next start")
    c[2].disconnect()
    c[3].disconnect()
  end)

  h.it("a late packet doesn't move a car backwards", function()
    local host, port = relayAddress()
    if not host then return end
    local c = fillRoom(host, port, 2)
    c[1].startRace()
    local loaded = loadWhenReady(c)
    h.assertTrue(pump(c, 5, function() return c[2].startIn() end, loaded), "race")
    c[1].udp:send(network.packState(stateOf({ round = 1, seq = 10, x = 500 })))
    h.assertTrue(pump(c, 1, function() return c[2].peers[1].state end), "first packet")
    c[1].udp:send(network.packState(stateOf({ round = 1, seq = 9, x = 400 })))
    c[1].udp:send(network.packState(stateOf({ round = 1, seq = 11, x = 600 })))
    h.assertTrue(pump(c, 1, function() return c[2].peers[1].state.x == 600 end), "a newer packet")
    c[1].udp:send(network.packState(stateOf({ round = 1, seq = 10, x = 500 })))
    pump(c, 0.15, function() return false end)
    h.assertEq(c[2].peers[1].state.x, 600, "an older one is ignored")
    c[1].disconnect()
    c[2].disconnect()
  end)

  h.it("reports a bad room code", function()
    local host, port = relayAddress()
    if not host then return end
    local c = freshClient()
    c.connect(host, port, "join", "ZZZZ", { car = "rocket", paint = 1 }, nil)
    h.assertTrue(pump({ c }, 2, function() return c.status == "error" end), "should be refused")
    h.assertTrue(c.message:find("No room"), c.message)
  end)

  h.it("tells a driver when their version doesn't match the room", function()
    local host, port = relayAddress()
    if not host then return end
    local a, b = freshClient(), freshClient()
    local code = codeFor("V")
    a.connect(host, port, "host", code, { car = "rocket", paint = 1 }, hostRace())
    h.assertTrue(pump({ a }, 2, function() return a.status == "lobby" end), "room")
    b.PROTOCOL = 99
    b.connect(host, port, "join", code, { car = "rocket", paint = 1 }, nil)
    h.assertTrue(pump({ a, b }, 2, function() return b.status == "error" end), "should be refused")
    h.assertTrue(b.message:find("different version"), b.message)
    a.disconnect()
  end)

  h.it("a client that has been forgotten finds out", function()
    local host, port = relayAddress()
    if not host then return end
    local c = fillRoom(host, port, 2)
    c[1].startRace()
    local loaded = loadWhenReady(c)
    h.assertTrue(pump(c, 5, function() return c[2].startIn() end, loaded), "race")
    c[2].lastHeard = love.timer.getTime() - 7
    c[2].udp:close()
    c[2].udp = { send = function() end, receive = function() return nil end, close = function() end }
    c[2].update(0.02)
    h.assertTrue(c[2].lost and c[2].lost:find("Lost"), tostring(c[2].lost))
    h.assertEq(next(c[2].peers), nil, "the others are gone")
    h.assertEq(#c[2].takeDepartures(), 1, "and the race is told")
    h.assertTrue(not c[2].canRematch(), "and there's nobody to rematch")
    c[1].disconnect()
    c[2].disconnect()
  end)
end)
