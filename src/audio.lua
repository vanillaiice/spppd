-- All sound is synthesised, on the first launch only: no audio files ship with the
-- game, and src/sound_cache.lua keeps the results. The one exception is the
-- player's own music, which src/radio.lua plays.
-- A piston engine is the startup's engine model rendered at a few speeds for each
-- cylinder count, so it keeps its exhaust note at any rpm. Turbos, a supercharger
-- or an electric motor are layers worked out from the car's spec.
-- The tones and small effects are built with sfxr, an arcade effects synth, from the
-- settings below. The sounds that have to feel mechanical (startup, gear change,
-- blow-off, crashes) are modelled here instead, out of the same parts: stepped noise,
-- simple filters, slides and short envelopes.
-- SOUND.md is the style guide: the levels and conventions a new sound has to meet.
local sfxr = require("src/lib/sfxr")
local cache = require("src/sound_cache")
local garage = require("src/entities/garage")

local audio = { ready = false, spool = 0, duck = 0 }
local voices = {}  -- audio.voiceOf's results, by key

local RATE = 44100
local SCRUB_MAX = 0.2
local SCRUB_RISE = 0.42    -- volume per unit of slide past the grip limit
-- A real drift sits at slide 1 for as long as it lasts, so this is what a slide
-- sounds like for seconds at a time.
local SQUEAL_MAX = 0.2
local SQUEAL_FROM, SQUEAL_RISE = 0.55, 0.5
local GRIND_MAX = 0.32     -- bodywork dragging along a wall at speed
local GRIND_IN, GRIND_OUT = 14, 6  -- its fade per second
local LOOSE_MAX = 0.2      -- off-road layer at full speed with all four wheels off
local LOOSE_IN, LOOSE_OUT = 1.2, 0.8  -- its fade per second: about 0.2 s, 0.25 s
local IMPACT_GAP = 0.12    -- seconds; only a bigger hit gets through inside this
local BOOST_GAS_LEVEL = 0.4
local BOOST_GAS_IN, BOOST_GAS_OUT = 4, 1.2  -- its fade per second: a swell on, a slow sigh off
local BOOST_SAG = 0.3      -- the share of its level that goes as the bottle empties
local BOOST_IN, BOOST_OUT = 10, 3  -- per second, matching the gas's swell and sigh
local HORN_LEVEL = 0.5
local HORN_FADE = 40       -- per second, so it starts and stops like a button
local HORN_HZ = { 420, 500 }  -- the classic two trumpets, a little under a third apart
local HORN_MASS = 1400     -- a car this heavy plays the horn at its written pitch
-- The tune horn cheat: the opening of La Cucaracha, in semitones from the horn's own
-- pitch and seconds. A false note is a rest. It loops for as long as it's held.
local HORN_TUNE = {
  { -5, 0.13 }, { -5, 0.13 }, { -5, 0.13 }, { 0, 0.39 }, { 4, 0.26 }, { false, 0.26 },
  { -5, 0.13 }, { -5, 0.13 }, { -5, 0.13 }, { 0, 0.39 }, { 4, 0.26 }, { false, 0.26 },
  { 0, 0.13 }, { 0, 0.13 }, { -1, 0.13 }, { -1, 0.13 }, { -3, 0.13 }, { -3, 0.13 }, { -5, 0.52 }, { false, 0.39 },
}
local HORN_GAP = 0.2       -- the share at the end of each note that's silent, so repeats part
local FLAME_LEVEL = 0.45   -- the flame cheat's roar
local FLAME_IN, FLAME_OUT = 10, 3
local FLAME_FADE = 0.4     -- seconds the roar takes to die with the fire
local SPOOL_DOWN = 7        -- how fast a turbo dumps (per s)
local BLOWOFF_SPOOL = 0.55 -- turbo pressure needed to be heard venting
local BLOWOFF_LENGTH = 0.55
local SHIFT_LENGTH = 0.14
audio.SHIFT_LEVEL = 0.55
local STARTUP_PRESS = 0.08 -- the start button going down
local STARTUP_CATCH = 0.35 -- seconds before the engine fires
audio.STARTUP_PEAK = 1.1   -- the rev flare tops out and the turbo vents
audio.STARTUP_LENGTH = 1.7
local STARTUP_REDLINE = 7000
-- Where each cylinder of a V8 fires in the cycle, and how hard its pulse reaches
-- the tailpipe. The unevenness is what gives it its lope. audio.voice works these
-- out for other engines.
local V8_FIRING = { 0.02, 0.13, 0.27, 0.36, 0.52, 0.61, 0.77, 0.86 }
local V8_LEVEL = { 1, 0.72, 0.9, 0.62, 0.95, 0.7, 0.84, 0.66 }
local LUMP = 0.85                         -- how far a rough engine's firing dips
local ENGINE_RPMS = { 1300, 3000, 5400 }  -- the speeds a voice's loops are rendered at
local RACE_RPMS = { 4000, 8000, 12000 }   -- a race engine lives far higher up
local ENGINE_LOOP, ENGINE_FADE = 0.7, 0.1  -- seconds, before rounding to whole engine cycles
local IDLE_RPM, RACE_IDLE_RPM = 900, 2400   -- what each voice's idle is rendered at
local IDLE_LOOP = 0.45     -- seconds: seven more loops, so they stay short
local IDLE_LEVEL = 0.3
-- Two loops at one engine speed share every harmonic, so where they overlap they
-- can cancel, by up to 10 dB depending on how they happen to line up. Keeping the
-- overlap narrow means a pull passes through it instead of living in it.
local BLEND_WIDTH = 1.12   -- either side of the middle of two speeds, as a ratio
-- How strong each kind of engine loop comes out, as its level above 300 Hz: the part
-- every speaker can play, so every car is as present on a phone. Bass goes on top of
-- that, which is why the big engines sound bigger on anything with a woofer.
local LOOP_LEVEL = { speed = 0.52, overrun = 0.14, idle = 0.3, limiter = 0.46 }
local LOOP_PEAK = 0.9      -- whatever that asks for, nothing goes past this

-- The cut pulses of a gear change, as { seconds, level }: uneven, or it's a buzz.
local SHIFT_PULSES = {
  { 0.012, 1 }, { 0.024, 0.6 }, { 0.04, 0.85 }, { 0.053, 0.5 }, { 0.07, 0.7 }, { 0.09, 0.42 }, { 0.112, 0.3 },
}
-- How hard each exhaust resonance rings. A shift leaves the bass to the engine.
local ENGINE_PIPES = { 1, 0.8, 0.5, 0.28 }
local SHIFT_PIPES = { 0.1, 0.9, 0.8, 0.4 }
local RACE_PIPES = { 0.15, 0.7, 0.9, 0.6 }  -- no bass in a short, wide-open pipe

-- Crashes come in as impulse / 9000: a bumper tap is about 0.2, a 70 m/s head-on
-- into a wall 27. That range is why these work on its logarithm. quiet and loud
-- are the volume at from and at to. A crash also pulls the engine down for a
-- moment, duck being the share taken off it.
local IMPACT_TIERS = {
  { from = 0.15, to = 0.6, quiet = 0.5, loud = 0.9, duck = 0 },
  { from = 0.6, to = 3, quiet = 0.7, loud = 1, duck = 0.3 },
  { from = 3, to = 20, quiet = 0.75, loud = 1, duck = 0.6 },
}
audio.IMPACT_TIERS = IMPACT_TIERS
local GRAZE_LEVEL = 0.35   -- a touch too small for any of those
local KNOCK_LEVEL = 0.45   -- a cone, at its loudest
local KNOCK_PITCH = 1.7
local KNOCK_GAP = 0.08     -- seconds
local DUCK_RECOVERY = 3.5  -- per second, so the engine is back within 0.3 s
local IMPACT_MASS = 1400   -- a car this heavy plays a crash at its written pitch

-- One hit at three sizes. The metal is dead, not ringing: long clean partials are the
-- sound of saucepans. On a phone the thump is gone, so the crunch has to carry it.
-- thump is a sine that sags at thumpFall. crunch is stepped noise held for holdFrom
-- samples, and holdBy more per second, so it coarsens as it dies. snap is the share of
-- it that dies fast. debris is how many bits fall off afterwards.
local CRASHES = {
  { seconds = 0.2, seed = 61, peak = 0.84, drive = 1.6,
    thump = 0.5, thumpHz = 165, thumpFall = 240, thumpDecay = 34, crack = 0.3, crackDecay = 500,
    crunch = 1.3, crunchDecay = 26, snap = 0.2, tone = 0.3, holdFrom = 2, holdBy = 20,
    metal = 0, ring = 0.97, debris = 0 },
  { seconds = 0.4, seed = 71, peak = 0.88, drive = 2.2,
    thump = 0.8, thumpHz = 118, thumpFall = 90, thumpDecay = 15, crack = 0.3, crackDecay = 420,
    crunch = 1.3, crunchDecay = 9, snap = 0.25, tone = 0.42, holdFrom = 1, holdBy = 22,
    metal = 0.5, ring = 0.982, debris = 3 },
  { seconds = 0.85, seed = 83, peak = 0.94, drive = 2.8,
    thump = 0.9, thumpHz = 88, thumpFall = 34, thumpDecay = 8, crack = 0.3, crackDecay = 300,
    crunch = 1.5, crunchDecay = 4.6, snap = 0.25, tone = 0.5, holdFrom = 1, holdBy = 24,
    metal = 0.8, ring = 0.986, debris = 8 },
}
-- Far from any simple ratio, so no pitch comes out of them.
local METAL_HZ = { 587, 1033, 1741, 2953 }
local METAL_LEVEL = { 1, 0.8, 0.6, 0.4 }

local NOISE, SQUARE = sfxr.WAVEFORM.NOISE, sfxr.WAVEFORM.SQUARE

-- White noise through sfxr's low-pass and high-pass, as Hz, its damping (1 / Q) and
-- a gain. bandNoise says why these aren't sfxr presets any more. Nothing steady lives
-- much above 2 kHz: white noise held there for seconds is static, whatever it's
-- meant to be. What tells them apart is what moves. wander swings the low-pass and
-- swell the level, as { cycles of the loop, share }, and a sound that doesn't move at
-- all reads as a fault on the line. body lifts everything under bodyHz by that much.
-- The road's texture is the tread going by, so it speeds up with the car.
local ROAD = { lowHz = 300, damping = 1.1, highHz = 45, gain = 3.2,
  swell = { { 21, 0.2 }, { 34, 0.14 } } }
-- Air in gusts, low, with nothing like a hiss in it.
local WIND = { lowHz = 620, damping = 0.75, highHz = 170, gain = 1.3,
  wander = { { 2, 0.24 }, { 5, 0.14 }, { 11, 0.07 } }, swell = { { 3, 0.2 }, { 7, 0.12 } } }
local LOOSE = { lowHz = 560, damping = 1.2, highHz = 60, gain = 2.2,
  swell = { { 17, 0.2 }, { 29, 0.16 } } }
-- Rubber dragging: the tyre's own chatter on top of a dull rub.
local SCRUB = { lowHz = 950, damping = 1.2, highHz = 130, gain = 1.3,
  swell = { { 37, 0.22 }, { 61, 0.14 } } }
-- The flame cheat's fire: a low ragged roar that flutters as the gas catches.
local FLAME = { lowHz = 520, damping = 1.0, highHz = 40, gain = 2.6, body = 1.4, bodyHz = 110,
  wander = { { 3, 0.15 } }, swell = { { 23, 0.35 }, { 41, 0.25 }, { 67, 0.15 } } }
-- Boost is a can of gas let go slowly, with pressure behind it. A smooth roll off
-- the top, so it's never sharp, and a chest under it, so it pushes.
local BOOST_GAS = { lowHz = 2400, damping = 1.1, highHz = 100, gain = 0.8, body = 1.1, bodyHz = 320,
  wander = { { 2, 0.03 }, { 5, 0.02 } } }
-- Past its limit a tyre grabs and lets go hundreds of times a second, so a squeal is
-- a note, not noise: a sawtooth for each tyre that's gone, a little off the others,
-- each stroke its own size by up to grit. Low for a tyre: more a rubber howl than a
-- shriek, so that it can be held through a whole drift.
local SQUEAL = { hz = { 482, 491, 502 }, lowHz = 1500, damping = 0.9, highHz = 240, grit = 0.4 }
local SQUEAL_DRIFT = { { 3, 0.012 }, { 7, 0.008 } }
local SQUEAL_CHATTER = { { 41, 0.12 }, { 67, 0.08 } }

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
  scrape = {
    waveform = NOISE, frequency = { start = 0.5 }, envelope = { sustain = 0.04, decay = 0.16 },
    lowpass = { cutoff = 0.25 }, highpass = { cutoff = 0.1 },
  },
}

-- By number of turbos. One small turbo spools fast and sits a little higher. More
-- are bigger and lower. size scales the sound's pitch, and vent is the blow-off's
-- volume and pitch against a pair's.
local TURBOS = {
  [1] = { size = 1.18, level = 0.75, spoolUp = 2.6, ventLevel = 0.8, ventPitch = 1.2, boost = 0.5, hiss = 0.28 },
  [2] = { size = 1, level = 1, spoolUp = 1.8, ventLevel = 1, ventPitch = 1, boost = 0.61, hiss = 0.34 },
  [4] = { size = 0.8, level = 1.3, spoolUp = 1.2, ventLevel = 1.25, ventPitch = 0.78, boost = 0.75, hiss = 0.42 },
}
local RACE_SPOOL = 5  -- a race engine's turbo is kept spinning for it

-- Boost drives whatever already feeds the engine harder, so each kind of car sounds
-- like itself under it. Only a car with nothing else to drive hears the gas.
-- TURBOS[n].boost is the loop's volume at full boost: -20 LUFS for one turbo, which
-- is where the gas sits, then -18.5 and -17. The whine and the motor only add to their
-- level, because they're already forward in the mix.
local BOOST_BLOWER, BOOST_MOTOR = 0.2, 0.14
local BOOST_CLIMB = { turbo = 1.12, blower = 1.15, motor = 1.2 }
-- A turbo's own air sits in the band the exhaust fills, so more of it can't be heard.
-- What says boost is above the exhaust, around 2 kHz, where the gas put it. Under
-- boost a turbo car gets a layer of its own up there: rushing air, plus a whistle of
-- noise ringing at one pitch for each turbo. The pitch is TURBO_RING scaled by the
-- turbo's size, so more turbos sit lower, and they're spread by TURBO_RING_SPREAD so
-- they beat. Noise rather than a tone, because a clean one was "a robot screaming".
local TURBO_RING = 2200
local TURBO_RING_SPREAD = 0.07
local TURBO_RING_WIDTH = 0.16
local TURBO_ROAR = { lowHz = 2000, damping = 0.75, highHz = 700, gain = 0.8,
  wander = { { 2, 0.06 }, { 5, 0.04 } }, swell = { { 3, 0.1 }, { 7, 0.07 } } }
local TURBO_BOOST_DUCK = 0.18  -- how far the exhaust steps back, to let it through
-- A turbo is air being forced through a housing, with a faint low whistle in it. A
-- clean tone sliding up over the air is a theremin, which is what an earlier version
-- sounded like, so the whistle wanders and never sits on a note. TURBO_WHISTLE is
-- its Hz and its share of the mix.
local TURBO_AIR = { lowHz = 1000, damping = 0.8, highHz = 240, gain = 0.8,
  wander = { { 2, 0.14 }, { 5, 0.08 } }, swell = { { 3, 0.1 }, { 7, 0.07 } } }
local TURBO_WHISTLE = { 520, 0.3 }
local TURBO_DRIFT = { { 3, 0.05 }, { 5, 0.03 }, { 11, 0.015 } }
local TURBO_SECONDS, TURBO_RMS = 1.7, 0.2
-- A supercharger is one thin, piercing note that climbs hard with the revs, and that
-- note is the sound: the grit and the engine go under it. It's a narrow pulse, as
-- BLOWER_PARTS of { harmonic, level }, with no detuning, which only muddied it. What
-- keeps it from the old flying saucer is a single high note instead of a low stack of
-- harmonics, and the grit. BLOWER_WHINE is its share of the mix and BLOWER_RING how
-- much of that is noise ringing at the same pitches.
local BLOWER_SECONDS, BLOWER_PEAK = 1.7, 0.64
local BLOWER_HZ = 1000
local BLOWER_PARTS = { { 1, 1 }, { 2, 0.81 }, { 3, 0.54 }, { 4, 0.25 }, { 6, 0.17 }, { 7, 0.23 } }
local BLOWER_WHINE, BLOWER_RING = 0.88, 0.12
local BLOWER_DRIFT = { { 3, 0.05 }, { 5, 0.03 }, { 11, 0.015 } }
local BLOWER_GRIT = { saws = { 297, 304, 311 }, grit = 0.5, lowHz = 1300, highHz = 200 }
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

-- A horn is a vibrating diaphragm: bright, buzzy and hard-edged, so it cuts through
-- an engine. Half a second holds a whole number of cycles of both notes.
function audio.hornData()
  return soundData(0.5, function(t)
    local total = 0
    for _, hz in ipairs(HORN_HZ) do
      for harmonic = 1, 8 do
        total = total + math.sin(t * math.pi * 2 * hz * harmonic) / harmonic
      end
    end
    return math.atan(total * 1.2) * 0.5
  end)
end

-- Cross-fade the tail over the head so the loop has no click. Two stretches of
-- noise are unrelated, so they add by power: a straight fade dips by 3 dB halfway
-- and the loop breathes. An engine's cycles line up across the join, so they add
-- as they stand and a fade by power would swell. noise is how much of the sound is
-- unrelated, 0..1, and picks the fade between those two. gain scales the result.
local function crossfade(base, seconds, fadeTime, noise, gain)
  gain = gain or 1
  local curve = 1 - (noise or 0) * 0.5
  local n = math.floor(seconds * RATE)
  local fade = math.min(math.floor(fadeTime * RATE), base:getSampleCount() - n)
  return soundData(seconds, function(_, i)
    local v = base:getSample(i)
    if i < fade then
      local t = i / fade
      v = v * t ^ curve + base:getSample(n + i) * (1 - t) ^ curve
    end
    return v * gain
  end)
end

local function highpass(hz)
  local leak = math.exp(-math.pi * 2 * hz / RATE)
  local lastIn, lastOut = 0, 0
  return function(x)
    lastOut = (lastOut + x - lastIn) * leak
    lastIn = x
    return lastOut
  end
end

-- Anything below 30 Hz is no use to any speaker, and a wave sitting off centre wastes
-- headroom and thumps when it starts or stops.
local function dcBlock()
  return highpass(30)
end

-- A two-pole low-pass, the kind sfxr's is. The second function moves its cutoff.
local function lowpass(damping)
  local b0, b1, a1, a2, x1, x2, y1, y2 = 0, 0, 0, 0, 0, 0, 0, 0
  local function run(x)
    local y = b0 * (x + x2) + b1 * x1 - a1 * y1 - a2 * y2
    x2, x1, y2, y1 = x1, x, y1, y
    return y
  end
  local function tune(hz)
    local w = math.pi * 2 * hz / RATE
    local alpha = math.sin(w) * damping / 2
    local norm = 1 + alpha
    b1, a1, a2 = (1 - math.cos(w)) / norm, -2 * math.cos(w) / norm, (1 - alpha) / norm
    b0 = b1 / 2
  end
  return run, tune
end

-- A slow movement over a loop, from { cycles of the loop, share } pairs. Whole cycles,
-- so it comes back to where it started. phase sets different ones apart.
local function wobble(parts, t, seconds, phase)
  local total = 0
  for _, part in ipairs(parts) do
    total = total + part[2] * math.sin(t * math.pi * 2 * part[1] / seconds + (phase or 0))
  end
  return total
end

-- Scales a rendered sound so its loudest sample reaches peak.
local function normalised(data, peak)
  local n, top = data:getSampleCount(), 0
  for i = 0, n - 1 do top = math.max(top, math.abs(data:getSample(i))) end
  local gain = peak / math.max(top, 1e-6)
  for i = 0, n - 1 do data:setSample(i, data:getSample(i) * gain) end
  return data
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

-- sfxr's noise: a random value held for some samples. The longer the hold, the
-- coarser and more digital it sounds.
local function steppedNoise(rng)
  local value, left = 0, 0
  return function(hold)
    left = left - 1
    if left <= 0 then value, left = rng:random() * 2 - 1, hold end
    return value
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
  local block = dcBlock()
  local base = soundData(seconds + fadeTime, function(_, i)
    local white = rng:random() * 2 - 1
    local total = 0
    for k, partial in ipairs(MOTOR_PARTIALS) do
      local hz = RATE / period * partial[1]
      total = total + (math.sin(i / RATE * math.pi * 2 * hz) * 0.5 + rings[k](white) * 7) * partial[2]
    end
    return block(math.atan(total * 1.6) * 0.5)
  end)
  return crossfade(base, seconds, fadeTime, 0.5)
end

-- Boost and the scrub were sfxr presets, and are still its filters on its noise. But
-- at their settings its noise is plain white, so its eightfold oversampling was five
-- times the render for nothing the ear could get at, and a phone pays that on first
-- launch.
local function bandNoise(settings, seconds, fadeTime)
  local rng = love.math.newRandomGenerator(settings.lowHz)
  local filter, tune = lowpass(settings.damping)
  local cut = highpass(settings.highHz)
  local wander, swell = settings.wander or {}, settings.swell or {}
  local body, chest = settings.body or 0, 1 - math.exp(-math.pi * 2 * (settings.bodyHz or 300) / RATE)
  local gain, low = settings.gain, 0
  local level = 1
  local base = soundData(seconds + fadeTime, function(t, i)
    if i % 32 == 0 then  -- far slower than audio, so it needn't be worked out each sample
      tune(settings.lowHz * (1 + wobble(wander, t, seconds)))
      level = 1 + wobble(swell, t, seconds)
    end
    local y = cut(filter(rng:random() * 2 - 1))
    low = low + (y - low) * chest
    return (y + low * body) * gain * level
  end)
  return crossfade(base, seconds, fadeTime, 1)
end

function audio.roadData()
  return bandNoise(ROAD, 1.5, 0.25)
end

function audio.flameData()
  return bandNoise(FLAME, 1.5, 0.25)
end

function audio.hornTuneLength()
  local length = 0
  for _, note in ipairs(HORN_TUNE) do length = length + note[2] end
  return length
end

-- Where the tune horn is, t seconds into the song: the pitch as a ratio of the
-- horn's own, and whether a note is sounding.
function audio.hornTuneNote(t)
  t = t % audio.hornTuneLength()
  for _, note in ipairs(HORN_TUNE) do
    if t < note[2] then
      if not note[1] then return 1, false end
      return 2 ^ (note[1] / 12), t < note[2] * (1 - HORN_GAP)
    end
    t = t - note[2]
  end
  return 1, false
end

-- Steps one car's horn and leaves what it plays in car.hornRatio and
-- car.hornSounding. With the tune on, a press plays the whole song, a press during
-- it changes nothing, and a horn still held at the end plays it again.
function audio.hornStep(car, dt)
  if not car.hornTune then
    car.tuneTime = nil
    car.hornRatio, car.hornSounding = 1, car.horn
    return
  end
  if not car.tuneTime then
    if not car.horn then
      car.hornRatio, car.hornSounding = 1, false
      return
    end
    car.tuneTime = 0
  end
  car.hornRatio, car.hornSounding = audio.hornTuneNote(car.tuneTime)
  car.tuneTime = car.tuneTime + dt
  if car.tuneTime >= audio.hornTuneLength() then car.tuneTime = car.horn and 0 or nil end
end

-- Air, then a whistle for each turbo. Each has a whole number of cycles in the loop
-- and they sit a little apart, so it joins up and the bigger cars beat slowly.
function audio.turboData(turbos)
  local size = TURBOS[turbos].size
  local settings = {}
  for key, value in pairs(TURBO_AIR) do settings[key] = value end
  settings.lowHz, settings.highHz = TURBO_AIR.lowHz * size, TURBO_AIR.highHz * size
  local air = bandNoise(settings, TURBO_SECONDS, 0.25)
  local hz, share = TURBO_WHISTLE[1] * size, TURBO_WHISTLE[2]
  local cycles, drift = {}, {}
  for k = 1, turbos do cycles[k] = math.floor(hz * (1 + (k - 1) * 0.012) * TURBO_SECONDS + 0.5) end
  local mixed = soundData(TURBO_SECONDS, function(t, i)
    local total = 0
    for k = 1, turbos do
      if i % 32 == 0 then drift[k] = wobble(TURBO_DRIFT, t, TURBO_SECONDS, k * 1.7) * 9 end
      total = total + math.sin(t * math.pi * 2 * cycles[k] / TURBO_SECONDS + drift[k])
    end
    return air:getSample(i) * (1 - share) + total / math.sqrt(turbos) * share * 0.3
  end)
  local sum, count = 0, mixed:getSampleCount()
  for i = 0, count - 1 do sum = sum + mixed:getSample(i) ^ 2 end
  local gain = TURBO_RMS / math.sqrt(sum / count)
  return soundData(TURBO_SECONDS, function(_, i) return mixed:getSample(i) * gain end)
end

-- The layer over the exhaust while a turbo car is on boost. See TURBO_RING.
function audio.turboBoostData(turbos)
  local size = TURBOS[turbos].size
  local roar = {}
  for key, value in pairs(TURBO_ROAR) do roar[key] = value end
  roar.lowHz, roar.highHz = TURBO_ROAR.lowHz * size, TURBO_ROAR.highHz * size
  local air = bandNoise(roar, TURBO_SECONDS, 0.25)
  local rings = {}
  for k = 1, turbos do
    local spread = 1 + (k - (turbos + 1) / 2) * TURBO_RING_SPREAD
    rings[k] = bandNoise({ lowHz = TURBO_RING * size * spread, damping = TURBO_RING_WIDTH,
      highHz = TURBO_RING * size * spread * 0.6, gain = 0.5,
      wander = { { 2, 0.04 }, { 5, 0.025 } }, swell = { { 3, 0.12 }, { 11, 0.06 } } }, TURBO_SECONDS, 0.25)
  end
  local mixed = soundData(TURBO_SECONDS, function(_, i)
    local ringing = 0
    for k = 1, turbos do ringing = ringing + rings[k]:getSample(i) end
    return air:getSample(i) + ringing / math.sqrt(turbos)
  end)
  local sum, count = 0, mixed:getSampleCount()
  for i = 0, count - 1 do sum = sum + mixed:getSample(i) ^ 2 end
  local gain = TURBO_RMS / math.sqrt(sum / count)
  return soundData(TURBO_SECONDS, function(_, i) return mixed:getSample(i) * gain end)
end

-- Rough saws, a little apart, each stroke its own size.
local function blowerGrit()
  local settings = BLOWER_GRIT
  local rng = love.math.newRandomGenerator(91)
  local filter, tune = lowpass(0.9)
  local cut = highpass(settings.highHz)
  tune(settings.lowHz)
  local notes = {}
  for k, hz in ipairs(settings.saws) do notes[k] = { hz = hz, at = k / 3, step = 0, size = 1 } end
  local base = soundData(BLOWER_SECONDS + 0.2, function(t, i)
    local total = 0
    for k, note in ipairs(notes) do
      if i % 32 == 0 then note.step = note.hz * (1 + wobble(BLOWER_DRIFT, t, BLOWER_SECONDS, k * 2.1) * 0.5) / RATE end
      note.at = note.at + note.step
      if note.at >= 1 then note.at, note.size = note.at - 1, 1 - rng:random() * settings.grit end
      total = total + (note.at * 2 - 1) * note.size
    end
    return cut(filter(total * 0.2))
  end)
  return crossfade(base, BLOWER_SECONDS, 0.2, 1)
end

-- The noise rings by hand here because a resonator gets louder the lower it sits, and
-- past ±1 soundData's clamp would add a harmonic that nobody asked for.
local function blowerRinging()
  local rng = love.math.newRandomGenerator(137)
  local rings, drive = {}, {}
  for k, part in ipairs(BLOWER_PARTS) do
    local hz = BLOWER_HZ * part[1]
    rings[k] = resonator(hz, 0.997)
    drive[k] = part[2] * 10 * math.sin(hz * math.pi * 2 / RATE)
  end
  local dull, tune = lowpass(0.9)
  tune(BLOWER_HZ * BLOWER_PARTS[#BLOWER_PARTS][1] * 1.6)  -- a resonator's skirts reach a long way up
  local base = soundData(BLOWER_SECONDS + 0.2, function()
    local white, total = rng:random() * 2 - 1, 0
    for k in ipairs(BLOWER_PARTS) do total = total + rings[k](white) * drive[k] end
    return dull(total)
  end)
  return crossfade(base, BLOWER_SECONDS, 0.2, 1)
end

-- Whole cycles, so the note joins up by itself and only the noise needs a crossfade.
function audio.blowerData()
  local grit, ringing = blowerGrit(), blowerRinging()
  local cycles = math.floor(BLOWER_HZ * BLOWER_SECONDS + 0.5)
  local drift = 0
  return normalised(soundData(BLOWER_SECONDS, function(t, i)
    if i % 32 == 0 then drift = wobble(BLOWER_DRIFT, t, BLOWER_SECONDS, 1.7) * 2 end
    local phase = t * math.pi * 2 * cycles / BLOWER_SECONDS + drift
    local clean = 0
    for _, part in ipairs(BLOWER_PARTS) do clean = clean + math.sin(phase * part[1]) * part[2] end
    local whine = clean * 0.3 * (1 - BLOWER_RING) + ringing:getSample(i) * BLOWER_RING
    return grit:getSample(i) * (1 - BLOWER_WHINE) + whine * BLOWER_WHINE
  end), BLOWER_PEAK)
end

function audio.windData()
  return bandNoise(WIND, 3, 0.25)
end

-- A soft rumble of dirt under the tyres.
function audio.looseData()
  return bandNoise(LOOSE, 1.2, 0.2)
end

function audio.scrubData()
  return bandNoise(SCRUB, 1.7, 0.25)
end

function audio.boostGasData()
  return bandNoise(BOOST_GAS, 1.7, 0.25)
end

-- The tyres don't agree, and their pitch won't hold still. Every note lands on a whole
-- number of cycles of the loop, so it joins up with itself.
function audio.squealData()
  local seconds, fadeTime = 1.5, 0.15
  local rng = love.math.newRandomGenerator(67)
  local filter, tune = lowpass(SQUEAL.damping)
  local cut = highpass(SQUEAL.highHz)
  tune(SQUEAL.lowHz)
  local notes = {}
  for k, hz in ipairs(SQUEAL.hz) do
    notes[k] = { hz = math.floor(hz * seconds + 0.5) / seconds, at = k / #SQUEAL.hz, step = 0, size = 1 }
  end
  local base = soundData(seconds + fadeTime, function(t, i)
    local total = 0
    for k, note in ipairs(notes) do
      if i % 32 == 0 then
        note.step = note.hz * (1 + wobble(SQUEAL_DRIFT, t, seconds, k * 2.1)) / RATE
      end
      note.at = note.at + note.step
      if note.at >= 1 then note.at, note.size = note.at - 1, 1 - rng:random() * SQUEAL.grit end
      total = total + (note.at * 2 - 1) * note.size
    end
    return cut(filter(total)) * (1 + wobble(SQUEAL_CHATTER, t, seconds)) * 0.3
  end)
  return normalised(crossfade(base, seconds, fadeTime, 0), 0.7)
end

-- Bodywork dragging along a wall: coarse noise through a few broad bands, chattering
-- as the panels catch and let go.
function audio.grindData()
  local seconds, fadeTime = 1.2, 0.15
  local rng = love.math.newRandomGenerator(73)
  local noise = steppedNoise(rng)
  local a, b, c = resonator(640, 0.97), resonator(1480, 0.96), resonator(3100, 0.93)
  local block = dcBlock()
  local base = soundData(seconds + fadeTime, function(t)
    local grit = noise(3)
    local chatter = 0.55 + 0.3 * math.abs(math.sin(t * math.pi * 2 * 22 / seconds))
      + 0.15 * math.sin(t * math.pi * 2 * 61 / seconds)
    return block((a(grit) + b(grit) * 0.9 + c(grit) * 0.5) * chatter * 0.5)
  end)
  return normalised(crossfade(base, seconds, fadeTime, 1), 0.7)
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

-- What an engine sounds like, from its cylinder count. More cylinders are rougher:
-- their firing gets less even, the gas noisier, the saturation harder, and the
-- bass heavier as the pipes get bigger. A V8 is the middle of the range, and
-- comes out as it always has. A race engine ignores all that: dead even firing
-- through short pipes, so a V6 at 12,000 rpm is a smooth, high wail.
function audio.voice(cylinders, race)
  local rough = race and 0.02 or math.min(1, (cylinders - 3) / 13)
  local firing, levels = V8_FIRING, V8_LEVEL
  if race or cylinders ~= 8 then
    local rng = love.math.newRandomGenerator(cylinders)
    firing, levels = {}, {}
    for i = 1, cylinders do
      firing[i] = (i - 0.9 + (rng:random() - 0.5) * rough * 0.7) / cylinders
      -- Lumps twice in a cycle, once a turn, or the ear just hears an average.
      local lump = 0.5 + 0.5 * math.sin((i - 1) / cylinders * math.pi * 4)
      levels[i] = 1 - (lump * 0.7 + rng:random() * 0.3) * rough * LUMP
    end
  end
  return {
    key = cylinders .. (race and "race" or ""),
    cylinders = cylinders,
    rpms = race and RACE_RPMS or ENGINE_RPMS,
    idleAt = race and RACE_IDLE_RPM or IDLE_RPM,
    firing = firing,
    levels = levels,
    pipes = race and RACE_PIPES or { 0.35 + rough * 0.65, 0.9, 0.7, 0.35 },
    pipeScale = race and 2 or (8 / cylinders) ^ 0.3,
    noise = 0.25 + rough * 0.65,
    -- Each burst of gas has to end before the next, or the firing averages out.
    burst = race and 0.001 or 0.0028 * math.min(1, 8 / cylinders),
    charge = math.min(1, 8 / cylinders) ^ 0.75,  -- many cylinders are small ones
    drive = race and 0.6 or 0.6 + math.sqrt(rough) * 0.65,
    gain = race and 1.85 or 1,  -- with no bass in it, a race engine rings far less
    rasp = race and 0.25 or 0.3 + rough * 0.5,
    presence = race and 0.25 or 1,
    level = race and 0.66 or 1,  -- all of a race engine reaches a phone, so it needs less
  }
end

-- The firing order, run at any rpm. Each call asks strength(level, cylinder) for
-- what a cylinder that fires this sample delivers, and returns the strongest.
local function newFiring(voice)
  local firing, levels = voice.firing, voice.levels
  local phase, cylinder, cycle = 0, 1, 0
  return function(rpm, strength)
    phase = phase + rpm / 120 / RATE  -- a four-stroke cycle is two turns
    local fired = 0
    while phase >= cycle + firing[cylinder] do
      fired = math.max(fired, strength(levels[cylinder], cylinder))
      cylinder = cylinder + 1
      if cylinder > #firing then cylinder, cycle = 1, cycle + 1 end
    end
    return fired
  end
end

-- Firing pulses leaving through the exhaust. Each call takes the strongest pulse
-- fired this sample. Hot gas leaving a valve is a rough burst, not a clean click.
local function newExhaust(pipeLevels, voice, rasp)
  local scale, noise, charge = voice.pipeScale, voice.noise, voice.charge
  rasp = rasp or 0
  local pipes = {
    resonator(92 * scale, 0.994), resonator(265 * scale, 0.99), resonator(710 * scale, 0.98), resonator(1900 * scale, 0.96),
  }
  local pressureDecay = math.exp(-1 / (voice.burst * RATE))
  local pressure, body = 0, 0
  local edge, edgeBody = 0, 0
  return function(fired, white, grain)
    pressure = math.max(pressure, fired * charge) * pressureDecay
    local gas = pressure * (0.65 + white * noise)
    body = body + (gas - body) * 0.015
    local pulse = gas - body  -- only the swing: steady pressure would pin the saturation
    local exhaust = pulse * 0.5
    for i, pipe in ipairs(pipes) do exhaust = exhaust + pipe(pulse) * pipeLevels[i] * 2.2 end
    -- The rasp: each burst's noise without its body, about 400 Hz to 2.5 kHz. It's
    -- the edge on the note, and most of what a phone's speaker gets to play.
    edge = edge + (pressure * (grain or white) - edge) * 0.3
    edgeBody = edgeBody + (edge - edgeBody) * 0.06
    return exhaust + (edge - edgeBody) * rasp
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
  local voice = audio.voice(8)
  local firing, exhaust, vent, knock = newFiring(voice), newExhaust(ENGINE_PIPES, voice), newVent(), newKnock()

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

-- One steady speed of an engine, as a loop. Whole engine cycles, so the firing
-- lines up across the join. mode "overrun" is the throttle shut: weak, uneven
-- pulses, the burble as the revs fall. Mode "idle" is ticking over: small pulses
-- that vary from one firing to the next, unstrained and low. Mode "limiter" is the
-- sparks cutting at the top of the revs, and the only one driven hard: of every two
-- engine cycles, the first one fires. Any more and the exhaust ringing on fills the
-- gaps. The rest are driven far less than the startup: that much saturation is
-- thrilling for a second, and square and fuzzy for a whole race.
function audio.engineData(voice, rpm, mode)
  local overrun, limiter, idle = mode == "overrun", mode == "limiter", mode == "idle"
  local cycle = 120 / rpm
  local seconds = math.ceil((idle and IDLE_LOOP or ENGINE_LOOP) / cycle) * cycle
  local fadeTime = math.ceil(ENGINE_FADE / cycle) * cycle
  local rng = love.math.newRandomGenerator(rpm + (overrun and 1 or limiter and 2 or idle and 3 or 0))
  -- Up the revs the note moves into the short pipes. The bass stays: the splash's
  -- flare is the balance to aim for, and it keeps its chest.
  local height = idle and 0.3 or rpm / voice.rpms[#voice.rpms]
  local pipes = voice.pipes
  local tilted = { pipes[1], pipes[2], pipes[3] * (1 + 0.8 * height), pipes[4] * (1 + height) }
  local firing, exhaust = newFiring(voice), newExhaust(tilted, voice, voice.rasp * (0.4 + height))
  local drive = (overrun and 0.35) or (limiter and 1) or (idle and 0.3) or (0.3 + rpm / 20000) * voice.drive
  local gain = (overrun and 0.5 or idle and 0.62 or 0.72) * voice.gain
  local shot, cylinders = 0, voice.cylinders
  local function strength(level)
    shot = shot + 1
    if limiter then return (shot - 1) % (cylinders * 2) < cylinders and level or 0 end
    if idle then return level * (0.5 + rng:random() * 0.35) end
    if not overrun then return level end
    return rng:random() < 0.3 and 0 or level * 0.28
  end
  -- A shelf from about 300 Hz, after the saturation so it brightens without adding
  -- any fuzz. A phone's speaker starts about there, and without this a phone plays
  -- the bass of a V8 as nothing at all.
  local presence = voice.presence * (idle and 2.4 or 0.6 + height)
  -- The same grain of noise every cycle, so the rasp has the note's pitch. High up the
  -- bursts run together, and fresh noise there is a steady hiss on top of the engine.
  -- Low down a little of it is what makes the firing rough, so that stays.
  local fresh = 1 - 0.75 * height
  local grainRng, grains = love.math.newRandomGenerator(rpm + 7), {}
  local grainCount = math.floor(cycle * RATE)
  for i = 1, grainCount do grains[i] = grainRng:random() * 2 - 1 end
  local block = dcBlock()
  local bass, top, peak = 0, 0, 0
  local base = soundData(seconds + fadeTime, function(t)
    local fired = firing(rpm, strength)
    local grain = grains[math.floor((t / cycle) % 1 * grainCount) + 1]
    local white = rng:random() * 2 - 1
    local engine = math.atan(exhaust(fired, grain + (white - grain) * fresh, grain) * drive) * gain
    bass = bass + (engine - bass) * 0.042
    local upper = engine - bass
    top = top + upper * upper
    engine = engine + upper * presence
    local v = block(engine / (1 + math.abs(engine) * 0.5) * 0.85)
    if v > peak then peak = v elseif -v > peak then peak = -v end
    return v
  end)
  local upper = math.sqrt(top / ((seconds + fadeTime) * RATE)) * (1 + presence)
  local wanted = LOOP_LEVEL[mode or "speed"] * voice.level / upper
  return crossfade(base, seconds, fadeTime, 0, math.min(wanted, LOOP_PEAK / peak))
end

-- An upshift is the power cutting out: the gear goes in with a knock while the
-- exhaust sputters on the cut sparks. Most of it sits in the midrange, because a
-- phone speaker can't play anything below about 200 Hz.
function MODELLED.shift()
  local rng = love.math.newRandomGenerator(43)
  local exhaust, knock = newExhaust(SHIFT_PIPES, audio.voice(8)), newKnock()
  local block = dcBlock()
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
    return block(mixed) * math.min(1, (SHIFT_LENGTH - t) / 0.03) * 0.6
  end)
end

-- A square-wave climb up a major chord, built from the same voice as the start
-- lights, with the top note left to ring.
local FINISH_NOTES = { 523, 659, 784, 1047 }
local FINISH_STEP = 0.1

function MODELLED.finish()
  return soundData(0.95, function(t)
    local v = 0
    for i, hz in ipairs(FINISH_NOTES) do
      local since = t - (i - 1) * FINISH_STEP
      if since > 0 then
        local wave = (since * hz) % 1 < 0.5 and 1 or -1
        local ring = i == #FINISH_NOTES and 5 or 16
        v = v + wave * math.exp(-since * ring) * math.min(1, since * 500)
      end
    end
    return v * 0.3
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

-- A crash, at one of the sizes in CRASHES. A crack of bare noise at the instant of
-- contact, a thump that sags, and sfxr-style stepped noise that coarsens as it dies,
-- exciting a little dead metal. The big ones shed a few bits after the hit.
function audio.crashData(size)
  local crash = CRASHES[size]
  local rng = love.math.newRandomGenerator(crash.seed)
  local noise = steppedNoise(rng)
  local rings = {}
  for i, hz in ipairs(METAL_HZ) do rings[i] = resonator(hz, crash.ring) end
  local bits = {}
  for i = 1, crash.debris do
    bits[i] = { at = 0.07 + rng:random() * rng:random() * crash.seconds * 0.7, level = 0.2 + rng:random() * 0.3 }
  end
  local low, lower = 0, 0
  local bit = resonator(2300, 0.96)
  local block = dcBlock()
  local data = soundData(crash.seconds, function(t)
    local white = rng:random() * 2 - 1
    low = low + (noise(crash.holdFrom + math.floor(crash.holdBy * t)) - low) * crash.tone
    lower = lower + (low - lower) * 0.04
    local snap = crash.snap
    local crunch = (low - lower) * (math.exp(-t * 55) * snap + math.exp(-t * crash.crunchDecay) * (1 - snap))
    local metal = 0
    for i, ring in ipairs(rings) do metal = metal + ring(crunch) * METAL_LEVEL[i] end
    local rattle = 0
    for _, piece in ipairs(bits) do
      local since = t - piece.at
      if since > 0 and since < 0.03 then rattle = rattle + white * piece.level * math.exp(-since * 260) end
    end
    local thump = math.sin((crash.thumpHz * t - crash.thumpFall * t * t) * math.pi * 2) * math.exp(-t * crash.thumpDecay)
    local mixed = thump * crash.thump + white * math.exp(-t * crash.crackDecay) * crash.crack
      + crunch * crash.crunch + metal * crash.metal * 0.45 + bit(rattle) * 3
    -- atan tops out at 1.57, and soundData clamps at 1.
    return block(math.atan(mixed * crash.drive)) * 0.62 * math.min(1, t / 0.0006) * math.min(1, (crash.seconds - t) / 0.03)
  end)
  return normalised(data, crash.peak)
end

for size = 1, #CRASHES do
  MODELLED["impact" .. size] = function() return audio.crashData(size) end
end

-- Gives the screen a turn when the game is loading on the side, but only when
-- it's due one: sounds read from the cache go by in a few milliseconds.
local lastBreath = 0
local BREATH = 1 / 30

local function breathe()
  if not coroutine.running() then return end
  local now = love.timer.getTime()
  if now - lastBreath < BREATH then return end
  coroutine.yield()
  lastBreath = love.timer.getTime()
end

local function looping(data)
  local source = love.audio.newSource(data, "static")
  source:setLooping(true)
  source:setVolume(0)
  breathe()
  return source
end

local function loop(name, render, ...)
  return looping(cache.get(name, render, ...))
end

local function shot(name, render, ...)
  local source = love.audio.newSource(cache.get(name, render, ...), "static")
  breathe()
  return source
end

-- The loops of one voice. Only the car's own engine plays, so a voice costs memory
-- but nothing per frame.
local function engineLoops(voice)
  local name = "engine" .. voice.key
  local engine = { voice = voice, speeds = {} }
  for i, rpm in ipairs(voice.rpms) do engine.speeds[i] = loop(name .. "_" .. i, audio.engineData, voice, rpm) end
  engine.overrun = loop(name .. "_overrun", audio.engineData, voice, voice.rpms[2], "overrun")
  engine.idle = loop(name .. "_idle", audio.engineData, voice, voice.idleAt, "idle")
  engine.limiter = loop(name .. "_limiter", audio.engineData, voice, voice.rpms[#voice.rpms], "limiter")
  engine.rival = engine.speeds[2]:clone()
  return engine
end

function audio.load()
  if audio.ready or not love.audio then return end
  local ok, err = pcall(function()
    cache.open({ "src/audio.lua", "src/lib/sfxr.lua" })
    audio.scrub = loop("scrub", audio.scrubData)
    audio.squeal = loop("squeal", audio.squealData)
    audio.grind = loop("grind", audio.grindData)
    audio.road = loop("road", audio.roadData)
    audio.loose = loop("loose", audio.looseData)
    audio.wind = loop("wind", audio.windData)
    audio.boostGas = loop("boostgas", audio.boostGasData)
    audio.horn = loop("horn", audio.hornData)
    audio.rivalHorn = audio.horn:clone()
    audio.flame = loop("flame", audio.flameData)
    audio.engines, audio.turbos, audio.turboBoosts = {}, {}, {}
    for _, spec in ipairs(garage) do
      local voice = audio.voiceOf(spec)
      if voice and not audio.engines[voice.key] then audio.engines[voice.key] = engineLoops(voice) end
      if TURBOS[spec.turbos] and not audio.turbos[spec.turbos] then
        audio.turbos[spec.turbos] = loop("turbo" .. spec.turbos, audio.turboData, spec.turbos)
        audio.turboBoosts[spec.turbos] = loop("turboboost" .. spec.turbos, audio.turboBoostData, spec.turbos)
      end
    end
    audio.blower = loop("blower", audio.blowerData)
    local motor = cache.get("motor", audio.motorData)
    audio.motor = looping(motor)
    audio.rivalMotor = looping(motor)
    audio.shots = {}
    for _, name in ipairs({ "beep", "go", "click", "select", "shift", "lap", "blowoff", "finish" }) do
      audio.shots[name] = shot(name, audio.shotData, name)
    end
    audio.shots.startup = shot("startup", audio.startupData)
    -- impacts[0] is the graze, then the sizes of crash. Each size can overlap itself.
    audio.impacts = {}
    for size = 0, #IMPACT_TIERS do
      local name = size == 0 and "scrape" or "impact" .. size
      local data = cache.get(name, audio.shotData, name)
      audio.impacts[size] = {}
      for i = 1, 2 do audio.impacts[size][i] = love.audio.newSource(data, "static") end
    end
    cache.finish()
    audio.lastImpact, audio.lastSize = 0, 0
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

-- Which size of crash a strength is, 0 being a graze, and how loud to play it.
function audio.impactLevel(strength)
  for size = #IMPACT_TIERS, 1, -1 do
    local tier = IMPACT_TIERS[size]
    if strength >= tier.from then
      local place = math.log(strength / tier.from) / math.log(tier.to / tier.from)
      return size, tier.quiet + (tier.loud - tier.quiet) * math.min(1, place)
    end
  end
  return 0, GRAZE_LEVEL
end

-- A heavy car's crash sits lower than a light one's.
function audio.impactPitch(spec)
  return math.max(0.85, math.min(1.15, (IMPACT_MASS / spec.mass) ^ 0.3))
end

-- A cone bowled over: the graze, pitched up into a hollow plastic knock.
-- impulse is in N s, about 150 for a cone taken flat out.
function audio.knock(impulse)
  if not audio.ready then return end
  -- One cone touches a car over several steps.
  local now = love.timer.getTime()
  if now - (audio.lastKnock or 0) < KNOCK_GAP then return end
  audio.lastKnock = now
  local pool = audio.impacts[0]
  local free = pool[1]
  for _, s in ipairs(pool) do
    if not s:isPlaying() then free = s end
  end
  free:stop()
  free:setVolume(KNOCK_LEVEL * math.min(1, 0.3 + impulse / 150))
  free:setPitch(KNOCK_PITCH * audio.variedPitch(0.1))
  free:play()
end

-- strength is the crash's impulse / 9000. spec is the car it happened to, and
-- who the seat of the driver in it, whose engine ducks under the crash.
function audio.impact(strength, spec, who)
  if not audio.ready then return end
  local ch = audio.channel(who)
  local size, volume = audio.impactLevel(strength)
  -- Pressed along a wall, the grind already is the sound of it.
  if size == 0 and ch.grind:getVolume() > 0.02 then return end
  local now = love.timer.getTime()
  if now - audio.lastImpact < IMPACT_GAP and size <= audio.lastSize then return end
  audio.lastImpact, audio.lastSize = now, size
  local pool = audio.impacts[size]
  local free = pool[1]
  for _, s in ipairs(pool) do
    if not s:isPlaying() then free = s end
  end
  free:stop()
  free:setVolume(volume * (0.92 + love.math.random() * 0.08))
  free:setPitch(audio.variedPitch(0.06) * (spec and audio.impactPitch(spec) or 1))
  free:play()
  if size > 0 then ch.duck = math.max(ch.duck, IMPACT_TIERS[size].duck) end
end

-- Sliding is worth hearing. Braking shouldn't nag every time it's used.
function audio.scrubLevel(slide, braking)
  if braking then return 0 end
  return math.max(0, math.min(SCRUB_MAX, (slide - 0.25) * SCRUB_RISE))
end

-- The squeal comes in on top once a tyre is well past its limit.
function audio.squealLevel(slide, braking)
  if braking then return 0 end
  return math.max(0, math.min(SQUEAL_MAX, (slide - SQUEAL_FROM) * SQUEAL_RISE))
end

-- scraping is how much of the car is on a wall, 0..1. Stopped against one is silent.
function audio.grindLevel(scraping, speed)
  return scraping * GRIND_MAX * math.min(1, speed / 22)
end

-- offRoad is the share of the car on loose ground, 0..1.
function audio.looseLevel(offRoad, speed)
  return offRoad * LOOSE_MAX * math.min(1, speed / 25)
end

local FADE_OUT = 0.5

local function fadeTo(source, target, dt, rate)
  local now = source:getVolume()
  -- Silent and staying so. A loop this quiet is already paused: only this
  -- function plays loops, and it pauses them at this level.
  if now <= 0.001 and target <= 0.001 then return end
  local step = (rate or 8) * dt
  local v = now + math.max(-step, math.min(step, target - now))
  source:setVolume(v)
  if v > 0.001 and not source:isPlaying() then source:play() end
  if v <= 0.001 and source:isPlaying() then source:pause() end
end

-- Turbo pressure lags the throttle, and has to go somewhere when it closes.
-- Returns true on the moment it vents.
-- spoolUp is how fast it fills, per second.
function audio.spoolStep(spool, onPower, revs, dt, spoolUp)
  local target = onPower and math.min(1, revs * 1.4) or 0
  local rate = target > spool and spoolUp or SPOOL_DOWN
  local step = rate * dt
  local nextSpool = spool + math.max(-step, math.min(step, target - spool))
  return nextSpool, spool >= BLOWOFF_SPOOL and not onPower
end

-- A truck's horn sits lower than a hatchback's.
function audio.hornPitch(spec)
  return math.max(0.7, math.min(1.25, math.sqrt(HORN_MASS / spec.mass)))
end

-- The note lifts as pressure builds, but only by half an octave or so. A wider sweep
-- sounds like something screaming.
function audio.turboPitch(spool)
  return 0.72 + spool * 0.38
end

-- Geared to the crank, so it climbs with the revs. That climb is half of the sound.
function audio.blowerPitch(revs)
  return 0.35 + revs * 1.3
end

-- The more pressure there is to dump, the louder it goes.
function audio.blowoffVolume(spool)
  return 0.3 + spool * 0.4
end

-- The gas sags as the bottle empties. tank is the share left, 0..1.
function audio.boostGasPitch(tank)
  return 0.9 + math.max(0, math.min(1, tank)) * 0.2
end

function audio.boostGasLevel(tank)
  return BOOST_GAS_LEVEL * (1 - BOOST_SAG * (1 - math.max(0, math.min(1, tank))))
end

-- What boost drives in this car.
function audio.boostKind(spec)
  if TURBOS[spec.turbos] then return "turbo" end
  if spec.supercharged then return "blower" end
  if spec.cylinders == 0 then return "motor" end
  return "gas"
end

-- How hard boost is being felt, 0..1. It eases like the gas, and sags with the tank.
function audio.boostStep(boost, active, tank, dt)
  local target = active and 1 - BOOST_SAG * (1 - math.max(0, math.min(1, tank))) or 0
  local step = (target > boost and BOOST_IN or BOOST_OUT) * dt
  return boost + math.max(-step, math.min(step, target - boost))
end

-- What boost does to the pitch of a car's turbo, whine or motor.
function audio.boostPitch(spec, boost)
  local climb = BOOST_CLIMB[audio.boostKind(spec)]
  return climb and 1 + (climb - 1) * boost or 1
end

-- The same sample twice running sounds like a machine gun.
function audio.variedPitch(spread)
  spread = spread or 0.07
  return 1 - spread + love.math.random() * spread * 2
end

-- The engine note drops out while a gear changes, because the power does.
function audio.engineLoad(throttle, shifting)
  return 0.45 + (shifting and 0 or math.min(1, throttle) * 0.55)
end

-- The voice a car's engine uses, or nil for an electric car: no cylinders.
function audio.voiceOf(spec)
  if spec.cylinders == 0 then return nil end
  local key = spec.cylinders .. (spec.raceExhaust and "race" or "")
  voices[key] = voices[key] or audio.voice(spec.cylinders, spec.raceExhaust)
  return voices[key]
end

-- How loud each part of a car's engine should be.
function audio.engineMix(spec, revs, load, spool, boost)
  boost = boost or 0
  local electric = spec.cylinders == 0
  local turbo = TURBOS[spec.turbos]
  local forced = turbo and spool ^ 2 * 0.3 * turbo.level or 0
  return {
    exhaust = electric and 0 or 0.34 + revs * 0.34,
    idle = electric and 0 or IDLE_LEVEL,
    limiter = electric and 0 or 0.39 + revs * 0.39,
    turbo = turbo and forced + (turbo.boost - forced) * boost or 0,
    turboBoost = turbo and turbo.hiss * boost or 0,
    -- A supercharger is geared to the crank, so it whines the instant the revs rise.
    blower = spec.supercharged and (0.096 + revs * 0.384) * load + BOOST_BLOWER * boost or 0,
    -- An electric car has no pistons to hear: the motor stands in for them.
    motor = electric and math.min(1, revs * 3) * (0.1 + load * 0.2) + BOOST_MOTOR * boost or 0,
  }
end

-- How much of each rendered speed to play at this rpm, handing over between the
-- two nearest so the exhaust note moves with the revs instead of being pitched up.
-- Their shares add by power, because the loops don't line up: a straight fade dips
-- by 3 dB at every handover.
function audio.engineBlend(rpm, rpms)
  local blend = {}
  for i = 1, #rpms do blend[i] = 0 end
  local last = #rpms
  for i = 1, last - 1 do
    local middle = math.sqrt(rpms[i] * rpms[i + 1])
    local from, to = middle / BLEND_WIDTH, middle * BLEND_WIDTH
    if rpm < to or i == last - 1 then
      local place = math.max(0, math.min(1, (rpm - from) / (to - from)))
      blend[i], blend[i + 1] = math.cos(place * math.pi / 2), math.sin(place * math.pi / 2)
      return blend
    end
  end
  return blend
end

-- How much of the engine is simply ticking over, 0..1, gone by twice idle.
function audio.idleShare(rpm, idleRpm)
  return 1 - math.max(0, math.min(1, (rpm - idleRpm * 1.15) / (idleRpm * 0.85)))
end

-- A narrower sweep than the speed alone would give: the full range is a swoop.
function audio.motorPitch(revs)
  return 0.5 + revs * 1.2
end

local function enginePitch(rpm, at)
  return math.min(3.2, math.max(0.35, rpm / at))
end

-- A driver's own set of loops and the state behind them. The first is this
-- module itself, so one driver alone sounds exactly as ever. A second, for two at
-- a screen, is a clone of every loop: clones share their samples, so it costs
-- sources and no memory to speak of.
local channels = { audio }
audio.gain = 1

local function fadeCh(ch, source, target, dt, rate)
  fadeTo(source, target * ch.gain, dt, rate)
end

-- The loops a driver's channel has one of each of. The rival's are the first's alone.
local LOOP_KEYS = { "scrub", "squeal", "grind", "road", "loose", "wind", "boostGas", "blower", "motor", "horn", "flame" }
-- Two at a screen each hear their own car a little to their own side, and a
-- little quieter, so two engines together aren't louder than one alone was.
local SPLIT_PAN = 0.5    -- sideways share of a unit distance: about 30 degrees
local SPLIT_GAIN = 0.8

-- Every source in a channel. The first's rival loops aren't in it.
local function eachChannelLoop(ch, fn)
  for _, key in ipairs(LOOP_KEYS) do fn(ch[key]) end
  for _, source in pairs(ch.turbos) do fn(source) end
  for _, source in pairs(ch.turboBoosts) do fn(source) end
  for _, engine in pairs(ch.engines) do
    for _, source in ipairs(engine.speeds) do fn(source) end
    fn(engine.overrun)
    fn(engine.idle)
    fn(engine.limiter)
  end
end

local function cloneChannel()
  local ch = { gain = 1, spool = 0, duck = 0, boost = 0, boosting = false, engines = {}, turbos = {}, turboBoosts = {} }
  local function copy(source)
    local c = source:clone()
    c:stop()
    c:setVolume(0)
    return c
  end
  for _, key in ipairs(LOOP_KEYS) do ch[key] = copy(audio[key]) end
  for k, source in pairs(audio.turbos) do ch.turbos[k] = copy(source) end
  for k, source in pairs(audio.turboBoosts) do ch.turboBoosts[k] = copy(source) end
  for key, engine in pairs(audio.engines) do
    local e = { voice = engine.voice, speeds = {} }
    for i, source in ipairs(engine.speeds) do e.speeds[i] = copy(source) end
    e.overrun, e.idle, e.limiter = copy(engine.overrun), copy(engine.idle), copy(engine.limiter)
    ch.engines[key] = e
  end
  return ch
end

-- A seat's channel, or the first's for anything else.
function audio.channel(who)
  return channels[who or 1] or audio
end

-- Only a mono source can be placed: the rest stay in the middle.
local function place(source, x)
  if source:getChannelCount() ~= 1 then return end
  source:setRelative(true)
  if x == 0 then
    source:setPosition(0, 0, 0)
  else
    source:setPosition(x, 0, -math.sqrt(1 - x * x))
  end
end

-- Two drivers at a screen, or one. Two make the second channel the first time,
-- and both go to their own side; one puts everything back where it was.
function audio.split(on)
  if not audio.ready then return end
  if on and not channels[2] then channels[2] = cloneChannel() end
  local count = on and 2 or 1
  for i = 1, #channels do
    local ch = channels[i]
    ch.gain = on and SPLIT_GAIN or 1
    local x = on and (i == 1 and -SPLIT_PAN or SPLIT_PAN) or 0
    eachChannelLoop(ch, function(source)
      place(source, x)
      if i > count then
        source:stop()
        source:setVolume(0)
      end
    end)
  end
  audio.seats = count
end

local function updateExhaust(ch, dt, engine, mix, model, load, spec)
  local rpm, limiting = model.rpm, model.limiting
  local voice = engine.voice
  local rpms = voice.rpms
  local power = (load - audio.engineLoad(0, true)) / (audio.engineLoad(1, false) - audio.engineLoad(0, true))
  local blend = audio.engineBlend(rpm, rpms)
  local resting = audio.idleShare(rpm, spec.idleRpm) * (1 - power)
  local pulling = 1 - resting
  for i, source in ipairs(engine.speeds) do
    source:setPitch(enginePitch(rpm, rpms[i]))
    fadeCh(ch, source, limiting and 0 or mix.exhaust * blend[i] * (0.3 + power * 0.7) * pulling, dt, limiting and 30 or 8)
  end
  engine.idle:setPitch(enginePitch(rpm, voice.idleAt))
  fadeCh(ch, engine.idle, mix.idle * resting, dt, 8)
  engine.overrun:setPitch(enginePitch(rpm, rpms[2]))
  fadeCh(ch, engine.overrun, mix.exhaust * (1 - power) * 1.1 * pulling, dt, 8)
  engine.limiter:setPitch(math.max(0.35, rpm / rpms[#rpms]))
  fadeCh(ch, engine.limiter, limiting and mix.limiter or 0, dt, 30)
end

-- Pressure builds with a lag and has to go somewhere when the throttle shuts. A
-- race engine's wastegate just opens, with none of a road car's blow-off.
local function updateTurbo(ch, dt, model, spec, revs)
  local turbo = TURBOS[spec.turbos]
  if not turbo then
    ch.spool = 0
    return
  end
  local onPower = model.throttle > 0.4 and model.shiftTimer == 0
  local spoolUp = spec.raceExhaust and RACE_SPOOL or turbo.spoolUp
  local vented
  ch.spool, vented = audio.spoolStep(ch.spool, onPower, revs, dt, spoolUp)
  if vented then
    if not spec.raceExhaust then
      audio.play("blowoff", audio.blowoffVolume(ch.spool) * turbo.ventLevel, audio.variedPitch() * turbo.ventPitch)
    end
    ch.spool = 0
  end
end

local function updateEngineLayers(ch, dt, model, spec, revs, load)
  updateTurbo(ch, dt, model, spec, revs)
  local boosting = model.boostState == "active"
  ch.boost = audio.boostStep(ch.boost, boosting, model.boostTank / spec.boostTime, dt)
  -- The bottle shutting off dumps the pressure, like lifting off does.
  local turbo = TURBOS[spec.turbos]
  if turbo and ch.boosting and not boosting and not spec.raceExhaust and ch.spool >= BLOWOFF_SPOOL then
    audio.play("blowoff", audio.blowoffVolume(1) * turbo.ventLevel, audio.variedPitch() * turbo.ventPitch)
  end
  ch.boosting = boosting
  local mix = audio.engineMix(spec, revs, load, ch.spool, ch.boost)
  ch.duck = math.max(0, ch.duck - DUCK_RECOVERY * dt)
  mix.exhaust = mix.exhaust * (1 - ch.duck)
  if audio.boostKind(spec) == "turbo" then mix.exhaust = mix.exhaust * (1 - TURBO_BOOST_DUCK * ch.boost) end
  local voice = audio.voiceOf(spec)
  if voice then updateExhaust(ch, dt, ch.engines[voice.key], mix, model, load, spec) end
  local whistle = ch.turbos[spec.turbos]
  local lift = audio.boostPitch(spec, ch.boost)
  if whistle then
    -- Boost is full pressure, whatever the turbo has built by itself.
    whistle:setPitch(audio.turboPitch(math.max(ch.spool, ch.boost)) * lift)
    fadeCh(ch, whistle, mix.turbo, dt, 10)
  end
  local tank = model.boostTank / spec.boostTime
  for turbos, source in pairs(ch.turboBoosts) do
    source:setPitch(audio.boostGasPitch(tank))
    fadeCh(ch, source, turbos == spec.turbos and mix.turboBoost or 0, dt, 10)
  end
  ch.blower:setPitch(audio.blowerPitch(revs) * lift)
  fadeCh(ch, ch.blower, mix.blower, dt, 6)
  ch.motor:setPitch(audio.motorPitch(revs) * lift)
  fadeCh(ch, ch.motor, mix.motor, dt, 6)
end

local function updateRival(dt, rival, rivalDistance)
  local near = rival and math.max(0, 1 - rivalDistance / 500) or 0
  local voice = rival and audio.voiceOf(rival.spec)
  local motorLevel = 0
  if rival and not voice then
    motorLevel = near * 0.22
    audio.rivalMotor:setPitch(audio.motorPitch(math.min(1.1, rival.model.rpm / rival.spec.redline)))
  end
  fadeTo(audio.rivalMotor, motorLevel, dt, 3)
  local rivalHorn = false
  if rival then
    audio.rivalHorn:setPitch(audio.hornPitch(rival.spec) * (rival.hornRatio or 1))
    rivalHorn = rival.hornSounding
    if rivalHorn == nil then rivalHorn = rival.horn end
  end
  fadeTo(audio.rivalHorn, rivalHorn and near * HORN_LEVEL or 0, dt, HORN_FADE)
  for key, engine in pairs(audio.engines) do
    local level = 0
    if voice and voice.key == key then
      level = near * 0.14
      engine.rival:setPitch(enginePitch(rival.model.rpm, voice.rpms[2]))
    end
    fadeTo(engine.rival, level, dt, 3)
  end
end

-- who is the driver's seat: 1, or 2 with two at a screen. Only the first hears a rival.
function audio.update(dt, car, rival, rivalDistance, who)
  if not audio.ready or not car then return end
  local ch = channels[who or 1]
  if not ch then return end
  local model = car.model
  local spec = car.spec
  local revs = math.max(0, math.min(1.1, model.rpm / spec.redline))
  local load = audio.engineLoad(model.throttle, model.shiftTimer > 0)
  updateEngineLayers(ch, dt, model, spec, revs, load)

  local speed = car:getSpeed()
  local slide, offRoad = 0, 0
  for _, w in ipairs(model.wheels) do
    slide = math.max(slide, w.surface == "asphalt" and math.max(w.slide, math.max(0, w.spin) / 14) or 0)
    if w.surface == "grass" or w.surface == "gravel" then offRoad = offRoad + 0.25 end
    if w.surface == "kerb" then offRoad = offRoad + 0.1 end
  end

  local braking = model.brake > 0.05
  ch.scrub:setPitch(0.9 + math.min(0.2, speed / 200))
  fadeCh(ch, ch.scrub, audio.scrubLevel(slide, braking), dt, 4)
  ch.squeal:setPitch(0.96 + math.min(0.1, speed / 500) + slide * 0.04)
  fadeCh(ch, ch.squeal, audio.squealLevel(slide, braking), dt, 4)
  ch.grind:setPitch(0.75 + math.min(0.55, speed / 90))
  local grinding = audio.grindLevel(car.scraping or 0, speed)
  fadeCh(ch, ch.grind, grinding, dt, grinding * ch.gain > ch.grind:getVolume() and GRIND_IN or GRIND_OUT)
  ch.road:setPitch(0.7 + math.min(0.7, speed / 100))
  fadeCh(ch, ch.road, math.min(0.3, speed / 230), dt, 3)
  ch.loose:setPitch(0.75 + math.min(0.35, speed / 70))
  local looseLevel = audio.looseLevel(offRoad, speed)
  fadeCh(ch, ch.loose, looseLevel, dt, looseLevel * ch.gain > ch.loose:getVolume() and LOOSE_IN or LOOSE_OUT)
  ch.wind:setPitch(0.85 + math.min(0.35, speed / 200) + model.slipstream * 0.1)
  fadeCh(ch, ch.wind, math.max(0, (speed - 18) / 110) * 0.55 + model.slipstream * 0.25, dt, 2)
  local boosting = model.boostState == "active"
  local tank = model.boostTank / spec.boostTime
  ch.boostGas:setPitch(audio.boostGasPitch(tank))
  local gas = boosting and audio.boostKind(spec) == "gas" and audio.boostGasLevel(tank) or 0
  fadeCh(ch, ch.boostGas, gas, dt, gas > 0 and BOOST_GAS_IN or BOOST_GAS_OUT)
  ch.horn:setPitch(audio.hornPitch(spec) * (car.hornRatio or 1))
  local hornOn = car.hornSounding
  if hornOn == nil then hornOn = car.horn end
  fadeCh(ch, ch.horn, hornOn and HORN_LEVEL or 0, dt, HORN_FADE)
  local fire = car.fx and car.fx.flameTime or 0
  local flame = FLAME_LEVEL * math.min(1, fire / FLAME_FADE)
  ch.flame:setPitch(0.9 + 0.2 * math.min(1, fire / FLAME_FADE))
  fadeCh(ch, ch.flame, flame, dt, flame * ch.gain > ch.flame:getVolume() and FLAME_IN or FLAME_OUT)

  if ch == audio then updateRival(dt, rival, rivalDistance) end
end

local function eachLoop(fn)
  fn(audio.rivalMotor)
  fn(audio.rivalHorn)
  for _, engine in pairs(audio.engines) do fn(engine.rival) end
  for _, ch in ipairs(channels) do eachChannelLoop(ch, fn) end
end

function audio.silence()
  if not audio.ready then return end
  eachLoop(function(source)
    source:stop()
    source:setVolume(0)
  end)
  for _, ch in ipairs(channels) do
    ch.spool, ch.duck, ch.boost, ch.boosting = 0, 0, 0, false
  end
end

-- The race noise dies away behind the results rather than cutting out.
function audio.fadeOut(dt)
  if not audio.ready then return end
  eachLoop(function(source)
    if source:isPlaying() then
      fadeTo(source, 0, dt, FADE_OUT)
      if source:getVolume() <= 0.001 then source:stop() end
    end
  end)
end

return audio
