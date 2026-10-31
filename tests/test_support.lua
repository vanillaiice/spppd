local h = require("tests/harness")
local settings = require("src/settings")
local input = require("src/input")
local catalog = require("src/tracks/catalog")
local Track = require("src/sim/track")
local audio = require("src/audio")

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

  h.it("synthesises a nitro rumble that loops", function()
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
    local layers = { na = "intake", supercharged = "blower", electric = "motor" }
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

  h.it("only an electric car loses its pistons", function()
    h.assertEq(audio.engineMix("electric", 0.8, 1, 0).pistons, 0)
    for _, kind in ipairs({ "na", "turbo", "supercharged" }) do
      h.assertEq(audio.engineMix(kind, 0.8, 1, 0).pistons, 1, kind)
    end
    h.assertEq(audio.engineMix(nil, 0.8, 1, 0).pistons, 1)
  end)

  for _, name in ipairs({ "beep", "go", "click", "select", "lap", "shift", "pop", "blowoff", "impact", "scrape" }) do
    h.it("the " .. name .. " sound is short and doesn't clip", function()
      local data = audio.shotData(name)
      h.assertBetween(data:getDuration(), 0.01, 1, "length")
      h.assertBetween(peakOf(data), 0.05, 0.95, "peak level")
    end)
  end

  h.it("tyres are silent until sliding, and on the brakes", function()
    h.assertEq(audio.scrubLevel(0.2, false), 0)
    h.assertTrue(audio.scrubLevel(0.8, false) > 0, "a slide is heard")
    h.assertEq(audio.scrubLevel(0.8, true), 0)
  end)
end)
