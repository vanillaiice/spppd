-- The Box2D world: barriers, collision filtering and impact reporting.
-- Tyres and engines live in src/sim/dynamics; Box2D only handles contact.
local config = require("src/config")

local M = config.METER

local world = {
  CATEGORY_BARRIER = 1,
  CATEGORY_CAR = 2,
  physics = nil,
  barriers = {},
  events = {},
}

local function firstCar(a, b)
  local ca, cb = a:getUserData(), b:getUserData()
  return ca, cb
end

-- Impacts are only recorded here; effects and sound read them after the step.
local function postSolve(a, b, contact, normal1, tangent1, normal2, tangent2)
  local impulse = (normal1 or 0) + (normal2 or 0)
  if impulse < 200 * M then return end
  if #world.events >= 16 then return end
  local carA, carB = firstCar(a, b)
  local x, y = contact:getPositions()
  if not x then return end
  local nx, ny = contact:getNormal()
  world.events[#world.events + 1] = {
    x = x, y = y, nx = nx, ny = ny,
    impulse = impulse / M,
    carA = carA, carB = carB,
    barrier = not (carA and carB),
  }
end

local function addBarrier(points)
  if #points < 3 then return end
  local coords = {}
  local last
  for _, p in ipairs(points) do
    if not last or math.abs(p.x - last.x) + math.abs(p.y - last.y) > 1 then
      coords[#coords + 1] = p.x
      coords[#coords + 1] = p.y
      last = p
    end
  end
  local body = love.physics.newBody(world.physics, 0, 0, "static")
  local shape = love.physics.newChainShape(true, coords)
  local fixture = love.physics.newFixture(body, shape)
  fixture:setFriction(0.15)
  fixture:setRestitution(0.2)
  fixture:setCategory(world.CATEGORY_BARRIER)
  world.barriers[#world.barriers + 1] = body
end

function world.load(track)
  if world.physics then world.physics:destroy() end
  love.physics.setMeter(M)
  world.physics = love.physics.newWorld(0, 0, true)
  world.physics:setCallbacks(nil, nil, nil, postSolve)
  world.barriers = {}
  world.events = {}
  if track then
    addBarrier(track.barrierL)
    addBarrier(track.barrierR)
  end
end

function world.step(dt)
  world.physics:update(dt, 8, 3)
end

function world.drainEvents()
  local events = world.events
  world.events = {}
  return events
end

function world.destroy()
  if world.physics then
    world.physics:destroy()
    world.physics = nil
  end
end

return world
