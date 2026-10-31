-- All sound is synthesised at load time: no audio files ship with the game.
-- Most engines are two loops cross-faded by rpm and pitched to match, and
-- spec.engineType adds a layer on top. The "na" V8 is the startup's engine model
-- rendered at a few speeds instead, so it keeps its exhaust note at any rpm.
-- Most of the rest is built with sfxr, an
-- arcade effects synth, from the settings below. The sounds that have to feel
-- mechanical (startup, gear change, blow-off) are modelled here instead.
local sfxr = require("src/lib/sfxr")

local audio = { voices = {}, ready = false, spool = 0 }

local RATE = 44100
local SCRUB_MAX = 0.14
local LOOSE_MAX = 0.2      -- off-road layer at full speed with all four wheels off
local LOOSE_IN, LOOSE_OUT = 1.2, 0.8  -- its fade per second: about 0.2 s, 0.25 s
local IMPACT_GAP = 0.12    -- seconds; a car grinding along a wall is one noise
local NITRO_LEVEL = 0.4
local NITRO_IN, NITRO_OUT = 12, 5  -- its fade per second: a burst on, a short sigh off
local SPOOL_UP, SPOOL_DOWN = 1.8, 7  -- how fast the turbo fills and dumps (per s)
local BLOWOFF_SPOOL = 0.55 -- turbo pressure needed to be heard venting
local BLOWOFF_LENGTH = 0.55
local SHIFT_LENGTH = 0.17
local STARTUP_PRESS = 0.08 -- the start button going down
local STARTUP_CATCH = 0.35 -- seconds before the engine fires
audio.STARTUP_PEAK = 1.1   -- the rev flare tops out and the turbo vents
audio.STARTUP_LENGTH = 1.7
local STARTUP_REDLINE = 7000
-- Where each cylinder fires in the cycle, and how hard its pulse reaches the
-- tailpipe. The unevenness is what gives a V8 its lope.
local V8_FIRING = { 0.02, 0.13, 0.27, 0.36, 0.52, 0.61, 0.77, 0.86 }
local V8_LEVEL = { 1, 0.72, 0.9, 0.62, 0.95, 0.7, 0.84, 0.66 }
local V8_RPMS = { 1300, 3000, 5400 }  -- the speeds its loops are rendered at
local V8_OVERRUN_RPM = 3000
-- The limiter cuts the sparks in bursts: of every 16 firings, the first 8 fire.
-- Any more and the exhaust ringing on fills the gaps.
local V8_LIMIT_BURST, V8_LIMIT_FIRED = 16, 8
local V8_LOOP, V8_FADE = 0.7, 0.14    -- seconds, before rounding to whole engine cycles

-- The cut pulses of a gear change, as { seconds, level }: uneven, or it's a buzz.
local SHIFT_PULSES = {
  { 0.012, 1 }, { 0.024, 0.6 }, { 0.04, 0.85 }, { 0.053, 0.5 }, { 0.07, 0.7 }, { 0.09, 0.42 }, { 0.112, 0.3 },
}
-- How hard each exhaust resonance rings. A shift leaves the bass to the engine.
local ENGINE_PIPES = { 1, 0.8, 0.5, 0.28 }
local SHIFT_PIPES = { 0.1, 0.9, 0.8, 0.4 }
local V8_PIPES = { 0.6, 0.9, 0.7, 0.35 }  -- more midrange, for a phone speaker

local NOISE, SQUARE = sfxr.WAVEFORM.NOISE, sfxr.WAVEFORM.SQUARE

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
  impact = {
    waveform = NOISE, frequency = { start = 0.3, slide = -0.3 },
    envelope = { sustain = 0.05, punch = 0.4, decay = 0.28 },
    lowpass = { cutoff = 0.15 }, volume = { master = 0.55 },
  },
  scrape = {
    waveform = NOISE, frequency = { start = 0.5 }, envelope = { sustain = 0.04, decay = 0.16 },
    lowpass = { cutoff = 0.25 }, highpass = { cutoff = 0.1 },
  },
}

local SCRUB = {
  waveform = NOISE, frequency = { start = 0.55 }, envelope = { sustain = 0.94, decay = 0 },
  lowpass = { cutoff = 0.22 }, highpass = { cutoff = 0.12 },
}

-- Nitro is gas under pressure: a hiss, up above the engine where it can be heard
-- without being loud. Anything lower just disappears under the pistons.
local NITRO = {
  waveform = NOISE, frequency = { start = 0.9 }, envelope = { sustain = 0.94, decay = 0 },
  lowpass = { cutoff = 0.55 }, highpass = { cutoff = 0.3 }, volume = { master = 0.5 },
}

-- Engine type layers, as harmonics for audio.toneData.
local TURBO_TONE = { [1] = 0.32, [2] = 0.05 }
local BLOWER_TONE = { [1] = 0.2, [2] = 0.3, [3] = 0.14, [5] = 0.06 }  -- straight-cut gears
-- { harmonic, level }. Close-packed, because a few clean partials sliding up
-- together is the sound of a flying saucer.
local MOTOR_PARTIALS = { { 1, 0.3 }, { 2, 0.22 }, { 3, 0.2 }, { 4, 0.14 }, { 6, 0.14 }, { 9, 0.1 }, { 13, 0.06 } }
local MOTOR_HZ = 210

local function chip(settings)
  local sound = sfxr.newSound()
  sound.volume.master = 0.4  -- sfxr's own default clips anything noisy
  sound.envelope.attack = 0.02  -- under a millisecond, enough to lose the click at the start
  for group, values in pairs(settings) do
    if type(values) == "table" then
      for key, value in pairs(values) do sound[group][key] = value end
    else
      sound[group] = values
    end
  end
  return (sound:generateSoundData(RATE, 0))
end

-- Filled in below: sounds modelled here, not built with sfxr.
local MODELLED = {}

function audio.shotData(name)
  return MODELLED[name] and MODELLED[name]() or chip(SHOTS[name])
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

-- A two-pole resonance: something ringing at hz.
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

-- A rough whine: the motor's harmonics, half clean and half noise ringing at the
-- same pitches, so there's no pure tone in it. It repeats whole cycles to loop.
function audio.motorData()
  local period = math.floor(RATE / MOTOR_HZ + 0.5)
  local fadeTime = period * 30 / RATE
  local seconds = period * 300 / RATE
  local rng = love.math.newRandomGenerator(23)
  local rings = {}
  for i, partial in ipairs(MOTOR_PARTIALS) do rings[i] = resonator(MOTOR_HZ * partial[1], 0.997) end
  local base = soundData(seconds + fadeTime, function(_, i)
    local white = rng:random() * 2 - 1
    local total = 0
    for k, partial in ipairs(MOTOR_PARTIALS) do
      local hz = RATE / period * partial[1]
      total = total + (math.sin(i / RATE * math.pi * 2 * hz) * 0.5 + rings[k](white) * 7) * partial[2]
    end
    return math.atan(total * 1.6) * 0.5
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

-- The firing order, run at any rpm. Each call asks strength(level, cylinder) for
-- what a cylinder that fires this sample delivers, and returns the strongest.
local function newFiring()
  local phase, cylinder, cycle = 0, 1, 0
  return function(rpm, strength)
    phase = phase + rpm / 120 / RATE  -- a four-stroke cycle is two turns
    local fired = 0
    while phase >= cycle + V8_FIRING[cylinder] do
      fired = math.max(fired, strength(V8_LEVEL[cylinder], cylinder))
      cylinder = cylinder + 1
      if cylinder > #V8_FIRING then cylinder, cycle = 1, cycle + 1 end
    end
    return fired
  end
end

-- Firing pulses leaving through the exhaust. Each call takes the strongest pulse
-- fired this sample. Hot gas leaving a valve is a rough burst, not a clean click.
local function newExhaust(pipeLevels)
  local pipes = { resonator(92, 0.994), resonator(265, 0.99), resonator(710, 0.98), resonator(1900, 0.96) }
  local pressureDecay = math.exp(-1 / (0.0028 * RATE))
  local pressure, body = 0, 0
  return function(fired, white)
    pressure = math.max(pressure, fired) * pressureDecay
    local gas = pressure * (0.65 + white * 0.5)
    body = body + (gas - body) * 0.015
    local pulse = gas - body  -- only the swing: steady pressure would pin the saturation
    local exhaust = pulse * 0.5
    for i, pipe in ipairs(pipes) do exhaust = exhaust + pipe(pulse) * pipeLevels[i] * 2.2 end
    return exhaust
  end
end

-- Turbo pressure escaping: noise through a band that sweeps down as the pressure
-- goes, chopped by the compressor surging. since is seconds after the valve opens.
local function newVent()
  local low, band, phase = 0, 0, 0
  return function(since, white)
    local cutoff = 0.08 + 0.3 * math.exp(-since * 5)
    low = low + cutoff * band
    band = band + cutoff * (white - low - band * 0.5)
    phase = phase + (34 - since * 30) / RATE
    local flutter = 1 - 0.65 * math.max(0, math.sin(phase * math.pi * 2)) * math.exp(-since * 1.5)
    return band * math.min(1, since / 0.012) * math.exp(-since * 3.6) * flutter * 0.55
  end
end

-- Dead metal doesn't ring: a soft low knock, damped within a few cycles. This is
-- what a gear going in, or a throttle slamming shut, sounds like from the seat.
local function newKnock()
  local thump, knock = resonator(120, 0.998), resonator(420, 0.9965)
  return function(since, white)
    local hit = white * math.min(1, since / 0.003) * math.exp(-since * 200)
    return thump(hit) * 1.3 + knock(hit) * 2.4
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
  local firing, exhaust, vent, knock = newFiring(), newExhaust(ENGINE_PIPES), newVent(), newKnock()

  return soundData(audio.STARTUP_LENGTH, function(t)
    local rpm = startupRpm(t)
    local peak = audio.STARTUP_PEAK
    local running, lifted = t >= STARTUP_CATCH, t >= peak
    local white = rng:random() * 2 - 1
    local fired = firing(rpm, function(level, cylinder)
      if not running then return 0 end
      if t < STARTUP_CATCH + 0.2 then
        if rng:random() < 0.3 then return 0 end         -- it stumbles as it catches
      elseif lifted then
        level = level * 0.28                            -- off the throttle
        if rng:random() < 0.3 then return 0 end
      elseif rpm > STARTUP_REDLINE * 0.97 and cylinder % 2 == 0 then
        return 0                                        -- the limiter cutting sparks
      end
      return level
    end)

    local drive = (not running or lifted) and 0.7 or 0.7 + rpm / 2600
    local engine = math.atan(exhaust(fired, white) * drive) * (lifted and 0.3 or 0.5)

    local button = buttonThud(t - STARTUP_PRESS, white)

    local bang, venting = 0, 0
    local since = t - peak
    if since > 0 then
      bang = knock(since, white)
      venting = vent(since, white)
    end

    local mixed = button + engine + bang
    mixed = mixed / (1 + math.abs(mixed) * 0.5)  -- a soft ceiling for the firing peaks
    return (mixed + venting) * 0.85 * math.min(1, (audio.STARTUP_LENGTH - t) / 0.12)
  end)
end

-- One steady speed of the startup's engine, as a loop. Whole engine cycles, so the
-- firing lines up across the join. mode "overrun" is the throttle shut: weak,
-- uneven pulses, the burble as the revs fall. Mode "limiter" is the sparks cutting
-- at the top of the revs, and the only one driven hard. The rest are driven far
-- less than the startup: that much saturation is thrilling for a second, and
-- square and fuzzy for a whole race.
function audio.v8Data(rpm, mode)
  local overrun, limiter = mode == "overrun", mode == "limiter"
  local cycle = 120 / rpm
  local seconds = math.ceil(V8_LOOP / cycle) * cycle
  local fadeTime = math.ceil(V8_FADE / cycle) * cycle
  local rng = love.math.newRandomGenerator(rpm + (overrun and 1 or limiter and 2 or 0))
  local firing, exhaust = newFiring(), newExhaust(V8_PIPES)
  local drive = overrun and 0.35 or limiter and 1 or 0.3 + rpm / 20000
  local gain = overrun and 0.5 or 0.72
  local shot = 0
  local function strength(level)
    shot = shot + 1
    if limiter then return (shot - 1) % V8_LIMIT_BURST < V8_LIMIT_FIRED and level or 0 end
    if not overrun then return level end
    return rng:random() < 0.3 and 0 or level * 0.28
  end
  local base = soundData(seconds + fadeTime, function()
    local fired = firing(rpm, strength)
    local engine = math.atan(exhaust(fired, rng:random() * 2 - 1) * drive) * gain
    return engine / (1 + math.abs(engine) * 0.5) * 0.85
  end)
  return crossfade(base, seconds, fadeTime)
end

-- An upshift is the power cutting out: the gear goes in with a knock while the
-- exhaust sputters on the cut sparks. Most of it sits in the midrange, because a
-- phone speaker can't play anything below about 200 Hz.
function MODELLED.shift()
  local rng = love.math.newRandomGenerator(43)
  local exhaust, knock = newExhaust(SHIFT_PIPES), newKnock()
  local nextPulse, slow, slower = 1, 0, 0
  return soundData(SHIFT_LENGTH, function(t)
    local white = rng:random() * 2 - 1
    local fired = 0
    local pulse = SHIFT_PULSES[nextPulse]
    if pulse and t >= pulse[1] then
      fired, nextPulse = pulse[2], nextPulse + 1
    end
    -- Each pulse is a push of air as well as a sound: lose the push, or it's a thud.
    local sound = exhaust(fired, white)
    slow = slow + (sound - slow) * 0.03
    slower = slower + (sound - slow - slower) * 0.03
    local mixed = knock(t, white) * 0.8 + math.atan((sound - slow - slower) * 2.4) * 0.75
    return mixed * math.min(1, (SHIFT_LENGTH - t) / 0.03) * 0.6
  end)
end

function MODELLED.blowoff()
  local rng = love.math.newRandomGenerator(59)
  local vent = newVent()
  local soft = 0
  return soundData(BLOWOFF_LENGTH, function(t)
    soft = soft + (vent(t, rng:random() * 2 - 1) - soft) * 0.35  -- a breath, not a hiss
    return soft * 1.5 * math.min(1, (BLOWOFF_LENGTH - t) / 0.1)
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
    audio.v8 = {}
    for i, rpm in ipairs(V8_RPMS) do audio.v8[i] = looping(audio.v8Data(rpm)) end
    audio.v8Overrun = looping(audio.v8Data(V8_OVERRUN_RPM, "overrun"))
    audio.v8Limiter = looping(audio.v8Data(V8_RPMS[#V8_RPMS], "limiter"))
    audio.rivalV8 = audio.v8[2]:clone()
    audio.turbo = looping(audio.toneData(1400, TURBO_TONE))
    audio.blower = looping(audio.toneData(380, BLOWER_TONE))
    local motor = audio.motorData()
    audio.motor = looping(motor)
    audio.rivalMotor = looping(motor)
    audio.shots = {}
    for _, name in ipairs({ "beep", "go", "click", "select", "shift", "lap", "blowoff" }) do
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

-- The more pressure there is to dump, the louder it goes.
function audio.blowoffVolume(spool)
  return 0.3 + spool * 0.4
end

-- The hiss sags as the bottle empties. tank is the share left, 0..1.
function audio.nitroPitch(tank)
  return 0.9 + math.max(0, math.min(1, tank)) * 0.2
end

-- The same sample twice running sounds like a machine gun.
function audio.variedPitch()
  return 0.93 + love.math.random() * 0.14
end

-- The engine note drops out while a gear changes, because the power does.
function audio.engineLoad(throttle, shifting)
  return 0.45 + (shifting and 0 or math.min(1, throttle) * 0.55)
end

-- How loud the pistons (0..1) and each engine type's layer should be.
function audio.engineMix(kind, revs, load, spool)
  return {
    -- An electric car has no pistons to hear: the motor layer stands in for them.
    -- The V8 is a whole engine by itself.
    pistons = (kind == "electric" or kind == "na") and 0 or 1,
    v8 = kind == "na" and 0.34 + revs * 0.34 or 0,
    -- Every piston engine borrows the V8's cut: sparks cutting sound much alike.
    limiter = kind == "electric" and 0 or 0.39 + revs * 0.39,
    turbo = spool ^ 2 * 0.3,
    -- A supercharger is geared to the crank, so it whines the instant the revs rise.
    blower = kind == "supercharged" and (0.08 + revs * 0.32) * load or 0,
    motor = kind == "electric" and math.min(1, revs * 3) * (0.1 + load * 0.2) or 0,
  }
end

-- How much of each rendered speed to play at this rpm, blending between the two
-- nearest so the exhaust note moves with the revs instead of being pitched up.
function audio.v8Blend(rpm)
  local blend = {}
  for i, at in ipairs(V8_RPMS) do
    local below, above = V8_RPMS[i - 1], V8_RPMS[i + 1]
    local share = 1
    if rpm < at and below then share = math.max(0, (rpm - below) / (at - below)) end
    if rpm > at and above then share = math.max(0, (above - rpm) / (above - at)) end
    blend[i] = share
  end
  return blend
end

-- A narrower sweep than the speed alone would give: the full range is a swoop.
function audio.motorPitch(revs)
  return 0.5 + revs * 1.2
end

local function updateV8(dt, level, rpm, load, limiting)
  local power = (load - audio.engineLoad(0, true)) / (audio.engineLoad(1, false) - audio.engineLoad(0, true))
  local blend = audio.v8Blend(rpm)
  for i, source in ipairs(audio.v8) do
    source:setPitch(math.min(3.2, math.max(0.35, rpm / V8_RPMS[i])))
    fadeTo(source, limiting and 0 or level * blend[i] * (0.3 + power * 0.7), dt, limiting and 30 or 8)
  end
  audio.v8Overrun:setPitch(math.min(3.2, math.max(0.35, rpm / V8_OVERRUN_RPM)))
  fadeTo(audio.v8Overrun, level * (1 - power) * 1.1, dt, 8)
end

local function updateEngineLayers(dt, model, kind, revs, load)
  if kind == "turbo" then
    local onPower = model.throttle > 0.4 and model.shiftTimer == 0
    local vented
    audio.spool, vented = audio.spoolStep(audio.spool, onPower, revs, dt)
    if vented then
      audio.play("blowoff", audio.blowoffVolume(audio.spool), audio.variedPitch())
      audio.spool = 0
    end
  else
    audio.spool = 0
  end

  local mix = audio.engineMix(kind, revs, load, audio.spool)
  updateV8(dt, mix.v8, model.rpm, load, model.limiting)
  audio.v8Limiter:setPitch(math.max(0.35, model.rpm / V8_RPMS[#V8_RPMS]))
  fadeTo(audio.v8Limiter, model.limiting and mix.limiter or 0, dt, 30)
  audio.turbo:setPitch(0.45 + audio.spool * 0.9)
  fadeTo(audio.turbo, mix.turbo, dt, 10)
  audio.blower:setPitch(math.min(3.2, 0.4 + revs * 1.5))
  fadeTo(audio.blower, mix.blower, dt, 6)
  audio.motor:setPitch(audio.motorPitch(revs))
  fadeTo(audio.motor, mix.motor, dt, 6)
  return mix.pistons * (model.limiting and 0.2 or 1)
end

function audio.update(dt, car, rival, rivalDistance)
  if not audio.ready or not car then return end
  local model = car.model
  local spec = car.spec
  local revs = math.max(0, math.min(1.1, model.rpm / spec.redline))
  local load = audio.engineLoad(model.throttle, model.shiftTimer > 0)

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
  local boosting = model.boostState == "active"
  audio.nitro:setPitch(audio.nitroPitch(model.boostTank / spec.boostTime))
  fadeTo(audio.nitro, boosting and NITRO_LEVEL or 0, dt, boosting and NITRO_IN or NITRO_OUT)

  local rivalLevel, rivalMotorLevel, rivalV8Level = 0, 0, 0
  if rival then
    local near = math.max(0, 1 - rivalDistance / 500)
    if rival.spec.engineType == "electric" then
      rivalMotorLevel = near * 0.22
      audio.rivalMotor:setPitch(audio.motorPitch(math.min(1.1, rival.model.rpm / rival.spec.redline)))
    elseif rival.spec.engineType == "na" then
      rivalV8Level = near * 0.14
      audio.rivalV8:setPitch(math.max(0.35, math.min(3.2, rival.model.rpm / V8_RPMS[2])))
    else
      rivalLevel = near * 0.22
      audio.rivalEngine:setPitch(math.max(0.5, math.min(3, rival.model.rpm / 3000)))
    end
  end
  fadeTo(audio.rivalEngine, rivalLevel, dt, 3)
  fadeTo(audio.rivalMotor, rivalMotorLevel, dt, 3)
  fadeTo(audio.rivalV8, rivalV8Level, dt, 3)
end

function audio.silence()
  if not audio.ready then return end
  for _, key in ipairs({ "engineLow", "engineHigh", "rivalEngine", "rivalMotor", "rivalV8", "scrub", "road", "loose", "wind", "nitro",
    "v8Overrun", "v8Limiter", "turbo", "blower", "motor" }) do
    audio[key]:stop()
    audio[key]:setVolume(0)
  end
  for _, source in ipairs(audio.v8) do
    source:stop()
    source:setVolume(0)
  end
  audio.spool = 0
end

return audio
