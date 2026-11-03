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

h.describe("car sprites", function()
  h.it("every car's shapes can be filled and fit on its sprite", function()
    local sprites = require("src/render/car_sprites")
    for _, spec in ipairs(require("src/entities/garage")) do
      local polygons, halfWidth, halfHeight = sprites.polygons(spec)
      for i, coords in ipairs(polygons) do
        local label = spec.id .. " polygon " .. i
        h.assertTrue(pcall(love.math.triangulate, coords), label .. " can't be triangulated")
        for c = 1, #coords, 2 do
          h.assertBetween(coords[c], -halfWidth, halfWidth, label .. " length")
          h.assertBetween(coords[c + 1], -halfHeight, halfHeight, label .. " width")
        end
      end
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

h.describe("settings server", function()
  h.it("defaults to the official server, and keeps a chosen one", function()
    local kept = settings.server
    h.assertEq(kept, "spppd.vanillaiice.xyz", "the name is the default, with no port to type")
    settings.server = "192.168.1.5:8080"
    settings.save()
    settings.load()
    h.assertEq(settings.server, "192.168.1.5:8080")
    settings.server = kept
    settings.save()
  end)

  h.it("uses the usual port unless the address names one", function()
    local kept = settings.server
    local host, port = settings.serverAddress()
    h.assertEq(host, kept)
    h.assertEq(port, 8080)
    settings.server = "192.168.1.5:9000"
    host, port = settings.serverAddress()
    h.assertEq(host, "192.168.1.5")
    h.assertEq(port, 9000)
    settings.server = kept
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

  local function circle(radius)
    local nodes = {}
    for i = 0, 11 do
      local a = i / 12 * math.pi * 2
      nodes[#nodes + 1] = { x = math.cos(a) * radius, y = math.sin(a) * radius, wl = 30, wr = 30 }
    end
    return { nodes = nodes, title = "CACHED", startPoint = { x = radius, y = 0, angle = 1.57 } }
  end

  h.it("runs a saved track's file once, until the folder can have changed", function()
    catalog.save("test_cached", circle(500))
    local load, reads = love.filesystem.load, 0
    love.filesystem.load = function(...)
      reads = reads + 1
      return load(...)
    end
    local first = catalog.find("test_cached").def
    for _ = 1, 10 do h.assertTrue(catalog.find("test_cached").def == first, "same definition") end
    love.filesystem.load = load
    h.assertEq(reads, 1, "file reads")
    catalog.remove("test_cached")
  end)

  h.it("sees a file added behind its back after a refresh", function()
    catalog.save("test_seen", circle(500))
    catalog.user()
    love.filesystem.write("tracks/test_dropped.lua", love.filesystem.read("tracks/test_seen.lua"))
    h.assertEq(catalog.find("test_dropped"), nil, "not looked yet")
    catalog.refresh()
    h.assertTrue(catalog.find("test_dropped") ~= nil, "found")
    catalog.remove("test_dropped")
    catalog.remove("test_seen")
  end)

  h.it("builds a saved track's preview once, and again when it's changed", function()
    local menu = require("src/menu")
    local new, builds = Track.new, 0
    Track.new = function(def)
      builds = builds + 1
      return new(def)
    end
    catalog.save("test_preview", circle(500))
    local data
    for _ = 1, 10 do data = menu.cachedTrack(catalog.find("test_preview")) end
    h.assertEq(builds, 1, "builds")
    catalog.save("test_preview", circle(700))
    local changed = menu.cachedTrack(catalog.find("test_preview"))
    Track.new = new
    catalog.remove("test_preview")
    h.assertEq(builds, 2, "builds after saving")
    h.assertTrue(changed.track.length > data.track.length, "shows the new shape")
  end)
end)

h.describe("midnight", function()
  local environment = require("src/render/environment")
  local renderer = require("src/render/track_renderer")
  local config = require("src/config")
  local midnight, night = environment.time("midnight"), environment.time("night")

  h.it("is much darker than floodlit night, but not black", function()
    for i = 1, 3 do
      h.assertTrue(midnight.ambient[i] < night.ambient[i] * 0.4, "channel " .. i)
      h.assertTrue(midnight.ambient[i] > 0.04, "the moon still shows the shape of things")
    end
    h.assertTrue(midnight.lights and not midnight.floodlit)
    h.assertTrue(night.floodlit, "floodlit night stays as it was")
  end)

  h.it("headlights are far shorter than a floodlit night's", function()
    -- The default camera shows about 70 m of road at top speed, and a beam has
    -- faded out well before its full length.
    h.assertTrue(midnight.beams.high.length <= 75)
    h.assertTrue(midnight.beams.low.length < midnight.beams.high.length)
    h.assertTrue(night.beams.high.length > midnight.beams.high.length)
  end)

  h.it("studs run down both edges of the road, on the road", function()
    local Track = require("src/sim/track")
    local track = Track.new(catalog.find("lusail").def)
    local spots = renderer.studSpots(track)
    h.assertTrue(#spots > 100, "a whole lap of them")
    local left, right = 0, 0
    for _, spot in ipairs(spots) do
      if spot.side < 0 then left = left + 1 else right = right + 1 end
    end
    h.assertEq(left, right)
    local first = track.samples[1]
    local off = math.sqrt((spots[1].x - first.x) ^ 2 + (spots[1].y - first.y) ^ 2)
    h.assertBetween(off, first.w / 2 - config.METER, first.w / 2, "on the edge line")
  end)
end)

h.describe("audio", function()
  local function peakOf(data)
    local peak = 0
    for i = 0, data:getSampleCount() - 1 do peak = math.max(peak, math.abs(data:getSample(i))) end
    return peak
  end

  local garage = require("src/entities/garage")

  -- The engines the garage uses, one of each.
  local function voices()
    local list, seen = {}, {}
    for _, spec in ipairs(garage) do
      local voice = audio.voiceOf(spec)
      if voice and not seen[voice.key] then
        seen[voice.key] = true
        list[#list + 1] = voice
      end
    end
    return list
  end

  h.it("synthesises a tyre scrub that loops", function()
    local data = audio.scrubData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
    h.assertBetween(peakOf(data), 0.1, 0.95, "peak level, clipping sounds harsh")
  end)

  h.it("synthesises a nitro release that loops", function()
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

  h.it("a turbo builds pressure with a lag and vents it once", function()
    local spool, vented = 0, false
    for _ = 1, 10 do spool, vented = audio.spoolStep(spool, true, 1, 1 / 60, 1.8) end
    h.assertBetween(spool, 0.1, 0.5, "still spooling")
    h.assertTrue(not vented)
    for _ = 1, 60 do spool = audio.spoolStep(spool, true, 1, 1 / 60, 1.8) end
    h.assertEq(spool, 1, "full pressure")
    spool, vented = audio.spoolStep(spool, false, 1, 1 / 60, 1.8)
    h.assertTrue(vented, "lifting vents it")
  end)

  h.it("a turbo with no pressure stays quiet on a lift", function()
    local spool, vented = audio.spoolStep(0.2, false, 1, 1 / 60, 1.8)
    h.assertTrue(not vented)
    h.assertTrue(spool < 0.2)
  end)

  h.it("every car has an engine the sound can play", function()
    for _, spec in ipairs(garage) do
      h.assertTrue(spec.cylinders == 0 or spec.cylinders >= 3, spec.name .. " cylinders")
      h.assertTrue(spec.turbos == 0 or spec.turbos == 1 or spec.turbos == 2 or spec.turbos == 4, spec.name .. " turbos")
      if spec.cylinders == 0 then h.assertEq(spec.turbos, 0, spec.name .. " has nothing to turbocharge") end
    end
  end)

  h.it("the single turbo and the pair are different whistles", function()
    h.assertEq(garage.byId("hot_hatch").turbos, 1)
    h.assertEq(garage.byId("big_bull").turbos, 2)
    local one, two = audio.turboData(1), audio.turboData(2)
    local same = 0
    for i = 0, one:getSampleCount() - 1 do
      if math.abs(one:getSample(i) - two:getSample(i)) < 0.02 then same = same + 1 end
    end
    h.assertTrue(same / one:getSampleCount() < 0.2, "the same sound twice")
  end)

  h.it("a supercharger's whine climbs hard with the revs", function()
    h.assertBetween(audio.blowerPitch(1) / audio.blowerPitch(0), 4, 5.5, "sweep")
  end)

  h.it("a supercharger's whine is what you hear of it", function()
    local data = audio.blowerData()
    local n = data:getSampleCount()
    h.assertBetween(peakOf(data), 0.3, 0.95, "peak level")
    local total, re, im = 0, 0, 0
    local step = math.pi * 2 * 1000 / data:getSampleRate()  -- whole cycles, so one bin holds it
    for i = 0, n - 1 do
      local v = data:getSample(i)
      total = total + v * v
      re, im = re + v * math.cos(step * i), im + v * math.sin(step * i)
    end
    h.assertTrue((re * re + im * im) * 2 / n / total > 0.2, "the note is lost")
  end)

  h.it("a turbo's pitch moves too little to scream", function()
    h.assertBetween(audio.turboPitch(1) / audio.turboPitch(0), 1.2, 1.6, "sweep")
  end)

  h.it("a turbo stays low and is never one clean tone", function()
    for _, turbos in ipairs({ 1, 2, 4 }) do
      local data = audio.turboData(turbos)
      local n = data:getSampleCount()
      local crossings = 0
      for i = 1, n - 1 do
        if (data:getSample(i - 1) < 0) ~= (data:getSample(i) < 0) then crossings = crossings + 1 end
      end
      -- A sine crosses zero twice a cycle, at the same level throughout. Air doesn't.
      local seconds = n / data:getSampleRate()
      h.assertTrue(crossings / seconds / 2 * audio.turboPitch(1) < 1500, turbos .. " turbos are too high")
      local peak, sum = peakOf(data), 0
      for i = 0, n - 1 do sum = sum + data:getSample(i) ^ 2 end
      h.assertTrue(peak / math.sqrt(sum / n) > 2.5, turbos .. " turbos have a tone's crest")
    end
  end)

  h.it("turbo whistles join cleanly", function()
    for _, turbos in ipairs({ 1, 2, 4 }) do
      local data = audio.turboData(turbos)
      local n = data:getSampleCount()
      h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, turbos .. " loop point")
      h.assertBetween(peakOf(data), 0.1, 0.95, turbos .. " peak")
    end
  end)

  local function car(fields)
    return setmetatable(fields, { __index = { cylinders = 8, turbos = 0, supercharged = false } })
  end

  h.it("each kind of engine adds its own layer and no other", function()
    local mix = audio.engineMix(car({}), 0.8, 1, 1)
    h.assertTrue(mix.exhaust > 0.05, "pistons are heard")
    h.assertEq(mix.turbo, 0)
    h.assertEq(mix.blower, 0)
    h.assertEq(mix.motor, 0)

    local blown = audio.engineMix(car({ supercharged = true }), 0.8, 1, 0)
    h.assertTrue(blown.blower > 0.05, "the blower whines")
    h.assertEq(blown.turbo, 0)

    h.assertTrue(audio.engineMix(car({ turbos = 2 }), 0.8, 1, 1).turbo > 0.1, "full pressure whistles")
    h.assertEq(audio.engineMix(car({ turbos = 2 }), 0.8, 1, 0).turbo, 0, "no pressure, no whistle")

    local electric = audio.engineMix(car({ cylinders = 0 }), 0.8, 1, 0)
    h.assertTrue(electric.motor > 0.05, "the motor stands in")
    h.assertEq(electric.exhaust, 0)
    h.assertEq(electric.limiter, 0)
  end)

  h.it("more turbos whistle louder", function()
    local one = audio.engineMix(car({ turbos = 1 }), 0.8, 1, 1).turbo
    local two = audio.engineMix(car({ turbos = 2 }), 0.8, 1, 1).turbo
    local four = audio.engineMix(car({ turbos = 4 }), 0.8, 1, 1).turbo
    h.assertTrue(one < two and two < four)
  end)

  h.it("no cylinders is electric, with no engine to render", function()
    h.assertEq(audio.voiceOf(car({ cylinders = 0 })), nil)
  end)

  h.it("every piston engine can hit the limiter", function()
    for _, spec in ipairs(garage) do
      if spec.cylinders > 0 then h.assertTrue(audio.engineMix(spec, 1, 1, 0).limiter > 0.3, spec.name) end
    end
  end)

  h.it("a hard crash isn't quieter than the engine", function()
    h.assertTrue(peakOf(audio.shotData("impact3")) > peakOf(audio.engineData(audio.voice(8), 5400)), "a crash is an event")
  end)

  h.it("no effect starts on a hard edge", function()
    for _, name in ipairs({ "beep", "go", "click", "select", "lap", "shift", "blowoff", "finish" }) do
      h.assertTrue(math.abs(audio.shotData(name):getSample(0)) < 0.1, name)
    end
  end)

  h.it("engine loops join cleanly and don't sit in hard saturation", function()
    for _, voice in ipairs(voices()) do
      for _, rpm in ipairs(voice.rpms) do
        local name = voice.key .. " at " .. rpm
        local data = audio.engineData(voice, rpm)
        local n = data:getSampleCount()
        h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.1, name .. " loop point")
        local peak, sum, mean = peakOf(data), 0, 0
        for i = 0, n - 1 do
          local v = data:getSample(i)
          sum, mean = sum + v * v, mean + v
        end
        h.assertBetween(peak, 0.3, 0.95, name .. " peak")
        h.assertTrue(peak / math.sqrt(sum / n) > 1.25, name .. " would be a square wave")
        h.assertTrue(math.abs(mean / n) < 0.05, name .. " sits off centre")
      end
      local mid = voice.rpms[2]
      h.assertTrue(peakOf(audio.engineData(voice, mid, "overrun")) < peakOf(audio.engineData(voice, mid)), voice.key .. " overrun is quieter")
    end
  end)

  h.it("the limiter cuts in and out, and loops, on any engine", function()
    for _, voice in ipairs(voices()) do
      local data = audio.engineData(voice, voice.rpms[#voice.rpms], "limiter")
      local n = data:getSampleCount()
      h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.1, voice.key .. " loop point")
      h.assertBetween(peakOf(data), 0.3, 0.95, voice.key .. " peak")
      local cuts, cutting = 0, false
      for t = 0.02, 0.5, 0.002 do
        local level = 0
        local a = math.floor(t * 44100)
        for i = a, a + 88 do level = math.max(level, math.abs(data:getSample(i))) end
        if level < 0.15 and not cutting then cuts = cuts + 1 end
        cutting = level < 0.15
      end
      h.assertBetween(cuts, 6, 30, voice.key .. " bursts in half a second")
    end
  end)

  h.it("an engine blends between its two nearest speeds", function()
    local rpms = { 1300, 3000, 5400 }
    for rpm = 500, 8000, 250 do
      local blend = audio.engineBlend(rpm, rpms)
      -- By power: the loops don't line up, so a straight fade dips at every handover.
      local total = blend[1] ^ 2 + blend[2] ^ 2 + blend[3] ^ 2
      h.assertTrue(math.abs(total - 1) < 1e-9, rpm .. " totals " .. total)
    end
    h.assertEq(audio.engineBlend(900, rpms)[1], 1, "idle")
    h.assertEq(audio.engineBlend(3000, rpms)[2], 1, "a rendered speed plays alone")
    h.assertEq(audio.engineBlend(7000, rpms)[3], 1, "past the top")
    local between = audio.engineBlend(4000, rpms)
    h.assertEq(between[1], 0, "the far loop stays out")
    h.assertTrue(between[2] > 0 and between[3] > 0, "both neighbours play")
  end)

  h.it("more cylinders are rougher", function()
    local spread = function(voice)
      local low = 1
      for _, level in ipairs(voice.levels) do low = math.min(low, level) end
      return 1 - low
    end
    local last
    for _, cylinders in ipairs({ 4, 5, 6, 12, 16 }) do
      local voice = audio.voice(cylinders)
      if last then
        h.assertTrue(voice.noise > last.noise and voice.drive > last.drive and spread(voice) > spread(last), cylinders .. " cylinders")
      end
      last = voice
    end
  end)

  h.it("a race engine isn't a road engine with the same cylinders", function()
    local road, race = audio.voice(6), audio.voice(6, true)
    h.assertTrue(race.key ~= road.key)
    h.assertTrue(race.rpms[3] >= 12000, "it has to reach the revs")
    h.assertTrue(race.noise < road.noise and race.drive < road.drive, "smooth")
    h.assertTrue(race.pipeScale > road.pipeScale, "short pipes")
    h.assertEq(audio.voiceOf(garage.byId("open_wheeler")).key, "6race")
    h.assertEq(garage.byId("open_wheeler").cylinders, 6)
  end)

  h.it("the horn loops, and is loud enough to cut through", function()
    local data = audio.hornData()
    local n = data:getSampleCount()
    -- The wave steps hard every cycle, so the join only has to be no worse than that.
    local biggest = 0
    for i = 1, n - 1 do biggest = math.max(biggest, math.abs(data:getSample(i) - data:getSample(i - 1))) end
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) <= biggest, "click at the loop point")
    h.assertBetween(peakOf(data), 0.3, 0.95, "peak level")
  end)

  h.it("a heavy car's horn is lower than a light one's", function()
    local low = audio.hornPitch(garage.byId("baja_beast"))
    local high = audio.hornPitch(garage.byId("tofu_runner"))
    h.assertTrue(low < 1 and high > 1 and low < high)
    h.assertBetween(low, 0.7, 1.25)
    h.assertBetween(high, 0.7, 1.25)
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

  for _, name in ipairs({ "beep", "go", "click", "select", "lap", "shift", "blowoff", "finish", "impact1", "impact2", "impact3", "scrape" }) do
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

  -- The share of a sound's energy over hz, through a gentle two-pole high-pass.
  local function shareAbove(data, hz)
    local k = 1 - math.exp(-math.pi * 2 * hz / 44100)
    local low, lower, all, above = 0, 0, 0, 0
    for i = 0, data:getSampleCount() - 1 do
      local v = data:getSample(i)
      low = low + (v - low) * k
      local high = v - low
      lower = lower + (high - lower) * k
      all, above = all + v * v, above + (high - lower) ^ 2
    end
    return above / all
  end

  h.it("nitro is smooth gas with a chest, and loses pressure as it runs out", function()
    local data = audio.nitroData()
    h.assertTrue(windowOf(data, 0.3, 1) > 0.08, "loud enough to hear")
    h.assertTrue(shareAbove(data, 4000) < 0.08, "strident: " .. shareAbove(data, 4000))
    h.assertTrue(shareAbove(data, 400) < 0.6, "no chest: " .. shareAbove(data, 400))
    h.assertTrue(audio.nitroPitch(0) < audio.nitroPitch(1))
    h.assertTrue(audio.nitroLevel(0) < audio.nitroLevel(1))
    h.assertTrue(audio.nitroLevel(0) > audio.nitroLevel(1) * 0.5, "still heard on the last of it")
  end)

  h.it("nitro drives what each car already has", function()
    local audio = require("src/audio")
    local garage = require("src/entities/garage")
    local kinds = {}
    for _, spec in ipairs(garage) do kinds[spec.id] = audio.boostKind(spec) end
    h.assertEq(kinds.hot_hatch, "turbo")
    h.assertEq(kinds.quad_turbo, "turbo")
    h.assertEq(kinds.muscle_monster, "blower")
    h.assertEq(kinds.baja_beast, "blower")
    h.assertEq(kinds.cyber, "motor")
    for _, id in ipairs({ "wedge", "tofu_runner", "samurai" }) do
      h.assertEq(kinds[id], "gas", id .. " has nothing else to drive")
    end
    for _, spec in ipairs(garage) do
      if kinds[spec.id] == "gas" then h.assertEq(audio.boostPitch(spec, 1), 1, spec.id .. " has nothing to climb") end
    end
  end)

  h.it("nitro lifts a car's own sound, and more turbos lift it further", function()
    local audio = require("src/audio")
    local function spec(id) return require("src/entities/garage").byId(id) end
    local function lift(id, part)
      local before = audio.engineMix(spec(id), 0.9, 1, 1)[part]
      local during = audio.engineMix(spec(id), 0.9, 1, 1, 1)[part]
      h.assertTrue(during > before * 1.3, id .. " should be plainly louder")
      h.assertTrue(during <= 1, id .. " can't go past full volume")
      return during
    end
    local one, two, four = lift("hot_hatch", "turbo"), lift("rocket", "turbo"), lift("quad_turbo", "turbo")
    h.assertTrue(one < two and two < four, "more turbos are louder")
    lift("muscle_monster", "blower")
    lift("cyber", "motor")
    h.assertEq(audio.engineMix(spec("wedge"), 0.9, 1, 1, 1).turbo, 0, "no turbo to drive")
    h.assertEq(audio.engineMix(spec("rocket"), 0.9, 1, 0.2, 0).turbo, audio.engineMix(spec("rocket"), 0.9, 1, 0.2).turbo,
      "nothing changes without nitro")
  end)

  h.it("a turbo car gets a layer above the exhaust on nitro, bigger with more turbos", function()
    local audio = require("src/audio")
    local garage = require("src/entities/garage")
    local function layer(id, boost) return audio.engineMix(garage.byId(id), 0.9, 1, 1, boost).turboBoost end
    h.assertEq(layer("rocket", 0), 0, "silent without nitro")
    h.assertTrue(layer("hot_hatch", 1) < layer("rocket", 1) and layer("rocket", 1) < layer("quad_turbo", 1), "more turbos are bigger")
    for _, id in ipairs({ "wedge", "muscle_monster", "cyber" }) do
      h.assertEq(layer(id, 1), 0, id .. " has no turbo")
    end
    for _, turbos in ipairs({ 1, 2, 4 }) do
      local data = audio.turboBoostData(turbos)
      local rms, peak, count = 0, 0, data:getSampleCount()
      for i = 0, count - 1 do
        local v = data:getSample(i)
        rms, peak = rms + v * v, math.max(peak, math.abs(v))
      end
      h.assertNear(math.sqrt(rms / count), 0.2, 0.01, "the same level for each")
      h.assertTrue(peak < 1, "and no clipping")
    end
  end)

  h.it("nitro eases in and out, and sags with the tank", function()
    local audio = require("src/audio")
    h.assertNear(audio.boostStep(0, true, 1, 0.05), 0.5, 0.001, "a swell, not a step")
    h.assertNear(audio.boostStep(1, false, 1, 0.1), 0.7, 0.001, "and a sigh")
    local boost = 0
    for _ = 1, 60 do boost = audio.boostStep(boost, true, 0, 1 / 60) end
    h.assertNear(boost, 0.7, 0.001, "less left in the bottle")
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

  h.it("tyres squeal only well past the limit, and more the further past", function()
    h.assertEq(audio.squealLevel(0.5, false), 0, "hard cornering is only a scrub")
    h.assertTrue(audio.scrubLevel(0.5, false) > 0, "which is still heard")
    h.assertTrue(audio.squealLevel(0.9, false) > audio.squealLevel(0.65, false))
    h.assertEq(audio.squealLevel(0.9, true), 0, "not on the brakes")
  end)

  -- The level of a stretch of samples, for comparing parts of one sound.
  local function levelOf(data, from, to)
    local sum = 0
    for i = from, to - 1 do sum = sum + data:getSample(i) ^ 2 end
    return math.sqrt(sum / (to - from))
  end

  -- Clipped and scaled back down still reads as under full scale, so go by the
  -- peak against the level: 1.0 is a square wave, and noise is around 3 to 4.
  local function crestOf(data)
    local n = data:getSampleCount()
    return peakOf(data) / levelOf(data, 0, n)
  end

  h.it("a squeal is a rough note, not noise and not a whistle", function()
    local data = audio.squealData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
    h.assertBetween(peakOf(data), 0.3, 0.95, "peak")
    local function alike(lag)
      local same, total = 0, 0
      for i = 0, 20000 do
        local a, b = data:getSample(i), data:getSample(i + lag)
        same, total = same + a * b, total + a * a
      end
      return same / total
    end
    h.assertTrue(alike(90) > 0.5, "one cycle on it should repeat: " .. alike(90))
    h.assertTrue(alike(2400) < 0.7, "stays too steady: " .. alike(2400))
    local _, pitch = windowOf(data, 0.2, 1.2)
    h.assertBetween(pitch, 400, 1000, "a howl, under the ear's sharpest band")
  end)

  h.it("a drift can be held without wearing", function()
    h.assertEq(audio.squealLevel(1, false), audio.squealLevel(0.99, false), "the most it gets to")
    h.assertTrue(audio.squealLevel(1, false) <= 0.25, "a real slide sits here for seconds")
  end)

  h.it("grinding along a wall loops and hasn't been clipped", function()
    local data = audio.grindData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
    h.assertBetween(peakOf(data), 0.3, 0.95, "peak")
    h.assertTrue(crestOf(data) > 2, "square, so it clipped on the way: " .. crestOf(data))
  end)

  h.it("grinding needs a wall and some speed", function()
    h.assertEq(audio.grindLevel(0, 40), 0, "not touching")
    h.assertEq(audio.grindLevel(1, 0), 0, "pressed against it and stopped")
    h.assertTrue(audio.grindLevel(1, 10) < audio.grindLevel(1, 22), "speed brings it up")
    h.assertEq(audio.grindLevel(1, 22), audio.grindLevel(1, 60), "and it tops out")
  end)

  h.it("crash sizes follow how hard the hit was, and don't run out of range", function()
    local cases = {
      { 0.1, 0 },      -- a brush along the wall
      { 0.2, 1 },      -- 5 degrees at 20 m/s
      { 0.5, 1 },      -- 15 degrees at 20 m/s
      { 0.95, 2 },     -- 15 degrees at 40 m/s
      { 2.5, 2 },      -- 30 degrees at 40 m/s
      { 3.7, 3 },      -- head on at 20 m/s
      { 27, 3 },       -- head on at 70 m/s in the heaviest car
    }
    for _, case in ipairs(cases) do
      local size = audio.impactLevel(case[1])
      h.assertEq(size, case[2], "strength " .. case[1])
    end
    local last = 0
    for _, strength in ipairs({ 3, 5, 8, 12, 20 }) do
      local _, volume = audio.impactLevel(strength)
      h.assertTrue(volume > last, "louder at " .. strength)
      last = volume
    end
    local _, top = audio.impactLevel(1000)
    h.assertBetween(top, 0.5, 1, "stays in range")
  end)

  h.it("every crash starts with the hit and dies away", function()
    for size = 1, 3 do
      local data = audio.crashData(size)
      local n = data:getSampleCount()
      h.assertTrue(math.abs(data:getSample(0)) < 0.1, size .. " starts on a hard edge")
      -- Where it's loudest, by 2 ms windows.
      local at, loudest = 0, 0
      for i = 0, n - 89, 88 do
        local level = levelOf(data, i, i + 88)
        if level > loudest then at, loudest = i, level end
      end
      h.assertTrue(at / 44100 < 0.03, size .. " is at its loudest " .. at / 44100 .. " s in")
      h.assertTrue(levelOf(data, n - 880, n) < loudest * 0.1, size .. " is still going at the end")
      h.assertTrue(crestOf(data) > 3, size .. " is a block of noise with no hit in it: " .. crestOf(data))
    end
  end)

  h.it("bigger crashes last longer and go lower", function()
    local small, big = audio.crashData(1), audio.crashData(3)
    h.assertTrue(big:getDuration() > small:getDuration() * 2, "longer")
    h.assertTrue(levelOf(big, 8820, 13230) > levelOf(small, 4410, 8820) * 0.5, "the big one holds up")
  end)

  h.it("a crash is dead metal, with no clean pitch ringing on", function()
    local data = audio.crashData(3)
    local n = data:getSampleCount()
    -- A ringing pan repeats itself. Noise doesn't, at any lag worth hearing.
    local from, to = math.floor(n * 0.4), math.floor(n * 0.7)
    local best = 0
    for lag = 40, 400 do
      local same, total = 0, 0
      for i = from, to, 3 do
        local a, b = data:getSample(i), data:getSample(i + lag)
        same, total = same + a * b, total + a * a
      end
      best = math.max(best, same / total)
    end
    h.assertTrue(best < 0.8, "the tail rings: " .. best)
  end)

  h.it("a heavy car's crash is lower than a light one's", function()
    local low = audio.impactPitch(garage.byId("baja_beast"))
    local high = audio.impactPitch(garage.byId("open_wheeler"))
    h.assertTrue(low < 1 and high > 1)
    h.assertBetween(low, 0.85, 1.15)
    h.assertBetween(high, 0.85, 1.15)
  end)

  h.it("repeated sounds vary, by as much as they're asked to", function()
    for _ = 1, 200 do
      h.assertBetween(audio.variedPitch(0.03), 0.97, 1.03)
      h.assertBetween(audio.variedPitch(), 0.93, 1.07)
    end
  end)

  h.it("idle is its own sound, and hands over to the revs", function()
    h.assertEq(audio.idleShare(900, 900), 1, "ticking over")
    h.assertEq(audio.idleShare(1800, 900), 0, "gone by twice idle")
    h.assertBetween(audio.idleShare(1400, 900), 0.01, 0.99, "in between")
    for _, voice in ipairs(voices()) do
      local data = audio.engineData(voice, voice.idleAt, "idle")
      local n = data:getSampleCount()
      h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.1, voice.key .. " loop point")
      h.assertBetween(peakOf(data), 0.05, 0.95, voice.key .. " peak")
    end
  end)

  h.it("engine loops are centred, and every car reaches a phone", function()
    for _, voice in ipairs(voices()) do
      for _, mode in ipairs({ "speed", "overrun", "limiter" }) do
        local rpm = voice.rpms[mode == "overrun" and 2 or 3]
        local data = audio.engineData(voice, rpm, mode ~= "speed" and mode or nil)
        local n = data:getSampleCount()
        local mean, above, last = 0, 0, 0
        for i = 0, n - 1 do
          local v = data:getSample(i)
          mean = mean + v
          last = last + (v - last) * 0.042  -- the same 300 Hz as the loops are set by
          above = above + (v - last) ^ 2
        end
        h.assertTrue(math.abs(mean / n) < 0.01, voice.key .. " " .. mode .. " sits off centre by " .. mean / n)
        if mode == "speed" then
          h.assertBetween(math.sqrt(above / n), 0.1, 0.8, voice.key .. " has too little above a phone's bottom end")
        end
      end
    end
  end)

  h.it("noise loops don't dip at the join", function()
    local loops = { scrub = audio.scrubData(), nitro = audio.nitroData(), loose = audio.looseData(), road = audio.roadData() }
    for name, data in pairs(loops) do
      local n = data:getSampleCount()
      local joined = levelOf(data, 2000, 8000)  -- the middle of the crossfade
      local body = levelOf(data, 20000, n)
      h.assertTrue(joined > body * 0.85, name .. " breathes: " .. joined / body)
    end
  end)

  h.it("nothing that plays for seconds is static", function()
    local loops = {
      road = audio.roadData(), wind = audio.windData(), loose = audio.looseData(),
      scrub = audio.scrubData(), squeal = audio.squealData(), nitro = audio.nitroData(),
    }
    for name, data in pairs(loops) do
      h.assertTrue(shareAbove(data, 4000) < 0.08, name .. " is a hiss: " .. shareAbove(data, 4000))
    end
    h.assertTrue(shareAbove(loops.road, 1000) < 0.08, "the road is a rumble: " .. shareAbove(loops.road, 1000))
  end)

  h.it("high up the revs an engine's noise stays part of its note", function()
    local data = audio.engineData(audio.voice(8), 5400)
    local k = 1 - math.exp(-math.pi * 2 * 1000 / 44100)
    local low, high = 0, {}
    for i = 0, 30000 do
      local v = data:getSample(i)
      low = low + (v - low) * k
      high[i] = v - low
    end
    local cycle, same, total = 980, 0, 0  -- two turns at 5400 rpm
    for i = 4000, 24000 do
      same, total = same + high[i] * high[i + cycle], total + high[i] ^ 2
    end
    h.assertTrue(same / total > 0.88, "fresh noise every cycle is a hiss: " .. same / total)
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
