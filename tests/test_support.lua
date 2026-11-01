local h = require("tests/harness")
local settings = require("src/settings")
local input = require("src/input")
local catalog = require("src/tracks/catalog")
local Track = require("src/sim/track")
local audio = require("src/audio")
local radio = require("src/radio")

h.describe("environment", function()
  h.it("every theme gives the shaders what they need", function()
    local environment = require("src/render/environment")
    for name, theme in pairs(environment.THEMES) do
      for _, field in ipairs({ "groundA", "groundB", "road", "gravel", "dust", "barrierA", "barrierB" }) do
        h.assertTrue(type(theme[field]) == "table", name .. " is missing " .. field)
      end
      h.assertBetween(theme.pattern, 0, 2, name .. " pattern")
    end
    for name, time in pairs(environment.TIMES) do
      h.assertTrue(time.saturation > 0, name .. " saturation")
    end
  end)
end)

h.describe("settings", function()
  h.it("round-trips through a file", function()
    settings.laps = 7
    settings.assists = "sim"
    settings.save()
    settings.laps = 1
    settings.assists = "full"
    settings.load()
    h.assertEq(settings.laps, 7)
    h.assertEq(settings.assists, "sim")
    settings.laps = 3
    settings.assists = "sport"
    settings.save()
  end)

  h.it("moves a saved FULL handling tier to ARCADE", function()
    settings.assists = "full"
    settings.save()
    settings.assists = "sim"
    settings.load()
    h.assertEq(settings.assists, "arcade")
    settings.assists = "sport"
    settings.save()
  end)

  h.it("survives a corrupted settings file", function()
    love.filesystem.write("settings.lua", "this is not lua (")
    settings.load()
    h.assertTrue(settings.laps ~= nil, "defaults kept")
    love.filesystem.write("settings.lua", "return { laps = 'lots', volume = 0.5 }")
    settings.load()
    h.assertEq(type(settings.laps), "number", "wrong types ignored")
    love.filesystem.remove("settings.lua")
  end)

  h.it("can't be used to run code", function()
    love.filesystem.write("settings.lua", "os.exit(3) return {}")
    settings.load()
    love.filesystem.remove("settings.lua")
  end)

  h.it("keeps the fastest lap and its ghost", function()
    love.filesystem.remove("records.lua")
    settings.load()
    h.assertEq(settings.bestLap("t", "c"), nil)
    h.assertTrue(settings.submitLap("t", "c", 62.5, { { 1, 2, 3 } }), "first lap is a record")
    h.assertTrue(not settings.submitLap("t", "c", 70, {}), "a slower lap is not")
    h.assertTrue(settings.submitLap("t", "c", 60, { { 4, 5, 6 } }), "a faster lap is")
    settings.load()
    h.assertEq(settings.bestLap("t", "c"), 60)
    h.assertEq(settings.ghost("t", "c")[1][1], 4)
    love.filesystem.remove("records.lua")
  end)
end)

h.describe("input", function()
  h.it("tracks held keys across both bindings", function()
    input.clear()
    input.press("w")
    input.press("up")
    input.release("w")
    h.assertTrue(input.isDown("throttle"), "still held by the other key")
    input.release("up")
    h.assertTrue(not input.isDown("throttle"), "released")
  end)

  h.it("reports a press exactly once", function()
    input.clear()
    input.press("r")
    h.assertTrue(input.consume("respawn"))
    h.assertTrue(not input.consume("respawn"))
  end)

  h.it("the nitro input follows the key, so the car can see each press", function()
    input.clear()
    local t = {}
    input.press("space")
    input.applyTo(t)
    h.assertTrue(t.boost)
    input.release("space")
    input.applyTo(t)
    h.assertTrue(not t.boost)
  end)

  h.it("a tap shorter than one frame still fires nitro", function()
    input.clear()
    local t = {}
    input.press("space")
    input.release("space")
    input.applyTo(t)
    h.assertTrue(t.boost, "tap fires")
    input.applyTo(t)
    h.assertTrue(not t.boost, "and only once")
  end)

  h.it("uses the pad layout", function()
    input.clear()
    local t = {}
    for _, button in ipairs({ "x", "a", "rightshoulder", "leftshoulder" }) do input.gamepadPress(nil, button) end
    input.applyTo(t)
    h.assertTrue(t.shiftUp, "square changes up")
    h.assertTrue(t.shiftDown, "cross changes down")
    h.assertTrue(t.handbrake, "R1 is the handbrake")
    h.assertTrue(t.boost, "L1 is the nitro")
    input.clear()
  end)

  h.it("the triggers give partial gas and braking", function()
    input.clear()
    input.gamepad = {
      isConnected = function() return true end,
      getGamepadAxis = function(_, axis)
        return axis == "triggerright" and 0.4 or axis == "triggerleft" and 0.25 or 0
      end,
    }
    local t = {}
    input.applyTo(t)
    h.assertEq(t.throttle, 0.4, "R2")
    h.assertEq(t.brake, 0.25, "L2")
    input.gamepad = nil
    input.clear()
  end)

  h.it("opposite steering keys cancel out", function()
    input.clear()
    local t = {}
    input.press("a")
    input.press("d")
    input.applyTo(t)
    h.assertEq(t.steer, 0)
    input.clear()
  end)
end)

h.describe("catalog", function()
  h.it("saves and reloads an editor track", function()
    local nodes = {}
    for i = 0, 11 do
      local a = i / 12 * math.pi * 2
      nodes[#nodes + 1] = { x = math.cos(a) * 500, y = math.sin(a) * 300, wl = 30, wr = 30 }
    end
    h.assertTrue(catalog.save("test_loop", { nodes = nodes, title = "TEST LOOP",
      startPoint = { x = 500, y = 0, angle = 1.57 } }))
    local entry = catalog.find("test_loop")
    h.assertTrue(entry ~= nil, "found")
    h.assertEq(#entry.def.nodes, 12)
    h.assertEq(entry.title, "TEST LOOP")
    local t = Track.new(entry.def)
    h.assertTrue(t.length > 0)
    catalog.remove("test_loop")
    h.assertEq(catalog.find("test_loop"), nil, "removed")
  end)
end)

h.describe("audio", function()
  h.it("engine loops are seamless and don't clip", function()
    local data = audio.engineData(55, 0.1)
    local n = data:getSampleCount()
    local peak = 0
    for i = 0, n - 1 do peak = math.max(peak, math.abs(data:getSample(i))) end
    h.assertBetween(peak, 0.2, 1.0, "peak level")
    local jump = math.abs(data:getSample(0) - data:getSample(n - 1))
    h.assertTrue(jump < 0.12, "click at the loop point: " .. jump)
  end)

  local function peakOf(data)
    local peak = 0
    for i = 0, data:getSampleCount() - 1 do peak = math.max(peak, math.abs(data:getSample(i))) end
    return peak
  end

  h.it("synthesises a tyre scrub that loops", function()
    local data = audio.scrubData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
    h.assertBetween(peakOf(data), 0.1, 0.95, "peak level, clipping sounds harsh")
  end)

  h.it("synthesises a nitro hiss that loops", function()
    local data = audio.nitroData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
    h.assertBetween(peakOf(data), 0.1, 0.95, "peak level")
  end)

  h.it("off-road noise is a soft rumble that loops", function()
    local data = audio.looseData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
    h.assertBetween(peakOf(data), 0.1, 0.95, "peak level")
    -- Sample-to-sample movement against level: white noise is about 1.4.
    local energy, change = 0, 0
    for i = 1, n - 1 do
      local v = data:getSample(i)
      energy = energy + v * v
      change = change + (v - data:getSample(i - 1)) ^ 2
    end
    h.assertTrue(math.sqrt(change / energy) < 0.55, "too bright, it will sound rough")
  end)

  h.it("off-road noise stays under the road and grows with speed", function()
    h.assertEq(audio.looseLevel(0, 40), 0, "silent on the road")
    h.assertEq(audio.looseLevel(1, 0), 0, "silent at a standstill")
    h.assertTrue(audio.looseLevel(1, 10) < audio.looseLevel(1, 25), "speed brings it up")
    h.assertBetween(audio.looseLevel(1, 80), 0.1, 0.26, "no louder than road noise")
  end)

  h.it("synthesises tones that loop without clipping", function()
    local data = audio.toneData(210, { [2] = 0.14, [4] = 0.06, [7] = 0.3, [10] = 0.09 })
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.3, "loop point")
    h.assertBetween(peakOf(data), 0.1, 0.95, "peak level")
  end)

  h.it("a turbo builds pressure with a lag and vents it once", function()
    local spool, vented = 0, false
    for _ = 1, 10 do spool, vented = audio.spoolStep(spool, true, 1, 1 / 60) end
    h.assertBetween(spool, 0.1, 0.5, "still spooling")
    h.assertTrue(not vented)
    for _ = 1, 60 do spool = audio.spoolStep(spool, true, 1, 1 / 60) end
    h.assertEq(spool, 1, "full pressure")
    spool, vented = audio.spoolStep(spool, false, 1, 1 / 60)
    h.assertTrue(vented, "lifting vents it")
  end)

  h.it("a turbo with no pressure stays quiet on a lift", function()
    local spool, vented = audio.spoolStep(0.2, false, 1, 1 / 60)
    h.assertTrue(not vented)
    h.assertTrue(spool < 0.2)
  end)

  h.it("no car has an unknown engine type", function()
    local garage = require("src/entities/garage")
    local types = { na = true, turbo = true, supercharged = true, electric = true }
    for _, spec in ipairs(garage) do
      if spec.engineType then
        h.assertTrue(types[spec.engineType], spec.name .. ": " .. tostring(spec.engineType))
      end
    end
  end)

  h.it("each engine type adds its own layer and no other", function()
    local layers = { na = "v8", supercharged = "blower", electric = "motor" }
    for kind, layer in pairs(layers) do
      local mix = audio.engineMix(kind, 0.8, 1, 0)
      for _, other in pairs(layers) do
        if other == layer then h.assertTrue(mix[other] > 0.05, kind .. " is silent")
        else h.assertEq(mix[other], 0, kind .. " also plays " .. other) end
      end
    end
    local plain = audio.engineMix(nil, 0.8, 1, 0)
    for _, layer in pairs(layers) do h.assertEq(plain[layer], 0, "no type, no " .. layer) end
    h.assertEq(plain.turbo, 0, "no pressure, no whistle")
    h.assertTrue(audio.engineMix("turbo", 0.8, 1, 1).turbo > 0.1, "full pressure whistles")
  end)

  h.it("only the turbo and supercharged cars use the piston loops", function()
    h.assertEq(audio.engineMix("electric", 0.8, 1, 0).pistons, 0)
    h.assertEq(audio.engineMix("na", 0.8, 1, 0).pistons, 0, "the V8 replaces them")
    for _, kind in ipairs({ "turbo", "supercharged" }) do
      h.assertEq(audio.engineMix(kind, 0.8, 1, 0).pistons, 1, kind)
    end
    h.assertEq(audio.engineMix(nil, 0.8, 1, 0).pistons, 1)
  end)

  h.it("every piston engine can hit the limiter, and a motor can't", function()
    for _, kind in ipairs({ "na", "turbo", "supercharged" }) do
      h.assertTrue(audio.engineMix(kind, 1, 1, 0).limiter > 0.3, kind)
    end
    h.assertEq(audio.engineMix("electric", 1, 1, 0).limiter, 0)
  end)

  h.it("a hard crash isn't quieter than the engine", function()
    h.assertTrue(peakOf(audio.shotData("impact")) > peakOf(audio.v8Data(5400)), "a crash is an event")
  end)

  h.it("no effect starts on a hard edge", function()
    for _, name in ipairs({ "beep", "go", "click", "select", "lap", "shift", "blowoff" }) do
      h.assertTrue(math.abs(audio.shotData(name):getSample(0)) < 0.1, name)
    end
  end)

  h.it("the V8 loops join cleanly and don't sit in hard saturation", function()
    for _, rpm in ipairs({ 1300, 3000, 5400 }) do
      local data = audio.v8Data(rpm)
      local n = data:getSampleCount()
      h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.1, rpm .. " loop point")
      local peak, sum, mean = peakOf(data), 0, 0
      for i = 0, n - 1 do
        local v = data:getSample(i)
        sum, mean = sum + v * v, mean + v
      end
      h.assertBetween(peak, 0.3, 0.95, rpm .. " peak")
      h.assertTrue(peak / math.sqrt(sum / n) > 1.25, rpm .. " would be a square wave")
      h.assertTrue(math.abs(mean / n) < 0.05, rpm .. " sits off centre")
    end
    h.assertTrue(peakOf(audio.v8Data(3000, "overrun")) < peakOf(audio.v8Data(3000)), "overrun is quieter")
  end)

  h.it("the V8 limiter cuts in and out, and loops", function()
    local data = audio.v8Data(5400, "limiter")
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.1, "loop point")
    h.assertBetween(peakOf(data), 0.3, 0.95, "peak level")
    local cuts, cutting = 0, false
    for t = 0.02, 0.5, 0.002 do
      local level = 0
      local a = math.floor(t * 44100)
      for i = a, a + 88 do level = math.max(level, math.abs(data:getSample(i))) end
      if level < 0.15 and not cutting then cuts = cuts + 1 end
      cutting = level < 0.15
    end
    h.assertBetween(cuts, 6, 16, "bursts in half a second")
  end)

  h.it("the V8 blends between its two nearest speeds", function()
    for rpm = 500, 8000, 250 do
      local blend = audio.v8Blend(rpm)
      local total = blend[1] + blend[2] + blend[3]
      h.assertTrue(math.abs(total - 1) < 1e-9, rpm .. " totals " .. total)
    end
    h.assertEq(audio.v8Blend(900)[1], 1, "idle")
    h.assertEq(audio.v8Blend(3000)[2], 1, "a rendered speed plays alone")
    h.assertEq(audio.v8Blend(7000)[3], 1, "past the top")
    local between = audio.v8Blend(4000)
    h.assertEq(between[1], 0, "the far loop stays out")
    h.assertTrue(between[2] > 0 and between[3] > 0, "both neighbours play")
  end)

  h.it("the electric motor is a rough whine, not clean tones", function()
    local data = audio.motorData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
    h.assertBetween(peakOf(data), 0.1, 0.95, "peak level")
    -- A clean tone repeats exactly from one period to the next.
    local lag, same, total = 210, 0, 0
    for i = 0, n - lag - 1 do
      local a, b = data:getSample(i), data:getSample(i + lag)
      same, total = same + a * b, total + a * a
    end
    h.assertTrue(same / total < 0.9, "repeats too exactly: " .. same / total)
    h.assertTrue(audio.motorPitch(1) / audio.motorPitch(0) < 3.5, "less of a swoop")
  end)

  for _, name in ipairs({ "beep", "go", "click", "select", "lap", "shift", "blowoff", "impact", "scrape" }) do
    h.it("the " .. name .. " sound is short and doesn't clip", function()
      local data = audio.shotData(name)
      h.assertBetween(data:getDuration(), 0.01, 1, "length")
      h.assertBetween(peakOf(data), 0.05, 0.95, "peak level")
    end)
  end

  -- Level over a window of seconds, and how often the wave crosses zero there.
  local function windowOf(data, from, to)
    local sum, crossings, last = 0, 0, 0
    local a, b = math.floor(from * 44100), math.floor(to * 44100)
    for i = a, b - 1 do
      local v = data:getSample(i)
      sum = sum + v * v
      if v * last < 0 then crossings = crossings + 1 end
      last = v
    end
    return math.sqrt(sum / (b - a)), crossings / (to - from) / 2
  end

  h.it("nitro hisses above the engine, and sags as it runs out", function()
    local level, pitch = windowOf(audio.nitroData(), 0.3, 1)
    h.assertTrue(pitch > 3000, "a hiss, not a rumble: " .. pitch)
    h.assertTrue(level > 0.08, "loud enough to hear: " .. level)
    h.assertTrue(audio.nitroPitch(0) < audio.nitroPitch(1))
  end)

  h.it("a gear change sputters on, it isn't one clank", function()
    local data = audio.shotData("shift")
    h.assertBetween(data:getDuration(), 0.1, 0.25, "about as long as the shift")
    local early, pitch = windowOf(data, 0.012, 0.05)
    local late = windowOf(data, 0.06, 0.1)
    h.assertTrue(late > early * 0.5, "still going: " .. early .. " then " .. late)
    h.assertTrue(pitch > 200, "a phone speaker can play it: " .. pitch)
    h.assertTrue(windowOf(data, 0, 0.002) < early * 0.5, "no hard edge at the start")
  end)

  h.it("the blow-off flutters and falls in pitch", function()
    local data = audio.shotData("blowoff")
    h.assertTrue(data:getDuration() > 0.4, "it takes time for the pressure to go")
    local dips, last, falling = 0, 0, false
    for t = 0.02, 0.3, 0.005 do
      local level = windowOf(data, t, t + 0.008)
      if level < last * 0.9 and not falling then dips = dips + 1 end
      falling = level < last
      last = level
    end
    h.assertTrue(dips >= 4, "flutters: " .. dips)
    local _, early = windowOf(data, 0.02, 0.1)
    local _, late = windowOf(data, 0.3, 0.45)
    h.assertTrue(early < 3500, "a breath, not a hiss: " .. early)
    h.assertTrue(late < early * 0.8, "falls: " .. early .. " to " .. late)
  end)

  h.it("more turbo pressure blows off louder", function()
    h.assertTrue(audio.blowoffVolume(1) > audio.blowoffVolume(0.55))
    h.assertBetween(audio.blowoffVolume(1), 0.3, 1, "stays in range")
  end)

  h.it("the engine note drops out during a gear change", function()
    h.assertTrue(audio.engineLoad(1, true) < audio.engineLoad(1, false) * 0.6)
    h.assertEq(audio.engineLoad(0, true), audio.engineLoad(0, false), "nothing to cut off throttle")
  end)

  h.it("the startup sound builds to a flare, vents, and ends quietly", function()
    local data = audio.startupData()
    h.assertEq(data:getDuration() >= audio.STARTUP_LENGTH - 0.01, true, "fills the splash")
    h.assertBetween(peakOf(data), 0.3, 0.95, "peak level")
    local function level(from, to)
      local sum, a, b = 0, math.floor(from * 44100), math.floor(to * 44100)
      for i = a, b - 1 do sum = sum + data:getSample(i) ^ 2 end
      return math.sqrt(sum / (b - a))
    end
    local peak = audio.STARTUP_PEAK
    h.assertTrue(level(0.08, 0.1) > 0.05, "the start button is heard")
    h.assertTrue(level(0.27, 0.34) < 0.01, "nothing else before the engine fires")
    local mean = 0
    local from, to = math.floor((peak - 0.3) * 44100), math.floor(peak * 44100)
    for i = from, to - 1 do mean = mean + data:getSample(i) end
    h.assertTrue(math.abs(mean / (to - from)) < 0.05, "the flare swings, it isn't stuck to one side")
    h.assertTrue(level(peak + 0.1, peak + 0.3) < level(peak - 0.2, peak), "the revs drop away")
    h.assertTrue(level(peak, peak + 0.2) > 0.05, "the vent is heard")
    h.assertTrue(level(audio.STARTUP_LENGTH - 0.03, audio.STARTUP_LENGTH) < 0.03, "no click at the end")
  end)

  h.it("tyres are silent until sliding, and on the brakes", function()
    h.assertEq(audio.scrubLevel(0.2, false), 0)
    h.assertTrue(audio.scrubLevel(0.8, false) > 0, "a slide is heard")
    h.assertEq(audio.scrubLevel(0.8, true), 0)
  end)
end)

h.describe("sound cache", function()
  local cache = require("src/sound_cache")
  local FILES = { "src/audio.lua" }

  local function tone()
    local data = love.sound.newSoundData(500, 44100, 16, 1)
    for i = 0, 499 do data:setSample(i, math.sin(i * 0.05) * 0.8) end
    return data
  end

  local function empty()
    for _, folder in ipairs(love.filesystem.getDirectoryItems("soundcache")) do
      local path = "soundcache/" .. folder
      for _, name in ipairs(love.filesystem.getDirectoryItems(path)) do love.filesystem.remove(path .. "/" .. name) end
      love.filesystem.remove(path)
    end
  end

  h.it("gives back exactly what was rendered, without rendering again", function()
    empty()
    cache.open(FILES)
    local first = cache.get("tone", tone)
    cache.finish()
    cache.open(FILES)
    h.assertTrue(cache.complete, "the finished cache is found")
    local renders = 0
    local second = cache.get("tone", function() renders = renders + 1 return tone() end)
    h.assertEq(renders, 0)
    h.assertEq(second:getSampleCount(), first:getSampleCount())
    h.assertEq(second:getSampleRate(), first:getSampleRate())
    for i = 0, first:getSampleCount() - 1 do h.assertEq(second:getSample(i), first:getSample(i)) end
  end)

  h.it("doesn't trust a first launch that never finished", function()
    empty()
    cache.open(FILES)
    cache.get("tone", tone)
    cache.open(FILES)
    h.assertTrue(not cache.complete)
    local renders = 0
    cache.get("tone", function() renders = renders + 1 return tone() end)
    h.assertEq(renders, 1)
  end)

  h.it("renders again if a saved sound is damaged", function()
    empty()
    cache.open(FILES)
    cache.get("tone", tone)
    cache.finish()
    love.filesystem.write(cache.folder .. "/tone.wav", "not a sound")
    cache.open(FILES)
    local renders = 0
    local data = cache.get("tone", function() renders = renders + 1 return tone() end)
    h.assertEq(renders, 1)
    h.assertEq(data:getSampleCount(), 500)
  end)

  h.it("changes when the code behind the sounds changes", function()
    h.assertTrue(cache.key({ "one" }) ~= cache.key({ "two" }))
    h.assertEq(cache.key({ "one" }), cache.key({ "one" }))
  end)

  h.it("clears out what older versions left behind", function()
    empty()
    love.filesystem.createDirectory("soundcache/old")
    love.filesystem.write("soundcache/old/tone.wav", "x")
    cache.open(FILES)
    h.assertTrue(not love.filesystem.getInfo("soundcache/old"))
  end)

  h.it("still gives sound when there's nowhere to keep it", function()
    cache.open({ "src/no_such_file.lua" })
    h.assertTrue(not cache.folder)
    h.assertEq(cache.get("tone", tone):getSampleCount(), 500)
  end)
end)

h.describe("radio", function()
  local function clearMusic()
    for _, name in ipairs(love.filesystem.getDirectoryItems("music")) do
      love.filesystem.remove("music/" .. name)
    end
  end

  local function dropped(path, contents)
    return {
      getFilename = function() return path end,
      open = function() return true end,
      read = function() return contents end,
      close = function() end,
    }
  end

  h.it("knows a song by its extension, in any case", function()
    for _, name in ipairs({ "a.mp3", "a.OGG", "a.oga", "a.b.flac", "a.Wav" }) do
      h.assertTrue(radio.isTrack(name), name)
    end
    for _, name in ipairs({ "cover.jpg", "notes.txt", "mp3", "a.mp3.part", "" }) do
      h.assertTrue(not radio.isTrack(name), name)
    end
  end)

  h.it("makes a title the font can print from any filename", function()
    h.assertEq(radio.title("night_drive.mp3"), "night drive")
    h.assertEq(radio.title("a.b.flac"), "a.b")
    h.assertEq(radio.title("caf\xc3\xa9 \xff.ogg"), "caf? ?")
    local long = radio.title(string.rep("x", 200) .. ".wav")
    h.assertEq(#long, 30, "a long name is cut short")
    h.assertEq(long:sub(-3), "...")
  end)

  h.it("shuffles every song in, and doesn't repeat the last one", function()
    local names = { "a", "b", "c", "d" }
    for _ = 1, 200 do
      local order = radio.shuffle(names, "a")
      h.assertEq(#order, 4)
      h.assertTrue(order[1] ~= "a", "the last song isn't next")
      local seen = {}
      for _, name in ipairs(order) do seen[name] = true end
      for _, name in ipairs(names) do h.assertTrue(seen[name], name) end
    end
    h.assertEq(radio.shuffle({ "a" }, "a")[1], "a", "one song can only repeat")
  end)

  h.it("finds songs in the music folder and ignores the rest", function()
    love.filesystem.createDirectory("music")
    clearMusic()
    love.filesystem.write("music/b.mp3", "x")
    love.filesystem.write("music/a.ogg", "x")
    love.filesystem.write("music/cover.jpg", "x")
    h.assertEq(table.concat(radio.scan(), " "), "a.ogg b.mp3")
    clearMusic()
    h.assertEq(#radio.scan(), 0)
  end)

  h.it("copies a dropped song into the folder and refuses anything else", function()
    love.filesystem.createDirectory("music")
    clearMusic()
    h.assertTrue(radio.addFile(dropped("/home/me/Music/song.MP3", "tune")), "unix path")
    h.assertEq(love.filesystem.read("music/song.MP3"), "tune")
    h.assertTrue(radio.addFile(dropped("C:\\Music\\other.ogg", "tune")), "windows path")
    h.assertEq(#radio.tracks, 2, "the list updates at once")
    h.assertTrue(not radio.addFile(dropped("/home/me/notes.txt", "words")))
    h.assertTrue(not love.filesystem.getInfo("music/notes.txt"), "nothing written")
    clearMusic()
    radio.scan()
  end)

  h.it("has no audio to tune here, and doesn't mind", function()
    radio.tune(true)
    radio.skip()
    h.assertTrue(not radio.isPlaying())
    h.assertEq(radio.update(), nil)
  end)
end)
