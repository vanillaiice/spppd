-- All sound is synthesised at load time: no audio files ship with the game.
-- The engine is two loops cross-faded by rpm and pitched to match.
local audio = { voices = {}, ready = false }

local RATE = 44100

local function soundData(seconds, fn)
  local samples = math.floor(seconds * RATE)
  local data = love.sound.newSoundData(samples, RATE, 16, 1)
  for i = 0, samples - 1 do
    local v = fn(i / RATE, i, samples)
    data:setSample(i, math.max(-1, math.min(1, v)))
  end
  return data
end

-- One engine cycle repeated, so the loop point is inaudible. Each firing
-- pulse differs slightly, which is what makes it sound like an engine.
function audio.engineData(baseHz, brightness)
  local period = math.floor(RATE / baseHz + 0.5)
  local cycles = 8
  local samples = period * cycles
  local rng = love.math.newRandomGenerator(77)
  local phases, levels = {}, {}
  for h = 1, 26 do
    phases[h] = rng:random() * math.pi * 2
    levels[h] = (1 / h ^ (1.25 - brightness * 0.5)) * (0.7 + rng:random() * 0.6)
  end
  local fireAmp = {}
  for i = 1, cycles do fireAmp[i] = 0.82 + rng:random() * 0.36 end

  return soundData(samples / RATE, function(_, i)
    local u = i / samples
    local total = 0
    for h = 1, 26 do
      total = total + math.sin(u * math.pi * 2 * h * cycles + phases[h]) * levels[h]
    end
    local firing = fireAmp[math.floor(u * cycles) + 1]
    -- Sub-harmonic throb across the whole loop
    total = total + math.sin(u * math.pi * 2 * cycles / 2) * 0.5
    return total * firing * 0.26
  end)
end

local function noiseLoop(seconds, colour, gain)
  local rng = love.math.newRandomGenerator(5)
  local last, slow = 0, 0
  local fadeTime = 0.1
  local base = soundData(seconds + fadeTime, function()
    local white = rng:random() * 2 - 1
    last = last + (white - last) * colour
    slow = slow + (last - slow) * colour * 0.25
    return (last - slow * 0.6) * gain
  end)
  -- Cross-fade the tail over the head so the loop has no click.
  local n = math.floor(seconds * RATE)
  local fade = math.floor(fadeTime * RATE)
  return soundData(seconds, function(_, i)
    local v = base:getSample(i)
    if i < fade then
      local t = i / fade
      v = v * t + base:getSample(n + i) * (1 - t)
    end
    return v
  end)
end

function audio.squealData()
  local period = math.floor(RATE / 8)
  return soundData(period * 4 / RATE, function(t, i, samples)
    local u = i / samples
    local wob = math.sin(u * math.pi * 2 * 3) * 0.012
    local a = math.sin(u * math.pi * 2 * 225 * (1 + wob))
    local b = math.sin(u * math.pi * 2 * 340 * (1 - wob)) * 0.6
    local c = math.sin(u * math.pi * 2 * 512) * 0.3
    return (a + b + c) * 0.34
  end)
end

local function burst(seconds, thump, noise, decay)
  local rng = love.math.newRandomGenerator(9)
  local last = 0
  return soundData(seconds, function(t)
    local env = math.exp(-t * decay)
    last = last + (rng:random() * 2 - 1 - last) * 0.4
    return (math.sin(t * math.pi * 2 * thump * (1 + env)) * 0.8 + last * noise) * env
  end)
end

local function tone(seconds, hz, decay)
  return soundData(seconds, function(t)
    local env = math.min(1, t * 200) * math.exp(-t * decay)
    return (math.sin(t * math.pi * 2 * hz) + math.sin(t * math.pi * 4 * hz) * 0.25) * env * 0.55
  end)
end

local function looping(data)
  local source = love.audio.newSource(data, "static")
  source:setLooping(true)
  source:setVolume(0)
  return source
end

function audio.load()
  if audio.ready or not love.audio then return end
  local ok, err = pcall(function()
    audio.engineLow = looping(audio.engineData(55, 0.1))
    audio.engineHigh = looping(audio.engineData(110, 0.6))
    audio.rivalEngine = looping(audio.engineData(82, 0.4))
    audio.squeal = looping(audio.squealData())
    audio.road = looping(noiseLoop(1.5, 0.08, 1.8))
    audio.loose = looping(noiseLoop(1.2, 0.5, 0.8))
    audio.wind = looping(noiseLoop(1.8, 0.2, 0.8))
    audio.nitro = looping(noiseLoop(1.0, 0.75, 0.7))
    audio.impactData = burst(0.35, 70, 0.8, 12)
    audio.scrapeData = burst(0.2, 180, 1.0, 20)
    audio.shots = {
      beep = love.audio.newSource(tone(0.28, 440, 8), "static"),
      go = love.audio.newSource(tone(0.7, 880, 4), "static"),
      click = love.audio.newSource(tone(0.05, 1100, 70), "static"),
      select = love.audio.newSource(tone(0.1, 660, 30), "static"),
      shift = love.audio.newSource(burst(0.07, 240, 0.25, 55), "static"),
      pop = love.audio.newSource(burst(0.1, 130, 1.0, 40), "static"),
      lap = love.audio.newSource(tone(0.4, 1046, 7), "static"),
    }
    audio.impacts = {}
    for i = 1, 4 do audio.impacts[i] = love.audio.newSource(audio.impactData, "static") end
    audio.scrapes = {}
    for i = 1, 2 do audio.scrapes[i] = love.audio.newSource(audio.scrapeData, "static") end
    audio.ready = true
  end)
  if not ok then print("audio disabled: " .. tostring(err)) end
end

function audio.setVolume(v)
  if love.audio then love.audio.setVolume(v) end
end

function audio.play(name, volume, pitch)
  if not audio.ready then return end
  local s = audio.shots[name]
  if not s then return end
  s:stop()
  s:setVolume(volume or 1)
  s:setPitch(pitch or 1)
  s:play()
end

function audio.impact(strength, scrape)
  if not audio.ready then return end
  local pool = scrape and audio.scrapes or audio.impacts
  for _, s in ipairs(pool) do
    if not s:isPlaying() then
      s:setVolume(math.min(1, strength))
      s:setPitch(0.8 + love.math.random() * 0.4)
      s:play()
      return
    end
  end
end

local function fadeTo(source, target, dt, rate)
  local now = source:getVolume()
  local step = (rate or 8) * dt
  local v = now + math.max(-step, math.min(step, target - now))
  source:setVolume(v)
  if v > 0.001 and not source:isPlaying() then source:play() end
  if v <= 0.001 and source:isPlaying() then source:pause() end
end

function audio.update(dt, car, rival, rivalDistance)
  if not audio.ready or not car then return end
  local model = car.model
  local spec = car.spec
  local revs = math.max(0, math.min(1.1, model.rpm / spec.redline))
  local load = 0.45 + math.min(1, model.throttle) * 0.55

  -- Pitch both loops together; their blend carries the tone change.
  local lowPitch = math.max(0.35, model.rpm / 1800)
  local highPitch = math.max(0.35, model.rpm / 4400)
  audio.engineLow:setPitch(math.min(3.2, lowPitch))
  audio.engineHigh:setPitch(math.min(3.2, highPitch))
  fadeTo(audio.engineLow, (1 - revs * 0.8) * load * 0.5, dt, 6)
  fadeTo(audio.engineHigh, (0.1 + revs * 0.9) * load * 0.42, dt, 6)

  local speed = car:getSpeed()
  local slide, offRoad = 0, 0
  for _, w in ipairs(model.wheels) do
    slide = math.max(slide, w.surface == "asphalt" and math.max(w.slide, math.max(0, w.spin) / 14) or 0)
    if w.surface == "grass" or w.surface == "gravel" then offRoad = offRoad + 0.25 end
    if w.surface == "kerb" then offRoad = offRoad + 0.1 end
  end

  audio.squeal:setPitch(0.86 + math.min(0.34, speed / 110))
  fadeTo(audio.squeal, slide > 0.25 and math.min(0.42, (slide - 0.2) * 0.65) or 0, dt, 5)
  audio.road:setPitch(0.6 + math.min(1.2, speed / 40))
  fadeTo(audio.road, math.min(0.26, speed / 120), dt, 3)
  audio.loose:setPitch(0.7 + math.min(0.6, speed / 40))
  fadeTo(audio.loose, offRoad * math.min(0.5, speed / 25), dt, 6)
  audio.wind:setPitch(0.7 + math.min(1, speed / 70) + model.slipstream * 0.25)
  fadeTo(audio.wind, math.max(0, (speed - 18) / 110) * 0.45 + model.slipstream * 0.2, dt, 2)
  fadeTo(audio.nitro, model.boostState == "active" and 0.34 or 0, dt, 5)

  if rival then
    audio.rivalEngine:setPitch(math.max(0.5, math.min(3, rival.model.rpm / 3000)))
    local near = math.max(0, 1 - rivalDistance / 500)
    fadeTo(audio.rivalEngine, near * 0.22, dt, 3)
  else
    fadeTo(audio.rivalEngine, 0, dt, 3)
  end
end

function audio.silence()
  if not audio.ready then return end
  for _, key in ipairs({ "engineLow", "engineHigh", "rivalEngine", "squeal", "road", "loose", "wind", "nitro" }) do
    audio[key]:stop()
    audio[key]:setVolume(0)
  end
end

return audio
