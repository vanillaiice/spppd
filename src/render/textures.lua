-- Procedural textures: nothing here needs an asset file.
local textures = {}

local function soft(size, falloff)
  local data = love.image.newImageData(size, size)
  local c = (size - 1) / 2
  data:mapPixel(function(x, y)
    local d = math.sqrt((x - c) ^ 2 + (y - c) ^ 2) / c
    local a = math.max(0, 1 - d)
    a = a ^ falloff
    return 1, 1, 1, a
  end)
  return love.graphics.newImage(data)
end

-- Periodic value noise so it tiles across the whole circuit.
local function tilingNoise(size, baseCells, octaves)
  local data = love.image.newImageData(size, size)
  local lattices = {}
  for o = 1, octaves do
    local cells = baseCells * 2 ^ (o - 1)
    local grid = {}
    for i = 0, cells * cells - 1 do grid[i] = love.math.random() end
    lattices[o] = { cells = cells, grid = grid }
  end
  local function sample(l, x, y)
    local cells = l.cells
    local fx, fy = x * cells, y * cells
    local x0, y0 = math.floor(fx), math.floor(fy)
    local tx, ty = fx - x0, fy - y0
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    local function g(ix, iy) return l.grid[(ix % cells) + (iy % cells) * cells] end
    local a = g(x0, y0) + (g(x0 + 1, y0) - g(x0, y0)) * tx
    local b = g(x0, y0 + 1) + (g(x0 + 1, y0 + 1) - g(x0, y0 + 1)) * tx
    return a + (b - a) * ty
  end
  data:mapPixel(function(x, y)
    local u, v = x / size, y / size
    local total, amp, norm = 0, 1, 0
    for o = 1, octaves do
      total = total + sample(lattices[o], u, v) * amp
      norm = norm + amp
      amp = amp * 0.55
    end
    local n = total / norm
    -- R: broad fbm, G: fine grain, B: blotches
    local grain = love.math.random()
    local blotch = sample(lattices[math.min(2, octaves)], u, v)
    return n, grain, blotch, 1
  end)
  local image = love.graphics.newImage(data, { mipmaps = true })
  image:setWrap("repeat", "repeat")
  image:setFilter("linear", "linear")
  image:setMipmapFilter("linear")
  return image
end

local function canopy(size, green)
  local data = love.image.newImageData(size, size)
  local c = (size - 1) / 2
  local lobes = {}
  for i = 1, 9 do
    local a = i / 9 * math.pi * 2 + love.math.random() * 0.4
    local r = c * (0.42 + love.math.random() * 0.18)
    lobes[i] = { x = c + math.cos(a) * r, y = c + math.sin(a) * r, r = c * (0.36 + love.math.random() * 0.14) }
  end
  lobes[#lobes + 1] = { x = c, y = c, r = c * 0.62 }
  data:mapPixel(function(x, y)
    local h = 0
    for _, l in ipairs(lobes) do
      local d = math.sqrt((x - l.x) ^ 2 + (y - l.y) ^ 2) / l.r
      if d < 1 then h = math.max(h, math.sqrt(1 - d * d)) end
    end
    if h <= 0 then return 0, 0, 0, 0 end
    local n = love.math.noise(x * 0.11, y * 0.11) * 0.5 + love.math.noise(x * 0.31, y * 0.31) * 0.5
    local sun = ((c - x) + (c - y)) / (2 * c) -- light from the top left
    local light = 0.42 + h * 0.34 + n * 0.3 + sun * 0.22
    return green[1] * light, green[2] * light, green[3] * light, math.min(1, h * 5)
  end)
  local image = love.graphics.newImage(data, { mipmaps = true })
  image:setFilter("linear", "linear")
  return image
end

local function palm(size)
  local canvas = love.graphics.newCanvas(size, size, { mipmaps = "auto" })
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setBlendMode("alpha")
  local c = size / 2
  for i = 1, 11 do
    local a = i / 11 * math.pi * 2 + love.math.random() * 0.3
    local len = c * (0.72 + love.math.random() * 0.24)
    local shade = 0.72 + love.math.random() * 0.34
    love.graphics.setColor(0.23 * shade, 0.40 * shade, 0.16 * shade)
    local steps = 8
    for s = 0, steps do
      local t = s / steps
      local r = len * t
      local w = c * 0.15 * math.sin(t * math.pi) + 0.6
      love.graphics.circle("fill", c + math.cos(a + t * 0.25) * r, c + math.sin(a + t * 0.25) * r, w)
    end
  end
  love.graphics.setColor(0.33, 0.25, 0.14)
  love.graphics.circle("fill", c, c, c * 0.1)
  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1)
  canvas:setFilter("linear", "linear")
  return canvas
end

-- Headlight pool: bright near the car, spreading and fading with distance.
local function beam(w, h)
  local data = love.image.newImageData(w, h)
  local cy = (h - 1) / 2
  data:mapPixel(function(x, y)
    local t = x / (w - 1)
    local spread = (y - cy) / cy
    local cone = 1 - math.min(1, math.abs(spread) / (0.1 + t * 0.9))
    local a = (cone ^ 1.4) * (1 - t) ^ 1.3 * math.min(1, t * 9 + 0.2)
    return 1, 1, 1, a
  end)
  return love.graphics.newImage(data)
end

function textures.load()
  if textures.loaded then return end
  textures.loaded = true
  love.math.setRandomSeed(1234)
  textures.blob = soft(64, 2.0)
  textures.smoke = soft(64, 1.1)
  textures.spark = soft(16, 1.5)
  textures.noise = tilingNoise(256, 8, 4)
  textures.tree = { canopy(96, { 0.2, 0.37, 0.15 }), canopy(96, { 0.16, 0.33, 0.17 }), canopy(96, { 0.27, 0.4, 0.15 }) }
  textures.shrub = canopy(64, { 0.42, 0.42, 0.22 })
  textures.palm = palm(128)
  textures.beam = beam(256, 128)
  love.math.setRandomSeed(os.time())
end

return textures
