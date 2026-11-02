-- Draws each car model once into canvases. Paint is white so the sprite can
-- be tinted to any colour; glass, lights and details sit on a second layer.
local plans = require("src/render/car_plans")

local sprites = {}

local RES = 22 -- sprite px per metre of car
local SHARPNESS = 2 -- canvases hold this many pixels for each sprite px

-- Half-width profile, rear to front. x runs -1..1 along the car, y 0..1 across.
local STYLES = {
  muscle = {
    outline = { { -1, 0.74 }, { -0.97, 0.92 }, { -0.84, 0.98 }, { -0.3, 0.96 }, { 0.3, 0.98 }, { 0.8, 0.96 }, { 0.97, 0.82 }, { 1, 0.5 }, { 1, 0 } },
    screen = { 0.3, 0.02 }, rearScreen = { -0.4, -0.62 }, roofWidth = 0.62, stripes = true, scoop = true,
  },
  fastback = {
    outline = { { -1, 0.6 }, { -0.97, 0.8 }, { -0.84, 0.92 }, { -0.42, 1 }, { 0.08, 0.95 }, { 0.5, 0.97 }, { 0.8, 0.88 }, { 0.94, 0.66 }, { 1, 0.32 }, { 1, 0 } },
    screen = { 0.42, 0.1 }, rearScreen = { -0.34, -0.68 }, roofWidth = 0.56, rearTaper = 0.68, hood = true, glassRoof = true,
    lamps = { 0.87, 0.6 },
  },
  notch = {
    outline = { { -1, 0.74 }, { -0.97, 0.92 }, { -0.84, 0.98 }, { 0.3, 0.98 }, { 0.82, 0.96 }, { 0.97, 0.84 }, { 1, 0.52 }, { 1, 0 } },
    screen = { 0.3, 0.04 }, rearScreen = { -0.46, -0.68 }, roofWidth = 0.68, hood = true, popups = { 0.72, 0.56 }, sills = true,
  },
  hyper = {
    outline = { { -1, 0.62 }, { -0.96, 0.84 }, { -0.76, 1 }, { -0.3, 1 }, { 0.16, 0.9 }, { 0.58, 0.92 }, { 0.86, 0.84 }, { 0.97, 0.6 }, { 1, 0.26 }, { 1, 0 } },
    screen = { 0.3, -0.04 }, rearScreen = { -0.3, -0.5 }, roofWidth = 0.54, spine = true, ducts = true, lamps = { 0.84, 0.62 },
  },
  -- No bodywork over the wheels, so the real ones show either side of a thin tub.
  formula = {
    outline = { { -1, 0.14 }, { -0.8, 0.2 }, { -0.5, 0.42 }, { -0.14, 0.54 }, { 0.06, 0.46 }, { 0.2, 0.2 }, { 0.92, 0.12 }, { 1, 0.08 }, { 1, 0 } },
    open = true,
  },
  truck = {
    outline = { { -1, 0.9 }, { -0.98, 0.98 }, { -0.9, 1 }, { 0.3, 1 }, { 0.74, 0.98 }, { 0.93, 0.9 }, { 1, 0.7 }, { 1, 0 } },
    screen = { 0.42, 0.28 }, rearScreen = { -0.14, -0.2 }, roofWidth = 0.76, hood = true, scoop = true, bed = true,
    markers = true, lamps = { 0.95, 0.72 },
  },
}

for name, plan in pairs(plans) do STYLES[name] = plan end

local function chaikin(poly, passes)
  for _ = 1, passes do
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

local function smoothOutline(points)
  -- Mirror the half profile, then round it off with Chaikin corner cutting.
  local poly = {}
  for i = 1, #points do poly[#poly + 1] = { points[i][1], points[i][2] } end
  for i = #points - 1, 1, -1 do poly[#poly + 1] = { points[i][1], -points[i][2] } end
  return chaikin(poly, 2)
end

-- Rounds each corner by its own radius in metres (the third number of a point,
-- or the plan's `corner`), so long edges stay straight and a nose can be sharp.
-- Chaikin can't do that: it cuts a fixed share of every edge.
local function filletOutline(points, hl, hw, corner, metres)
  local half = {}
  for i = 1, #points do half[i] = points[i] end
  for i = #points - 1, 1, -1 do half[#half + 1] = { points[i][1], -points[i][2], points[i][3] } end
  local poly = {}
  -- Two curves that each take half an edge meet on the same point, and
  -- triangulating fails on a repeated point.
  local function add(x, y)
    local last = poly[#poly] or poly[1]
    if not last or math.abs(last[1] - x) + math.abs(last[2] - y) > 1e-4 then poly[#poly + 1] = { x, y } end
  end
  local count = #half
  for i = 1, count do
    local p, a, b = half[i], half[(i - 2) % count + 1], half[i % count + 1]
    local ax, ay = (a[1] - p[1]) * hl, (a[2] - p[2]) * hw
    local bx, by = (b[1] - p[1]) * hl, (b[2] - p[2]) * hw
    local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
    local cut = math.min((p[3] or corner) * metres, la / 2, lb / 2)
    if cut <= 0 then
      add(p[1], p[2])
    else
      local sx, sy = ax / la * cut, ay / la * cut
      local ex, ey = bx / lb * cut, by / lb * cut
      for step = 0, 4 do
        local t = step / 4
        local u = 1 - t
        -- A quadratic curve with the original corner as its control point.
        local x = sx * u * u + ex * t * t
        local y = sy * u * u + ey * t * t
        add(p[1] + x / hl, p[2] + y / hw)
      end
    end
  end
  local first, last = poly[1], poly[#poly]
  if math.abs(last[1] - first[1]) + math.abs(last[2] - first[2]) <= 1e-4 then poly[#poly] = nil end
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

local function drawOpenPaint(poly, hl, hw)
  love.graphics.setColor(0.84, 0.84, 0.86)
  fillPoly(poly, hl, hw, 1)
  love.graphics.setColor(1, 1, 1)
  fillPoly(poly, hl, hw, 0.9)
  -- Front wing, sweeping back at its tips, and the rear wing.
  quad(hl, hw, 0.98, -0.2, 0.98, 0.2, 0.88, 0.94, 0.8, 0.94)
  quad(hl, hw, 0.98, -0.2, 0.98, 0.2, 0.8, -0.94, 0.88, -0.94)
  quad(hl, hw, -0.84, -0.66, -0.84, 0.66, -0.98, 0.66, -0.98, -0.66)
end

local function drawOpenDetails(hl, hw)
  -- Suspension arms out to the wheels.
  love.graphics.setColor(0.08, 0.08, 0.09)
  love.graphics.setLineWidth(1.2)
  for _, side in ipairs({ -1, 1 }) do
    love.graphics.line(0.5 * hl, side * 0.14 * hw, 0.68 * hl, side * 0.8 * hw)
    love.graphics.line(0.76 * hl, side * 0.12 * hw, 0.68 * hl, side * 0.8 * hw)
    love.graphics.line(-0.56 * hl, side * 0.3 * hw, -0.66 * hl, side * 0.8 * hw)
    love.graphics.line(-0.78 * hl, side * 0.18 * hw, -0.66 * hl, side * 0.8 * hw)
  end
  -- Cockpit, helmet and the intake over the driver's head.
  love.graphics.setColor(0.05, 0.05, 0.06)
  love.graphics.ellipse("fill", 0.06 * hl, 0, 0.16 * hl, 0.15 * hw)
  love.graphics.setColor(0.96, 0.84, 0.16)
  love.graphics.circle("fill", 0.02 * hl, 0, 0.09 * hw)
  love.graphics.setColor(0.05, 0.05, 0.06)
  love.graphics.ellipse("fill", -0.14 * hl, 0, 0.05 * hl, 0.07 * hw)
  -- Wing end plates and the rain light.
  for _, side in ipairs({ -1, 1 }) do
    quad(hl, hw, 0.9, side * 0.92, 0.9, side * 0.98, 0.78, side * 0.98, 0.78, side * 0.92)
    quad(hl, hw, -0.82, side * 0.62, -0.82, side * 0.7, -1, side * 0.7, -1, side * 0.62)
  end
  love.graphics.setColor(0.42, 0.04, 0.05)
  love.graphics.rectangle("fill", -0.985 * hl - 0.8, -0.1 * hw, 3, 0.2 * hw, 1)
end

local function outlineCoords(poly, hl, hw, inset)
  local coords = {}
  for _, p in ipairs(poly) do
    coords[#coords + 1] = p[1] * (hl - inset)
    coords[#coords + 1] = p[2] * (hw - inset)
  end
  return coords
end

local function fillCoords(coords)
  for _, t in ipairs(love.math.triangulate(coords)) do love.graphics.polygon("fill", t) end
end

-- The edge falls away evenly all round, nose and flanks alike.
local function drawPlanPaint(poly, hl, hw)
  love.graphics.setColor(0.62, 0.62, 0.64)
  fillCoords(outlineCoords(poly, hl, hw, 0))
  love.graphics.setColor(0.84, 0.84, 0.86)
  fillCoords(outlineCoords(poly, hl, hw, 0.9))
  love.graphics.setColor(1, 1, 1)
  fillCoords(outlineCoords(poly, hl, hw, 2.2))
end

-- The filled polygons of one plan part, in outline coordinates.
local function partPolygons(part)
  local function build(points, flip, closed)
    local poly = {}
    for i = 1, #points, 2 do poly[#poly + 1] = { points[i], points[i + 1] * flip } end
    if closed then
      for i = #points - 1, 1, -2 do poly[#poly + 1] = { points[i], -points[i + 1] } end
    end
    return chaikin(poly, part.soft or 0)
  end
  if part.solo then return { build(part.solo, 1) } end
  if part.pair then return { build(part.pair, 1), build(part.pair, -1) } end
  if part.across then return { build(part.across, 1, true) } end
  return {}
end

local function drawPart(part, hl, hw)
  love.graphics.setColor(part[1])
  for _, poly in ipairs(partPolygons(part)) do fillCoords(outlineCoords(poly, hl, hw, 0)) end
  if part.trace then
    love.graphics.setLineWidth(part.width or 0.8)
    for _, flip in ipairs({ 1, -1 }) do
      local coords = {}
      for i = 1, #part.trace, 2 do
        coords[#coords + 1] = part.trace[i] * hl
        coords[#coords + 1] = part.trace[i + 1] * flip * hw
      end
      love.graphics.line(coords)
    end
  end
end

local function drawPaint(style, poly, hl, hw)
  if style.open then return drawOpenPaint(poly, hl, hw) end
  if style.parts then return drawPlanPaint(poly, hl, hw) end
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

local function drawDetails(style, hl, hw)
  if style.open then return drawOpenDetails(hl, hw) end
  if style.parts then
    for _, part in ipairs(style.parts) do drawPart(part, hl, hw) end
    return
  end
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
  -- An open load bed behind the cab, ribbed along its floor.
  if style.bed then
    love.graphics.setColor(0.09, 0.09, 0.1)
    quad(hl, hw, -0.25, -0.84, -0.25, 0.84, -0.94, 0.84, -0.94, -0.84)
    love.graphics.setColor(0.17, 0.17, 0.19)
    for y = -0.62, 0.63, 0.31 do
      quad(hl, hw, -0.29, y - 0.05, -0.29, y + 0.05, -0.9, y + 0.05, -0.9, y - 0.05)
    end
  end
  -- Amber marker lights along the front of the roof.
  if style.markers then
    love.graphics.setColor(1, 0.66, 0.12)
    for _, y in ipairs({ -0.3, -0.15, 0, 0.15, 0.3 }) do
      love.graphics.circle("fill", (style.screen[2] - 0.03) * hl, y * hw, 1.8)
    end
  end
  -- A dark lower half, seen as a band down each flank.
  if style.sills then
    love.graphics.setColor(0.07, 0.07, 0.08)
    for _, side in ipairs({ -1, 1 }) do
      quad(hl, hw, 0.96, side * 0.8, 0.96, side * 0.92, -0.96, side * 0.92, -0.96, side * 0.8)
    end
  end
  -- A dark rib from the nose to the tail, with a horseshoe grille on the end.
  if style.spine then
    love.graphics.setColor(0.06, 0.06, 0.08)
    quad(hl, hw, 0.98, -0.07, 0.98, 0.07, -0.98, 0.07, -0.98, -0.07)
    love.graphics.setColor(0.8, 0.8, 0.84)
    love.graphics.ellipse("line", 0.9 * hl, 0, 0.06 * hl, 0.15 * hw)
  end
  -- Scoops in the flanks, behind the doors.
  if style.ducts then
    love.graphics.setColor(0.04, 0.04, 0.05)
    for _, side in ipairs({ -1, 1 }) do
      quad(hl, hw, -0.14, side * 0.97, -0.3, side * 0.68, -0.5, side * 0.68, -0.34, side * 0.97)
    end
  end
  -- Pop-up headlamps, folded flat into the bonnet.
  if style.popups then
    love.graphics.setColor(0, 0, 0, 0.55)
    for _, side in ipairs({ -1, 1 }) do
      love.graphics.rectangle("line", (style.popups[1] - 0.09) * hl, side * style.popups[2] * hw - 0.13 * hw,
        0.18 * hl, 0.26 * hw, 1)
    end
  end
  if style.scoop then
    love.graphics.setColor(0.04, 0.04, 0.05)
    quad(hl, hw, 0.62, -0.2, 0.62, 0.2, 0.5, 0.24, 0.5, -0.24)
  end
  if style.glassRoof then
    love.graphics.setColor(glassA)
    quad(hl, hw, sc[2] - 0.03, -roof * 0.96, sc[2] - 0.03, roof * 0.96, rs[1] + 0.03, roof * 0.96, rs[1] + 0.03, -roof * 0.96)
    love.graphics.setColor(glassB)
    quad(hl, hw, sc[2] - 0.08, -roof * 0.7, sc[2] - 0.08, -roof * 0.1, rs[1] + 0.1, -roof * 0.1, rs[1] + 0.1, -roof * 0.7)
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

local function bodyOutline(style, hl, hw)
  if style.parts then return filletOutline(style.outline, hl, hw, style.corner, RES) end
  return smoothOutline(style.outline)
end

-- Every filled polygon of a car as flat coordinates in sprite px, for the tests.
function sprites.polygons(spec)
  local style = STYLES[spec.bodyStyle] or STYLES.sedan
  local hl, hw = spec.length * RES / 2, spec.width * RES / 2
  local list = { outlineCoords(bodyOutline(style, hl, hw), hl, hw, 0) }
  for _, part in ipairs(style.parts or {}) do
    for _, poly in ipairs(partPolygons(part)) do list[#list + 1] = outlineCoords(poly, hl, hw, 0) end
  end
  return list, hl + 8, hw + 8
end

-- How far the wheels sit from where the physics puts them, in metres, and where
-- the lamps are as fractions of the half length and half width.
function sprites.layout(spec)
  local style = STYLES[spec.bodyStyle] or STYLES.sedan
  return style.axleShift or 0, style.headlamp or { 0.92, 0.66 }, style.taillamp or { 1, 0.62 }
end

function sprites.get(spec)
  sprites.cache = sprites.cache or {}
  local key = spec.id
  if sprites.cache[key] then return sprites.cache[key] end

  local style = STYLES[spec.bodyStyle] or STYLES.sedan
  local hl, hw = spec.length * RES / 2, spec.width * RES / 2
  local poly = bodyOutline(style, hl, hw)
  local width, height = (spec.length * RES + 16) * SHARPNESS, (spec.width * RES + 16) * SHARPNESS

  local function layer(draw)
    local canvas = love.graphics.newCanvas(width, height, { mipmaps = "auto" })
    love.graphics.push("all")
    love.graphics.reset()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.translate(width / 2, height / 2)
    love.graphics.scale(SHARPNESS)
    draw()
    love.graphics.pop()
    canvas:setFilter("linear", "linear")
    canvas:setMipmapFilter("linear")
    return canvas
  end

  local sprite = {
    scale = 12 / RES / SHARPNESS, -- canvas px to world px (see config.METER)
    ox = width / 2, oy = height / 2,
    paint = layer(function() drawPaint(style, poly, hl, hw) end),
    detail = layer(function() drawDetails(style, hl, hw) end),
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
