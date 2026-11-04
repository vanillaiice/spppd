-- The Box2D world: barriers, collision filtering and impact reporting.
-- Tyres and engines live in src/sim/dynamics; Box2D only handles contact.
local config = require("src/config")

local M = config.METER
local PROP_EVENT = 15  -- N s: a car brushing a cone barely counts

local world = {
  CATEGORY_BARRIER = 1,
  CATEGORY_CAR = 2,
  CATEGORY_PROP = 4,
  physics = nil,
  barriers = {},
  events = {},
}

-- Impacts are only recorded here; effects and sound read them after the step.
-- Something loose a car can knock about, like a cone. It can't wreck a car, dent
-- it or scrape it: it's only an event, for the knock and the dust.
local function propHit(da, db, contact, impulse)
  local car = (da and not da.prop and da) or (db and not db.prop and db) or nil
  if not car or impulse < PROP_EVENT * M or #world.events >= 16 then return end
  local x, y = contact:getPositions()
  if not x then return end
  local nx, ny = contact:getNormal()
  world.events[#world.events + 1] = {
    x = x, y = y, nx = nx, ny = ny, impulse = impulse / M, car = car, prop = true,
  }
end

local function postSolve(a, b, contact, normal1, tangent1, normal2, tangent2)
  local impulse = (normal1 or 0) + (normal2 or 0)
  local carA, carB = a:getUserData(), b:getUserData()
  if (carA and carA.prop) or (carB and carB.prop) then
    propHit(carA, carB, contact, impulse)
    return
  end
  -- Touching at all counts, for the sound of dragging along a wall: that's far
  -- too gentle to be an event, and goes on for as long as the car stays on it.
  if carA then carA.scraped = true end
  if carB then carB.scraped = true end
  -- A crash is judged on all of a hit, so this comes before the small ones are
  -- dropped. The event list has a cap, and a hit can be spread over contacts.
  if carA and carB then
    carA.touchedCar, carB.touchedCar = true, true
  elseif carA or carB then
    local car = carA or carB
    car.fenceImpulse = car.fenceImpulse + impulse
    -- Where the hardest hit of the step was, and which way is out, so a wreck
    -- with no road to go back to can be put back clear of what it hit.
    if impulse > (car.fencePeak or 0) then
      local x, y = contact:getPositions()
      local nx, ny = contact:getNormal()
      -- The normal runs from the first fixture to the second.
      if carA then nx, ny = -nx, -ny end
      car.fencePeak = impulse
      car.fenceX, car.fenceY = x or car.body:getX(), y or car.body:getY()
      car.fenceNx, car.fenceNy = nx, ny
    end
  end
  if impulse < 200 * M then return end
  if #world.events >= 16 then return end
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

local function staticFixture(shape)
  local body = love.physics.newBody(world.physics, 0, 0, "static")
  local fixture = love.physics.newFixture(body, shape)
  fixture:setFriction(0.15)
  fixture:setRestitution(0.2)
  fixture:setCategory(world.CATEGORY_BARRIER)
  world.barriers[#world.barriers + 1] = body
  return body
end

local function addBarrier(points, open)
  if #points < (open and 2 or 3) then return end
  local coords = {}
  local last
  for _, p in ipairs(points) do
    if not last or math.abs(p.x - last.x) + math.abs(p.y - last.y) > 1 then
      coords[#coords + 1] = p.x
      coords[#coords + 1] = p.y
      last = p
    end
  end
  staticFixture(love.physics.newChainShape(not open, coords))
end

-- Freestyle's playground. Returns the cones, which a race puts back in place.
function world.addLot(layout, coneRadius, coneMass)
  addBarrier(layout.wall, true)
  for _, b in ipairs(layout.blocks) do
    staticFixture(love.physics.newPolygonShape(b.x, b.y, b.x + b.w, b.y, b.x + b.w, b.y + b.h, b.x, b.y + b.h))
  end
  for _, p in ipairs(layout.pillars) do
    local body = staticFixture(love.physics.newCircleShape(p.r))
    body:setPosition(p.x, p.y)
  end
  local cones = {}
  for _, c in ipairs(layout.cones) do
    local body = love.physics.newBody(world.physics, c.x, c.y, "dynamic")
    local fixture = love.physics.newFixture(body, love.physics.newCircleShape(coneRadius), 1)
    fixture:setFriction(0.4)
    fixture:setRestitution(0.3)
    fixture:setCategory(world.CATEGORY_PROP)
    fixture:setUserData({ prop = true })
    body:setMass(coneMass)
    body:setLinearDamping(2.5)
    body:setAngularDamping(4)
    cones[#cones + 1] = { body = body, homeX = c.x, homeY = c.y }
  end
  return cones
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
