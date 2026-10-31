local h = require("tests/harness")
local Race = require("src/sim/race")
local Car = require("src/entities/car")
local dynamics = require("src/sim/dynamics")
local slipstream = require("src/sim/slipstream")
local garage = require("src/entities/garage")
local config = require("src/config")

local DT = config.PHYSICS_DT
local M = config.METER
local SPEED = 50

-- An open-air race heading up the screen, with a rival `gap` metres ahead of
-- the player and `side` metres across. Both are in top-but-one gear at speed.
local function duel(gap, side, opts)
  opts = opts or {}
  local spec = opts.spec or garage[1]
  local race = Race.new({ mode = "freestyle", spec = spec, assist = opts.assist, startDelay = 0 })
  local player = race.player
  local rival = Car.new(spec, (side or 0) * M, -gap * M, -math.pi / 2, { assist = opts.assist })
  race.cars[2] = rival
  for _, car in ipairs(race.cars) do
    race:initProgress(car)
    car.body:setLinearVelocity(0, -(opts.speed or SPEED) * M)
    car.model.gear = math.max(1, #spec.gears - 1)
    car.input.throttle = 1
  end
  rival.body:setLinearVelocity((opts.rivalSide or 0) * M, -(opts.rivalSpeed or opts.speed or SPEED) * M)
  return race, player, rival
end

local function stepFor(race, seconds)
  for _ = 1, seconds / DT do
    race:step(DT)
    for _, car in ipairs(race.cars) do car.input.throttle = 1 end
  end
end

local function wakeAt(gap, side, opts)
  local race, player, rival = duel(gap, side, opts)
  local wake = slipstream.wake(player, rival)
  race:destroy()
  return wake
end

-- Gap in metres after `seconds` flat out from a `gap`-metre start.
local function gapAfter(gap, side, seconds, opts)
  local race, player, rival = duel(gap, side, opts)
  stepFor(race, seconds)
  local result = (player.body:getY() - rival.body:getY()) / M
  race:destroy()
  return result
end

-- Forward force on a car at speed with the given slipstream.
local function pull(assist, amount, inputs)
  local spec = garage[1]
  local c = dynamics.new(spec, assist)
  c.slipstream = amount
  c.gear = #spec.gears - 1
  return (dynamics.step(c, inputs, SPEED, 0, 0, DT))
end

h.describe("slipstream", function()
  h.it("is strongest close behind and gone at range", function()
    h.assertEq(wakeAt(10, 0), 1, "right behind")
    local far = wakeAt(26, 0)
    h.assertTrue(far > 0 and far < 1, "fades towards the end, got " .. far)
    h.assertEq(wakeAt(40, 0), 0, "out of range")
  end)

  h.it("needs the car to be in line", function()
    h.assertEq(wakeAt(10, 5), 0, "off to one side")
    h.assertEq(wakeAt(10, 1), 1, "there is some room either side")
    h.assertTrue(wakeAt(10, 1.5) < 0.7, "weaker towards the edge")
  end)

  h.it("only works behind the other car", function()
    h.assertEq(wakeAt(-10, 0), 0, "the car in front gets nothing")
    h.assertEq(wakeAt(1, 0), 0, "too close to be a wake")
  end)

  h.it("needs speed from both cars", function()
    h.assertEq(wakeAt(10, 0, { speed = 10 }), 0, "both slow")
    h.assertEq(wakeAt(10, 0, { rivalSpeed = 10 }), 0, "a slow car leaves no wake")
  end)

  h.it("ignores a car going the other way", function()
    h.assertEq(wakeAt(10, 0, { rivalSpeed = -SPEED }), 0, "oncoming")
  end)

  h.it("follows the way the other car travels, not where it points", function()
    -- Sliding at 45 degrees: its wake trails back along the slide.
    local race, player, rival = duel(10, 10, { rivalSide = SPEED, rivalSpeed = SPEED })
    player.body:setLinearVelocity(SPEED * M, -SPEED * M)
    h.assertTrue(slipstream.wake(player, rival) > 0.9, "in line with the slide")
    race:destroy()
  end)

  h.it("removes drag on every tier and only tows on arcade", function()
    local flat = { throttle = 1, brake = 0, steer = 0 }
    local arcade = pull("arcade", 1, flat) - pull("arcade", 0, flat)
    local sport = pull("sport", 1, flat) - pull("sport", 0, flat)
    h.assertTrue(sport > 0, "drag falls in a slipstream")
    h.assertTrue(arcade > sport + 1000, "arcade adds a tow on top")
  end)

  h.it("does not push a car that is braking", function()
    local spec = garage[1]
    local braking = { throttle = 0, brake = 1, steer = 0 }
    local drag = 0.5 * 1.2 * spec.dragArea * SPEED * SPEED * 0.3
    h.assertNear(pull("arcade", 1, braking) - pull("arcade", 0, braking), drag, 1, "drag only")
  end)

  h.it("leaves the car alone when there is no wake", function()
    local race = Race.new({ mode = "freestyle", spec = garage[1], startDelay = 0 })
    race.player.body:setLinearVelocity(0, -SPEED * M)
    for _ = 1, 60 do race:step(DT) end
    h.assertEq(race.player.model.slipstream, 0, "alone on the road")
    race:destroy()
  end)

  h.it("reels in the car ahead in every car", function()
    for _, spec in ipairs(garage) do
      local towed = gapAfter(24, 0, 4, { spec = spec })
      local clear = gapAfter(24, 12, 4, { spec = spec })
      print(string.format("        %-15s gap after 4 s: %.1f m towed, %.1f m clear", spec.name, towed, clear))
      h.assertTrue(clear > 23, spec.name .. " should hold station without a wake")
      h.assertBetween(clear - towed, 2.5, 6, spec.name .. " metres gained in 4 s")
    end
  end)

  h.it("takes a couple of seconds of following to build", function()
    local race, player = duel(16, 0)
    stepFor(race, 0.5)
    h.assertBetween(player.model.slipstream, 0.2, 0.3, "half a second in")
    stepFor(race, 0.5)
    h.assertBetween(player.model.slipstream, 0.45, 0.55, "one second in")
    race:destroy()
  end)

  h.it("keeps pulling for a moment after leaving the wake", function()
    local race, player, rival = duel(16, 0)
    stepFor(race, 2.2)
    h.assertEq(player.model.slipstream, 1, "fully towed")
    local x, y = player.body:getPosition()
    player.body:setPosition(x + 8 * M, y)
    stepFor(race, 0.5)
    h.assertBetween(player.model.slipstream, 0.4, 0.7, "fading")
    stepFor(race, 1)
    h.assertEq(player.model.slipstream, 0, "gone")
    h.assertEq(rival.model.slipstream, 0, "the leader never had any")
    race:destroy()
  end)

  h.it("is cleared by a respawn", function()
    local race, player = duel(16, 0)
    stepFor(race, 2.2)
    h.assertTrue(player.model.slipstream > 0.9, "towed first")
    player:teleport(0, 0, 0)
    h.assertEq(player.model.slipstream, 0, "after a teleport")
    race:destroy()
  end)
end)

h.describe("slipstream traffic", function()
  local Track = require("src/sim/track")
  local AI = require("src/ai_controller")
  local catalog = require("src/tracks/catalog")

  for _, entry in ipairs(catalog.builtin()) do
    h.it("a full grid races cleanly on " .. entry.name, function()
      local race = Race.new({ mode = "race", track = Track.new(entry.def), laps = 3, opponents = 5,
        spec = garage[3], difficulty = "pro", seed = 11, startDelay = 0.5 })
      race.player.driver = AI.new(race.track, race.player, { skill = 0.92 })
      local respawns, towed = 0, 0
      local realRespawn = race.respawn
      race.respawn = function(self, car) respawns = respawns + 1 return realRespawn(self, car) end
      for _ = 1, 400 / DT do
        race:step(DT)
        for _, car in ipairs(race.cars) do
          if car.model.slipstream > 0.5 then towed = towed + DT end
        end
        if race.finishGrace then break end
      end
      print(string.format("        %-10s towed for %.0f car-seconds, %d respawns", entry.name, towed, respawns))
      h.assertTrue(race.player.finished, "the race never finished")
      h.assertTrue(towed > 0, "nobody ever got a tow")
      h.assertTrue(respawns <= 1, "traffic piled up: " .. respawns .. " respawns")
      race:destroy()
    end)
  end
end)
