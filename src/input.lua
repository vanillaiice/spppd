-- Keyboard and gamepad, merged into one set of driving controls. Touch sits on
-- top of this in src/touch.lua. The pad borrows R1 handbrake and L1 boost from
-- Need for Speed: Most Wanted on PS2, with the triggers kept for partial gas
-- and braking. Players can change the keys and buttons on CONTROLS > KEYBOARD
-- and CONTROLS > PAD (src/menu.lua), and settings.keys and settings.padButtons
-- keep what they changed.
local input = {
  -- Built from the tables below by input.setBindings: every key, then every pad
  -- button, that does each action.
  binds = {},
  pads = {},
  held = {},
  pressedOnce = {},
  gamepad = nil,
  -- The same presses again, kept apart by whose hands they came from, for two
  -- drivers at one screen. The merged ones above are what one driver reads.
  keyPressed = {},
  padHeld = {},     -- [joystick] = { [button] = true }
  padPressed = {},  -- [joystick] = { [action] = true }
}

-- Every action, in the order the CONTROLS screens list them.
input.ACTIONS = {
  "throttle", "brake", "steerLeft", "steerRight", "handbrake", "boost", "shiftUp", "shiftDown",
  "lowBeam", "highBeam", "respawn", "camera", "radio", "horn", "pause",
}

-- One key per action, which the player can change.
input.DEFAULT_KEYS = {
  throttle = "w", brake = "s", steerLeft = "a", steerRight = "d", handbrake = "lshift",
  boost = "space", shiftUp = "e", shiftDown = "q", lowBeam = "f", highBeam = "g",
  respawn = "r", camera = "c", radio = "n", horn = "h", pause = "p",
}
-- Second keys that never change, so the arrows always drive and Esc always pauses.
input.FIXED_KEYS = {
  throttle = "up", brake = "down", steerLeft = "left", steerRight = "right",
  handbrake = "rshift", pause = "escape",
}

-- The pad's buttons, which the player can change too. The stick steers and the
-- triggers give partial gas and brake whatever is set here; a button for gas or
-- brake is full on, on top of them.
input.PAD_ACTIONS = {
  "throttle", "brake", "handbrake", "boost", "shiftUp", "shiftDown", "respawn", "camera", "radio", "horn",
  "pause",
}
input.DEFAULT_BUTTONS = {
  handbrake = "rightshoulder", boost = "leftshoulder", shiftUp = "x", shiftDown = "a",
  respawn = "y", camera = "back", radio = "dpright", horn = "b", pause = "start",
}
-- What a pad can be asked for. The guide button belongs to the system.
input.BUTTONS = {
  a = true, b = true, x = true, y = true, back = true, start = true, leftstick = true, rightstick = true,
  leftshoulder = true, rightshoulder = true, dpup = true, dpdown = true, dpleft = true, dpright = true,
}

-- The current choices: action -> key, and action -> button (or nil for none).
local keyOf, buttonOf = {}, {}
local byKey, byButton = {}, {}

local function rebuild()
  byKey, byButton = {}, {}
  input.binds, input.pads = {}, {}
  for _, action in ipairs(input.ACTIONS) do
    local keys = { keyOf[action], input.FIXED_KEYS[action] }
    input.binds[action] = keys
    for _, key in ipairs(keys) do byKey[key] = action end
    -- The on-screen controls press these, so they work whatever keys are set.
    byKey["touch:" .. action] = action
  end
  for _, action in ipairs(input.PAD_ACTIONS) do
    input.pads[action] = { buttonOf[action] }
    if buttonOf[action] then byButton[buttonOf[action]] = action end
  end
end

local fixedKey = {}
for _, key in pairs(input.FIXED_KEYS) do fixedKey[key] = true end

-- Sets the keys and buttons from what was saved: only the ones that differ from
-- the defaults, false meaning a pad action has no button. Anything that doesn't
-- make sense, two actions on one key included, puts that device back to its
-- defaults. Returns false when that happened.
function input.setBindings(keys, buttons)
  local ok = true
  keyOf, buttonOf = {}, {}
  local used = {}
  for _, action in ipairs(input.ACTIONS) do
    local key = keys and keys[action]
    if key == nil then key = input.DEFAULT_KEYS[action] end
    if type(key) ~= "string" or key == "" or #key > 20 or fixedKey[key] or used[key] then
      ok = false
      keyOf = nil
      break
    end
    keyOf[action], used[key] = key, true
  end
  if not keyOf then
    keyOf = {}
    for action, key in pairs(input.DEFAULT_KEYS) do keyOf[action] = key end
  end
  used = {}
  for _, action in ipairs(input.PAD_ACTIONS) do
    local button = buttons and buttons[action]
    if button == nil then button = input.DEFAULT_BUTTONS[action] or false end
    if button ~= false and (not input.BUTTONS[button] or used[button]) then
      ok = false
      buttonOf = nil
      break
    end
    buttonOf[action] = button or nil
    if button then used[button] = true end
  end
  if not buttonOf or not buttonOf.pause then
    if buttonOf then ok = false end
    buttonOf = {}
    for action, button in pairs(input.DEFAULT_BUTTONS) do buttonOf[action] = button end
  end
  rebuild()
  return ok
end

-- What to save: only the choices that differ from the defaults.
function input.keyChanges()
  local out = {}
  for action, key in pairs(keyOf) do
    if key ~= input.DEFAULT_KEYS[action] then out[action] = key end
  end
  return out
end

function input.buttonChanges()
  local out = {}
  for _, action in ipairs(input.PAD_ACTIONS) do
    local button = buttonOf[action] or false
    if button ~= (input.DEFAULT_BUTTONS[action] or false) then out[action] = button end
  end
  return out
end

function input.keyFor(action) return keyOf[action] end
function input.fixedKeyFor(action) return input.FIXED_KEYS[action] end
function input.buttonFor(action) return buttonOf[action] end

-- Puts a key on an action. The action that had it takes this one's old key, so
-- every action keeps one. Returns false and why when the key can't be used.
function input.rebindKey(action, key)
  if fixedKey[key] then return false, "fixed" end
  local old = keyOf[action]
  if old == key then return true end
  for other, k in pairs(keyOf) do
    if k == key then keyOf[other] = old end
  end
  keyOf[action] = key
  rebuild()
  return true
end

-- The same for a pad button. Pause always keeps a button, so a pad can always
-- get out of a race.
function input.rebindButton(action, button)
  if not input.BUTTONS[button] then return false, "reserved" end
  local old = buttonOf[action]
  if old == button then return true end
  for other, b in pairs(buttonOf) do
    if b == button then
      if other == "pause" and not old then return false, "pause" end
      buttonOf[other] = old
    end
  end
  buttonOf[action] = button
  rebuild()
  return true
end

function input.resetKeys()
  input.setBindings(nil, input.buttonChanges())
end

function input.resetButtons()
  input.setBindings(input.keyChanges(), nil)
end

input.setBindings()

function input.press(key)
  local action = byKey[key]
  if action then
    input.held[key] = true
    input.pressedOnce[action] = true
    input.keyPressed[action] = true
  end
end

function input.release(key)
  input.held[key] = nil
end

function input.gamepadPress(joystick, button)
  input.gamepad = joystick
  if joystick then
    input.padHeld[joystick] = input.padHeld[joystick] or {}
    input.padHeld[joystick][button] = true
  end
  local action = byButton[button]
  if action then
    input.held["pad:" .. button] = true
    input.pressedOnce[action] = true
    if joystick then
      input.padPressed[joystick] = input.padPressed[joystick] or {}
      input.padPressed[joystick][action] = true
    end
  end
end

function input.gamepadRelease(joystick, button)
  input.held["pad:" .. button] = nil
  local held = joystick and input.padHeld[joystick]
  if held then held[button] = nil end
end

function input.joystickAdded(joystick)
  if joystick:isGamepad() then input.gamepad = joystick end
end

function input.joystickRemoved(joystick)
  if input.gamepad == joystick then input.gamepad = nil end
  input.padHeld[joystick], input.padPressed[joystick] = nil, nil
end

-- Every pad that's plugged in, oldest first, so the same pad is the same player.
function input.gamepads()
  local list = {}
  if not love.joystick then return list end
  for _, joystick in ipairs(love.joystick.getJoysticks()) do
    if joystick:isGamepad() and joystick:isConnected() then list[#list + 1] = joystick end
  end
  table.sort(list, function(a, b) return a:getID() < b:getID() end)
  return list
end

function input.padConnected()
  local pad = input.gamepad
  return pad ~= nil and pad:isConnected()
end

local function keyDown(action)
  for _, key in ipairs(input.binds[action] or {}) do
    if input.held[key] then return true end
  end
  return input.held["touch:" .. action] == true
end

function input.isDown(action)
  if keyDown(action) then return true end
  for _, button in ipairs(input.pads[action] or {}) do
    if input.held["pad:" .. button] then return true end
  end
  return false
end

-- True once per press; reading it uses the press up.
function input.consume(action)
  local pressed = input.pressedOnce[action]
  input.pressedOnce[action] = nil
  return pressed == true
end

-- Forget presses not yet read, but not what's held down.
function input.dropPresses()
  input.pressedOnce = {}
  input.keyPressed = {}
  input.padPressed = {}
end

function input.clear()
  input.pressedOnce = {}
  input.held = {}
  input.keyPressed = {}
  input.padHeld = {}
  input.padPressed = {}
end

local function deadzone(v)
  if math.abs(v) < 0.08 then return 0 end
  return (v - (v > 0 and 0.08 or -0.08)) / 0.92
end

-- A curved response gives fine control around the centre.
function input.curve(v)
  local axis = deadzone(v)
  return axis * math.abs(axis) ^ 0.6
end

-- How far the throttle is pressed, on any device.
function input.throttle()
  local amount = input.isDown("throttle") and 1 or 0
  local pad = input.gamepad
  if pad and pad:isConnected() then
    amount = math.max(amount, pad:getGamepadAxis("triggerright"))
  end
  return amount
end

-- How far the brake is pressed, on any device.
function input.brake()
  local amount = input.isDown("brake") and 1 or 0
  local pad = input.gamepad
  if pad and pad:isConnected() then
    amount = math.max(amount, pad:getGamepadAxis("triggerleft"))
  end
  return amount
end

-- Fill a car's input table from the player's hands.
function input.applyTo(target, manualGearbox)
  local steer = 0
  if input.isDown("steerLeft") then steer = steer - 1 end
  if input.isDown("steerRight") then steer = steer + 1 end
  target.keyboard = true

  local pad = input.gamepad
  if pad and pad:isConnected() then
    local axis = input.curve(pad:getGamepadAxis("leftx"))
    if axis ~= 0 then
      steer = axis
      target.keyboard = false
    end
  end

  target.steer, target.throttle, target.brake = steer, input.throttle(), input.brake()
  target.handbrake = input.isDown("handbrake")
  -- Checking the press too means a tap shorter than a frame still counts.
  local boostTapped = input.consume("boost")
  target.boost = boostTapped or input.isDown("boost")
  target.manual = manualGearbox
  target.shiftUp = input.consume("shiftUp")
  target.shiftDown = input.consume("shiftDown")
end

-- One driver's own hands, when two share the screen: the keyboard, one pad, or
-- both. It reads only what those hands pressed, and fills a car as applyTo does.
local Reader = {}
Reader.__index = Reader

function input.reader(keyboard, pad)
  return setmetatable({ keyboard = keyboard or false, pad = pad }, Reader)
end

function Reader:isDown(action)
  if self.keyboard and keyDown(action) then return true end
  local held = self.pad and input.padHeld[self.pad]
  if held then
    for _, button in ipairs(input.pads[action] or {}) do
      if held[button] then return true end
    end
  end
  return false
end

function Reader:consume(action)
  local pressed = false
  if self.keyboard and input.keyPressed[action] then
    input.keyPressed[action] = nil
    pressed = true
  end
  local list = self.pad and input.padPressed[self.pad]
  if list and list[action] then
    list[action] = nil
    pressed = true
  end
  return pressed
end

function Reader:connected()
  return self.pad ~= nil and self.pad:isConnected()
end

function Reader:throttle()
  local amount = self:isDown("throttle") and 1 or 0
  if self:connected() then amount = math.max(amount, self.pad:getGamepadAxis("triggerright")) end
  return amount
end

function Reader:brake()
  local amount = self:isDown("brake") and 1 or 0
  if self:connected() then amount = math.max(amount, self.pad:getGamepadAxis("triggerleft")) end
  return amount
end

function Reader:applyTo(target, manualGearbox)
  local steer = 0
  if self:isDown("steerLeft") then steer = steer - 1 end
  if self:isDown("steerRight") then steer = steer + 1 end
  target.keyboard = true
  if self:connected() then
    local axis = input.curve(self.pad:getGamepadAxis("leftx"))
    if axis ~= 0 then
      steer = axis
      target.keyboard = false
    end
  end
  target.steer, target.throttle, target.brake = steer, self:throttle(), self:brake()
  target.handbrake = self:isDown("handbrake")
  local boostTapped = self:consume("boost")
  target.boost = boostTapped or self:isDown("boost")
  target.manual = manualGearbox
  target.shiftUp = self:consume("shiftUp")
  target.shiftDown = self:consume("shiftDown")
end

-- Who drives with what when two share the screen, or nil without a pad for the
-- second. One pad: the keyboard and the pad. Two or more: the keyboard goes with
-- the first pad, and the second pad is the other driver's.
function input.splitReaders(pads)
  pads = pads or input.gamepads()
  if #pads == 0 then return nil end
  if #pads == 1 then return input.reader(true, nil), input.reader(false, pads[1]) end
  return input.reader(true, pads[1]), input.reader(false, pads[2])
end

return input
