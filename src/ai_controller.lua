-- AI driver. Follows the track's racing line through the same input channel
-- as a human, so it obeys exactly the same physics as the player.
local config = require("src/config")
local dynamics = require("src/sim/dynamics")

local AI = {}
AI.__index = AI

local M = config.METER
local abs, min, max, atan, cos, sin = math.abs, math.min, math.max, math.atan, math.cos, math.sin

function AI.new(track, car, opts)
  opts = opts or {}
  local self = setmetatable({}, AI)
  self.track = track
  self.skill = opts.skill or 1.0
  self.digital = opts.digital or false  -- behave like a keyboard player
  self.reaction = opts.reaction or 0
  self.offset = 0
  self.wander = 0
  self.wanderT = 0
  self.stuckTime = 0
  self.reverseTime = 0
  self.rng = opts.rng
  self.pending = nil
  self.pendingT = 0

  local spec = car.spec
  local top = min(95, dynamics.gearingTopSpeed(spec))
  local accel = dynamics.peakPower(spec) / (spec.mass * 28)
  local mu = spec.grip * 0.92 * self.skill
  self.profile = track:speedProfile({
    mu = mu,
    vmax = top,
    brake = (opts.brakeG or 0.72) * spec.grip * config.GRAVITY,
    accel = accel,
  })
  return self
end

-- Look for traffic ahead and pick a side to pass on.
function AI:planOffset(car, race, dt)
  local target = 0
  local px, py = car.body:getPosition()
  local heading = car.body:getAngle()
  local ca, sa = cos(heading), sin(heading)
  for _, other in ipairs(race.cars) do
    if other ~= car then
      local ox, oy = other.body:getPosition()
      local dx, dy = (ox - px) / M, (oy - py) / M
      local ahead = dx * ca + dy * sa
      local side = -dx * sa + dy * ca
      if ahead > -2 and ahead < 22 and abs(side) < 4 then
        local push = (1 - max(0, ahead) / 22)
        local away = side >= 0 and -1 or 1
        if abs(side) < 0.4 then
          -- Dead ahead: pass on the side with more road.
          away = car.lateral > 0 and -1 or 1
        end
        target = target + away * push * 4.2
      end
    end
  end
  target = max(-4.5, min(4.5, target))
  self.offset = self.offset + (target - self.offset) * (1 - math.exp(-dt * 2.5))
end

function AI:recover(car, dt)
  local speed = car:getSpeed()
  local input = car.input
  if self.reverseTime > 0 then
    self.reverseTime = self.reverseTime - dt
    input.throttle, input.brake = 0, 1
    input.steer = -self.lastSteer
    return true
  end
  if speed < 1.0 and car.input.throttle > 0.3 then
    self.stuckTime = self.stuckTime + dt
  else
    self.stuckTime = max(0, self.stuckTime - dt * 2)
  end
  if self.stuckTime > 1.2 then
    self.stuckTime = 0
    self.reverseTime = 1.4
    self.retries = (self.retries or 0) + 1
  end
  return false
end

function AI:update(car, race, dt)
  local input = car.input
  local track = self.track
  local samples, n = track.samples, track.count
  local index = car.trackIndex or 1

  input.handbrake, input.boost = false, false
  input.shiftUp, input.shiftDown = false, false
  if self:recover(car, dt) then return end
  if (self.retries or 0) >= 3 then
    self.retries = 0
    race:respawn(car)
    return
  end
  if self.reverseTime <= 0 and car:getSpeed() > 6 then self.retries = 0 end

  self:planOffset(car, race, dt)

  local speed = car:getSpeed()
  local look = max(9, min(46, speed * 0.62 + 5))
  local steps = math.floor(look / config.SAMPLE_SPACING + 0.5)
  local target = samples[(index + steps - 1) % n + 1]
  local tx = target.lineX + target.nx * self.offset * M
  local ty = target.lineY + target.ny * self.offset * M

  local x, y = car.body:getPosition()
  local a = car.body:getAngle()
  local ca, sa = cos(a), sin(a)
  local dx, dy = (tx - x) / M, (ty - y) / M
  local fx = dx * ca + dy * sa
  local fy = -dx * sa + dy * ca
  local d2 = max(1, fx * fx + fy * fy)

  local model = car.model
  local wanted = atan(2 * car.spec.wheelbase * fy / d2)
  local vf, vr = car:getVelocity()
  local yaw = car.body:getAngularVelocity()
  local travel = 0
  if speed > 2 then
    travel = math.atan2(vr + yaw * model.a, max(abs(vf), 2)) * (vf >= 0 and 1 or -1)
  end
  local correction = wanted - travel * model.assist.caster
  local steerRange = max(0.05, dynamics.steerLimit(model, speed))
  local steer = max(-1, min(1, correction / steerRange))
  self.lastSteer = steer

  -- Target speed comes from a little further up the road.
  local vt = self.profile[index] or 30
  local lookSteps = math.floor((speed * 0.25) / config.SAMPLE_SPACING)
  for k = 1, lookSteps do
    local v = self.profile[(index + k - 1) % n + 1]
    if v < vt then vt = v end
  end
  vt = vt * self.skill
  if abs(self.offset) > 0.5 then vt = vt * 0.97 end

  local err = vt - speed
  local throttle = max(0, min(1, err * 0.45 + 0.1))
  local brake = max(0, min(1, -err * 0.3))
  if brake > 0.05 then throttle = 0 end

  -- Back off on loose ground and when the car is already sliding.
  local onLoose = model.wheels[1].surface == "grass" or model.wheels[1].surface == "gravel"
  if onLoose then throttle = min(throttle, 0.6) end
  if model.slip > 0.5 then throttle = throttle * 0.6 end

  -- Being pointed the wrong way needs more than the racing line can offer.
  if fx < 0 and speed < 8 then
    steer = fy >= 0 and 1 or -1
    throttle = 0.5
  end

  if self.digital then
    input.keyboard = true
    steer = abs(steer) > 0.16 and (steer > 0 and 1 or -1) or 0
    throttle = throttle > 0.35 and 1 or 0
    brake = brake > 0.2 and 1 or 0
  end

  if self.reaction > 0 then
    -- Hold each decision briefly, like a human reaction time.
    self.pendingT = self.pendingT - dt
    if self.pendingT <= 0 or not self.pending then
      self.pending = { steer = steer, throttle = throttle, brake = brake }
      self.pendingT = self.reaction
    end
    steer, throttle, brake = self.pending.steer, self.pending.throttle, self.pending.brake
  end

  input.steer, input.throttle, input.brake = steer, throttle, brake
end

return AI
