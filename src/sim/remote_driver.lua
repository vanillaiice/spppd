-- Moves the other player's car from network updates. Packets arrive 20 times
-- a second, so the car is steered towards where it should be by now.
local RemoteDriver = {}
RemoteDriver.__index = RemoteDriver

local MAX_EXTRAPOLATION = 0.25
local SNAP_DISTANCE = 300
local FOLLOW_RATE = 12

-- `source()` returns the latest state and its age in seconds, or nil.
function RemoteDriver.new(source)
  return setmetatable({ source = source }, RemoteDriver)
end

function RemoteDriver:update(car, race, dt)
  local state, age = self.source()
  if not state then return end
  age = math.min(age or 0, MAX_EXTRAPOLATION)

  local body = car.body
  local x, y = body:getPosition()
  local tx = state.x + state.vx * age
  local ty = state.y + state.vy * age
  local dx, dy = tx - x, ty - y
  local k = 1 - math.exp(-dt * FOLLOW_RATE)
  if dx * dx + dy * dy > SNAP_DISTANCE * SNAP_DISTANCE then k = 1 end
  body:setPosition(x + dx * k, y + dy * k)
  body:setLinearVelocity(state.vx, state.vy)

  local a = body:getAngle()
  local da = (state.a - a + math.pi) % (math.pi * 2) - math.pi
  body:setAngle(a + da * k)
  body:setAngularVelocity(0)

  local model = car.model
  model.steer, model.rpm, model.throttle, model.brake = state.steer, state.rpm, state.throttle, state.brake
  model.gear = math.max(1, state.gear)
  car.horn = state.horn == 1
end

return RemoteDriver
