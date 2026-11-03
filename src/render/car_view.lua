-- Draws a car and spawns what it leaves behind: smoke, dust, marks, backfires.
local config = require("src/config")
local sprites = require("src/render/car_sprites")
local textures = require("src/render/textures")
local vfx = require("src/vfx_manager")
local skids = require("src/skid_manager")

local view = {}

local M = config.METER
local FLAME_RATE = 110     -- particles a second at full strength
local FLAME_JET = 260      -- px/s the fire leaves the exhaust, on top of the car's speed
local FLAME_TAPER = 0.4    -- seconds it takes to die away at the end
local FLAME_CRACKLE = 6    -- pops a second, on average
local NEON_PULSE = 2.2     -- radians a second

-- Per-frame effects ------------------------------------------------------

-- Lights the exhaust for the flame cheat.
local function fxOf(car)
  car.fx = car.fx or { trails = { {}, {}, {}, {} }, gear = 1, popTimer = 0, warp = 0 }
  return car.fx
end

function view.flames(car, seconds)
  fxOf(car).flameTime = seconds
end

local function flaming(car)
  return car.fx and car.fx.flameTime and car.fx.flameTime > 0
end

-- The neon cheat's colour: the paint at full strength, or cyan for a grey car.
local function neonColor(car)
  local c = car.color
  local hi, lo = math.max(c[1], c[2], c[3]), math.min(c[1], c[2], c[3])
  if hi - lo < 0.15 then return 0.1, 0.9, 1 end
  local function push(v) return (v - lo) / (hi - lo) end
  return push(c[1]), push(c[2]), push(c[3])
end

local function wheelFx(car, wheel, trail, speed)
  local x, y = car:wheelWorldPosition(wheel)
  local a = car.body:getAngle()
  local shift = sprites.layout(car.spec) * M
  x, y = x + math.cos(a) * shift, y + math.sin(a) * shift
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
  local fx = fxOf(car)
  local speed = car:getSpeed()
  local model = car.model
  for i = 1, 4 do wheelFx(car, model.wheels[i], fx.trails[i], speed) end

  -- The warp eases in and out, so a quick tap of nitro never flashes.
  local warpTarget = model.boostState == "active" and 1 or 0
  fx.warp = fx.warp + (warpTarget - fx.warp) * math.min(1, dt * (warpTarget == 1 and 9 or 5))

  local x, y = car.body:getPosition()
  local a = car.body:getAngle()
  local back = a + math.pi
  local ex = x + math.cos(back) * (car.length / 2 + 2)
  local ey = y + math.sin(back) * (car.length / 2 + 2)

  -- An upshift at high revs pops through the exhaust.
  fx.popTimer = fx.popTimer - dt
  if model.gear ~= fx.gear then
    if model.gear > fx.gear and model.rpm > car.spec.redline * 0.75 and fx.popTimer <= 0 then
      vfx.backfire(ex, ey, back)
      fx.popTimer = 0.3
    end
    fx.gear = model.gear
  end

  -- The flame cheat: a jet of fire, strongest at first and dying off at the end.
  if fx.flameTime and fx.flameTime > 0 then
    fx.flameTime = math.max(0, fx.flameTime - dt)
    local strength = math.min(1, fx.flameTime / FLAME_TAPER) * (0.75 + 0.25 * love.math.random())
    local vx, vy = car.body:getLinearVelocity()
    local jet = FLAME_JET * (0.6 + 0.4 * strength)
    fx.flameCarry = (fx.flameCarry or 0) + FLAME_RATE * strength * vfx.density * dt
    local count = math.floor(fx.flameCarry)
    fx.flameCarry = fx.flameCarry - count
    if count > 0 then
      vfx.flame(ex, ey, vx + math.cos(back) * jet, vy + math.sin(back) * jet, count)
    end
    if love.math.random() < dt * FLAME_CRACKLE then vfx.backfire(ex, ey, back) end
  end

  -- A wreck smokes from under the bonnet until it's put back on the road.
  if car.wreck then
    local front = car.length / 2 - 4
    vfx.tyreSmoke(x + math.cos(a) * front, y + math.sin(a) * front, 0, 0, 0.8)
  end
end

-- Drawing ----------------------------------------------------------------

local function drawWheel(wheel, steer, shift)
  love.graphics.push()
  love.graphics.translate((wheel.x + shift) * M, wheel.y * M)
  if wheel.front then love.graphics.rotate(steer) end
  love.graphics.setColor(0.03, 0.03, 0.035)
  love.graphics.rectangle("fill", -0.34 * M, -0.13 * M, 0.68 * M, 0.26 * M, 2)
  love.graphics.pop()
end

local function warpAmount(car)
  return car.fx and car.fx.warp or 0
end

-- A thin pointed wisp of air running along the car, fading in and out as it
-- passes. Plain white and faint: it should read as moving air, not as an effect.
local function drawWisp(front, y, len, width, a)
  love.graphics.setColor(1, 1, 1, a)
  love.graphics.polygon("fill", front, y, front - len * 0.3, y - width, front - len, y, front - len * 0.3, y + width)
end

-- Nitro is the slipstream at a harder pace: more air, moving faster.
local function drawWarp(car, alpha)
  local amount = warpAmount(car) * alpha
  if amount < 0.02 then return end
  local hl, hw = car.length / 2, car.width / 2
  local time = love.timer.getTime()
  for i = 1, 12 do
    local phase = (time * 3.4 + i * 0.618) % 1
    local side = i % 2 == 0 and 1 or -1
    local offset = (hw + (0.3 + (i * 7 % 5) * 0.4) * M) * (0.8 + phase * 0.4)
    local front = hl * 1.6 - phase * car.length * 3
    local len = (2 + (i % 4) * 0.9) * M
    drawWisp(front, side * offset, len, 0.07 * M, 0.55 * amount * math.sin(phase * math.pi))
  end
end

function view.drawShadow(car, x, y, angle, env, alpha)
  local sprite = sprites.get(car.spec)
  local len = env.shadowLength
  love.graphics.setColor(0, 0, 0, env.shadowAlpha * (alpha or 1))
  love.graphics.draw(sprite.shadow, x + env.sun[1] * len * 0.55, y + env.sun[2] * len * 0.55,
    angle, sprite.scale * 1.04, sprite.scale * 1.04, sprite.ox, sprite.oy)
end

-- Air sliding down both sides of a car that is being towed.
local function drawSlipstream(car, alpha)
  -- The warp takes over from these while nitro is on.
  local amount = car.model.slipstream * (1 - warpAmount(car))
  if amount < 0.05 then return end
  local hl, hw = car.length / 2, car.width / 2
  local time = love.timer.getTime()
  for i = 1, 6 do
    local phase = (time * 1.6 + i * 0.37) % 1
    local side = (i % 2 == 0 and 1 or -1) * (hw + (0.2 + (i % 3) * 0.3) * M)
    local front = hl * 0.9 - phase * car.length * 2.2
    local len = (1.6 + (i % 3) * 0.6) * M
    drawWisp(front, side, len, 0.06 * M, 0.4 * amount * alpha * math.sin(phase * math.pi))
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
  if car.neon then
    local blob = textures.blob
    local r, g, b = neonColor(car)
    local pulse = 0.85 + 0.15 * math.sin(love.timer.getTime() * NEON_PULSE)
    love.graphics.setBlendMode("add")
    love.graphics.setColor(r, g, b, pulse * alpha)
    love.graphics.draw(blob, 0, 0, 0, car.length * 1.6 / blob:getWidth(), car.width * 3 / blob:getHeight(),
      blob:getWidth() / 2, blob:getHeight() / 2)
    love.graphics.setBlendMode("alpha")
  end
  local shift = sprites.layout(car.spec)
  for i = 1, 4 do drawWheel(model.wheels[i], model.steer, shift) end

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
  local _, head, tail = sprites.layout(car.spec)
  local tx, ty = -hl * tail[1], hw * tail[2]
  if braking then
    lamp(x, y, angle, tx, -ty, 1, 0.08, 0.05, 1, 3.4 * M)
    lamp(x, y, angle, tx, ty, 1, 0.08, 0.05, 1, 3.4 * M)
  elseif car.lowBeam or car.highBeam then
    lamp(x, y, angle, tx, -ty, 0.7, 0.05, 0.04, 0.7, 2.2 * M)
    lamp(x, y, angle, tx, ty, 0.7, 0.05, 0.04, 0.7, 2.2 * M)
  end
  if reversing then
    lamp(x, y, angle, -hl, -hw * 0.3, 1, 1, 1, 0.8, 1.8 * M)
    lamp(x, y, angle, -hl, hw * 0.3, 1, 1, 1, 0.8, 1.8 * M)
  end
  if car.lowBeam or car.highBeam then
    local b = car.highBeam and 1 or 0.7
    lamp(x, y, angle, hl * head[1], -hw * head[2], 1, 0.96, 0.82, b, 2.6 * M)
    lamp(x, y, angle, hl * head[1], hw * head[2], 1, 0.96, 0.82, b, 2.6 * M)
  end
  if flaming(car) then
    local flicker = 0.6 + 0.4 * love.math.random()
    lamp(x, y, angle, -hl - 0.4 * M, 0, 1, 0.45, 0.1, flicker * 0.6, 3 * M)
  end
end

-- Pools of light on the road, for the night lightmap.
function view.drawBeams(car, x, y, angle, beams)
  local hl = car.length / 2
  local ca, sa = math.cos(angle), math.sin(angle)
  if car.lowBeam or car.highBeam then
    local on = car.highBeam and beams.high or beams.low
    local beam = textures.beam
    local bw, bh = beam:getDimensions()
    love.graphics.setColor(on.power, on.power * 0.96, on.power * 0.86, 1)
    love.graphics.draw(beam, x + ca * hl, y + sa * hl, angle, on.length * M / bw, on.width * M / bh, 0, bh / 2)
  end
  local glow = textures.blob
  local s = 14 * M / glow:getWidth()
  love.graphics.setColor(0.3, 0.3, 0.32, 1)
  love.graphics.draw(glow, x, y, 0, s, s, 32, 32)
  -- Tail lights are how a rival shows up in the dark.
  local braking = car.model.brake > 0.05
  if braking or car.lowBeam or car.highBeam then
    local red = braking and 0.7 or 0.3
    love.graphics.setColor(red, red * 0.09, red * 0.06, 1)
    love.graphics.draw(glow, x - ca * hl * 1.5, y - sa * hl * 1.5, 0, s * 0.8, s * 0.8, 32, 32)
  end
  if flaming(car) then
    local f = 0.7 + 0.3 * love.math.random()
    love.graphics.setColor(f, f * 0.5, f * 0.15, 1)
    love.graphics.draw(glow, x - ca * hl * 1.8, y - sa * hl * 1.8, 0, s, s, 32, 32)
  end
  if car.neon then
    local r, g, b = neonColor(car)
    love.graphics.setColor(r * 0.6, g * 0.6, b * 0.6, 1)
    love.graphics.draw(glow, x, y, angle, s * 0.75, s * 0.45, 32, 32)
  end
end

return view
