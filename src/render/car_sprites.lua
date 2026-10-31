-- Draws each car model once into canvases. Paint is white so the sprite can
-- be tinted to any colour; glass, lights and details sit on a second layer.
local sprites = {}

local RES = 22 -- sprite px per metre of car

-- Half-width profile, rear to front. x runs -1..1 along the car, y 0..1 across.
local STYLES = {
  hatch = {
    outline = { { -1, 0.72 }, { -0.97, 0.9 }, { -0.8, 0.98 }, { -0.2, 1 }, { 0.3, 0.98 }, { 0.72, 0.93 }, { 0.92, 0.8 }, { 1, 0.45 }, { 1, 0 } },
    screen = { 0.3, 0.02 }, rearScreen = { -0.62, -0.82 }, roofWidth = 0.68, hood = true,
  },
  sedan = {
    outline = { { -1, 0.68 }, { -0.96, 0.86 }, { -0.8, 0.96 }, { -0.2, 1 }, { 0.4, 1 }, { 0.8, 0.94 }, { 0.95, 0.76 }, { 1, 0.42 }, { 1, 0 } },
    screen = { 0.36, 0.08 }, rearScreen = { -0.44, -0.66 }, roofWidth = 0.66, hood = true, wing = 0.74, scoop = true,
  },
  coupe = {
    outline = { { -1, 0.6 }, { -0.95, 0.84 }, { -0.74, 1 }, { -0.36, 1 }, { 0.1, 0.9 }, { 0.5, 0.92 }, { 0.82, 0.84 }, { 0.96, 0.62 }, { 1, 0.32 }, { 1, 0 } },
    screen = { 0.34, 0.04 }, rearScreen = { -0.34, -0.58 }, roofWidth = 0.56, wing = 0.86, vents = true,
  },
  suv = {
    outline = { { -1, 0.78 }, { -0.97, 0.92 }, { -0.84, 1 }, { 0.3, 1 }, { 0.76, 0.97 }, { 0.94, 0.84 }, { 1, 0.56 }, { 1, 0 } },
    screen = { 0.42, 0.14 }, rearScreen = { -0.72, -0.86 }, roofWidth = 0.74, hood = true, sunroof = true,
  },
  muscle = {
    outline = { { -1, 0.74 }, { -0.97, 0.92 }, { -0.84, 0.98 }, { -0.3, 0.96 }, { 0.3, 0.98 }, { 0.8, 0.96 }, { 0.97, 0.82 }, { 1, 0.5 }, { 1, 0 } },
    screen = { 0.3, 0.02 }, rearScreen = { -0.4, -0.62 }, roofWidth = 0.62, stripes = true, scoop = true,
  },
  offroad = {
    outline = { { -1, 0.86 }, { -0.98, 0.96 }, { -0.9, 1 }, { 0.76, 1 }, { 0.94, 0.96 }, { 1, 0.8 }, { 1, 0 } },
    screen = { 0.46, 0.3 }, rearScreen = { -0.8, -0.9 }, roofWidth = 0.8, rack = true, spare = true,
  },
  fastback = {
    outline = { { -1, 0.6 }, { -0.97, 0.8 }, { -0.84, 0.92 }, { -0.42, 1 }, { 0.08, 0.95 }, { 0.5, 0.97 }, { 0.8, 0.88 }, { 0.94, 0.66 }, { 1, 0.32 }, { 1, 0 } },
    screen = { 0.42, 0.1 }, rearScreen = { -0.34, -0.68 }, roofWidth = 0.56, rearTaper = 0.68, hood = true, glassRoof = true,
    lamps = { 0.87, 0.6 },
  },
}

local function smoothOutline(points)
  -- Mirror the half profile, then round it off with Chaikin corner cutting.
  local poly = {}
  for i = 1, #points do poly[#poly + 1] = { points[i][1], points[i][2] } end
  for i = #points - 1, 2, -1 do poly[#poly + 1] = { points[i][1], -points[i][2] } end
  for _ = 1, 2 do
    local nextPoly = {}
    for i = 1, #poly do
      local a, b = poly[i], poly[i % #poly + 1]
      nextPoly[#nextPoly + 1] = { a[1] * 0.75 + b[1] * 0.25, a[2] * 0.75 + b[2] * 0.25 }
      nextPoly[#nextPoly + 1] = { a[1] * 0.25 + b[1] * 0.75, a[2] * 0.25 + b[2] * 0.75 }
    end
    poly = nextPoly
  end
  return poly
end

local function fillPoly(poly, hl, hw, scale, ox)
  local coords = {}
  for _, p in ipairs(poly) do
    coords[#coords + 1] = (p[1] * scale) * hl + (ox or 0)
    coords[#coords + 1] = p[2] * scale * hw
  end
  local ok, tris = pcall(love.math.triangulate, coords)
  if ok then
    for _, t in ipairs(tris) do love.graphics.polygon("fill", t) end
  end
end

local function quad(hl, hw, x1, y1, x2, y2, x3, y3, x4, y4)
  love.graphics.polygon("fill", x1 * hl, y1 * hw, x2 * hl, y2 * hw, x3 * hl, y3 * hw, x4 * hl, y4 * hw)
end

local function drawPaint(style, poly, hl, hw)
  love.graphics.setColor(0.62, 0.62, 0.64)
  fillPoly(poly, hl, hw, 1)
  love.graphics.setColor(0.84, 0.84, 0.86)
  fillPoly(poly, hl, hw, 0.965)
  love.graphics.setColor(1, 1, 1)
  fillPoly(poly, hl, hw, 0.9)

  -- Roof reads a shade lighter than the bonnet: it faces the sun.
  local sc = style.screen
  local rs = style.rearScreen
  love.graphics.setColor(1, 1, 1)
  quad(hl, hw, sc[2], -style.roofWidth, sc[2], style.roofWidth, rs[1], style.roofWidth * 0.98, rs[1], -style.roofWidth * 0.98)
end

local function drawDetails(style, poly, hl, hw, spec)
  local sc, rs, roof = style.screen, style.rearScreen, style.roofWidth
  local glassA = { 0.07, 0.10, 0.13, 1 }
  local glassB = { 0.13, 0.19, 0.25, 1 }

  -- Windscreen
  love.graphics.setColor(glassA)
  quad(hl, hw, sc[1], -roof * 1.22, sc[1], roof * 1.22, sc[2], roof, sc[2], -roof)
  love.graphics.setColor(glassB)
  quad(hl, hw, sc[1] - 0.03, -roof * 0.7, sc[1] - 0.03, roof * 0.1, sc[2] + 0.04, roof * 0.02, sc[2] + 0.04, -roof * 0.6)

  -- Rear screen
  love.graphics.setColor(glassA)
  local rearWidth = roof * (style.rearTaper or 1.08)
  quad(hl, hw, rs[1], -roof, rs[1], roof, rs[2], rearWidth, rs[2], -rearWidth)

  -- Side glass, split by the door pillar
  local pillar = (sc[2] + rs[1]) / 2
  for _, side in ipairs({ -1, 1 }) do
    love.graphics.setColor(glassA)
    quad(hl, hw, sc[2] - 0.02, side * (roof + 0.02), sc[2] - 0.02, side * (roof + 0.17),
      pillar + 0.02, side * (roof + 0.17), pillar + 0.02, side * (roof + 0.02))
    quad(hl, hw, pillar - 0.02, side * (roof + 0.02), pillar - 0.02, side * (roof + 0.17),
      rs[1] + 0.02, side * (roof + 0.15), rs[1] + 0.02, side * (roof + 0.02))
    -- Door mirror
    love.graphics.setColor(0.05, 0.05, 0.06)
    love.graphics.rectangle("fill", (sc[1] - 0.04) * hl - 2, side * hw * 1.03 - 2.5, 5, 5, 1.5)
  end

  -- Panel lines
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.setLineWidth(0.8)
  if style.hood then
    love.graphics.line(0.92 * hl, -0.6 * hw, sc[1] * hl, -0.72 * hw)
    love.graphics.line(0.92 * hl, 0.6 * hw, sc[1] * hl, 0.72 * hw)
  end
  love.graphics.line(pillar * hl, -0.98 * hw, pillar * hl, -0.82 * hw)
  love.graphics.line(pillar * hl, 0.98 * hw, pillar * hl, 0.82 * hw)

  -- Sheen: a soft band across bonnet and roof that survives any paint colour
  love.graphics.setColor(1, 1, 1, 0.13)
  quad(hl, hw, 0.84, -0.5, 0.84, -0.1, sc[1] + 0.02, -0.18, sc[1] + 0.02, -0.6)
  love.graphics.setColor(1, 1, 1, 0.1)
  quad(hl, hw, sc[2] - 0.05, -roof * 0.8, sc[2] - 0.05, -roof * 0.1, rs[1] + 0.08, -roof * 0.1, rs[1] + 0.08, -roof * 0.8)

  if style.stripes then
    love.graphics.setColor(0.95, 0.95, 0.95, 0.9)
    quad(hl, hw, 1, -0.2, 1, -0.06, -1, -0.06, -1, -0.2)
    quad(hl, hw, 1, 0.06, 1, 0.2, -1, 0.2, -1, 0.06)
  end
  if style.scoop then
    love.graphics.setColor(0.04, 0.04, 0.05)
    quad(hl, hw, 0.62, -0.2, 0.62, 0.2, 0.5, 0.24, 0.5, -0.24)
  end
  if style.vents then
    love.graphics.setColor(0.05, 0.05, 0.06)
    for _, x in ipairs({ -0.62, -0.7, -0.78 }) do
      quad(hl, hw, x, -0.34, x, 0.34, x - 0.04, 0.34, x - 0.04, -0.34)
    end
  end
  if style.sunroof then
    love.graphics.setColor(0.06, 0.08, 0.1)
    love.graphics.rectangle("fill", -0.3 * hl, -0.42 * hw, 0.42 * hl, 0.84 * hw, 3)
  end
  if style.glassRoof then
    love.graphics.setColor(glassA)
    quad(hl, hw, sc[2] - 0.03, -roof * 0.96, sc[2] - 0.03, roof * 0.96, rs[1] + 0.03, roof * 0.96, rs[1] + 0.03, -roof * 0.96)
    love.graphics.setColor(glassB)
    quad(hl, hw, sc[2] - 0.08, -roof * 0.7, sc[2] - 0.08, -roof * 0.1, rs[1] + 0.1, -roof * 0.1, rs[1] + 0.1, -roof * 0.7)
  end
  if style.rack then
    love.graphics.setColor(0.08, 0.08, 0.09)
    love.graphics.setLineWidth(1.6)
    for x = -0.6, 0.1, 0.17 do
      love.graphics.line(x * hl, -roof * 0.86 * hw, x * hl, roof * 0.86 * hw)
    end
    love.graphics.line(-0.65 * hl, -roof * 0.86 * hw, 0.14 * hl, -roof * 0.86 * hw)
    love.graphics.line(-0.65 * hl, roof * 0.86 * hw, 0.14 * hl, roof * 0.86 * hw)
  end
  if style.spare then
    love.graphics.setColor(0.05, 0.05, 0.05)
    love.graphics.rectangle("fill", -hl - 3, -0.34 * hw, 5, 0.68 * hw, 2)
  end
  if style.wing then
    love.graphics.setColor(0.05, 0.05, 0.06)
    quad(hl, hw, -style.wing - 0.04, -0.94, -style.wing - 0.04, 0.94, -style.wing - 0.13, 0.94, -style.wing - 0.13, -0.94)
  end

  -- Lamps, unlit. The glow is added at runtime.
  local lamps = style.lamps or { 0.92, 0.66 }
  love.graphics.setColor(0.92, 0.94, 0.86)
  for _, side in ipairs({ -1, 1 }) do
    love.graphics.ellipse("fill", lamps[1] * hl, side * lamps[2] * hw, 3.5, 6)
  end
  love.graphics.setColor(0.42, 0.04, 0.05)
  for _, side in ipairs({ -1, 1 }) do
    love.graphics.rectangle("fill", -0.985 * hl - 0.8, side * 0.62 * hw - 7, 3, 14, 1)
  end
end

function sprites.get(spec)
  sprites.cache = sprites.cache or {}
  local key = spec.id
  if sprites.cache[key] then return sprites.cache[key] end

  local style = STYLES[spec.bodyStyle] or STYLES.sedan
  local poly = smoothOutline(style.outline)
  local width, height = spec.length * RES + 16, spec.width * RES + 16
  local hl, hw = spec.length * RES / 2, spec.width * RES / 2

  local function layer(draw)
    local canvas = love.graphics.newCanvas(width, height, { mipmaps = "auto" })
    love.graphics.push("all")
    love.graphics.reset()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.translate(width / 2, height / 2)
    draw()
    love.graphics.pop()
    canvas:setFilter("linear", "linear")
    canvas:setMipmapFilter("linear")
    return canvas
  end

  local sprite = {
    scale = 12 / RES, -- sprite px to world px (see config.METER)
    ox = width / 2, oy = height / 2,
    paint = layer(function() drawPaint(style, poly, hl, hw) end),
    detail = layer(function() drawDetails(style, poly, hl, hw, spec) end),
    shadow = layer(function()
      for i = 1, 8 do
        love.graphics.setColor(1, 1, 1, 0.13)
        fillPoly(poly, hl, hw, 0.92 + i * 0.022)
      end
    end),
  }
  sprites.cache[key] = sprite
  return sprite
end

return sprites
