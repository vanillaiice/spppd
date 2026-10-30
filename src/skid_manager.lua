-- Tyre marks stay on the road, as they do at a real circuit. A ring buffer
-- of quads in one mesh means thousands of marks cost a single draw.
local skids = {}

local MAX_QUADS = 6000
local WIDTH = 2.6

function skids.load()
  local vertices = {}
  for i = 1, MAX_QUADS * 4 do vertices[i] = { 0, 0, 0, 0, 0, 0, 0, 0 } end
  skids.mesh = love.graphics.newMesh(vertices, "triangles", "stream")
  local map = {}
  for q = 0, MAX_QUADS - 1 do
    local b = q * 4
    map[#map + 1] = b + 1
    map[#map + 1] = b + 2
    map[#map + 1] = b + 3
    map[#map + 1] = b + 1
    map[#map + 1] = b + 3
    map[#map + 1] = b + 4
  end
  skids.mesh:setVertexMap(map)
  skids.head = 0
  skids.count = 0
end

-- Each wheel keeps its own last point; pass nil to lift the tyre.
function skids.add(trail, x, y, nx, ny, strength, r, g, b)
  if not trail.x then
    trail.x, trail.y, trail.nx, trail.ny, trail.a = x, y, nx, ny, 0
    return
  end
  local dx, dy = x - trail.x, y - trail.y
  if dx * dx + dy * dy < 16 then return end

  local a0, a1 = trail.a, strength
  local w = WIDTH
  local base = skids.head * 4
  local mesh = skids.mesh
  mesh:setVertex(base + 1, trail.x - trail.nx * w, trail.y - trail.ny * w, 0, 0, r, g, b, a0)
  mesh:setVertex(base + 2, trail.x + trail.nx * w, trail.y + trail.ny * w, 0, 0, r, g, b, a0)
  mesh:setVertex(base + 3, x + nx * w, y + ny * w, 0, 0, r, g, b, a1)
  mesh:setVertex(base + 4, x - nx * w, y - ny * w, 0, 0, r, g, b, a1)

  skids.head = (skids.head + 1) % MAX_QUADS
  skids.count = math.min(MAX_QUADS, skids.count + 1)
  trail.x, trail.y, trail.nx, trail.ny, trail.a = x, y, nx, ny, a1
end

function skids.lift(trail)
  trail.x = nil
end

function skids.draw()
  if skids.count == 0 then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(skids.mesh)
end

return skids
