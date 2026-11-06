-- Race rules: grid, start lights, laps, standings and finishing. Steps at a
-- fixed rate and draws nothing, so whole races can run headless in tests.
local config = require("src/config")
local Car = require("src/entities/car")
local AI = require("src/ai_controller")
local dynamics = require("src/sim/dynamics")
local RemoteDriver = require("src/sim/remote_driver")
local slipstream = require("src/sim/slipstream")
local garage = require("src/entities/garage")
local world = require("src/world")
local lot = require("src/sim/lot")

local Race = {}
Race.__index = Race

local M = config.METER
local abs, floor = math.abs, math.floor

Race.DIFFICULTY = {
  rookie = { skill = 0.84, spread = 0.03 },
  pro    = { skill = 0.92, spread = 0.025 },
  ace    = { skill = 0.985, spread = 0.015 },
}

local AI_NAMES = { "VEGA", "KOSTA", "TANAKA", "OKAFOR", "LINDQVIST" }
local AI_COLORS = {
  { 0.08, 0.36, 0.72 }, { 0.86, 0.46, 0.07 }, { 0.07, 0.52, 0.34 },
  { 0.46, 0.14, 0.62 }, { 0.82, 0.82, 0.86 },
}
-- Arcade tyres grip harder, so a grid only matches the player's car on them.
local AI_ASSIST = { arcade = "arcade" }
local WRONG_WAY_TIME = 1.2
local SHORTCUT_JUMP = 45 * M
local FINISH_GRACE = 25

-- A fence wrecks a car that loses this much speed to it, in m/s. Speed rather
-- than force, or heavy cars would wreck first and light ones could bounce for free.
local CRASH_SPEED = 15
local CRASH_MEMORY = 0.15  -- seconds; a nose and then the tail swinging in are one hit
local WRECK_TIME = 1.2     -- seconds out of the car's hands before it goes back
local SHUNT_GRACE = 0.4    -- seconds after touching a car when a fence can't wreck it
local RECOVER_CLEARANCE = 4 * M  -- how far out from a wall a wreck off the road restarts
local LOT_PAIR = 3 * M           -- two drivers on the lot start this far either side of the box's middle

-- Seats can have gaps, because someone left the lobby. The grid doesn't.
local function gridPlace(online, slot)
  local place = 1
  if online.slot < slot then place = place + 1 end
  for _, driver in ipairs(online.peers) do
    if driver.slot < slot then place = place + 1 end
  end
  return place
end

function Race.new(opts)
  local self = setmetatable({}, Race)
  self.mode = opts.mode or "race"    -- race | trial | freestyle
  -- "clean" voids a lap for going off, cutting, a reset or a wreck; "open" never does.
  self.rules = opts.rules or "clean"
  self.track = opts.track
  self.laps = opts.laps or 3
  self.phase = "countdown"
  self.timer = 0
  self.time = 0
  self.startDelay = opts.startDelay or config.START_DELAY
  self.seed = opts.seed or os.time()
  self.rng = love.math.newRandomGenerator(self.seed)
  self.cars = {}
  self.onLap = opts.onLap
  self.onCrash = opts.onCrash
  self.onRecover = opts.onRecover
  self.onSpoil = opts.onSpoil

  world.load(self.track)
  -- Freestyle's playground, when it isn't on a circuit.
  if opts.lot and not self.track then
    self.cones = world.addLot(lot.layout(), lot.CONE_RADIUS, lot.CONE_MASS)
  end

  local spec = opts.spec or garage[1]
  local online = opts.online
  self.online = online ~= nil
  -- Seconds to lights out on the clock everyone shares, or nil until it's called.
  self.startIn = online and online.startIn
  self.gone = {}
  -- Tiers change how much grip a car has, so an online race has to share one.
  local handling = online and dynamics.DEFAULT_ASSIST or opts.assist or dynamics.DEFAULT_ASSIST
  self.handling = handling
  -- A second driver at the same screen. Local only: never online.
  local second = not online and opts.player2 or nil
  local slot = 1
  if self.mode == "race" and self.track then slot = online and gridPlace(online, online.slot) or (opts.opponents or 0) + 1 end
  local x, y, angle, index = 0, 0, -math.pi / 2, nil
  if self.track then
    x, y, angle, index = self.track:gridSlot(slot)
  elseif second then
    x = -LOT_PAIR
  end

  self.player = Car.new(spec, x, y, angle, {
    isPlayer = true,
    color = opts.color,
    assist = handling,
    name = opts.playerName or "YOU",
  })
  self.player.input.manual = opts.manualGearbox or false
  self.player.trackIndex = index
  self.player.homeX, self.player.homeY = x, y
  self.cars[1] = self.player
  -- Everyone driven by someone here, P1 first.
  self.players = { self.player }

  if second then
    local sx, sy, sa, si = LOT_PAIR, 0, -math.pi / 2, nil
    if self.track then sx, sy, sa, si = self.track:gridSlot(slot + 1) end
    local car = Car.new(second.spec or garage[1], sx, sy, sa, {
      isPlayer = true,
      color = second.color,
      -- Each driver here picks their own handling. The AI goes by P1's.
      assist = second.assist or handling,
      name = second.name or "P2",
    })
    car.input.manual = second.manualGearbox or false
    car.trackIndex = si
    car.homeX, car.homeY = sx, sy
    self.cars[2] = car
    self.players[2] = car
  end

  if online then
    self.player.slot = online.slot
    for _, driver in ipairs(online.peers) do
      local px, py, pa, pi = self.track:gridSlot(gridPlace(online, driver.slot))
      local peer = Car.new(driver.spec, px, py, pa, { name = "P" .. driver.slot, color = driver.color })
      peer.remote = true
      peer.slot = driver.slot
      peer.driver = RemoteDriver.new(driver.state)
      peer.trackIndex = pi
      self.cars[#self.cars + 1] = peer
    end
  elseif self.mode == "race" and self.track then
    self:spawnOpponents(opts, slot)
  end

  for _, car in ipairs(self.cars) do self:initProgress(car) end
  -- Latest standings. Every step sorts this, so reading it costs nothing.
  self.order = {}
  for i, car in ipairs(self.cars) do self.order[i] = car end
  self:standings()
  return self
end

function Race:spawnOpponents(opts, playerSlot)
  local diff = Race.DIFFICULTY[opts.difficulty or "pro"] or Race.DIFFICULTY.pro
  for i = 1, opts.opponents or 0 do
    local spec = garage[(i + (self.seed % #garage)) % #garage + 1]
    local grid = playerSlot - i
    local x, y, angle, index = self.track:gridSlot(grid)
    local car = Car.new(spec, x, y, angle, {
      name = AI_NAMES[(i - 1) % #AI_NAMES + 1],
      color = AI_COLORS[(i - 1) % #AI_COLORS + 1],
      assist = AI_ASSIST[self.handling] or "full",
    })
    -- Better starters are further up the grid.
    local skill = diff.skill + diff.spread * (grid <= playerSlot / 2 and 1 or -1)
      + (self.rng:random() - 0.5) * diff.spread
    car.driver = AI.new(self.track, car, { skill = skill, revPhase = self.rng:random() })
    car.trackIndex = index
    self.cars[#self.cars + 1] = car
  end
end

function Race:initProgress(car)
  car.lapsDone = 0
  car.lapStart = 0
  car.lastLap = nil
  car.bestLap = nil
  car.finished = false
  car.finishTime = nil
  car.place = 1
  car.wrongWayTime = 0
  car.offTrack = false
  car.lapClean = true
  car.distance = 0
  car.offCount = 0
  if self.track then
    local _, s, lateral = self.track:locate(car.body:getX(), car.body:getY(), car.trackIndex)
    car.trackS = s
    car.lateral = lateral
    -- Starting behind the line counts as a negative distance into lap 1.
    car.distance = s > self.track.length / 2 and s - self.track.length or s
  end
end

function Race:destroy()
  for _, car in ipairs(self.cars) do car:destroy() end
  for _, car in ipairs(self.gone) do car:destroy() end
  self.cars = {}
  self.gone = {}
  self.order = {}
  world.destroy()
end

function Race:currentLap(car)
  return math.min(self.laps, car.lapsDone + 1)
end

-- Where the car sits in the full race distance, for standings.
local function rank(a, b)
  if a.finished and b.finished then
    -- Every screen has to agree, even on a dead heat.
    if a.finishTime ~= b.finishTime then return a.finishTime < b.finishTime end
    return (a.slot or 0) < (b.slot or 0)
  end
  if a.finished ~= b.finished then return a.finished end
  if (a.retired or false) ~= (b.retired or false) then return b.retired or false end
  return a.distance > b.distance
end

function Race:standings()
  local order = self.order
  table.sort(order, rank)
  for i, car in ipairs(order) do car.place = i end
  return order
end

-- The lap stops counting, said once per lap. Open rules let everything go.
local function spoil(self, car, reason)
  if self.rules == "open" or not car.lapClean then return end
  car.lapClean = false
  if self.onSpoil then self.onSpoil(car, reason) end
end

local function placeOnLine(self, car, s)
  car:teleport(s.lineX, s.lineY, math.atan2(s.ty, s.tx), 2.5)
  car.trackIndex = s.index
  spoil(self, car, "reset")
end

-- True when no driver here is near enough to see something at x, y move.
local function outOfSight(self, x, y)
  local far = lot.CONE_RESET_DISTANCE ^ 2
  for _, car in ipairs(self.players) do
    local px, py = car.body:getPosition()
    if (px - x) ^ 2 + (py - y) ^ 2 <= far then return false end
  end
  return true
end

-- Knocked cones go back to their spots: all of them, or only the ones every
-- player is far enough from not to see it happen.
function Race:resetCones(all)
  if not self.cones then return end
  local moved = (1 * M) ^ 2
  for _, cone in ipairs(self.cones) do
    local body = cone.body
    local x, y = body:getPosition()
    if (x - cone.homeX) ^ 2 + (y - cone.homeY) ^ 2 > moved
      and (all or outOfSight(self, cone.homeX, cone.homeY)) then
      body:setPosition(cone.homeX, cone.homeY)
      body:setAngle(0)
      body:setLinearVelocity(0, 0)
      body:setAngularVelocity(0)
    end
  end
end

function Race:respawn(car)
  local track = self.track
  if not track then
    car:teleport(car.homeX or 0, car.homeY or 0, -math.pi / 2)
    if car.isPlayer then self:resetCones(true) end
    return
  end
  local index = car.trackIndex or 1
  placeOnLine(self, car, track.samples[(index + 1) % track.count + 1])
end

-- Freestyle's live car change, from the pause menu. A wreck in progress is
-- over: the new car arrives whole. A bigger car swapped in against a wall is
-- eased out of it, which loses no speed, so it's no crash.
function Race:swapCar(car, spec, color)
  car.wreck = nil
  car.input.wrecked, car.input.brake = false, 0
  car:setSpec(spec, color)
end

-- Back to where it hit, not where it slid to. Going on from there made a wreck
-- quicker than braking, so the slide comes off its distance here: a long one is
-- past what updateProgress would count.
local function recover(self, car)
  local track = self.track
  if not track then
    -- No road to go back to: out from what it hit, along it, from a stop.
    local spot = car.wreckSpot
    if not spot.x then spot = { x = car.body:getX(), y = car.body:getY(), nx = 0, ny = 0 } end
    local nx, ny = spot.nx or 0, spot.ny or 0
    local along = math.atan2(nx, -ny)
    local heading = car.body:getAngle()
    -- Whichever way along it is nearer where the car was pointing.
    if math.cos(heading - along) < 0 then along = along + math.pi end
    car:teleport(spot.x + nx * RECOVER_CLEARANCE, spot.y + ny * RECOVER_CLEARANCE, along)
    if self.onRecover then self.onRecover(car) end
    return
  end
  local s = track.samples[car.wreckIndex]
  local delta = (s.s - car.trackS + track.length / 2) % track.length - track.length / 2
  car.distance = car.distance + delta
  car.trackS = s.s
  placeOnLine(self, car, s)
  if self.onRecover then self.onRecover(car) end
end

local function wreck(self, car, hit)
  car.wreck = WRECK_TIME
  car.wreckIndex = car.trackIndex
  car.wreckSpot = { x = car.fenceX, y = car.fenceY, nx = car.fenceNx, ny = car.fenceNy }
  local input = car.input
  input.throttle, input.brake, input.steer = 0, 1, 0
  input.handbrake, input.boost, input.shiftUp, input.shiftDown = false, false, false, false
  input.wrecked = true
  if self.onCrash then self.onCrash(car, hit) end
  spoil(self, car, "wreck")
end

-- A fence can wreck a car, but another car can't, and that includes being shoved
-- into a fence by one. Each game judges its own cars, as it does their laps.
function Race:updateCrash(car, dt)
  if car.remote then return end
  car.shunted = car.touchedCar and SHUNT_GRACE or math.max(0, car.shunted - dt)
  car.touchedCar = false
  car.fenceHit = car.fenceHit * math.exp(-dt / CRASH_MEMORY) + car.fenceImpulse / (car.spec.mass * M)
  car.fenceImpulse = 0
  car.fencePeak = 0

  if car.wreck then
    car.wreck = car.wreck - dt
    if car.wreck <= 0 or car.finished then
      car.wreck = nil
      car.input.brake, car.input.wrecked = 0, false
      if not car.finished then recover(self, car) end
    end
  elseif car.fenceHit >= CRASH_SPEED and car.shunted == 0 and self.phase == "racing" and not car.finished then
    wreck(self, car, car.fenceHit)
  end
end

function Race:updateProgress(car, dt)
  local track = self.track
  local x, y = car.body:getPosition()
  local index, s, lateral, off = track:locate(x, y, car.trackIndex)
  local previous = car.trackS
  car.trackIndex, car.trackS, car.lateral = index, s, lateral
  -- Their own game counts their laps, and sends the answer.
  if car.remote then return end

  local delta = s - previous
  local length = track.length
  if delta < -length / 2 then delta = delta + length
  elseif delta > length / 2 then delta = delta - length end

  -- A big jump means the car left the road and rejoined somewhere else:
  -- the skipped distance doesn't count, so cutting the track never pays.
  if abs(delta) < SHORTCUT_JUMP then
    car.distance = car.distance + delta
  else
    spoil(self, car, "cut")
  end

  -- All four wheels off means the lap doesn't count as clean.
  local wheels = car.model.wheels
  local offCount = 0
  for i = 1, 4 do
    local surface = wheels[i].surface
    if surface == "grass" or surface == "gravel" then offCount = offCount + 1 end
  end
  car.offCount = offCount
  car.offTrack = offCount == 4
  if car.offTrack and self.phase == "racing" then spoil(self, car, "off") end

  -- Wrong way warning
  local sample = track.samples[index]
  local vx, vy = car.body:getLinearVelocity()
  local dot = (vx * sample.tx + vy * sample.ty) / M
  if dot < -4 then
    car.wrongWayTime = car.wrongWayTime + dt
  else
    car.wrongWayTime = 0
  end
  -- Freestyle goes whichever way it likes.
  car.wrongWay = self.mode ~= "freestyle" and car.wrongWayTime > WRONG_WAY_TIME

  -- Laps
  local completed = floor(car.distance / length)
  if completed > car.lapsDone and self.phase == "racing" and not car.finished then
    local lapTime = self.time - car.lapStart
    car.lapsDone = completed
    car.lapStart = self.time
    car.lastLap = lapTime
    if lapTime > 0 and (not car.bestLap or lapTime < car.bestLap) and car.lapClean then
      car.bestLap = lapTime
    end
    if self.onLap then self.onLap(car, lapTime, car.lapClean) end
    car.lapClean = true
    if self.mode == "race" and car.lapsDone >= self.laps then
      car.finished = true
      car.finishTime = self.time
      if car.isPlayer then self:onPlayerFinished(car) end
    end
  end
end

-- The car drives its own cool-down lap behind the results.
local function coolDown(self, car)
  car.driver = AI.new(self.track, car, { skill = 0.7 })
  car.input.boost = false
  -- Nobody is left to work a manual gearbox.
  car.input.manual = false
end

-- The first driver here home starts the clock on everyone else.
function Race:onPlayerFinished(car)
  car = car or self.player
  if not self.online and not self.finishGrace then self.finishGrace = FINISH_GRACE end
  coolDown(self, car)
end

-- Another driver has gone. Someone who already took the flag only went home, so
-- their car drives on rather than freezing on the road just past the line.
-- Someone who quit takes their car with them, or it would sit on the road as a
-- wall. They stay in the standings. Returns true if they quit mid-race.
function Race:peerLeft(car)
  if car.finished then
    car.remote = false
    coolDown(self, car)
    return false
  end
  car.retired = true
  car.body:setActive(false)
  for i, other in ipairs(self.cars) do
    if other == car then
      table.remove(self.cars, i)
      break
    end
  end
  self.gone[#self.gone + 1] = car
  return true
end

-- Everyone agrees when the race ends: 25 seconds after the first car home, by
-- the clock they share. Whoever isn't over the line by then didn't finish.
local function firstFinish(self)
  local first
  for _, car in ipairs(self.order) do
    if car.finished and (not first or car.finishTime < first) then first = car.finishTime end
  end
  return first
end

local function allFinished(self)
  for _, car in ipairs(self.cars) do
    if not car.finished and not car.retired then return false end
  end
  return true
end

Race.FINISH_GRACE = FINISH_GRACE
Race.CRASH_SPEED = CRASH_SPEED
Race.WRECK_TIME = WRECK_TIME

function Race:step(dt)
  if self.phase == "countdown" then
    if self.startIn then
      -- The lights follow the shared clock. A game that loaded late joins in
      -- part way through them, and nobody's lights start until everyone's ready.
      local left = self.startIn()
      self.holding = left == nil
      self.timer = left and self.startDelay - left or 0
    else
      self.timer = self.timer + dt
    end
    for _, car in ipairs(self.cars) do
      car.input.throttle, car.input.steer = 0, 0
      car.input.handbrake = false
      -- The clutch is in at the lights, so the pedal only spins the engine.
      car.input.rev = car.driver and car.driver.revs and car.driver:revs(dt) or 0
      -- The brake held with it lights the tyres up on the spot.
      car.input.brake = car.driver and car.driver.brakes and car.driver:brakes() or 0
      car.input.boost = car.driver and car.driver.boostButton and car.driver:boostButton() or false
    end
    if self.timer >= self.startDelay then
      self.phase = "racing"
      self.timer = 0
      self.justStarted = true
      for _, car in ipairs(self.cars) do
        car.input.rev = nil
        if not car.remote then dynamics.launch(car.model) end
      end
    end
  else
    self.time = self.time + dt
    for _, car in ipairs(self.cars) do
      if car.driver and not car.wreck then car.driver:update(car, self, dt) end
    end
  end

  for _, car in ipairs(self.cars) do
    -- A remote car's own game works out its slipstream.
    if not car.remote then slipstream.update(car, self.cars, dt) end
    car:step(dt, self.track)
  end
  world.step(dt)
  for _, car in ipairs(self.cars) do
    car:afterStep()
    self:updateCrash(car, dt)
    if self.track then self:updateProgress(car, dt) end
  end

  if self.track then self:standings() end
  self:resetCones(false)

  if self.finishGrace then
    self.finishGrace = self.finishGrace - dt
    if self.finishGrace <= 0 or allFinished(self) then
      self.phase = "finished"
      -- The other driver here didn't make it in time.
      for _, car in ipairs(self.players) do
        if not car.finished and not car.timedOut then
          car.timedOut = true
          coolDown(self, car)
        end
      end
    end
  end

  if self.online and self.phase == "racing" then
    local first = firstFinish(self)
    self.flagFell = first
    if first and (self.time >= first + FINISH_GRACE or allFinished(self)) then
      self.phase = "finished"
      local player = self.player
      if not player.finished then
        player.timedOut = true
        coolDown(self, player)
      end
    end
  end
end

-- Once a frame in an online race. A slow frame slows the simulation down, and a
-- phone mustn't get a better time by being slow, so the race clock keeps up with
-- the real one. It never runs back, so lap times stay whole.
function Race:syncClock()
  if not self.startIn or self.phase == "countdown" then return end
  local left = self.startIn()
  if left and -left > self.time then self.time = -left end
end

return Race
