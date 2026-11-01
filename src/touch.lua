-- On-screen driving controls: a stick that appears under the left thumb and
-- buttons under the right. The buttons press the same bindings as the keyboard,
-- so a touch is just another pair of hands.
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

function touch.shown()
  if settings.touch == "on" then return true end
  return settings.touch == "auto" and touch.active
end

-- Nitro sits under the resting right thumb with drift just inside it. Reset and
-- pause are up top, where a thumb won't hit them by accident.
function touch.layout(sw, sh)
  local s = ui.scale(sw, sh)
  return {
    s = s,
    radius = STICK_RADIUS * s,
    rest = { x = 62 * s, y = sh - 62 * s },
    buttons = {
      { action = "boost", label = "BOOST", size = 8 * s, x = sw - 52 * s, y = sh - 52 * s, r = 34 * s },
      { action = "handbrake", label = "DRIFT", size = 7 * s, x = sw - 124 * s, y = sh - 40 * s, r = 26 * s },
      { action = "pause", label = "II", size = 7 * s, x = sw - 24 * s, y = 24 * s, r = 17 * s },
      { action = "respawn", label = "RESET", size = 5 * s, x = sw - 62 * s, y = 24 * s, r = 17 * s },
    },
  }
end

local function keyFor(action)
  return input.binds[action][1]
end

function touch.pressed(id, x, y, sw, sh)
  local layout = touch.layout(sw, sh)
  local hit, nearest = nil, math.huge
  for _, b in ipairs(layout.buttons) do
    local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2)
    if d < b.r * HIT_SLOP and d < nearest then hit, nearest = b, d end
  end
  if hit then
    touch.fingers[id] = hit.action
    input.press(keyFor(hit.action))
  elseif x < sw / 2 and not touch.stick then
    touch.stick = { id = id, baseX = x, baseY = y, x = 0, y = 0, radius = layout.radius }
  end
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
    input.release(keyFor(action))
  end
  if touch.stick and touch.stick.id == id then touch.stick = nil end
end

-- Fingers can leave the glass unseen while the game is paused or in the background.
function touch.reset()
  for id in pairs(touch.fingers) do touch.released(id) end
  touch.stick = nil
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
  -- There are no shift buttons on screen.
  target.manual = false
end

-- Drawing ---------------------------------------------------------------------

local function drawStick(layout)
  local stick = touch.stick
  local s, r = layout.s, layout.radius
  local x = stick and stick.baseX or layout.rest.x
  local y = stick and stick.baseY or layout.rest.y
  local alpha = stick and 0.75 or 0.4
  local panel = colors.asphaltDeep
  love.graphics.setColor(panel[1], panel[2], panel[3], alpha * 0.6)
  love.graphics.rectangle("fill", x - r, y - r, r * 2, r * 2, 10 * s)
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.setLineWidth(2 * s)
  love.graphics.rectangle("line", x - r, y - r, r * 2, r * 2, 10 * s)
  local c = colors.marshal
  love.graphics.setColor(c[1], c[2], c[3], alpha + 0.2)
  love.graphics.circle("fill", x + (stick and stick.x or 0) * r, y - (stick and stick.y or 0) * r, 15 * s)
end

local function buttonColor(action, car)
  if action == "boost" then
    local state = car.model.boostState
    if state == "active" then return colors.sectorPurple end
    return state == "cooldown" and colors.muted or colors.sectorGreen
  end
  return action == "handbrake" and colors.marshal or colors.paint
end

local function drawButton(b, car, s)
  local c = buttonColor(b.action, car)
  -- Nitro stays lit for as long as it's on, not just while it's pressed.
  local held = input.isDown(b.action) or (b.action == "boost" and car.model.boostState == "active")
  local panel = colors.asphaltDeep
  if held then
    love.graphics.setColor(c)
  else
    love.graphics.setColor(panel[1], panel[2], panel[3], 0.55)
  end
  love.graphics.circle("fill", b.x, b.y, b.r)
  love.graphics.setColor(c[1], c[2], c[3], 0.9)
  love.graphics.setLineWidth(2 * s)
  love.graphics.circle("line", b.x, b.y, b.r)
  ui.text(b.label, b.x - b.r, b.y - b.size / 2, b.size, held and panel or c, "center", b.r * 2)
end

function touch.draw(sw, sh, car)
  if not touch.shown() then return end
  local layout = touch.layout(sw, sh)
  drawStick(layout)
  for _, b in ipairs(layout.buttons) do drawButton(b, car, layout.s) end
end

return touch
