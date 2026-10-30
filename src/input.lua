-- Keyboard and gamepad, merged into one set of driving controls.
local input = {
  binds = {
    throttle = { "w", "up" },
    brake = { "s", "down" },
    steerLeft = { "a", "left" },
    steerRight = { "d", "right" },
    handbrake = { "lshift", "rshift" },
    boost = { "space" },
    shiftUp = { "e" },
    shiftDown = { "q" },
    lowBeam = { "f" },
    highBeam = { "g" },
    respawn = { "r" },
    camera = { "c" },
    pause = { "escape", "p" },
  },
  pads = {
    handbrake = "x",
    boost = "a",
    shiftUp = "rightshoulder",
    shiftDown = "leftshoulder",
    respawn = "y",
    camera = "back",
    pause = "start",
  },
  held = {},
  pressedOnce = {},
  gamepad = nil,
}

local byKey = {}
for action, keys in pairs(input.binds) do
  for _, key in ipairs(keys) do byKey[key] = action end
end
local byButton = {}
for action, button in pairs(input.pads) do byButton[button] = action end

function input.press(key)
  local action = byKey[key]
  if action then
    input.held[key] = true
    input.pressedOnce[action] = true
  end
end

function input.release(key)
  input.held[key] = nil
end

function input.gamepadPress(joystick, button)
  input.gamepad = joystick
  local action = byButton[button]
  if action then
    input.held["pad:" .. button] = true
    input.pressedOnce[action] = true
  end
end

function input.gamepadRelease(joystick, button)
  input.held["pad:" .. button] = nil
end

function input.joystickAdded(joystick)
  if joystick:isGamepad() then input.gamepad = joystick end
end

function input.joystickRemoved(joystick)
  if input.gamepad == joystick then input.gamepad = nil end
end

function input.isDown(action)
  for _, key in ipairs(input.binds[action] or {}) do
    if input.held[key] then return true end
  end
  local button = input.pads[action]
  return button ~= nil and input.held["pad:" .. button] == true
end

-- True once per press; reading it uses the press up.
function input.consume(action)
  local pressed = input.pressedOnce[action]
  input.pressedOnce[action] = nil
  return pressed == true
end

function input.clear()
  input.pressedOnce = {}
  input.held = {}
end

local function deadzone(v)
  if math.abs(v) < 0.08 then return 0 end
  return (v - (v > 0 and 0.08 or -0.08)) / 0.92
end

-- Fill a car's input table from the player's hands.
function input.applyTo(target, manualGearbox)
  local steer, throttle, brake = 0, 0, 0
  if input.isDown("steerLeft") then steer = steer - 1 end
  if input.isDown("steerRight") then steer = steer + 1 end
  if input.isDown("throttle") then throttle = 1 end
  if input.isDown("brake") then brake = 1 end
  target.keyboard = true

  local pad = input.gamepad
  if pad and pad:isConnected() then
    local axis = deadzone(pad:getGamepadAxis("leftx"))
    local right = pad:getGamepadAxis("triggerright")
    local left = pad:getGamepadAxis("triggerleft")
    if axis ~= 0 then
      -- A curved response gives fine control around the centre.
      steer = axis * math.abs(axis) ^ 0.6
      target.keyboard = false
    end
    throttle = math.max(throttle, right)
    brake = math.max(brake, left)
  end

  target.steer, target.throttle, target.brake = steer, throttle, brake
  target.handbrake = input.isDown("handbrake")
  -- Checking the press too means a tap shorter than a frame still counts.
  local boostTapped = input.consume("boost")
  target.boost = boostTapped or input.isDown("boost")
  target.manual = manualGearbox
  target.shiftUp = input.consume("shiftUp")
  target.shiftDown = input.consume("shiftDown")
end

return input
