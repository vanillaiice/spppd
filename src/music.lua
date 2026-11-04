-- The menu's music: a little tracker that renders a song from the notes below.
-- Like every other sound it's synthesised, never shipped as a file. It renders a
-- slice at a time while the menu is up, so the first launch doesn't wait for it,
-- and keeps the result in the save folder, so later launches don't render at all.
--
-- A song is 16 bars as four sections of four, one chord to a bar. Each bar of a
-- part is 16 sixteenths, written as tokens:
--   lead   a note ("A4", "C#5", "Bb4"), "-" holds the one before, "." is a rest
--   bass   R the chord's root, O an octave up, F its fifth, "-" and "." as above
--   arp    1 2 3 are the chord's notes, 4 and 5 the first two an octave up
--   drums  one string per drum, "x" hits
-- The last bar's tails wrap round into the first, so the loop has no seam.
local cache = require("src/sound_cache")

local music = {}

local RATE = 22050         -- nothing up top worth the cost: see SOUND.md
local STEPS = 16           -- sixteenths to a bar
local PEAK = 0.89          -- -1 dBFS
local TARGET_RMS = 0.11    -- every take renders to this, so they play as loud
local LEVEL = 0.8          -- the source's volume, before VOLUME: about -21 LUFS as played
local FADE_IN, FADE_OUT = 1.2, 0.35  -- seconds
local SLICE = 0.004        -- seconds of rendering a frame may spend
local ROOT = "musiccache"
local TAU = math.pi * 2

music.RATE = RATE

-- Voices -------------------------------------------------------------------------
-- attack, decay and release in seconds; sustain is the share the decay falls to.
-- cutoff is a one-pole low-pass: nothing here is meant to be bright.
local VOICES = {
  lead = { wave = "pulse", duty = 0.25, attack = 0.004, decay = 0.25, sustain = 0.55, release = 0.06,
    cutoff = 2600, vibrato = 0.004, vibratoHz = 5.5, vibratoAfter = 0.18, gain = 0.34 },
  bass = { wave = "saw", attack = 0.003, decay = 0.14, sustain = 0.45, release = 0.03,
    cutoff = 900, gain = 0.34 },
  arp = { wave = "pulse", duty = 0.5, attack = 0.002, decay = 0.07, sustain = 0, release = 0.02,
    cutoff = 2200, gain = 0.12 },
  pad = { wave = "saw", detune = 1.007, attack = 0.3, decay = 1, sustain = 1, release = 0.35,
    cutoff = 1100, gain = 0.07 },
}

-- The takes ----------------------------------------------------------------------
-- Three, picked in SETTINGS > SONG. A is the default.

local A = {
  name = "PIT LANE", bpm = 132, swing = 0,
  drums = {
    kick = "x...x...x...x...", snare = "....x.......x...", hat = "..x...x...x...x.",
    fill = "....x.......x.xx",
  },
}
do
  local hook = {
    "A4 . C5 . E5 . A5 - - - G5 - E5 - . .",
    "F5 - - - E5 - C5 - A4 - - - C5 - D5 -",
    "E5 . G5 . C6 - - - B5 - G5 - E5 - . .",
  }
  local mainBass = "R . O . R . O . R . O . R . O ."
  A.sections = {
    { chords = "Am F C G", bass = mainBass,
      lead = { hook[1], hook[2], hook[3], "D5 - - - - - B4 - G4 - B4 - D5 - . ." } },
    { chords = "Am F C G", bass = mainBass, fill = true,
      lead = { hook[1], hook[2], "E5 . G5 . C6 - - - D6 - C6 - B5 - G5 -", "D6 - - - - - B5 - G5 - - - A5 - B5 -" } },
    { chords = "Dm G C E", bass = "R . R O . R . O R . R O . R O .", arp = "1 2 3 4 1 2 3 4 1 2 3 4 1 2 3 4",
      lead = {
        "A5 - - F5 - - D5 - F5 - A5 - D6 - - -",
        "B5 - - G5 - - D5 - G5 - B5 - D6 - - -",
        "C6 - - G5 - - E5 - G5 - C6 - E6 - - -",
        "B5 - - - G#5 - - - E5 - G#5 - B5 - D6 -",
      } },
    { chords = "Am F C G", bass = mainBass, fill = true, arp = "1 . 3 . 4 . 3 . 1 . 3 . 4 . 3 .",
      lead = { hook[1], hook[2], hook[3], "B4 - - - D5 - - - G5 - - - E5 - D5 -" } },
  }
end

local B = {
  name = "NIGHT DRIVE", bpm = 112, swing = 0, pad = true,
  drums = {
    kick = "x.......x.......", snare = "....x.......x...", hat = "x.x.x.x.x.x.x.x.",
    fill = "....x.......x.xx",
  },
}
do
  local hook = {
    "D5 - - - - - - - F5 - - - E5 - D5 -",
    "F5 - - - - - - - . . D5 - F5 - G5 -",
    "A5 - - - - - G5 - F5 - - - D5 - - -",
  }
  local bass = "R . R . R . O . R . R . R . O ."
  local arp = "1 3 4 5 1 3 4 5 1 3 4 5 1 3 4 5"
  B.sections = {
    { chords = "Dm Bb Gm A", bass = bass, arp = arp,
      lead = { hook[1], hook[2], hook[3], "E5 - - - - - - - C#5 - - - E5 - - -" } },
    { chords = "Dm Bb Gm A", bass = bass, arp = arp, fill = true,
      lead = { hook[1], hook[2], "A5 - - - - - Bb5 - A5 - - - G5 - F5 -", "E5 - - - - - - - - - - - . . . ." } },
    { chords = "Gm Bb C A", bass = bass, arp = arp,
      lead = {
        "G5 - - Bb5 - - D6 - - - C6 - Bb5 - A5 -",
        "F5 - - - - - D5 - F5 - - - Bb5 - - -",
        "C6 - - - - - G5 - E5 - - - G5 - - -",
        "A5 - - - - - - - C#6 - - - E6 - - -",
      } },
    { chords = "Dm Bb Gm A", bass = bass, arp = arp, fill = true,
      lead = { hook[1], hook[2], hook[3], "E5 - - - - - - - - - - - . . . ." } },
  }
end

local C = {
  name = "SUNDAY CUP", bpm = 140, swing = 0.3,
  drums = {
    kick = "x..x....x.x.....", snare = "....x.......x...", hat = "x.xxx.xxx.xxx.xx",
    fill = "....x.......xxxx",
  },
}
do
  local hook = {
    "E5 . G5 . C6 . G5 . E5 . G5 . A5 - G5 .",
    "E5 . C5 . A4 . C5 . E5 - - . D5 . C5 .",
    "A4 . C5 . F5 . A5 . G5 . F5 . E5 - F5 .",
  }
  local bass = "R . F . O . F . R . F . O . F ."
  C.sections = {
    { chords = "C Am F G", bass = bass,
      lead = { hook[1], hook[2], hook[3], "G5 - - . D5 . B4 . D5 . F5 . E5 - D5 ." } },
    { chords = "C Am F G", bass = bass, fill = true,
      lead = { hook[1], hook[2], hook[3], "G5 . A5 . B5 . D6 - - . B5 . G5 - - ." } },
    { chords = "F G Em Am", bass = bass, arp = "1 . 2 . 3 . 4 . 3 . 2 . 1 . 2 .",
      lead = {
        "C6 - A5 . F5 . A5 . C6 . D6 . C6 - A5 .",
        "B5 - G5 . D5 . G5 . B5 . D6 . B5 - G5 .",
        "G5 - E5 . B4 . E5 . G5 . B5 . A5 - G5 .",
        "A5 . . . E5 . . . A5 . B5 . C6 - - .",
      } },
    { chords = "C Am F G", bass = bass, fill = true,
      lead = { hook[1], hook[2], hook[3], "G5 - - . D5 . B4 . D5 . F5 . E5 - D5 ." } },
  }
end

music.TAKES = { a = A, b = B, c = C }
music.ORDER = { "a", "b", "c" }

-- Notes --------------------------------------------------------------------------

local SEMITONES = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

-- "A4" -> 69, the MIDI number.
function music.midi(name)
  local letter, accidental, octave = name:match("^([A-G])([#b]?)(%-?%d)$")
  assert(letter, "not a note: " .. tostring(name))
  local n = SEMITONES[letter] + (accidental == "#" and 1 or accidental == "b" and -1 or 0)
  return 12 * (tonumber(octave) + 1) + n
end

function music.hz(midi)
  return 440 * 2 ^ ((midi - 69) / 12)
end

-- "F#m" -> the root's MIDI number in octave 0 (0 to 11) and the chord's intervals.
function music.chord(name)
  local root, accidental, minor = name:match("^([A-G])([#b]?)(m?)$")
  assert(root, "not a chord: " .. tostring(name))
  local n = (SEMITONES[root] + (accidental == "#" and 1 or accidental == "b" and -1 or 0)) % 12
  return n, minor == "m" and { 0, 3, 7 } or { 0, 4, 7 }
end

local function tokens(line)
  local list = {}
  for token in line:gmatch("%S+") do list[#list + 1] = token end
  assert(#list == STEPS, "a bar is 16 steps, not " .. #list .. ": " .. line)
  return list
end

-- The step a song's sixteenth lands on, in samples, with swing pushing the off ones late.
local function stepLength(song)
  return math.floor(RATE * 60 / song.bpm / 4)
end

function music.length(song)
  return stepLength(song) * STEPS * 4 * #song.sections
end

-- Every note in the song, as { at, length, midi, voice }, in samples.
function music.events(song)
  local step = stepLength(song)
  local events = {}
  local function at(bar, s)
    local swing = (s % 2 == 1) and math.floor(song.swing * step) or 0
    return (bar * STEPS + s) * step + swing
  end
  local function addLine(voice, bar, list, pitchOf)
    local s = 0
    while s < STEPS do
      local token = list[s + 1]
      local midi = token ~= "." and token ~= "-" and pitchOf(token)
      if midi then
        local held = 1
        while s + held < STEPS and list[s + held + 1] == "-" do held = held + 1 end
        local start = at(bar, s)
        local length = math.floor(held * step * (held > 1 and 0.95 or 0.8))
        events[#events + 1] = { at = start, length = length, midi = midi, voice = voice }
        s = s + held
      else
        s = s + 1
      end
    end
  end
  local drumEvents = {}
  for section, part in ipairs(song.sections) do
    local chords = {}
    for name in part.chords:gmatch("%S+") do chords[#chords + 1] = name end
    assert(#chords == 4, "a section is four chords")
    for b = 1, 4 do
      local bar = (section - 1) * 4 + (b - 1)
      local root, intervals = music.chord(chords[b])
      -- The bass sits between E1 and D#2, the chord tones from root to an octave up.
      local bassRoot = 28 + (root - 4) % 12
      local chordRoot = 60 + root
      addLine("lead", bar, tokens(part.lead[b]), music.midi)
      addLine("bass", bar, tokens(part.bass), function(t)
        if t == "R" then return bassRoot end
        if t == "O" then return bassRoot + 12 end
        if t == "F" then return bassRoot + 7 end
        error("not a bass note: " .. t)
      end)
      if part.arp then
        addLine("arp", bar, tokens(part.arp), function(t)
          local i = assert(tonumber(t), "not an arp note: " .. t)
          return chordRoot + intervals[(i - 1) % 3 + 1] + (i > 3 and 12 or 0)
        end)
      end
      if song.pad then
        for _, interval in ipairs(intervals) do
          events[#events + 1] = { at = at(bar, 0), length = STEPS * step, midi = chordRoot - 12 + interval, voice = "pad" }
        end
      end
      local drums = song.drums
      local snare = (part.fill and b == 4) and drums.fill or drums.snare
      for s = 0, STEPS - 1 do
        local function hit(pattern, kind)
          if pattern:sub(s + 1, s + 1) == "x" then drumEvents[#drumEvents + 1] = { at = at(bar, s), voice = kind } end
        end
        hit(drums.kick, "kick")
        hit(snare, "snare")
        hit(drums.hat, "hat")
      end
    end
  end
  for _, e in ipairs(drumEvents) do events[#events + 1] = e end
  return events
end

-- Rendering ----------------------------------------------------------------------

-- A slice runs out when its time is up. Outside a coroutine nothing waits.
local deadline
local function breathe()
  if deadline and coroutine.running() and love.timer.getTime() > deadline then coroutine.yield() end
end

-- Band-limited steps, so a 22 kHz pulse doesn't fold its harmonics back down.
local function blep(t, dt)
  if t < dt then
    t = t / dt
    return t + t - t * t - 1
  elseif t > 1 - dt then
    t = (t - 1) / dt
    return t * t + t + t + 1
  end
  return 0
end

local function onePole(hz)
  return 1 - math.exp(-TAU * hz / RATE)
end

local function addNote(buffer, n, e, voice)
  local hz = music.hz(e.midi)
  local attack = math.max(1, math.floor(voice.attack * RATE))
  local release = math.max(1, math.floor(voice.release * RATE))
  local fall = math.exp(-1 / (voice.decay * RATE))
  local sustain = voice.sustain
  local total = e.length + release
  local a = onePole(voice.cutoff)
  local duty = voice.duty or 0.5
  local isPulse = voice.wave == "pulse"
  local detune = voice.detune
  local vibrato, vibratoHz = voice.vibrato or 0, voice.vibratoHz or 0
  local vibratoAfter = math.floor((voice.vibratoAfter or 0) * RATE)
  local gain = voice.gain
  local phase, phase2, low, decay = 0, 0.37, 0, 1
  local start = e.at
  for i = 0, total - 1 do
    local env
    if i < attack then
      env = i / attack
    else
      decay = decay * fall
      env = sustain + (1 - sustain) * decay
    end
    if i >= e.length then env = env * (1 - (i - e.length) / release) end
    local dt = hz / RATE
    if vibrato > 0 and i > vibratoAfter then
      dt = dt * (1 + vibrato * math.sin(TAU * vibratoHz * (i - vibratoAfter) / RATE))
    end
    phase = phase + dt
    if phase >= 1 then phase = phase - 1 end
    local v
    if isPulse then
      v = (phase < duty and 1 or -1) + blep(phase, dt) - blep((phase - duty) % 1, dt) - (2 * duty - 1)
    else
      v = 2 * phase - 1 - blep(phase, dt)
    end
    if detune then
      local dt2 = dt * detune
      phase2 = phase2 + dt2
      if phase2 >= 1 then phase2 = phase2 - 1 end
      v = (v + 2 * phase2 - 1 - blep(phase2, dt2)) * 0.5
    end
    low = low + a * (v - low)
    local index = (start + i) % n + 1
    buffer[index] = buffer[index] + low * env * gain
    if i % 2048 == 0 then breathe() end
  end
end

-- A drop from a knock a phone can play down to a thump it can't.
local function addKick(buffer, n, start)
  local length = math.floor(0.22 * RATE)
  local phase = 0
  for i = 0, length - 1 do
    local t = i / RATE
    local hz = 48 + 120 * math.exp(-t / 0.03)
    phase = phase + hz / RATE
    local v = math.sin(TAU * phase) * math.exp(-t / 0.09)
    local index = (start + i) % n + 1
    buffer[index] = buffer[index] + v * 0.55
  end
end

local function addNoise(buffer, n, start, rng, seconds, decay, lowHz, highHz, gain, toneHz)
  local length = math.floor(seconds * RATE)
  local aLow, aHigh = onePole(highHz), onePole(lowHz)
  local top, bottom = 0, 0
  for i = 0, length - 1 do
    local t = i / RATE
    local x = rng:random() * 2 - 1
    top = top + aLow * (x - top)
    bottom = bottom + aHigh * (top - bottom)
    local v = (top - bottom) * math.exp(-t / decay)
    if toneHz then v = v + math.sin(TAU * toneHz * t) * math.exp(-t / 0.04) * 0.5 end
    local fade = math.min(1, (length - i) / (0.01 * RATE))
    local index = (start + i) % n + 1
    buffer[index] = buffer[index] + v * gain * fade
  end
end

-- The song as a looping SoundData. Run inside a coroutine it yields now and then.
function music.render(id)
  local song = assert(music.TAKES[id], "no such take: " .. tostring(id))
  local n = music.length(song)
  local buffer = {}
  for i = 1, n do buffer[i] = 0 end
  breathe()
  local rng = love.math.newRandomGenerator(1987)
  for _, e in ipairs(music.events(song)) do
    local voice = VOICES[e.voice]
    if voice then
      addNote(buffer, n, e, voice)
    elseif e.voice == "kick" then
      addKick(buffer, n, e.at)
    elseif e.voice == "snare" then
      addNoise(buffer, n, e.at, rng, 0.18, 0.06, 900, 5000, 0.9, 190)
    elseif e.voice == "hat" then
      addNoise(buffer, n, e.at, rng, 0.04, 0.012, 6000, 10000, 0.35)
    end
    breathe()
  end
  -- The same loudness for every take, then nothing past the peak.
  local sum, peak = 0, 0
  for i = 1, n do
    local v = buffer[i]
    sum = sum + v * v
    if v > peak then peak = v elseif -v > peak then peak = -v end
  end
  local rms = math.sqrt(sum / n)
  local gain = rms > 0 and TARGET_RMS / rms or 1
  if peak * gain > PEAK then gain = PEAK / peak end
  local data = love.sound.newSoundData(n, RATE, 16, 1)
  for i = 0, n - 1 do
    data:setSample(i, buffer[i + 1] * gain)
    if i % 8192 == 0 then breathe() end
  end
  return data
end

-- Cache --------------------------------------------------------------------------

local folder  -- false once the cache has been found unusable

local function cacheFolder()
  if folder ~= nil then return folder end
  folder = false
  pcall(function()
    local key = cache.key({ assert(love.filesystem.read("src/music.lua")) })
    local path = ROOT .. "/" .. key
    if not love.filesystem.getInfo(path, "directory") then
      cache.clear(ROOT)
      assert(love.filesystem.createDirectory(path))
    end
    folder = path
  end)
  return folder
end

-- The take from the cache if it's there and whole, otherwise rendered and saved.
function music.data(id)
  local dir = cacheFolder()
  local path = dir and dir .. "/" .. id .. ".wav"
  if path and love.filesystem.getInfo(path) then
    local ok, data = pcall(love.sound.newSoundData, path)
    if ok and data:getSampleCount() == music.length(music.TAKES[id]) then return data end
  end
  local data = music.render(id)
  if path then pcall(love.filesystem.write, path, cache.wav(data)) end
  return data
end

-- Playing ------------------------------------------------------------------------

local take = "a"
local datas = {}   -- rendered takes, by id, so switching back is instant
local job          -- the coroutine rendering the take that's wanted
local source
local level = 0
local broken = false

function music.take()
  return take
end

function music.setTake(id)
  if not music.TAKES[id] or id == take then return end
  take = id
  if source then
    source:stop()
    source:release()
    source = nil
  end
  job = nil
end

function music.isPlaying()
  return source ~= nil and source:isPlaying()
end

function music.level()
  return level
end

-- Runs a rendering coroutine for up to seconds. Returns what coroutine.resume does.
function music.step(job, seconds)
  deadline = love.timer.getTime() + seconds
  local results = { coroutine.resume(job) }
  deadline = nil
  return unpack(results)
end

-- play: the menu is up and music is on. prepare: worth rendering towards it now.
function music.update(dt, play, prepare)
  if broken or not love.audio then return end
  if not source and (play or prepare) then
    if datas[take] then
      source = love.audio.newSource(datas[take], "static")
      source:setLooping(true)
      source:setVolume(0)
      level = 0
    else
      local id = take
      job = job or coroutine.create(function() return music.data(id) end)
      local ok, result = music.step(job, SLICE)
      if not ok then
        print("music disabled: " .. tostring(result))
        broken, job = true, nil
        return
      end
      if coroutine.status(job) == "dead" then
        datas[id], job = result, nil
      end
    end
  end
  if not source then return end
  local target = play and LEVEL or 0
  if level < target then
    level = math.min(target, level + dt * LEVEL / FADE_IN)
  elseif level > target then
    level = math.max(target, level - dt * LEVEL / FADE_OUT)
  end
  source:setVolume(level)
  if level > 0 and not source:isPlaying() then
    source:play()
  elseif level <= 0 and source:isPlaying() then
    source:pause()
  end
end

return music
