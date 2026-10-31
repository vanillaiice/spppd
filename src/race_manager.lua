-- The running race as the player sees it: owns the session, drives the
-- simulation at a fixed rate and draws each frame.
local config = require("src/config")
local Race = require("src/sim/race")
local Track = require("src/sim/track")
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
local colors = require("src/colors")
local network = require("src/network_manager")

local rm = {}

local M = config.METER
local DT = config.PHYSICS_DT

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
  return math.max(input.throttle(), touch.revs())
end

function playerDriver:update(car)
  input.applyTo(car.input, settings.gearbox == "manual")
  touch.applyTo(car.input)
end

local function lightsForTime(car, time)
  car.lowBeam = time ~= "day"
end

local function newCamera(x, y, angle)
  return { x = x, y = y, rot = -angle - math.pi / 2, zoom = 1, lookX = 0, lookY = 0, trauma = 0, shakeX = 0, shakeY = 0 }
end

function rm.start(opts)
  rm.stop()
  local track = opts.track or (opts.entry and Track.new(opts.entry.def))
  local race = Race.new({
    mode = opts.mode, track = track, laps = opts.laps, opponents = opts.opponents,
    spec = opts.spec, color = opts.color, assist = opts.assist or settings.assists,
    difficulty = opts.difficulty, seed = opts.seed, startDelay = opts.startDelay,
    online = opts.online,
    manualGearbox = settings.gearbox == "manual",
    onLap = function(car, time, clean) rm.onLap(car, time, clean) end,
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
    cam = newCamera(race.player.curX, race.player.curY, race.player.curA),
    toast = nil,
    drift = race.mode == "freestyle" and { total = 0, combo = 0, idle = 0 } or nil,
    bestLap = nil,
    ghostFrames = {},
    ghostTimer = 0,
  }

  for _, car in ipairs(race.cars) do lightsForTime(car, timeName) end
  for _, car in ipairs(race.cars) do sprites.get(car.spec) end

  if opts.demo then
    local AI = require("src/ai_controller")
    race.player.driver = AI.new(track, race.player, { skill = 0.95 })
    race.player.name = "VOSS"
  else
    race.player.driver = playerDriver
    if race.mode == "trial" then
      if opts.entry then
        session.bestLap = settings.bestLap(opts.entry.name, opts.spec.id)
        session.ghost = settings.ghost(opts.entry.name, opts.spec.id)
      end
    end
  end
  input.clear()
  touch.reset()
  rm.syncCamera(1)
end

function rm.stop()
  if session then
    session.race:destroy()
    session = nil
  end
  audio.silence()
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
    require("src/ui").focus.pause = 1
    touch.reset()
  end
  input.pressedOnce = {}
end

function rm.isFinished()
  return session and session.race.phase == "finished"
end

function rm.isOnline()
  return session and session.opts.online ~= nil
end

function rm.restart()
  if session then rm.start(session.opts) end
end

function rm.setToast(text, color, seconds, size)
  session.toast = { text = text, color = color, time = seconds or 2.5, size = size }
end

function rm.onLap(car, time, clean)
  if not session or car ~= session.race.player or session.demo then return end
  local race = session.race
  audio.play("lap", 0.5)

  if race.mode == "trial" then
    local entry = session.opts.entry
    if clean then
      -- A test drive from the editor keeps its best in memory only.
      local isRecord = not session.bestLap or time < session.bestLap
      if entry then
        isRecord = settings.submitLap(entry.name, session.opts.spec.id, time, session.ghostFrames)
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
    rm.setToast(string.format("LAP %d  %s", car.lapsDone, hud.formatTime(time)), best and colors.sectorGreen or colors.paint, 2)
  end
end

-- Simulation ----------------------------------------------------------------

local function handleControls()
  local race = session.race
  local car = race.player
  if input.consume("lowBeam") then
    car.lowBeam = not car.lowBeam
    if car.lowBeam then car.highBeam = false end
  end
  if input.consume("highBeam") then
    car.highBeam = not car.highBeam
  end
  if input.consume("camera") then
    settings.camera = settings.camera == "chase" and "fixed" or "chase"
    settings.save()
  end
  if input.consume("respawn") and race.phase == "racing" then
    race:respawn(car)
    audio.play("select", 0.5)
  end
end

local function processImpacts()
  local events = world.drainEvents()
  local race = session.race
  for _, e in ipairs(events) do
    local mine = e.carA == race.player or e.carB == race.player
    local strength = e.impulse / 9000
    if strength > 0.02 then
      vfx.scrape(e.x, e.y, e.nx, e.ny, math.min(2.5, strength * 3))
      if mine and not session.demo then
        session.cam.trauma = math.min(1, session.cam.trauma + math.min(0.6, strength * 0.8))
        audio.impact(math.min(1, 0.25 + strength), strength < 0.15)
        if session.drift then session.drift.combo = 0 end
      end
    end
  end
end

local function updateDrift(dt)
  local drift = session.drift
  if not drift then return end
  local car = session.race.player
  local beta = math.abs(car.model.beta)
  local speed = car:getSpeed()
  if beta > math.rad(10) and speed > 7 and car.model.reverse == false then
    drift.combo = drift.combo + speed * math.deg(beta) * dt * 0.12
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
local function updatePaceNote()
  local race = session.race
  local car = race.player
  session.pace = nil
  if not settings.paceNotes or not race.track or race.phase ~= "racing" or car.finished then return end
  if not session.paceProfile then
    local spec = car.spec
    session.paceProfile = race.track:speedProfile({
      mu = spec.grip * 0.95,
      vmax = 95,
      brake = spec.grip * config.GRAVITY * 0.8,
      accel = 6,
    })
  end

  local track = race.track
  local samples, n = track.samples, track.count
  local profile = session.paceProfile
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

  session.pace = {
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

function rm.syncCamera(blend)
  local cam = session.cam
  local car = session.race.player
  local x, y, a = car:interpolated(session.alpha)
  local speed = car:getSpeed()

  local beta = math.max(-0.6, math.min(0.6, car.model.beta))
  local facing = a + beta * 0.55
  local sw, sh = love.graphics.getDimensions()
  local base = math.min(sw / 1280, sh / 720)
  local framing = ZOOM[settings.zoom] or ZOOM.near
  local speedFade = math.min(1, speed / 85)
  local targetZoom = base * framing.close * (1 - framing.pullBack * speedFade)

  -- The camera breathes with the car: it falls back under power and leans
  -- in under braking, and nitro throws it back further.
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

local function updateCamera(dt)
  local cam = session.cam
  rm.syncCamera(1 - math.exp(-dt * 4))

  -- Impacts shake the view; kerbs give it the slightest buzz.
  local car = session.race.player
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

function rm.update(dt)
  -- An online race can't stop for one player: the menu opens over it instead.
  if not session or (session.paused and not session.opts.online) then return end
  local race = session.race
  if not session.demo then handleControls() end

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
        local launch = race.player.model.launch
        if launch >= 0.85 then
          rm.setToast("PERFECT START", colors.sectorGreen, 1.6)
        elseif launch >= 0.25 then
          rm.setToast("GOOD START", colors.marshal, 1.6)
        end
      end
    end
    if not session then return end
  end
  session.alpha = session.accumulator / DT

  if session.opts.online then
    session.netTimer = (session.netTimer or 0) - dt
    if session.netTimer <= 0 then
      session.netTimer = 1 / 20
      network.sendCar(race.player)
    end
    if network.peerGone and not session.peerGoneShown then
      session.peerGoneShown = true
      rm.setToast("YOUR RIVAL LEFT THE RACE", colors.kerb, 4)
    end
  end

  updateDrift(dt)
  recordGhost(dt)
  updatePaceNote()
  updateCamera(dt)
  for _, car in ipairs(race.cars) do car_view.updateFx(car, dt) end
  vfx.update(dt)

  if session.toast then session.toast.time = session.toast.time - dt end

  if not session.demo then
    local player = race.player
    local rival, nearest
    for _, car in ipairs(race.cars) do
      if car ~= player then
        local d = math.sqrt((car.curX - player.curX) ^ 2 + (car.curY - player.curY) ^ 2) / M
        if not nearest or d < nearest then rival, nearest = car, d end
      end
    end
    audio.update(dt, player, rival, nearest and nearest * 12 or 0)
    if player.fx and player.fx.backfired then
      player.fx.backfired = false
      audio.play("pop", 0.4, 0.8 + love.math.random() * 0.5)
    end
    -- Downshifts stay silent: a hard stop would rattle through every gear.
    local gear, lastGear = player.model.gear, session.lastGear or 1
    if gear ~= lastGear then
      session.lastGear = gear
      if gear > lastGear then audio.play("shift", 0.25) end
    end
    if race.phase == "finished" then audio.silence() end
  end
end

-- Drawing ---------------------------------------------------------------------

local function withCamera(sw, sh, fn)
  local cam = session.cam
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

local function drawWorld(sw, sh)
  local race, env, scene = session.race, session.env, session.scene
  local alpha = session.alpha
  withCamera(sw, sh, function()
    scene:drawGround()
    skids.draw()
    drawGhost(env)
    for _, car in ipairs(race.cars) do
      local x, y, a = car:interpolated(alpha)
      car_view.drawShadow(car, x, y, a, env)
    end
    for _, car in ipairs(race.cars) do
      local x, y, a = car:interpolated(alpha)
      car_view.draw(car, x, y, a)
    end
    vfx.draw()
    vfx.drawEmissive()
    love.graphics.setBlendMode("add")
    for _, car in ipairs(race.cars) do
      local x, y, a = car:interpolated(alpha)
      car_view.drawLamps(car, x, y, a)
    end
    love.graphics.setBlendMode("alpha")
    local on, out = lightsState()
    scene:drawOverhead(on, out)
  end)
end

function rm.drawScene(sw, sh)
  local race, env, scene = session.race, session.env, session.scene
  local alpha = session.alpha
  local boosting = race.player.model.boostState == "active"

  post.begin(sw, sh)
  drawWorld(sw, sh)

  if env.lights then
    post.drawLights(env.ambient, function()
      withCamera(sw, sh, function()
        scene:drawLights()
        for _, car in ipairs(race.cars) do
          local x, y, a = car:interpolated(alpha)
          car_view.drawBeams(car, x, y, a)
        end
      end)
    end)
  end

  post.drawGlow(function()
    withCamera(sw, sh, function()
      vfx.drawEmissive()
      love.graphics.setBlendMode("add")
      for _, car in ipairs(race.cars) do
        local x, y, a = car:interpolated(alpha)
        car_view.drawLamps(car, x, y, a)
      end
      local on, out = lightsState()
      scene:drawGlow(on, out)
    end)
  end)

  post.present({
    lights = env.lights,
    grade = env.grade,
    saturation = env.saturation,
    glow = env.glow,
    vignette = env.vignette,
    punch = boosting and 0.25 or 0,
    speedBlur = settings.quality == "low" and 0
      or math.max(0, math.min(1, (race.player:getSpeed() - 45) / 45)) * 0.01 + (boosting and 0.014 or 0),
  })
end

function rm.draw(sw, sh)
  if not session then return end
  rm.drawScene(sw, sh)
  if session.demo then return end
  hud.draw(sw, sh, session.race, session)
end

return rm
