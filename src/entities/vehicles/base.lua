-- Shared vehicle defaults. A vehicle file only states how it differs.
local config = require("src/config")

local base = {}

local DEFAULTS = {
  -- Chassis
  mass = 1400,
  weightFront = 0.52,   -- share of the weight on the front axle
  cgHeight = 0.52,
  wheelbase = 2.65,
  track = 1.6,
  length = 4.5,
  width = 1.85,
  rollBalance = 0.55,   -- share of lateral load transfer on the front axle
  -- Tyres
  grip = 1.1,
  peakSlip = 0.15,      -- slip angle at peak grip (rad)
  looseGrip = 1.0,      -- multiplier on grass and gravel
  -- Drivetrain
  drive = "RWD",
  awdFront = 0.4,
  peakTorque = 400,
  redline = 7000,
  idleRpm = 900,
  gears = { 3.6, 2.3, 1.7, 1.3, 1.03, 0.84 },
  finalDrive = 3.6,
  reverseGear = 3.4,
  drivelineEfficiency = 0.88,
  wheelRadius = 0.33,
  shiftTime = 0.11,
  engineBrake = 900,
  -- Aero
  dragArea = 0.68,      -- Cd * A
  liftArea = 0.15,      -- downforce coefficient * A
  -- Brakes (peak force as a multiple of weight)
  brakeG = 1.35,
  brakeBias = 0.64,
  handbrakeForce = 9000,
  -- Steering
  steerLock = math.rad(34),
  steerSpeed = math.rad(420),
  -- Nitrous
  boostPower = 150000,
  boostTime = 3,
  boostCooldown = 10,
  -- Looks
  bodyStyle = "sedan",
  color = { 0.8, 0.1, 0.1 },
}

function base.define(spec)
  for k, v in pairs(DEFAULTS) do
    if spec[k] == nil then spec[k] = v end
  end
  spec.brakeForce = spec.brakeForce or spec.mass * config.GRAVITY * spec.brakeG
  spec.inertia = spec.inertia or spec.mass * (spec.length ^ 2 + spec.width ^ 2) / 12 * 1.05
  return spec
end

return base
