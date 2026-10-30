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

-- A cartoon tree top: round lobes, three flat tones and a dark outline.
local function canopy(size, green)
  local data = love.image.newImageData(size, size)
  local c = (size - 1) / 2
  local lobes = {}
  for i = 1, 7 do
    local a = i / 7 * math.pi * 2 + love.math.random() * 0.4
    local r = c * (0.46 + love.math.random() * 0.12)
    lobes[i] = { x = c + math.cos(a) * r, y = c + math.sin(a) * r, r = c * (0.36 + love.math.random() * 0.08) }
  end
  lobes[#lobes + 1] = { x = c, y = c, r = c * 0.66 }
  data:mapPixel(function(x, y)
    local h = 0
    for _, l in ipairs(lobes) do
      local d = math.sqrt((x - l.x) ^ 2 + (y - l.y) ^ 2) / l.r
      if d < 1 then h = math.max(h, 1 - d) end
    end
    if h <= 0 then return 0, 0, 0, 0 end
    if h < 0.1 then return 0.08, 0.2, 0.14, 1 end
    local sun = ((c - x) + (c - y)) / (2 * c) -- light from the top left
    local light = h + sun * 0.7
    local tone = light > 0.62 and 1.3 or (light > 0.2 and 1 or 0.72)
    return green[1] * tone, green[2] * tone, green[3] * tone, 1
  end)
  local image = love.graphics.newImage(data, { mipmaps = true })
  image:setFilter("linear", "linear")
  return image
end

local function palm(size)
  local canvas = love.graphics.newCanvas(size, size)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setBlendMode("alpha")
  local c = size / 2
  local function frond(a, len, width)
    for s = 0, 10 do
      local t = s / 10
      local r = len * t
      local w = c * width * math.sin(t * math.pi * 0.9 + 0.1) + 0.6
      love.graphics.circle("fill", c + math.cos(a + t * 0.3) * r, c + math.sin(a + t * 0.3) * r, w)
    end
  end
  for i = 1, 8 do
    local a = i / 8 * math.pi * 2
    love.graphics.setColor(0.04, 0.3, 0.2)
    frond(a, c * 0.96, 0.2)
  end
  for i = 1, 8 do
    local a = i / 8 * math.pi * 2
    love.graphics.setColor(i % 2 == 0 and { 0.1, 0.72, 0.36 } or { 0.2, 0.84, 0.36 })
    frond(a, c * 0.9, 0.15)
  end
  love.graphics.setColor(0.72, 0.42, 0.16)
  love.graphics.circle("fill", c, c, c * 0.11)
  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1)
  local image = love.graphics.newImage(canvas:newImageData(), { mipmaps = true })
  image:setFilter("linear", "linear")
  canvas:release()
  return image
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
  textures.tree = { canopy(128, { 0.1, 0.58, 0.3 }), canopy(128, { 0.08, 0.5, 0.36 }), canopy(128, { 0.26, 0.62, 0.2 }) }
  textures.shrub = canopy(96, { 0.5, 0.68, 0.2 })
  textures.palm = palm(128)
  textures.beam = beam(256, 128)
  love.math.setRandomSeed(os.time())
end

return textures
