-- On-screen driving controls: a stick that appears under the left thumb, or
-- left and right buttons in its place, and buttons under the right. The buttons
-- press the same bindings as the keyboard, so a touch is just another pair of
-- hands, and button steering winds on as smoothly as the arrow keys.
local ui = require("src/ui")
local input = require("src/input")
local colors = require("src/colors")
local settings = require("src/settings")

local touch = { active = ui.mobile, stick = nil, fingers = {} }

local STICK_RADIUS = 34
-- The thumb wanders while steering, so the pedals only wake up past this.
local PEDAL_DEADZONE = 0.3
-- Thumbs land near a button, not on it.
local HIT_SLOP = 1.25

-- A stick or a trigger alone hands over to the pad too, past the drift a
-- resting stick can have.
local PAD_WAKE = 0.3

function touch.padUsed(joystick)
  input.gamepad = joystick
  touch.active = false
end

function touch.padAxis(joystick, value)
  if math.abs(value) >= PAD_WAKE then touch.padUsed(joystick) end
end

-- A pad plugged in is a pad about to be used.
function touch.padAdded(joystick)
  input.joystickAdded(joystick)
  if joystick:isGamepad() then touch.active = false end
end

-- True when it was the pad doing the driving. A phone gets its touch controls back.
function touch.padRemoved(joystick)
  local driving = input.gamepad == joystick
  input.joystickRemoved(joystick)
  if driving then touch.active = ui.mobile end
  return driving
end

function touch.shown()
  if settings.touch == "on" then return true end
  return settings.touch == "auto" and touch.active
end

function touch.buttons()
  return settings.touchSteer == "buttons"
end

-- TOUCH SIZE scales the buttons where they stand. LARGE is as big as the 16:9
-- phone allows: past it DRIFT meets BOOST or the dash. The top row and the arrows
-- are packed tighter, so they stop growing sooner.
local SIZES = { small = 0.85, medium = 1, large = 1.2 }
local TOP_MAX, ARROW_MAX = 1.1, 1.12

function touch.size()
  return SIZES[settings.touchSize] or 1
end

-- The manual gearbox gets a pair of buttons, so touch honours it.
function touch.shifting()
  return settings.gearbox == "manual"
end

-- Boost sits under the resting right thumb with drift just inside it. Reset, pause
-- and the horn are up top, where a thumb won't hit them by accident.
--
-- With buttons, brake sits above drift, clear of the dash's row, and the left
-- thumb rocks between two arrows. Without auto gas, gas and brake share the bottom
-- row like a pair of pedals, drift goes up where brake was, and boost moves out
-- beside it.
--
-- With the manual box, DOWN sits on the left above the steering and UP on the
-- right above the cluster, like paddles behind a wheel.
function touch.layout(sw, sh)
  local s = ui.scale(sw, sh)
  local k = touch.size()
  local function at(action, label, size, right, up, r, grow)
    grow = grow or k
    return { action = action, label = label, size = size * s * grow, x = sw - right * s, y = sh - up * s,
      r = r * s * grow }
  end
  local function top(action, label, size, right)
    local grow = math.min(k, TOP_MAX)
    return { action = action, label = label, size = size * s * grow, x = sw - right * s, y = 24 * s,
      r = 17 * s * grow }
  end
  local layout = {
    s = s,
    radius = STICK_RADIUS * s * k,
    rest = { x = 62 * s, y = sh - 62 * s },
    buttons = {
      at("boost", "BOOST", 8, 52, 52, 34),
      at("handbrake", "DRIFT", 7, 124, 40, 26),
      top("pause", "II", 7, 24),
      top("respawn", "RESET", 5, 62),
      top("horn", "HORN", 5, 100),
    },
  }
  local list = layout.buttons
  if touch.buttons() then
    if settings.autoGas then
      list[#list + 1] = at("brake", "BRAKE", 7, 134, 104, 26)
    else
      list[1] = at("boost", "BOOST", 6, 196, 96, 22)
      list[2] = at("handbrake", "DRIFT", 7, 134, 104, 26)
      list[#list + 1] = at("brake", "BRAKE", 7, 124, 40, 26)
      list[#list + 1] = at("throttle", "GAS", 8, 52, 52, 34)
    end
    local grow = math.min(k, ARROW_MAX)
    local left = { action = "steerLeft", shape = "left", x = 42 * s, y = sh - 46 * s, r = 32 * s * grow }
    local right = { action = "steerRight", shape = "right", x = 116 * s, y = sh - 46 * s, r = 32 * s * grow }
    list[#list + 1], list[#list + 2] = left, right
    -- A thumb anywhere on the left half steers, to whichever side of this line it's on.
    layout.divide = (left.x + right.x) / 2
  end
  if touch.shifting() then
    local down = at("shiftDown", "DOWN", 5, 0, 118, 18)
    down.x = 28 * s
    list[#list + 1] = down
    list[#list + 1] = at("shiftUp", "UP", 5, 128, 160, 18)
  end
  return layout
end

local function keyFor(action)
  return input.binds[action][1]
end

-- Two thumbs can share an action, so it's only let go when the last one lifts.
local function hold(id, action)
  if touch.fingers[id] == action then return end
  local before = touch.fingers[id]
  touch.fingers[id] = action
  if before then
    local still = false
    for _, a in pairs(touch.fingers) do still = still or a == before end
    if not still then input.release(keyFor(before)) end
  end
  input.press(keyFor(action))
end

local function steerSide(layout, x)
  return x < layout.divide and "steerLeft" or "steerRight"
end

function touch.pressed(id, x, y, sw, sh)
  local layout = touch.layout(sw, sh)
  local hit, nearest = nil, math.huge
  for _, b in ipairs(layout.buttons) do
    local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2)
    if d < b.r * HIT_SLOP and d < nearest then hit, nearest = b, d end
  end
  if hit then
    hold(id, hit.action)
  elseif x < sw / 2 and layout.divide then
    hold(id, steerSide(layout, x))
  elseif x < sw / 2 and not touch.stick then
    touch.stick = { id = id, baseX = x, baseY = y, x = 0, y = 0, radius = layout.radius }
  end
  local action = touch.fingers[id]
  if action == "steerLeft" or action == "steerRight" then
    touch.steering = touch.steering or {}
    touch.steering[id] = { sw = sw, sh = sh }
  elseif (action == "throttle" or action == "brake") and not settings.autoGas then
    touch.pedals = touch.pedals or {}
    touch.pedals[id] = { sw = sw, sh = sh }
  end
end

-- A thumb on the pedal pair slides between gas and brake without lifting, the
-- way it rocks between the steering arrows.
local function nearestPedal(layout, x, y)
  local best, nearest = nil, math.huge
  for _, b in ipairs(layout.buttons) do
    if b.action == "throttle" or b.action == "brake" then
      local d = (x - b.x) ^ 2 + (y - b.y) ^ 2
      if d < nearest then best, nearest = b.action, d end
    end
  end
  return best
end

-- Dragged past the edge, the base follows the thumb. Turning back then acts at
-- once instead of crossing a dead stretch of screen first.
local function follow(base, thumb, radius)
  local d = thumb - base
  if d > radius then return thumb - radius end
  if d < -radius then return thumb + radius end
  return base
end

function touch.moved(id, x, y)
  -- A steering thumb rocks from one arrow to the other without lifting.
  local steering = touch.steering and touch.steering[id]
  if steering then
    hold(id, steerSide(touch.layout(steering.sw, steering.sh), x))
    return
  end
  local pedals = touch.pedals and touch.pedals[id]
  if pedals then
    local action = nearestPedal(touch.layout(pedals.sw, pedals.sh), x, y)
    if action then hold(id, action) end
    return
  end
  local stick = touch.stick
  if not stick or stick.id ~= id then return end
  local r = stick.radius
  stick.baseX = follow(stick.baseX, x, r)
  stick.baseY = follow(stick.baseY, y, r)
  -- Each axis is free of the other, so full lock doesn't cost any brake.
  stick.x = (x - stick.baseX) / r
  stick.y = (stick.baseY - y) / r
end

function touch.released(id)
  local action = touch.fingers[id]
  if action then
    touch.fingers[id] = nil
    local still = false
    for _, a in pairs(touch.fingers) do still = still or a == action end
    if not still then input.release(keyFor(action)) end
  end
  if touch.steering then touch.steering[id] = nil end
  if touch.pedals then touch.pedals[id] = nil end
  if touch.stick and touch.stick.id == id then touch.stick = nil end
end

-- Fingers can leave the glass unseen while the game is paused or in the background.
function touch.reset()
  for id in pairs(touch.fingers) do touch.released(id) end
  touch.stick = nil
  touch.steering = nil
  touch.pedals = nil
end

local function pedal(v)
  return math.max(0, (v - PEDAL_DEADZONE) / (1 - PEDAL_DEADZONE))
end

-- Only a real push on the stick revs the engine, so auto gas stays quiet at
-- the lights.
function touch.revs()
  if not touch.shown() or not touch.stick then return 0 end
  return pedal(touch.stick.y)
end

-- The stick pulled back at the lights. The BRAKE button presses the brake key, so
-- the keyboard's reading has that.
function touch.brakes()
  if not touch.shown() or not touch.stick then return 0 end
  return pedal(-touch.stick.y)
end

-- Layered over input.applyTo, so a keyboard or pad keeps working alongside.
function touch.applyTo(target)
  if not touch.shown() then return end
  local stick = touch.stick
  local up = stick and stick.y or 0
  if stick then
    target.steer = input.curve(stick.x)
    target.keyboard = false
  end
  target.brake = math.max(target.brake, pedal(-up))
  local gas = settings.autoGas and 1 or pedal(up)
  target.throttle = math.max(target.throttle, target.brake > 0 and 0 or gas)
  -- With buttons, the arrows press the keyboard's own steering, and the shift
  -- buttons press its gear keys, so the gearbox setting stands as it is.
end

-- Drawing ---------------------------------------------------------------------

-- TOUCH OPACITY fades everything at rest. A held button stays at least this
-- bright, so a press always shows.
local HELD_FLOOR = 0.6

local function opacity()
  return settings.touchOpacity or 1
end

local function buttonColor(action, car)
  if action == "boost" then
    local state = car.model.boostState
    if state == "active" then return colors.sectorPurple end
    return state == "cooldown" and colors.muted or colors.sectorGreen
  end
  if action == "brake" then return colors.kerb end
  if action == "throttle" then return colors.sectorGreen end
  return action == "handbrake" and colors.marshal or colors.paint
end

local function fade(c, a)
  return { c[1], c[2], c[3], (c[4] or 1) * a }
end

local function drawArrow(b, x, y, c)
  local w = b.r * 0.42
  local dir = b.shape == "left" and -1 or 1
  love.graphics.setColor(c)
  love.graphics.polygon("fill", x + dir * w, y, x - dir * w * 0.7, y - w, x - dir * w * 0.7, y + w)
end

-- One button with its middle at x, y.
local function paintButton(x, y, b, c, held, a, s)
  local panel = colors.asphaltDeep
  if held then
    love.graphics.setColor(fade(c, a))
  else
    love.graphics.setColor(panel[1], panel[2], panel[3], 0.55 * a)
  end
  love.graphics.circle("fill", x, y, b.r)
  love.graphics.setColor(c[1], c[2], c[3], 0.9 * a)
  love.graphics.setLineWidth(2 * s)
  love.graphics.circle("line", x, y, b.r)
  if b.shape then
    drawArrow(b, x, y, fade(held and panel or c, a))
  else
    -- Red text on the dark panel is hard to read, so brake is labelled in white.
    local text = b.action == "brake" and colors.paint or (held and panel or c)
    ui.text(b.label, x - b.r, y - b.size / 2, b.size, fade(text, a), "center", b.r * 2)
  end
end

-- The controls look the same frame after frame until they're pressed, and their
-- circles and rounded corners cost a slow phone more than the rest of the HUD. So
-- each look is drawn once into a canvas, keyed by everything that changes it, and
-- kept. paint(x, y, ...) draws it with its middle at x, y.
local looks, lookCount = {}, 0
local MAX_LOOKS = 64

local function drawLook(key, half, x, y, paint, ...)
  local canvas = looks[key]
  if not canvas then
    if lookCount >= MAX_LOOKS then looks, lookCount = {}, 0 end
    canvas = love.graphics.newCanvas(half * 2, half * 2)
    canvas:setFilter("nearest", "nearest")
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    paint(half, half, ...)
    love.graphics.pop()
    looks[key] = canvas
    lookCount = lookCount + 1
  end
  -- On a whole pixel, so the canvas lands on the screen's pixels as drawn.
  local dpi = love.graphics.getDPIScale()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.draw(canvas, math.floor((x - half) * dpi + 0.5) / dpi, math.floor((y - half) * dpi + 0.5) / dpi)
  love.graphics.setBlendMode("alpha")
end

local function paintStickBase(x, y, r, s, alpha)
  local panel = colors.asphaltDeep
  love.graphics.setColor(panel[1], panel[2], panel[3], alpha * 0.6)
  love.graphics.rectangle("fill", x - r, y - r, r * 2, r * 2, 10 * s)
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.setLineWidth(2 * s)
  love.graphics.rectangle("line", x - r, y - r, r * 2, r * 2, 10 * s)
end

local function drawStick(layout)
  local stick = touch.stick
  local s, r = layout.s, layout.radius
  local x = stick and stick.baseX or layout.rest.x
  local y = stick and stick.baseY or layout.rest.y
  local alpha = stick and 0.75 * math.max(opacity(), HELD_FLOOR) or 0.4 * opacity()
  drawLook(string.format("stick|%.2f|%.2f|%.3f", r, s, alpha), math.ceil(r + 2 * s + 2), x, y,
    paintStickBase, r, s, alpha)
  local c = colors.marshal
  love.graphics.setColor(c[1], c[2], c[3], math.min(1, alpha + 0.2))
  local knob = 15 * r / STICK_RADIUS
  love.graphics.circle("fill", x + (stick and stick.x or 0) * r, y - (stick and stick.y or 0) * r, knob)
end

local function drawButton(b, car, s)
  local c = buttonColor(b.action, car)
  -- Boost stays lit for as long as it's on, not just while it's pressed.
  local held = input.isDown(b.action) or (b.action == "boost" and car.model.boostState == "active")
  local a = held and math.max(opacity(), HELD_FLOOR) or opacity()
  local key = string.format("%s|%s|%.2f|%.2f|%s|%s|%.3f|%.2f", b.action, b.label or b.shape,
    b.r, b.size or 0, tostring(c), tostring(held), a, s)
  drawLook(key, math.ceil(b.r + 2 * s + 2), b.x, b.y, paintButton, b, c, held, a, s)
end

function touch.draw(sw, sh, car)
  if not touch.shown() then return end
  local layout = touch.layout(sw, sh)
  if not layout.divide then drawStick(layout) end
  for _, b in ipairs(layout.buttons) do drawButton(b, car, layout.s) end
end

return touch
