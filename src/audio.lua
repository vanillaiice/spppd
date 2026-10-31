-- All sound is synthesised at load time: no audio files ship with the game.
-- The engine is two loops cross-faded by rpm and pitched to match, and
-- spec.engineType adds a layer on top. Everything else that isn't plain wind or
-- road noise is built with sfxr, an arcade effects synth, from the settings below.
local sfxr = require("src/lib/sfxr")

local audio = { voices = {}, ready = false, spool = 0 }

local RATE = 44100
local SCRUB_MAX = 0.14
local LOOSE_MAX = 0.2      -- off-road layer at full speed with all four wheels off
local LOOSE_IN, LOOSE_OUT = 1.2, 0.8  -- its fade per second: about 0.2 s, 0.25 s
local IMPACT_GAP = 0.12    -- seconds; a car grinding along a wall is one noise
local SPOOL_UP, SPOOL_DOWN = 1.8, 7  -- how fast the turbo fills and dumps (per s)
local BLOWOFF_SPOOL = 0.55 -- turbo pressure needed to be heard venting
local STARTUP_PRESS = 0.08 -- the start button going down
local STARTUP_CATCH = 0.35 -- seconds before the engine fires
audio.STARTUP_PEAK = 1.1   -- the rev flare tops out and the turbo vents
audio.STARTUP_LENGTH = 1.7
local STARTUP_REDLINE = 7000
-- Where each cylinder fires in the cycle, and how hard its pulse reaches the
-- tailpipe. The unevenness is what gives a V8 its lope.
local V8_FIRING = { 0.02, 0.13, 0.27, 0.36, 0.52, 0.61, 0.77, 0.86 }
local V8_LEVEL = { 1, 0.72, 0.9, 0.62, 0.95, 0.7, 0.84, 0.66 }

local NOISE, SINE, SQUARE = sfxr.WAVEFORM.NOISE, sfxr.WAVEFORM.SINE, sfxr.WAVEFORM.SQUARE

-- A frequency f plays at 3528 * f^2 Hz and an envelope stage e lasts 2.27 * e^2
-- seconds. Keep a lowpass cutoff under 0.3 or noise stays a bright hiss.
local SHOTS = {
  beep = { waveform = SQUARE, frequency = { start = 0.353 }, envelope = { sustain = 0.2, decay = 0.25 } },
  go = { waveform = SQUARE, frequency = { start = 0.5 }, envelope = { sustain = 0.35, decay = 0.4 } },
  click = { waveform = SQUARE, frequency = { start = 0.56 }, envelope = { sustain = 0.05, decay = 0.08 } },
  select = { waveform = SQUARE, frequency = { start = 0.43 }, envelope = { sustain = 0.08, decay = 0.15 } },
  lap = {
    waveform = SQUARE, frequency = { start = 0.545 }, envelope = { sustain = 0.15, decay = 0.4 },
    change = { speed = 0.6, amount = 0.45 },
  },
  shift = { waveform = SINE, frequency = { start = 0.23 }, envelope = { sustain = 0.02, decay = 0.1 } },
  pop = {
    waveform = NOISE, frequency = { start = 0.35, slide = -0.2 }, envelope = { sustain = 0.05, decay = 0.2 },
    lowpass = { cutoff = 0.25 },
  },
  impact = {
    waveform = NOISE, frequency = { start = 0.3, slide = -0.3 },
    envelope = { sustain = 0.05, punch = 0.4, decay = 0.28 },
    lowpass = { cutoff = 0.15 }, volume = { master = 0.3 },
  },
  scrape = {
    waveform = NOISE, frequency = { start = 0.5 }, envelope = { sustain = 0.04, decay = 0.16 },
    lowpass = { cutoff = 0.25 }, highpass = { cutoff = 0.1 },
  },
  -- The turbo venting when the throttle closes.
  blowoff = {
    waveform = NOISE, frequency = { start = 0.7, slide = -0.12 }, envelope = { attack = 0.03, sustain = 0.08, decay = 0.3 },
    lowpass = { cutoff = 0.5 }, highpass = { cutoff = 0.2 },
  },
}

local SCRUB = {
  waveform = NOISE, frequency = { start = 0.55 }, envelope = { sustain = 0.94, decay = 0 },
  lowpass = { cutoff = 0.22 }, highpass = { cutoff = 0.12 },
}

-- Nitro is a low rumble, kept well below the hiss of a jet.
local NITRO = {
  waveform = NOISE, frequency = { start = 0.32 }, envelope = { sustain = 0.94, decay = 0 },
  lowpass = { cutoff = 0.17 }, highpass = { cutoff = 0.06 }, volume = { master = 0.3 },
}

-- Engine type layers, as harmonics for audio.toneData.
local TURBO_TONE = { [1] = 0.32, [2] = 0.05 }
local BLOWER_TONE = { [1] = 0.2, [2] = 0.3, [3] = 0.14, [5] = 0.06 }  -- straight-cut gears
local MOTOR_TONE = { [2] = 0.14, [4] = 0.06, [7] = 0.3, [10] = 0.09 }  -- inverter whine

local function chip(settings)
  local sound = sfxr.newSound()
  sound.volume.master = 0.4  -- sfxr's own default clips anything noisy
  for group, values in pairs(settings) do
    if type(values) == "table" then
      for key, value in pairs(values) do sound[group][key] = value end
    else
      sound[group] = values
    end
  end
  return (sound:generateSoundData(RATE, 0))
end

function audio.shotData(name)
  return chip(SHOTS[name])
end

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

-- A steady tone built from harmonics of baseHz, as { [harmonic] = level }.
-- Harmonics are whole cycles, so it loops without a click.
function audio.toneData(baseHz, harmonics)
  local samples = math.floor(RATE / baseHz + 0.5) * 8
  return soundData(samples / RATE, function(_, i)
    local u = i / samples
    local total = 0
    for h, level in pairs(harmonics) do
      total = total + math.sin(u * math.pi * 2 * h * 8) * level
    end
    return total
  end)
end

-- Cross-fade the tail over the head so the loop has no click.
local function crossfade(base, seconds, fadeTime)
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
  return crossfade(base, seconds, fadeTime)
end

function audio.scrubData()
  return crossfade(chip(SCRUB), 1.7, 0.25)
end

function audio.nitroData()
  return crossfade(chip(NITRO), 1.7, 0.25)
end

-- Dark enough to read as a soft rumble of dirt under the tyres, not a hiss.
function audio.looseData()
  return noiseLoop(1.2, 0.11, 1.7)
end

-- Engine speed through the startup: a stumble as it catches, then a hard snap
-- up the revs into the limiter, and a fall to idle.
local function startupRpm(t)
  if t < STARTUP_CATCH then return 500 end
  local peak = audio.STARTUP_PEAK
  if t < STARTUP_CATCH + 0.2 then
    return 500 + 900 * (t - STARTUP_CATCH) / 0.2
  end
  if t < peak then
    return 1400 + (STARTUP_REDLINE - 1400) * (1 - math.exp(-(t - STARTUP_CATCH - 0.2) * 7))
  end
  return 1000 + (STARTUP_REDLINE - 1000) * math.exp(-(t - peak) * 6)
end

-- A two-pole resonance: one length of exhaust pipe ringing at hz.
local function resonator(hz, r)
  local y1, y2 = 0, 0
  local a = 2 * r * math.cos(hz * math.pi * 2 / RATE)
  local gain = 1 - r
  return function(x)
    local y = a * y1 - r * r * y2 + x * gain
    y2, y1 = y1, y
    return y
  end
end

-- A heavy start button bottoming out: a low thud that sags in pitch, with a
-- muted knock on top and only a trace of contact noise.
local function buttonThud(t, white)
  if t < 0 or t > 0.2 then return 0 end
  return math.sin((130 * t - 300 * t * t) * math.pi * 2) * math.exp(-t * 28) * 2.2
    + math.sin(t * math.pi * 2 * 320) * math.exp(-t * 90) * 0.9
    + white * math.exp(-t * 400) * 0.08
end

-- The launch sound: the start button, a rough catch, the revs snapped to the
-- limiter, then the throttle shutting with a bang and a fluttering blow-off.
-- The engine is a model, not a tone: uneven V8 firing pulses hit the resonances
-- of the exhaust and the result is driven hard into saturation. One sample, so
-- the parts can't drift apart whatever the frame rate does.
function audio.startupData()
  local rng = love.math.newRandomGenerator(31)
  local cyclePhase, flutterPhase = 0, 0
  local ventLow, ventBand = 0, 0
  local cylinder, cycle, pressure, body = 1, 0, 0, 0
  local pipes = { resonator(92, 0.994), resonator(265, 0.99), resonator(710, 0.98), resonator(1900, 0.96) }
  local PIPE_LEVEL = { 1, 0.8, 0.5, 0.28 }
  local pressureDecay = math.exp(-1 / (0.0028 * RATE))

  return soundData(audio.STARTUP_LENGTH, function(t)
    local rpm = startupRpm(t)
    local peak = audio.STARTUP_PEAK
    local running, lifted = t >= STARTUP_CATCH, t >= peak
    local white = rng:random() * 2 - 1
    cyclePhase = cyclePhase + rpm / 120 / RATE  -- a four-stroke cycle is two turns

    while cyclePhase >= cycle + V8_FIRING[cylinder] do
      local level = V8_LEVEL[cylinder]
      if not running then
        level = 0
      elseif t < STARTUP_CATCH + 0.2 then
        if rng:random() < 0.3 then level = 0 end        -- it stumbles as it catches
      elseif lifted then
        level = level * 0.28                            -- off the throttle
        if rng:random() < 0.3 then level = 0 end
      elseif rpm > STARTUP_REDLINE * 0.97 and cylinder % 2 == 0 then
        level = 0                                       -- the limiter cutting sparks
      end
      pressure = math.max(pressure, level)
      cylinder = cylinder + 1
      if cylinder > #V8_FIRING then cylinder, cycle = 1, cycle + 1 end
    end
    pressure = pressure * pressureDecay

    -- Hot gas leaving a valve is a rough burst, not a clean click.
    local gas = pressure * (0.65 + white * 0.5)
    body = body + (gas - body) * 0.015
    local pulse = gas - body  -- only the swing: steady pressure would pin the saturation
    local exhaust = pulse * 0.5
    for i, pipe in ipairs(pipes) do exhaust = exhaust + pipe(pulse) * PIPE_LEVEL[i] * 2.2 end
    local drive = (not running or lifted) and 0.7 or 0.7 + rpm / 2600
    local engine = math.atan(exhaust * drive) * (lifted and 0.3 or 0.5)

    local button = buttonThud(t - STARTUP_PRESS, white)

    local bang, vent = 0, 0
    local since = t - peak
    if since > 0 then
      bang = math.sin(since * math.pi * 2 * (150 - since * 900)) * math.exp(-since * 32) * 0.6
      -- Noise through a band that sweeps down as the pressure goes.
      local band = 0.08 + 0.3 * math.exp(-since * 5)
      ventLow = ventLow + band * ventBand
      ventBand = ventBand + band * (white - ventLow - ventBand * 0.5)
      flutterPhase = flutterPhase + (34 - since * 30) / RATE
      local flutter = 1 - 0.65 * math.max(0, math.sin(flutterPhase * math.pi * 2)) * math.exp(-since * 1.5)
      vent = ventBand * math.min(1, since / 0.012) * math.exp(-since * 3.6) * flutter * 0.55
    end

    local mixed = button + engine + bang
    mixed = mixed / (1 + math.abs(mixed) * 0.5)  -- a soft ceiling for the firing peaks
    return (mixed + vent) * 0.85 * math.min(1, (audio.STARTUP_LENGTH - t) / 0.12)
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
    audio.scrub = looping(audio.scrubData())
    audio.road = looping(noiseLoop(1.5, 0.08, 1.8))
    audio.loose = looping(audio.looseData())
    audio.wind = looping(noiseLoop(1.8, 0.2, 0.8))
    audio.nitro = looping(audio.nitroData())
    audio.intake = looping(audio.engineData(220, 1))
    audio.turbo = looping(audio.toneData(1400, TURBO_TONE))
    audio.blower = looping(audio.toneData(380, BLOWER_TONE))
    audio.motor = looping(audio.toneData(210, MOTOR_TONE))
    audio.rivalMotor = looping(audio.toneData(210, MOTOR_TONE))
    audio.shots = {}
    for _, name in ipairs({ "beep", "go", "click", "select", "shift", "pop", "lap", "blowoff" }) do
      audio.shots[name] = love.audio.newSource(audio.shotData(name), "static")
    end
    audio.shots.startup = love.audio.newSource(audio.startupData(), "static")
    local impact, scrape = audio.shotData("impact"), audio.shotData("scrape")
    audio.impacts = {}
    for i = 1, 4 do audio.impacts[i] = love.audio.newSource(impact, "static") end
    audio.scrapes = {}
    for i = 1, 2 do audio.scrapes[i] = love.audio.newSource(scrape, "static") end
    audio.lastImpact = 0
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
  local now = love.timer.getTime()
  if now - audio.lastImpact < IMPACT_GAP then return end
  audio.lastImpact = now
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

-- Sliding is worth hearing. Braking shouldn't nag every time it's used.
function audio.scrubLevel(slide, braking)
  if braking then return 0 end
  return math.max(0, math.min(SCRUB_MAX, (slide - 0.25) * 0.3))
end

-- offRoad is the share of the car on loose ground, 0..1.
function audio.looseLevel(offRoad, speed)
  return offRoad * LOOSE_MAX * math.min(1, speed / 25)
end

local function fadeTo(source, target, dt, rate)
  local now = source:getVolume()
  local step = (rate or 8) * dt
  local v = now + math.max(-step, math.min(step, target - now))
  source:setVolume(v)
  if v > 0.001 and not source:isPlaying() then source:play() end
  if v <= 0.001 and source:isPlaying() then source:pause() end
end

-- Turbo pressure lags the throttle, and has to go somewhere when it closes.
-- Returns true on the moment it vents.
function audio.spoolStep(spool, onPower, revs, dt)
  local target = onPower and math.min(1, revs * 1.4) or 0
  local rate = target > spool and SPOOL_UP or SPOOL_DOWN
  local step = rate * dt
  local nextSpool = spool + math.max(-step, math.min(step, target - spool))
  return nextSpool, spool >= BLOWOFF_SPOOL and not onPower
end

-- How loud the pistons (0..1) and each engine type's layer should be.
function audio.engineMix(kind, revs, load, spool)
  return {
    -- An electric car has no pistons to hear: the motor layer stands in for them.
    pistons = kind == "electric" and 0 or 1,
    -- An open engine howls through its intake near the top of the revs.
    intake = kind == "na" and math.max(0, revs - 0.45) * 2 * load * 0.5 or 0,
    turbo = spool ^ 2 * 0.3,
    -- A supercharger is geared to the crank, so it whines the instant the revs rise.
    blower = kind == "supercharged" and (0.08 + revs * 0.32) * load or 0,
    motor = kind == "electric" and math.min(1, revs * 3) * (0.12 + load * 0.32) or 0,
  }
end

local function updateEngineLayers(dt, model, kind, revs, load)
  if kind == "turbo" then
    local onPower = model.throttle > 0.4 and model.shiftTimer == 0
    local vented
    audio.spool, vented = audio.spoolStep(audio.spool, onPower, revs, dt)
    if vented then
      audio.spool = 0
      audio.play("blowoff", 0.5)
    end
  else
    audio.spool = 0
  end

  local mix = audio.engineMix(kind, revs, load, audio.spool)
  audio.intake:setPitch(math.min(3.2, 0.5 + revs * 1.3))
  fadeTo(audio.intake, mix.intake, dt, 6)
  audio.turbo:setPitch(0.45 + audio.spool * 0.9)
  fadeTo(audio.turbo, mix.turbo, dt, 10)
  audio.blower:setPitch(math.min(3.2, 0.4 + revs * 1.5))
  fadeTo(audio.blower, mix.blower, dt, 6)
  audio.motor:setPitch(0.3 + revs * 2)
  fadeTo(audio.motor, mix.motor, dt, 6)
  return mix.pistons
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
  local pistons = updateEngineLayers(dt, model, spec.engineType, revs, load)
  fadeTo(audio.engineLow, (1 - revs * 0.8) * load * 0.5 * pistons, dt, 6)
  fadeTo(audio.engineHigh, (0.1 + revs * 0.9) * load * 0.42 * pistons, dt, 6)

  local speed = car:getSpeed()
  local slide, offRoad = 0, 0
  for _, w in ipairs(model.wheels) do
    slide = math.max(slide, w.surface == "asphalt" and math.max(w.slide, math.max(0, w.spin) / 14) or 0)
    if w.surface == "grass" or w.surface == "gravel" then offRoad = offRoad + 0.25 end
    if w.surface == "kerb" then offRoad = offRoad + 0.1 end
  end

  audio.scrub:setPitch(0.86 + math.min(0.34, speed / 110))
  fadeTo(audio.scrub, audio.scrubLevel(slide, model.brake > 0.05), dt, 3)
  audio.road:setPitch(0.6 + math.min(1.2, speed / 40))
  fadeTo(audio.road, math.min(0.26, speed / 120), dt, 3)
  audio.loose:setPitch(0.75 + math.min(0.35, speed / 70))
  local looseLevel = audio.looseLevel(offRoad, speed)
  fadeTo(audio.loose, looseLevel, dt, looseLevel > audio.loose:getVolume() and LOOSE_IN or LOOSE_OUT)
  audio.wind:setPitch(0.7 + math.min(1, speed / 70) + model.slipstream * 0.25)
  fadeTo(audio.wind, math.max(0, (speed - 18) / 110) * 0.45 + model.slipstream * 0.2, dt, 2)
  fadeTo(audio.nitro, model.boostState == "active" and 0.35 or 0, dt, 3)

  local rivalLevel, rivalMotorLevel = 0, 0
  if rival then
    local near = math.max(0, 1 - rivalDistance / 500)
    if rival.spec.engineType == "electric" then
      rivalMotorLevel = near * 0.22
      audio.rivalMotor:setPitch(0.3 + math.min(1.1, rival.model.rpm / rival.spec.redline) * 2)
    else
      rivalLevel = near * 0.22
      audio.rivalEngine:setPitch(math.max(0.5, math.min(3, rival.model.rpm / 3000)))
    end
  end
  fadeTo(audio.rivalEngine, rivalLevel, dt, 3)
  fadeTo(audio.rivalMotor, rivalMotorLevel, dt, 3)
end

function audio.silence()
  if not audio.ready then return end
  for _, key in ipairs({ "engineLow", "engineHigh", "rivalEngine", "rivalMotor", "scrub", "road", "loose", "wind", "nitro",
    "intake", "turbo", "blower", "motor" }) do
    audio[key]:stop()
    audio[key]:setVolume(0)
  end
  audio.spool = 0
end

return audio
