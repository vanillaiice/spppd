-- Two drivers at one screen: the race with two of them in it, each driver's own
-- hands, and each pad's own motors.
local h = require("tests/harness")
local Race = require("src/sim/race")
local AI = require("src/ai_controller")
local Track = require("src/sim/track")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")
local config = require("src/config")
local input = require("src/input")
local rumble = require("src/rumble")
local settings = require("src/settings")
local dynamics = require("src/sim/dynamics")

local DT = config.PHYSICS_DT
local M = config.METER

local function run(race, seconds, stop)
  for i = 1, math.floor(seconds / DT) do
    race:step(DT)
    if stop and stop(race) then return i * DT end
  end
  return seconds
end

local function twoUp(opts)
  opts = opts or {}
  local track = not opts.lot and Track.new(catalog.builtin()[1].def) or nil
  local race = Race.new({
    mode = opts.mode or "race", track = track, lot = opts.lot, laps = opts.laps or 1,
    opponents = opts.opponents or 0, spec = garage[3], seed = 5, startDelay = 0.2,
    playerName = "P1", player2 = { spec = garage[5], color = { 1, 0, 0 }, name = "P2" },
  })
  return race, race.players[1], race.players[2]
end

-- A pad as far as input and rumble need one.
local function fakePad(id, axes)
  local pad = { calls = {}, axes = axes or {} }
  function pad:isConnected() return true end
  function pad:isGamepad() return true end
  function pad:getID() return id end
  function pad:getName() return "PAD " .. id end
  function pad:getGamepadAxis(axis) return self.axes[axis] or 0 end
  function pad:isVibrationSupported() return true end
  function pad:setVibration(l, r) self.calls[#self.calls + 1] = { l or 0, r or 0 } end
  return pad
end

h.describe("two at one screen", function()
  h.it("both drivers start on the grid behind the field, each their own car", function()
    local race, p1, p2 = twoUp({ opponents = 3 })
    h.assertEq(#race.players, 2)
    h.assertEq(#race.cars, 5, "three opponents and the two of them")
    h.assertTrue(p1.isPlayer and p2.isPlayer, "both are players")
    h.assertEq(p1.name, "P1")
    h.assertEq(p2.name, "P2")
    h.assertEq(p2.spec, garage[5])
    local x4, y4 = race.track:gridSlot(4)
    local x5, y5 = race.track:gridSlot(5)
    h.assertBetween(p1.body:getX(), x4 - 1, x4 + 1, "P1 in the first slot behind the field")
    h.assertBetween(p1.body:getY(), y4 - 1, y4 + 1)
    h.assertBetween(p2.body:getX(), x5 - 1, x5 + 1, "P2 in the next")
    h.assertBetween(p2.body:getY(), y5 - 1, y5 + 1)
    race:destroy()
  end)

  h.it("a race runs until both are home, and the results wait for the second", function()
    local race, p1, p2 = twoUp({ opponents = 1 })
    p1.driver = AI.new(race.track, p1, { skill = 0.95 })
    p2.driver = AI.new(race.track, p2, { skill = 0.9 })
    run(race, 400, function(r) return r.phase == "finished" end)
    h.assertEq(race.phase, "finished")
    h.assertTrue(p1.finished and p2.finished, "both took the flag")
    h.assertTrue(not p1.timedOut and not p2.timedOut)
    h.assertTrue(p1.place ~= p2.place, "and they have places of their own")
    race:destroy()
  end)

  h.it("the one still out when the time's up doesn't finish", function()
    local race, p1, p2 = twoUp()
    p1.driver = AI.new(race.track, p1, { skill = 0.95 })
    p2.driver = { update = function(_, c) c.input.throttle, c.input.brake = 0, 1 end }
    run(race, 400, function(r) return r.phase == "finished" end)
    h.assertEq(race.phase, "finished")
    h.assertTrue(p1.finished, "the first came home")
    h.assertTrue(not p2.finished and p2.timedOut, "the second ran out of time")
    h.assertTrue(p2.driver.update ~= nil and p2.driver.track ~= nil, "and drives a cool-down lap")
    race:destroy()
  end)

  h.it("on the lot they start apart in the box and reset to their own spots", function()
    local race, p1, p2 = twoUp({ mode = "freestyle", lot = true })
    h.assertTrue(p1.body:getX() < 0 and p2.body:getX() > 0, "side by side in the start box")
    h.assertTrue(math.abs(p1.body:getX() - p2.body:getX()) >= 4 * M, "with room between them")
    p2:teleport(40 * M, 40 * M, 0)
    race:respawn(p2)
    h.assertBetween(p2.body:getX(), 2 * M, 4 * M, "P2 goes back to their own spot")
    h.assertBetween(p2.body:getY(), -1 * M, 1 * M)
    race:destroy()
  end)

  h.it("a knocked cone waits until neither of them can see it go back", function()
    local race, p1, p2 = twoUp({ mode = "freestyle", lot = true })
    local cone = race.cones[#race.cones]
    p2:teleport(cone.homeX + 10 * M, cone.homeY, 0)
    cone.body:setPosition(cone.homeX + 3 * M, cone.homeY)
    local stop = { update = function(_, c) c.input.throttle, c.input.brake = 0, 1 end }
    p1.driver, p2.driver = stop, stop
    run(race, 0.1)
    h.assertTrue(cone.body:getX() > cone.homeX + 1 * M, "P2 is looking at it, P1 isn't")
    race:destroy()
  end)

  h.it("each driver has their own handling and gearbox", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 1, spec = garage[3], seed = 5,
      assist = "sim", manualGearbox = false,
      player2 = { spec = garage[3], name = "P2", assist = "arcade", manualGearbox = true } })
    local p1, p2 = race.players[1], race.players[2]
    h.assertEq(p1.model.assist, dynamics.new(garage[3], "sim").assist, "P1 on sim")
    h.assertEq(p2.model.assist, dynamics.new(garage[3], "arcade").assist, "P2 on arcade")
    h.assertTrue(p1.model.assist ~= p2.model.assist, "and they differ")
    h.assertTrue(p2.input.manual and not p1.input.manual, "P2's manual box is P2's alone")
    race:destroy()
  end)

  h.it("one driver alone still races as ever", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 2, spec = garage[3], seed = 5 })
    h.assertEq(#race.players, 1)
    h.assertEq(race.players[1], race.player)
    h.assertEq(race.player.name, "YOU")
    race:destroy()
  end)

  h.it("an online race never takes a second driver here", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 1, spec = garage[3],
      online = { slot = 1, peers = {} }, player2 = { spec = garage[2] } })
    h.assertEq(#race.players, 1)
    race:destroy()
  end)
end)

h.describe("each driver's own hands", function()
  h.it("a pad's reader hears only that pad", function()
    input.clear()
    local a, b = fakePad(1), fakePad(2)
    local ra, rb = input.reader(false, a), input.reader(false, b)
    input.gamepadPress(b, "leftshoulder")
    h.assertTrue(rb:isDown("boost"), "the pad pressed")
    h.assertTrue(not ra:isDown("boost"), "not the other")
    h.assertTrue(rb:consume("boost"), "the press is there once")
    h.assertTrue(not rb:consume("boost"), "and only once")
    h.assertTrue(not ra:consume("boost"))
    input.gamepadRelease(b, "leftshoulder")
    h.assertTrue(not rb:isDown("boost"))
    input.clear()
  end)

  h.it("the keyboard is its own driver's, and a pad driver doesn't feel it", function()
    input.clear()
    local pad = fakePad(1)
    local keys, other = input.reader(true, nil), input.reader(false, pad)
    input.press("w")
    input.press("e")
    local t1, t2 = {}, {}
    keys:applyTo(t1, true)
    other:applyTo(t2, true)
    h.assertEq(t1.throttle, 1, "W is the keyboard driver's gas")
    h.assertTrue(t1.shiftUp)
    h.assertEq(t2.throttle, 0, "not the pad driver's")
    h.assertTrue(not t2.shiftUp)
    input.clear()
  end)

  h.it("each pad's triggers and stick drive its own car", function()
    input.clear()
    local a = fakePad(1, { triggerright = 0.6, leftx = -1 })
    local b = fakePad(2, { triggerleft = 0.5, leftx = 0.5 })
    local ta, tb = {}, {}
    input.reader(false, a):applyTo(ta, false)
    input.reader(false, b):applyTo(tb, false)
    h.assertEq(ta.throttle, 0.6)
    h.assertEq(ta.brake, 0)
    h.assertTrue(ta.steer < -0.9 and not ta.keyboard, "full lock left on the stick")
    h.assertEq(tb.throttle, 0)
    h.assertEq(tb.brake, 0.5)
    h.assertTrue(tb.steer > 0, "steering right")
    input.clear()
  end)

  h.it("one pad goes to the second driver; with two, the keyboard joins the first", function()
    local a, b = fakePad(1), fakePad(2)
    local p1, p2 = input.splitReaders({ a })
    h.assertTrue(p1.keyboard and p1.pad == nil, "the keyboard drives P1")
    h.assertTrue(not p2.keyboard and p2.pad == a, "the pad drives P2")
    p1, p2 = input.splitReaders({ a, b })
    h.assertTrue(p1.keyboard and p1.pad == a, "P1 has the keyboard and the first pad")
    h.assertTrue(not p2.keyboard and p2.pad == b, "P2 the second")
    h.assertEq(input.splitReaders({}), nil, "no pad, no second driver")
  end)
end)

h.describe("each pad's own motors", function()
  local function car(model)
    return { model = model, getSpeed = function() return 20 end }
  end

  h.it("a crash is felt in the pad of the driver who had it", function()
    local a, b = fakePad(1), fakePad(2)
    settings.vibration = true
    rumble.assign(1, a)
    rumble.assign(2, b)
    rumble.stop()
    local model = dynamics.new(garage[1], "arcade")
    rumble.crash(0.8, 2)
    rumble.update(1 / 60, car(model), 1)
    rumble.update(1 / 60, car(model), 2)
    h.assertEq(#a.calls, 0, "P1 felt nothing")
    h.assertTrue(#b.calls >= 1 and b.calls[1][1] > 0.8, "P2's heavy motor")
    rumble.stop()
    rumble.assign(1, nil)
    rumble.assign(2, nil)
  end)

  h.it("a keyboard driver doesn't borrow the other driver's pad", function()
    local pad = fakePad(1)
    local before = input.gamepad
    input.gamepad = pad
    settings.vibration = true
    rumble.assign(1, false)
    rumble.stop()
    rumble.crash(1, 1)
    rumble.update(1 / 60, car(dynamics.new(garage[1], "arcade")), 1)
    h.assertEq(#pad.calls, 0, "the last pad used is P2's, and stays quiet for P1")
    rumble.assign(1, nil)
    rumble.stop()
    input.gamepad = before
  end)
end)
