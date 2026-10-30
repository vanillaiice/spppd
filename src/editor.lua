-- The track editor screen. Click to add nodes, drag to shape the circuit, and
-- press T to drive it. All edits go through src/editor_model.
local ui = require("src/ui")
local state = require("src/state")
local colors = require("src/colors")
local config = require("src/config")
local catalog = require("src/tracks/catalog")
local model = require("src/editor_model")
local input = require("src/input")

local editor = {}

local PANEL = 150          -- at scale 1
local NODE_R = 7
local GRID = 25
local REBUILD_DELAY = 0.12

local doc, track, issues, stats
local cam = { x = 0, y = 0, zoom = 0.4 }
local selected, hovered
local drag
local snapGrid = false
local status, statusTime = "", 0
local overlay
local rebuildTimer = 0
local ribbon, centerLine, lineStrip

local function say(message)
  status, statusTime = message, 3
end

-- World here means track-file units, the same units nodes are stored in.
local function toWorld(sx, sy)
  local sw, sh = love.graphics.getDimensions()
  return (sx - sw / 2) / cam.zoom + cam.x, (sy - sh / 2) / cam.zoom + cam.y
end

local function toScreen(x, y)
  local sw, sh = love.graphics.getDimensions()
  return (x - cam.x) * cam.zoom + sw / 2, (y - cam.y) * cam.zoom + sh / 2
end

local function snap(x, y)
  if snapGrid then
    return math.floor(x / GRID + 0.5) * GRID, math.floor(y / GRID + 0.5) * GRID
  end
  return x, y
end

local function panelWidth()
  return PANEL * ui.scale()
end

local function rebuildMeshes()
  ribbon, centerLine, lineStrip = nil, nil, nil
  if not track then return end
  local s = doc.scale
  local verts = {}
  local a, b = colors.asphalt, colors.asphalt
  local function column(p)
    verts[#verts + 1] = { p.lx / s, p.ly / s, 0, 0, a[1] * 2.2, a[2] * 2.2, a[3] * 2.2, 1 }
    verts[#verts + 1] = { p.rx / s, p.ry / s, 0, 0, b[1] * 2.2, b[2] * 2.2, b[3] * 2.2, 1 }
  end
  for i = 1, track.count do column(track.samples[i]) end
  column(track.samples[1])
  ribbon = love.graphics.newMesh(verts, "strip", "static")

  lineStrip = {}
  for i = 1, track.count do
    lineStrip[#lineStrip + 1] = track.samples[i].lineX / s
    lineStrip[#lineStrip + 1] = track.samples[i].lineY / s
  end
  lineStrip[#lineStrip + 1] = lineStrip[1]
  lineStrip[#lineStrip + 1] = lineStrip[2]
end

local function rebuild()
  track, issues, stats = model.build(doc)
  rebuildMeshes()
end

local function changed()
  rebuildTimer = REBUILD_DELAY
end

local function fitView()
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for _, n in ipairs(doc.nodes) do
    minX, minY = math.min(minX, n.x), math.min(minY, n.y)
    maxX, maxY = math.max(maxX, n.x), math.max(maxY, n.y)
  end
  local sw, sh = love.graphics.getDimensions()
  local panel = panelWidth()
  local pad = 140
  local zx = (sw - panel) / (maxX - minX + pad * 2)
  local zy = sh / (maxY - minY + pad * 2)
  cam.zoom = math.min(zx, zy)
  cam.x = (minX + maxX) / 2 - panel / 2 / cam.zoom
  cam.y = (minY + maxY) / 2
end

-- New tracks never take a name that's already in use.
local function freshName()
  local name, n = "my_track", 1
  while catalog.find(name) do
    n = n + 1
    name = "my_track_" .. n
  end
  return name
end

function editor.open(existing)
  doc = existing or doc or model.new(freshName())
  selected, drag, overlay = nil, nil, nil
  rebuild()
  fitView()
end

-- Actions ----------------------------------------------------------------------

local function setDocument(newDoc)
  doc = newDoc
  selected, drag, overlay = nil, nil, nil
  rebuild()
  fitView()
end

local function saveTrack()
  -- Built-in tracks are never replaced: saving makes your own copy.
  local existing = catalog.find(doc.name)
  if doc.builtin or (existing and existing.builtin) then
    doc.name = doc.name .. "_edit"
    doc.title = doc.title .. " EDIT"
    doc.builtin = false
  end
  if catalog.save(doc.name, model.definition(doc)) then
    doc.dirty = false
    say("Saved " .. doc.title)
  else
    say("Couldn't save the track")
  end
end

local function testDrive()
  if not track then
    say("Fix the layout before driving it")
    return
  end
  require("src/menu").testDrive(doc, track)
end

local function undo()
  if model.undo(doc) then selected = nil changed() say("Undone") end
end

local function redo()
  if model.redo(doc) then selected = nil changed() say("Redone") end
end

local function reverseTrack()
  model.reverse(doc)
  selected = nil
  changed()
  say("Direction reversed")
end

local function rename()
  ui.startEditing(doc.name, function(value)
    if value ~= "" then
      doc.name = value:lower():gsub(" ", "_")
      doc.title = value:upper():gsub("_", " ")
      doc.dirty = true
    end
  end, "^[%w_ ]$", 18)
end

local function goBack()
  overlay = nil
  state.screen = "menu"
  require("src/menu").demoRunning = false
  require("src/menu").enter()
end

local function requestBack()
  if doc.dirty then overlay = "leave" else goBack() end
end

local function cycleTheme()
  for i, t in ipairs(model.THEMES) do
    if t == doc.theme then
      doc.theme = model.THEMES[i % #model.THEMES + 1]
      doc.dirty = true
      return
    end
  end
  doc.theme = model.THEMES[1]
end

local function toolRows()
  return {
    { label = "TEST DRIVE", value = "T", activate = testDrive },
    { label = "SAVE", value = "CTRL S", activate = saveTrack },
    { label = "OPEN", activate = function() overlay = "open" end },
    { label = "NEW", activate = function()
        setDocument(model.new(freshName()))
        say("New track")
      end },
    { label = "NAME", activate = rename },
    { label = "SCENERY", value = function() return doc.theme:upper() end, activate = cycleTheme },
    { label = "SET START", value = "ENTER", disabled = selected == nil, activate = function()
        model.setStart(doc, selected)
        changed()
        say("Start line moved")
      end },
    { label = "DELETE NODE", value = "DEL", disabled = selected == nil, activate = function()
        if model.removeNode(doc, selected) then selected = nil changed() else say("A track needs at least 4 nodes") end
      end },
    { label = "REVERSE", activate = reverseTrack },
    { label = "UNDO", value = "CTRL Z", activate = undo },
    { label = "REDO", value = "CTRL Y", activate = redo },
    { label = "SNAP", value = function() return snapGrid and "ON" or "OFF" end,
      activate = function() snapGrid = not snapGrid end },
    { label = "FIT VIEW", value = "F", activate = fitView },
    { label = "BACK", value = "ESC", activate = requestBack },
  }
end

-- Mouse -------------------------------------------------------------------------

local function overPanel(x)
  return x < panelWidth()
end

local function widthHandles(index)
  local n = doc.nodes[index]
  local count = #doc.nodes
  local p, q = doc.nodes[(index - 2) % count + 1], doc.nodes[index % count + 1]
  local tx, ty = q.x - p.x, q.y - p.y
  local len = math.sqrt(tx * tx + ty * ty)
  if len < 1e-6 then len = 1 end
  tx, ty = tx / len, ty / len
  local lx, ly = n.x + ty * n.wl, n.y - tx * n.wl
  local rx, ry = n.x - ty * n.wr, n.y + tx * n.wr
  return lx, ly, rx, ry, ty, -tx
end

local function hitHandle(wx, wy)
  if not selected then return nil end
  local lx, ly, rx, ry = widthHandles(selected)
  local r = (NODE_R + 4) / cam.zoom
  if math.sqrt((wx - lx) ^ 2 + (wy - ly) ^ 2) < r then return "l" end
  if math.sqrt((wx - rx) ^ 2 + (wy - ry) ^ 2) < r then return "r" end
  return nil
end

function editor.mousepressed(x, y, button)
  if overlay or ui.editing then return end
  if overPanel(x) then return end
  local wx, wy = toWorld(x, y)
  local radius = (NODE_R + 5) / cam.zoom

  if button == 1 then
    local handle = hitHandle(wx, wy)
    if handle then
      model.checkpoint(doc)
      drag = { kind = "width", side = handle }
      return
    end
    local index = model.nodeAt(doc, wx, wy, radius)
    if index then
      selected = index
      model.checkpoint(doc)
      drag = { kind = "node" }
    else
      wx, wy = snap(wx, wy)
      selected = model.insertNode(doc, wx, wy)
      drag = { kind = "node" }
      changed()
    end
  elseif button == 2 then
    local index = model.nodeAt(doc, wx, wy, radius)
    if index then
      if model.removeNode(doc, index) then
        selected = nil
        changed()
      else
        say("A track needs at least 4 nodes")
      end
    else
      drag = { kind = "pan", x = x, y = y, camX = cam.x, camY = cam.y }
    end
  elseif button == 3 then
    drag = { kind = "pan", x = x, y = y, camX = cam.x, camY = cam.y }
  end
end

function editor.mousereleased()
  if drag and drag.kind ~= "pan" then rebuildTimer = 0.01 end
  drag = nil
end

function editor.mousemoved(x, y)
  local wx, wy = toWorld(x, y)
  hovered = not overlay and not overPanel(x) and model.nodeAt(doc, wx, wy, (NODE_R + 5) / cam.zoom) or nil
  if not drag then return end
  if drag.kind == "pan" then
    cam.x = drag.camX - (x - drag.x) / cam.zoom
    cam.y = drag.camY - (y - drag.y) / cam.zoom
  elseif drag.kind == "node" then
    wx, wy = snap(wx, wy)
    model.moveNode(doc, selected, wx, wy)
    changed()
  elseif drag.kind == "width" then
    local n = doc.nodes[selected]
    local width = math.sqrt((wx - n.x) ^ 2 + (wy - n.y) ^ 2)
    model.setWidth(doc, selected, drag.side, width, love.keyboard.isDown("lshift", "rshift"))
    changed()
  end
end

function editor.wheelmoved(_, y)
  if overlay then return end
  local mx, my = love.mouse.getPosition()
  local beforeX, beforeY = toWorld(mx, my)
  cam.zoom = math.max(0.06, math.min(4, cam.zoom * (y > 0 and 1.15 or 1 / 1.15)))
  local afterX, afterY = toWorld(mx, my)
  cam.x = cam.x + beforeX - afterX
  cam.y = cam.y + beforeY - afterY
end

-- Keyboard ------------------------------------------------------------------------

function editor.keypressed(key)
  if ui.editing or overlay then
    if overlay == "open" and key == "escape" then
      overlay = nil
      return
    end
    ui.keypressed(key)
    return
  end
  local ctrl = love.keyboard.isDown("lctrl", "rctrl")
  local shift = love.keyboard.isDown("lshift", "rshift")
  if key == "s" and ctrl then saveTrack()
  elseif key == "z" and ctrl and shift then redo()
  elseif key == "z" and ctrl then undo()
  elseif key == "y" and ctrl then redo()
  elseif key == "t" then testDrive()
  elseif key == "f" then fitView()
  elseif key == "g" then snapGrid = not snapGrid
  elseif key == "escape" then requestBack()
  elseif key == "delete" and selected then
    if model.removeNode(doc, selected) then selected = nil changed() end
  elseif key == "return" and selected then
    model.setStart(doc, selected)
    changed()
    say("Start line moved")
  elseif key == "tab" then
    selected = ((selected or 0) % #doc.nodes) + 1
  end
end

function editor.textinput(t)
  ui.textinput(t)
end

function editor.update(dt)
  if rebuildTimer > 0 then
    rebuildTimer = rebuildTimer - dt
    if rebuildTimer <= 0 then rebuild() end
  end
  statusTime = math.max(0, statusTime - dt)
end

-- Drawing -------------------------------------------------------------------------

local function drawGrid(sw, sh)
  local step = GRID * (cam.zoom < 0.3 and 8 or (cam.zoom < 0.7 and 4 or 1))
  local x0, y0 = toWorld(0, 0)
  local x1, y1 = toWorld(sw, sh)
  love.graphics.setColor(1, 1, 1, 0.045)
  love.graphics.setLineWidth(1 / cam.zoom)
  for x = math.floor(x0 / step) * step, x1, step do love.graphics.line(x, y0, x, y1) end
  for y = math.floor(y0 / step) * step, y1, step do love.graphics.line(x0, y, x1, y) end
end

local function drawTrackShape()
  if not track then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(ribbon)
  local s = doc.scale
  local samples = track.samples
  local n = track.count

  -- Edges, with kerbs picked out
  love.graphics.setLineWidth(2 / cam.zoom)
  for i = 1, n do
    local a, b = samples[i], samples[i % n + 1]
    love.graphics.setColor(a.kerbL and colors.kerb or colors.paint)
    love.graphics.line(a.lx / s, a.ly / s, b.lx / s, b.ly / s)
    love.graphics.setColor(a.kerbR and colors.kerb or colors.paint)
    love.graphics.line(a.rx / s, a.ry / s, b.rx / s, b.ry / s)
  end

  -- Barriers and racing line, quieter
  love.graphics.setLineWidth(1.5 / cam.zoom)
  love.graphics.setColor(colors.muted[1], colors.muted[2], colors.muted[3], 0.45)
  for _, wall in ipairs({ track.barrierL, track.barrierR }) do
    local pts = {}
    for _, p in ipairs(wall) do
      pts[#pts + 1] = p.x / s
      pts[#pts + 1] = p.y / s
    end
    pts[#pts + 1] = pts[1]
    pts[#pts + 1] = pts[2]
    love.graphics.line(pts)
  end
  love.graphics.setColor(colors.sectorGreen[1], colors.sectorGreen[2], colors.sectorGreen[3], 0.55)
  love.graphics.line(lineStrip)
end

local function drawStart()
  local st = doc.startPoint
  if not st then return end
  local sx, sy = toScreen(st.x, st.y)
  local ca, sa = math.cos(st.angle or 0), math.sin(st.angle or 0)
  love.graphics.setColor(colors.marshal)
  love.graphics.setLineWidth(3)
  love.graphics.line(sx - sa * 14, sy + ca * 14, sx + sa * 14, sy - ca * 14)
  love.graphics.line(sx, sy, sx + ca * 26, sy + sa * 26)
  love.graphics.polygon("fill", sx + ca * 34, sy + sa * 34, sx + ca * 24 - sa * 6, sy + sa * 24 + ca * 6,
    sx + ca * 24 + sa * 6, sy + sa * 24 - ca * 6)
end

local function drawNodes()
  for i, n in ipairs(doc.nodes) do
    local sx, sy = toScreen(n.x, n.y)
    if i == selected then
      love.graphics.setColor(colors.marshal)
      love.graphics.circle("fill", sx, sy, NODE_R + 2)
    elseif i == hovered then
      love.graphics.setColor(colors.paint)
      love.graphics.circle("fill", sx, sy, NODE_R + 1)
    else
      love.graphics.setColor(colors.asphaltDeep)
      love.graphics.circle("fill", sx, sy, NODE_R)
      love.graphics.setColor(colors.paint)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", sx, sy, NODE_R)
    end
  end
  if selected then
    local lx, ly, rx, ry = widthHandles(selected)
    for _, p in ipairs({ { lx, ly }, { rx, ry } }) do
      local sx, sy = toScreen(p[1], p[2])
      local nx, ny = toScreen(doc.nodes[selected].x, doc.nodes[selected].y)
      love.graphics.setColor(colors.sectorGreen)
      love.graphics.setLineWidth(1.5)
      love.graphics.line(nx, ny, sx, sy)
      love.graphics.rectangle("fill", sx - 5, sy - 5, 10, 10)
    end
  end
end

local function drawStats(sw, sh, s)
  local x = panelWidth() + 8 * s
  local y = sh - 12 * s
  if track then
    ui.text(string.format("%.2f KM   NARROWEST %.1f M", track.length / config.METER / 1000, stats.narrowest),
      x, y, 6 * s, colors.paint)
  end
  for i, issue in ipairs(issues or {}) do
    ui.text(issue, x, y - i * 11 * s, 6 * s, colors.kerb)
  end
  if statusTime > 0 then
    ui.text(status, 0, 8 * s, 7 * s, colors.marshal, "center", sw + panelWidth())
  end
end

local function drawOpen(sw, sh, s)
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  local w, h = 240 * s, 220 * s
  local x, y = (sw - w) / 2, (sh - h) / 2
  ui.panel(x, y, w, h, 0.97)
  ui.kerb(x, y, w, 3 * s, s)
  ui.text("OPEN A TRACK", x + 10 * s, y + 10 * s, 7 * s, colors.marshal)
  local rows = {}
  for _, entry in ipairs(catalog.all()) do
    rows[#rows + 1] = {
      label = entry.title,
      value = entry.builtin and "BUILT IN" or "YOURS",
      activate = function()
        setDocument(model.fromEntry(entry))
        say("Opened " .. entry.title)
      end,
    }
  end
  rows[#rows + 1] = { label = "CANCEL", activate = function() overlay = nil end }
  ui.list("editor-open", rows, x + 6 * s, y + 26 * s, w - 18 * s, 14 * s, 6 * s, s)
end

local function drawLeave(sw, sh, s)
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  local w, h = 230 * s, 90 * s
  local x, y = (sw - w) / 2, (sh - h) / 2
  ui.panel(x, y, w, h, 0.97)
  ui.kerb(x, y, w, 3 * s, s)
  ui.text("You have unsaved changes.", x + 10 * s, y + 12 * s, 6 * s, colors.paint)
  local rows = {
    { label = "SAVE AND LEAVE", activate = function() saveTrack() goBack() end },
    { label = "LEAVE WITHOUT SAVING", activate = goBack },
    { label = "KEEP EDITING", activate = function() overlay = nil end },
  }
  ui.list("editor-leave", rows, x + 6 * s, y + 28 * s, w - 18 * s, 15 * s, 6 * s, s)
end

function editor.draw(sw, sh)
  local s = ui.scale(sw, sh)
  love.graphics.clear(0.085, 0.09, 0.1)

  love.graphics.push()
  love.graphics.translate(sw / 2, sh / 2)
  love.graphics.scale(cam.zoom)
  love.graphics.translate(-cam.x, -cam.y)
  drawGrid(sw, sh)
  drawTrackShape()
  love.graphics.pop()

  drawStart()
  drawNodes()

  local w = panelWidth()
  ui.panel(0, 0, w, sh, 0.95)
  love.graphics.setColor(colors.kerb)
  love.graphics.rectangle("fill", w, 0, s, sh)
  ui.text(doc.title .. (doc.dirty and " *" or ""), 8 * s, 8 * s, 6 * s, colors.marshal, "left", w - 12 * s)
  -- While a dialog is open it owns the input, not the toolbar behind it.
  local nav, clicked = ui.nav, ui.clicked
  local modal = overlay ~= nil or ui.editing ~= nil
  if modal then ui.nav, ui.clicked = {}, false end
  local rows = toolRows()
  local rowH = math.min(14 * s, (sh - 40 * s) / #rows)
  ui.list("editor-tools", rows, 2 * s, 28 * s, w - 8 * s, rowH, 5 * s, s)
  if modal then ui.nav, ui.clicked = nav, clicked end

  if ui.editing then
    ui.text("NAME: " .. ui.editing.value .. "_", 0, 24 * s, 8 * s, colors.paint, "center", sw + w)
  else
    ui.text("Click to add a node. Drag to move. Right click deletes. Wheel zooms.",
      w + 8 * s, sh - 23 * s, 5 * s, colors.muted)
  end
  drawStats(sw, sh, s)

  if overlay == "open" then drawOpen(sw, sh, s)
  elseif overlay == "leave" then drawLeave(sw, sh, s) end
end

function editor.currentDoc()
  return doc
end

return editor
