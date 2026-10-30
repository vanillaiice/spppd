-- North-up map of the lap, with every car on it.
local colors = require("src/colors")

local minimap = {}

function minimap.load(track)
  minimap.track = track
  local b = track.bounds
  local pts = {}
  for i = 1, track.count, 2 do
    local s = track.samples[i]
    pts[#pts + 1] = s.x
    pts[#pts + 1] = s.y
  end
  pts[#pts + 1] = track.samples[1].x
  pts[#pts + 1] = track.samples[1].y
  minimap.line = pts
  minimap.bounds = b
end

-- Fits the circuit in a box; also used by the track picker.
function minimap.drawOutline(track, line, x, y, size, width, color)
  local b = track.bounds
  local span = math.max(b.maxX - b.minX, b.maxY - b.minY)
  local scale = size / span
  local ox = x + (size - (b.maxX - b.minX) * scale) / 2
  local oy = y + (size - (b.maxY - b.minY) * scale) / 2
  love.graphics.push()
  love.graphics.translate(ox, oy)
  love.graphics.scale(scale)
  love.graphics.translate(-b.minX, -b.minY)
  love.graphics.setLineJoin("bevel")
  love.graphics.setColor(0, 0, 0, 0.7)
  love.graphics.setLineWidth((width + 2) / scale)
  love.graphics.line(line)
  love.graphics.setColor(color or colors.paint)
  love.graphics.setLineWidth(width / scale)
  love.graphics.line(line)
  love.graphics.pop()
  return ox, oy, scale
end

function minimap.draw(x, y, size, cars, player)
  if not minimap.track then return end
  local b = minimap.bounds
  local ox, oy, scale = minimap.drawOutline(minimap.track, minimap.line, x, y, size, 2.5)
  local start = minimap.track.samples[1]
  love.graphics.setColor(colors.kerb)
  love.graphics.circle("fill", ox + (start.x - b.minX) * scale, oy + (start.y - b.minY) * scale, 2.5)

  for i = #cars, 1, -1 do
    local car = cars[i]
    local cx = ox + (car.curX - b.minX) * scale
    local cy = oy + (car.curY - b.minY) * scale
    if car == player then
      love.graphics.setColor(0, 0, 0)
      love.graphics.circle("fill", cx, cy, 5)
      love.graphics.setColor(colors.marshal)
      love.graphics.circle("fill", cx, cy, 3.5)
    else
      love.graphics.setColor(car.color)
      love.graphics.circle("fill", cx, cy, 3)
    end
  end
end

return minimap
