-- The race setup's car stats.
local h = require("tests/harness")
local garage = require("src/entities/garage")
local stats = require("src/sim/car_stats")

h.describe("car stats", function()
  h.it("ship for every car, and match how each car drives now (else run make car-stats)", function()
    for _, spec in ipairs(garage) do
      local shipped = stats.shipped[spec.id]
      h.assertTrue(shipped ~= nil, spec.name .. " has no shipped stats")
      local now = stats.round(stats.measure(spec))
      for _, key in ipairs(stats.ORDER) do
        h.assertNear(shipped[key], now[key], math.abs(now[key]) * 0.005 + 1e-9, spec.name .. " " .. key)
      end
    end
  end)

  h.it("give every car all five, each scored 0..1", function()
    for _, spec in ipairs(garage) do
      local s = stats.of(spec)
      for _, key in ipairs(stats.ORDER) do
        h.assertTrue(s[key] ~= nil, key)
        h.assertBetween(s[key].score, 0, 1, spec.name .. " " .. key)
        h.assertTrue(#s[key].text > 0, key .. " text")
      end
      h.assertTrue(stats.of(spec) == s, "worked out once")
    end
  end)

  h.it("rank the obvious ones the obvious way", function()
    local quad, hatch = stats.of(garage.byId("quad_turbo")), stats.of(garage.byId("hot_hatch"))
    h.assertTrue(quad.speed.value > hatch.speed.value, "QUAD TURBO is faster than the HOT HATCH")
    h.assertTrue(quad.accel.value < hatch.accel.value, "and gets to 100 sooner")
    local tofu, bull = stats.of(garage.byId("tofu_runner")), stats.of(garage.byId("big_bull"))
    h.assertTrue(tofu.handling.score > bull.handling.score, "TOFU RUNNER handles better than BIG BULL")
  end)
end)

h.describe("formula kid", function()
  local kid = garage.byId("formula_kid")

  h.it("is in the garage, at the end so saved picks keep their car", function()
    h.assertEq(kid.id, "formula_kid")
    h.assertEq(garage[#garage], kid)
  end)

  h.it("has the grippiest tyres and the lowest top speed", function()
    local mine = stats.of(kid)
    for _, spec in ipairs(garage) do
      if spec ~= kid then
        local other = stats.of(spec)
        h.assertTrue(mine.tires.value > other.tires.value, "tyres beat " .. spec.name)
        h.assertTrue(mine.speed.value < other.speed.value, "slower than " .. spec.name)
      end
    end
  end)
end)
