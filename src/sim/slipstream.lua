-- Slipstream: a car punches a hole in the air, and a car following it through
-- that hole has less drag to fight. This works out how far into a wake each
-- car is; the tyre model turns that into speed.
local config = require("src/config")

local slipstream = {}

local M = config.METER
local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max

local MIN_SPEED = 18     -- m/s; below this there is no wake worth having
local MIN_GAP = 3        -- metres behind the other car, measured centre to centre
local RANGE = 32         -- metres; the wake has gone by here
local FULL_RANGE = 0.5   -- the share of RANGE that gives the full effect
local NEAR_WIDTH = 1.6   -- half width of the wake right behind the car, metres
local FAR_WIDTH = 3.2    -- and at the far end, where it has spread out
local SAME_WAY = 0.8     -- cos of the angle two cars can differ by and still share air
local BUILD_RATE = 0.5   -- per second, so a full tow takes 2 s of following to arrive
local FADE_RATE = 0.9    -- per second; the slow fade is what makes a slingshot

-- How far `car` sits inside the wake of `other`, 0..1.
function slipstream.wake(car, other)
  local _, _, ovx, ovy = other:getVelocity()
  local speed = sqrt(ovx * ovx + ovy * ovy)
  if speed < MIN_SPEED then return 0 end

  -- The wake trails the way the car is travelling, not the way it is pointed.
  local ux, uy = ovx / speed, ovy / speed
  local _, _, vx, vy = car:getVelocity()
  local own = sqrt(vx * vx + vy * vy)
  if own < MIN_SPEED or vx * ux + vy * uy < own * SAME_WAY then return 0 end

  local x, y = car.body:getPosition()
  local ox, oy = other.body:getPosition()
  local dx, dy = (x - ox) / M, (y - oy) / M
  local behind = -(dx * ux + dy * uy)
  if behind < MIN_GAP or behind > RANGE then return 0 end

  local along = behind / RANGE
  local width = NEAR_WIDTH + (FAR_WIDTH - NEAR_WIDTH) * along
  local side = abs(-dx * uy + dy * ux)
  if side >= width then return 0 end

  local reach = min(1, (1 - along) / (1 - FULL_RANGE))
  local centred = min(1, (1 - side / width) * 2)
  return reach * centred
end

-- Move a car's slipstream towards the strongest wake it is in.
function slipstream.update(car, cars, dt)
  local target = 0
  for _, other in ipairs(cars) do
    if other ~= car then target = max(target, slipstream.wake(car, other)) end
  end
  local model = car.model
  local rate = target > model.slipstream and BUILD_RATE or FADE_RATE
  model.slipstream = model.slipstream + max(-rate * dt, min(rate * dt, target - model.slipstream))
end

return slipstream
