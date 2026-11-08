-- Turns a Track into meshes. The road is one mesh painted analytically in a
-- shader, so lines and kerbs stay crisp at any camera zoom.
local config = require("src/config")
local textures = require("src/render/textures")
local environment = require("src/render/environment")
local lot = require("src/sim/lot")
local boards = require("src/render/boards")

local renderer = {}

local M = config.METER
local KERB = config.KERB_WIDTH * M
local INK = { 0.15, 0.15, 0.22 }  -- outline colour for anything solid
local STUD_SPACING = 15  -- metres along the road
local STUD_SIZE = 3      -- metres across, with the soft edge of its glow
local STUD_INSET = 0.5   -- metres in from the road's edge, on the painted line
local POOL_SIZE = 70     -- metres across, a lamp on an unlit circuit

-- The size of what's being drawn into: the scene canvas, which is one player's
-- half when two share the screen, or the window.
local function viewSize()
  local canvas = love.graphics.getCanvas()
  if canvas then return canvas:getDimensions() end
  return love.graphics.getDimensions()
end

local ROAD_SHADER = [[
  varying vec2 v_edge;
  varying float v_s;
  varying vec2 v_kerb;
  uniform highp vec3 roadColor;
  uniform highp float trackLength;

  #ifdef VERTEX
  attribute vec2 Edge;
  attribute vec2 KerbFlags;
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    v_edge = Edge;
    v_s = VertexTexCoord.x;
    v_kerb = KerbFlags;
    return transform_projection * vertex_position;
  }
  #endif

  #ifdef PIXEL
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    const float M = ]] .. string.format("%.1f", M) .. [[;
    const vec3 PAINT = vec3(0.98, 0.98, 0.95);
    float dL = v_edge.x, dR = v_edge.y;
    float d = min(dL, dR);

    if (d < 0.0) {
      float kerb = dL < dR ? v_kerb.x : v_kerb.y;
      if (kerb > 0.5) {
        float block = mod(v_s, 4.0 * M) < 2.0 * M ? 1.0 : 0.0;
        return vec4(mix(vec3(0.95, 0.12, 0.16), PAINT, block), 1.0);
      }
      // A thin dark outline stops the road melting into the ground.
      return -d < 7.0 ? vec4(0.15, 0.15, 0.22, 1.0) : vec4(0.0);
    }

    // Bands across the road strobe past and show how fast you are going.
    float band = mod(v_s, 10.0 * M) < 5.0 * M ? 1.0 : 0.0;
    vec3 c = roadColor * (1.0 + band * 0.1);

    float dash = mod(v_s, 12.0 * M) < 5.0 * M ? 1.0 : 0.0;
    if (abs(dL - dR) < 10.0) c = mix(c, PAINT, dash * 0.8);
    if (d > 5.0 && d < 15.0) c = PAINT;

    // Start line chequers
    float s = v_s;
    if (s > trackLength - 5.0 * M) s -= trackLength;
    if (s > -M * 1.6 && s < M * 1.6) {
      float cell = M * 1.0;
      float across = floor(dL / cell), along = floor((s + 100.0 * cell) / cell);
      float check = mod(across + along, 2.0);
      c = vec3(check * 0.94 + 0.04);
    }
    return vec4(c, 1.0);
  }
  #endif
]]

local GROUND_SHADER = [[
  varying vec2 v_world;
  uniform Image noise;
  uniform highp vec3 colorA;
  uniform highp vec3 colorB;
  uniform highp float pattern;

  #ifdef VERTEX
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    v_world = vertex_position.xy;
    return transform_projection * vertex_position;
  }
  #endif

  #ifdef PIXEL
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    float shape = Texel(noise, v_world / 2600.0).r;
    float mix2;
    float shade = 1.0;
    if (pattern < 0.5) {
      mix2 = step(0.5, fract((v_world.x + v_world.y) / 480.0));
      shade = 1.0 + step(0.52, shape) * 0.05;
    } else if (pattern < 1.5) {
      float wave = sin((v_world.x * 0.8 + v_world.y * 0.6) / 62.0 + shape * 16.0);
      mix2 = smoothstep(-0.03, 0.03, wave);
    } else {
      vec2 cell = v_world / 192.0;
      mix2 = mod(floor(cell.x) + floor(cell.y), 2.0);
      vec2 joint = fract(cell);
      shade = joint.x < 0.03 || joint.y < 0.03 ? 0.86 : 1.0;
    }
    return vec4(mix(colorA, colorB, mix2) * shade, 1.0);
  }
  #endif
]]

-- Sand traps are a flat colour with a polka dot of pebbles.
local GRAVEL_SHADER = [[
  varying vec2 v_world;

  #ifdef VERTEX
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    v_world = vertex_position.xy;
    return transform_projection * vertex_position;
  }
  #endif

  #ifdef PIXEL
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec2 cell = v_world / 36.0;
    vec2 p = fract(cell + vec2(0.5 * mod(floor(cell.y), 2.0), 0.0)) - 0.5;
    float dot2 = step(dot(p, p), 0.03);
    return vec4(color.rgb * (1.0 - dot2 * 0.09), color.a * step(0.02, uv.y));
  }
  #endif
]]

local ROAD_FORMAT = {
  { "VertexPosition", "float", 2 },
  { "VertexTexCoord", "float", 2 },
  { "Edge", "float", 2 },
  { "KerbFlags", "float", 2 },
}

local function buildRoad(track)
  local samples, n = track.samples, track.count
  local verts = {}
  local function column(s, along)
    local ex, ey = (s.rx - s.lx) / s.w, (s.ry - s.ly) / s.w
    local kl, kr = s.kerbL and 1 or 0, s.kerbR and 1 or 0
    local w = s.w
    local function add(x, y, dL, dR)
      verts[#verts + 1] = { x, y, along, 0, dL, dR, kl, kr }
    end
    add(s.lx - ex * KERB, s.ly - ey * KERB, -KERB, w + KERB)
    add(s.lx, s.ly, 0, w)
    add(s.rx, s.ry, w, 0)
    add(s.rx + ex * KERB, s.ry + ey * KERB, w + KERB, -KERB)
  end
  for i = 1, n do column(samples[i], samples[i].s) end
  column(samples[1], track.length)

  local indices = {}
  for c = 0, n - 1 do
    local base = c * 4
    for strip = 1, 3 do
      local a, b = base + strip, base + strip + 1
      local d, e = a + 4, b + 4
      indices[#indices + 1] = a
      indices[#indices + 1] = b
      indices[#indices + 1] = e
      indices[#indices + 1] = a
      indices[#indices + 1] = e
      indices[#indices + 1] = d
    end
  end
  local mesh = love.graphics.newMesh(ROAD_FORMAT, verts, "triangles", "static")
  mesh:setVertexMap(indices)
  return mesh
end

local function buildGravel(track, theme)
  local samples, n = track.samples, track.count
  local verts, indices = {}, {}
  local g = theme.gravel
  local function strip(side, key)
    local run = {}
    for i = 1, n + 1 do
      local s = samples[(i - 1) % n + 1]
      if s[key] > 0.5 then
        run[#run + 1] = s
      elseif #run > 0 then
        local base = #verts
        local sign = side == "l" and -1 or 1
        for r, q in ipairs(run) do
          local ex, ey = q[side .. "x"], q[side .. "y"]
          local fade = math.min(1, math.min(r - 1, #run - r) / 4)
          local d = math.min(q[key], q["barrier" .. side] - M * 0.6) + KERB * 0.7
          verts[#verts + 1] = { ex, ey, 0, 1, g[1], g[2], g[3], fade }
          verts[#verts + 1] = { ex + q.nx * sign * d, ey + q.ny * sign * d, 0, 0, g[1], g[2], g[3], fade }
          if r < #run then
            local v = base + (r - 1) * 2 + 1
            indices[#indices + 1] = v
            indices[#indices + 1] = v + 1
            indices[#indices + 1] = v + 3
            indices[#indices + 1] = v
            indices[#indices + 1] = v + 3
            indices[#indices + 1] = v + 2
          end
        end
        run = {}
      end
    end
  end
  strip("l", "gravelL")
  strip("r", "gravelR")
  if #verts < 3 then return nil end
  local mesh = love.graphics.newMesh(verts, "triangles", "static")
  mesh:setVertexMap(indices)
  return mesh
end

local function barrierMesh(points, theme, halfWidth, shift, open)
  local verts, indices = {}, {}
  local n = #points
  local segment = 0
  for i = 1, open and n - 1 or n do
    local a, b = points[i], points[i % n + 1]
    local dx, dy = b.x - a.x, b.y - a.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0.01 then
      dx, dy = dx / len, dy / len
      local nx, ny = -dy * halfWidth, dx * halfWidth
      local band = math.floor(segment / 3) % 2 == 0 and theme.barrierA or theme.barrierB
      segment = segment + 1
      local base = #verts
      local ox, oy = shift and shift[1] or 0, shift and shift[2] or 0
      local function add(x, y)
        verts[#verts + 1] = { x + ox, y + oy, 0, 0, band[1], band[2], band[3], 1 }
      end
      add(a.x + nx, a.y + ny)
      add(a.x - nx, a.y - ny)
      add(b.x - nx, b.y - ny)
      add(b.x + nx, b.y + ny)
      for _, k in ipairs({ 1, 2, 3, 1, 3, 4 }) do indices[#indices + 1] = base + k end
    end
  end
  local mesh = love.graphics.newMesh(verts, "triangles", "static")
  mesh:setVertexMap(indices)
  return mesh
end

-- Flat coloured rectangles, baked into one mesh. Drawing them one at a time costs
-- a slow phone more than the rest of the world put together. frame is an optional
-- { x, y, angle } the rectangle is placed in.
local function addRect(rects, x, y, w, h, c, alpha, frame)
  rects[#rects + 1] = { x = x, y = y, w = w, h = h, c = c, alpha = alpha or 1, frame = frame }
end

local function rectMesh(rects)
  if #rects == 0 then return nil end
  local verts, indices = {}, {}
  for _, r in ipairs(rects) do
    local c, f = r.c, r.frame
    local ox, oy, ca, sa = 0, 0, 1, 0
    if f then ox, oy, ca, sa = f[1], f[2], math.cos(f[3]), math.sin(f[3]) end
    local base = #verts
    local function corner(x, y)
      verts[#verts + 1] = { ox + x * ca - y * sa, oy + x * sa + y * ca, 0, 0, c[1], c[2], c[3], r.alpha }
    end
    corner(r.x, r.y)
    corner(r.x + r.w, r.y)
    corner(r.x + r.w, r.y + r.h)
    corner(r.x, r.y + r.h)
    for _, k in ipairs({ 1, 2, 3, 1, 3, 4 }) do indices[#indices + 1] = base + k end
  end
  local mesh = love.graphics.newMesh(verts, "triangles", "static")
  mesh:setVertexMap(indices)
  return mesh
end

local function outsideRoad(track, x, y, clearance)
  local i, _, _, off, side = track:locate(x, y)
  if off <= 0 then return false end
  local s = track.samples[i]
  local barrier = side == "l" and s.barrierl or s.barrierr
  return off > barrier + clearance
end

-- Trees and containers stand this far clear of a sponsor board, so the board shows.
local BOARD_CLEARANCE = 6.5 * M

local function scatter(track, theme, rng, boardList)
  local b = track.bounds
  local margin = 80 * M
  local items = {}
  local attempts = theme.scenery == "containers" and 320 or 3000
  for _ = 1, attempts do
    local x = rng:random(b.minX - margin, b.maxX + margin)
    local y = rng:random(b.minY - margin, b.maxY + margin)
    -- Clumps read as woodland; a pure random spread reads as confetti.
    local clump = love.math.noise(x / 1400, y / 1400)
    if clump > 0.34 and outsideRoad(track, x, y, 3 * M) and not boards.near(boardList, x, y, BOARD_CLEARANCE) then
      items[#items + 1] = { x = x, y = y, spin = rng:random() * math.pi * 2, s = 0.75 + rng:random() * 0.7 }
    end
  end
  return items
end

local function buildScenery(track, theme, rng, boardList)
  local items = scatter(track, theme, rng, boardList)
  local batches = {}
  -- Canopies have the sun painted on, so only palms may spin.
  local function add(image, item, size, angle)
    batches[image] = batches[image] or love.graphics.newSpriteBatch(image, 3000, "static")
    local w, h = image:getDimensions()
    local scale = size * item.s / w
    batches[image]:add(item.x, item.y, angle or 0, scale, scale, w / 2, h / 2)
  end

  local boxes = {}
  if theme.scenery == "trees" then
    for i, item in ipairs(items) do add(textures.tree[i % 3 + 1], item, 8.5 * M) end
  elseif theme.scenery == "palms" then
    for i, item in ipairs(items) do
      if i % 2 == 0 then add(textures.palm, item, 7 * M, item.spin)
      else add(textures.shrub, item, 3 * M) end
    end
  else
    -- Stacks of shipping containers, squared up with the quay.
    local colors = { { 0.93, 0.2, 0.2 }, { 0.1, 0.5, 0.92 }, { 0.98, 0.72, 0.1 }, { 0.12, 0.72, 0.5 }, { 0.95, 0.95, 0.97 } }
    for i, item in ipairs(items) do
      if i % 2 == 0 then
        local stack = math.floor(item.x / 240) * 240 + 120
        local row = math.floor(item.y / 90) * 90 + 45
        boxes[stack .. ":" .. row] = { x = stack, y = row, color = colors[(i % #colors) + 1], h = 1 + i % 3 }
      end
    end
  end
  local list = {}
  for _, box in pairs(boxes) do
    if outsideRoad(track, box.x, box.y, 7 * M) and not boards.near(boardList, box.x, box.y, BOARD_CLEARANCE) then
      list[#list + 1] = box
    end
  end
  return batches, list
end

local function grandstandSpot(track)
  -- The longest straight on the start side gets the crowd.
  local s = track.samples[(track.count - 8) % track.count + 1]
  local side = s.barrierr >= s.barrierl and "r" or "l"
  local sign = side == "r" and 1 or -1
  local depth = s["barrier" .. side] + s.w / 2 + 3.5 * M
  return {
    x = s.x + s.nx * sign * depth,
    y = s.y + s.ny * sign * depth,
    angle = math.atan2(s.ty, s.tx),
  }
end

local STAND_W, STAND_H = 62 * M, 8 * M

-- Every sponsor board on the track, numbered; see src/render/boards.lua.
function renderer.boardSpots(track)
  local st = grandstandSpot(track)
  return boards.place(track, { { x = st.x, y = st.y, angle = st.angle, len = STAND_W, depth = STAND_H } })
end

local function buildGridBoxes(track)
  local rects = {}
  local paint = { 0.92, 0.92, 0.88 }
  local w, near, far, thick = 1.3 * M, 3.2 * M, 3.6 * M, 2
  for slot = 1, 6 do
    local x, y, angle = track:gridSlot(slot)
    local frame = { x, y, angle }
    addRect(rects, near, -w - thick / 2, far - near + thick / 2, thick, paint, 0.8, frame)
    addRect(rects, far - thick / 2, -w + thick / 2, thick, w * 2 - thick, paint, 0.8, frame)
    addRect(rects, near, w - thick / 2, far - near + thick / 2, thick, paint, 0.8, frame)
  end
  return rectMesh(rects)
end

local function buildBoxes(boxes, env)
  local rects = {}
  local sx, sy = env.sun[1] * env.shadowLength, env.sun[2] * env.shadowLength
  local w, h, edge = 12.2 * M, 2.5 * M, 1.5
  for _, box in ipairs(boxes) do
    local x, y = box.x - w / 2, box.y - h / 2
    addRect(rects, x + sx * box.h * 1.6, y + sy * box.h * 1.6, w, h, { 0, 0, 0 }, env.shadowAlpha)
    addRect(rects, x - edge, y - edge, w + edge * 2, h + edge * 2, INK)
    addRect(rects, x + edge, y + edge, w - edge * 2, h - edge * 2, box.color)
  end
  return rectMesh(rects)
end

local function buildStand(st, env)
  local CROWD = { { 0.98, 0.25, 0.25 }, { 0.2, 0.55, 0.98 }, { 0.99, 0.85, 0.2 }, { 0.98, 0.98, 0.98 }, { 0.98, 0.45, 0.75 } }
  local rects = {}
  local frame = { st.x, st.y, st.angle }
  local w, h = STAND_W, STAND_H
  addRect(rects, -w / 2 + 12, -h / 2 + 12, w, h, { 0, 0, 0 }, env.shadowAlpha, frame)
  addRect(rects, -w / 2, -h / 2, w, h, { 0.32, 0.36, 0.5 }, 1, frame)
  local rng = love.math.newRandomGenerator(5)
  for row = 0, 9 do
    for col = 0, 150 do
      if rng:random() > 0.2 then
        local c = CROWD[rng:random(1, #CROWD)]
        addRect(rects, -w / 2 + 6 + col * (w - 12) / 150, -h / 2 + 5 + row * (h - 8) / 10, 3, 3, c, 1, frame)
      end
    end
  end
  return rectMesh(rects)
end

-- Where the road studs go: along both edges of the road, as { x, y, side }.
function renderer.studSpots(track)
  local spots = {}
  local stride = math.max(1, math.floor(STUD_SPACING / config.SAMPLE_SPACING))
  for i = 1, track.count, stride do
    local s = track.samples[i]
    local reach = s.w / 2 - STUD_INSET * M
    spots[#spots + 1] = { x = s.x - s.nx * reach, y = s.y - s.ny * reach, side = -1 }
    spots[#spots + 1] = { x = s.x + s.nx * reach, y = s.y + s.ny * reach, side = 1 }
  end
  return spots
end

-- Studs are drawn into the lightmap, so what shows is the paint they sit on: amber
-- down one edge and white down the other, to tell the sides apart in a spin.
local function buildStuds(track)
  textures.load()
  local spots = renderer.studSpots(track)
  local batch = love.graphics.newSpriteBatch(textures.blob, #spots, "static")
  local scale = STUD_SIZE * M / textures.blob:getWidth()
  for _, spot in ipairs(spots) do
    if spot.side < 0 then batch:setColor(1, 0.68, 0.22, 1) else batch:setColor(0.9, 0.95, 1, 1) end
    batch:add(spot.x, spot.y, 0, scale, scale, 32, 32)
  end
  return batch
end

-- trackName is a built-in track's name, which its sold boards are filed under;
-- nil for one of the player's own.
function renderer.load(track, timeName, trackName)
  textures.load()
  local self = {}
  self.track = track
  self.theme = environment.theme(track.theme)
  self.env = environment.time(timeName)

  self.roadShader = renderer.roadShader or love.graphics.newShader(ROAD_SHADER)
  self.groundShader = renderer.groundShader or love.graphics.newShader(GROUND_SHADER)
  self.gravelShader = renderer.gravelShader or love.graphics.newShader(GRAVEL_SHADER)
  renderer.roadShader, renderer.groundShader, renderer.gravelShader =
    self.roadShader, self.groundShader, self.gravelShader

  self.road = buildRoad(track)
  self.gravel = buildGravel(track, self.theme)
  self.barrierL = barrierMesh(track.barrierL, self.theme, config.BARRIER_THICKNESS * M / 2)
  self.barrierR = barrierMesh(track.barrierR, self.theme, config.BARRIER_THICKNESS * M / 2)
  local ink = { barrierA = INK, barrierB = INK }
  self.barrierEdgeL = barrierMesh(track.barrierL, ink, config.BARRIER_THICKNESS * M / 2 + 2.5)
  self.barrierEdgeR = barrierMesh(track.barrierR, ink, config.BARRIER_THICKNESS * M / 2 + 2.5)

  local sun = self.env.sun
  local len = self.env.shadowLength
  local shift = { sun[1] * len, sun[2] * len }
  local dark = { barrierA = { 0, 0, 0 }, barrierB = { 0, 0, 0 } }
  self.barrierShadowL = barrierMesh(track.barrierL, dark, config.BARRIER_THICKNESS * M / 2 + 1, shift)
  self.barrierShadowR = barrierMesh(track.barrierR, dark, config.BARRIER_THICKNESS * M / 2 + 1, shift)

  local b = track.bounds
  local pad = 220 * M
  self.ground = love.graphics.newMesh({
    { b.minX - pad, b.minY - pad, 0, 0 },
    { b.maxX + pad, b.minY - pad, 1, 0 },
    { b.maxX + pad, b.maxY + pad, 1, 1 },
    { b.minX - pad, b.maxY + pad, 0, 1 },
  }, "fan", "static")

  local rng = love.math.newRandomGenerator(track.count * 7 + 3)
  local boardList = renderer.boardSpots(track)
  self.boards = boards.build(boardList, trackName, track.title, self.env, addRect, rectMesh)
  self.batches, self.boxes = buildScenery(track, self.theme, rng, boardList)
  self.gridBoxes = buildGridBoxes(track)
  self.boxMesh = buildBoxes(self.boxes, self.env)
  self.standMesh = buildStand(grandstandSpot(track), self.env)

  -- Floodlights around the lap for night racing.
  self.floods = {}
  local stride = math.floor(55 / config.SAMPLE_SPACING)
  for i = 1, track.count, stride do
    local s = track.samples[i]
    local side = (math.floor(i / stride) % 2 == 0) and "l" or "r"
    local sign = side == "l" and -1 or 1
    local d = s.w / 2 + s["barrier" .. side] + M * 1.2
    self.floods[#self.floods + 1] = { x = s.x + s.nx * sign * d, y = s.y + s.ny * sign * d, nx = -s.nx * sign, ny = -s.ny * sign }
  end

  local start = track.samples[1]
  self.start = { x = start.x, y = start.y, angle = math.atan2(start.ty, start.tx), w = start.w }
  -- Unlit circuits still light the grid, which marks every lap.
  self.pools = { { x = start.x, y = start.y } }
  if self.env.studs then self.studs = buildStuds(track) end
  return setmetatable(self, { __index = renderer })
end

-- The ground under everything, painted by its shader for the theme.
local function drawGroundPlane(self)
  local shader = self.groundShader
  shader:send("noise", textures.noise)
  shader:send("colorA", self.theme.groundA)
  shader:send("colorB", self.theme.groundB)
  shader:send("pattern", self.theme.pattern)
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(self.ground)
  love.graphics.setShader()
end

-- The playground's containers, baked like the quay's: shadow, ink, then paint.
local LOT_COLORS = { { 0.93, 0.2, 0.2 }, { 0.1, 0.5, 0.92 }, { 0.98, 0.72, 0.1 }, { 0.12, 0.72, 0.5 }, { 0.95, 0.95, 0.97 } }

local function lotBlocks(layout, env)
  local rects = {}
  local sx, sy = env.sun[1] * env.shadowLength * 3, env.sun[2] * env.shadowLength * 3
  local cw, ch, edge = lot.CONTAINER_W, lot.CONTAINER_H, 1.5
  local n = 0
  for _, b in ipairs(layout.blocks) do
    addRect(rects, b.x + sx, b.y + sy, b.w, b.h, { 0, 0, 0 }, env.shadowAlpha)
    addRect(rects, b.x - edge, b.y - edge, b.w + edge * 2, b.h + edge * 2, INK)
    for c = 0, b.cols - 1 do
      for r = 0, b.rows - 1 do
        n = n + 1
        local x, y = b.x + c * cw, b.y + r * ch
        addRect(rects, x + edge, y + edge, cw - edge * 2, ch - edge * 2, LOT_COLORS[(n * 3) % #LOT_COLORS + 1])
      end
    end
  end
  return rectMesh(rects)
end

local function lotWall(self, layout)
  local half = lot.WALL_HALF
  local paint = { barrierA = { 0.98, 0.98, 0.96 }, barrierB = { 0.93, 0.13, 0.18 } }
  local ink = { barrierA = INK, barrierB = INK }
  local dark = { barrierA = { 0, 0, 0 }, barrierB = { 0, 0, 0 } }
  local sun, len = self.env.sun, self.env.shadowLength
  self.wall = barrierMesh(layout.wall, paint, half, nil, true)
  self.wallEdge = barrierMesh(layout.wall, ink, half + 2.5, nil, true)
  self.wallShadow = barrierMesh(layout.wall, dark, half + 1, { sun[1] * len, sun[2] * len }, true)
end

-- Painted markings: the start box, the donut ring and the slalom's line.
local function drawLotPaint(layout)
  love.graphics.setColor(0.98, 0.98, 0.96, 0.85)
  love.graphics.setLineWidth(4)
  local b = layout.startBox
  love.graphics.rectangle("line", b.x, b.y, b.w, b.h)
  local d = layout.donut
  love.graphics.circle("line", d.x, d.y, d.ring, 64)
  love.graphics.circle("line", d.x, d.y, d.ring + 6 * M, 64)
  local sl = layout.slalom
  love.graphics.setColor(0.98, 0.82, 0.12, 0.9)
  for y = sl.fromY, sl.toY, -4 * M do
    love.graphics.line(sl.x, y, sl.x, y - 2 * M)
  end
end

local function drawPillars(layout, env)
  local sx, sy = env.sun[1] * env.shadowLength * 2, env.sun[2] * env.shadowLength * 2
  for _, p in ipairs(layout.pillars) do
    love.graphics.setColor(0, 0, 0, env.shadowAlpha)
    love.graphics.circle("fill", p.x + sx, p.y + sy, p.r)
    love.graphics.setColor(INK)
    love.graphics.circle("fill", p.x, p.y, p.r + 2.5)
    -- A stack of tyres, looked down on: rings, with the hole in the middle.
    for i, shade in ipairs({ 0.2, 0.28, 0.2, 0.28 }) do
      love.graphics.setColor(shade, shade, shade + 0.03)
      love.graphics.circle("fill", p.x, p.y, p.r * (1 - (i - 1) * 0.16))
    end
    love.graphics.setColor(0.93, 0.13, 0.18)
    love.graphics.setLineWidth(3)
    love.graphics.circle("line", p.x, p.y, p.r * 0.72)
    love.graphics.setColor(0.06, 0.06, 0.08)
    love.graphics.circle("fill", p.x, p.y, p.r * 0.3)
  end
end

-- Freestyle has no circuit: just a huge concrete apron with worn paint, and the
-- playground in the middle of it.
function renderer.loadApron(timeName)
  textures.load()
  local self = {}
  self.theme = {
    groundA = { 0.42, 0.46, 0.58 }, groundB = { 0.38, 0.42, 0.54 }, pattern = 2,
    dust = { 0.8, 0.82, 0.86 },
  }
  self.env = environment.time(timeName)
  self.groundShader = renderer.groundShader or love.graphics.newShader(GROUND_SHADER)
  renderer.groundShader = self.groundShader
  local extent = 12000 * M
  self.ground = love.graphics.newMesh({
    { -extent, -extent, 0, 0 }, { extent, -extent, 1, 0 },
    { extent, extent, 1, 1 }, { -extent, extent, 0, 1 },
  }, "fan", "static")

  self.layout = lot.layout()
  lotWall(self, self.layout)
  self.blockMesh = lotBlocks(self.layout, self.env)

  self.floods, self.pools = {}, {}
  for x = -8, 8 do
    for y = -8, 8 do
      self.floods[#self.floods + 1] = { x = x * 70 * M, y = y * 70 * M, nx = 0, ny = 0 }
      -- Scattered lamps, for something to drive around in the dark.
      if x % 3 == 0 and y % 3 == 0 then self.pools[#self.pools + 1] = { x = x * 70 * M, y = y * 70 * M } end
    end
  end

  function self:drawGround()
    drawGroundPlane(self)

    -- Painted bays around wherever the camera is looking.
    local vw, vh = viewSize()
    local tx, ty = love.graphics.inverseTransformPoint(vw / 2, vh / 2)
    local cell = 40 * M
    local reach = 5
    local cx, cy = math.floor(tx / cell), math.floor(ty / cell)
    love.graphics.setLineWidth(5)
    love.graphics.setColor(0.98, 0.82, 0.12, 0.9)
    for i = -reach, reach do
      local x, y = (cx + i) * cell, (cy + i) * cell
      love.graphics.line(x, (cy - reach) * cell, x, (cy + reach) * cell)
      love.graphics.line((cx - reach) * cell, y, (cx + reach) * cell, y)
    end

    drawLotPaint(self.layout)
    love.graphics.setColor(1, 1, 1, self.env.shadowAlpha * 0.9)
    love.graphics.draw(self.wallShadow)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(self.wallEdge)
    love.graphics.draw(self.wall)
    love.graphics.draw(self.blockMesh)
    drawPillars(self.layout, self.env)
  end

  -- Cones move, so they're drawn where they are, and only near the screen.
  function self:drawCones(cones)
    local sw, sh = viewSize()
    local cx, cy = love.graphics.inverseTransformPoint(sw / 2, sh / 2)
    local ex, ey = love.graphics.inverseTransformPoint(0, 0)
    local reach = (ex - cx) ^ 2 + (ey - cy) ^ 2 + (4 * M) ^ 2
    local env = self.env
    local sx, sy = env.sun[1] * env.shadowLength * 0.8, env.sun[2] * env.shadowLength * 0.8
    local r = lot.CONE_RADIUS
    for _, cone in ipairs(cones) do
      local x, y = cone.body:getPosition()
      if (x - cx) ^ 2 + (y - cy) ^ 2 < reach then
        love.graphics.setColor(0, 0, 0, env.shadowAlpha)
        -- Drawn bigger than it is to hit, so it reads from the chase camera.
        love.graphics.circle("fill", x + sx, y + sy, r * 2)
        love.graphics.setColor(INK)
        love.graphics.circle("fill", x, y, r * 2 + 2)
        love.graphics.setColor(1, 0.45, 0.08)
        love.graphics.circle("fill", x, y, r * 2)
        love.graphics.setColor(0.98, 0.98, 0.96)
        love.graphics.circle("fill", x, y, r * 1.3)
        love.graphics.setColor(1, 0.45, 0.08)
        love.graphics.circle("fill", x, y, r * 0.75)
      end
    end
  end
  function self:drawOverhead() end
  function self:drawGlow() end
  self.drawLights = renderer.drawLights
  return self
end

-- Everything under the cars.
function renderer:drawGround()
  drawGroundPlane(self)

  if self.gravel then
    love.graphics.setShader(self.gravelShader)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(self.gravel)
    love.graphics.setShader()
  end

  local road = self.roadShader
  road:send("roadColor", self.theme.road)
  road:send("trackLength", self.track.length)
  love.graphics.setShader(road)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(self.road)
  love.graphics.setShader()

  love.graphics.draw(self.gridBoxes)

  love.graphics.setColor(1, 1, 1, self.env.shadowAlpha * 0.9)
  love.graphics.draw(self.barrierShadowL)
  love.graphics.draw(self.barrierShadowR)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(self.barrierEdgeL)
  love.graphics.draw(self.barrierEdgeR)
  love.graphics.draw(self.barrierL)
  love.graphics.draw(self.barrierR)
  boards.draw(self.boards)

  -- Scenery shadows, then the scenery itself.
  local env = self.env
  local sx, sy = env.sun[1] * env.shadowLength * 1.8, env.sun[2] * env.shadowLength * 1.8
  love.graphics.setColor(0, 0, 0, env.shadowAlpha)
  for _, batch in pairs(self.batches) do love.graphics.draw(batch, sx, sy) end
  love.graphics.setColor(1, 1, 1)
  for _, batch in pairs(self.batches) do love.graphics.draw(batch) end
  if self.boxMesh then love.graphics.draw(self.boxMesh) end
  love.graphics.draw(self.standMesh)
end

-- The start gantry passes over the top of the cars.
function renderer:drawOverhead(lightsOn, lightsOut)
  local st = self.start
  local env = self.env
  love.graphics.push()
  love.graphics.translate(st.x, st.y)
  love.graphics.rotate(st.angle)
  local span = st.w / 2 + 2 * M
  local sx = env.sun[1] * 16
  love.graphics.setColor(0, 0, 0, env.shadowAlpha)
  love.graphics.rectangle("fill", -M * 0.5 + sx, -span, M, span * 2)
  love.graphics.setColor(0.16, 0.17, 0.2)
  love.graphics.rectangle("fill", -M * 0.5, -span, M, span * 2)
  love.graphics.setColor(0.3, 0.31, 0.35)
  love.graphics.setLineWidth(2)
  for y = -span, span, M * 1.2 do
    love.graphics.line(-M * 0.5, y, M * 0.5, y + M * 0.6)
  end
  for i = 1, 5 do
    local y = (i - 3) * M * 1.1
    love.graphics.setColor(0.03, 0.03, 0.04)
    love.graphics.rectangle("fill", -M * 0.45, y - M * 0.45, M * 0.9, M * 0.9, 2)
    local on = lightsOn and lightsOn >= i and not lightsOut
    if on then love.graphics.setColor(1, 0.1, 0.08) else love.graphics.setColor(0.24, 0.05, 0.05) end
    love.graphics.circle("fill", 0, y, M * 0.3)
  end
  love.graphics.pop()
end

function renderer:drawGlow(lightsOn, lightsOut)
  if not lightsOn or lightsOut then return end
  local st = self.start
  local ca, sa = math.cos(st.angle), math.sin(st.angle)
  for i = 1, lightsOn do
    local y = (i - 3) * M * 1.1
    love.graphics.setColor(1, 0.12, 0.06, 1)
    local size = M * 3 / textures.blob:getWidth()
    love.graphics.draw(textures.blob, st.x - sa * y, st.y + ca * y, 0, size, size, 32, 32)
  end
end

-- The lamps never move, so the first night frame bakes them into one batch:
-- floodlights on a floodlit circuit, pools of light on an unlit one.
local function lampBatch(self)
  if self.lamps then return self.lamps end
  local blob = textures.blob
  local floodlit = self.env.floodlit
  local list = floodlit and self.floods or self.pools
  local batch = love.graphics.newSpriteBatch(blob, math.max(1, #list), "static")
  if floodlit then
    local scale = 62 * M / blob:getWidth()
    batch:setColor(0.78, 0.74, 0.62, 1)
    for _, f in ipairs(list) do batch:add(f.x + f.nx * 12 * M, f.y + f.ny * 12 * M, 0, scale, scale, 32, 32) end
  else
    local scale = POOL_SIZE * M / blob:getWidth()
    batch:setColor(0.62, 0.6, 0.52, 1)
    for _, p in ipairs(list) do batch:add(p.x, p.y, 0, scale, scale, 32, 32) end
  end
  self.lamps = batch
  return batch
end

function renderer:drawLights()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(lampBatch(self))
  if not self.env.floodlit and self.studs then love.graphics.draw(self.studs) end
end

return renderer
