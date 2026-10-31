-- Draws a car and spawns what it leaves behind: smoke, dust, marks, backfires.
local config = require("src/config")
local sprites = require("src/render/car_sprites")
local textures = require("src/render/textures")
local vfx = require("src/vfx_manager")
local skids = require("src/skid_manager")

local view = {}

local M = config.METER

-- Per-frame effects ------------------------------------------------------

local function wheelFx(car, wheel, trail, dt, speed)
  local x, y = car:wheelWorldPosition(wheel)
  local a = car.body:getAngle()
  local nx, ny = -math.sin(a), math.cos(a)
  local surface = wheel.surface
  local loose = surface == "grass" or surface == "gravel"
  local vx, vy = car.body:getLinearVelocity()
  local spinning = math.max(0, wheel.spin) / 16
  local grip = math.max(wheel.slide, spinning)

  if loose then
    if speed > 3 then
      skids.add(trail, x, y, nx, ny, 0.5, 0.13, 0.11, 0.07)
      vfx.dust(x, y, -vx * 0.6, -vy * 0.6, math.min(1, speed / 30) * 0.8)
    else
      skids.lift(trail)
    end
  elseif grip > 0.32 and speed > 1.5 and surface == "asphalt" then
    skids.add(trail, x, y, nx, ny, math.min(0.62, 0.18 + grip * 0.5), 0.03, 0.03, 0.035)
    vfx.tyreSmoke(x, y, vx, vy, math.min(1, (grip - 0.25) * 1.1))
  else
    skids.lift(trail)
  end
end

function view.updateFx(car, dt)
  car.fx = car.fx or { trails = { {}, {}, {}, {} }, gear = 1, popTimer = 0, warp = 0 }
  local fx = car.fx
  local speed = car:getSpeed()
  local model = car.model
  for i = 1, 4 do wheelFx(car, model.wheels[i], fx.trails[i], dt, speed) end

  -- The warp eases in and out, so a quick tap of nitro never flashes.
  local warpTarget = model.boostState == "active" and 1 or 0
  fx.warp = fx.warp + (warpTarget - fx.warp) * math.min(1, dt * (warpTarget == 1 and 9 or 5))

  local x, y = car.body:getPosition()
  local a = car.body:getAngle()
  local back = a + math.pi
  local ex = x + math.cos(back) * (car.length / 2 + 2)
  local ey = y + math.sin(back) * (car.length / 2 + 2)

  -- A lifted throttle at high revs pops through the exhaust.
  fx.popTimer = fx.popTimer - dt
  if model.gear ~= fx.gear then
    if model.gear > fx.gear and model.rpm > car.spec.redline * 0.75 and fx.popTimer <= 0 then
      vfx.backfire(ex, ey, back)
      fx.popTimer = 0.3
      fx.backfired = true
    end
    fx.gear = model.gear
  end
end

-- Drawing ----------------------------------------------------------------

local function drawWheel(wheel, steer, sprite)
  love.graphics.push()
  love.graphics.translate(wheel.x * M, wheel.y * M)
  if wheel.front then love.graphics.rotate(steer) end
  love.graphics.setColor(0.03, 0.03, 0.035)
  love.graphics.rectangle("fill", -0.34 * M, -0.13 * M, 0.68 * M, 0.26 * M, 2)
  love.graphics.pop()
end

local function warpAmount(car)
  return car.fx and car.fx.warp or 0
end

local WARP_TINTS = { { 1, 1, 1 }, { 1, 0.6, 0.1 }, { 0.98, 0.18, 0.08 } }
local WARP_RING_STEPS = 12

-- A bow wave the car punches through, sweeping back over it.
local function drawWarpRing(car, phase, amount)
  local x = car.length * (0.95 - phase * 1.7)
  local rise = car.width * (0.75 + phase * 0.9)
  local depth = rise * 0.45
  local points = {}
  for i = 0, WARP_RING_STEPS do
    local t = (i / WARP_RING_STEPS - 0.5) * math.pi
    points[#points + 1] = x + math.cos(t) * depth
    points[#points + 1] = math.sin(t) * rise
  end
  local c = WARP_TINTS[phase < 0.5 and 2 or 3]
  love.graphics.setColor(c[1], c[2], c[3], amount * math.sin(phase * math.pi))
  love.graphics.line(points)
end

-- Nitro is the slipstream turned up to a warp: needles of light tear past both
-- sides, opening out from the nose, with red and orange among the white.
local function drawWarp(car, alpha)
  local amount = warpAmount(car) * alpha
  if amount < 0.02 then return end
  local hl, hw = car.length / 2, car.width / 2
  local time = love.timer.getTime()
  love.graphics.setLineWidth(0.22 * M)
  for i = 1, 3 do drawWarpRing(car, (time * 1.7 + i / 3) % 1, amount) end
  for i = 1, 20 do
    local phase = (time * 3.4 + i * 0.618) % 1
    local side = i % 2 == 0 and 1 or -1
    local offset = (hw + (0.3 + (i * 7 % 5) * 0.5) * M) * (0.6 + phase * 0.8)
    local front = hl * 2.2 - phase * car.length * 3.6
    local len = (2.4 + (i % 4) * 1.1) * M
    local width = (i % 3 == 1 and 0.16 or 0.26) * M
    local c = WARP_TINTS[i % 3 + 1]
    love.graphics.setColor(c[1], c[2], c[3], amount * math.sin(phase * math.pi))
    love.graphics.polygon("fill", front, side * offset, front - len * 0.3, side * offset - width,
      front - len, side * offset, front - len * 0.3, side * offset + width)
  end
end

function view.drawShadow(car, x, y, angle, env, alpha)
  local sprite = sprites.get(car.spec)
  local len = env.shadowLength
  love.graphics.setColor(0, 0, 0, env.shadowAlpha * (alpha or 1))
  love.graphics.draw(sprite.shadow, x + env.sun[1] * len * 0.55, y + env.sun[2] * len * 0.55,
    angle, sprite.scale * 1.04, sprite.scale * 1.04, sprite.ox, sprite.oy)
end

-- Air rushing down both sides of a car that is being towed.
local function drawSlipstream(car, alpha)
  -- The warp takes over from these while nitro is on.
  local amount = car.model.slipstream * (1 - warpAmount(car))
  if amount < 0.05 then return end
  local hl, hw = car.length / 2, car.width / 2
  local time = love.timer.getTime()
  love.graphics.setLineWidth(0.14 * M)
  for i = 1, 8 do
    local phase = (time * 2.4 + i * 0.37) % 1
    local side = (i % 2 == 0 and 1 or -1) * (hw + (0.3 + (i % 3) * 0.4) * M)
    local front = hl * 1.5 - phase * car.length * 2.6
    local len = (1.4 + (i % 3) * 0.6) * M
    love.graphics.setColor(1, 1, 1, 0.9 * amount * alpha * math.sin(phase * math.pi))
    love.graphics.line(front, side, front - len, side)
  end
end

function view.draw(car, x, y, angle, alpha)
  alpha = alpha or 1
  if car.ghostTimer > 0 then alpha = alpha * (0.4 + 0.25 * math.sin(car.ghostTimer * 22)) end
  local sprite = sprites.get(car.spec)
  local model = car.model

  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.rotate(angle)

  drawWarp(car, alpha)
  drawSlipstream(car, alpha)
  for i = 1, 4 do drawWheel(model.wheels[i], model.steer, sprite) end

  -- The body leans a pixel or two against the suspension.
  local roll = math.max(-1, math.min(1, model.ay / 12)) * 1.4
  local pitch = math.max(-1, math.min(1, -model.ax / 12)) * 1.4
  local c = car.color
  love.graphics.setColor(c[1], c[2], c[3], alpha)
  love.graphics.draw(sprite.paint, pitch, roll, 0, sprite.scale, sprite.scale, sprite.ox, sprite.oy)
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(sprite.detail, pitch, roll, 0, sprite.scale, sprite.scale, sprite.ox, sprite.oy)
  love.graphics.pop()
end

local function lamp(x, y, angle, ox, oy, r, g, b, a, size)
  local ca, sa = math.cos(angle), math.sin(angle)
  local blob = textures.blob
  local s = size / blob:getWidth()
  love.graphics.setColor(r, g, b, a)
  love.graphics.draw(blob, x + ox * ca - oy * sa, y + ox * sa + oy * ca, 0, s, s, 32, 32)
end

-- Lamps as emissive light, for the scene and the glow pass.
function view.drawLamps(car, x, y, angle)
  local hl, hw = car.length / 2, car.width / 2
  local model = car.model
  local braking = model.brake > 0.05
  local reversing = model.reverse
  local warp = warpAmount(car)
  if warp > 0.02 then lamp(x, y, angle, 0, 0, 1, 0.3, 0.08, 0.45 * warp, 11 * M) end
  if braking then
    lamp(x, y, angle, -hl, -hw * 0.62, 1, 0.08, 0.05, 1, 3.4 * M)
    lamp(x, y, angle, -hl, hw * 0.62, 1, 0.08, 0.05, 1, 3.4 * M)
  elseif car.lowBeam or car.highBeam then
    lamp(x, y, angle, -hl, -hw * 0.62, 0.7, 0.05, 0.04, 0.7, 2.2 * M)
    lamp(x, y, angle, -hl, hw * 0.62, 0.7, 0.05, 0.04, 0.7, 2.2 * M)
  end
  if reversing then
    lamp(x, y, angle, -hl, -hw * 0.3, 1, 1, 1, 0.8, 1.8 * M)
    lamp(x, y, angle, -hl, hw * 0.3, 1, 1, 1, 0.8, 1.8 * M)
  end
  if car.lowBeam or car.highBeam then
    local b = car.highBeam and 1 or 0.7
    lamp(x, y, angle, hl * 0.92, -hw * 0.66, 1, 0.96, 0.82, b, 2.6 * M)
    lamp(x, y, angle, hl * 0.92, hw * 0.66, 1, 0.96, 0.82, b, 2.6 * M)
  end
end

-- Pools of light on the road, for the night lightmap.
function view.drawBeams(car, x, y, angle)
  local hl = car.length / 2
  local ca, sa = math.cos(angle), math.sin(angle)
  if car.lowBeam or car.highBeam then
    local beam = textures.beam
    local bw, bh = beam:getDimensions()
    local length = (car.highBeam and 120 or 74) * M
    local width = (car.highBeam and 52 or 46) * M
    local power = car.highBeam and 1.4 or 1.1
    love.graphics.setColor(power, power * 0.96, power * 0.86, 1)
    love.graphics.draw(beam, x + ca * hl, y + sa * hl, angle, length / bw, width / bh, 0, bh / 2)
  end
  local glow = textures.blob
  local s = 14 * M / glow:getWidth()
  love.graphics.setColor(0.3, 0.3, 0.32, 1)
  love.graphics.draw(glow, x, y, 0, s, s, 32, 32)
  if car.model.brake > 0.05 then
    love.graphics.setColor(0.7, 0.06, 0.04, 1)
    love.graphics.draw(glow, x - ca * hl * 1.5, y - sa * hl * 1.5, 0, s * 0.8, s * 0.8, 32, 32)
  end
end

return view
