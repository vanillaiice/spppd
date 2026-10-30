-- A car in the world: a Box2D chassis driven by the tyre model.
local config = require("src/config")
local dynamics = require("src/sim/dynamics")
local world = require("src/world")

local Car = {}
Car.__index = Car

local M = config.METER

function Car.new(spec, x, y, angle, opts)
  opts = opts or {}
  local self = setmetatable({}, Car)

  self.spec = spec
  self.name = opts.name or spec.name
  self.color = opts.color or spec.color
  self.isPlayer = opts.isPlayer or false
  self.driver = opts.driver
  self.model = dynamics.new(spec, opts.assist)

  local length, width = spec.length * M, spec.width * M
  self.length, self.width = length, width

  self.body = love.physics.newBody(world.physics, x, y, "dynamic")
  self.body:setAngle(angle or 0)
  self.body:setBullet(true)
  self.body:setSleepingAllowed(false)

  -- Chamfered corners stop cars snagging on each other.
  local hl, hw, ch = length / 2, width / 2, width * 0.2
  local shape = love.physics.newPolygonShape(
    hl, -hw + ch, hl - ch, -hw, -hl + ch, -hw, -hl, -hw + ch,
    -hl, hw - ch, -hl + ch, hw, hl - ch, hw, hl, hw - ch
  )
  self.fixture = love.physics.newFixture(self.body, shape, 1)
  self.fixture:setFriction(0.25)
  self.fixture:setRestitution(0.15)
  self.fixture:setCategory(world.CATEGORY_CAR)
  self.fixture:setUserData(self)
  self.body:setMassData(0, 0, spec.mass, spec.inertia * M * M)

  self.input = {
    throttle = 0, brake = 0, steer = 0,
    handbrake = false, boost = false,
    manual = false, shiftUp = false, shiftDown = false,
  }
  self.lowBeam, self.highBeam = false, false

  -- Race progress, maintained by the race logic.
  self.trackIndex = nil
  self.trackS = 0
  self.lateral = 0
  self.distance = 0
  self.ghostTimer = 0

  -- Previous and current pose for render interpolation.
  local a = angle or 0
  self.prevX, self.prevY, self.prevA = x, y, a
  self.curX, self.curY, self.curA = x, y, a
  return self
end

function Car:destroy()
  if self.body and not self.body:isDestroyed() then self.body:destroy() end
end

-- Velocity in m/s: forward, right, world x, world y
function Car:getVelocity()
  local vx, vy = self.body:getLinearVelocity()
  local a = self.body:getAngle()
  local ca, sa = math.cos(a), math.sin(a)
  return (vx * ca + vy * sa) / M, (-vx * sa + vy * ca) / M, vx / M, vy / M
end

function Car:getSpeed()
  local vx, vy = self.body:getLinearVelocity()
  return math.sqrt(vx * vx + vy * vy) / M
end

function Car:getForwardSpeed()
  return (self:getVelocity())
end

function Car:wheelWorldPosition(wheel)
  local x, y = self.body:getPosition()
  local a = self.body:getAngle()
  local ca, sa = math.cos(a), math.sin(a)
  local wx, wy = wheel.x * M, wheel.y * M
  return x + wx * ca - wy * sa, y + wx * sa + wy * ca
end

function Car:updateSurfaces(track)
  local wheels = self.model.wheels
  if not track then
    for i = 1, 4 do wheels[i].surface = "asphalt" end
    return
  end
  for i = 1, 4 do
    local w = wheels[i]
    local x, y = self:wheelWorldPosition(w)
    w.surface = track:surfaceAt(x, y, self.trackIndex)
  end
end

-- One fixed physics step. Forces go on the body; Box2D integrates them.
function Car:step(dt, track)
  self.prevX, self.prevY, self.prevA = self.curX, self.curY, self.curA
  if self.ghostTimer > 0 then
    self.ghostTimer = self.ghostTimer - dt
    if self.ghostTimer <= 0 then self.fixture:setMask() end
  end

  self:updateSurfaces(track)

  -- A remote car's motion comes from the network, not from its tyres.
  if self.remote then return end

  local body = self.body
  local fv, rv = self:getVelocity()
  local fx, fy, mz = dynamics.step(self.model, self.input, fv, rv, body:getAngularVelocity(), dt)

  local a = body:getAngle()
  local ca, sa = math.cos(a), math.sin(a)
  body:applyForce((fx * ca - fy * sa) * M, (fx * sa + fy * ca) * M)
  body:applyTorque(mz * M * M)
end

function Car:afterStep()
  self.curX, self.curY = self.body:getPosition()
  self.curA = self.body:getAngle()
end

-- Pose for drawing, between the last two physics states.
function Car:interpolated(alpha)
  local da = (self.curA - self.prevA + math.pi) % (math.pi * 2) - math.pi
  return self.prevX + (self.curX - self.prevX) * alpha,
    self.prevY + (self.curY - self.prevY) * alpha,
    self.prevA + da * alpha
end

-- Put the car back on the road, briefly passing through other cars.
function Car:teleport(x, y, angle, ghostTime)
  local body = self.body
  body:setPosition(x, y)
  body:setAngle(angle)
  body:setLinearVelocity(0, 0)
  body:setAngularVelocity(0)
  self.prevX, self.prevY, self.prevA = x, y, angle
  self.curX, self.curY, self.curA = x, y, angle
  self.model.ax, self.model.ay = 0, 0
  self.model.steer = 0
  self.model.drift = 0
  self.model.gear = 1
  self.model.reverse = false
  if ghostTime then
    self.ghostTimer = ghostTime
    self.fixture:setMask(world.CATEGORY_CAR)
  end
end

return Car
