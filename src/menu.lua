-- Menus sit on a pit board down the left of the screen, with a live race
-- running behind it. Every screen is just a list of rows.
local ui = require("src/ui")
local state = require("src/state")
local colors = require("src/colors")
local config = require("src/config")
local settings = require("src/settings")
local garage = require("src/entities/garage")
local catalog = require("src/tracks/catalog")
local Track = require("src/sim/track")
local rm = require("src/race_manager")
local minimap = require("src/minimap")
local sprites = require("src/render/car_sprites")
local hud = require("src/hud")
local audio = require("src/audio")
local network = require("src/network_manager")
local dynamics = require("src/sim/dynamics")

local menu = { screen = "main" }

local PAINTS = {
  { name = "FACTORY" },
  { name = "RACE RED", color = { 0.78, 0.07, 0.09 } },
  { name = "SIGNAL YELLOW", color = { 0.95, 0.72, 0.08 } },
  { name = "ICE WHITE", color = { 0.92, 0.93, 0.95 } },
  { name = "GUNMETAL", color = { 0.2, 0.22, 0.25 } },
  { name = "ROYAL BLUE", color = { 0.07, 0.2, 0.62 } },
  { name = "BRITISH GREEN", color = { 0.04, 0.26, 0.15 } },
  { name = "SUNSET ORANGE", color = { 0.93, 0.36, 0.05 } },
  { name = "VIOLET", color = { 0.35, 0.1, 0.55 } },
}

local MODES = {
  race = "RACE", trial = "TIME TRIAL", freestyle = "FREESTYLE",
}
local TIMES = { "day", "dusk", "night" }
local TIME_NAMES = { day = "DAY", dusk = "DUSK", night = "NIGHT" }
local DIFFICULTIES = { "rookie", "pro", "ace" }
local DIFFICULTY_NAMES = { rookie = "ROOKIE", pro = "PRO", ace = "ACE" }
local ASSISTS = { "arcade", "sport", "sim" }
local ASSIST_NAMES = { arcade = "ARCADE", sport = "SPORT", sim = "SIM" }
local ASSIST_HINTS = {
  arcade = "Big grip and easy drifts. Hold the handbrake to slide.",
  sport = "Realistic grip, with driver aids as a safety net.",
  sim = "No aids. The car does exactly what you ask.",
}
local QUALITY = { "high", "low" }

local trackCache = {}
local function cachedTrack(entry)
  local key = entry.name .. (entry.builtin and "" or tostring(entry.def))
  if not trackCache[key] then
    local track = Track.new(entry.def)
    local line = {}
    for i = 1, track.count, 3 do
      line[#line + 1] = track.samples[i].x
      line[#line + 1] = track.samples[i].y
    end
    line[#line + 1] = track.samples[1].x
    line[#line + 1] = track.samples[1].y
    trackCache[key] = { track = track, line = line }
  end
  return trackCache[key]
end

local function cycle(list, current, direction)
  local index = 1
  for i, v in ipairs(list) do
    if v == current then index = i end
  end
  return list[(index - 1 + direction) % #list + 1]
end

local function save()
  settings.save()
end

local function currentEntry()
  return catalog.find(settings.track) or catalog.builtin()[1]
end

local function currentCar()
  return garage[math.max(1, math.min(#garage, settings.car))]
end

local function currentColor(spec)
  local paint = PAINTS[math.max(1, math.min(#PAINTS, settings.hue))]
  return paint.color or spec.color
end

function menu.go(screen)
  menu.screen = screen
  ui.focus[screen] = ui.focus[screen] or 1
end

function menu.enter()
  state.screen = "menu"
  menu.go("main")
  if not rm.isRunning() or not rm.race() or not menu.demoRunning then
    local list = catalog.builtin()
    local entry = list[love.math.random(1, #list)]
    menu.demoRunning = true
    rm.start({
      demo = true, mode = "race", entry = entry, laps = 999, opponents = 3,
      spec = garage[love.math.random(1, #garage)], time = "dusk", assist = "full",
      difficulty = "pro", startDelay = 0.1, seed = love.math.random(1, 100000),
    })
  end
end

function menu.startRace(extra)
  extra = extra or {}
  local spec = currentCar()
  menu.demoRunning = false
  local mode = settings.mode
  rm.start({
    mode = mode,
    entry = mode ~= "freestyle" and (extra.entry or currentEntry()) or nil,
    spec = spec,
    color = currentColor(spec),
    laps = mode == "race" and settings.laps or 9999,
    opponents = mode == "race" and settings.opponents or 0,
    difficulty = settings.difficulty,
    time = settings.time,
    fromEditor = extra.fromEditor,
    online = extra.online,
  })
  state.screen = "race"
end

-- Screens ------------------------------------------------------------------

local function mainRows()
  return {
    { label = "RACE", activate = function() settings.mode = "race" menu.go("setup") end },
    { label = "TIME TRIAL", activate = function() settings.mode = "trial" menu.go("setup") end },
    { label = "FREESTYLE", activate = function() settings.mode = "freestyle" menu.go("setup") end },
    { label = "ONLINE", activate = function() settings.mode = "race" menu.go("online") end },
    { label = "TRACK EDITOR", activate = function() menu.openEditor() end },
    { label = "SETTINGS", activate = function() menu.go("settings") end },
    { label = "CONTROLS", activate = function() menu.go("controls") end },
    { label = "CREDITS", activate = function() menu.go("credits") end },
    { label = "QUIT", activate = function() love.event.quit() end },
  }
end

local function stepper(label, get, set, list, names)
  local function shift(d)
    set(cycle(list, get(), d))
    save()
  end
  return {
    label = label,
    value = function() return names and names[get()] or tostring(get()) end,
    left = function() shift(-1) end,
    right = function() shift(1) end,
    activate = function() shift(1) end,
  }
end

local function numberStepper(label, key, low, high)
  local function shift(d)
    settings[key] = math.max(low, math.min(high, settings[key] + d))
    save()
  end
  return {
    label = label,
    value = function() return tostring(settings[key]) end,
    left = function() shift(-1) end,
    right = function() shift(1) end,
  }
end

local function toggle(label, key)
  local function flip()
    settings[key] = not settings[key]
    save()
  end
  return { label = label, value = function() return settings[key] and "ON" or "OFF" end,
    left = flip, right = flip, activate = flip }
end

local function setupRows()
  local rows = {}
  local mode = settings.mode
  if mode ~= "freestyle" then
    local entries = catalog.all()
    local names = {}
    local titles = {}
    for i, e in ipairs(entries) do
      names[i] = e.name
      titles[e.name] = e.title
    end
    rows[#rows + 1] = stepper("TRACK", function() return settings.track end,
      function(v) settings.track = v end, names, titles)
  end

  local carIds, carNames = {}, {}
  for i, spec in ipairs(garage) do
    carIds[i] = i
    carNames[i] = spec.name
  end
  rows[#rows + 1] = stepper("CAR", function() return settings.car end,
    function(v) settings.car = v end, carIds, carNames)

  local paintIds, paintNames = {}, {}
  for i, p in ipairs(PAINTS) do
    paintIds[i] = i
    paintNames[i] = p.name
  end
  rows[#rows + 1] = stepper("PAINT", function() return settings.hue end,
    function(v) settings.hue = v end, paintIds, paintNames)

  if mode == "race" then
    rows[#rows + 1] = numberStepper("LAPS", "laps", config.LAPS_MIN, config.LAPS_MAX)
    rows[#rows + 1] = numberStepper("OPPONENTS", "opponents", 0, config.OPPONENTS_MAX)
    rows[#rows + 1] = stepper("DIFFICULTY", function() return settings.difficulty end,
      function(v) settings.difficulty = v end, DIFFICULTIES, DIFFICULTY_NAMES)
  end
  rows[#rows + 1] = stepper("TIME", function() return settings.time end,
    function(v) settings.time = v end, TIMES, TIME_NAMES)
  rows[#rows + 1] = stepper("HANDLING", function() return settings.assists end,
    function(v) settings.assists = v end, ASSISTS, ASSIST_NAMES)
  rows[#rows + 1] = { label = "START", activate = function() menu.startRace() end }
  rows[#rows + 1] = { label = "BACK", activate = function() menu.go("main") end }
  return rows
end

local function settingsRows()
  local volumes = { 0, 0.2, 0.4, 0.6, 0.8, 1 }
  local volumeNames = { [0] = "OFF", [0.2] = "20%", [0.4] = "40%", [0.6] = "60%", [0.8] = "80%", [1] = "100%" }
  return {
    stepper("VOLUME", function() return settings.volume end, function(v)
      settings.volume = v
      audio.setVolume(v)
    end, volumes, volumeNames),
    stepper("CAMERA", function() return settings.camera end, function(v) settings.camera = v end,
      { "chase", "fixed" }, { chase = "CHASE", fixed = "FIXED" }),
    stepper("ZOOM", function() return settings.zoom end, function(v) settings.zoom = v end,
      { "near", "mid", "far" }, { near = "NEAR", mid = "MID", far = "FAR" }),
    stepper("GEARBOX", function() return settings.gearbox end, function(v) settings.gearbox = v end,
      { "auto", "manual" }, { auto = "AUTO", manual = "MANUAL" }),
    stepper("UNITS", function() return settings.units end, function(v) settings.units = v end,
      { "kmh", "mph" }, { kmh = "KM/H", mph = "MPH" }),
    stepper("EFFECTS", function() return settings.quality end, function(v)
      settings.quality = v
      require("src/render/post").quality = v
    end, QUALITY, { high = "HIGH", low = "LOW" }),
    toggle("PACE NOTES", "paceNotes"),
    toggle("MINIMAP", "minimap"),
    toggle("SHOW FPS", "showFps"),
    (function()
      local flip = function()
        settings.fullscreen = not settings.fullscreen
        love.window.setFullscreen(settings.fullscreen, "desktop")
        save()
      end
      return { label = "FULLSCREEN", value = function() return settings.fullscreen and "ON" or "OFF" end,
        left = flip, right = flip, activate = flip }
    end)(),
    { label = "BACK", activate = function() menu.go("main") end },
  }
end

local function onlineRows()
  local rows = {
    { label = "SERVER", value = function()
        return ui.editing and ui.editing.field == "server" and ui.editing.value .. "_" or settings.server
      end, activate = function()
        ui.startEditing(settings.server, function(v) settings.server = v save() end, "^[%w%.:%-]$", 40)
        ui.editing.field = "server"
      end },
    { label = "ROOM CODE", value = function()
        return ui.editing and ui.editing.field == "room" and ui.editing.value .. "_" or (network.roomCode ~= "" and network.roomCode or "NONE")
      end, activate = function()
        ui.startEditing(network.roomCode, function(v) network.roomCode = v:upper() end, "^%w$", 6)
        ui.editing.field = "room"
      end },
  }
  if network.status == "idle" or network.status == "error" then
    rows[#rows + 1] = { label = "HOST A ROOM", activate = function() menu.connect("host") end }
    rows[#rows + 1] = { label = "JOIN A ROOM", disabled = network.roomCode == "",
      activate = function() menu.connect("join") end }
  else
    rows[#rows + 1] = { label = "CANCEL", activate = function() network.disconnect() end }
  end
  rows[#rows + 1] = { label = "BACK", activate = function()
    network.disconnect()
    menu.go("main")
  end }
  return rows
end

function menu.connect(role)
  local host, port = settings.server:match("^(.+):(%d+)$")
  if role == "host" and network.roomCode == "" then
    network.roomCode = network.generateCode()
  end
  local spec = currentCar()
  network.connect(host or settings.server, tonumber(port) or 8080, role, network.roomCode, {
    car = spec.id, paint = settings.hue, track = settings.track,
    laps = settings.laps, time = settings.time,
  })
end

function menu.testDrive(doc, track)
  local spec = currentCar()
  menu.demoRunning = false
  rm.start({
    mode = "trial", track = track, spec = spec, color = currentColor(spec),
    laps = 9999, opponents = 0, time = settings.time, fromEditor = true,
  })
  state.screen = "race"
end

function menu.openEditor()
  require("src/editor").open()
  rm.stop()
  menu.demoRunning = false
  state.screen = "editor"
end

-- Drawing --------------------------------------------------------------------

local SCREENS = {
  main = { rows = mainRows },
  setup = { rows = setupRows },
  settings = { rows = settingsRows },
  online = { rows = onlineRows },
}

local function drawBoard(sw, sh, s, title)
  local w = sw > sh and math.min(sw, math.max(250 * s, sw * 0.4)) or sw
  ui.panel(0, 0, w, sh, 0.9)
  love.graphics.setColor(colors.kerb)
  love.graphics.rectangle("fill", w, 0, 2 * s, sh)
  ui.kerb(14 * s, 44 * s, w - 28 * s, 4 * s, s)
  ui.text("SPPPD", 14 * s, 14 * s, 22 * s, colors.marshal)
  if title then
    ui.text(title, 14 * s, 56 * s, 7 * s, colors.paint)
  end
  ui.text("v" .. config.VERSION, 14 * s, sh - 12 * s, 5 * s, colors.muted)
  return w
end

local function drawCar(spec, color, cx, cy, s, spin)
  local sprite = sprites.get(spec)
  local scale = sprite.scale * s * 1.3
  love.graphics.setColor(0, 0, 0, 0.45)
  love.graphics.draw(sprite.shadow, cx + 4 * s, cy + 6 * s, spin, scale, scale, sprite.ox, sprite.oy)
  love.graphics.setColor(color)
  love.graphics.draw(sprite.paint, cx, cy, spin, scale, scale, sprite.ox, sprite.oy)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(sprite.detail, cx, cy, spin, scale, scale, sprite.ox, sprite.oy)
end

local function drawSetupPreview(sw, sh, boardW, s)
  local x = boardW + 14 * s
  local w = sw - x - 14 * s
  if w < 120 * s then return end

  if settings.mode ~= "freestyle" then
    local entry = currentEntry()
    local data = cachedTrack(entry)
    local size = math.min(w, sh * 0.5)
    ui.panel(x, 14 * s, w, size + 34 * s, 0.82)
    minimap.drawOutline(data.track, data.line, x + (w - size) / 2 + 10 * s, 20 * s, size - 20 * s, 3, colors.paint)
    ui.text(entry.title, x + 6 * s, 14 * s + size + 8 * s, 8 * s, colors.marshal)
    local best = settings.bestLap(entry.name, currentCar().id)
    local detail = string.format("%.2f KM", data.track.length / config.METER / 1000)
    ui.text(detail, x, 14 * s + size + 8 * s, 6 * s, colors.paint, "right", w - 6 * s)
    ui.text("BEST " .. hud.formatTime(best), x + 6 * s, 14 * s + size + 20 * s, 6 * s,
      best and colors.sectorPurple or colors.muted)
  end

  local spec = currentCar()
  local panelH = 72 * s
  local py = sh - panelH - 14 * s
  ui.panel(x, py, w, panelH, 0.82)
  drawCar(spec, currentColor(spec), x + 42 * s, py + panelH / 2, s, 0)
  local tx = x + 84 * s
  ui.text(spec.name, tx, py + 7 * s, 8 * s, colors.paint)
  ui.text(string.format("%.0f KW  %s  %.0f KG", dynamics.peakPower(spec) / 1000, spec.drive, spec.mass),
    tx, py + 21 * s, 6 * s, colors.marshal)
  ui.text(spec.blurb, tx, py + 33 * s, 6 * s, colors.muted, "left", w - 90 * s)
end

local function drawControls(sw, sh, s, w)
  local rows = {
    { "STEER", "A D / ARROWS" }, { "ACCELERATE", "W / UP" }, { "BRAKE, REVERSE", "S / DOWN" },
    { "HANDBRAKE", "SHIFT" }, { "NITRO", "SPACE" }, { "LIGHTS", "F  G" },
    { "RESET TO TRACK", "R" }, { "CAMERA", "C" }, { "SHIFT GEARS", "Q E" }, { "PAUSE", "ESC / P" },
  }
  local y = 72 * s
  for i, row in ipairs(rows) do
    ui.text(row[1], 14 * s, y + (i - 1) * 13 * s, 6 * s, colors.paint)
    ui.text(row[2], 0, y + (i - 1) * 13 * s, 6 * s, colors.marshal, "right", w - 14 * s)
  end
  ui.text("Gamepads work too.", 14 * s, y + #rows * 13 * s + 4 * s, 6 * s, colors.muted)
end

local function drawCredits(sw, sh, s, w)
  ui.text("Created by VANILLAIICE", 14 * s, 76 * s, 6 * s, colors.paint)
  ui.text("Font: Press Start 2P by CodeMan38", 14 * s, 92 * s, 6 * s, colors.muted, "left", w - 28 * s)
  ui.text("Built with LOVE", 14 * s, 118 * s, 6 * s, colors.muted)
end

function menu.draw(sw, sh)
  rm.drawScene(sw, sh)
  local s = ui.scale(sw, sh)

  local titles = {
    setup = MODES[settings.mode], settings = "SETTINGS", online = "ONLINE",
    controls = "CONTROLS", credits = "CREDITS",
  }
  local w = drawBoard(sw, sh, s, titles[menu.screen])
  local x, y = 8 * s, 72 * s
  local listW = w - 22 * s
  local size = 7 * s

  if ui.consumeBack() then
    if menu.screen == "main" then
      -- nothing to go back to
    else
      if menu.screen == "online" then network.disconnect() end
      menu.go("main")
    end
  end

  local def = SCREENS[menu.screen]
  if def then
    local rows = def.rows()
    local rowH = math.min(15 * s, (sh - y - 24 * s) / #rows)
    if menu.screen == "main" then y = 62 * s end
    local focused = ui.list(menu.screen, rows, x, y, listW, rowH, size, s)
    if menu.screen == "setup" then
      drawSetupPreview(sw, sh, w, s)
      if focused.label == "HANDLING" then
        ui.text(ASSIST_HINTS[settings.assists], 14 * s, sh - 34 * s, 5 * s, colors.muted, "left", w - 28 * s)
      end
    end
    if menu.screen == "online" then
      local statusY = y + #rows * rowH + 8 * s
      ui.text(network.statusText(), 14 * s, statusY, 6 * s,
        network.status == "error" and colors.kerb or colors.marshal, "left", w - 28 * s)
    end
  else
    local rows = { { label = "BACK", activate = function() menu.go("main") end } }
    if menu.screen == "controls" then drawControls(sw, sh, s, w)
    else drawCredits(sw, sh, s, w) end
    ui.list(menu.screen, rows, x, sh - 34 * s, listW, 15 * s, size, s)
  end
end

function menu.update(dt)
  rm.update(dt)
  if menu.screen == "online" then
    network.update(dt)
    if network.ready then
      network.ready = false
      menu.startOnline()
    end
  end
end

function menu.startOnline()
  local cfg = network.session
  settings.track = cfg.track
  settings.laps = cfg.laps
  settings.time = cfg.time
  settings.mode = "race"
  local entry = catalog.find(cfg.track)
  if not entry then
    network.fail("You don't have the track " .. tostring(cfg.track))
    return
  end
  local peer = garage.byId(cfg.peerCar)
  local paint = PAINTS[cfg.peerPaint or 1]
  menu.startRace({
    entry = entry,
    online = {
      slot = cfg.slot, peerSpec = peer, peerColor = paint and paint.color or peer.color,
      state = network.latestPeerState,
    },
  })
end

-- Pause and results overlays ---------------------------------------------------

local function quitRace()
  local opts = rm.race() and rm.opts()
  local fromEditor = opts and opts.fromEditor
  network.disconnect()
  rm.stop()
  ui.nav = {}
  if fromEditor then
    state.screen = "editor"
    require("src/editor").open()
  else
    menu.demoRunning = false
    menu.enter()
  end
end

function menu.drawPause(sw, sh)
  local s = ui.scale(sw, sh)
  love.graphics.setColor(0, 0, 0, 0.55)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  local w = 190 * s
  local x = (sw - w) / 2
  local y = sh * 0.3
  ui.panel(x, y, w, 76 * s, 0.95)
  ui.kerb(x, y, w, 3 * s, s)
  ui.text("PAUSED", x, y + 10 * s, 8 * s, colors.marshal, "center", w)
  local fromEditor = rm.opts().fromEditor
  local rows = {
    { label = "RESUME", activate = function() rm.setPaused(false) end },
  }
  if not rm.isOnline() then
    rows[#rows + 1] = { label = "RESTART", activate = function() rm.restart() end }
  end
  rows[#rows + 1] = { label = fromEditor and "BACK TO EDITOR" or "QUIT TO MENU", activate = quitRace }
  ui.list("pause", rows, x + 8 * s, y + 24 * s, w - 16 * s, 16 * s, 7 * s, s)
  if ui.consumeBack() then rm.setPaused(false) end
end

function menu.drawResults(sw, sh)
  local s = ui.scale(sw, sh)
  local race = rm.race()
  love.graphics.setColor(0, 0, 0, 0.5)
  love.graphics.rectangle("fill", 0, 0, sw, sh)

  local order = race:standings()
  local w = math.min(sw - 16 * s, 300 * s)
  local rowH = 13 * s
  local h = 52 * s + rowH * #order + 40 * s
  local x, y = (sw - w) / 2, (sh - h) / 2
  ui.panel(x, y, w, h, 0.95)
  ui.kerb(x, y, w, 3 * s, s)

  local place = race.player.place
  local heading = place == 1 and "YOU WIN" or ("FINISHED P" .. place)
  ui.text(heading, x, y + 12 * s, 12 * s, place == 1 and colors.marshal or colors.paint, "center", w)

  local listY = y + 36 * s
  for i, car in ipairs(order) do
    local ry = listY + (i - 1) * rowH
    if car == race.player then
      love.graphics.setColor(colors.marshal[1], colors.marshal[2], colors.marshal[3], 0.18)
      love.graphics.rectangle("fill", x + 6 * s, ry - 2 * s, w - 12 * s, rowH)
    end
    ui.text(i .. "  " .. car.name, x + 10 * s, ry, 6 * s, colors.paint)
    local t = car.finished and hud.formatTime(car.finishTime) or "DID NOT FINISH"
    ui.text(t, x, ry, 6 * s, colors.muted, "right", w - 10 * s)
  end

  local rows = {}
  if not rm.isOnline() then
    rows[1] = { label = "RACE AGAIN", activate = function() rm.restart() end }
  end
  rows[#rows + 1] = { label = rm.opts().fromEditor and "BACK TO EDITOR" or "QUIT TO MENU", activate = quitRace }
  ui.list("results", rows, x + 8 * s, y + h - 36 * s, w - 16 * s, 15 * s, 7 * s, s)
end

return menu
