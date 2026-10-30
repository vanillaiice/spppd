local h = require("tests/harness")
local network = require("src/network_manager")
local Race = require("src/sim/race")
local Track = require("src/sim/track")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")

-- A second, independent client for the live relay test.
local function freshClient()
  return love.filesystem.load("src/network_manager.lua")()
end

h.describe("network", function()
  h.it("car state survives the trip through a packet", function()
    local packed = network.packState({ x = 100.5, y = -20.25, a = 1.5, vx = 3, vy = 4, steer = -0.2, rpm = 5000, throttle = 1, brake = 0, gear = 3 })
    local s = network.unpackState(packed)
    h.assertNear(s.x, 100.5, 0.1)
    h.assertNear(s.a, 1.5, 0.01)
    h.assertEq(s.gear, 3)
    h.assertEq(s.rpm, 5000)
  end)

  h.it("rejects malformed packets", function()
    h.assertEq(network.unpackState("sync|1|2"), nil)
    h.assertEq(network.unpackState("sync|a|b|c|d|e|f|g|h|i|j"), nil)
    h.assertEq(network.unpackState("nonsense"), nil)
    h.assertEq(network.unpackHello("event|hello|broken"), nil)
  end)

  h.it("hello carries the race setup", function()
    local hello = network.unpackHello(network.packHello({ car = "rocket", paint = 3, track = "lusail", laps = 5, time = "dusk", seen = true }))
    h.assertEq(hello.car, "rocket")
    h.assertEq(hello.laps, 5)
    h.assertEq(hello.time, "dusk")
    h.assertTrue(hello.seen)
  end)

  h.it("room codes are readable", function()
    for _ = 1, 50 do
      local code = network.generateCode()
      h.assertEq(#code, 4)
      h.assertTrue(not code:find("[01OI]"), "ambiguous character in " .. code)
    end
  end)

  h.it("a remote car follows its packets without running its own physics", function()
    local track = Track.new(catalog.builtin()[1].def)
    local s = track.samples[20]
    local state = { x = s.x, y = s.y, a = 0.5, vx = 50, vy = 0, steer = 0.1, rpm = 4000, throttle = 1, brake = 0, gear = 2 }
    local race = Race.new({
      mode = "race", track = track, laps = 2, seed = 1, startDelay = 0.05,
      online = { slot = 1, peerSpec = garage[2], peerColor = { 1, 0, 0 }, state = function() return state, 0.05 end },
    })
    local peer = race.cars[2]
    h.assertTrue(peer.remote and #race.cars == 2, "two cars")
    for _ = 1, 120 do race:step(1 / 120) end
    h.assertNear(peer.curX, s.x + 2.5, 8, "tracked the packet")
    h.assertNear(peer.body:getAngle(), 0.5, 0.05, "tracked the angle")
    h.assertEq(peer.model.gear, 2)
    race:destroy()
  end)

  h.it("two clients pair through the real relay", function()
    local relay = os.getenv("SPPPD_RELAY")
    if not relay then
      print("        skipped: set SPPPD_RELAY=host:port to run against a live server")
      return
    end
    local host, port = relay:match("^(.+):(%d+)$")
    local socket = require("socket")
    local a, b = freshClient(), freshClient()
    a.connect(host, tonumber(port), "host", "TEST", { car = "rocket", paint = 2, track = "harbour", laps = 4, time = "night" })
    local function pump(seconds, until_)
      local deadline = socket.gettime() + seconds
      while socket.gettime() < deadline do
        a.update(0.02)
        b.update(0.02)
        if until_() then return true end
        socket.sleep(0.02)
      end
      return false
    end
    h.assertTrue(pump(2, function() return a.status == "waiting" end), "host should get its ack, is " .. a.status .. " " .. a.message)
    b.connect(host, tonumber(port), "join", "TEST", { car = "samurai", paint = 5, track = "lusail", laps = 1, time = "day" })
    h.assertTrue(pump(3, function() return a.ready and b.ready end),
      "both should be ready, got " .. a.status .. "/" .. b.status)
    h.assertEq(a.session.track, "harbour", "host picks the track")
    h.assertEq(b.session.track, "harbour", "joiner takes the host's track")
    h.assertEq(b.session.laps, 4)
    h.assertEq(a.session.peerCar, "samurai", "host sees the joiner's car")
    h.assertEq(b.session.peerCar, "rocket", "joiner sees the host's car")
    h.assertEq(a.session.slot, 1)
    h.assertEq(b.session.slot, 2)

    -- Race data flows, and a departure is noticed.
    local car = { curX = 10, curY = 20, curA = 1, body = { getLinearVelocity = function() return 1, 2 end },
      model = { steer = 0, rpm = 3000, throttle = 1, brake = 0, gear = 2 } }
    h.assertTrue(pump(2, function()
      a.sendCar(car)
      return b.peerState ~= nil
    end), "state should reach the joiner")
    h.assertNear(b.peerState.x, 10, 0.1)
    a.disconnect()
    h.assertTrue(pump(2, function() return b.peerGone end), "joiner should learn the host left")
    b.disconnect()
  end)

  h.it("reports a bad room code", function()
    local relay = os.getenv("SPPPD_RELAY")
    if not relay then return end
    local host, port = relay:match("^(.+):(%d+)$")
    local socket = require("socket")
    local c = freshClient()
    c.connect(host, tonumber(port), "join", "ZZZZ", { car = "rocket", paint = 1, track = "lusail", laps = 1, time = "day" })
    local deadline = socket.gettime() + 2
    while socket.gettime() < deadline and c.status ~= "error" do
      c.update(0.02)
      socket.sleep(0.02)
    end
    h.assertEq(c.status, "error")
    h.assertTrue(c.message:find("No room"), c.message)
  end)
end)
