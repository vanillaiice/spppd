local h = require("tests/harness")
local Race = require("src/sim/race")
local AI = require("src/ai_controller")
local Track = require("src/sim/track")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")
local config = require("src/config")

local DT = config.PHYSICS_DT
local M = config.METER

local function run(race, seconds, stop)
  local steps = math.floor(seconds / DT)
  for i = 1, steps do
    race:step(DT)
    if stop and stop(race) then return i * DT end
  end
  return seconds
end

local function checkFinite(race)
  for _, car in ipairs(race.cars) do
    local x, y = car.body:getPosition()
    assert(x == x and y == y and math.abs(x) < 1e6, "car left the universe: " .. tostring(x))
  end
end

-- Drive the player with a bot and report how the laps went.
local function botLaps(entry, spec, laps, opts)
  opts = opts or {}
  local track = Track.new(entry.def)
  local race = Race.new({ mode = "race", track = track, laps = laps, opponents = 0,
    spec = spec, assist = opts.assist or "sport", seed = 7, startDelay = 0.5 })
  race.player.driver = AI.new(track, race.player, {
    skill = opts.skill or 1.0, digital = opts.digital, reaction = opts.reaction,
  })
  local respawns = 0
  local realRespawn = race.respawn
  race.respawn = function(self, car) respawns = respawns + 1 return realRespawn(self, car) end
  local offSteps = 0
  run(race, 600, function(r)
    if r.player.offTrack then offSteps = offSteps + 1 end
    return r.player.finished
  end)
  local car = race.player
  local result = {
    finished = car.finished, time = car.finishTime, best = car.bestLap,
    last = car.lastLap, respawns = respawns, offSeconds = offSteps * DT, laps = car.lapsDone,
  }
  race:destroy()
  return result
end

h.describe("race", function()
  for _, entry in ipairs(catalog.builtin()) do
    h.it("the AI laps " .. entry.name .. " in every car", function()
      for _, spec in ipairs(garage) do
        local r = botLaps(entry, spec, 2, { assist = "full", skill = 0.98 })
        print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d",
          entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns))
        h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
        h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
        h.assertTrue(r.offSeconds < 3, spec.name .. " spent too long off the road")
      end
    end)

    h.it("a keyboard player can lap " .. entry.name .. " on default assists", function()
      for _, spec in ipairs(garage) do
        local r = botLaps(entry, spec, 2, { digital = true, reaction = 0.05, skill = 0.9 })
        print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d",
          entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns))
        h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
        h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
        -- A crude bang-bang bot, so some running wide is expected. The rule
        -- is that it's occasional: under 20% of the race on the grass.
        h.assertTrue(r.offSeconds < r.time * 0.2,
          string.format("%s off the road for %.0f of %.0f s", spec.name, r.offSeconds, r.time))
      end
    end)

    h.it("a full grid races " .. entry.name .. " to the flag", function()
      local track = Track.new(entry.def)
      local race = Race.new({ mode = "race", track = track, laps = 2, opponents = 5,
        spec = garage[3], difficulty = "pro", seed = 11, startDelay = 0.5 })
      race.player.driver = AI.new(track, race.player, { skill = 0.93 })
      local stepsWithImpact = 0
      run(race, 400, function(r)
        checkFinite(r)
        local events = require("src/world").drainEvents()
        if #events > 0 then stepsWithImpact = stepsWithImpact + 1 end
        return r.phase == "finished"
      end)
      h.assertEq(race.phase, "finished", "race never ended")
      local finishers = 0
      for _, car in ipairs(race.cars) do
        if car.finished then finishers = finishers + 1 end
        h.assertTrue(car.lapsDone >= 1, car.name .. " never finished a lap")
      end
      local order = race:standings()
      local names = {}
      for i, car in ipairs(order) do names[i] = car.name .. string.format("(%.1f)", car.finishTime or -1) end
      print("        " .. table.concat(names, " "))
      h.assertTrue(finishers >= 5, "only " .. finishers .. " cars finished")
      race:destroy()
    end)
  end

  h.it("cars wait for the lights", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 3, seed = 3, startDelay = 2 })
    local x, y = race.player.body:getPosition()
    race.player.input.throttle = 1
    run(race, 1.5)
    local nx, ny = race.player.body:getPosition()
    h.assertTrue(math.abs(nx - x) + math.abs(ny - y) < 2, "jumped the start")
    h.assertEq(race.phase, "countdown")
    run(race, 1)
    h.assertEq(race.phase, "racing")
    race:destroy()
  end)

  h.it("driving backwards over the line does not count as a lap", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 3, opponents = 0, seed = 3, startDelay = 0.1 })
    run(race, 0.2)
    local car = race.player
    local s = track.samples[track.count - 40]
    for i = 40, -40, -1 do
      local p = track.samples[(track.count - i) % track.count + 1]
      car:teleport(p.x, p.y, 0)
      race:step(DT)
    end
    h.assertEq(car.lapsDone, 0, "forwards through the line once is not a finished lap")
    for i = -40, 40 do
      local p = track.samples[(track.count - i) % track.count + 1]
      car:teleport(p.x, p.y, 0)
      race:step(DT)
    end
    h.assertEq(car.lapsDone, 0, "reversing is not a lap")
    h.assertTrue(s ~= nil)
    race:destroy()
  end)

  h.it("a real lap counts, and cutting across the infield does not", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 5, opponents = 0, seed = 3, startDelay = 0.1 })
    run(race, 0.2)
    local car = race.player
    local n = track.count
    for i = 1, n + 2 do
      local p = track.samples[i % n + 1]
      car:teleport(p.x, p.y, 0)
      race:step(DT)
    end
    h.assertEq(car.lapsDone, 1, "one full lap")
    -- now teleport three quarters of the way round in one go
    local far = track.samples[math.floor(n * 0.8)]
    car:teleport(far.x, far.y, 0)
    race:step(DT)
    for i = math.floor(n * 0.8), n + 5 do
      local p = track.samples[i % n + 1]
      car:teleport(p.x, p.y, 0)
      race:step(DT)
    end
    h.assertEq(car.lapsDone, 1, "the cut must not earn a lap")
    race:destroy()
  end)

  h.it("standings put the leader first", function()
    local track = Track.new(catalog.builtin()[2].def)
    local race = Race.new({ mode = "race", track = track, laps = 2, opponents = 2, seed = 5, startDelay = 0.1 })
    run(race, 8)
    local order = race:standings()
    h.assertEq(order[1].place, 1)
    h.assertTrue(order[1].distance >= order[2].distance, "ordering")
    race:destroy()
  end)

  h.it("the wrong way warning comes on and goes off", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 2, opponents = 0, seed = 3, startDelay = 0.1 })
    run(race, 0.2)
    local car = race.player
    local s = track.samples[60]
    car:teleport(s.x, s.y, math.atan2(-s.ty, -s.tx))
    car.trackIndex = 60
    car.driver = { update = function(_, c) c.input.throttle = 1 end }
    run(race, 4)
    h.assertTrue(car.wrongWay, "should warn")
    car.driver = { update = function(_, c) c.input.throttle = 0 c.input.brake = 1 end }
    run(race, 8)
    h.assertTrue(not car.wrongWay, "should clear once stopped")
    race:destroy()
  end)

  h.it("respawn puts the car back on the road, stationary", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 2, opponents = 0, seed = 3, startDelay = 0.1 })
    run(race, 0.2)
    local car = race.player
    local s = track.samples[100]
    car:teleport(s.rx + s.nx * 60, s.ry + s.ny * 60, 1)
    car.trackIndex = 100
    race:step(DT)
    race:respawn(car)
    race:step(DT)
    local _, _, _, off = track:locate(car.body:getX(), car.body:getY(), car.trackIndex)
    h.assertEq(off, 0, "should be on the road")
    h.assertTrue(car:getSpeed() < 1, "should be stopped")
    race:destroy()
  end)

  h.it("a barrier stops a car even at very high speed", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 2, opponents = 0, seed = 3, startDelay = 0.1 })
    run(race, 0.2)
    local car = race.player
    local s = track.samples[20]
    for _ = 1, 4 do
      car:teleport(s.x, s.y, math.atan2(s.ny, s.nx))
      car.trackIndex = s.index
      car.body:setLinearVelocity(s.nx * 90 * M, s.ny * 90 * M)
      run(race, 1.5)
      local _, _, lateral = track:locate(car.body:getX(), car.body:getY(), car.trackIndex)
      local limit = s.w / 2 + s.barrierr + 8 * M
      h.assertTrue(math.abs(lateral) < limit, string.format("punched through: %.0f > %.0f", lateral, limit))
    end
    race:destroy()
  end)

  h.it("freestyle has no track and runs forever", function()
    local race = Race.new({ mode = "freestyle", spec = garage[3], seed = 3, startDelay = 0 })
    race.player.driver = { update = function(_, c) c.input.throttle = 1 c.input.steer = 0.6 end }
    run(race, 20)
    checkFinite(race)
    h.assertTrue(race.player:getSpeed() > 3, "should be moving")
    race:destroy()
  end)
end)
