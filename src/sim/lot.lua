-- Freestyle's playground: what stands on the concrete apron. Data only, in world
-- px: src/world builds the bodies and track_renderer.loadApron draws them.
-- The car starts at 0,0 facing north (-y). Past this the apron goes on empty.
local config = require("src/config")

local M = config.METER

local lot = {}

lot.CONE_RADIUS = 0.4 * M
lot.CONE_MASS = 4            -- kg: a car shrugs one off
lot.CONE_RESET_DISTANCE = 60 * M  -- a knocked cone goes back once you're this far off
lot.CONTAINER_W, lot.CONTAINER_H = 12.2 * M, 2.5 * M
lot.WALL_HALF = 0.6 * M

-- Built once: the layout never changes.
local layout

local function build()
  local self = {}

  -- A painted box to start in.
  self.startBox = { x = -3 * M, y = -5 * M, w = 6 * M, h = 10 * M }

  -- Donut pad, north: a ring to circle and a tyre stack in the middle of it.
  self.donut = { x = 0, y = -90 * M, ring = 15 * M }
  self.pillars = { { x = 0, y = -90 * M, r = 2.5 * M } }

  -- Slalom, east, then three gates that step from side to side.
  self.cones = {}
  local function cone(x, y) self.cones[#self.cones + 1] = { x = x * M, y = y * M } end
  self.slalom = { x = 70 * M, fromY = 40 * M, toY = -142 * M }
  for i = 0, 13 do cone(70, 40 - i * 14) end
  for i, x in ipairs({ 70, 84, 70 }) do
    local y = -170 - (i - 1) * 26
    cone(x - 4, y)
    cone(x + 4, y)
  end

  -- Wall ride, west: an S of concrete to slide along on either side.
  self.wall = {}
  for y = 100, -100, -5 do
    local x = -80 + 12 * math.sin(2 * math.pi * (y + 100) / 200)
    self.wall[#self.wall + 1] = { x = x * M, y = y * M }
  end

  -- Figure-8, south: two blocks of stacked containers.
  self.blocks = {}
  local cols, rows = 3, 6
  local w, h = cols * lot.CONTAINER_W, rows * lot.CONTAINER_H
  for _, cx in ipairs({ -35 * M, 35 * M }) do
    local cy = 130 * M
    self.blocks[#self.blocks + 1] = { x = cx - w / 2, y = cy - h / 2, w = w, h = h, cols = cols, rows = rows }
  end
  return self
end

function lot.layout()
  layout = layout or build()
  return layout
end

return lot
