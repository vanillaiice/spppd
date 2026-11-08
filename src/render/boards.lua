-- Sponsor boards: flat panels laid on the grass just outside the fence, lettered
-- to face the road. Only drawn; nothing can hit them. Who is on which board is
-- src/sponsors.lua's business.
local config = require("src/config")
local sponsors = require("src/sponsors")

local boards = {}

local M = config.METER

-- A board's number is its address, and a sold board is sold by its address.
-- Changing any of these, or the walk in boards.place, renumbers every board on
-- every track, so once one is sold they stay as they are.
boards.LENGTH = 20   -- m along the fence
boards.DEPTH = 2.4   -- m across
boards.GAP = 50      -- m between one board and the next
boards.SET = 0.5     -- m of grass between the fence and the board
boards.BOW = 0.4     -- m the fence may bend away from a board's line

local LETTER = 1.3   -- m, the height of the lettering
local PAD = 1        -- m clear at each end of the lettering
local FONT_SIZE = 24

-- Board-local coordinates: u along the board, v across it.
local function toLocal(b, x, y)
  local dx, dy = x - b.x, y - b.y
  local ca, sa = math.cos(b.angle), math.sin(b.angle)
  return dx * ca + dy * sa, -dx * sa + dy * ca
end

-- Whether x, y is on the rectangle b, grown by margin on every side.
function boards.covers(b, x, y, margin)
  local u, v = toLocal(b, x, y)
  return math.abs(u) <= b.len / 2 + margin and math.abs(v) <= b.depth / 2 + margin
end

local function corners(b)
  local ca, sa = math.cos(b.angle), math.sin(b.angle)
  local hu, hv = b.len / 2, b.depth / 2
  local out = {}
  for _, k in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { 0, 0 }, { 0, 1 }, { 0, -1 } }) do
    local u, v = k[1] * hu, k[2] * hv
    out[#out + 1] = { b.x + u * ca - v * sa, b.y + u * sa + v * ca }
  end
  return out
end

local function overlaps(a, b)
  if (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 > ((a.len + b.len) / 2 + a.depth + b.depth) ^ 2 then return false end
  for _, p in ipairs(corners(a)) do if boards.covers(b, p[1], p[2], 0) then return true end end
  for _, p in ipairs(corners(b)) do if boards.covers(a, p[1], p[2], 0) then return true end end
  return false
end

-- Off the road and beyond whichever fence is nearest.
local function behindFence(track, x, y)
  local i, _, _, off, side = track:locate(x, y)
  if off <= 0 then return false end
  local s = track.samples[i]
  local fence = side == "l" and s.barrierl or s.barrierr
  return off > fence + config.BARRIER_THICKNESS * M / 2
end

local function fencePoint(s, side)
  local sign = side == "l" and -1 or 1
  local d = s["barrier" .. side]
  return s[side .. "x"] + s.nx * sign * d, s[side .. "y"] + s.ny * sign * d
end

-- Every board on a track, numbered from 1: the left fence from the start line
-- round, then the right. Each is { x, y, angle, len, depth, n, side }, the
-- lettering reading along angle. avoid lists rectangles, in the same form, to
-- keep clear of, such as the grandstand.
function boards.place(track, avoid)
  local samples, n = track.samples, track.count
  local length, gap, bow = boards.LENGTH * M, boards.GAP * M, boards.BOW * M
  local push = config.BARRIER_THICKNESS * M / 2 + boards.SET * M + boards.DEPTH * M / 2
  local list = {}
  avoid = avoid or {}

  for _, side in ipairs({ "l", "r" }) do
    local sign = side == "l" and -1 or 1
    local i = 1
    while i < n do
      local ax, ay = fencePoint(samples[i], side)
      -- Reach along the fence until the chord is a board long.
      local j = i + 1
      local bx, by = fencePoint(samples[j], side)
      while j < n and (bx - ax) ^ 2 + (by - ay) ^ 2 < length * length do
        j = j + 1
        bx, by = fencePoint(samples[j], side)
      end
      local chord = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
      if chord < length then break end

      local tx, ty = (bx - ax) / chord, (by - ay) / chord
      local mid = samples[math.floor((i + j) / 2)]
      -- Out, away from the road: the chord's normal on the fence's side.
      local ox, oy = -ty, tx
      if ox * mid.nx * sign + oy * mid.ny * sign < 0 then ox, oy = -ox, -oy end
      -- How far the fence strays from the chord, and how far out towards the
      -- board it bows, on the outside of a bend.
      local straight, bulge = true, 0
      for k = i + 1, j - 1 do
        local px, py = fencePoint(samples[k], side)
        local along = (px - ax) * tx + (py - ay) * ty
        local across = (px - ax) * ox + (py - ay) * oy
        if math.abs(across) > bow or along < 0 or along > chord then straight = false break end
        bulge = math.max(bulge, across)
      end

      local placed = false
      if straight then
        -- The lettering stands on the road's side, its bottom to the road.
        -- Text's down is (-sin, cos), which has to be the way back, (-ox, -oy).
        local angle = math.atan2(ox, -oy)
        local b = {
          x = (ax + bx) / 2 + ox * (push + bulge), y = (ay + by) / 2 + oy * (push + bulge),
          angle = angle, len = length, depth = boards.DEPTH * M, side = side,
        }
        local fits = true
        for _, p in ipairs(corners(b)) do
          if not behindFence(track, p[1], p[2]) then fits = false break end
        end
        if fits then
          for _, other in ipairs(list) do if overlaps(b, other) then fits = false break end end
        end
        if fits then
          for _, other in ipairs(avoid) do if overlaps(b, other) then fits = false break end end
        end
        if fits then
          b.n = #list + 1
          list[#list + 1] = b
          placed = true
          -- Skip on until a gap's length past this board's end.
          i = j
          while i < n do
            local cx, cy = fencePoint(samples[i], side)
            if (cx - bx) ^ 2 + (cy - by) ^ 2 >= gap * gap then break end
            i = i + 1
          end
        end
      end
      if not placed then i = i + 1 end
    end
  end
  return list
end

-- Whether x, y is within margin of any board.
function boards.near(list, x, y, margin)
  for _, b in ipairs(list) do
    if (b.x - x) ^ 2 + (b.y - y) ^ 2 < (b.len / 2 + margin + b.depth) ^ 2 and boards.covers(b, x, y, margin) then
      return true
    end
  end
  return false
end

local font

-- What every board shows, in two static draws: the panels, then the lettering.
-- addRect and rectMesh are the track renderer's own baking helpers.
function boards.build(list, trackName, title, env, addRect, rectMesh)
  if #list == 0 then return nil end
  font = font or love.graphics.newFont("assets/fonts/PressStart2P.ttf", FONT_SIZE)
  local showSpots = os.getenv("SPPPD_SPOTS") == "1"
  local rects = {}
  local text = love.graphics.newText(font)
  local sx, sy = env.sun[1] * env.shadowLength * 0.6, env.sun[2] * env.shadowLength * 0.6
  local edge = 2
  for _, b in ipairs(list) do
    local paint
    if showSpots then
      paint = sponsors.paint({ text = (title or trackName or "TRACK"):upper() .. " " .. b.n, board = "#FFFFFF", ink = "#141820" })
    else
      paint = sponsors.paint(sponsors.forBoard(trackName, b.n))
    end
    local hu, hv = b.len / 2, b.depth / 2
    addRect(rects, -hu, -hv, b.len, b.depth, { 0, 0, 0 }, env.shadowAlpha, { b.x + sx, b.y + sy, b.angle })
    addRect(rects, -hu - edge, -hv - edge, b.len + edge * 2, b.depth + edge * 2, { 0.15, 0.15, 0.22 }, 1, { b.x, b.y, b.angle })
    addRect(rects, -hu, -hv, b.len, b.depth, paint.board, 1, { b.x, b.y, b.angle })

    local w, h = font:getWidth(paint.text), font:getHeight()
    local scale = math.min(LETTER * M / h, (b.len - PAD * 2 * M) / w)
    local ink = paint.ink
    text:add({ { ink[1], ink[2], ink[3], 1 }, paint.text }, b.x, b.y, b.angle, scale, scale, w / 2, h / 2)
  end
  return { panels = rectMesh(rects), text = text }
end

function boards.draw(built)
  if not built then return end
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(built.panels)
  love.graphics.draw(built.text)
end

return boards
