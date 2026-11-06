-- What the driver feels: a pad's motors and a phone's buzzer. A pad gets the
-- road as well as the hits. A phone only has one crude buzzer, so it keeps to
-- the moments that matter.
local settings = require("src/settings")
local input = require("src/input")
local ui = require("src/ui")

local rumble = { thump = 0, tick = 0 }

local SEND_GAP = 1 / 30     -- seconds between updates to the pad
local MOTOR_TIME = 0.2      -- how long each update runs, so a stall can't jam them on
local FADE = 7              -- how fast a thump dies away (per s)
local CHANGE = 0.02         -- smaller changes aren't worth a message to the pad
local PHONE_GAP = 0.15      -- seconds between phone buzzes
local PHONE_MIN, PHONE_MAX = 0.02, 0.09

local phoneTimer = 0

-- Each driver's own pad and motors. The first is this module itself, so one
-- driver alone reads as it always has; the second only exists with two at a screen.
local first = rumble
first.sendTimer, first.sentLeft, first.sentRight = 0, 0, 0
local seats = { first, { thump = 0, tick = 0, sendTimer = 0, sentLeft = 0, sentRight = 0 } }

-- A pad for this seat: false for none, or nil for the first to follow whichever
-- pad was used last.
function rumble.assign(who, joystick)
  seats[who].joystick = joystick
end

local function pad(seat)
  if seat.joystick == false then return nil end
  local joystick = seat.joystick or (seat == first and input.gamepad or nil)
  if joystick and joystick:isConnected() and joystick:isVibrationSupported() then return joystick end
  return nil
end

local function buzz(seconds)
  if not ui.mobile or not settings.vibration or phoneTimer > 0 then return end
  phoneTimer = PHONE_GAP
  love.system.vibrate(seconds)
end

-- A crash, 0..1 and up. A big hit is felt in the heavy motor.
function rumble.crash(strength, who)
  local seat = seats[who or 1]
  local amount = math.min(1, 0.25 + strength)
  seat.thump = math.max(seat.thump, amount)
  if seat == first then buzz(PHONE_MIN + (PHONE_MAX - PHONE_MIN) * amount) end
end

-- A gear going in: a tap in the light motor, too small for a phone.
function rumble.shift(who)
  local seat = seats[who or 1]
  seat.tick = math.max(seat.tick, 0.45)
end

-- Motor levels, 0..1, heavy then light.
function rumble.levels(model, speed, thump, tick)
  local heavy, light = thump, tick
  local pace = math.min(1, speed / 30)
  if model.boostState == "active" then
    heavy = heavy + 0.35
    light = light + 0.2
  end
  local kerb, loose = false, false
  for i = 1, 4 do
    local surface = model.wheels[i].surface
    if surface == "kerb" then kerb = true end
    if surface == "grass" or surface == "gravel" then loose = true end
  end
  if kerb then light = light + 0.4 * pace end
  if loose then heavy = heavy + 0.25 * pace end
  light = light + model.slip * 0.2 * pace
  return math.min(1, heavy), math.min(1, light)
end

local function motorsOff(seat)
  if seat.sentLeft == 0 and seat.sentRight == 0 then return end
  seat.sentLeft, seat.sentRight = 0, 0
  local joystick = pad(seat)
  if joystick then joystick:setVibration() end
end

function rumble.update(dt, car, who)
  local seat = seats[who or 1]
  seat.sendTimer = seat.sendTimer - dt
  if seat == first then
    phoneTimer = math.max(0, phoneTimer - dt)
    local boosting = car.model.boostState == "active"
    if boosting and not rumble.boosting then buzz(PHONE_MIN) end
    rumble.boosting = boosting
  end

  local joystick = pad(seat)
  local fade = math.exp(-dt * FADE)
  local left, right = rumble.levels(car.model, car:getSpeed(), seat.thump, seat.tick)
  seat.thump, seat.tick = seat.thump * fade, seat.tick * fade
  if not joystick or not settings.vibration then return motorsOff(seat) end
  if seat.sendTimer > 0 then return end

  if left < CHANGE and right < CHANGE then return motorsOff(seat) end
  if math.abs(left - seat.sentLeft) < CHANGE and math.abs(right - seat.sentRight) < CHANGE
    and seat.sendTimer > -MOTOR_TIME / 2 then
    return
  end
  joystick:setVibration(left, right, MOTOR_TIME)
  seat.sentLeft, seat.sentRight = left, right
  seat.sendTimer = SEND_GAP
end

-- Both drivers' motors, or only one's.
function rumble.stop(who)
  for i, seat in ipairs(seats) do
    if not who or who == i then
      seat.thump, seat.tick = 0, 0
      seat.sendTimer = 0
      if seat == first then rumble.boosting = false end
      motorsOff(seat)
    end
  end
end

return rumble
