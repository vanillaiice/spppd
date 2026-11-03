-- Particle effects. Each one is tuned to read clearly and then get out of
-- the way: short-lived, soft, and capped so a pile-up can't fill the screen.
local textures = require("src/render/textures")

local vfx = {}

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
  flame:setSizes(0.18, 0.34, 0.26, 0.06)
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
  core:setSizes(0.2, 0.26, 0.08)
  core:setSizeVariation(0.3)
  core:setColors(0.3, 0.55, 1, 0.9, 0.15, 0.35, 1, 0.6, 0.1, 0.2, 0.9, 0)
  vfx.fireCore = core

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

function vfx.update(dt)
  vfx.smoke:update(dt)
  vfx.dirt:update(dt)
  vfx.sparks:update(dt)
  vfx.pop:update(dt)
  vfx.fire:update(dt)
  vfx.fireCore:update(dt)
end

-- Ground-hugging smoke and dust.
function vfx.draw()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(vfx.dirt)
  love.graphics.draw(vfx.smoke)
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
