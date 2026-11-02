-- Tracks as plain text, for sending to another player. A track file is Lua, which
-- is fine for your own but can't be run from a stranger: setfenv doesn't stop a
-- loop that never ends, and LuaJIT loads bytecode. So this is data, and `decode`
-- refuses anything outside the limits before it can reach Track.new. Pure Lua.
local config = require("src/config")

local wire = {}

wire.MAX_BYTES = 64000

local HEADER = "spppd-track 1"
local THEMES = { meadow = true, desert = true, marina = true }
local KINDS = { line = true, curve = true, startPt = true, kerb = true }
local SIDES = { left = true, right = true }

local MAX_NODES = 1500
local MAX_SEGMENTS = 400
local MAX_CURVE_POINTS = 64  -- a Bezier's cost grows with the square of these
local MAX_POINTS = 3000
local MAX_COORD = 100000
local MAX_LAP_METRES = 20000
local MIN_WIDTH, MAX_WIDTH = 1, 400
local MIN_SCALE, MAX_SCALE = 1, 8
local MIN_RUNOFF, MAX_RUNOFF = 2, 30
local MAX_TITLE = 24

-- The font only has ASCII, and printing invalid UTF-8 raises an error.
function wire.cleanTitle(title)
  local clean = tostring(title or ""):gsub("[^%w %-_%.']", ""):sub(1, MAX_TITLE)
  return clean ~= "" and clean or "SHARED TRACK"
end

local function point(p)
  return string.format("%.2f %.2f", p.x, p.y)
end

local function encodeSegments(lines, side, segments)
  for _, seg in ipairs(segments or {}) do
    local parts = { "seg", side, seg.type }
    for _, p in ipairs(seg.points or {}) do parts[#parts + 1] = point(p) end
    lines[#lines + 1] = table.concat(parts, " ")
  end
end

function wire.encode(def)
  local lines = { HEADER, "title " .. wire.cleanTitle(def.title), "theme " .. (def.theme or "meadow") }
  if def.scale then lines[#lines + 1] = string.format("scale %.3f", def.scale) end
  if def.runoff then lines[#lines + 1] = string.format("runoff %.2f", def.runoff) end
  if def.startPoint then
    lines[#lines + 1] = string.format("start %.2f %.2f %.4f", def.startPoint.x, def.startPoint.y, def.startPoint.angle or 0)
  end
  for _, n in ipairs(def.nodes or {}) do
    lines[#lines + 1] = string.format("node %.2f %.2f %.2f %.2f", n.x, n.y, n.wl, n.wr)
  end
  encodeSegments(lines, "left", def.left)
  encodeSegments(lines, "right", def.right)
  return table.concat(lines, "\n")
end

local function within(value, low, high)
  return value ~= nil and value >= low and value <= high
end

local function numbers(text)
  local out = {}
  for word in text:gmatch("%S+") do
    local value = tonumber(word)
    -- Also turns away NaN, which fails every comparison.
    if not within(value, -MAX_COORD, MAX_COORD) then return nil end
    out[#out + 1] = value
  end
  return out
end

local function polylineMetres(points, scale)
  local total = 0
  for i = 2, #points do
    total = total + math.sqrt((points[i].x - points[i - 1].x) ^ 2 + (points[i].y - points[i - 1].y) ^ 2)
  end
  return total * scale / config.METER
end

-- Returns a definition Track.new can take, or nil and why not.
function wire.decode(text)
  if type(text) ~= "string" or #text > wire.MAX_BYTES then return nil, "too big" end
  local first = text:match("^[^\n]*")
  if first ~= HEADER then return nil, "not a track" end

  local def = { theme = "meadow" }
  local nodes, left, right = {}, {}, {}
  local totalPoints = 0
  for line in text:gmatch("[^\n]+") do
    local key, rest = line:match("^(%S+)%s*(.*)$")
    if key == "title" then
      def.title = wire.cleanTitle(rest)
    elseif key == "theme" then
      if THEMES[rest] then def.theme = rest end
    elseif key == "scale" then
      def.scale = tonumber(rest)
      if not within(def.scale, MIN_SCALE, MAX_SCALE) then return nil, "bad scale" end
    elseif key == "runoff" then
      def.runoff = tonumber(rest)
      if not within(def.runoff, MIN_RUNOFF, MAX_RUNOFF) then return nil, "bad runoff" end
    elseif key == "start" then
      local v = numbers(rest)
      if not v or #v ~= 3 then return nil, "bad start" end
      def.startPoint = { x = v[1], y = v[2], angle = v[3] }
    elseif key == "node" then
      local v = numbers(rest)
      if not v or #v ~= 4 then return nil, "bad node" end
      if not within(v[3], MIN_WIDTH, MAX_WIDTH) or not within(v[4], MIN_WIDTH, MAX_WIDTH) then
        return nil, "bad width"
      end
      if #nodes >= MAX_NODES then return nil, "too many nodes" end
      nodes[#nodes + 1] = { x = v[1], y = v[2], wl = v[3], wr = v[4] }
    elseif key == "seg" then
      local side, kind, coords = rest:match("^(%S+) (%S+) (.*)$")
      if not SIDES[side] or not KINDS[kind] then return nil, "bad segment" end
      local v = numbers(coords)
      if not v or #v % 2 ~= 0 then return nil, "bad segment" end
      if kind == "curve" and #v / 2 > MAX_CURVE_POINTS then return nil, "curve too complex" end
      local points = {}
      for i = 1, #v, 2 do points[#points + 1] = { x = v[i], y = v[i + 1] } end
      totalPoints = totalPoints + #points
      local list = side == "left" and left or right
      if #list >= MAX_SEGMENTS or totalPoints > MAX_POINTS then return nil, "too many segments" end
      list[#list + 1] = { type = kind, points = points }
    end
  end

  local scale = def.scale or config.TRACK_SCALE
  if #nodes > 0 then
    if #nodes < 4 then return nil, "too few nodes" end
    if polylineMetres(nodes, scale) > MAX_LAP_METRES then return nil, "too long" end
    def.nodes = nodes
    return def
  end
  if #left == 0 or #right == 0 then return nil, "no road" end
  for _, list in ipairs({ left, right }) do
    local metres = 0
    for _, seg in ipairs(list) do metres = metres + polylineMetres(seg.points, scale) end
    if metres > MAX_LAP_METRES then return nil, "too long" end
  end
  def.left, def.right = left, right
  return def
end

return wire
