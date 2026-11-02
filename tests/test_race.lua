local h = require("tests/harness")
local Race = require("src/sim/race")
local AI = require("src/ai_controller")
local Track = require("src/sim/track")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")
local config = require("src/config")
local touch = require("src/touch")
local input = require("src/input")
local settings = require("src/settings")
local hud = require("src/hud")

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

-- Puts a bot's decisions through the real on-screen stick: its steering becomes
-- a thumb position, its braking a pull down, and auto gas does the rest.
local function thumbOn(bot)
  local thumb = {}
  local radius = touch.layout(1280, 720).radius
  local unCurve = function(steer)
    local curved = math.abs(steer) ^ (1 / 1.6) * 0.92 + 0.08
    return steer == 0 and 0 or curved * (steer > 0 and 1 or -1)
  end
  function thumb.update(_, car, race, dt)
    bot:update(car, race, dt)
    local want = car.input
    local pull = want.brake > 0.05 and 0.3 + want.brake * 0.7 or 0
    touch.moved(1, 200 + unCurve(want.steer) * radius, 500 + pull * radius)
    input.applyTo(want, false)
    touch.applyTo(want)
  end
  return thumb
end

-- Drive the player with a bot and report how the laps went.
local function botLaps(entry, spec, laps, opts)
  opts = opts or {}
  local track = Track.new(entry.def)
  local race = Race.new({ mode = "race", track = track, laps = laps, opponents = 0,
    spec = spec, assist = opts.assist or "arcade", seed = 7, startDelay = 0.5 })
  race.player.driver = AI.new(track, race.player, {
    skill = opts.skill or 1.0, digital = opts.digital, reaction = opts.reaction,
  })
  if opts.thumb then race.player.driver = opts.thumb(race.player.driver) end
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
  h.it("a car touching a barrier is marked for the sound of grinding, one on the road isn't", function()
    local track = Track.new(catalog.find("lusail").def)
    local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 0, spec = garage[3],
      seed = 7, startDelay = 0 })
    local car = race.player
    run(race, 0.2)
    h.assertTrue(not car.scraped, "nothing to touch on the grid")
    local post = track.barrierL[40]
    car:teleport(post.x, post.y, 0)
    run(race, 0.1)
    h.assertTrue(car.scraped, "too gentle to be an impact, but it's touching")
    race:destroy()
  end)

  for _, entry in ipairs(catalog.builtin()) do
    for _, assist in ipairs({ "arcade", "full" }) do
      h.it("the AI laps " .. entry.name .. " in every car on " .. assist, function()
        for _, spec in ipairs(garage) do
          local r = botLaps(entry, spec, 2, { assist = assist, skill = 0.98 })
          print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d",
            entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns))
          h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
          h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
          h.assertTrue(r.offSeconds < 3, spec.name .. " spent too long off the road")
        end
      end)
    end

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

    h.it("a thumb on the stick can lap " .. entry.name .. " on auto gas", function()
      input.clear()
      touch.reset()
      settings.touch, settings.autoGas = "on", true
      touch.pressed(1, 200, 500, 1280, 720)
      for _, spec in ipairs(garage) do
        local r = botLaps(entry, spec, 2, { thumb = thumbOn, reaction = 0.08, skill = 0.9 })
        print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d",
          entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns))
        h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
        h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
        h.assertTrue(r.offSeconds < r.time * 0.2,
          string.format("%s off the road for %.0f of %.0f s", spec.name, r.offSeconds, r.time))
      end
      touch.reset()
      settings.touch = "auto"
    end)

    h.it("a manual car shifts for itself after the flag on " .. entry.name, function()
      local track = Track.new(entry.def)
      local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 0,
        spec = garage[3], seed = 7, startDelay = 0.5, manualGearbox = true })
      h.assertEq(race.player.input.manual, true)
      race.phase = "racing"
      race.player.lapsDone = race.laps - 1
      race.player.distance = track.length * race.laps + 1
      race:step(DT)
      h.assertTrue(race.player.finished, "over the line")
      h.assertEq(race.player.input.manual, false)
      race:destroy()
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

  h.it("opponents race on the same grip as the player", function()
    local track = Track.new(catalog.builtin()[1].def)
    local function gripOf(assist)
      local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 1, seed = 3, assist = assist })
      local player, rival = race.player.model.assist.grip, race.cars[2].model.assist.grip
      race:destroy()
      return player, rival
    end
    for _, assist in ipairs({ "arcade", "sport", "sim" }) do
      local player, rival = gripOf(assist)
      h.assertEq(rival, player, assist .. " grid grip")
    end
  end)

  h.it("every mode starts on a full tank that can't fire until lights out", function()
    for _, mode in ipairs({ "race", "trial", "freestyle" }) do
      local entry = catalog.builtin()[1]
      local race = Race.new({ mode = mode, track = Track.new(entry.def), laps = 1, opponents = 2,
        spec = garage[3], seed = 7, startDelay = 1 })
      local car = race.player
      local held = true
      car.driver = {
        nitroButton = function() return held end,
        update = function(_, c) c.input.boost = held end,
      }
      for _, each in ipairs(race.cars) do h.assertEq(each.model.boostTank, each.spec.boostTime, each.name) end
      while race.phase == "countdown" do
        race:step(DT)
        h.assertEq(car.model.boostState, "ready", "no firing at the lights")
      end
      for _ = 1, 0.2 / DT do race:step(DT) end
      h.assertEq(car.model.boostState, "ready", "held through the lights, it stays off")
      held = false
      race:step(DT)
      race:step(DT)
      held = true
      race:step(DT)
      race:step(DT)
      h.assertEq(car.model.boostState, "active", "a fresh press after the start lights it")
      race:destroy()
    end
  end)

  local function onlineRace()
    local entry = catalog.builtin()[1]
    local peerState = { x = 0, y = 0, vx = 0, vy = 0, a = 0, steer = 0, rpm = 1000, throttle = 0, brake = 0, gear = 1 }
    local track = Track.new(entry.def)
    local race = Race.new({ mode = "race", track = track, laps = 1, spec = garage[3], seed = 7, startDelay = 0.1,
      online = { slot = 1, peers = { { slot = 2, spec = garage[2], color = { 1, 0, 0 }, state = function() return peerState, 0 end } } } })
    peerState.x, peerState.y, peerState.a = race.cars[2].curX, race.cars[2].curY, race.cars[2].curA
    while race.phase == "countdown" do race:step(DT) end
    return race, track
  end

  h.it("a rival who leaves after the flag isn't reported as quitting", function()
    local race, track = onlineRace()
    local peer = race.cars[2]
    peer.finished, peer.finishTime = true, 60
    h.assertEq(race:peerLeft(peer), false)
    h.assertTrue(not peer.remote, "their car is ours to drive now")
    local x, y = peer.curX, peer.curY
    for _ = 1, 3 / DT do race:step(DT) end
    checkFinite(race)
    h.assertTrue(math.abs(peer.curX - x) + math.abs(peer.curY - y) > 5 * M, "it drives on, clear of the line")

    race.player.lapsDone = race.laps - 1
    race.player.distance = track.length * race.laps + 1
    race:step(DT)
    h.assertEq(race.phase, "finished", "nobody left to wait for")
    race:destroy()
  end)

  h.it("a rival who quits mid-race isn't waited for", function()
    local race, track = onlineRace()
    local peer = race.cars[2]
    h.assertEq(race:peerLeft(peer), true)
    h.assertEq(#race.cars, 1, "their car has left the road")
    h.assertEq(race.order[2], peer, "but they're still in the standings")
    race.player.lapsDone = race.laps - 1
    race.player.distance = track.length * race.laps + 1
    race:step(DT)
    h.assertTrue(race.player.finished, "over the line")
    h.assertEq(race.phase, "finished", "no grace period for someone who's gone")
    h.assertTrue(not peer.finished, "and they did not finish")
    h.assertEq(peer.place, 2)
    race:destroy()
  end)

  h.it("a driver who quit ranks behind everyone still in the race", function()
    local race = onlineRace()
    local peer = race.cars[2]
    peer.distance = race.player.distance + 5000
    race:peerLeft(peer)
    race:step(DT)
    h.assertEq(race.player.place, 1)
    race:destroy()
  end)

  -- A race whose rival's state the test sets directly, as packets would.
  local function sharedRace(peerCount)
    local entry = catalog.builtin()[1]
    local states, peers = {}, {}
    for i = 1, peerCount do
      local slot = i + 1
      local state = { x = 0, y = 0, vx = 0, vy = 0, a = 0, steer = 0, rpm = 1000, throttle = 0, brake = 0, gear = 1 }
      states[slot] = state
      peers[i] = { slot = slot, spec = garage[slot], color = { 1, 0, 0 }, state = function() return state, 0 end }
    end
    local clock = { left = 0 }
    local race = Race.new({ mode = "race", track = Track.new(entry.def), laps = 1, spec = garage[3], seed = 7,
      online = { slot = 1, peers = peers, startIn = function() return clock.left end } })
    for i, car in ipairs(race.cars) do
      if i > 1 then
        local state = states[car.slot]
        state.x, state.y, state.a = car.curX, car.curY, car.curA
      end
    end
    return race, states, clock
  end

  h.it("the rival's own game decides its laps and finish", function()
    local race, states, clock = sharedRace(1)
    clock.left = -1
    race:step(DT)
    local peer = race.cars[2]
    states[2].distance = race.track.length * 0.5
    race:step(DT)
    h.assertEq(peer.distance, race.track.length * 0.5, "progress comes from the packet")
    h.assertTrue(not peer.finished, "not finished by being near the line")
    states[2].distance = race.track.length + 1
    states[2].finish = 61.5
    race:step(DT)
    h.assertTrue(peer.finished, "the packet says it finished")
    h.assertEq(peer.finishTime, 61.5, "at the time it says")
    race:destroy()
  end)

  h.it("both players get the same result, whoever crosses first on screen", function()
    local race, states, clock = sharedRace(1)
    clock.left = -1
    race:step(DT)
    race.time = 60
    race.player.lapsDone = 0
    race.player.distance = race.track.length + 1
    race:step(DT)
    h.assertEq(race.player.place, 1, "ahead until the rival's time arrives")
    states[2].finish = 59.9
    race:step(DT)
    h.assertEq(race.player.place, 2, "their earlier time takes the win")
    h.assertEq(race.phase, "finished", "nobody left racing")
    race:destroy()
  end)

  h.it("the race ends for everyone a fixed time after the first finish", function()
    local race, states, clock = sharedRace(2)
    clock.left = -1
    race:step(DT)
    race.time = 60
    states[2].finish = 60
    race:step(DT)
    h.assertEq(race.flagFell, 60, "the flag is out")
    h.assertEq(race.phase, "racing", "and the rest have time")
    race.time = 60 + race.FINISH_GRACE - 0.5
    race:step(DT)
    h.assertEq(race.phase, "racing", "still time left")
    race.time = 60 + race.FINISH_GRACE
    race:step(DT)
    h.assertEq(race.phase, "finished", "time is up")
    h.assertTrue(race.player.timedOut, "the player didn't finish")
    h.assertTrue(not race.player.finished, "and has no time")
    race:destroy()
  end)

  h.it("cars wait on the grid until the start is called, then follow the clock", function()
    local race, _, clock = sharedRace(1)
    clock.left = nil
    for _ = 1, 240 do race:step(DT) end
    h.assertEq(race.phase, "countdown", "held")
    h.assertTrue(race.holding, "and saying so")
    h.assertEq(hud.lightsOn(race), 0, "with the lights dark")
    clock.left = race.startDelay + 1
    race:step(DT)
    h.assertEq(hud.lightsOn(race), 0, "still dark before the lights begin")
    clock.left = race.startDelay / 2
    race:step(DT)
    h.assertEq(hud.lightsOn(race), 3, "a late game joins part way through the lights")
    clock.left = 0
    race:step(DT)
    h.assertEq(race.phase, "racing", "lights out on the shared clock")
    race:destroy()
  end)

  h.it("a slow frame doesn't flatter a phone's race time", function()
    local race, _, clock = sharedRace(1)
    clock.left = -1
    race:step(DT)
    clock.left = -10
    race:step(DT)
    h.assertNear(race.time, DT, 0.001, "a step only adds a step")
    race:syncClock()
    h.assertEq(race.time, 10, "and the real clock catches it up")
    clock.left = -5
    race:syncClock()
    h.assertEq(race.time, 10, "it never runs back")
    race:destroy()
  end)

  h.it("seats with gaps still make a tight grid", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 1, spec = garage[3], seed = 7,
      online = { slot = 2, peers = {
        { slot = 1, spec = garage[1], state = function() end },
        { slot = 4, spec = garage[2], state = function() end },
      } } })
    h.assertEq(#race.cars, 3)
    local function gridOf(n) local x, y = track:gridSlot(n) return x, y end
    local x2 = gridOf(2)
    local x3 = gridOf(3)
    h.assertNear(race.player.curX, x2, 0.01, "seat 2 is second on the grid")
    h.assertNear(race.cars[3].curX, x3, 0.01, "seat 4 is third, not fourth")
    h.assertEq(race.cars[3].name, "P4")
    race:destroy()
  end)

  h.it("online races ignore the local handling tier", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 1, seed = 3, assist = "sim",
      online = { slot = 1, peers = { { slot = 2, spec = garage[2], state = function() end } } } })
    h.assertEq(race.handling, "arcade")
    h.assertEq(race.player.model.assist.grip, require("src/sim/dynamics").ASSISTS.arcade.grip)
    race:destroy()
  end)

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

  h.it("the player and the AI both rev at the lights", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 1, seed = 3, startDelay = 2 })
    local car, rival = race.player, race.cars[2]
    car.driver = { revs = function() return 1 end, update = function() end }
    local x, y = car.body:getPosition()
    run(race, 1.5)
    h.assertTrue(car.model.rpm > car.spec.redline * 0.85, "revving: " .. car.model.rpm)
    h.assertTrue(rival.model.rpm > rival.spec.redline * 0.4, "rival revs: " .. rival.model.rpm)
    local nx, ny = car.body:getPosition()
    h.assertTrue(math.abs(nx - x) + math.abs(ny - y) < 2, "jumped the start")
    run(race, 1)
    h.assertEq(race.phase, "racing")
    h.assertEq(car.input.rev, nil, "revving stops at the green")
    h.assertTrue(car.model.launch > 0, "and the launch is judged")
    race:destroy()
  end)

  h.it("better AI drivers launch better, and none of them is a machine", function()
    local track = Track.new(catalog.builtin()[1].def)
    local mean, perfects = {}, {}
    for _, difficulty in ipairs({ "rookie", "pro", "ace" }) do
      local total, count, perfect = 0, 0, 0
      for seed = 1, 12 do
        local race = Race.new({
          mode = "race", track = track, laps = 1, opponents = 5, seed = seed, difficulty = difficulty,
          startDelay = 2.5 + seed * 0.13,
        })
        run(race, 3 + seed * 0.13)
        for i = 2, #race.cars do
          local launch = race.cars[i].model.launch
          total, count = total + launch, count + 1
          if launch >= 0.85 then perfect = perfect + 1 end
        end
        race:destroy()
      end
      mean[difficulty], perfects[difficulty] = total / count, perfect / count
      print(string.format("        %-7s mean launch %.2f, %d of %d perfect", difficulty, total / count, perfect, count))
    end
    h.assertTrue(mean.ace > mean.pro and mean.pro > mean.rookie, "launches follow skill")
    h.assertTrue(mean.rookie > 0.3, "rookies still get going")
    h.assertTrue(perfects.ace < 0.9, "even aces fluff some: " .. perfects.ace)
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
    race:step(DT)
    h.assertTrue(race:standings() == order and race.order == order, "no new table each step")
    h.assertEq(#order, #race.cars, "everyone listed")
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
