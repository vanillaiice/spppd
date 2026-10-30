local h = require("tests/harness")
local Track = require("src/sim/track")
local config = require("src/config")
local catalog = require("src/tracks/catalog")

local M = config.METER

h.describe("track", function()
  for _, entry in ipairs(catalog.builtin()) do
    h.it(entry.name .. " builds a clean closed ribbon", function()
      local t = Track.new(entry.def)
      print(string.format("        %s: %.0f m, %d samples", entry.name, t.length / M, t.count))
      h.assertTrue(t.length > 500 * M, "lap too short")
      for i = 1, t.count do
        local s = t.samples[i]
        h.assertTrue(s.x == s.x and s.lx == s.lx and s.k == s.k, "NaN in sample " .. i)
        local q = t.samples[i % t.count + 1]
        local gap = math.sqrt((s.x - q.x) ^ 2 + (s.y - q.y) ^ 2)
        h.assertTrue(gap < config.SAMPLE_SPACING * M * 4, "ribbon jump at sample " .. i)
        h.assertTrue(s.w > 5 * M, string.format("too narrow at %d: %.1f m", i, s.w / M))
      end
      local issues = t:validate()
      h.assertEq(#issues, 0, "validate: " .. table.concat(issues, "; "))
    end)

    h.it(entry.name .. " drives in the start direction with left on the left", function()
      local t = Track.new(entry.def)
      if entry.def.startPoint and entry.def.startPoint.angle then
        local s = t.samples[1]
        local a = entry.def.startPoint.angle
        h.assertTrue(s.tx * math.cos(a) + s.ty * math.sin(a) > 0.5, "wrong way round")
      end
      for i = 1, t.count do
        local s = t.samples[i]
        local dot = (s.rx - s.x) * s.nx + (s.ry - s.y) * s.ny
        h.assertTrue(dot > 0, "right edge is on the left at " .. i)
      end
    end)

    h.it(entry.name .. " keeps the racing line and barriers sane", function()
      local t = Track.new(entry.def)
      for i = 1, t.count do
        local s = t.samples[i]
        local _, _, lateral, off = t:locate(s.lineX, s.lineY, i)
        h.assertEq(off, 0, "racing line left the road at " .. i)
        h.assertTrue(math.abs(lateral) < s.w / 2, "line off centre")
        h.assertTrue(s.barrierl > 1.5 * M and s.barrierr > 1.5 * M, "barrier too tight at " .. i)
      end
    end)

    h.it(entry.name .. " barriers never cross the road", function()
      local t = Track.new(entry.def)
      local function ccw(a, b, c) return (c.y - a.y) * (b.x - a.x) > (b.y - a.y) * (c.x - a.x) end
      local function crosses(a, b, c, d)
        return ccw(a, c, d) ~= ccw(b, c, d) and ccw(a, b, c) ~= ccw(a, b, d)
      end
      for _, wall in ipairs({ t.barrierL, t.barrierR }) do
        for w = 1, #wall do
          local a, b = wall[w], wall[w % #wall + 1]
          for i = 1, t.count do
            local s, q = t.samples[i], t.samples[i % t.count + 1]
            local l1, l2 = { x = s.lx, y = s.ly }, { x = q.lx, y = q.ly }
            local r1, r2 = { x = s.rx, y = s.ry }, { x = q.rx, y = q.ry }
            h.assertTrue(not crosses(a, b, l1, l2) and not crosses(a, b, r1, r2),
              "barrier crosses the road near sample " .. i)
          end
        end
      end
    end)

    h.it(entry.name .. " barriers have no self-intersections", function()
      local t = Track.new(entry.def)
      local function ccw(a, b, c) return (c.y - a.y) * (b.x - a.x) > (b.y - a.y) * (c.x - a.x) end
      for _, wall in ipairs({ t.barrierL, t.barrierR }) do
        local n = #wall
        for i = 1, n do
          local a, b = wall[i], wall[i % n + 1]
          for j = i + 2, n do
            if not (i == 1 and j == n) then
              local c, d = wall[j], wall[j % n + 1]
              local cross = ccw(a, c, d) ~= ccw(b, c, d) and ccw(a, b, c) ~= ccw(a, b, d)
              h.assertTrue(not cross, "wall loops at " .. i)
            end
          end
        end
      end
    end)

    h.it(entry.name .. " surface checks agree with the geometry", function()
      local t = Track.new(entry.def)
      for i = 1, t.count, 7 do
        local s = t.samples[i]
        h.assertEq((t:surfaceAt(s.x, s.y, i)), "asphalt", "centre at " .. i)
        local out = t:surfaceAt(s.rx + s.nx * 6 * M, s.ry + s.ny * 6 * M, i)
        h.assertTrue(out == "grass" or out == "gravel" or out == "asphalt", "outside at " .. i)
      end
    end)

    h.it(entry.name .. " grid slots are on the road and don't overlap", function()
      local t = Track.new(entry.def)
      local seen = {}
      for slot = 1, 6 do
        local x, y, angle = t:gridSlot(slot)
        local _, _, _, off = t:locate(x, y)
        h.assertEq(off, 0, "slot " .. slot .. " off the road")
        for _, p in ipairs(seen) do
          local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2) / M
          h.assertTrue(d > 4, string.format("slots overlap: %.1f m", d))
        end
        seen[#seen + 1] = { x = x, y = y }
        h.assertTrue(angle == angle, "NaN angle")
      end
    end)
  end

  h.it("locate is stable around the lap", function()
    local t = Track.new(catalog.builtin()[1].def)
    local hint
    local last = -1
    local wraps = 0
    for i = 1, t.count do
      local s = t.samples[i]
      local idx, dist = t:locate(s.x + s.tx * 3, s.y + s.ty * 3, hint)
      hint = idx
      if dist < last then wraps = wraps + 1 end
      last = dist
    end
    h.assertTrue(wraps <= 1, "distance went backwards " .. wraps .. " times")
  end)

  h.it("a spline definition honours its node widths", function()
    local nodes = {}
    for i = 0, 15 do
      local a = i / 16 * math.pi * 2
      nodes[#nodes + 1] = { x = math.cos(a) * 600, y = math.sin(a) * 400, wl = 50, wr = 70 }
    end
    local t = Track.new({ nodes = nodes, startPoint = { x = 600, y = 0, angle = math.pi / 2 } })
    local s = t.samples[1]
    h.assertNear(s.w / config.TRACK_SCALE, 120, 6, "width")
    local back = t:toNodes(60)
    h.assertTrue(#back >= 8, "toNodes too sparse")
    h.assertNear(back[1].wl + back[1].wr, 120, 8, "round-trip width")
  end)
end)
