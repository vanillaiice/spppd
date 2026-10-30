-- Race rules: grid, start lights, laps, standings and finishing. Steps at a
-- fixed rate and draws nothing, so whole races can run headless in tests.
local config = require("src/config")
local Car = require("src/entities/car")
local AI = require("src/ai_controller")
local dynamics = require("src/sim/dynamics")
local RemoteDriver = require("src/sim/remote_driver")
local garage = require("src/entities/garage")
local world = require("src/world")

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

function Race.new(opts)
  local self = setmetatable({}, Race)
  self.mode = opts.mode or "race"    -- race | trial | freestyle
  self.track = opts.track
  self.laps = opts.laps or 3
  self.phase = "countdown"
  self.timer = 0
  self.time = 0
  self.startDelay = opts.startDelay or 3.6
  self.seed = opts.seed or os.time()
  self.rng = love.math.newRandomGenerator(self.seed)
  self.cars = {}
  self.onLap = opts.onLap

  world.load(self.track)

  local spec = opts.spec or garage[1]
  local online = opts.online
  -- Tiers change how much grip a car has, so an online race has to share one.
  local handling = online and dynamics.DEFAULT_ASSIST or opts.assist or dynamics.DEFAULT_ASSIST
  self.handling = handling
  local slot = 1
  if self.mode == "race" and self.track then slot = online and online.slot or (opts.opponents or 0) + 1 end
  local x, y, angle, index = 0, 0, opts.spawnAngle or -math.pi / 2, nil
  if self.track then x, y, angle, index = self.track:gridSlot(slot) end

  self.player = Car.new(spec, x, y, angle, {
    isPlayer = true,
    color = opts.color,
    assist = handling,
    name = opts.playerName or "YOU",
  })
  self.player.input.manual = opts.manualGearbox or false
  self.player.trackIndex = index
  self.cars[1] = self.player

  if online then
    local peerSlot = online.slot == 1 and 2 or 1
    local px, py, pa, pi = self.track:gridSlot(peerSlot)
    local peer = Car.new(online.peerSpec, px, py, pa, { name = "RIVAL", color = online.peerColor })
    peer.remote = true
    peer.driver = RemoteDriver.new(online.state)
    peer.trackIndex = pi
    self.cars[2] = peer
  elseif self.mode == "race" and self.track then
    self:spawnOpponents(opts, slot)
  end

  for _, car in ipairs(self.cars) do self:initProgress(car) end
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
    car.driver = AI.new(self.track, car, { skill = skill })
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
  self.cars = {}
  world.destroy()
end

function Race:currentLap(car)
  return math.min(self.laps, car.lapsDone + 1)
end

-- Where the car sits in the full race distance, for standings.
local function rank(a, b)
  if a.finished and b.finished then return a.finishTime < b.finishTime end
  if a.finished ~= b.finished then return a.finished end
  return a.distance > b.distance
end

function Race:standings()
  local list = {}
  for i, car in ipairs(self.cars) do list[i] = car end
  table.sort(list, rank)
  for i, car in ipairs(list) do car.place = i end
  return list
end

function Race:respawn(car)
  local track = self.track
  if not track then
    car:teleport(0, 0, -math.pi / 2)
    return
  end
  local index = car.trackIndex or 1
  local s = track.samples[(index + 1) % track.count + 1]
  car:teleport(s.lineX, s.lineY, math.atan2(s.ty, s.tx), 2.5)
  car.trackIndex = s.index
  car.lapClean = false
end

function Race:updateProgress(car, dt)
  local track = self.track
  local x, y = car.body:getPosition()
  local index, s, lateral, off = track:locate(x, y, car.trackIndex)
  local previous = car.trackS
  car.trackIndex, car.trackS, car.lateral = index, s, lateral

  local delta = s - previous
  local length = track.length
  if delta < -length / 2 then delta = delta + length
  elseif delta > length / 2 then delta = delta - length end

  -- A big jump means the car left the road and rejoined somewhere else:
  -- the skipped distance doesn't count, so cutting the track never pays.
  if abs(delta) < SHORTCUT_JUMP then
    car.distance = car.distance + delta
  else
    car.lapClean = false
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
  if car.offTrack and self.phase == "racing" then car.lapClean = false end

  -- Wrong way warning
  local sample = track.samples[index]
  local vx, vy = car.body:getLinearVelocity()
  local dot = (vx * sample.tx + vy * sample.ty) / M
  if dot < -4 then
    car.wrongWayTime = car.wrongWayTime + dt
  else
    car.wrongWayTime = 0
  end
  car.wrongWay = car.wrongWayTime > WRONG_WAY_TIME

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
      if car.isPlayer then self:onPlayerFinished() end
    end
  end
end

function Race:onPlayerFinished()
  self.finishGrace = FINISH_GRACE
  -- The car drives its own cool-down lap behind the results.
  local car = self.player
  car.driver = AI.new(self.track, car, { skill = 0.7 })
  car.input.boost = false
end

local function allFinished(self)
  for _, car in ipairs(self.cars) do
    if not car.finished then return false end
  end
  return true
end

function Race:step(dt)
  if self.phase == "countdown" then
    self.timer = self.timer + dt
    for _, car in ipairs(self.cars) do
      car.input.throttle, car.input.steer = 0, 0
      car.input.handbrake = false
    end
    if self.timer >= self.startDelay then
      self.phase = "racing"
      self.timer = 0
      self.justStarted = true
    end
  else
    self.time = self.time + dt
    for _, car in ipairs(self.cars) do
      if car.driver then car.driver:update(car, self, dt) end
    end
  end

  for _, car in ipairs(self.cars) do car:step(dt, self.track) end
  world.step(dt)
  for _, car in ipairs(self.cars) do
    car:afterStep()
    if self.track then self:updateProgress(car, dt) end
  end

  if self.track then self:standings() end

  if self.finishGrace then
    self.finishGrace = self.finishGrace - dt
    if self.finishGrace <= 0 or allFinished(self) then
      self.phase = "finished"
    end
  end
end

return Race
