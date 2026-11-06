-- The running race as the player sees it: owns the session, drives the
-- simulation at a fixed rate and draws each frame.
local config = require("src/config")
local Race = require("src/sim/race")
local Track = require("src/sim/track")
local dynamics = require("src/sim/dynamics")
local world = require("src/world")
local input = require("src/input")
local touch = require("src/touch")
local settings = require("src/settings")
local vfx = require("src/vfx_manager")
local skids = require("src/skid_manager")
local post = require("src/render/post")
local environment = require("src/render/environment")
local track_renderer = require("src/render/track_renderer")
local car_view = require("src/render/car_view")
local sprites = require("src/render/car_sprites")
local hud = require("src/hud")
local minimap = require("src/minimap")
local audio = require("src/audio")
local radio = require("src/radio")
local colors = require("src/colors")
local network = require("src/network_manager")
local rumble = require("src/rumble")
local cheats = require("src/cheats")

local rm = {}

local M = config.METER
local DT = config.PHYSICS_DT
local SCRAPE_FADE = 12  -- per second, so a car off the wall is silent in 0.08 s
local LOOK_INTERVAL = 0.5  -- seconds between telling the others about our cheats
local CRASH_SOUND = 3   -- a wreck is always the biggest crash, however heavy the car

local session -- everything that belongs to the current race

-- Camera distance: how close it sits when slow, and how far it pulls back at
-- top speed. Closer feels faster, further shows more road.
local ZOOM = {
  near = { close = 1.42, pullBack = 0.4 },
  mid = { close = 1.2, pullBack = 0.48 },
  far = { close = 1.04, pullBack = 0.6 },
}

local playerDriver = {}
function playerDriver:revs()
  if session.paused then return 0 end
  return math.max(input.throttle(), touch.revs())
end

-- Read at the lights too, so a press there is used up and can't fire at the go.
function playerDriver:boostButton()
  if session.paused then return false end
  local tapped = input.consume("boost")
  return tapped or input.isDown("boost")
end

function playerDriver:update(car)
  -- Only an online race runs on behind the pause menu. The keys are working the
  -- menu, so the car coasts rather than taking them as driving.
  if session.paused then
    local held = car.input
    held.throttle, held.brake, held.steer = 0, 0, 0
    held.handbrake, held.boost, held.shiftUp, held.shiftDown = false, false, false, false
    return
  end
  input.applyTo(car.input, settings.gearbox == "manual")
  touch.applyTo(car.input)
end

-- A driver's own hands when two share the screen: an input.reader, and a
-- function that says whether their gearbox is manual.
local function readerDriver(reader, manual)
  local driver = {}
  function driver:revs()
    if session.paused then return 0 end
    return reader:throttle()
  end
  function driver:boostButton()
    if session.paused then return false end
    local tapped = reader:consume("boost")
    return tapped or reader:isDown("boost")
  end
  function driver:update(car)
    reader:applyTo(car.input, manual())
  end
  return driver
end

-- The keyboard, any pad and the touch controls together, for one driver alone.
local MERGED = {
  isDown = function(_, action) return input.isDown(action) end,
  consume = function(_, action) return input.consume(action) end,
}

local function lightsFor(car, env)
  car.highBeam = env.highBeams or false
  car.lowBeam = env.lights and not car.highBeam
end

local function newCamera(x, y, angle)
  return { x = x, y = y, rot = -angle - math.pi / 2, zoom = 1, lookX = 0, lookY = 0, trauma = 0, shakeX = 0, shakeY = 0 }
end

-- One driver's share of the session: their car, their hands, their camera and
-- what the HUD is telling them. One alone has one; two at a screen have one each.
local function newView(race, car, index, hands)
  return {
    index = index,
    car = car,
    hands = hands,
    cam = newCamera(car.curX, car.curY, car.curA),
    drift = race.mode == "freestyle" and { total = 0, combo = 0, idle = 0 } or nil,
  }
end

local function viewOf(car)
  if not session then return nil end
  for _, view in ipairs(session.views) do
    if view.car == car then return view end
  end
  return nil
end

-- Two drivers get a half each, side by side: a chase camera looks up the screen,
-- so a half as tall as the window sees as far ahead as one driver alone does.
local function viewRect(index, sw, sh)
  if not session or not session.split then return 0, 0, sw, sh end
  local w = math.floor(sw / 2)
  return index == 1 and 0 or sw - w, 0, w, sh
end

function rm.start(opts)
  rm.stop()
  local track = opts.track or (opts.entry and Track.new(opts.entry.def))
  -- Two at a screen need hands for the second: a pad. Without one, as on a RACE
  -- AGAIN after it was pulled out, one drives alone.
  local player2, readers = nil, nil
  if opts.player2 and not opts.demo and not opts.online then
    readers = opts.readers or { input.splitReaders() }
    if readers[1] and readers[2] then player2 = opts.player2 end
  end
  local race = Race.new({
    mode = opts.mode, track = track, laps = opts.laps, opponents = opts.opponents,
    spec = opts.spec, color = opts.color, assist = opts.assist or settings.assists,
    difficulty = opts.difficulty, seed = opts.seed, startDelay = opts.startDelay,
    online = opts.online,
    rules = opts.rules,
    player2 = player2,
    playerName = player2 and opts.playerName or nil,
    lot = opts.mode == "freestyle" and not opts.demo,
    manualGearbox = settings.gearbox == "manual",
    onLap = function(car, time, clean) rm.onLap(car, time, clean) end,
    onCrash = function(car, hit) rm.onCrash(car, hit) end,
    onRecover = function(car) rm.onRecover(car) end,
    onSpoil = function(car, reason) rm.onSpoil(car, reason) end,
  })

  local timeName = opts.time or "day"
  local env = environment.time(timeName)
  local scene
  if track then
    scene = track_renderer.load(track, timeName)
    minimap.load(track)
  else
    scene = track_renderer.loadApron(timeName)
  end

  vfx.load(scene.theme.dust)
  vfx.density = settings.quality == "low" and 0.5 or 1
  skids.load()

  session = {
    opts = opts,
    race = race,
    env = env,
    scene = scene,
    time = timeName,
    accumulator = 0,
    alpha = 1,
    paused = false,
    demo = opts.demo,
    split = #race.players > 1,
    bestLap = nil,
    ghostFrames = {},
    ghostTimer = 0,
  }

  for _, car in ipairs(race.cars) do lightsFor(car, env) end
  for _, car in ipairs(race.cars) do sprites.get(car.spec) end

  local hands1, hands2 = MERGED, nil
  if session.split then hands1, hands2 = readers[1], readers[2] end
  session.views = { newView(race, race.player, 1, hands1) }
  if session.split then session.views[2] = newView(race, race.players[2], 2, hands2) end
  rumble.assign(1, session.split and (hands1.pad or false) or nil)
  rumble.assign(2, hands2 and hands2.pad or nil)
  audio.split(session.split)

  if opts.demo then
    local AI = require("src/ai_controller")
    race.player.driver = AI.new(track, race.player, { skill = 0.95 })
    race.player.name = "VOSS"
  elseif session.split then
    race.player.driver = readerDriver(hands1, function() return settings.gearbox == "manual" end)
    race.players[2].driver = readerDriver(hands2, function() return settings.gearbox2 == "manual" end)
  else
    race.player.driver = playerDriver
    if race.mode == "trial" then
      if opts.entry then
        session.bestLap = settings.bestLap(opts.entry.name, opts.spec.id, race.rules)
        session.ghost = settings.ghost(opts.entry.name, opts.spec.id, race.rules)
      end
    end
  end
  input.clear()
  touch.reset()
  rm.syncCamera(1)
  -- The only switch: rm.stop leaves it alone, so a restart doesn't cut the song.
  radio.tune(race.mode == "freestyle" and not opts.demo)
end

function rm.stop()
  if session then
    session.race:destroy()
    session = nil
  end
  audio.silence()
  rumble.stop()
end

function rm.isRunning()
  return session ~= nil
end

function rm.race()
  return session and session.race
end

function rm.opts()
  return session and session.opts
end

function rm.isPaused()
  return session and session.paused
end

function rm.setPaused(paused)
  if not session then return end
  session.paused = paused
  if paused then
    audio.silence()
    rumble.stop()
    require("src/ui").focus.pause = 1
    touch.reset()
  end
  radio.pause(paused)
  input.dropPresses()
end

-- True from the moment the player takes the flag, whatever the rest are doing.
-- With two at a screen, from when the second of them does.
function rm.isFinished()
  return session and session.finishClock ~= nil
end

-- Seconds the results have been up, or nil while they aren't.
function rm.resultsAge()
  local clock = session and session.finishClock
  return clock and clock >= hud.FINISH_HOLD and clock - hud.FINISH_HOLD or nil
end

function rm.isOnline()
  return session and session.opts.online ~= nil
end

function rm.restart()
  if session then rm.start(session.opts) end
end

-- On one driver's half, or on everyone's when it's news for all.
function rm.setToast(text, color, seconds, size, view)
  local toast = { text = text, color = color, time = seconds or 2.5, size = size }
  if view then
    view.toast = toast
    return
  end
  for _, each in ipairs(session.views) do
    each.toast = { text = toast.text, color = toast.color, time = toast.time, size = toast.size }
  end
end

-- The players' views, P1 first. Nil with no race.
function rm.views()
  return session and session.views
end

function rm.isSplit()
  return session ~= nil and session.split
end

-- True when a pad that's gone was one of the two drivers'.
function rm.usesPad(joystick)
  if not session or not session.split then return false end
  for _, view in ipairs(session.views) do
    if view.hands.pad == joystick then return true end
  end
  return false
end

-- Lights the player's exhaust, and tells the others at once.
local function lightFlames()
  car_view.flames(session.race.player, cheats.FLAME_TIME)
  session.flamesLit = (session.flamesLit or 0) + 1
  session.lookTimer = 0
end

-- A cheat code typed in the race. Flames go off at once; a toggle says so.
function rm.cheat(effect, label)
  if not session or session.demo then return end
  session.lookTimer = 0
  if effect == "flames" then
    cheats.takeFlames()
    lightFlames()
  else
    rm.setToast(label, colors.marshal, 1.6)
  end
end

function rm.onLap(car, time, clean)
  local view = viewOf(car)
  if not view or session.demo then return end
  local race = session.race
  -- Freestyle counts no laps out loud.
  if race.mode == "freestyle" then return end
  -- The last lap gets the finish sting instead.
  if race.mode ~= "race" or car.lapsDone < race.laps then audio.play("lap", 0.5) end

  if race.mode == "trial" then
    local entry = session.opts.entry
    if clean then
      -- A test drive from the editor keeps its best in memory only.
      local isRecord = not session.bestLap or time < session.bestLap
      if entry then
        isRecord = settings.submitLap(entry.name, session.opts.spec.id, time, session.ghostFrames, race.rules)
      end
      if isRecord then
        rm.setToast("NEW BEST  " .. hud.formatTime(time), colors.sectorPurple)
        session.bestLap = time
        session.ghost = session.ghostFrames
      else
        local delta = time - (session.bestLap or time)
        rm.setToast(string.format("%s  +%.3f", hud.formatTime(time), delta), colors.paint)
      end
    else
      rm.setToast("LAP NOT COUNTED", colors.kerb)
    end
    session.ghostFrames = {}
    session.ghostTimer = 0
  elseif race.mode == "race" and car.lapsDone < race.laps then
    local best = car.bestLap == time
    rm.setToast(string.format("LAP %d  %s", car.lapsDone, hud.formatTime(time)), best and colors.sectorGreen or colors.paint, 2,
      nil, view)
  end
end

function rm.onCrash(car, hit)
  local view = viewOf(car)
  if not view or session.demo then return end
  rm.setToast("CRASHED", colors.kerb, Race.WRECK_TIME + 0.3, nil, view)
  view.cam.trauma = 1
  audio.impact(math.max(CRASH_SOUND, hit * car.spec.mass / 9000), car.spec, view.index)
end

-- Clean rules say the moment a lap is lost, not just at the line.
local SPOILED = { off = "OFF TRACK", cut = "SHORTCUT", reset = "RESET", wreck = "CRASHED" }

function rm.onSpoil(car, reason)
  if not session or car ~= session.race.player or session.demo then return end
  if session.race.mode ~= "trial" then return end
  rm.setToast(SPOILED[reason] .. " - LAP VOID", colors.kerb, reason == "wreck" and Race.WRECK_TIME + 0.3 or 2)
end

function rm.onRecover(car)
  if not viewOf(car) or session.demo then return end
  audio.play("select", 0.5)
end

-- Simulation ----------------------------------------------------------------

-- The camera and the radio are everyone's; the rest is each driver's own.
local function handleControls(view)
  local race = session.race
  local car, hands = view.car, view.hands
  car.horn = hands:isDown("horn")
  if hands:consume("lowBeam") then
    car.lowBeam = not car.lowBeam
    if car.lowBeam then car.highBeam = false end
  end
  if hands:consume("highBeam") then
    car.highBeam = not car.highBeam
  end
  if hands:consume("camera") then
    settings.camera = settings.camera == "chase" and "fixed" or "chase"
    settings.save()
  end
  if hands:consume("respawn") and race.phase == "racing" and not car.finished and not car.wreck then
    race:respawn(car)
    audio.play("select", 0.5)
  end
  if hands:consume("radio") then radio.skip() end
end

local function processImpacts()
  local events = world.drainEvents()
  local views = session.views
  -- One crash is several contacts: only the hardest of them is the sound of it.
  local hardest = {}
  for _, e in ipairs(events) do
    local strength = e.impulse / 9000
    if e.prop then
      -- A cone: a puff and a knock, never a dent or a broken combo.
      local view = viewOf(e.car)
      if view and not session.demo then
        local vx, vy = view.car.body:getLinearVelocity()
        for _ = 1, 3 do vfx.dust(e.x, e.y, vx, vy, 1) end
        audio.knock(e.impulse)
      end
    elseif strength > 0.02 then
      vfx.scrape(e.x, e.y, e.nx, e.ny, math.min(2.5, strength * 3))
      if e.carA then car_view.hit(e.carA, e.x, e.y, strength, e.barrier) end
      if e.carB then car_view.hit(e.carB, e.x, e.y, strength, e.barrier) end
      if not session.demo then
        for i, view in ipairs(views) do
          if e.carA == view.car or e.carB == view.car then
            local cam = view.cam
            cam.trauma = math.min(1, cam.trauma + math.min(0.6, strength * 0.8))
            hardest[i] = math.max(hardest[i] or 0, strength)
            rumble.crash(strength, i)
            if view.drift then view.drift.combo = 0 end
          end
        end
      end
    end
  end
  for i, view in ipairs(views) do
    local car = view.car
    if hardest[i] then audio.impact(hardest[i], car.spec, i) end
    -- Contact flickers as a car bounces along a wall. This rides over the gaps.
    car.scraping = car.scraped and 1 or math.max(0, (car.scraping or 0) - DT * SCRAPE_FADE)
    car.scraped = false
  end
end

local function updateDrift(view, dt)
  local drift = view.drift
  if not drift then return end
  local car = view.car
  local speed = car:getSpeed()
  if dynamics.sliding(car.model, speed) then
    drift.combo = drift.combo + speed * math.deg(math.abs(car.model.beta)) * dt * 0.12
    drift.idle = 0
  else
    drift.idle = drift.idle + dt
    if drift.idle > 0.8 and drift.combo > 0 then
      drift.total = drift.total + drift.combo
      drift.combo = 0
    end
  end
end

-- The call a co-driver would make: what the next corner is, and when to brake.
local function updatePaceNote(view)
  local race = session.race
  local car = view.car
  view.pace = nil
  if not settings.paceNotes or not race.track or race.phase ~= "racing" or car.finished then return end
  if not view.paceProfile then
    local spec = car.spec
    view.paceProfile = race.track:speedProfile({
      mu = spec.grip * 0.95,
      vmax = 95,
      brake = spec.grip * config.GRAVITY * 0.8,
      accel = 6,
    })
  end

  local track = race.track
  local samples, n = track.samples, track.count
  local profile = view.paceProfile
  local speed = car:getSpeed()
  if speed < 12 then return end
  local index = car.trackIndex or 1
  local reach = (speed * speed / 14 + 45) / config.SAMPLE_SPACING

  local slowest, at = speed, nil
  for k = 1, math.floor(reach) do
    local i = (index + k - 1) % n + 1
    if profile[i] < slowest then slowest, at = profile[i], i end
  end
  if not at or slowest > speed * 0.9 then return end

  view.pace = {
    direction = samples[at].lineK > 0 and 1 or -1,
    -- Tightness runs 1 (hairpin) to 4 (fast kink), like a rally note.
    grade = slowest < 18 and 1 or (slowest < 28 and 2 or (slowest < 40 and 3 or 4)),
    brake = profile[index] < speed - 1,
  }
end

local function recordGhost(dt)
  if session.race.mode ~= "trial" or session.race.phase ~= "racing" then return end
  session.ghostTimer = session.ghostTimer - dt
  if session.ghostTimer <= 0 then
    session.ghostTimer = 1 / 15
    local car = session.race.player
    local f = session.ghostFrames
    f[#f + 1] = math.floor(car.curX + 0.5)
    f[#f + 1] = math.floor(car.curY + 0.5)
    f[#f + 1] = math.floor(car.curA * 100 + 0.5) / 100
  end
end

-- How far the camera pulls back on half a screen, against the whole window's
-- framing. A half shows less road to the sides, so it stands a little further off.
local SPLIT_ZOOM = 0.88

local function syncView(view, blend)
  local cam = view.cam
  local car = view.car
  local x, y, a = car:interpolated(session.alpha)
  local speed = car:getSpeed()

  local beta = math.max(-0.6, math.min(0.6, car.model.beta))
  local facing = a + beta * 0.55
  local fullW, fullH = love.graphics.getDimensions()
  local _, _, sw, sh = viewRect(view.index, fullW, fullH)
  local base = math.min(fullW / 1280, fullH / 720) * (session.split and SPLIT_ZOOM or 1)
  local framing = ZOOM[settings.zoom] or ZOOM.near
  local speedFade = math.min(1, speed / 85)
  local targetZoom = base * framing.close * (1 - framing.pullBack * speedFade)

  -- The camera breathes with the car: it falls back under power and leans
  -- in under braking, and boost throws it back further.
  local model = car.model
  local surge = math.max(-1, math.min(1, model.ax / 10))
  targetZoom = targetZoom * (1 - surge * 0.05)
  if model.boostState == "active" then targetZoom = targetZoom * 0.86 end
  cam.zoom = cam.zoom + (targetZoom - cam.zoom) * blend * 1.1

  local chase = settings.camera == "chase"
  local targetRot = chase and (-facing - math.pi / 2) or 0
  local diff = (targetRot - cam.rot + math.pi) % (math.pi * 2) - math.pi
  cam.rot = cam.rot + diff * blend * 1.5

  local lookX, lookY
  if chase then
    -- The car slides around the frame: back under power, out in corners.
    local fwd = (sh * 0.25 - surge * sh * 0.035) / cam.zoom
    local side = -math.max(-1, math.min(1, model.ay / 11)) * sw * 0.035 / cam.zoom
    local ca, sa = math.cos(a), math.sin(a)
    lookX, lookY = ca * fwd - sa * side, sa * fwd + ca * side
  else
    local vx, vy = car.body:getLinearVelocity()
    lookX, lookY = vx * 0.3, vy * 0.3
  end
  cam.lookX = cam.lookX + (lookX - cam.lookX) * blend * 1.5
  cam.lookY = cam.lookY + (lookY - cam.lookY) * blend * 1.5
  cam.x, cam.y = x + cam.lookX, y + cam.lookY
end

function rm.syncCamera(blend)
  for _, view in ipairs(session.views) do syncView(view, blend) end
end

-- The flag falls for the player here, while the rest may race on for a while.
-- Each driver at the screen gets their own banner; the results wait for both.
local function updateFinish(dt)
  if session.demo then return end
  local allDone = true
  for i, view in ipairs(session.views) do
    local car = view.car
    if view.finishClock then
      view.finishClock = view.finishClock + dt
    elseif car.finished or car.timedOut then
      view.finishClock = 0
      view.toast = nil
      rumble.stop(i)
      audio.play("finish", 0.6, car.place == 1 and 1 or 0.84)
    else
      allDone = false
    end
  end
  if not allDone then return end
  if session.finishClock then
    session.finishClock = session.finishClock + dt
    return
  end
  -- Held back by the later of the two, so the results never cut a banner short.
  local clock = math.huge
  for _, view in ipairs(session.views) do clock = math.min(clock, view.finishClock) end
  session.finishClock = clock
  session.paused = false
  touch.reset()
  rumble.stop()
end

local function updateCamera(view, dt)
  local cam = view.cam
  syncView(view, 1 - math.exp(-dt * 4))

  -- Impacts shake the view; kerbs give it the slightest buzz.
  local car = view.car
  local rumble = 0
  for _, w in ipairs(car.model.wheels) do
    if w.surface == "kerb" then rumble = 0.05 end
  end
  cam.trauma = math.max(0, cam.trauma - dt * 1.8)
  local speed = car:getSpeed()
  local buffet = math.max(0, speed - 45) / 45 * 0.035
  if car.model.boostState == "active" then buffet = buffet + 0.05 end
  local shake = cam.trauma * cam.trauma + rumble * math.min(1, speed / 30) + buffet
  cam.shakeX = (love.math.random() - 0.5) * 22 * shake
  cam.shakeY = (love.math.random() - 0.5) * 22 * shake
end

local function carInSeat(race, slot)
  for _, car in ipairs(race.cars) do
    if car.slot == slot and car ~= race.player then return car end
  end
  return nil
end

local function updateOnline(dt)
  local race = session.race
  race:syncClock()
  session.netTimer = (session.netTimer or 0) - dt
  if session.netTimer <= 0 then
    session.netTimer = 1 / 20
    network.sendCar(race.player)
  end
  session.lookTimer = (session.lookTimer or 0) - dt
  if session.lookTimer <= 0 then
    session.lookTimer = LOOK_INTERVAL
    local fx = race.player.fx
    network.sendLook({ neon = settings.neon, tune = settings.tuneHorn, flames = session.flamesLit or 0,
      flameLeft = fx and fx.flameTime or 0 })
  end
  -- The others' cheats, as their games last said.
  for _, car in ipairs(race.cars) do
    local look = car ~= race.player and car.slot and network.lookOf(car.slot)
    if look then
      car.neon, car.hornTune = look.neon, look.tune
      if look.flames > (car.flamesLit or 0) and look.flameLeft > 0 then
        car_view.flames(car, look.flameLeft)
      end
      car.flamesLit = look.flames
    end
  end

  for _, slot in ipairs(network.takeDepartures()) do
    local car = carInSeat(race, slot)
    if car and race:peerLeft(car) and not network.lost then
      rm.setToast(car.name .. " LEFT THE RACE", colors.kerb, 4)
    end
  end
  -- Connections that dropped and came back. The race goes on through all of it.
  for _, n in ipairs(network.takeNotices()) do
    if n.kind == "away" then
      rm.setToast("CONNECTION LOST  GETTING BACK IN", colors.marshal, 4)
    elseif n.kind == "back" then
      rm.setToast("BACK ONLINE", colors.marshal, 3)
    else
      local car = carInSeat(race, n.slot)
      if car and not car.finished then
        rm.setToast(car.name .. (n.kind == "peerAway" and " LOST CONNECTION" or " IS BACK"), colors.marshal, 3)
      end
    end
  end
  -- Why the others vanished, which isn't that they all left.
  if network.lost and not session.lostShown then
    session.lostShown = true
    rm.setToast(network.lost:upper(), colors.kerb, 5)
  end

  local player = race.player
  if race.flagFell and not session.flagShown then
    session.flagShown = true
    if not player.finished then
      rm.setToast(string.format("FLAG IS OUT  %d SECONDS LEFT", race.FINISH_GRACE), colors.marshal, 4)
    end
  end
end

-- What one driver hears and feels. Alone, the nearest rival's engine joins in;
-- two at a screen each hear their own car, panned to their own half.
local function updateFeel(view, i, dt)
  local race = session.race
  local car = view.car
  local rival, nearest
  if not session.split then
    for _, other in ipairs(race.cars) do
      if other ~= car then
        local d = math.sqrt((other.curX - car.curX) ^ 2 + (other.curY - car.curY) ^ 2) / M
        if not nearest or d < nearest then rival, nearest = other, d end
      end
    end
  end
  audio.update(dt, car, rival, nearest and nearest * 12 or 0, i)
  if not view.finishClock and not session.paused then rumble.update(dt, car, i) end
  -- Downshifts stay silent: a hard stop would rattle through every gear.
  local gear, lastGear = car.model.gear, view.lastGear or 1
  if gear ~= lastGear then
    view.lastGear = gear
    if gear > lastGear then
      audio.play("shift", audio.SHIFT_LEVEL, audio.variedPitch())
      rumble.shift(i)
    end
  end
end

function rm.update(dt)
  -- An online race can't stop for one player: the menu opens over it instead.
  if not session or (session.paused and not session.opts.online) then return end
  local race = session.race
  if session.paused then
    race.player.horn = false
  elseif not session.demo then
    for _, view in ipairs(session.views) do handleControls(view) end
  end

  session.accumulator = math.min(session.accumulator + dt, DT * config.MAX_STEPS_PER_FRAME)
  while session.accumulator >= DT do
    local lightsBefore = hud.lightsOn(race)
    race:step(DT)
    session.accumulator = session.accumulator - DT
    processImpacts()
    if not session.demo then
      local lightsAfter = hud.lightsOn(race)
      if lightsAfter > lightsBefore then audio.play("beep", 0.6) end
      if race.justStarted then
        race.justStarted = false
        audio.play("go", 0.7)
        -- A flame code entered in the menus goes off with the lights.
        if cheats.takeFlames() then lightFlames() end
        for _, view in ipairs(session.views) do
          local launch = view.car.model.launch
          if launch >= 0.85 then
            rm.setToast("PERFECT START", colors.sectorGreen, 1.6, nil, view)
          elseif launch >= 0.25 then
            rm.setToast("GOOD START", colors.marshal, 1.6, nil, view)
          end
        end
      end
    end
    if not session then return end
  end
  session.alpha = session.accumulator / DT

  if session.opts.online then updateOnline(dt) end

  updateFinish(dt)
  for _, view in ipairs(session.views) do
    updateDrift(view, dt)
    updatePaceNote(view)
    updateCamera(view, dt)
  end
  recordGhost(dt)
  for _, car in ipairs(race.cars) do car_view.updateFx(car, dt) end
  vfx.update(dt)

  local song = radio.update()
  if song then rm.setToast("ON AIR  " .. song, colors.marshal, 3) end
  for _, view in ipairs(session.views) do
    if view.toast then view.toast.time = view.toast.time - dt end
  end

  if not session.demo then
    for _, view in ipairs(session.views) do
      local car = view.car
      -- The cheats are this machine's, so both drivers here have them.
      car.neon, car.hornTune = settings.neon, settings.tuneHorn
    end
    for _, car in ipairs(race.cars) do audio.hornStep(car, dt) end
    if rm.resultsAge() then
      audio.fadeOut(dt)
    else
      for i, view in ipairs(session.views) do updateFeel(view, i, dt) end
    end
  end
end

-- Drawing ---------------------------------------------------------------------

local function withCamera(sw, sh, fn, cam)
  cam = cam or session.views[1].cam
  love.graphics.push()
  love.graphics.translate(sw / 2 + cam.shakeX, sh / 2 + cam.shakeY)
  love.graphics.scale(cam.zoom)
  love.graphics.rotate(cam.rot)
  love.graphics.translate(-cam.x, -cam.y)
  fn()
  love.graphics.pop()
end

local function drawGhost(env)
  local frames = session.ghost
  local race = session.race
  if not frames or #frames < 6 or race.phase ~= "racing" then return end
  local t = (race.time - race.player.lapStart) * 15
  local i = math.floor(t)
  local n = #frames / 3
  if i >= n - 1 then return end
  local f = t - i
  local a = i * 3
  local x = frames[a + 1] + (frames[a + 4] - frames[a + 1]) * f
  local y = frames[a + 2] + (frames[a + 5] - frames[a + 2]) * f
  local angle = frames[a + 3] + ((frames[a + 6] - frames[a + 3] + math.pi) % (math.pi * 2) - math.pi) * f
  car_view.draw(race.player, x, y, angle, 0.35)
end

local function lightsState()
  local race = session.race
  if race.phase == "countdown" then return hud.lightsOn(race), false end
  return nil, true
end

-- How far from the middle of a view, in world px, anything can be and still
-- show: half its diagonal, plus the shake, at the camera's zoom.
local function viewReach(cam, sw, sh)
  return (math.sqrt(sw * sw + sh * sh) / 2 + math.abs(cam.shakeX) + math.abs(cam.shakeY)) / cam.zoom
end

-- Cars too far from the camera to show aren't drawn. A car reaches this far
-- from its middle, with the boost warp trailing behind it; its beams far more.
local BODY_REACH = 20 * M
local BEAM_REACH = 125 * M

local function inView(car, cam, reach)
  local dx, dy = car.drawX - cam.x, car.drawY - cam.y
  return dx * dx + dy * dy < reach * reach
end

local function drawWorld(sw, sh, cam)
  local race, env, scene = session.race, session.env, session.scene
  local reach = viewReach(cam, sw, sh) + BODY_REACH
  withCamera(sw, sh, function()
    scene:drawGround()
    skids.draw()
    if race.cones then scene:drawCones(race.cones) end
    drawGhost(env)
    for _, car in ipairs(race.cars) do
      if inView(car, cam, reach) then car_view.drawShadow(car, car.drawX, car.drawY, car.drawA, env) end
    end
    for _, car in ipairs(race.cars) do
      if inView(car, cam, reach) then car_view.draw(car, car.drawX, car.drawY, car.drawA) end
    end
    vfx.draw()
    vfx.drawEmissive()
    love.graphics.setBlendMode("add")
    for _, car in ipairs(race.cars) do
      if inView(car, cam, reach) then car_view.drawLamps(car, car.drawX, car.drawY, car.drawA) end
    end
    love.graphics.setBlendMode("alpha")
    local on, out = lightsState()
    scene:drawOverhead(on, out)
  end, cam)
end

-- One view's picture, drawn at x, y on the screen: the whole window for one
-- driver, or each driver's half.
local function drawView(view, x, y, sw, sh)
  local race, env, scene = session.race, session.env, session.scene
  local car, cam = view.car, view.cam
  local reach = viewReach(cam, sw, sh)
  local boosting = car.model.boostState == "active"

  post.begin(sw, sh)
  drawWorld(sw, sh, cam)

  if env.lights then
    post.drawLights(env.ambient, function()
      withCamera(sw, sh, function()
        scene:drawLights()
        for _, car in ipairs(race.cars) do
          if inView(car, cam, reach + BEAM_REACH) then
            car_view.drawBeams(car, car.drawX, car.drawY, car.drawA, env.beams)
          end
        end
      end, cam)
    end)
  end

  post.drawGlow(function()
    withCamera(sw, sh, function()
      vfx.drawEmissive()
      love.graphics.setBlendMode("add")
      for _, car in ipairs(race.cars) do
        if inView(car, cam, reach + BODY_REACH) then car_view.drawLamps(car, car.drawX, car.drawY, car.drawA) end
      end
      local on, out = lightsState()
      scene:drawGlow(on, out)
    end, cam)
  end)

  post.present({
    x = x,
    y = y,
    lights = env.lights,
    grade = env.grade,
    saturation = env.saturation,
    glow = env.glow,
    vignette = env.vignette,
    punch = boosting and 0.25 or 0,
    speedBlur = settings.quality == "low" and 0
      or math.max(0, math.min(1, (car:getSpeed() - 45) / 45)) * 0.01 + (boosting and 0.014 or 0),
  })
end

function rm.drawScene(sw, sh)
  -- Each car's pose for this frame, between the last two physics steps.
  for _, car in ipairs(session.race.cars) do
    car.drawX, car.drawY, car.drawA = car:interpolated(session.alpha)
  end
  for i, view in ipairs(session.views) do
    local x, y, w, h = viewRect(i, sw, sh)
    drawView(view, x, y, w, h)
  end
end

-- Where each driver's car is in this view, in its own pixels, for the P1 and P2
-- chips. The same transform withCamera applies, done by hand.
local CAR_REACH = 2.6 * M  -- from a car's middle to past its nose or tail

local function markDrivers(view, sw, sh)
  local cam = view.cam
  local c, sn = math.cos(cam.rot), math.sin(cam.rot)
  view.marks = view.marks or {}
  for i, other in ipairs(session.views) do
    local dx, dy = other.car.drawX - cam.x, other.car.drawY - cam.y
    view.marks[i] = {
      car = other.car,
      x = sw / 2 + cam.shakeX + (dx * c - dy * sn) * cam.zoom,
      y = sh / 2 + cam.shakeY + (dx * sn + dy * c) * cam.zoom,
      reach = CAR_REACH * cam.zoom,
    }
  end
end

function rm.draw(sw, sh)
  if not session then return end
  rm.drawScene(sw, sh)
  if session.demo then return end
  if not session.split then
    hud.draw(sw, sh, session.race, session, session.views[1])
    return
  end
  for i, view in ipairs(session.views) do
    local x, y, w, h = viewRect(i, sw, sh)
    markDrivers(view, w, h)
    love.graphics.push()
    love.graphics.translate(x, y)
    love.graphics.setScissor(x, y, w, h)
    hud.drawView(w, h, session.race, session, view, sw, sh)
    love.graphics.setScissor()
    love.graphics.pop()
  end
  hud.drawShared(sw, sh, session.race, session)
end

return rm
