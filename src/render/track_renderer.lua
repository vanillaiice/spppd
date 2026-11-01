-- Turns a Track into meshes. The road is one mesh painted analytically in a
-- shader, so lines and kerbs stay crisp at any camera zoom.
local config = require("src/config")
local textures = require("src/render/textures")
local environment = require("src/render/environment")

local renderer = {}

local M = config.METER
local KERB = config.KERB_WIDTH * M
local INK = { 0.15, 0.15, 0.22 }  -- outline colour for anything solid

local ROAD_SHADER = [[
  varying vec3 v_edge;
  varying float v_s;
  varying vec2 v_kerb;
  uniform highp vec3 roadColor;
  uniform highp float trackLength;

  #ifdef VERTEX
  attribute vec3 Edge;
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
    const float M = 12.0;
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
  { "Edge", "float", 3 },
  { "KerbFlags", "float", 2 },
}

local function lineOffset(s)
  local dx, dy = s.lineX - s.lx, s.lineY - s.ly
  local ex, ey = (s.rx - s.lx) / s.w, (s.ry - s.ly) / s.w
  return dx * ex + dy * ey
end

local function buildRoad(track)
  local samples, n = track.samples, track.count
  local verts = {}
  local function column(s, along)
    local ex, ey = (s.rx - s.lx) / s.w, (s.ry - s.ly) / s.w
    local kl, kr = s.kerbL and 1 or 0, s.kerbR and 1 or 0
    local line = lineOffset(s)
    local w = s.w
    local function add(x, y, dL, dR)
      verts[#verts + 1] = { x, y, along, 0, dL, dR, dL - line, kl, kr }
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

local function barrierMesh(points, theme, halfWidth, shift)
  local verts, indices = {}, {}
  local n = #points
  local segment = 0
  for i = 1, n do
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
  local _, _, _, off, side = track:locate(x, y)
  if off <= 0 then return false end
  local i = track:locate(x, y)
  local s = track.samples[i]
  local barrier = side == "l" and s.barrierl or s.barrierr
  return off > barrier + clearance
end

local function scatter(track, theme, rng)
  local b = track.bounds
  local margin = 80 * M
  local items = {}
  local attempts = theme.scenery == "containers" and 320 or 3000
  for _ = 1, attempts do
    local x = rng:random(b.minX - margin, b.maxX + margin)
    local y = rng:random(b.minY - margin, b.maxY + margin)
    -- Clumps read as woodland; a pure random spread reads as confetti.
    local clump = love.math.noise(x / 1400, y / 1400)
    if clump > 0.34 and outsideRoad(track, x, y, 3 * M) then
      items[#items + 1] = { x = x, y = y, spin = rng:random() * math.pi * 2, s = 0.75 + rng:random() * 0.7 }
    end
  end
  return items
end

local function buildScenery(track, theme, rng)
  local items = scatter(track, theme, rng)
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
    if outsideRoad(track, box.x, box.y, 7 * M) then list[#list + 1] = box end
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
  local w, h = 62 * M, 8 * M
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

function renderer.load(track, timeName)
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
  self.batches, self.boxes = buildScenery(track, self.theme, rng)
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
  return setmetatable(self, { __index = renderer })
end

-- Freestyle has no circuit: just a huge concrete apron with worn paint.
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

  self.floods = {}
  for x = -8, 8 do
    for y = -8, 8 do
      self.floods[#self.floods + 1] = { x = x * 70 * M, y = y * 70 * M, nx = 0, ny = 0 }
    end
  end

  function self:drawGround()
    local shader = self.groundShader
    shader:send("noise", textures.noise)
    shader:send("colorA", self.theme.groundA)
    shader:send("colorB", self.theme.groundB)
    shader:send("pattern", self.theme.pattern)
    love.graphics.setShader(shader)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(self.ground)
    love.graphics.setShader()

    -- Painted bays around wherever the camera is looking.
    local tx, ty = love.graphics.inverseTransformPoint(love.graphics.getWidth() / 2, love.graphics.getHeight() / 2)
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
  end
  function self:drawOverhead() end
  function self:drawGlow() end
  self.drawLights = renderer.drawLights
  return self
end

-- Everything under the cars.
function renderer:drawGround()
  local shader = self.groundShader
  shader:send("noise", textures.noise)
  shader:send("colorA", self.theme.groundA)
  shader:send("colorB", self.theme.groundB)
  shader:send("pattern", self.theme.pattern)
  love.graphics.setShader(shader)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(self.ground)
  love.graphics.setShader()

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

function renderer:drawLights()
  local blob = textures.blob
  local scale = 62 * M / blob:getWidth()
  love.graphics.setColor(0.78, 0.74, 0.62, 1)
  for _, f in ipairs(self.floods) do
    love.graphics.draw(blob, f.x + f.nx * 12 * M, f.y + f.ny * 12 * M, 0, scale, scale, 32, 32)
  end
end

return renderer
