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
local radio = require("src/radio")
local network = require("src/network_manager")
local dynamics = require("src/sim/dynamics")
local cheats = require("src/cheats")

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
  race = "RACE", trial = "TIME TRIAL - NO OPPONENTS", freestyle = "FREESTYLE",
}
local TIMES = { "day", "dusk", "night", "midnight" }
local TIME_NAMES = { day = "DAY", dusk = "DUSK", night = "NIGHT", midnight = "MIDNIGHT" }
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
local VOLUMES = { 0, 0.2, 0.4, 0.6, 0.8, 1 }
local VOLUME_NAMES = { [0] = "OFF", [0.2] = "20%", [0.4] = "40%", [0.6] = "60%", [0.8] = "80%", [1] = "100%" }
local MUSIC_HINT = "Drop MP3, OGG, FLAC, WAV here, or press to open the folder."

-- What a player should know before going online. ARCHITECTURE.md explains why.
menu.ONLINE_NOTES = {
  "Online is new, so expect rough edges.",
  "Stay in the game. Away for 5 seconds and you're out of the race, with no way back in.",
  "Nobody checks results, so a changed game can cheat. Race people you trust.",
  "A slow connection makes cars look late, and contact can look wrong.",
  "Everyone in a room needs the same version of the game.",
  "The server sees your IP address. Other drivers don't. See PRIVACY & TERMS.",
}

-- Weak, so a saved track that's been changed lets go of its old build. The
-- race drives the same Track, which nothing changes once it's built.
local trackCache = setmetatable({}, { __mode = "k" })
local function cachedTrack(entry)
  local key = entry.def
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
menu.cachedTrack = cachedTrack

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
  local mode = extra.online and "race" or settings.mode
  local entry = mode ~= "freestyle" and (extra.entry or currentEntry()) or nil
  rm.start({
    mode = mode,
    entry = entry,
    track = entry and cachedTrack(entry).track,
    spec = spec,
    color = currentColor(spec),
    laps = extra.laps or (mode == "race" and settings.laps or 9999),
    opponents = mode == "race" and settings.opponents or 0,
    difficulty = settings.difficulty,
    time = extra.time or settings.time,
    fromEditor = extra.fromEditor,
    online = extra.online,
  })
  state.screen = "race"
end

-- Screens ------------------------------------------------------------------

local function mainRows()
  local rows = {
    { label = "RACE", activate = function() settings.mode = "race" menu.go("setup") end },
    { label = "TIME TRIAL", activate = function() settings.mode = "trial" menu.go("setup") end },
    { label = "FREESTYLE", activate = function()
        settings.mode = "freestyle"
        radio.scan()
        menu.go("setup")
      end },
    { label = "ONLINE", activate = function() settings.mode = "race" menu.go("online") end },
  }
  -- The editor needs a keyboard and a right click.
  if not ui.mobile then
    rows[#rows + 1] = { label = "TRACK EDITOR", activate = function() menu.openEditor() end }
  end
  rows[#rows + 1] = { label = "SETTINGS", activate = function() menu.go("settings") end }
  rows[#rows + 1] = { label = "CONTROLS", activate = function() menu.go("controls") end }
  rows[#rows + 1] = { label = "CREDITS", activate = function() menu.go("credits") end }
  rows[#rows + 1] = { label = "QUIT", activate = function() love.event.quit() end }
  return rows
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

local function trackRow()
  local names, titles = {}, {}
  for i, e in ipairs(catalog.all()) do
    names[i] = e.name
    titles[e.name] = e.title
  end
  return stepper("TRACK", function() return settings.track end,
    function(v) settings.track = v end, names, titles)
end

local function carRow()
  local ids, names = {}, {}
  for i, spec in ipairs(garage) do
    ids[i] = i
    names[i] = spec.name
  end
  return stepper("CAR", function() return settings.car end,
    function(v) settings.car = v end, ids, names)
end

local function paintRow()
  local ids, names = {}, {}
  for i, p in ipairs(PAINTS) do
    ids[i] = i
    names[i] = p.name
  end
  return stepper("PAINT", function() return settings.hue end,
    function(v) settings.hue = v end, ids, names)
end

local function lapsRow()
  return numberStepper("LAPS", "laps", config.LAPS_MIN, config.LAPS_MAX)
end

local function timeRow()
  return stepper("TIME", function() return settings.time end,
    function(v) settings.time = v end, TIMES, TIME_NAMES)
end

local function setupRows()
  local rows = {}
  local mode = settings.mode
  if mode ~= "freestyle" then rows[#rows + 1] = trackRow() end
  rows[#rows + 1] = carRow()
  rows[#rows + 1] = paintRow()

  if mode == "race" then
    rows[#rows + 1] = lapsRow()
    rows[#rows + 1] = numberStepper("OPPONENTS", "opponents", 0, config.OPPONENTS_MAX)
    rows[#rows + 1] = stepper("DIFFICULTY", function() return settings.difficulty end,
      function(v) settings.difficulty = v end, DIFFICULTIES, DIFFICULTY_NAMES)
  end
  rows[#rows + 1] = timeRow()
  rows[#rows + 1] = stepper("HANDLING", function() return settings.assists end,
    function(v) settings.assists = v end, ASSISTS, ASSIST_NAMES)
  -- A phone's save folder is out of reach, so there's no way to fill it there.
  if mode == "freestyle" and not ui.mobile then
    rows[#rows + 1] = stepper("RADIO", function() return settings.radioVolume end,
      function(v) settings.radioVolume = v end, VOLUMES, VOLUME_NAMES)
    rows[#rows + 1] = { label = "MUSIC FOLDER", value = function()
        local count = #radio.tracks
        return count == 1 and "1 SONG" or count .. " SONGS"
      end, activate = function() radio.openFolder() end }
  end
  rows[#rows + 1] = { label = "START", activate = function() menu.startRace() end }
  rows[#rows + 1] = { label = "BACK", activate = function() menu.go("main") end }
  return rows
end

-- Where a phone enters cheat codes. The answer shows in the row for a moment.
local CODE_ANSWER_TIME = 2
local codeAnswer

local function codeRow()
  return { label = "CODE", value = function()
      if ui.editing and ui.editing.field == "code" then return ui.editing.value .. "_" end
      if codeAnswer and love.timer.getTime() < codeAnswer.untilTime then return codeAnswer.text end
      return "ENTER"
    end, activate = function()
      ui.startEditing("", function(word)
        local effect = cheats.enter(word)
        local text = effect and cheats.apply(effect) or "NO SUCH CODE"
        codeAnswer = { text = text, untilTime = love.timer.getTime() + CODE_ANSWER_TIME }
        if effect then audio.play("select", 0.5) end
      end, "^%a$", 8)
      ui.editing.field = "code"
    end }
end

local function settingsRows()
  local rows = {
    stepper("VOLUME", function() return settings.volume end, function(v)
      settings.volume = v
      audio.setVolume(v)
    end, VOLUMES, VOLUME_NAMES),
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
    toggle("AUTO GAS", "autoGas"),
    stepper("TOUCH STEERING", function() return settings.touchSteer end,
      function(v) settings.touchSteer = v end, { "stick", "buttons" }, { stick = "STICK", buttons = "BUTTONS" }),
    toggle("VIBRATION", "vibration"),
  }
  -- A phone always has the touch controls and always fills the screen.
  if not ui.mobile then
    rows[#rows + 1] = stepper("TOUCH CONTROLS", function() return settings.touch end,
      function(v) settings.touch = v end, { "auto", "on", "off" }, { auto = "AUTO", on = "ON", off = "OFF" })
    local flip = function()
      settings.fullscreen = not settings.fullscreen
      love.window.setFullscreen(settings.fullscreen, "desktop")
      save()
    end
    rows[#rows + 1] = { label = "FULLSCREEN", value = function() return settings.fullscreen and "ON" or "OFF" end,
      left = flip, right = flip, activate = flip }
  end
  rows[#rows + 1] = codeRow()
  rows[#rows + 1] = { label = "BACK", activate = function() menu.go("main") end }
  return rows
end

-- Everyone picks their own car here. The race itself is the host's to set, on
-- the next screen, so a joiner never sees choices that wouldn't count. Once
-- connecting, there's nothing left to choose and the status gets the room.
local function onlineRows()
  local back = { label = "BACK", activate = function()
    network.disconnect()
    menu.go("main")
  end }
  local busy = network.status ~= "idle" and network.status ~= "error"
  local room = { label = "ROOM CODE", disabled = busy, value = function()
      if ui.editing and ui.editing.field == "room" then return ui.editing.value .. "_" end
      return network.roomCode ~= "" and network.roomCode or "ENTER CODE"
    end, activate = function()
      ui.startEditing(network.roomCode, function(v) network.roomCode = v:upper() end, "^%w$", 6)
      ui.editing.field = "room"
    end }
  if busy then
    local rows = { room }
    if network.isLeader() then
      local startable = network.canStart()
      -- The list skips a disabled row, so focus has to come back when it opens.
      if startable and not menu.startable then ui.focus.online = 2 end
      menu.startable = startable
      rows[2] = { label = "START RACE", disabled = not startable, activate = function() network.startRace() end }
    end
    rows[#rows + 1] = { label = "CANCEL", activate = function() network.disconnect() end }
    rows[#rows + 1] = back
    return rows
  end
  return {
    { label = "SERVER", value = function()
        return ui.editing and ui.editing.field == "server" and ui.editing.value .. "_" or settings.server
      end, activate = function()
        ui.startEditing(settings.server, function(v) settings.server = v save() end, "^[%w%.:%-]$", 40)
        ui.editing.field = "server"
      end },
    carRow(), paintRow(),
    { label = "HOST A ROOM", activate = function() menu.go("host") end },
    room,
    { label = "JOIN A ROOM", disabled = network.roomCode == "", activate = function() menu.connect("join") end },
    { label = "PRIVACY & TERMS", activate = function() love.system.openURL(config.PRIVACY_URL) end },
    back,
  }
end
menu.onlineRows = onlineRows

local function hostRows()
  return {
    trackRow(), lapsRow(), timeRow(),
    { label = "START ROOM", activate = function() menu.connect("host") end },
    { label = "BACK", activate = function() menu.go("online") end },
  }
end
menu.hostRows = hostRows

function menu.connect(role)
  local race
  -- Every room gets a fresh code, so a host never has to think of one.
  if role == "host" then
    network.roomCode = network.generateCode()
    local entry = currentEntry()
    race = { def = entry.def, title = entry.title, laps = settings.laps, time = settings.time }
  end
  local spec = currentCar()
  local host, port = settings.serverAddress()
  network.connect(host, port, role, network.roomCode,
    { car = spec.id, paint = settings.hue }, race)
  menu.go("online")
  ui.focus.online = 2  -- START RACE or CANCEL, once the list has shrunk
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
  host = { rows = hostRows },
}

local function drawBoard(sw, sh, s, title)
  local w = sw > sh and math.min(sw, math.max(250 * s, sw * 0.4)) or sw
  ui.panel(0, 0, w, sh, 0.9)
  love.graphics.setColor(colors.kerb)
  love.graphics.rectangle("fill", w, 0, 2 * s, sh)
  ui.kerb(14 * s, 44 * s, w - 28 * s, 4 * s, s)
  ui.text("SPPPD", 14 * s, 14 * s, 22 * s, colors.marshal)
  if title then
    ui.text(title, 14 * s, 56 * s, 7 * s, colors.marshal)
  end
  ui.text("v" .. config.VERSION, 14 * s, sh - 12 * s, 5 * s, colors.muted)
  return w
end

local function drawCar(spec, color, cx, cy, s, spin)
  local sprite = sprites.get(spec)
  -- The longest cars would run into the text beside them.
  local scale = math.min(sprite.scale * s * 1.3, 80 * s / sprite.paint:getWidth())
  love.graphics.setColor(0, 0, 0, 0.45)
  love.graphics.draw(sprite.shadow, cx + 4 * s, cy + 6 * s, spin, scale, scale, sprite.ox, sprite.oy)
  love.graphics.setColor(color)
  love.graphics.draw(sprite.paint, cx, cy, spin, scale, scale, sprite.ox, sprite.oy)
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(sprite.detail, cx, cy, spin, scale, scale, sprite.ox, sprite.oy)
end

local function drawOnlineNotes(x, y, w, s)
  local size = 6 * s
  local font = ui.font(size)
  local inner = w - 12 * s
  local gap = 4 * s
  local height = 22 * s
  local heights = {}
  for i, note in ipairs(menu.ONLINE_NOTES) do
    local _, lines = font:getWrap(note, inner)
    heights[i] = #lines * font:getHeight() * font:getLineHeight() + gap
    height = height + heights[i]
  end
  ui.panel(x, y, w, height, 0.82)
  ui.text("BEFORE YOU RACE", x + 6 * s, y + 7 * s, size, colors.kerb)
  local ty = y + 20 * s
  for i, note in ipairs(menu.ONLINE_NOTES) do
    ui.text(note, x + 6 * s, ty, size, colors.paint, "left", inner)
    ty = ty + heights[i]
  end
end

local function drawSetupPreview(sw, sh, boardW, s, carOnly)
  local x = boardW + 14 * s
  local w = sw - x - 14 * s
  if w < 120 * s then return end

  if settings.mode ~= "freestyle" and not carOnly then
    local entry = currentEntry()
    local data = cachedTrack(entry)
    -- Stops short of the car panel on a screen as low as a phone's.
    local size = math.min(w, sh * 0.5, sh - 138 * s)
    ui.panel(x, 14 * s, w, size + 34 * s, 0.82)
    minimap.drawOutline(data.track, data.line, x + (w - size) / 2 + 10 * s, 20 * s, size - 20 * s, 3, colors.paint)
    ui.text(entry.title, x + 6 * s, 14 * s + size + 8 * s, 8 * s, colors.marshal)
    local best = settings.bestLap(entry.name, currentCar().id)
    local detail = string.format("%.2f KM", data.track.length / config.METER / 1000)
    ui.text(detail, x, 14 * s + size + 8 * s, 6 * s, colors.paint, "right", w - 6 * s)
    ui.text("BEST " .. hud.formatTime(best), x + 6 * s, 14 * s + size + 20 * s, 6 * s,
      best and colors.sectorPurple or colors.muted)
  end

  if carOnly then drawOnlineNotes(x, 14 * s, w, s) end

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

-- Who's in the room and what they're racing for, down the side of the lobby.
local function drawLobby(sw, sh, boardW, s)
  local x = boardW + 14 * s
  local w = sw - x - 14 * s
  if w < 120 * s then return end
  local setup = network.setup
  local rowH = 15 * s
  ui.panel(x, 14 * s, w, 44 * s + rowH * network.MAX_PLAYERS, 0.82)
  ui.text(setup and setup.title or "GETTING THE RACE...", x + 6 * s, 21 * s, 8 * s, colors.marshal)
  if setup then
    local laps = setup.laps == 1 and "1 LAP" or setup.laps .. " LAPS"
    ui.text(laps .. "  " .. (TIME_NAMES[setup.time] or "DAY"), x + 6 * s, 35 * s, 6 * s, colors.paint)
  end

  local drivers = network.peerList()
  table.insert(drivers, { slot = network.slot, car = network.me.car, paint = network.me.paint, have = network.def ~= nil, you = true })
  table.sort(drivers, function(a, b) return a.slot < b.slot end)
  local y = 52 * s
  for i, driver in ipairs(drivers) do
    local ry = y + (i - 1) * rowH
    local spec = driver.car and garage.byId(driver.car)
    if spec then
      local paint = PAINTS[driver.paint or 1]
      love.graphics.setColor(paint and paint.color or spec.color)
      love.graphics.rectangle("fill", x + 6 * s, ry + s, 3 * s, 8 * s)
    end
    ui.text("P" .. driver.slot .. "  " .. (spec and spec.name or "..."), x + 13 * s, ry + 2 * s, 6 * s,
      driver.you and colors.marshal or colors.paint)
    local note = driver.you and "YOU" or (driver.slot == network.leader and "HOST") or (not driver.have and "GETTING TRACK") or ""
    ui.text(note, x, ry + 2 * s, 6 * s, colors.muted, "right", w - 6 * s)
  end
end

local function drawControls(sw, sh, s, w)
  local rows = {
    { "STEER", "A D / ARROWS" }, { "ACCELERATE", "W / UP" }, { "BRAKE, REVERSE", "S / DOWN" },
    { "HANDBRAKE", "SHIFT" }, { "NITRO", "SPACE" }, { "LIGHTS", "F  G" },
    { "RESET TO TRACK", "R" }, { "CAMERA", "C" }, { "SHIFT GEARS", "Q E" }, { "NEXT SONG", "N" },
    { "HORN", "H" }, { "PAUSE", "ESC / P" },
  }
  if ui.mobile and settings.touchSteer == "buttons" then
    rows = {
      { "STEER", "LEFT, RIGHT" }, { "ACCELERATE", settings.autoGas and "AUTO" or "HOLD GAS" },
      { "BRAKE, REVERSE", "HOLD BRAKE" }, { "DRIFT", "HOLD DRIFT" }, { "BOOST", "TAP BOOST" },
      { "HORN, RESET, PAUSE", "TOP RIGHT" },
    }
  elseif ui.mobile then
    rows = {
      { "STEER", "STICK" }, { "ACCELERATE", "AUTO, OR STICK UP" }, { "BRAKE, REVERSE", "STICK DOWN" },
      { "DRIFT", "HOLD DRIFT" }, { "BOOST", "TAP BOOST" }, { "HORN, RESET, PAUSE", "TOP RIGHT" },
    }
  end
  local y = 72 * s
  for i, row in ipairs(rows) do
    ui.text(row[1], 14 * s, y + (i - 1) * 13 * s, 6 * s, colors.paint)
    ui.text(row[2], 0, y + (i - 1) * 13 * s, 6 * s, colors.marshal, "right", w - 14 * s)
  end
  if not ui.mobile then
    ui.text("PAD: R2 GAS, L2 BRAKE, R1 HANDBRAKE, L1 NITRO, SQUARE CROSS GEARS, D-PAD RIGHT NEXT SONG, CIRCLE HORN",
      14 * s, y + #rows * 13 * s + 4 * s, 6 * s, colors.muted, "left", w - 28 * s)
  end
end

local function drawCredits(sw, sh, s, w)
  ui.text("Created by VANILLAIICE", 14 * s, 76 * s, 6 * s, colors.paint)
  ui.text("Font: Press Start 2P by CodeMan38", 14 * s, 92 * s, 6 * s, colors.muted, "left", w - 28 * s)
  ui.text("Built with LOVE", 14 * s, 118 * s, 6 * s, colors.muted)
end

-- Where a screen's list sits, and how tall its rows are. Standard rows are about
-- 4 mm tall on a phone, too close for a thumb to pick RACE over TIME TRIAL, so
-- the main menu spreads out over the whole height there.
function menu.listLayout(screen, count, sh, s)
  if screen == "main" and ui.mobile then
    local y = 52 * s
    return y, (sh - y - 16 * s) / count
  end
  local rowH = math.min(15 * s, (sh - 96 * s) / count)
  return screen == "main" and 62 * s or 72 * s, rowH
end

function menu.draw(sw, sh)
  rm.drawScene(sw, sh)
  local s = ui.scale(sw, sh)

  local titles = {
    setup = MODES[settings.mode], settings = "SETTINGS", online = "ONLINE", host = "HOST A ROOM",
    controls = "CONTROLS", credits = "CREDITS",
  }
  -- A failure takes over the title, because the full list leaves no room below it.
  local failed = menu.screen == "online" and network.status == "error"
  local w = drawBoard(sw, sh, s, not failed and titles[menu.screen] or nil)
  if failed then ui.text(network.statusText(), 14 * s, 53 * s, 5 * s, colors.kerb, "left", w - 28 * s) end
  local x = 8 * s
  local listW = w - 22 * s
  local size = 7 * s

  if ui.consumeBack() then
    if menu.screen == "main" then
      -- nothing to go back to
    else
      if menu.screen == "online" then network.disconnect() end
      menu.go(menu.screen == "host" and "online" or "main")
    end
  end

  local def = SCREENS[menu.screen]
  if def then
    local rows = def.rows()
    local y, rowH = menu.listLayout(menu.screen, #rows, sh, s)
    local focused = ui.list(menu.screen, rows, x, y, listW, rowH, size, s)
    if menu.screen == "setup" or menu.screen == "host" then
      drawSetupPreview(sw, sh, w, s)
    elseif menu.screen == "online" and network.slot then
      drawLobby(sw, sh, w, s)
    elseif menu.screen == "online" then
      drawSetupPreview(sw, sh, w, s, true)
    end
    if menu.screen == "setup" then
      if focused.label == "HANDLING" then
        ui.text(ASSIST_HINTS[settings.assists], 14 * s, sh - 34 * s, 5 * s, colors.muted, "left", w - 28 * s)
      elseif focused.label == "MUSIC FOLDER" then
        ui.text(MUSIC_HINT, 14 * s, sh - 34 * s, 5 * s, colors.muted, "left", w - 28 * s)
      end
    end
    if menu.screen == "online" and not failed then
      ui.text(network.statusText(), 14 * s, y + #rows * rowH + 8 * s, 6 * s, colors.marshal, "left", w - 28 * s)
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
  if menu.screen == "online" then menu.updateOnline(dt) end
end

-- Runs in the menus and in a race, because a rematch starts from the results.
function menu.updateOnline(dt)
  network.update(dt)
  if network.ready then
    network.ready = false
    menu.startOnline()
  end
end

-- Nothing here touches the saved settings: this race is the host's, not yours.
function menu.startOnline()
  local cfg = network.raceConfig()
  local entry = { name = "online", title = cfg.title, def = cfg.def }
  -- A shared track came from someone else, so a bad one can't be allowed to throw.
  if not pcall(cachedTrack, entry) then
    network.fail("The host's track couldn't be built")
    return
  end
  local peers = {}
  for _, peer in ipairs(cfg.peers) do
    local spec = garage.byId(peer.car)
    local paint = PAINTS[peer.paint or 1]
    peers[#peers + 1] = {
      slot = peer.slot, spec = spec, color = paint and paint.color or spec.color,
      state = network.stateOf(peer.slot),
    }
  end
  menu.startRace({
    entry = entry, laps = cfg.laps, time = TIME_NAMES[cfg.time] and cfg.time or "day",
    online = { slot = cfg.slot, peers = peers, startIn = network.startIn },
  })
  network.raceLoaded()
end

-- Pause and results overlays ---------------------------------------------------

local RESULTS_SLIDE = 0.3

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
  -- An online race can't stop for one player, and their car is coasting.
  ui.text(rm.isOnline() and "RACE STILL RUNNING" or "PAUSED", x, y + 10 * s, 8 * s, colors.marshal, "center", w)
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
  local slide = math.min(1, rm.resultsAge() / RESULTS_SLIDE)
  local ease = 1 - (1 - slide) ^ 3
  love.graphics.setColor(0, 0, 0, 0.5 * ease)
  love.graphics.rectangle("fill", 0, 0, sw, sh)

  local order = race.order
  local w = math.min(sw - 16 * s, 300 * s)
  local rowH = 13 * s
  local h = 52 * s + rowH * #order + 40 * s
  local x, y = (sw - w) / 2, sh + ((sh - h) / 2 - sh) * ease
  ui.panel(x, y, w, h, 0.95)
  ui.kerb(x, y, w, 3 * s, s)

  local heading, headingColor = hud.finishHeading(race.player.place, race.player.timedOut)
  ui.text(heading, x, y + 12 * s, 12 * s, headingColor, "center", w)

  local listY = y + 36 * s
  for i, car in ipairs(order) do
    local ry = listY + (i - 1) * rowH
    if car == race.player then
      love.graphics.setColor(colors.marshal[1], colors.marshal[2], colors.marshal[3], 0.18)
      love.graphics.rectangle("fill", x + 6 * s, ry - 2 * s, w - 12 * s, rowH)
    end
    ui.text(i .. "  " .. car.name, x + 10 * s, ry, 6 * s, colors.paint)
    -- The panel opens with the others still out there: they fill in as they finish.
    local t = car.finished and hud.formatTime(car.finishTime)
      or (car.retired and "LEFT THE RACE")
      or (race.phase == "finished" and "DID NOT FINISH" or "RACING")
    ui.text(t, x, ry, 6 * s, colors.muted, "right", w - 10 * s)
  end

  -- No buttons until it lands, so a press meant for the car can't hit one.
  if slide < 1 then return end
  local rows = {}
  if not rm.isOnline() then
    rows[1] = { label = "RACE AGAIN", activate = function() rm.restart() end }
  elseif network.canRematch() then
    local voted, total = network.rematchCount()
    if network.hasVoted() then
      rows[1] = { label = string.format("WAITING %d/%d", voted, total), disabled = true }
    else
      rows[1] = { label = voted > 0 and string.format("REMATCH %d/%d", voted, total) or "REMATCH",
        activate = function() network.voteRematch() end }
    end
  end
  rows[#rows + 1] = { label = rm.opts().fromEditor and "BACK TO EDITOR" or "QUIT TO MENU", activate = quitRace }
  ui.list("results", rows, x + 8 * s, y + h - 36 * s, w - 16 * s, 15 * s, 7 * s, s)
end

return menu
