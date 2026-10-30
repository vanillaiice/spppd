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

  h.it("nitro only fires while the key is held (the old toggle bug)", function()
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

  h.it("synthesises a tyre squeal that loops", function()
    local data = audio.squealData()
    local n = data:getSampleCount()
    h.assertTrue(math.abs(data:getSample(0) - data:getSample(n - 1)) < 0.2, "loop point")
  end)
end)
