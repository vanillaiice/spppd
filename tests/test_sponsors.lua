local h = require("tests/harness")
local Track = require("src/sim/track")
local config = require("src/config")
local catalog = require("src/tracks/catalog")
local sponsors = require("src/sponsors")
local renderer = require("src/render/track_renderer")

local M = config.METER

h.describe("sponsors", function()
  h.it("every sponsor has text the font can show and colours that parse", function()
    for i, entry in ipairs(sponsors.pool) do
      h.assertEq(sponsors.check(entry), nil, "pool " .. i)
    end
    for track, spots in pairs(sponsors.spots) do
      for n, entry in pairs(spots) do
        h.assertEq(sponsors.check(entry), nil, track .. " " .. tostring(n))
      end
    end
  end)

  h.it("check turns away what a board can't show", function()
    h.assertTrue(sponsors.check({ text = "lower case", board = "#FFFFFF" }))
    h.assertTrue(sponsors.check({ text = "A VERY LONG SPONSOR NAME", board = "#FFFFFF" }))
    h.assertTrue(sponsors.check({ text = "OK", board = "red" }))
    h.assertTrue(sponsors.check({ text = "OK", board = "#FFFFFF", ink = "#FFF" }))
    h.assertEq(sponsors.check({ text = "OK & GO!", board = "#ffffff" }), nil)
  end)

  h.it("the pool never puts one sponsor on two boards in a row", function()
    for n = 1, 60 do
      local a, b = sponsors.forBoard("mirage", n), sponsors.forBoard("mirage", n + 1)
      h.assertTrue(a.text ~= b.text, "boards " .. n .. " and " .. (n + 1))
    end
  end)

  h.it("a sold board shows its buyer, and the rest the pool", function()
    local saved = sponsors.spots
    local buyer = { text = "BUYER", board = "#123456" }
    sponsors.spots = { mirage = { [3] = buyer } }
    local ok, err = pcall(function()
      h.assertEq(sponsors.forBoard("mirage", 3), buyer)
      h.assertTrue(sponsors.forBoard("mirage", 4) ~= buyer)
      h.assertTrue(sponsors.forBoard("highlands", 3) ~= buyer)
      h.assertTrue(sponsors.forBoard(nil, 3) ~= buyer)
    end)
    sponsors.spots = saved
    if not ok then error(err, 0) end
  end)

  h.it("ink left out reads on the board", function()
    h.assertEq(sponsors.paint({ text = "A", board = "#FFFFFF" }).ink[1] < 0.5, true)
    h.assertEq(sponsors.paint({ text = "A", board = "#000000" }).ink[1] > 0.5, true)
  end)

  local counts = {}
  for _, entry in ipairs(catalog.builtin()) do
    h.it(entry.name .. " has boards behind its fences, numbered the same every time", function()
      local t = Track.new(entry.def)
      local list = renderer.boardSpots(t)
      local again = renderer.boardSpots(Track.new(entry.def))
      print(string.format("        %s: %d boards", entry.name, #list))
      counts[entry.name] = #list
      h.assertTrue(#list >= 15, "only " .. #list .. " boards")
      h.assertEq(#again, #list, "a second build numbers differently")
      for i, b in ipairs(list) do
        h.assertEq(b.n, i)
        h.assertTrue(math.abs(again[i].x - b.x) < 0.01 and math.abs(again[i].y - b.y) < 0.01, "board " .. i .. " moved")
        -- Nowhere on a board is on the road.
        local ca, sa = math.cos(b.angle), math.sin(b.angle)
        for _, k in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { 0, 0 } }) do
          local u, v = k[1] * b.len / 2, k[2] * b.depth / 2
          local _, _, _, off = t:locate(b.x + u * ca - v * sa, b.y + u * sa + v * ca)
          h.assertTrue(off > 0, "board " .. i .. " is on the road")
        end
        -- The lettering's bottom faces the road.
        local downX, downY = -sa, ca
        local _, _, _, offNear = t:locate(b.x + downX * b.depth, b.y + downY * b.depth)
        local _, _, _, offFar = t:locate(b.x - downX * b.depth, b.y - downY * b.depth)
        h.assertTrue(offNear < offFar, "board " .. i .. " is lettered away from the road")
      end
    end)
  end

  h.it("every sold board is on a built-in track and exists", function()
    for name, spots in pairs(sponsors.spots) do
      local entry = catalog.find(name)
      h.assertTrue(entry and entry.builtin, "no built-in track " .. name)
      local count = counts[name] or #renderer.boardSpots(Track.new(entry.def))
      for n in pairs(spots) do
        h.assertTrue(type(n) == "number" and n >= 1 and n <= count, name .. " has no board " .. tostring(n))
      end
    end
  end)
end)

