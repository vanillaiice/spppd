-- Track editing without any drawing: a document of spline nodes plus undo.
-- Keeping this apart from the screen code means it can be tested directly.
local Track = require("src/sim/track")
local config = require("src/config")

local model = {}

model.MIN_WIDTH = 18
model.MAX_WIDTH = 140
model.THEMES = { "meadow", "desert", "marina" }
local MAX_UNDO = 100

local function copyNodes(nodes)
  local out = {}
  for i, n in ipairs(nodes) do out[i] = { x = n.x, y = n.y, wl = n.wl, wr = n.wr } end
  return out
end

local function snapshot(doc)
  local start = doc.startPoint
  return {
    nodes = copyNodes(doc.nodes),
    startPoint = start and { x = start.x, y = start.y, angle = start.angle } or nil,
  }
end

local function restore(doc, snap)
  doc.nodes = copyNodes(snap.nodes)
  local start = snap.startPoint
  doc.startPoint = start and { x = start.x, y = start.y, angle = start.angle } or nil
end

local function defaultNodes()
  local nodes = {}
  for i = 0, 11 do
    local a = i / 12 * math.pi * 2
    nodes[#nodes + 1] = { x = math.cos(a) * 800, y = math.sin(a) * 480, wl = 34, wr = 34 }
  end
  return nodes
end

function model.new(name)
  local doc = {
    name = name or "my_track",
    title = (name or "my track"):gsub("_", " "):upper(),
    theme = "meadow",
    scale = config.TRACK_SCALE,
    nodes = defaultNodes(),
    undo = {}, redo = {},
    dirty = false,
  }
  doc.startPoint = { x = 800, y = 0, angle = math.pi / 2 }
  return doc
end

-- Boundary tracks are converted to nodes, so any circuit can be opened.
function model.fromEntry(entry)
  local def = entry.def
  local doc = model.new(entry.name)
  doc.title = entry.title
  doc.theme = def.theme or "meadow"
  doc.scale = def.scale or config.TRACK_SCALE
  doc.builtin = entry.builtin
  if def.nodes then
    doc.nodes = copyNodes(def.nodes)
  else
    doc.nodes = Track.new(def):toNodes(26)
  end
  local start = def.startPoint
  doc.startPoint = start and { x = start.x, y = start.y, angle = start.angle } or nil
  return doc
end

function model.definition(doc)
  return {
    title = doc.title, theme = doc.theme, scale = doc.scale,
    nodes = doc.nodes, startPoint = doc.startPoint,
  }
end

-- Call before a change. Dragging calls this once, on mouse down.
function model.checkpoint(doc)
  doc.undo[#doc.undo + 1] = snapshot(doc)
  if #doc.undo > MAX_UNDO then table.remove(doc.undo, 1) end
  doc.redo = {}
  doc.dirty = true
end

function model.undo(doc)
  local snap = table.remove(doc.undo)
  if not snap then return false end
  doc.redo[#doc.redo + 1] = snapshot(doc)
  restore(doc, snap)
  doc.dirty = true
  return true
end

function model.redo(doc)
  local snap = table.remove(doc.redo)
  if not snap then return false end
  doc.undo[#doc.undo + 1] = snapshot(doc)
  restore(doc, snap)
  doc.dirty = true
  return true
end

local function pointSegment(px, py, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local len2 = dx * dx + dy * dy
  local u = len2 > 0 and ((px - a.x) * dx + (py - a.y) * dy) / len2 or 0
  u = math.max(0, math.min(1, u))
  local qx, qy = a.x + dx * u, a.y + dy * u
  return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end

-- Which gap between nodes is this point nearest to?
function model.nearestGap(doc, x, y)
  local best, bestD = 1, math.huge
  local n = #doc.nodes
  for i = 1, n do
    local d = pointSegment(x, y, doc.nodes[i], doc.nodes[i % n + 1])
    if d < bestD then bestD, best = d, i end
  end
  return best, bestD
end

function model.nodeAt(doc, x, y, radius)
  local best, bestD = nil, radius
  for i, n in ipairs(doc.nodes) do
    local d = math.sqrt((n.x - x) ^ 2 + (n.y - y) ^ 2)
    if d < bestD then bestD, best = d, i end
  end
  return best
end

-- New nodes go into the nearest gap, taking their width from its neighbours.
function model.insertNode(doc, x, y)
  model.checkpoint(doc)
  local gap = model.nearestGap(doc, x, y)
  local a, b = doc.nodes[gap], doc.nodes[gap % #doc.nodes + 1]
  table.insert(doc.nodes, gap + 1, { x = x, y = y, wl = (a.wl + b.wl) / 2, wr = (a.wr + b.wr) / 2 })
  return gap + 1
end

function model.removeNode(doc, index)
  if #doc.nodes <= 4 then return false end
  model.checkpoint(doc)
  table.remove(doc.nodes, index)
  return true
end

function model.moveNode(doc, index, x, y)
  local n = doc.nodes[index]
  n.x, n.y = x, y
end

function model.setWidth(doc, index, side, value, both)
  local n = doc.nodes[index]
  value = math.max(model.MIN_WIDTH, math.min(model.MAX_WIDTH, value))
  if side == "l" or both then n.wl = value end
  if side == "r" or both then n.wr = value end
end

function model.reverse(doc)
  model.checkpoint(doc)
  local out = {}
  for i = #doc.nodes, 1, -1 do
    local n = doc.nodes[i]
    out[#out + 1] = { x = n.x, y = n.y, wl = n.wr, wr = n.wl }
  end
  doc.nodes = out
  if doc.startPoint then doc.startPoint.angle = doc.startPoint.angle + math.pi end
end

function model.setStart(doc, index)
  model.checkpoint(doc)
  local n = #doc.nodes
  local a, b = doc.nodes[(index - 2) % n + 1], doc.nodes[index % n + 1]
  local node = doc.nodes[index]
  doc.startPoint = { x = node.x, y = node.y, angle = math.atan2(b.y - a.y, b.x - a.x) }
end

-- Returns a built Track and any problems. A failed build is reported, never thrown.
function model.build(doc)
  local ok, track = pcall(Track.new, model.definition(doc))
  if not ok then return nil, { "This layout can't be built" } end
  local issues, stats = track:validate()
  return track, issues, stats
end

return model
