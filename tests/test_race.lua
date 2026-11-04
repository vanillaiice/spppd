local h = require("tests/harness")
local Race = require("src/sim/race")
local AI = require("src/ai_controller")
local RemoteDriver = require("src/sim/remote_driver")
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

-- Puts a keyboard-style bot through the on-screen buttons: one thumb on the
-- arrows, rocking or lifting, and the other on brake.
local function buttonsOn(bot)
  local thumb = {}
  local layout = touch.layout(1280, 720)
  local function find(action)
    for _, b in ipairs(layout.buttons) do
      if b.action == action then return b end
    end
  end
  local left, right, brake = find("steerLeft"), find("steerRight"), find("brake")
  local side, braking = 0, false
  function thumb.update(_, car, race, dt)
    bot:update(car, race, dt)
    local want = car.input
    local steer = want.steer > 0 and 1 or (want.steer < 0 and -1 or 0)
    if steer ~= side then
      if side ~= 0 and steer ~= 0 then
        local to = steer < 0 and left or right
        touch.moved(1, to.x, to.y)
      elseif steer == 0 then
        touch.released(1)
      else
        local to = steer < 0 and left or right
        touch.pressed(1, to.x, to.y, 1280, 720)
      end
      side = steer
    end
    if (want.brake > 0) ~= braking then
      braking = want.brake > 0
      if braking then touch.pressed(2, brake.x, brake.y, 1280, 720) else touch.released(2) end
    end
    input.applyTo(want, false)
    touch.applyTo(want)
  end
  return thumb
end

-- Drive the player with a bot and report how the laps went.
local function botLaps(entry, spec, laps, opts)
  opts = opts or {}
  local track = Track.new(entry.def)
  local crashes = 0
  local race = Race.new({ mode = "race", track = track, laps = laps, opponents = 0,
    spec = spec, assist = opts.assist or "arcade", seed = 7, startDelay = 0.5,
    onCrash = function() crashes = crashes + 1 end })
  race.player.driver = AI.new(track, race.player, {
    skill = opts.skill or 1.0, digital = opts.digital, reaction = opts.reaction,
  })
  if opts.thumb then race.player.driver = opts.thumb(race.player.driver) end
  local respawns = 0
  local realRespawn = race.respawn
  race.respawn = function(self, car) respawns = respawns + 1 return realRespawn(self, car) end
  local offSteps = 0
  run(race, 600, function(r)
    -- Sat wrecked in the run-off isn't running wide.
    if r.player.offTrack and not r.player.wreck then offSteps = offSteps + 1 end
    return r.player.finished
  end)
  local car = race.player
  local result = {
    finished = car.finished, time = car.finishTime, best = car.bestLap,
    last = car.lastLap, respawns = respawns, crashes = crashes, offSeconds = offSteps * DT, laps = car.lapsDone,
  }
  race:destroy()
  return result
end

h.describe("race", function()
  h.it("a car touching a barrier is marked for the sound of grinding, one on the road isn't", function()
    local track = Track.new(catalog.find("mirage").def)
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
          print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d  crashes %d",
            entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns, r.crashes))
          h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
          h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
          h.assertTrue(r.offSeconds < 3, spec.name .. " spent too long off the road")
        end
      end)
    end

    h.it("a keyboard player can lap " .. entry.name .. " on default assists", function()
      for _, spec in ipairs(garage) do
        local r = botLaps(entry, spec, 2, { digital = true, reaction = 0.05, skill = 0.9 })
        print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d  crashes %d",
          entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns, r.crashes))
        h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
        h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
        -- A crude bang-bang bot, so some running wide is expected. The rule
        -- is that it's occasional: under a quarter of the race on the grass.
        h.assertTrue(r.offSeconds < r.time * 0.25,
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
        print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d  crashes %d",
          entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns, r.crashes))
        h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
        h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
        h.assertTrue(r.offSeconds < r.time * 0.2,
          string.format("%s off the road for %.0f of %.0f s", spec.name, r.offSeconds, r.time))
      end
      touch.reset()
      settings.touch = "auto"
    end)

    h.it("a thumb on the buttons can lap " .. entry.name .. " on auto gas", function()
      input.clear()
      touch.reset()
      settings.touch, settings.autoGas, settings.touchSteer = "on", true, "buttons"
      for _, spec in ipairs(garage) do
        local r = botLaps(entry, spec, 2, { thumb = buttonsOn, digital = true, reaction = 0.05, skill = 0.9 })
        print(string.format("        %-10s %-15s lap %.1fs  off %.1fs  respawns %d  crashes %d",
          entry.name, spec.name, r.last or -1, r.offSeconds, r.respawns, r.crashes))
        touch.reset()
        h.assertTrue(r.finished, spec.name .. " did not finish, laps " .. r.laps)
        h.assertEq(r.respawns, 0, spec.name .. " needed respawns")
        h.assertTrue(r.offSeconds < r.time * 0.25,
          string.format("%s off the road for %.0f of %.0f s", spec.name, r.offSeconds, r.time))
      end
      touch.reset()
      settings.touch, settings.touchSteer = "auto", "stick"
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
        boostButton = function() return held end,
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

  -- Aims a car at the right-hand fence of a straight, a little short of it.
  local function aimAtFence(race, car, degrees, speed)
    local s = race.track.samples[20]
    local r = math.rad(degrees)
    local dx = s.tx * math.cos(r) + s.nx * math.sin(r)
    local dy = s.ty * math.cos(r) + s.ny * math.sin(r)
    local reach = s.w / 2 + s.barrierr - 4 * M
    car:teleport(s.x + s.nx * reach - dx * 4 * M, s.y + s.ny * reach - dy * 4 * M, math.atan2(dy, dx))
    car.trackIndex = s.index
    car.body:setLinearVelocity(dx * speed * M, dy * speed * M)
    return dx, dy
  end

  local function fenceRace(spec, opts)
    opts = opts or {}
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "race", track = track, laps = 2, opponents = opts.opponents or 0, seed = 3,
      startDelay = 0.1, spec = spec, onCrash = opts.onCrash, onRecover = opts.onRecover })
    race.player.driver = { update = function(_, c) c.input.throttle = 1 end }
    run(race, 0.2)
    return race, race.player
  end

  h.it("hitting a fence hard wrecks the car and puts it back on the road", function()
    local crashes, recoveries = 0, 0
    local race, car = fenceRace(garage[3], {
      onCrash = function() crashes = crashes + 1 end,
      onRecover = function() recoveries = recoveries + 1 end,
    })
    aimAtFence(race, car, 60, 45)
    run(race, 0.5, function() return car.wreck end)
    h.assertTrue(car.wreck, "should be wrecked")
    h.assertEq(crashes, 1)
    run(race, 0.02)
    h.assertEq(car.input.throttle, 0, "the driver's pedal is cut off")
    h.assertEq(recoveries, 0, "not back yet")
    run(race, Race.WRECK_TIME + 0.1, function() return not car.wreck end)
    h.assertEq(recoveries, 1)
    h.assertEq(crashes, 1, "one hit is one crash")
    h.assertTrue(car:getSpeed() < 3, "starts again from a stop")
    h.assertTrue(car.ghostTimer > 0, "out of the way of the traffic")
    h.assertTrue(not car.lapClean, "a wreck spoils the lap")
    local _, _, _, off = race.track:locate(car.body:getX(), car.body:getY(), car.trackIndex)
    h.assertEq(off, 0, "should be on the road")
    run(race, 0.5)
    h.assertTrue(car.input.throttle > 0 and car.input.brake == 0, "the driver has it back")
    h.assertEq(car.model.reverse, false)
    race:destroy()
  end)

  h.it("a wreck gives back the road it slid along", function()
    local race, car = fenceRace(garage[3])
    aimAtFence(race, car, 25, 70)
    local index, distance
    run(race, 1, function()
      if car.wreck then
        index, distance = car.trackIndex, car.distance
        return true
      end
    end)
    h.assertTrue(index, "should be wrecked")
    run(race, Race.WRECK_TIME + 0.1, function() return not car.wreck end)
    h.assertEq(car.trackIndex, index)
    h.assertNear(car.distance, distance, 3 * config.SAMPLE_SPACING * M, "no road gained or lost")
    race:destroy()
  end)

  h.it("glancing off a fence at speed only bounces", function()
    local crashes = 0
    local race, car = fenceRace(garage[3], { onCrash = function() crashes = crashes + 1 end })
    aimAtFence(race, car, 8, 70)
    run(race, 1)
    h.assertTrue(car.scraped, "should have touched it")
    h.assertEq(crashes, 0)
    race:destroy()
  end)

  h.it("the same hit wrecks a light car and a heavy one alike", function()
    for _, id in ipairs({ "open_wheeler", "baja_beast" }) do
      for _, case in ipairs({ { 60, 45, true }, { 10, 45, false } }) do
        local race, car = fenceRace(garage.byId(id))
        aimAtFence(race, car, case[1], case[2])
        local wrecked = run(race, 1, function() return car.wreck end) < 1
        h.assertEq(wrecked, case[3], string.format("%s at %d degrees", id, case[1]))
        race:destroy()
      end
    end
  end)

  h.it("a wreck can't reverse or earn boost on the way to a stop", function()
    local race, car = fenceRace(garage[3])
    aimAtFence(race, car, 60, 45)
    run(race, 0.5, function() return car.wreck end)
    car.model.boostTank = 1
    car.model.beta = 1
    local slideFilled = false
    run(race, Race.WRECK_TIME - 0.02, function()
      slideFilled = slideFilled or car.model.boostFilling
      h.assertEq(car.model.reverse, false, "a held brake mustn't find reverse")
      return not car.wreck
    end)
    h.assertTrue(not slideFilled, "a spin isn't a drift")
    race:destroy()
  end)

  h.it("another car can't wreck you, even by shoving you into a fence", function()
    local crashes = 0
    local race, victim = fenceRace(garage[3], { opponents = 1, onCrash = function() crashes = crashes + 1 end })
    local rammer = race.cars[2]
    rammer.driver = nil
    victim.driver = nil
    victim.input.throttle = 0
    -- Parked against the fence, side on.
    local dx, dy = aimAtFence(race, victim, 90, 2)
    run(race, 1.2)
    local vx, vy = victim.body:getPosition()
    rammer:teleport(vx - dx * 8 * M, vy - dy * 8 * M, math.atan2(dy, dx))
    rammer.trackIndex = victim.trackIndex
    rammer.body:setLinearVelocity(dx * 60 * M, dy * 60 * M)
    run(race, 0.3)
    h.assertTrue(victim.fenceHit >= Race.CRASH_SPEED, "the fence should have hit it this hard")
    h.assertEq(victim.wreck, nil, "the fence didn't do this")
    h.assertEq(crashes, 0)
    race:destroy()
  end)

  h.it("a car past the flag doesn't crash, and one wrecked over the line is let go", function()
    local race, car = fenceRace(garage[3])
    car.finished, car.finishTime = true, 1
    aimAtFence(race, car, 60, 45)
    run(race, 0.5)
    h.assertEq(car.wreck, nil)
    race:destroy()

    race, car = fenceRace(garage[3])
    aimAtFence(race, car, 60, 45)
    run(race, 0.5, function() return car.wreck end)
    car.finished, car.finishTime = true, 1
    run(race, 0.05)
    h.assertEq(car.wreck, nil)
    h.assertEq(car.input.wrecked, false)
    race:destroy()
  end)

  h.it("a remote car's crash is left to its own game", function()
    local race, car = fenceRace(garage[3])
    car.remote = true
    aimAtFence(race, car, 90, 45)
    run(race, 0.5)
    h.assertEq(car.wreck, nil)
    race:destroy()
  end)

  h.it("a rival who's a ghost in their game can't be hit in this one", function()
    local race, car = fenceRace(garage[3], { opponents = 1 })
    local rival = race.cars[2]
    local state = { x = rival.curX, y = rival.curY, a = rival.curA, vx = 0, vy = 0, steer = 0, rpm = 900,
      throttle = 0, brake = 0, gear = 1, ghost = true }
    rival.remote = true
    rival.driver = RemoteDriver.new(function() return state, 0 end)
    race:step(DT)
    h.assertTrue(rival.ghostTimer > 0)
    state.ghost = false
    run(race, 0.5)
    h.assertTrue(rival.ghostTimer <= 0, "solid again once they are")
    race:destroy()
  end)

  -- The reason wrecks exist: flat out, using the fences to turn, mustn't pay.
  for _, name in ipairs({ "highlands", "boat", "harbour", "oasis" }) do
    h.it("driving at the fences loses to driving the road on " .. name, function()
      local times = {}
      for _, reckless in ipairs({ false, true }) do
        local track = Track.new(catalog.find(name).def)
        local race = Race.new({ mode = "race", track = track, laps = 2, opponents = 0, seed = 7,
          spec = garage.byId("cyber"), assist = "arcade", startDelay = 0.5 })
        local bot = AI.new(track, race.player, { skill = 1.0 })
        race.player.driver = reckless and { update = function(_, c, r, dt)
          bot:update(c, r, dt)
          c.input.brake, c.input.throttle = 0, 1
        end } or bot
        run(race, 400, function(r) return r.player.finished end)
        times[#times + 1] = race.player.finishTime or math.huge
        race:destroy()
      end
      print(string.format("        %-10s road %.1fs  fences %.1fs", name, times[1], times[2]))
      h.assertTrue(times[2] > times[1], "the fences were quicker")
    end)
  end

  h.it("freestyle has no track and runs forever", function()
    local race = Race.new({ mode = "freestyle", spec = garage[3], seed = 3, startDelay = 0 })
    race.player.driver = { update = function(_, c) c.input.throttle = 1 c.input.steer = 0.6 end }
    run(race, 20)
    checkFinite(race)
    h.assertTrue(race.player:getSpeed() > 3, "should be moving")
    race:destroy()
  end)

  local lot = require("src/sim/lot")
  local world = require("src/world")

  local function lotRace(opts)
    opts = opts or {}
    local race = Race.new({ mode = "freestyle", lot = true, spec = garage[3], seed = 3, startDelay = 0,
      onRecover = opts.onRecover })
    race.player.driver = { update = function(_, c) c.input.throttle = 1 c.input.steer = 0 end }
    run(race, 0.05)
    return race, race.player
  end

  -- Puts the car at x, y metres, going along dx, dy at speed m/s.
  local function launch(car, x, y, dx, dy, speed)
    car:teleport(x * M, y * M, math.atan2(dy, dx))
    car.body:setLinearVelocity(dx * speed * M, dy * speed * M)
  end

  h.it("the lot has its playground, and only when asked for", function()
    local race = lotRace()
    h.assertEq(#race.cones, #lot.layout().cones)
    h.assertTrue(#race.cones >= 20, "a slalom and gates")
    -- The wall, two container blocks and the donut's tyre stack.
    h.assertEq(#world.barriers, 4)
    race:destroy()
    local bare = Race.new({ mode = "freestyle", spec = garage[3], seed = 3, startDelay = 0 })
    h.assertEq(bare.cones, nil)
    h.assertEq(#world.barriers, 0)
    bare:destroy()
  end)

  h.it("cones get knocked flying but never wreck the car", function()
    local race, car = lotRace()
    local first = lot.layout().cones[1]
    launch(car, first.x / M, first.y / M + 25, 0, -1, 30)
    local wrecked = false
    run(race, 3, function() wrecked = wrecked or car.wreck ~= nil end)
    h.assertTrue(not wrecked, "a cone wrecked the car")
    local moved = 0
    for _, cone in ipairs(race.cones) do
      local x, y = cone.body:getPosition()
      if (x - cone.homeX) ^ 2 + (y - cone.homeY) ^ 2 > (0.5 * M) ^ 2 then moved = moved + 1 end
    end
    h.assertTrue(moved >= 3, "should have bowled cones over, moved " .. moved)
    checkFinite(race)
    race:destroy()
  end)

  h.it("a container on the lot wrecks the car, which goes back clear of it", function()
    local recoveries = 0
    local race, car = lotRace({ onRecover = function() recoveries = recoveries + 1 end })
    local block = lot.layout().blocks[2]
    local cx = (block.x + block.w / 2) / M
    launch(car, cx, block.y / M - 20, 0, 1, 30)
    run(race, 1.5, function() return car.wreck end)
    h.assertTrue(car.wreck, "should be wrecked")
    run(race, Race.WRECK_TIME + 0.1, function() return not car.wreck end)
    h.assertEq(recoveries, 1)
    h.assertTrue(car:getSpeed() < 3, "starts again from a stop")
    local x, y = car.body:getPosition()
    h.assertTrue(y < block.y - 1.5 * M, string.format("should be clear of the block: %.1f m short", (block.y - y) / M))
    h.assertTrue(math.abs(x / M - cx) < 10, "back where it hit")
    h.assertTrue(math.abs(math.cos(car.body:getAngle())) > 0.95, "pointing along the wall")
    run(race, 1)
    h.assertEq(car.wreck, nil, "driving off doesn't wreck it again")
    checkFinite(race)
    race:destroy()
  end)

  h.it("knocked cones go back once you're far off, and all of them on a respawn", function()
    local race, car = lotRace()
    local near, far = race.cones[1], race.cones[#race.cones]
    car:teleport(near.homeX + 10 * M, near.homeY, 0)
    near.body:setPosition(near.homeX + 3 * M, near.homeY)
    far.body:setPosition(far.homeX + 3 * M, far.homeY)
    race.player.driver = { update = function(_, c) c.input.throttle = 0 c.input.brake = 1 end }
    run(race, 0.1)
    h.assertTrue(near.body:getX() > near.homeX + 1 * M, "a cone in view stays where it was knocked")
    h.assertEq(far.body:getX(), far.homeX, "one out of sight goes back")
    race:respawn(car)
    h.assertEq(near.body:getX(), near.homeX)
    race:destroy()
  end)

  h.it("freestyle on a circuit goes any way it likes", function()
    local track = Track.new(catalog.builtin()[1].def)
    local race = Race.new({ mode = "freestyle", track = track, laps = 9999, spec = garage[3], seed = 3, startDelay = 0 })
    h.assertEq(race.cones, nil, "no cones on a circuit")
    local car = race.player
    local s = track.samples[1]
    car.driver = { update = function(_, c) c.input.throttle = 0.3 end }
    car:teleport(s.x, s.y, math.atan2(-s.ty, -s.tx))
    car.body:setLinearVelocity(-s.tx * 15 * M, -s.ty * 15 * M)
    local warned = false
    run(race, 3, function() warned = warned or car.wrongWay end)
    h.assertTrue(not warned, "freestyle said wrong way")
    race:destroy()
  end)
end)
