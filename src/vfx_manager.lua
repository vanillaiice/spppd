-- Particle effects. Each one is tuned to read clearly and then get out of
-- the way: short-lived, soft, and capped so a pile-up can't fill the screen.
local textures = require("src/render/textures")
local config = require("src/config")

local vfx = {}

local M = config.METER
local DEBRIS_MAX = 90     -- pieces of car on the ground at once
local DEBRIS_GRAVITY = 14 -- m/s², a bit more than real, so pieces land smartly
local DEBRIS_GRIP = 5     -- how quickly a piece slides to a stop on the ground

local function newSystem(image, buffer)
  local ps = love.graphics.newParticleSystem(image, buffer)
  ps:setEmissionRate(0)
  ps:setInsertMode("random")
  return ps
end

function vfx.load(dustColor)
  textures.load()
  local dust = dustColor or { 0.5, 0.42, 0.28 }

  local smoke = newSystem(textures.smoke, 700)
  smoke:setParticleLifetime(0.8, 1.9)
  smoke:setSizes(0.22, 0.62, 1.15)
  smoke:setSizeVariation(0.5)
  smoke:setSpin(-0.6, 0.6)
  smoke:setRotation(0, math.pi * 2)
  smoke:setLinearDamping(1.6, 2.6)
  smoke:setColors(0.82, 0.82, 0.84, 0.0, 0.8, 0.8, 0.82, 0.17, 0.7, 0.7, 0.72, 0.09, 0.62, 0.62, 0.64, 0)
  vfx.smoke = smoke

  local dirt = newSystem(textures.smoke, 500)
  dirt:setParticleLifetime(0.5, 1.3)
  dirt:setSizes(0.18, 0.5, 0.82)
  dirt:setSizeVariation(0.6)
  dirt:setLinearDamping(1.8, 3)
  dirt:setRotation(0, math.pi * 2)
  dirt:setColors(dust[1], dust[2], dust[3], 0.0, dust[1], dust[2], dust[3], 0.3, dust[1], dust[2], dust[3], 0)
  vfx.dirt = dirt

  local sparks = newSystem(textures.spark, 400)
  sparks:setParticleLifetime(0.12, 0.42)
  sparks:setSizes(0.4, 0.22, 0.05)
  sparks:setSpeed(140, 520)
  sparks:setSpread(math.pi * 0.7)
  sparks:setLinearDamping(2, 4)
  sparks:setColors(1, 0.95, 0.75, 1, 1, 0.68, 0.22, 1, 1, 0.3, 0.05, 0)
  vfx.sparks = sparks

  local pop = newSystem(textures.smoke, 60)
  pop:setParticleLifetime(0.04, 0.1)
  pop:setSizes(0.14, 0.24, 0.02)
  pop:setSpeed(40, 120)
  pop:setSpread(0.5)
  pop:setColors(1, 0.8, 0.4, 0.9, 1, 0.35, 0.08, 0)
  vfx.pop = pop

  -- A jet of fire from the exhaust, cooling from yellow through orange to red as
  -- it leaves. Short enough to stay a tongue rather than a cloud, and faint on its
  -- own, because the particles pile up under additive blending.
  local flame = newSystem(textures.smoke, 360)
  flame:setParticleLifetime(0.08, 0.22)
  flame:setSizes(0.08, 0.26, 0.22, 0.05)
  flame:setSizeVariation(0.4)
  flame:setSpin(-3, 3)
  flame:setRotation(0, math.pi * 2)
  flame:setLinearDamping(3, 5)
  flame:setColors(1, 0.85, 0.55, 0.55, 1, 0.6, 0.15, 0.5, 0.95, 0.28, 0.05, 0.35, 0.6, 0.08, 0.02, 0)
  vfx.fire = flame

  -- The blue at the pipe, where it burns hottest. Added light piles up to white
  -- there, so this one is laid over the top with plain blending to stay blue.
  local core = newSystem(textures.smoke, 160)
  core:setParticleLifetime(0.07, 0.14)
  core:setSizes(0.13, 0.21, 0.07)
  core:setSizeVariation(0.3)
  core:setColors(0.3, 0.55, 1, 0.9, 0.15, 0.35, 1, 0.6, 0.1, 0.2, 0.9, 0)
  vfx.fireCore = core

  -- Thick dark smoke from a wreck, heavier and slower to clear than tyre smoke.
  local soot = newSystem(textures.smoke, 320)
  soot:setParticleLifetime(0.9, 1.9)
  soot:setSizes(0.3, 0.85, 1.5)
  soot:setSizeVariation(0.5)
  soot:setSpin(-0.5, 0.5)
  soot:setRotation(0, math.pi * 2)
  soot:setLinearDamping(1.4, 2.4)
  soot:setColors(0.16, 0.15, 0.15, 0.0, 0.2, 0.19, 0.19, 0.4, 0.3, 0.29, 0.29, 0.22, 0.42, 0.41, 0.41, 0)
  vfx.soot = soot

  vfx.debris = {}
  vfx.density = 1
end

local function aim(ps, x, y, vx, vy, jitter)
  ps:setPosition(x, y)
  local speed = math.sqrt(vx * vx + vy * vy)
  ps:setDirection(math.atan2(vy, vx))
  ps:setSpeed(speed * (1 - jitter), speed * (1 + jitter))
  ps:setSpread(0.5)
end

function vfx.tyreSmoke(x, y, vx, vy, amount)
  if love.math.random() > amount * vfx.density then return end
  aim(vfx.smoke, x, y, vx * 0.2, vy * 0.2, 0.5)
  vfx.smoke:emit(1)
end

function vfx.dust(x, y, vx, vy, amount)
  if love.math.random() > amount * vfx.density then return end
  aim(vfx.dirt, x, y, vx * 0.3, vy * 0.3, 0.6)
  vfx.dirt:emit(1)
end

function vfx.scrape(x, y, nx, ny, strength)
  vfx.sparks:setPosition(x, y)
  vfx.sparks:setDirection(math.atan2(ny, nx))
  vfx.sparks:emit(math.min(26, math.floor(4 + strength * 10)))
end

function vfx.backfire(x, y, angle)
  vfx.pop:setPosition(x, y)
  vfx.pop:setDirection(angle)
  vfx.pop:emit(4)
end

-- vx, vy is how the fire leaves: the car's own velocity plus the jet.
function vfx.flame(x, y, vx, vy, count)
  aim(vfx.fire, x, y, vx, vy, 0.3)
  vfx.fire:setSpread(0.25)
  vfx.fire:emit(count)
  aim(vfx.fireCore, x, y, vx, vy, 0.2)
  vfx.fireCore:setSpread(0.15)
  vfx.fireCore:emit(math.ceil(count / 2))
end

-- A puff of dark smoke at x, y, drifting at vx, vy px/s.
function vfx.smokeBurst(x, y, vx, vy, count)
  aim(vfx.soot, x, y, vx, vy, 0.8)
  vfx.soot:setSpread(math.pi * 2)
  vfx.soot:emit(math.max(1, math.floor(count * vfx.density + 0.5)))
end

-- Bits of a car thrown off at x, y: outward along nx, ny, on top of the car's own
-- velocity vx, vy (px/s), fanned spread radians either side. Most are paint,
-- some black plastic, a few glass.
function vfx.shatter(x, y, nx, ny, vx, vy, count, paint, spread)
  local list = vfx.debris
  local random = love.math.random
  count = math.floor(count * vfx.density + 0.5)
  for _ = 1, count do
    local roll = random()
    local color
    if roll < 0.6 then
      local shade = 0.75 + random() * 0.25
      color = { paint[1] * shade, paint[2] * shade, paint[3] * shade }
    elseif roll < 0.85 then
      color = { 0.07, 0.07, 0.08 }
    else
      color = { 0.75, 0.88, 0.95 }
    end
    local out = (3 + random() * 9) * M
    local turn = (random() * 2 - 1) * (spread or 1.1)
    local dx = nx * math.cos(turn) - ny * math.sin(turn)
    local dy = nx * math.sin(turn) + ny * math.cos(turn)
    local size = roll < 0.85 and (0.25 + random() * 0.3) or (0.12 + random() * 0.12)
    local piece = {
      x = x, y = y, z = 0.4 + random() * 0.4,
      vx = vx * (0.4 + random() * 0.3) + dx * out, vy = vy * (0.4 + random() * 0.3) + dy * out,
      vz = 2 + random() * 4,
      angle = random() * math.pi * 2, spin = (random() - 0.5) * 24,
      w = size * M, h = size * (0.4 + random() * 0.5) * M,
      color = color, age = 0, life = 2.5 + random() * 1.5,
    }
    if #list < DEBRIS_MAX then
      list[#list + 1] = piece
    else
      list[random(#list)] = piece
    end
  end
end

local function updateDebris(dt)
  local list = vfx.debris
  local i = 1
  while i <= #list do
    local p = list[i]
    p.age = p.age + dt
    if p.age >= p.life then
      list[i] = list[#list]
      list[#list] = nil
    else
      if p.z > 0 or p.vz > 0 then
        p.vz = p.vz - DEBRIS_GRAVITY * dt
        p.z = p.z + p.vz * dt
        if p.z <= 0 then
          p.z = 0
          -- One small bounce, then it skids.
          if p.vz < -3 then p.vz = -p.vz * 0.3 else p.vz = 0 end
          p.vx, p.vy, p.spin = p.vx * 0.6, p.vy * 0.6, p.spin * 0.5
        end
      else
        local grip = math.exp(-DEBRIS_GRIP * dt)
        p.vx, p.vy, p.spin = p.vx * grip, p.vy * grip, p.spin * grip
      end
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      p.angle = p.angle + p.spin * dt
      i = i + 1
    end
  end
end

local function drawDebris()
  for _, p in ipairs(vfx.debris) do
    -- Higher up is nearer the camera, so a little bigger.
    local s = 1 + p.z * 0.35
    local hw, hh = p.w * s / 2, p.h * s / 2
    local c, sn = math.cos(p.angle), math.sin(p.angle)
    local ax, ay = c * hw, sn * hw
    local bx, by = -sn * hh, c * hh
    local fade = math.min(1, (p.life - p.age) / 0.6)
    love.graphics.setColor(p.color[1], p.color[2], p.color[3], fade)
    love.graphics.polygon("fill", p.x + ax + bx, p.y + ay + by, p.x - ax + bx, p.y - ay + by,
      p.x - ax - bx, p.y - ay - by, p.x + ax - bx, p.y + ay - by)
  end
end

function vfx.update(dt)
  vfx.smoke:update(dt)
  vfx.dirt:update(dt)
  vfx.sparks:update(dt)
  vfx.pop:update(dt)
  vfx.fire:update(dt)
  vfx.fireCore:update(dt)
  vfx.soot:update(dt)
  updateDebris(dt)
end

-- Ground-hugging smoke and dust, the bits of a crash, and the smoke over it.
function vfx.draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(vfx.dirt)
  love.graphics.draw(vfx.smoke)
  drawDebris()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(vfx.soot)
end

-- Anything that emits its own light, drawn into the scene and the glow pass.
function vfx.drawEmissive()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("add")
  love.graphics.draw(vfx.fire)
  love.graphics.draw(vfx.pop)
  love.graphics.draw(vfx.sparks)
  love.graphics.setBlendMode("alpha")
  love.graphics.draw(vfx.fireCore)
end

return vfx
