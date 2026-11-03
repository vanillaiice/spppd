local h = require("tests/harness")
local damage = require("src/render/car_damage")

h.describe("crash damage", function()
  h.it("a dent folds the body in towards the middle where it hit", function()
    local dents = {}
    damage.dent(dents, 2.2, 0.6, 0.3)
    local dx, dy, wear = damage.at(dents, 2.2, 0.6)
    h.assertTrue(dx < -0.2 and dy < 0, "the nose corner goes back and in")
    h.assertBetween(wear, 0.5, 1, "and is scuffed")
    local fx, fy, far = damage.at(dents, -2.2, -0.9)
    h.assertTrue(math.abs(fx) + math.abs(fy) < 0.01 and far < 0.01, "the far corner is untouched")
  end)

  h.it("hits in one place deepen one dent, up to a limit", function()
    local dents = {}
    for _ = 1, 10 do damage.dent(dents, 2.2, 0.1, 0.3) end
    h.assertEq(#dents, 1)
    local dx, dy = damage.at(dents, 2.2, 0.1)
    h.assertTrue(math.sqrt(dx * dx + dy * dy) <= damage.MAX_PUSH + 1e-9, "never folds past the limit")
  end)

  h.it("keeps only the deepest few dents", function()
    local dents = {}
    damage.dent(dents, 2.2, 0, 0.1)
    damage.dent(dents, -2.2, 0, 0.3)
    damage.dent(dents, 0, 0.9, 0.3)
    damage.dent(dents, 0, -0.9, 0.3)
    h.assertEq(#dents, damage.MAX_DENTS)
    for _, d in ipairs(dents) do h.assertTrue(d.depth > 0.2, "the shallow one gave way") end
  end)

  h.it("a harder wreck folds deeper", function()
    h.assertTrue(damage.wreckDepth(40) > damage.wreckDepth(15))
    h.assertTrue(damage.wreckDepth(200) <= damage.MAX_PUSH)
  end)
end)
