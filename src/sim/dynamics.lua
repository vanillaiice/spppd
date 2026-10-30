-- Four-wheel vehicle model in SI units. Given the chassis velocity it works
-- out tyre forces, and returns the net force and yaw moment in the body frame.
-- It knows nothing about Box2D or LÖVE, so it can be tested on its own.
--
-- Body frame: +x forward, +y to the driver's right, +yaw clockwise on screen.
-- Wheels: 1 front-left, 2 front-right, 3 rear-left, 4 rear-right.
local config = require("src/config")

local dynamics = {}

local G = config.GRAVITY
local abs, sqrt, atan, atan2, sin, cos, tan, min, max =
  math.abs, math.sqrt, math.atan, math.atan2, math.sin, math.cos, math.tan, math.min, math.max
local RPM_PER_RADS = 60 / (2 * math.pi)

-- Slip-angle curve shape (Pacejka). C sets how much grip survives past the
-- peak: sin(C * pi/2) = 0.86 here, so a slide is recoverable but not free.
local TYRE_C = 1.35
local TYRE_B_PEAK = math.tan(math.pi / (2 * TYRE_C))
local MIN_SLIP_SPEED = 2.0
local LOAD_SENSITIVITY = 0.09
local LOAD_LAG = 0.07
local KEY_STEER_RATE = 7.0      -- units/s at a standstill
local KEY_STEER_FADE = 22       -- speed (m/s) at which that rate halves
local KEY_STEER_RELEASE = 9.0
local REVERSE_DELAY = 0.25      -- hold the brake this long at a stop to back up
local REVERSE_THROTTLE = 0.6
local REVERSE_TOP_SPEED = 11

dynamics.SURFACES = {
  asphalt = { grip = 1.00, roll = 0.014, drag = 0.0 },
  kerb    = { grip = 0.90, roll = 0.020, drag = 0.0 },
  grass   = { grip = 0.48, roll = 0.070, drag = 0.022, loose = true },
  gravel  = { grip = 0.42, roll = 0.180, drag = 0.060, loose = true },
}

-- Driver aids. `steer` is how strongly the wheels are held at the tyre's
-- peak slip angle, `caster` how far they self-align towards the direction of
-- travel. Both exist on real cars; turning them down is what makes SIM hard.
dynamics.ASSISTS = {
  full  = { tc = 1.0, abs = 1.0, esc = 1.0, steer = 1.0, caster = 0.85 },
  sport = { tc = 0.8, abs = 1.0, esc = 0.5, steer = 0.9, caster = 0.75 },
  sim   = { tc = 0.0, abs = 0.0, esc = 0.0, steer = 0.0, caster = 0.35 },
}

-- Engine torque shape over rpm / redline.
local TORQUE_CURVE = {
  { 0.00, 0.55 }, { 0.20, 0.72 }, { 0.40, 0.92 }, { 0.60, 1.00 },
  { 0.80, 0.97 }, { 0.95, 0.86 }, { 1.05, 0.62 },
}

local function torqueShape(ratio)
  if ratio <= TORQUE_CURVE[1][1] then return TORQUE_CURVE[1][2] end
  for i = 1, #TORQUE_CURVE - 1 do
    local a, b = TORQUE_CURVE[i], TORQUE_CURVE[i + 1]
    if ratio <= b[1] then
      return a[2] + (b[2] - a[2]) * (ratio - a[1]) / (b[1] - a[1])
    end
  end
  return TORQUE_CURVE[#TORQUE_CURVE][2]
end

function dynamics.new(spec, assist)
  local a = spec.wheelbase * (1 - spec.weightFront)
  local b = spec.wheelbase * spec.weightFront
  local t = spec.track / 2
  local c = {
    spec = spec,
    assist = dynamics.ASSISTS[assist or "sport"] or dynamics.ASSISTS.sport,
    a = a, b = b,
    peakSlip = spec.peakSlip or 0.15,
    tyreB = TYRE_B_PEAK / (spec.peakSlip or 0.15),

    steer = 0,
    steerInput = 0,
    gear = 1,
    reverse = false,
    rpm = spec.idleRpm,
    shiftTimer = 0,
    shiftCooldown = 0,
    clutch = 0,
    stoppedOnBrake = 0,
    throttle = 0,
    brake = 0,
    handbrake = false,
    ax = 0, ay = 0,
    slip = 0,
    beta = 0,
    tcActive = 0,
    absActive = 0,
    escActive = 0,

    boostState = "ready",
    boostTimer = 0,
    boostCooldown = 0,

    wheels = {
      { x = a, y = -t, front = true, driven = spec.drive ~= "RWD" },
      { x = a, y = t, front = true, driven = spec.drive ~= "RWD" },
      { x = -b, y = -t, front = false, driven = spec.drive ~= "FWD" },
      { x = -b, y = t, front = false, driven = spec.drive ~= "FWD" },
    },
  }
  for _, w in ipairs(c.wheels) do
    w.surface = "asphalt"
    w.fz = spec.mass * G / 4
    w.alpha = 0
    w.slide = 0     -- 0..1 how far past the limit this tyre is
    w.spin = 0      -- longitudinal slip speed, m/s (+ wheelspin, - lockup)
    w.fx = 0
    w.fy = 0
    w.vx = 0
    w.vy = 0
  end

  local driven = 0
  for _, w in ipairs(c.wheels) do
    if w.driven then driven = driven + 1 end
  end
  c.drivenCount = driven

  -- Handy derived numbers for the HUD and the AI.
  c.maxPower = dynamics.peakPower(spec)
  return c
end

function dynamics.peakPower(spec)
  local best = 0
  for ratio = 0.3, 1.0, 0.02 do
    local rpm = ratio * spec.redline
    best = max(best, spec.peakTorque * torqueShape(ratio) * rpm / RPM_PER_RADS)
  end
  return best
end

-- Top speed in m/s if a gear pulls hard enough; used by the AI and the menus.
function dynamics.gearingTopSpeed(spec)
  local top = spec.gears[#spec.gears]
  return spec.redline / RPM_PER_RADS * spec.wheelRadius / (top * spec.finalDrive)
end

-- Steering --------------------------------------------------------------

-- The steering angle a full input asks for at this speed. With assists on
-- that is the angle that puts the front tyres right at peak grip.
function dynamics.steerLimit(c, speed)
  local spec = c.spec
  local lock = spec.steerLock
  local limit = lock
  if speed > 3 then
    local turnIn = atan(spec.wheelbase * spec.grip * G / (speed * speed)) + c.peakSlip * 0.9
    limit = min(lock, turnIn)
  end
  return lock + (limit - lock) * c.assist.steer
end

-- A key press is all-or-nothing, so digital steering winds on over time: a
-- tap at speed moves the wheel a little, holding the key takes it to the limit.
local function filterKeyboardSteer(c, wanted, speed, dt)
  local current = c.steerInput
  local rate
  if wanted == 0 or wanted * current < 0 then
    rate = KEY_STEER_RELEASE
  else
    rate = KEY_STEER_RATE / (1 + speed / KEY_STEER_FADE)
  end
  local delta = max(-rate * dt, min(rate * dt, wanted - current))
  c.steerInput = current + delta
  return c.steerInput
end

local function updateSteering(c, input, vx, vy, r, dt)
  local spec = c.spec
  local assist = c.assist
  local speed = sqrt(vx * vx + vy * vy)
  local lock = spec.steerLock
  local maxAngle = dynamics.steerLimit(c, speed)
  local steerInput = input.steer
  if input.keyboard then
    steerInput = filterKeyboardSteer(c, steerInput, speed, dt)
  else
    c.steerInput = steerInput
  end

  -- Direction of travel at the front axle, relative to the chassis. Tyres
  -- pull the steering towards this, which is what catches a slide.
  local travel = 0
  if speed > 2 then
    travel = atan2(vy + r * c.a, max(abs(vx), 2)) * (vx >= 0 and 1 or -1)
  end
  local target = steerInput * maxAngle + travel * assist.caster
  target = max(-lock, min(lock, target))

  local rate = spec.steerSpeed / (1 + speed * 0.018)
  local delta = target - c.steer
  local maxStep = rate * dt
  if abs(steerInput) < 0.01 then maxStep = maxStep * 1.6 end
  if delta > maxStep then delta = maxStep elseif delta < -maxStep then delta = -maxStep end
  c.steer = c.steer + delta
end

-- Powertrain ------------------------------------------------------------

local function updateBoost(c, input, dt)
  local spec = c.spec
  if c.boostState == "ready" then
    if input.boost then
      c.boostState = "active"
      c.boostTimer = spec.boostTime
    end
  elseif c.boostState == "active" then
    c.boostTimer = c.boostTimer - dt
    if c.boostTimer <= 0 then
      c.boostState = "cooldown"
      c.boostCooldown = spec.boostCooldown
    end
  else
    c.boostCooldown = c.boostCooldown - dt
    if c.boostCooldown <= 0 then c.boostState = "ready" end
  end
end

-- Turn "accelerate / brake" pedals into drive and brake demands, handling
-- the shift into reverse when the car is stopped and the brake is held.
local function resolvePedals(c, input, vx, dt)
  local throttle, brake = input.throttle, input.brake
  if c.reverse then
    if throttle > 0.05 then
      c.reverse = false
    elseif vx < -0.5 or brake > 0.05 then
      return brake * REVERSE_THROTTLE, 0
    else
      return 0, 0
    end
  elseif brake > 0.05 and throttle < 0.05 and vx < 0.8 then
    c.stoppedOnBrake = c.stoppedOnBrake + dt
    if c.stoppedOnBrake > REVERSE_DELAY then
      c.reverse = true
      c.stoppedOnBrake = 0
      return brake * REVERSE_THROTTLE, 0
    end
    return 0, brake
  else
    c.stoppedOnBrake = 0
  end
  return throttle, brake
end

local function updateGearbox(c, input, wheelSpeed, dt)
  local spec = c.spec
  c.shiftTimer = max(0, c.shiftTimer - dt)
  c.shiftCooldown = max(0, c.shiftCooldown - dt)
  if c.reverse then
    c.gear = 1
    return
  end

  local function rpmIn(gear)
    return abs(wheelSpeed) / spec.wheelRadius * spec.gears[gear] * spec.finalDrive * RPM_PER_RADS
  end

  if input.manual then
    if input.shiftUp and c.gear < #spec.gears and c.shiftTimer == 0 then
      c.gear = c.gear + 1
      c.shiftTimer = spec.shiftTime
    elseif input.shiftDown and c.gear > 1 and c.shiftTimer == 0 then
      c.gear = c.gear - 1
      c.shiftTimer = spec.shiftTime
    end
    return
  end

  if c.shiftCooldown > 0 then return end
  local upAt = spec.redline * 0.965
  if c.gear < #spec.gears and rpmIn(c.gear) > upAt then
    c.gear = c.gear + 1
    c.shiftTimer = spec.shiftTime
    c.shiftCooldown = 0.45
  elseif c.gear > 1 then
    -- Drop a gear as soon as the lower one sits below the upshift point,
    -- with more eagerness under load so the car pulls out of corners.
    local downAt = spec.redline * (0.62 + 0.18 * c.throttle)
    if rpmIn(c.gear - 1) < downAt then
      c.gear = c.gear - 1
      c.shiftTimer = spec.shiftTime * 0.7
      c.shiftCooldown = 0.3
    end
  end
end

-- Returns the total drive force at the wheels (N), signed for direction.
local function driveForce(c, pedal, wheelSpeed, dt)
  local spec = c.spec
  local ratio = c.reverse and spec.reverseGear or spec.gears[c.gear]
  ratio = ratio * spec.finalDrive

  local wheelOmega = abs(wheelSpeed) / spec.wheelRadius
  local coupled = wheelOmega * ratio * RPM_PER_RADS

  -- Clutch slips off the line so the engine stays in its power band.
  local launch = spec.idleRpm + pedal * (spec.redline * 0.48 - spec.idleRpm)
  local target = max(coupled, launch)
  local follow = 1 - math.exp(-dt * 14)
  c.rpm = c.rpm + (target - c.rpm) * follow
  c.clutch = coupled < launch and 1 - coupled / launch or 0

  if c.shiftTimer > 0 then return 0 end

  local rpm = max(c.rpm, spec.idleRpm)
  local torque = spec.peakTorque * torqueShape(rpm / spec.redline) * pedal
  if c.boostState == "active" then
    torque = torque + spec.boostPower / (rpm / RPM_PER_RADS) * max(pedal, 0.4)
  end
  if rpm > spec.redline * 1.02 then torque = 0 end
  if c.reverse and abs(wheelSpeed) > REVERSE_TOP_SPEED then torque = 0 end

  local force = torque * ratio * spec.drivelineEfficiency / spec.wheelRadius
  return c.reverse and -force or force
end

-- Main step -------------------------------------------------------------

function dynamics.step(c, input, vx, vy, r, dt)
  local spec = c.spec
  local assist = c.assist
  local wheels = c.wheels

  updateBoost(c, input, dt)
  updateSteering(c, input, vx, vy, r, dt)

  local pedal, brakeInput = resolvePedals(c, input, vx, dt)
  c.throttle, c.brake, c.handbrake = pedal, brakeInput, input.handbrake and true or false

  local boosting = c.boostState == "active"
  if boosting then pedal = max(pedal, 0.75) end

  local steer = c.steer
  local cosS, sinS = cos(steer), sin(steer)
  local speed = sqrt(vx * vx + vy * vy)
  local beta = speed > 2 and atan2(vy, max(abs(vx), 1)) or 0
  c.beta = beta

  -- Stability control ----------------------------------------------------
  local escMoment = 0
  c.escActive = 0
  if assist.esc > 0 and speed > 4 and vx > 0 then
    local yawLimit = spec.grip * G / speed * 1.15
    local yawRef = max(-yawLimit, min(yawLimit, vx * tan(steer) / spec.wheelbase))
    local yawErr = r - yawRef
    local slide = max(0, abs(beta) - 0.11) / 0.3
    local over = max(0, abs(yawErr) - 0.18)
    if over > 0 or slide > 0 then
      local amount = min(1, over * 1.1 + slide)
      local moment = spec.mass * G * spec.wheelbase * 0.42 * amount * assist.esc
      if input.handbrake then moment = moment * 0.15 end
      escMoment = yawErr > 0 and -moment or moment
      pedal = pedal * (1 - min(0.8, slide * 1.4) * assist.esc)
      c.escActive = amount * assist.esc
    end
  end

  -- Vertical loads -------------------------------------------------------
  local downforce = 0.5 * 1.2 * spec.liftArea * speed * speed
  local totalWeight = spec.mass * G + downforce
  local staticF = totalWeight * spec.weightFront / 2
  local staticR = totalWeight * (1 - spec.weightFront) / 2
  local longShift = spec.mass * c.ax * spec.cgHeight / spec.wheelbase / 2
  local latTotal = spec.mass * c.ay * spec.cgHeight / spec.track
  local latF = latTotal * spec.rollBalance
  local latR = latTotal * (1 - spec.rollBalance)

  wheels[1].fz = max(120, staticF - longShift - latF)
  wheels[2].fz = max(120, staticF - longShift + latF)
  wheels[3].fz = max(120, staticR + longShift - latR)
  wheels[4].fz = max(120, staticR + longShift + latR)

  -- Drive and brake demands ---------------------------------------------
  local drivenSpeed, drivenN = 0, 0
  for i = 1, 4 do
    local w = wheels[i]
    if w.driven then
      drivenSpeed = drivenSpeed + vx + max(0, w.spin)
      drivenN = drivenN + 1
    end
  end
  drivenSpeed = drivenSpeed / drivenN

  updateGearbox(c, input, drivenSpeed, dt)
  local totalDrive = driveForce(c, pedal, drivenSpeed, dt)

  -- Without a throttle the engine holds the car back a little.
  if abs(pedal) < 0.02 and c.shiftTimer == 0 and not c.reverse then
    totalDrive = -spec.engineBrake * min(1, abs(vx) / 8) * (c.rpm / spec.redline)
    if vx < 0 then totalDrive = -totalDrive end
  end

  local frontShare, rearShare = 0, 0
  if spec.drive == "FWD" then frontShare = 0.5
  elseif spec.drive == "RWD" then rearShare = 0.5
  else
    frontShare = spec.awdFront / 2
    rearShare = (1 - spec.awdFront) / 2
  end

  local brakeForce = brakeInput * spec.brakeForce
  local massPerWheel = spec.mass / 4
  local nominalLoad = spec.mass * G / 4

  local fxTotal, fyTotal, mzTotal = 0, 0, 0
  local slipSum, tcHit, absHit = 0, 0, 0
  local accSum = 0

  for i = 1, 4 do
    local w = wheels[i]
    local surface = dynamics.SURFACES[w.surface] or dynamics.SURFACES.asphalt
    local grip = spec.grip * surface.grip
    if surface.loose and spec.looseGrip then grip = grip * spec.looseGrip end

    local loadRatio = w.fz / nominalLoad
    local mu = grip * max(0.6, 1 - LOAD_SENSITIVITY * (loadRatio - 1))
    local maxForce = mu * w.fz

    -- Velocity of the contact patch in the tyre's own frame.
    local wvx = vx - r * w.y
    local wvy = vy + r * w.x
    local tvx, tvy = wvx, wvy
    if w.front then
      tvx = wvx * cosS + wvy * sinS
      tvy = -wvx * sinS + wvy * cosS
    end
    w.vx, w.vy = tvx, tvy

    local alpha = atan2(tvy, max(abs(tvx), MIN_SLIP_SPEED))
    w.alpha = alpha

    -- Lateral force, never enough to reverse the slip within one step.
    local fy = -maxForce * sin(TYRE_C * atan(c.tyreB * alpha))
    local stopY = abs(tvy) * massPerWheel / dt
    if fy > stopY then fy = stopY elseif fy < -stopY then fy = -stopY end

    -- Longitudinal demand
    local fx = totalDrive * (w.front and frontShare or rearShare)
    local braking = brakeForce * (w.front and spec.brakeBias or (1 - spec.brakeBias)) / 2
    if input.handbrake and not w.front then braking = braking + spec.handbrakeForce / 2 end

    local brakeF = 0
    if braking > 0 then
      local stop = abs(tvx) * massPerWheel / dt
      brakeF = min(braking, stop)
      if abs(tvx) < 0.05 and braking > 1 then brakeF = 0 end
      if tvx > 0 then brakeF = -brakeF end
    end

    -- ABS keeps enough circle spare to steer; a locked wheel has none.
    local lockedRear = input.handbrake and not w.front
    if brakeF ~= 0 and assist.abs > 0 and not lockedRear then
      local spare = sqrt(max(maxForce * maxForce - fy * fy * 0.75, (maxForce * 0.5) ^ 2))
      if abs(brakeF) > spare then
        absHit = 1
        brakeF = brakeF * (spare / abs(brakeF)) * assist.abs + brakeF * (1 - assist.abs)
      end
    end

    -- Traction control trims drive to what the tyre can use.
    if fx ~= 0 and assist.tc > 0 then
      local spare = sqrt(max(maxForce * maxForce - fy * fy, (maxForce * 0.2) ^ 2))
      if abs(fx) > spare then
        tcHit = 1
        local capped = fx > 0 and spare or -spare
        fx = fx + (capped - fx) * assist.tc
      end
    end
    fx = fx + brakeF

    -- Friction circle: anything past the limit scales both axes down, so a
    -- spinning or locked tyre loses its side grip, as on a real car.
    local demand = sqrt(fx * fx + fy * fy)
    local over = 0
    if demand > maxForce then
      local scale = maxForce / demand
      over = 1 / scale - 1
      fx, fy = fx * scale, fy * scale
    end
    w.fx, w.fy = fx, fy

    local peak = c.peakSlip
    w.slide = min(1, max(over * 1.5, (abs(alpha) - peak) / peak) )
    if w.slide < 0 then w.slide = 0 end
    if speed < 1.5 and over == 0 then w.slide = 0 end

    -- Longitudinal slip speed is only for the tach, smoke and sound.
    local slipTarget = 0
    if over > 0 then
      if fx * tvx >= 0 and w.driven and abs(fx) > 1 then
        slipTarget = min(35, over * 16)
      elseif fx * tvx < 0 then
        slipTarget = -abs(tvx)
      end
    end
    w.spin = w.spin + (slipTarget - w.spin) * (1 - math.exp(-dt * 16))

    -- Rolling resistance and loose-surface drag
    local rollForce = (surface.roll + surface.drag * abs(tvx)) * w.fz
    rollForce = min(rollForce, abs(tvx) * massPerWheel / dt)
    local rollX = tvx > 0 and -rollForce or rollForce

    local tfx, tfy = fx + rollX, fy
    local bfx, bfy = tfx, tfy
    if w.front then
      bfx = tfx * cosS - tfy * sinS
      bfy = tfx * sinS + tfy * cosS
    end

    fxTotal = fxTotal + bfx
    fyTotal = fyTotal + bfy
    mzTotal = mzTotal + (w.x * bfy - w.y * bfx)
    slipSum = slipSum + w.slide
    accSum = accSum + 1
  end

  -- Aero drag acts through the centre of the car
  local dragForce = 0.5 * 1.2 * spec.dragArea * speed
  fxTotal = fxTotal - dragForce * vx
  fyTotal = fyTotal - dragForce * vy

  mzTotal = mzTotal + escMoment

  c.slip = slipSum / accSum
  c.tcActive = tcHit
  c.absActive = absHit

  -- Filtered accelerations drive next step's weight transfer.
  local k = 1 - math.exp(-dt / LOAD_LAG)
  c.ax = c.ax + (fxTotal / spec.mass - c.ax) * k
  c.ay = c.ay + (fyTotal / spec.mass - c.ay) * k

  return fxTotal, fyTotal, mzTotal
end

return dynamics
