local h = require("tests.harness")
local menu = require("src.menu")
local settings = require("src.settings")
local garage = require("src.entities.garage")

h.describe("quick race", function()
  h.it("picks its own track and car, and leaves RACE's alone", function()
    local track, car = settings.track, settings.car
    for _ = 1, 20 do
      menu.rollQuick()
      local entry, spec = menu.quickPick()
      h.assertTrue(entry and entry.def, "a track")
      h.assertTrue(garage.byId(spec.id) == spec, "a car from the garage")
    end
    h.assertEq(settings.track, track, "RACE's track is as it was")
    h.assertEq(settings.car, car, "and its car")
  end)

  h.it("changes from one roll to the next, never the same track twice running", function()
    local tracks, cars, last = {}, {}, nil
    for _ = 1, 60 do
      menu.rollQuick()
      local entry, spec = menu.quickPick()
      h.assertTrue(entry.name ~= last, "the same track twice: " .. entry.name)
      last = entry.name
      tracks[entry.name], cars[spec.id] = true, true
    end
    local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    h.assertTrue(count(tracks) >= 5, "most tracks come up")
    h.assertTrue(count(cars) >= 5, "and most cars")
  end)
end)
