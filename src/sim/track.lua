-- Track geometry. Turns a track definition into a closed, evenly sampled
-- ribbon that physics, AI, rendering and the race logic all share.
-- No LÖVE dependency: this module runs in plain tests.
--
-- A definition is either
--   spline:   { nodes = {{x, y, wl, wr}, ...}, startPoint = {x, y, angle} }
--   boundary: { left = segments, right = segments, startPoint = ... }
-- Boundary segments are the legacy {type = "line"|"curve", points = {...}}.
local config = require("src/config")

local Track = {}
Track.__index = Track

local M = config.METER
local SPACING = config.SAMPLE_SPACING * M
local KERB_WIDTH = config.KERB_WIDTH * M

local sqrt, abs, min, max, floor = math.sqrt, math.abs, math.min, math.max, math.floor

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return sqrt(dx * dx + dy * dy)
end

local function wrap(i, n)
  return (i - 1) % n + 1
end

-- ─── Definition flattening ──────────────────────────────────────────

local function bezierPoint(points, u)
  local xs, ys = {}, {}
  for i, p in ipairs(points) do xs[i], ys[i] = p.x, p.y end
  for r = #points - 1, 1, -1 do
    for k = 1, r do
      xs[k] = xs[k] * (1 - u) + xs[k + 1] * u
      ys[k] = ys[k] * (1 - u) + ys[k + 1] * u
    end
  end
  return xs[1], ys[1]
end

local function flattenSegments(segments, scale)
  local out = {}
  local function push(x, y)
    local last = out[#out]
    if not last or abs(last.x - x) + abs(last.y - y) > 0.05 then
      out[#out + 1] = { x = x, y = y }
    end
  end
  for _, seg in ipairs(segments or {}) do
    if seg.type == "curve" and #seg.points >= 2 then
      local steps = 24 + #seg.points * 4
      for i = 0, steps do
        local x, y = bezierPoint(seg.points, i / steps)
        push(x * scale, y * scale)
      end
    else
      for _, p in ipairs(seg.points or {}) do push(p.x * scale, p.y * scale) end
    end
  end
  return out
end

local function closedLength(pts)
  local total = 0
  for i = 1, #pts do total = total + dist(pts[i], pts[wrap(i + 1, #pts)]) end
  return total
end

-- Evenly resample a closed polyline.
local function resampleClosed(pts, spacing)
  local total = closedLength(pts)
  local count = max(8, floor(total / spacing + 0.5))
  local step = total / count
  local out, i, walked = {}, 1, 0
  local segLen = dist(pts[1], pts[2])
  for k = 0, count - 1 do
    local target = k * step
    while walked + segLen < target and i < #pts do
      walked = walked + segLen
      i = i + 1
      segLen = dist(pts[i], pts[wrap(i + 1, #pts)])
    end
    local a, b = pts[i], pts[wrap(i + 1, #pts)]
    local u = segLen > 0 and (target - walked) / segLen or 0
    out[#out + 1] = { x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u }
  end
  return out
end

local function reversed(pts)
  local out = {}
  for i = #pts, 1, -1 do out[#out + 1] = pts[i] end
  return out
end

-- Pair up two closed boundaries by always advancing along the side that
-- gives the shorter rung. This copes with hairpins, where the inside edge
-- barely moves while the outside edge sweeps round.
local function pairBoundaries(a, b)
  local n, m = #a, #b
  local j, bestD = 1, math.huge
  for k = 1, m do
    local d = dist(a[1], b[k])
    if d < bestD then bestD, j = d, k end
  end

  local rungs = {}
  local i, di, dj = 1, 0, 0
  while di < n or dj < m do
    local ai, bj = a[wrap(i + di, n)], b[wrap(j + dj, m)]
    rungs[#rungs + 1] = { ax = ai.x, ay = ai.y, bx = bj.x, by = bj.y }
    if di >= n then
      dj = dj + 1
    elseif dj >= m then
      di = di + 1
    else
      local d1 = dist(a[wrap(i + di + 1, n)], bj)
      local d2 = dist(ai, b[wrap(j + dj + 1, m)])
      if d1 <= d2 then di = di + 1 else dj = dj + 1 end
    end
  end
  return rungs
end

-- Do the boundaries run the same way round? Hand-drawn inner/outer walls
-- are often wound in opposite directions.
local function sameDirection(a, b)
  local function signedArea(p)
    local area = 0
    for i = 1, #p do
      local q = p[wrap(i + 1, #p)]
      area = area + p[i].x * q.y - q.x * p[i].y
    end
    return area
  end
  return signedArea(a) * signedArea(b) > 0
end

-- Catmull-Rom through closed control nodes, with interpolated widths.
local function splineBoundaries(nodes, scale)
  local left, right = {}, {}
  local center = {}
  local n = #nodes
  local DEFAULT = 60
  for i = 1, n do
    local p0, p1 = nodes[wrap(i - 1, n)], nodes[i]
    local p2, p3 = nodes[wrap(i + 1, n)], nodes[wrap(i + 2, n)]
    local span = sqrt((p2.x - p1.x) ^ 2 + (p2.y - p1.y) ^ 2) * scale
    local steps = max(2, floor(span / (SPACING * 0.5)))
    local wl1, wl2 = p1.wl or DEFAULT, p2.wl or DEFAULT
    local wr1, wr2 = p1.wr or DEFAULT, p2.wr or DEFAULT
    for s = 0, steps - 1 do
      local u = s / steps
      local u2, u3 = u * u, u * u * u
      local cx = 0.5 * (2 * p1.x + (p2.x - p0.x) * u
        + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * u2
        + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * u3)
      local cy = 0.5 * (2 * p1.y + (p2.y - p0.y) * u
        + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * u2
        + (3 * p1.y - p0.y - 3 * p2.y + p3.y) * u3)
      local e = u * u * (3 - 2 * u)
      center[#center + 1] = {
        x = cx * scale, y = cy * scale,
        wl = (wl1 + (wl2 - wl1) * e) * scale,
        wr = (wr1 + (wr2 - wr1) * e) * scale,
      }
    end
  end
  local count = #center
  for i = 1, count do
    local p, q = center[wrap(i - 1, count)], center[wrap(i + 1, count)]
    local tx, ty = q.x - p.x, q.y - p.y
    local len = sqrt(tx * tx + ty * ty)
    if len < 1e-6 then len = 1 end
    tx, ty = tx / len, ty / len
    local c = center[i]
    left[i] = { x = c.x + ty * c.wl, y = c.y - tx * c.wl }
    right[i] = { x = c.x - ty * c.wr, y = c.y + tx * c.wr }
  end
  return left, right
end

-- ─── Ribbon construction ────────────────────────────────────────────

local function buildSamples(a, b)
  local rungs = pairBoundaries(a, b)
  local count = #rungs
  local length = 0
  for i = 1, count do
    local r = rungs[i]
    r.x, r.y = (r.ax + r.bx) / 2, (r.ay + r.by) / 2
  end
  for i = 1, count do
    local r, q = rungs[i], rungs[wrap(i + 1, count)]
    r.s = length
    length = length + dist(r, q)
  end

  local n = max(16, floor(length / SPACING + 0.5))
  local step = length / n
  local samples = {}
  local ri = 1
  for k = 0, n - 1 do
    local target = k * step
    while ri < count and rungs[ri + 1].s <= target do ri = ri + 1 end
    local r, q = rungs[ri], rungs[wrap(ri + 1, count)]
    local seg = (ri < count and q.s or length) - r.s
    local u = seg > 0 and (target - r.s) / seg or 0
    samples[k + 1] = {
      ax = r.ax + (q.ax - r.ax) * u, ay = r.ay + (q.ay - r.ay) * u,
      bx = r.bx + (q.bx - r.bx) * u, by = r.by + (q.by - r.by) * u,
    }
  end

  -- Hand-drawn edges are lumpy: a little smoothing keeps the ribbon clean.
  for _ = 1, 3 do
    local nextAx, nextAy, nextBx, nextBy = {}, {}, {}, {}
    for i = 1, n do
      local p, s, q = samples[wrap(i - 1, n)], samples[i], samples[wrap(i + 1, n)]
      nextAx[i] = (p.ax + 2 * s.ax + q.ax) / 4
      nextAy[i] = (p.ay + 2 * s.ay + q.ay) / 4
      nextBx[i] = (p.bx + 2 * s.bx + q.bx) / 4
      nextBy[i] = (p.by + 2 * s.by + q.by) / 4
    end
    for i = 1, n do
      local s = samples[i]
      s.ax, s.ay, s.bx, s.by = nextAx[i], nextAy[i], nextBx[i], nextBy[i]
    end
  end

  for i = 1, n do
    local s = samples[i]
    s.x, s.y = (s.ax + s.bx) / 2, (s.ay + s.by) / 2
  end
  return samples
end

local function computeFrames(samples)
  local n = #samples
  local total = 0
  for i = 1, n do
    local s = samples[i]
    s.s = total
    total = total + dist(s, samples[wrap(i + 1, n)])
  end
  for i = 1, n do
    local s = samples[i]
    local p, q = samples[wrap(i - 2, n)], samples[wrap(i + 2, n)]
    local tx, ty = q.x - p.x, q.y - p.y
    local len = sqrt(tx * tx + ty * ty)
    if len < 1e-6 then len = 1 end
    s.tx, s.ty = tx / len, ty / len
    s.nx, s.ny = -s.ty, s.tx -- points to the driver's right
  end
  return total
end

local function signedCurvature(p, q, r)
  local abx, aby = q.x - p.x, q.y - p.y
  local bcx, bcy = r.x - q.x, r.y - q.y
  local cross = abx * bcy - aby * bcx
  local denom = sqrt((abx * abx + aby * aby) * (bcx * bcx + bcy * bcy)
    * ((p.x - r.x) ^ 2 + (p.y - r.y) ^ 2))
  if denom < 1e-6 then return 0 end
  return 2 * cross / denom
end

-- Shape the ribbon so index 1 sits on the start line, indices increase in
-- the driving direction, `l` is the driver's left and `r` the right.
local function orient(samples, startPoint)
  local n = #samples
  computeFrames(samples)

  local start = 1
  if startPoint then
    local best = math.huge
    for i = 1, n do
      local d = dist(samples[i], startPoint)
      if d < best then best, start = d, i end
    end
    if startPoint.angle then
      local s = samples[start]
      local dot = s.tx * math.cos(startPoint.angle) + s.ty * math.sin(startPoint.angle)
      if dot < 0 then
        local flipped = {}
        for i = 1, n do flipped[i] = samples[wrap(start - i + 1, n)] end
        samples = flipped
        start = 1
        computeFrames(samples)
      end
    end
  end

  if start ~= 1 then
    local rotated = {}
    for i = 1, n do rotated[i] = samples[wrap(start + i - 1, n)] end
    samples = rotated
  end

  local total = computeFrames(samples)

  local vote = 0
  for i = 1, n do
    local s = samples[i]
    vote = vote + (s.bx - s.ax) * s.nx + (s.by - s.ay) * s.ny
  end
  for i = 1, n do
    local s = samples[i]
    if vote >= 0 then
      s.lx, s.ly, s.rx, s.ry = s.ax, s.ay, s.bx, s.by
    else
      s.lx, s.ly, s.rx, s.ry = s.bx, s.by, s.ax, s.ay
    end
    s.ax, s.ay, s.bx, s.by = nil, nil, nil, nil
    s.w = sqrt((s.rx - s.lx) ^ 2 + (s.ry - s.ly) ^ 2)
    s.index = i
  end
  return samples, total
end

local function computeCurvature(samples)
  local n = #samples
  local raw = {}
  for i = 1, n do
    raw[i] = signedCurvature(samples[wrap(i - 3, n)], samples[i], samples[wrap(i + 3, n)])
  end
  for i = 1, n do
    local total = 0
    for k = -2, 2 do total = total + raw[wrap(i + k, n)] end
    samples[i].k = total / 5
  end
end

-- Kerbs line the inside of real corners and the outside of the exits.
local function assignKerbs(samples)
  local n = #samples
  local R_KERB = 40 * M
  for i = 1, n do
    local s = samples[i]
    s.kerbL, s.kerbR = false, false
  end
  for i = 1, n do
    local k = samples[i].k
    if abs(k) > 1 / R_KERB then
      for off = -4, 4 do
        local s = samples[wrap(i + off, n)]
        if k < 0 then s.kerbL = true else s.kerbR = true end
      end
      for off = 3, 10 do
        local s = samples[wrap(i + off, n)]
        if k < 0 then s.kerbR = true else s.kerbL = true end
      end
    end
  end
  -- Drop slivers: a kerb shorter than a few samples just looks like a glitch.
  for _, key in ipairs({ "kerbL", "kerbR" }) do
    local i = 1
    while i <= n do
      if samples[i][key] then
        local run = 0
        while run < n and samples[wrap(i + run, n)][key] do run = run + 1 end
        if run < 6 then
          for r = 0, run - 1 do samples[wrap(i + r, n)][key] = false end
        end
        i = i + run
      else
        i = i + 1
      end
    end
  end
end

-- Gravel traps sit on the outside of the fastest-closing corners.
local function assignGravel(samples)
  local n = #samples
  local R_GRAVEL = 34 * M
  for i = 1, n do samples[i].gravelL, samples[i].gravelR = 0, 0 end
  for i = 1, n do
    local k = samples[i].k
    if abs(k) > 1 / R_GRAVEL then
      local depth = 7 * M
      for off = -8, 14 do
        local s = samples[wrap(i + off, n)]
        local fade = 1 - abs(off - 3) / 12
        if fade > 0 then
          local d = depth * min(1, fade * 2.2)
          if k < 0 then s.gravelR = max(s.gravelR, d) else s.gravelL = max(s.gravelL, d) end
        end
      end
    end
  end
end

-- ─── Barriers ───────────────────────────────────────────────────────

-- Distance along the ray (ox,oy)+(dx,dy)t to the closest sample edge that
-- is not part of the nearby stretch of road.
local function clearance(samples, i, ox, oy, dx, dy, limit)
  local n = #samples
  local best = limit
  local skip = 26
  for k = 1, n do
    local gap = abs(k - i)
    gap = min(gap, n - gap)
    if gap > skip then
      local s = samples[k]
      for side = 1, 2 do
        local px, py
        if side == 1 then px, py = s.lx, s.ly else px, py = s.rx, s.ry end
        local rx, ry = px - ox, py - oy
        local along = rx * dx + ry * dy
        if along > 0 and along < best then
          local perp = abs(rx * dy - ry * dx)
          if perp < SPACING then
            best = along
          end
        end
      end
    end
  end
  return best
end

-- Offsetting a polyline leaves little loops at tight inside corners. Cut
-- them out so Box2D gets a clean wall with nothing to snag on.
local function removeLoops(pts)
  local function cross(a, b, c, d)
    local rx, ry = b.x - a.x, b.y - a.y
    local sx, sy = d.x - c.x, d.y - c.y
    local denom = rx * sy - ry * sx
    if abs(denom) < 1e-9 then return nil end
    local t = ((c.x - a.x) * sy - (c.y - a.y) * sx) / denom
    local u = ((c.x - a.x) * ry - (c.y - a.y) * rx) / denom
    if t > 0 and t < 1 and u > 0 and u < 1 then
      return { x = a.x + rx * t, y = a.y + ry * t }
    end
    return nil
  end

  local WINDOW = 60
  local changed = true
  while changed do
    changed = false
    local n = #pts
    local i = 1
    while i <= n and not changed do
      for j = min(n - 1, i + WINDOW), i + 2, -1 do
        local hit = cross(pts[i], pts[i + 1] or pts[1], pts[j], pts[j + 1] or pts[1])
        if hit then
          local out = {}
          for k = 1, i do out[#out + 1] = pts[k] end
          out[#out + 1] = hit
          for k = j + 1, n do out[#out + 1] = pts[k] end
          pts = out
          changed = true
          break
        end
      end
      i = i + 1
    end
  end
  return pts
end

local function buildBarrierSide(samples, side, runoff)
  local n = #samples
  local offsets = {}
  local sign = side == "l" and -1 or 1
  local exKey, eyKey = side .. "x", side .. "y"
  local minimum = 2.2 * M

  for i = 1, n do
    local s = samples[i]
    local ex, ey = s[exKey], s[eyKey]
    local dx, dy = s.nx * sign, s.ny * sign
    local want = runoff
    -- On the inside of a corner an offset curve folds over itself.
    local inward = s.k * sign
    if inward > 1e-5 then want = min(want, 0.7 / inward) end
    local room = clearance(samples, i, ex, ey, dx, dy, want * 2.2)
    offsets[i] = max(minimum, min(want, room * 0.46))
  end

  -- Pull the barrier in ahead of any squeeze, then smooth so it stays a
  -- flowing line instead of following every constraint.
  local spread = {}
  for i = 1, n do
    local low = offsets[i]
    for k = -7, 7 do low = min(low, offsets[wrap(i + k, n)]) end
    spread[i] = low
  end
  for _ = 1, 8 do
    local nextO = {}
    for i = 1, n do
      nextO[i] = (spread[wrap(i - 1, n)] + 2 * spread[i] + spread[wrap(i + 1, n)]) / 4
    end
    spread = nextO
  end

  local pts = {}
  for i = 1, n do
    local s = samples[i]
    local d = spread[i]
    s["barrier" .. side] = d
    pts[i] = { x = s[exKey] + s.nx * sign * d, y = s[eyKey] + s.ny * sign * d }
  end
  return removeLoops(pts)
end

-- ─── Racing line ────────────────────────────────────────────────────

local function buildRacingLine(samples)
  local n = #samples
  local margin = 2.0 * M
  local px, py, lo, hi = {}, {}, {}, {}
  for i = 1, n do
    local s = samples[i]
    px[i], py[i] = s.x, s.y
    local half = s.w / 2
    local m = min(margin, half * 0.45)
    lo[i], hi[i] = -half + m, half - m
  end

  -- Relax towards minimum curvature: the fourth-order stencil below is the
  -- fixed point of "bend as little as possible", which is what produces the
  -- classic out-in-out shape. Wide strides find the big arcs through a corner
  -- and fine strides clean up the result.
  local stride = 12
  while stride >= 1 do
    local sweeps = stride > 2 and 70 or 40
    for _ = 1, sweeps do
      for i = 1, n do
        local s = samples[i]
        local a1, b1 = wrap(i - stride, n), wrap(i + stride, n)
        local a2, b2 = wrap(i - 2 * stride, n), wrap(i + 2 * stride, n)
        local mx = (4 * (px[a1] + px[b1]) - (px[a2] + px[b2])) / 6
        local my = (4 * (py[a1] + py[b1]) - (py[a2] + py[b2])) / 6
        local rdx, rdy = (s.rx - s.lx) / s.w, (s.ry - s.ly) / s.w
        local cur = (px[i] - s.x) * rdx + (py[i] - s.y) * rdy
        local off = (mx - s.x) * rdx + (my - s.y) * rdy
        off = cur + (off - cur) * 0.6
        off = max(lo[i], min(hi[i], off))
        px[i], py[i] = s.x + rdx * off, s.y + rdy * off
      end
    end
    stride = floor(stride / 2)
  end

  local line = {}
  for i = 1, n do line[i] = { x = px[i], y = py[i] } end
  for i = 1, n do
    local s = samples[i]
    local l = line[i]
    local k = signedCurvature(line[wrap(i - 4, n)], l, line[wrap(i + 4, n)])
    l.k = k
    s.lineX, s.lineY = l.x, l.y
    s.lineK = k
  end
  for _ = 1, 2 do
    local nextK = {}
    for i = 1, n do
      nextK[i] = (samples[wrap(i - 1, n)].lineK + 2 * samples[i].lineK + samples[wrap(i + 1, n)].lineK) / 4
    end
    for i = 1, n do samples[i].lineK = nextK[i] end
  end
end

-- ─── Public API ─────────────────────────────────────────────────────

function Track.new(def)
  local scale = def.scale or config.TRACK_SCALE
  local self = setmetatable({}, Track)
  self.scale = scale
  self.theme = def.theme or "meadow"
  self.title = def.title

  local a, b
  if def.nodes then
    assert(#def.nodes >= 3, "a spline track needs at least 3 nodes")
    a, b = splineBoundaries(def.nodes, scale)
  else
    a, b = flattenSegments(def.left, scale), flattenSegments(def.right, scale)
    assert(#a >= 3 and #b >= 3, "a boundary track needs both edges")
  end

  a = resampleClosed(a, SPACING / 2)
  b = resampleClosed(b, SPACING / 2)
  if not sameDirection(a, b) then b = reversed(b) end

  local startPoint
  if def.startPoint then
    startPoint = {
      x = def.startPoint.x * scale, y = def.startPoint.y * scale,
      angle = def.startPoint.angle,
    }
  end

  local samples, length = orient(buildSamples(a, b), startPoint)
  self.samples = samples
  self.count = #samples
  self.length = length

  computeCurvature(samples)
  assignKerbs(samples)
  assignGravel(samples)
  local runoff = (def.runoff or config.RUNOFF_WIDTH) * M
  self.barrierL = buildBarrierSide(samples, "l", runoff)
  self.barrierR = buildBarrierSide(samples, "r", runoff)
  buildRacingLine(samples)

  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for _, pts in ipairs({ self.barrierL, self.barrierR }) do
    for _, p in ipairs(pts) do
      minX, minY = min(minX, p.x), min(minY, p.y)
      maxX, maxY = max(maxX, p.x), max(maxY, p.y)
    end
  end
  self.bounds = { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
  return self
end

-- Find where a world point sits on the ribbon. Pass the previous index as
-- `hint` so that parallel stretches of road can't steal the result. `window`
-- is how many samples either side of it to search, 12 unless said.
function Track:locate(x, y, hint, window)
  local samples, n = self.samples, self.count
  local best, bestD = 1, math.huge
  if hint then
    window = window or 12
    for k = -window, window do
      local i = wrap(hint + k, n)
      local s = samples[i]
      local dx, dy = x - s.x, y - s.y
      local d = dx * dx + dy * dy
      if d < bestD then bestD, best = d, i end
    end
  end
  if not hint or bestD > (30 * M) ^ 2 then
    bestD = math.huge
    for i = 1, n do
      local s = samples[i]
      local dx, dy = x - s.x, y - s.y
      local d = dx * dx + dy * dy
      if d < bestD then bestD, best = d, i end
    end
  end

  -- Refine onto the segment that actually contains the point.
  local s = samples[best]
  local along = (x - s.x) * s.tx + (y - s.y) * s.ty
  local i1, i2
  if along >= 0 then i1, i2 = best, wrap(best + 1, n) else i1, i2 = wrap(best - 1, n), best end
  local p, q = samples[i1], samples[i2]
  local dx, dy = q.x - p.x, q.y - p.y
  local len2 = dx * dx + dy * dy
  local u = len2 > 0 and ((x - p.x) * dx + (y - p.y) * dy) / len2 or 0
  u = max(0, min(1, u))

  local lx = p.lx + (q.lx - p.lx) * u
  local ly = p.ly + (q.ly - p.ly) * u
  local rx = p.rx + (q.rx - p.rx) * u
  local ry = p.ry + (q.ry - p.ry) * u
  local ex, ey = rx - lx, ry - ly
  local w2 = ex * ex + ey * ey
  local across = w2 > 0 and ((x - lx) * ex + (y - ly) * ey) / w2 or 0.5
  local width = sqrt(w2)
  local distance = (i1 == n and self.length or q.s)
  local s0 = p.s + (distance - p.s) * u

  -- off > 0 means past the edge, in world px, on the side given by across
  local off = 0
  if across < 0 then off = -across * width elseif across > 1 then off = (across - 1) * width end
  return best, s0, (across - 0.5) * width, off, across < 0.5 and "l" or "r"
end

function Track:surfaceAt(x, y, hint, window)
  local i, _, _, off, side = self:locate(x, y, hint, window)
  if off <= 0 then return "asphalt", i end
  local s = self.samples[i]
  if off <= KERB_WIDTH and (side == "l" and s.kerbL or side == "r" and s.kerbR) then
    return "kerb", i
  end
  local gravel = side == "l" and s.gravelL or s.gravelR
  if gravel > 0 and off <= gravel + KERB_WIDTH then return "gravel", i end
  return "grass", i
end

-- Grid slots sit in staggered pairs behind the start line.
function Track:gridSlot(slot)
  local n = self.count
  local row = floor((slot - 1) / 2)
  local stepsBack = 3 + floor(row * 8 / config.SAMPLE_SPACING + (slot - 1) % 2 * 1.6)
  local s = self.samples[wrap(1 - stepsBack, n)]
  local q = self.samples[wrap(1 - stepsBack + 2, n)]
  local tx, ty = q.x - s.x, q.y - s.y
  local side = (slot % 2 == 1) and -1 or 1
  local offset = side * min(s.w * 0.25, 3.2 * M)
  return s.x + s.nx * offset, s.y + s.ny * offset, math.atan2(ty, tx), s.index
end

-- Maximum corner speed around the lap (m/s) with brake and traction limits
-- applied. Returned as a plain array aligned with the samples.
function Track:speedProfile(opts)
  local g = config.GRAVITY
  local mu = opts.mu or 1.0
  local vmax = opts.vmax or 90
  local brake = opts.brake or mu * g * 0.8
  local accel = opts.accel or 5
  local samples, n = self.samples, self.count
  local v = {}
  for i = 1, n do
    local k = abs(samples[i].lineK) * M
    v[i] = k > 1e-5 and min(vmax, sqrt(mu * g / k)) or vmax
  end
  local ds = (self.length / n) / M
  for _ = 1, 2 do
    for i = n, 1, -1 do
      local nextV = v[wrap(i + 1, n)]
      v[i] = min(v[i], sqrt(nextV * nextV + 2 * brake * ds))
    end
    for i = 1, n do
      local prev = v[wrap(i - 1, n)]
      local a = accel * max(0.2, 1 - prev / vmax)
      v[i] = min(v[i], sqrt(prev * prev + 2 * a * ds))
    end
  end
  return v
end

-- Quality checks shown in the editor; `issues` is empty for a clean track.
function Track:validate()
  local issues = {}
  local samples, n = self.samples, self.count
  local narrow = math.huge
  for i = 1, n do
    narrow = min(narrow, samples[i].w)
  end
  if self.length < 300 * M then
    issues[#issues + 1] = string.format("Short lap: %.0f m", self.length / M)
  end
  if narrow < 7 * M then
    issues[#issues + 1] = string.format("Narrow: %.1f m wide", narrow / M)
  end

  -- Edges crossing a far-away stretch of road means the layout overlaps.
  local crossings = 0
  local function ccw(ax, ay, bx, by, cx, cy)
    return (cy - ay) * (bx - ax) > (by - ay) * (cx - ax)
  end
  for i = 1, n, 2 do
    local p, q = samples[i], samples[wrap(i + 2, n)]
    for k = i + 40, n, 2 do
      local gap = min(abs(k - i), n - abs(k - i))
      if gap > 30 then
        local r, t = samples[k], samples[wrap(k + 2, n)]
        if ccw(p.x, p.y, r.x, r.y, t.x, t.y) ~= ccw(q.x, q.y, r.x, r.y, t.x, t.y)
          and ccw(p.x, p.y, q.x, q.y, r.x, r.y) ~= ccw(p.x, p.y, q.x, q.y, t.x, t.y) then
          crossings = crossings + 1
        end
      end
    end
  end
  if crossings > 0 then issues[#issues + 1] = "Track crosses itself" end

  -- Two stretches of road sitting on top of each other, without crossing.
  local overlaps = 0
  for i = 1, n, 3 do
    local p = samples[i]
    for k = i + 30, n, 3 do
      local gap = min(k - i, n - (k - i))
      if gap > 30 then
        local q = samples[k]
        local reach = (p.w + q.w) / 2 + M
        local dx, dy = p.x - q.x, p.y - q.y
        if dx * dx + dy * dy < reach * reach then overlaps = overlaps + 1 end
      end
    end
  end
  if overlaps > 0 and crossings == 0 then issues[#issues + 1] = "Two parts of the track overlap" end
  return issues, { length = self.length / M, narrowest = narrow / M, crossings = crossings }
end

-- Convert any definition to editable nodes (used to open boundary tracks).
function Track:toNodes(everyMetres)
  local nodes = {}
  local stride = max(4, floor((everyMetres or 30) / config.SAMPLE_SPACING))
  local scale = self.scale
  for i = 1, self.count, stride do
    local s = self.samples[i]
    nodes[#nodes + 1] = {
      x = s.x / scale, y = s.y / scale,
      wl = sqrt((s.x - s.lx) ^ 2 + (s.y - s.ly) ^ 2) / scale,
      wr = sqrt((s.x - s.rx) ^ 2 + (s.y - s.ry) ^ 2) / scale,
    }
  end
  return nodes
end

return Track
