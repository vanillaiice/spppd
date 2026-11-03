-- A wrecked car's body folds in where it hit, and the paint scuffs dark there.
-- It's only for the wreck: the car goes back on the road whole, so nothing adds
-- up over a race.
--
-- The sprite is drawn through a grid mesh, and the grid is pulled in around each
-- dent. Positions here are metres in the car's own frame, x forward, y across.
local damage = {}

damage.MAX_DENTS = 3
damage.MAX_PUSH = 0.6    -- metres the body can fold in at one spot
local REACH = 0.9        -- metres a full-depth dent spreads across the body
local MERGE = 0.6        -- metres: a hit this close to a dent deepens that one
local CELL = 0.2         -- metres between the mesh's vertices
local WRINKLE = 0.12     -- of a dent's push, crumpling it across

-- How deep a wreck folds the car, from the speed it lost to the fence in m/s.
function damage.wreckDepth(hit)
  return math.max(0.38, math.min(damage.MAX_PUSH, 0.38 + ((hit or 15) - 15) * 0.012))
end

-- Adds a dent at lx, ly, pushed in towards the middle of the car.
function damage.dent(dents, lx, ly, depth)
  for _, d in ipairs(dents) do
    if (d.x - lx) ^ 2 + (d.y - ly) ^ 2 < MERGE * MERGE then
      d.depth = math.min(damage.MAX_PUSH, math.max(d.depth, depth) + math.min(d.depth, depth) * 0.4)
      return d
    end
  end
  local len = math.sqrt(lx * lx + ly * ly)
  local d = {
    x = lx, y = ly, depth = math.min(damage.MAX_PUSH, depth),
    dx = len > 1e-6 and -lx / len or -1, dy = len > 1e-6 and -ly / len or 0,
  }
  if #dents < damage.MAX_DENTS then
    dents[#dents + 1] = d
  else
    local shallowest = 1
    for i, other in ipairs(dents) do
      if other.depth < dents[shallowest].depth then shallowest = i end
    end
    if dents[shallowest].depth < depth then dents[shallowest] = d end
  end
  return d
end

-- How far a point of the body is pushed, in metres, and how worn it is, 0..1.
function damage.at(dents, px, py)
  local dx, dy, wear = 0, 0, 0
  for _, d in ipairs(dents) do
    local reach = REACH * (0.6 + 0.4 * d.depth / damage.MAX_PUSH)
    local f = math.exp(-((px - d.x) ^ 2 + (py - d.y) ^ 2) / (reach * reach))
    local push = d.depth * f
    dx, dy = dx + d.dx * push, dy + d.dy * push
    wear = wear + f * d.depth / damage.MAX_PUSH
  end
  local len = math.sqrt(dx * dx + dy * dy)
  if len > damage.MAX_PUSH then
    dx, dy = dx / len * damage.MAX_PUSH, dy / len * damage.MAX_PUSH
  end
  return dx, dy, math.min(1, wear)
end

-- The same small shake for a vertex every frame, so the crumple doesn't shimmer.
local function hash(i, j)
  local v = math.sin(i * 12.9898 + j * 78.233) * 43758.5453
  return v - math.floor(v) - 0.5
end

-- The grid for a sprite, bent by these dents. ppm is canvas px per metre. An old
-- mesh of the same sprite is reused.
function damage.mesh(sprite, dents, ppm, old)
  local w, h = sprite.paint:getDimensions()
  local cols = math.max(4, math.ceil(w / (CELL * ppm)))
  local rows = math.max(2, math.ceil(h / (CELL * ppm)))
  local verts = {}
  for j = 0, rows do
    for i = 0, cols do
      local u, v = i / cols, j / rows
      local px, py = u * w, v * h
      local dx, dy, wear = damage.at(dents, (px - sprite.ox) / ppm, (py - sprite.oy) / ppm)
      -- Crumpled metal wrinkles across the push as well as along it.
      local shake = hash(i, j) * WRINKLE * 2
      dx, dy = dx - dy * shake, dy + dx * shake
      local shade = 1 - wear * 0.72
      verts[#verts + 1] = { px + dx * ppm, py + dy * ppm, u, v, shade, shade * 0.97, shade * 0.95, 1 }
    end
  end
  if old and old:getVertexCount() == #verts then
    old:setVertices(verts)
    return old
  end
  local map = {}
  for j = 0, rows - 1 do
    for i = 0, cols - 1 do
      local a = j * (cols + 1) + i + 1
      local b, c, d = a + 1, a + cols + 1, a + cols + 2
      map[#map + 1], map[#map + 2], map[#map + 3] = a, b, c
      map[#map + 1], map[#map + 2], map[#map + 3] = b, d, c
    end
  end
  local mesh = love.graphics.newMesh(verts, "triangles", "dynamic")
  mesh:setVertexMap(map)
  return mesh
end

return damage
