-- Scripted driving for measuring the sound: no physics, just the fields audio.update
-- reads, set by hand so the same moment can be replayed on every car and on both
-- the old and the new sounds. dump.lua logs what the mix does with them.
local scenes = {}

-- A car as src/audio.lua sees it.
function scenes.car(spec)
  local wheels = {}
  for i = 1, 4 do wheels[i] = { surface = "asphalt", slide = 0, spin = 0 } end
  local car = {
    spec = spec, horn = false, speed = 0, scraping = 0,
    model = {
      rpm = spec.idleRpm, throttle = 0, brake = 0, shiftTimer = 0, limiting = false, slipstream = 0,
      boostState = "ready", boostTank = spec.boostTime, wheels = wheels,
    },
  }
  function car.getSpeed(self) return self.speed end
  return car
end

-- A crash as race_manager.processImpacts reports it. strength is impulse / 9000.
-- The old module took a volume and a flag instead.
function scenes.hit(audio, strength, spec)
  if audio.IMPACT_TIERS then
    audio.impact(strength, spec)
  else
    audio.impact(math.min(1, 0.25 + strength), strength < 0.15)
  end
end

local function revs(car, ratio)
  car.model.rpm = car.spec.idleRpm + (car.spec.redline - car.spec.idleRpm) * ratio
end

local function slide(car, amount)
  for _, wheel in ipairs(car.model.wheels) do wheel.slide = amount end
end

local function surface(car, name)
  for _, wheel in ipairs(car.model.wheels) do wheel.surface = name end
end

scenes.list = {
  { name = "idle", seconds = 3, drive = function(car) car.speed = 0 end },
  -- Full throttle from idle to the redline with no gear changes: every rpm once.
  { name = "sweep", seconds = 8, drive = function(car, u)
    car.model.throttle, car.speed = 1, 8 + u * 52
    revs(car, u)
  end },
  { name = "cruise", seconds = 4, drive = function(car)
    car.model.throttle, car.speed = 1, 40
    revs(car, 0.7)
  end },
  { name = "lift", seconds = 3, drive = function(car, u)
    car.speed = 40
    car.model.throttle = u < 0.2 and 1 or 0
    revs(car, u < 0.2 and 0.9 or 0.9 - (u - 0.2) * 0.8)
  end },
  { name = "limiter", seconds = 3, drive = function(car)
    car.model.throttle, car.speed, car.model.limiting = 1, 0, car.spec.cylinders > 0
    revs(car, 1)
  end },
  { name = "drift", seconds = 4, drive = function(car)
    car.model.throttle, car.speed = 1, 28
    revs(car, 0.75)
    slide(car, 0.9)
  end },
  { name = "grass", seconds = 4, drive = function(car)
    car.model.throttle, car.speed = 1, 28
    revs(car, 0.75)
    surface(car, "grass")
  end },
  -- The most that plays at once short of a crash.
  { name = "flatout", seconds = 4, drive = function(car)
    car.model.throttle, car.speed, car.model.boostState = 1, 75, "active"
    car.model.slipstream = 0.5
    revs(car, 0.9)
    slide(car, 0.9)
  end },
  { name = "grind", seconds = 4, drive = function(car, u)
    car.model.throttle, car.speed = 1, 35
    car.scraping = (u > 0.25 and u < 0.75) and 1 or 0
    revs(car, 0.7)
  end },
  -- Upshifts through a steady pull, as race_manager plays them.
  { name = "shifts", seconds = 4, drive = function(car, _, t)
    car.model.throttle, car.speed = 1, 40
    revs(car, 0.8)
    car.model.shiftTimer = (t % 1 > 0.5 and t % 1 < 0.61) and 0.05 or 0
  end, events = {
    { at = 0.5, fire = function(audio) audio.play("shift", audio.SHIFT_LEVEL or 0.42, 1) end, label = "shift" },
    { at = 1.5, fire = function(audio) audio.play("shift", audio.SHIFT_LEVEL or 0.42, 1) end, label = "shift" },
    { at = 2.5, fire = function(audio) audio.play("shift", audio.SHIFT_LEVEL or 0.42, 1) end, label = "shift" },
  } },
  -- One of each size of crash over a steady drive, by strength.
  { name = "crashes", seconds = 8, drive = function(car)
    car.model.throttle, car.speed = 1, 40
    revs(car, 0.7)
  end, events = {
    { at = 1, fire = function(audio) scenes.hit(audio, 0.1) end, label = "graze 0.1" },
    { at = 2, fire = function(audio) scenes.hit(audio, 0.4) end, label = "tap 0.4" },
    { at = 3, fire = function(audio) scenes.hit(audio, 1) end, label = "hit 1" },
    { at = 4, fire = function(audio) scenes.hit(audio, 3) end, label = "hit 3" },
    { at = 5, fire = function(audio) scenes.hit(audio, 8) end, label = "crash 8" },
    { at = 6, fire = function(audio) scenes.hit(audio, 25) end, label = "crash 25" },
  } },
}

return scenes
