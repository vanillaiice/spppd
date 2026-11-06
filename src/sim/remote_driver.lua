-- Moves the other player's car from network updates. Packets arrive 20 times
-- a second, so the car is steered towards where it should be by now.
local dynamics = require("src/sim/dynamics")
local config = require("src/config")

local RemoteDriver = {}
RemoteDriver.__index = RemoteDriver

local MAX_EXTRAPOLATION = 0.25
local SNAP_DISTANCE = 300
local FOLLOW_RATE = 12
local GHOST_HOLD = 0.2  -- seconds, so it outlasts the gap between packets
-- Silent this long, the driver has lost their connection, and their car would
-- sit on the road as a wall. It's a ghost until they're back or gone.
local GONE_GHOST = 1

-- `source()` returns the latest state and its age in seconds, or nil.
function RemoteDriver.new(source)
  return setmetatable({ source = source }, RemoteDriver)
end

function RemoteDriver:update(car, race, dt)
  local state, age = self.source()
  if not state then return end
  age = age or 0
  -- Past this the driver has stopped sending, so don't carry them off the road.
  local stale = age > MAX_EXTRAPOLATION
  local vx, vy = stale and 0 or state.vx, stale and 0 or state.vy

  local body = car.body
  local x, y = body:getPosition()
  local tx = state.x + vx * age
  local ty = state.y + vy * age
  local dx, dy = tx - x, ty - y
  local k = 1 - math.exp(-dt * FOLLOW_RATE)
  if dx * dx + dy * dy > SNAP_DISTANCE * SNAP_DISTANCE then k = 1 end
  body:setPosition(x + dx * k, y + dy * k)
  body:setLinearVelocity(vx, vy)

  local a = body:getAngle()
  local da = (state.a - a + math.pi) % (math.pi * 2) - math.pi
  body:setAngle(a + da * k)
  body:setAngularVelocity(0)

  local model = car.model
  model.steer, model.rpm, model.throttle, model.brake = state.steer, state.rpm, state.throttle, state.brake
  model.gear = math.max(1, state.gear)
  model.reverse = state.reverse or false
  model.boostState = state.boost and "active" or "ready"
  for _, wheel in ipairs(model.wheels) do wheel.slide = state.slide or 0 end
  dynamics.showBurnout(model, math.sqrt(vx * vx + vy * vy) / config.METER)
  car.horn = state.horn or false
  -- Their game put them back on the road, so they're a ghost there. Solid here,
  -- they'd be a stopped car on the racing line that only this driver can hit.
  if state.ghost and not stale or age > GONE_GHOST then car:ghost(GHOST_HOLD) end
  -- Wrecked on their screen: only for the smoke and the dent, as their game
  -- judges the wreck itself.
  car.remoteWreck = state.wreck and not stale or false
  if state.lowBeam ~= nil then car.lowBeam, car.highBeam = state.lowBeam, state.highBeam end

  -- Their own game counts their laps. A copy worked out from a smoothed position
  -- here would disagree with it, and each screen would show a different result.
  if state.distance then
    car.distance = state.distance
    car.lapsDone = math.max(car.lapsDone, math.floor(state.distance / race.track.length))
  end
  if state.finish and state.finish > 0 and not car.finished then
    car.finished = true
    car.finishTime = state.finish
  end
end

return RemoteDriver
