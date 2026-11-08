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
local music = require("src/music")
local network = require("src/network_manager")
local account = require("src/account")
local dynamics = require("src/sim/dynamics")
local cheats = require("src/cheats")
local input = require("src/input")

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
local RULES = { "open", "clean" }
local RULE_NAMES = { open = "OPEN", clean = "CLEAN" }
local RULE_HINTS = {
  open = "Every lap counts, however you get round.",
  clean = "Off the road, a cut, a reset or a wreck voids the lap.",
}
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
  "Lose the connection, or leave the game for a moment, and it gets you back in. Away for over 30 seconds, there's no way back in.",
  "Nobody checks results, so a changed game can cheat. Race people you trust.",
  "A slow connection makes cars look late, and contact can look wrong.",
  "Everyone drives with their own handling. ARCADE grips the most.",
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

-- Freestyle keeps its own track, so a drive round a circuit doesn't change the
-- race's. The lot is nil, and so is a track that's gone.
local LOT = "lot"
local function freestyleEntry()
  if settings.freestyleTrack == LOT then return nil end
  return catalog.find(settings.freestyleTrack)
end

local function currentCar()
  return garage[math.max(1, math.min(#garage, settings.car))]
end

local function currentColor(spec, hue)
  local paint = PAINTS[math.max(1, math.min(#PAINTS, hue or settings.hue))]
  return paint.color or spec.color
end

-- Each driver's own settings when two share the screen. P1's gearbox is the same
-- setting as CONTROLS > GEARBOX.
local DRIVER_KEYS = {
  { car = "car", hue = "hue", assists = "assists", gearbox = "gearbox" },
  { car = "car2", hue = "hue2", assists = "assists2", gearbox = "gearbox2" },
}

-- Whose car the setup and pause rows set when two share the screen: one driver
-- at a time, picked on the DRIVER row.
menu.driver = 1

local function driverKeys(two)
  return DRIVER_KEYS[two and menu.driver or 1]
end

-- Driver i's car and its paint.
local function driverCar(i)
  local keys = DRIVER_KEYS[i]
  local spec = garage[math.max(1, math.min(#garage, settings[keys.car]))]
  return spec, currentColor(spec, settings[keys.hue])
end

-- Two at one screen: a desktop with a pad for the second, in a race or freestyle.
-- Time trial is one driver's, against their own ghost.
function menu.canSplit(mode)
  mode = mode or settings.mode
  if ui.mobile or mode == "trial" then return false end
  return #input.gamepads() >= 1
end

local function splitting(mode)
  return settings.players == 2 and menu.canSplit(mode)
end

-- Who drives with what, as the PLAYERS row says it.
local function splitHint()
  local pads = input.gamepads()
  if #pads == 0 then return "Plug in a pad for the second driver." end
  local first = #pads >= 2 and "KEYBOARD OR " .. pads[1]:getName():upper() or "KEYBOARD"
  return "P1: " .. first .. ".  P2: " .. pads[#pads >= 2 and 2 or 1]:getName():upper() .. "."
end

-- A row on the keys or pad screen waiting for a press, and a short message said
-- in place of that screen's title. See "Setting keys and pad buttons" below.
local capture = nil  -- { kind = "key" or "pad", action =, age = }
local note = nil     -- { text =, age = }

function menu.go(screen)
  -- The setup screen always opens on P1.
  if screen == "setup" then menu.driver = 1 end
  menu.screen = screen
  ui.focus[screen] = ui.focus[screen] or 1
  capture, note = nil, nil
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
  local entry
  if mode == "freestyle" then entry = freestyleEntry() else entry = extra.entry or currentEntry() end
  local player2, playerName
  if not extra.online and not extra.fromEditor and splitting(mode) then
    local spec2, color2 = driverCar(2)
    player2 = { spec = spec2, color = color2, name = "P2",
      assist = settings.assists2, manualGearbox = settings.gearbox2 == "manual" }
    playerName = "P1"
  end
  rm.start({
    player2 = player2,
    playerName = playerName,
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
    rules = mode == "trial" and settings.trialRules or nil,
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

local function freestyleTrackRow()
  local names, titles = { LOT }, { [LOT] = "THE LOT" }
  for _, e in ipairs(catalog.all()) do
    names[#names + 1] = e.name
    titles[e.name] = e.title
  end
  return stepper("TRACK", function() return freestyleEntry() and settings.freestyleTrack or LOT end,
    function(v) settings.freestyleTrack = v end, names, titles)
end

-- key is the setting it changes: car, or car2 for the second driver. apply, if
-- given, runs once it has: the pause menu's way of changing the car on the road.
local function carRow(label, key, apply)
  key = key or "car"
  local ids, names = {}, {}
  for i, spec in ipairs(garage) do
    ids[i] = i
    names[i] = spec.name
  end
  return stepper(label or "CAR", function() return settings[key] end, function(v)
    settings[key] = v
    if apply then apply() end
  end, ids, names)
end

local function paintRow(label, key, apply)
  key = key or "hue"
  local ids, names = {}, {}
  for i, p in ipairs(PAINTS) do
    ids[i] = i
    names[i] = p.name
  end
  return stepper(label or "PAINT", function() return settings[key] end, function(v)
    settings[key] = v
    if apply then apply() end
  end, ids, names)
end

local function lapsRow()
  return numberStepper("LAPS", "laps", config.LAPS_MIN, config.LAPS_MAX)
end

local function timeRow()
  return stepper("TIME", function() return settings.time end,
    function(v) settings.time = v end, TIMES, TIME_NAMES)
end

local function handlingRow(label, key)
  return stepper(label, function() return settings[key] end,
    function(v) settings[key] = v end, ASSISTS, ASSIST_NAMES)
end

-- Picks whose car the rows under it set.
local function driverRow()
  return stepper("DRIVER", function() return menu.driver end,
    function(v) menu.driver = v end, { 1, 2 }, { "P1", "P2" })
end

local function setupRows()
  local rows = {}
  local mode = settings.mode
  rows[#rows + 1] = mode == "freestyle" and freestyleTrackRow() or trackRow()
  if menu.canSplit(mode) then
    rows[#rows + 1] = stepper("PLAYERS", function() return settings.players end,
      function(v) settings.players = v end, { 1, 2 })
  end
  local two = splitting(mode)
  if two then
    -- One driver's car, paint, handling and gearbox at a time.
    local keys = driverKeys(true)
    rows[#rows + 1] = driverRow()
    rows[#rows + 1] = carRow("CAR", keys.car)
    rows[#rows + 1] = paintRow("PAINT", keys.hue)
    rows[#rows + 1] = handlingRow("HANDLING", keys.assists)
    rows[#rows + 1] = stepper("GEARBOX", function() return settings[keys.gearbox] end,
      function(v) settings[keys.gearbox] = v end, { "auto", "manual" }, { auto = "AUTO", manual = "MANUAL" })
  else
    rows[#rows + 1] = carRow()
    rows[#rows + 1] = paintRow()
  end
  -- Open counts every lap; clean voids one that goes off, cuts, resets or wrecks.
  if mode == "trial" then
    rows[#rows + 1] = stepper("RULES", function() return settings.trialRules end,
      function(v) settings.trialRules = v end, RULES, RULE_NAMES)
  end

  if mode == "race" then
    rows[#rows + 1] = lapsRow()
    rows[#rows + 1] = numberStepper("OPPONENTS", "opponents", 0, config.OPPONENTS_MAX)
    rows[#rows + 1] = stepper("DIFFICULTY", function() return settings.difficulty end,
      function(v) settings.difficulty = v end, DIFFICULTIES, DIFFICULTY_NAMES)
  end
  rows[#rows + 1] = timeRow()
  if not two then rows[#rows + 1] = handlingRow("HANDLING", "assists") end
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
    toggle("MUSIC", "music"),
    stepper("SONG", function() return music.take() end, function(v)
      settings.musicTake = v
      music.setTake(v)
    end, music.ORDER, { a = music.TAKES.a.name, b = music.TAKES.b.name, c = music.TAKES.c.name }),
    stepper("CAMERA", function() return settings.camera end, function(v) settings.camera = v end,
      { "chase", "fixed" }, { chase = "CHASE", fixed = "FIXED" }),
    stepper("ZOOM", function() return settings.zoom end, function(v) settings.zoom = v end,
      { "near", "mid", "far" }, { near = "NEAR", mid = "MID", far = "FAR" }),
    stepper("UNITS", function() return settings.units end, function(v) settings.units = v end,
      { "kmh", "mph" }, { kmh = "KM/H", mph = "MPH" }),
    stepper("EFFECTS", function() return settings.quality end, function(v)
      settings.quality = v
      require("src/render/post").quality = v
    end, QUALITY, { high = "HIGH", low = "LOW" }),
    toggle("PACE NOTES", "paceNotes"),
    toggle("MINIMAP", "minimap"),
    toggle("SHOW FPS", "showFps"),
  }
  -- A phone always fills the screen.
  if not ui.mobile then
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

-- How the car is driven, by every kind of hand. AUTO shows the touch controls
-- after a touch, and hides them for a key or a pad.
local TOUCH_SIZES = { "small", "medium", "large" }
local TOUCH_SIZE_NAMES = { small = "SMALL", medium = "MEDIUM", large = "LARGE" }
local OPACITIES = { 0.25, 0.5, 0.75, 1 }
local OPACITY_NAMES = { [0.25] = "25%", [0.5] = "50%", [0.75] = "75%", [1] = "100%" }

local function controlsRows()
  local rows = {
    stepper("TOUCH CONTROLS", function() return settings.touch end,
      function(v) settings.touch = v end, { "auto", "on", "off" }, { auto = "AUTO", on = "ON", off = "OFF" }),
    stepper("TOUCH STEERING", function() return settings.touchSteer end,
      function(v) settings.touchSteer = v end, { "stick", "buttons" }, { stick = "STICK", buttons = "BUTTONS" }),
    toggle("AUTO GAS", "autoGas"),
    stepper("GEARBOX", function() return settings.gearbox end, function(v) settings.gearbox = v end,
      { "auto", "manual" }, { auto = "AUTO", manual = "MANUAL" }),
    stepper("TOUCH SIZE", function() return settings.touchSize end,
      function(v) settings.touchSize = v end, TOUCH_SIZES, TOUCH_SIZE_NAMES),
    stepper("TOUCH OPACITY", function() return settings.touchOpacity end,
      function(v) settings.touchOpacity = v end, OPACITIES, OPACITY_NAMES),
    toggle("VIBRATION", "vibration"),
  }
  if not ui.mobile then rows[#rows + 1] = { label = "KEYBOARD", activate = function() menu.go("keys") end } end
  rows[#rows + 1] = { label = "PAD", activate = function() menu.go("pad") end }
  if ui.mobile then rows[#rows + 1] = { label = "BUTTON LIST", activate = function() menu.go("buttons") end } end
  rows[#rows + 1] = { label = "BACK", activate = function() menu.go("main") end }
  return rows
end

-- Setting keys and pad buttons ----------------------------------------------------
-- Picking a row waits for the next key or button, which takes that action over.
-- Whatever had it before gets the row's old one, so nothing is left without.

local ACTION_LABELS = {
  throttle = "ACCELERATE", brake = "BRAKE, REVERSE", steerLeft = "STEER LEFT", steerRight = "STEER RIGHT",
  handbrake = "HANDBRAKE", boost = "BOOST", shiftUp = "SHIFT UP", shiftDown = "SHIFT DOWN",
  lowBeam = "LOW BEAMS", highBeam = "HIGH BEAMS", respawn = "RESET TO TRACK", camera = "CAMERA",
  radio = "NEXT SONG", horn = "HORN", pause = "PAUSE",
}
menu.ACTION_LABELS = ACTION_LABELS

local KEY_NAMES = {
  lshift = "L SHIFT", rshift = "R SHIFT", lctrl = "L CTRL", rctrl = "R CTRL", lalt = "L ALT", ralt = "R ALT",
  lgui = "L SUPER", rgui = "R SUPER", ["return"] = "ENTER", kpenter = "NUM ENTER", escape = "ESC",
  capslock = "CAPS LOCK", pageup = "PAGE UP", pagedown = "PAGE DOWN", backspace = "BACKSPACE",
  printscreen = "PRT SC", scrolllock = "SCR LK", numlock = "NUM LK", application = "MENU",
}

function menu.keyName(key)
  if KEY_NAMES[key] then return KEY_NAMES[key] end
  local pad = key:match("^kp(.+)$")
  if pad then return "NUM " .. pad:upper() end
  return key:upper()
end

-- PlayStation names first, then Xbox: a pad shows its own, or both without one.
local BUTTON_NAMES = {
  a = { "CROSS", "A" }, b = { "CIRCLE", "B" }, x = { "SQUARE", "X" }, y = { "TRIANGLE", "Y" },
  back = { "SHARE", "BACK" }, start = { "OPTIONS", "START" }, leftstick = { "L3", "LS" },
  rightstick = { "R3", "RS" }, leftshoulder = { "L1", "LB" }, rightshoulder = { "R1", "RB" },
  dpup = "D-PAD UP", dpdown = "D-PAD DOWN", dpleft = "D-PAD LEFT", dpright = "D-PAD RIGHT",
}
local TRIGGER_NAMES = { throttle = { "R2", "RT" }, brake = { "L2", "LT" } }

-- 1 for a PlayStation pad, 2 for any other, nil with none plugged in.
function menu.padFamily(pad)
  pad = pad or (input.padConnected() and input.gamepad) or input.gamepads()[1]
  if not pad then return nil end
  local name = pad:getName():lower()
  for _, word in ipairs({ "playstation", "dualshock", "dualsense", "ps3", "ps4", "ps5", "sony",
    "wireless controller" }) do
    if name:find(word, 1, true) then return 1 end
  end
  return 2
end

function menu.buttonName(button, family)
  local name = BUTTON_NAMES[button] or TRIGGER_NAMES[button]
  if type(name) == "string" then return name end
  if not name then return button:upper() end
  return family and name[family] or (name[1] .. "/" .. name[2])
end

local CAPTURE_TIME = 6  -- seconds a row waits for a press
local NOTE_TIME = 2.5
local textTaken = false

local function say(text)
  note = { text = text, age = 0 }
end

local function startCapture(kind, action)
  if kind == "pad" and #input.gamepads() == 0 then
    say("CONNECT A PAD FIRST")
    return
  end
  capture = { kind = kind, action = action, age = 0 }
  note = nil
end

menu.startCapture = startCapture

function menu.capturing()
  return capture
end

function menu.cancelCapture()
  capture = nil
end

-- A key pressed while a row waits. True when it was used up here.
function menu.takeKey(key, isRepeat)
  if not capture then return false end
  textTaken = true
  if isRepeat then return true end
  local kind, action = capture.kind, capture.action
  if key == "escape" or kind ~= "key" then
    -- A pad row only listens to the pad. Esc lets go of either.
    if key == "escape" then capture = nil end
    return true
  end
  capture = nil
  if input.rebindKey(action, key) then
    settings.keys = input.keyChanges()
    settings.save()
    ui.played = "select"
  else
    for other, fixed in pairs(input.FIXED_KEYS) do
      if fixed == key then say(menu.keyName(key) .. " IS KEPT FOR " .. ACTION_LABELS[other]:match("^[^,]+")) end
    end
  end
  return true
end

-- A pad button pressed while a row waits. On a keyboard row it lets go.
function menu.takeButton(button)
  if not capture then return false end
  local kind, action = capture.kind, capture.action
  capture = nil
  if kind ~= "pad" then return true end
  local ok, why = input.rebindButton(action, button)
  if ok then
    settings.padButtons = input.buttonChanges()
    settings.save()
    ui.played = "select"
  elseif why == "pause" then
    say("PAUSE NEEDS A BUTTON")
  else
    say("PICK ANOTHER BUTTON")
  end
  return true
end

-- True when the key that made this text was taken by a waiting row.
function menu.textTaken()
  return textTaken
end

local function updateRemap(dt)
  textTaken = false
  if capture then
    capture.age = capture.age + dt
    if capture.age > CAPTURE_TIME then capture = nil end
  end
  if note then
    note.age = note.age + dt
    if note.age > NOTE_TIME then note = nil end
  end
end

-- What a keys or pad screen says in place of its title.
local function remapTitle(plain)
  if note then return note.text, colors.kerb end
  if capture then return capture.kind == "key" and "ESC CANCELS" or "ESC OR WAIT TO CANCEL", colors.marshal end
  return plain, colors.marshal
end

local function waiting(kind, action)
  return capture and capture.kind == kind and capture.action == action
end

local function keyRows()
  local rows = {}
  for _, action in ipairs(input.ACTIONS) do
    rows[#rows + 1] = { label = ACTION_LABELS[action], value = function()
        if waiting("key", action) then return "PRESS A KEY" end
        local fixed = input.fixedKeyFor(action)
        return menu.keyName(input.keyFor(action)) .. (fixed and " / " .. menu.keyName(fixed) or "")
      end, activate = function() startCapture("key", action) end }
  end
  rows[#rows + 1] = { label = "RESET KEYS", activate = function()
    input.resetKeys()
    settings.keys = {}
    settings.save()
    say("KEYS RESET")
  end }
  rows[#rows + 1] = { label = "BACK", activate = function() menu.go("controls") end }
  return rows
end

local function padRows()
  local family = menu.padFamily()
  local rows = {
    { label = "STEER", value = "LEFT STICK", disabled = true },
  }
  for _, action in ipairs(input.PAD_ACTIONS) do
    rows[#rows + 1] = { label = ACTION_LABELS[action], value = function()
        if waiting("pad", action) then return "PRESS A BUTTON" end
        local button = input.buttonFor(action)
        local name = button and menu.buttonName(button, family)
        if TRIGGER_NAMES[action] then
          local trigger = menu.buttonName(action, family)
          -- Without a pad both names show, and both triggers too would run long.
          if name and not family then return "+ " .. name end
          return name and trigger .. " + " .. name or trigger
        end
        return name or "NONE"
      end, activate = function() startCapture("pad", action) end }
  end
  rows[#rows + 1] = { label = "RESET PAD", activate = function()
    input.resetButtons()
    settings.padButtons = {}
    settings.save()
    say("PAD RESET")
  end }
  rows[#rows + 1] = { label = "BACK", activate = function() menu.go("controls") end }
  return rows
end

-- What a driver brings to an online race: car, paint, and the handling and
-- gearbox they drive with.
local function onlineSelf()
  return { car = currentCar().id, paint = settings.hue, handling = settings.assists, gearbox = settings.gearbox }
end

-- How a driver's car is set up, for the lobby and the results. A 3.0 game
-- doesn't say, and drives ARCADE.
local function setupText(handling, gearbox)
  if not handling then return nil end
  return ASSIST_NAMES[handling] .. " " .. (gearbox == "manual" and "MANUAL" or "AUTO")
end
menu.setupText = setupText

-- Everyone picks their own car and setup here. The race itself is the host's to
-- set, on the next screen, or the server's in a quick match, so a joiner never
-- sees choices that wouldn't count. Once connecting, there's nothing left to
-- choose and the status gets the room.
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
  if busy and (network.role == "queue" or network.isMatch()) then
    return { { label = "CANCEL", activate = function() network.disconnect() end }, back }
  end
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
    handlingRow("HANDLING", "assists"),
    stepper("GEARBOX", function() return settings.gearbox end, function(v) settings.gearbox = v end,
      { "auto", "manual" }, { auto = "AUTO", manual = "MANUAL" }),
    { label = "PROFILE", value = function()
        local driver = account.driver()
        return driver and driver.name or "NO NAME"
      end, activate = function() menu.openProfile() end },
    { label = "QUICK MATCH", activate = function() menu.quickMatch() end },
    { label = "HOST A ROOM", activate = function() menu.go("host") end },
    room,
    { label = "JOIN A ROOM", disabled = network.roomCode == "", activate = function() menu.connect("join") end },
    { label = "PRIVACY & TERMS", activate = function() love.system.openURL(config.PRIVACY_URL) end },
    back,
  }
end
menu.onlineRows = onlineRows

-- PROFILE: the name the others see online. A driver is kept by the server in
-- SETTINGS, and this device holds a key to it.
local confirming = nil   -- a row waiting for its second press

function menu.openProfile()
  confirming, menu.showCode = nil, false
  account.message = ""
  if account.driver() then account.refresh() end
  menu.go("profile")
end

-- `start` is what the field holds when it opens, when there's something to offer.
local function editRow(label, field, value, pattern, max, done, start)
  return { label = label, disabled = account.busy ~= nil, value = function()
      if ui.editing and ui.editing.field == field then return ui.editing.value .. "_" end
      return value and value() or ""
    end, activate = function()
      ui.startEditing("", function(v) if v ~= "" then done(v) end end, pattern, max)
      ui.editing.field = field
      if start then ui.textinput(start() or "") end
    end }
end

-- A recovery code already on the clipboard, copied on another device, fills the
-- field by itself.
local function copiedCode()
  local text = love.system.getClipboardText()
  return text and account.readCode(text) and text or nil
end

-- A row that does something hard to undo asks for a second press.
local function confirmRow(label, again, run)
  return { label = confirming == label and again or label, disabled = account.busy ~= nil, activate = function()
    if confirming == label then
      confirming = nil
      run()
    else
      confirming = label
    end
  end }
end

local function profileRows()
  local back = { label = "BACK", activate = function()
    account.cancel()
    menu.go("online")
  end }
  local driver = account.driver()
  if not driver then
    return {
      editRow("PICK A NAME", "name", nil, "^[%w_%-]$", 12, account.signUp),
      editRow("I HAVE A RECOVERY CODE", "code", nil, "^[%w%-]$", 48, account.recover, copiedCode),
      back,
    }
  end
  return {
    editRow("NAME", "rename", function() return driver.name end, "^[%w_%-]$", 12, account.rename),
    { label = menu.showCode and "HIDE RECOVERY CODE" or "SHOW RECOVERY CODE", activate = function()
      menu.showCode = not menu.showCode
    end },
    { label = "COPY RECOVERY CODE", activate = function()
      love.system.setClipboardText(account.recoveryCode())
      account.message = "Copied. Keep it somewhere safe."
    end },
    confirmRow("SIGN OUT OF THIS DEVICE", "PRESS AGAIN TO SIGN OUT", account.signOut),
    confirmRow("DELETE DRIVER", "PRESS AGAIN TO DELETE", account.forget),
    back,
  }
end
menu.profileRows = profileRows

-- What goes under the list: the code when it's asked for, then whatever the
-- server last said, or what a driver is for.
function menu.profileText()
  local driver = account.driver()
  if account.busy then return "WAITING FOR THE SERVER..." end
  local lines = {}
  if driver and menu.showCode then
    lines[#lines + 1] = account.recoveryCode()
    lines[#lines + 1] = "Paste it into PROFILE on another device to race as " .. driver.name
      .. " there. Anyone with it can. Lose it and every device, and the driver is gone."
  end
  if account.message ~= "" then lines[#lines + 1] = account.message end
  if #lines == 0 then
    if driver then
      local profile = account.profile
      lines[1] = profile and string.format("Since %s, on %d %s.", profile.since, profile.devices,
        profile.devices == 1 and "device" or "devices") or ""
      if confirming == "SIGN OUT OF THIS DEVICE" then
        lines[1] = "You'll need your recovery code to get " .. driver.name .. " back on this device."
      elseif confirming == "DELETE DRIVER" then
        lines[1] = driver.name .. " goes from every device, for good."
      end
    else
      lines[1] = "Pick a name and the others see it online, instead of P2. No email, no password: "
        .. "this device holds a key, and a recovery code moves it to another."
    end
  end
  return table.concat(lines, "\n\n")
end

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
  local host, port = settings.serverAddress()
  network.connect(host, port, role, network.roomCode, onlineSelf(), race)
  menu.go("online")
  ui.focus.online = 2  -- START RACE or CANCEL, once the list has shrunk
end

-- Looks for a race with whoever else is looking: no code, and the server picks.
function menu.quickMatch()
  local host, port = settings.serverAddress()
  network.queue(host, port, onlineSelf())
  menu.go("online")
  ui.focus.online = 1  -- CANCEL
end

function menu.testDrive(doc, track)
  local spec = currentCar()
  menu.demoRunning = false
  rm.start({
    mode = "trial", track = track, spec = spec, color = currentColor(spec),
    laps = 9999, opponents = 0, time = settings.time, fromEditor = true, rules = settings.trialRules,
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
  controls = { rows = controlsRows },
  keys = { rows = keyRows },
  pad = { rows = padRows },
  online = { rows = onlineRows },
  profile = { rows = profileRows },
  host = { rows = hostRows },
}

local function drawBoard(sw, sh, s, title, titleColor)
  local w = sw > sh and math.min(sw, math.max(250 * s, sw * 0.4)) or sw
  ui.panel(0, 0, w, sh, 0.9)
  love.graphics.setColor(colors.kerb)
  love.graphics.rectangle("fill", w, 0, 2 * s, sh)
  ui.kerb(14 * s, 44 * s, w - 28 * s, 4 * s, s)
  ui.text("SPPPD", 14 * s, 14 * s, 22 * s, colors.marshal)
  if title then
    ui.text(title, 14 * s, 56 * s, 7 * s, titleColor or colors.marshal)
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

  -- The driver the rows are setting, when two share the screen. Online is one
  -- driver's, even with two chosen for races here.
  local two = not carOnly and menu.screen == "setup" and splitting()
  local spec, color = driverCar(two and menu.driver or 1)

  local entry
  if not carOnly then
    if settings.mode == "freestyle" then entry = freestyleEntry() else entry = currentEntry() end
  end
  if entry then
    local data = cachedTrack(entry)
    -- Stops short of the car panel on a screen as low as a phone's.
    local size = math.min(w, sh * 0.5, sh - 138 * s)
    ui.panel(x, 14 * s, w, size + 34 * s, 0.82)
    minimap.drawOutline(data.track, data.line, x + (w - size) / 2 + 10 * s, 20 * s, size - 20 * s, 3, colors.paint)
    ui.text(entry.title, x + 6 * s, 14 * s + size + 8 * s, 8 * s, colors.marshal)
    local detail = string.format("%.2f KM", data.track.length / config.METER / 1000)
    ui.text(detail, x, 14 * s + size + 8 * s, 6 * s, colors.paint, "right", w - 6 * s)
    -- Freestyle times nothing, so a best lap means nothing there.
    if settings.mode ~= "freestyle" then
      local best = settings.bestLap(entry.name, spec.id, settings.trialRules)
      ui.text("BEST " .. hud.formatTime(best), x + 6 * s, 14 * s + size + 20 * s, 6 * s,
        best and colors.sectorPurple or colors.muted)
    end
  end

  if carOnly then drawOnlineNotes(x, 14 * s, w, s) end

  local panelH = 72 * s
  local py = sh - panelH - 14 * s
  ui.panel(x, py, w, panelH, 0.82)
  drawCar(spec, color, x + 42 * s, py + panelH / 2, s, 0)
  local tx = x + 84 * s
  ui.text(spec.name, tx, py + 7 * s, 8 * s, colors.paint)
  if two then ui.text("P" .. menu.driver, x, py + 7 * s, 8 * s, colors.marshal, "right", w - 6 * s) end
  ui.text(string.format("%.0f KW  %s  %.0f KG", dynamics.peakPower(spec) / 1000, spec.drive, spec.mass),
    tx, py + 21 * s, 6 * s, colors.marshal)
  ui.text(spec.blurb, tx, py + 33 * s, 6 * s, colors.muted, "left", w - 90 * s)
end

-- Who's in the room and what they're racing for, down the side of the lobby.
local function drawLobby(sw, sh, boardW, s)
  local x = boardW + 14 * s
  local w = sw - x - 14 * s
  if w < 120 * s then return end
  local setup, match = network.setup, network.match
  local rowH = 20 * s
  ui.panel(x, 14 * s, w, 44 * s + rowH * network.MAX_PLAYERS, 0.82)
  local title = setup and setup.title or network.matchTitle()
  ui.text(title or "GETTING THE RACE...", x + 6 * s, 21 * s, 8 * s, colors.marshal)
  local laps, time = setup and setup.laps or match and match.laps, setup and setup.time or match and match.time
  if laps then
    laps = laps == 1 and "1 LAP" or laps .. " LAPS"
    ui.text(laps .. "  " .. (TIME_NAMES[time] or "DAY"), x + 6 * s, 35 * s, 6 * s, colors.paint)
  end
  if match then ui.text("QUICK MATCH", x, 35 * s, 6 * s, colors.kerb, "right", w - 6 * s) end

  local drivers = network.peerList()
  local me = network.me
  table.insert(drivers, { slot = network.slot, car = me.car, paint = me.paint, have = network.def ~= nil, you = true,
    handling = me.handling, gearbox = me.gearbox })
  table.sort(drivers, function(a, b) return a.slot < b.slot end)
  local y = 52 * s
  for i, driver in ipairs(drivers) do
    local ry = y + (i - 1) * rowH
    local spec = driver.car and garage.byId(driver.car)
    if spec then
      local paint = PAINTS[driver.paint or 1]
      love.graphics.setColor(paint and paint.color or spec.color)
      love.graphics.rectangle("fill", x + 6 * s, ry + s, 3 * s, 14 * s)
    end
    ui.text(network.nameOf(driver.slot) .. "  " .. (spec and spec.name or "..."), x + 13 * s, ry + 2 * s, 6 * s,
      driver.you and colors.marshal or colors.paint)
    if driver.car then
      ui.text(setupText(driver.handling, driver.gearbox) or "ARCADE", x + 13 * s, ry + 10 * s, 5 * s, colors.muted)
    end
    local host = not match and driver.slot == network.leader
    local note = driver.you and "YOU" or (host and "HOST") or (not driver.have and "GETTING TRACK") or ""
    ui.text(note, x, ry + 2 * s, 6 * s, colors.muted, "right", w - 6 * s)
  end
end

-- The on-screen controls, for a phone. Keys and pad buttons have screens of
-- their own, where they can be changed.
local function touchRows()
  local gas = settings.autoGas and "AUTO" or "HOLD GAS"
  local rows
  if settings.touchSteer == "buttons" then
    rows = {
      { "STEER", "LEFT, RIGHT" }, { "ACCELERATE", gas }, { "BRAKE, REVERSE", "HOLD BRAKE" },
    }
  else
    rows = {
      { "STEER", "STICK" }, { "ACCELERATE", settings.autoGas and "AUTO" or "STICK UP" },
      { "BRAKE, REVERSE", "STICK DOWN" },
    }
  end
  rows[#rows + 1] = { "DRIFT", "HOLD DRIFT" }
  rows[#rows + 1] = { "BOOST", "TAP BOOST" }
  if settings.gearbox == "manual" then rows[#rows + 1] = { "SHIFT GEARS", "DOWN LEFT, UP RIGHT" } end
  rows[#rows + 1] = { "HORN, RESET, PAUSE", "TOP RIGHT" }
  return rows
end

function menu.buttonRows()
  return touchRows()
end

local function drawButtonList(sw, sh, s, w)
  local rows = menu.buttonRows()
  local y = 72 * s
  -- Clear of BACK, which sits 34 up from the bottom.
  local step = math.min(13 * s, (sh - 38 * s - y) / #rows)
  for i, row in ipairs(rows) do
    ui.text(row[1], 14 * s, y + (i - 1) * step, 6 * s, colors.paint)
    ui.text(row[2], 0, y + (i - 1) * step, 6 * s, colors.marshal, "right", w - 14 * s)
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
    setup = MODES[settings.mode], settings = "SETTINGS", online = "ONLINE", host = "HOST A ROOM", profile = "PROFILE",
    controls = "CONTROLS", buttons = "BUTTON LIST", credits = "CREDITS", keys = "KEYBOARD", pad = "PAD",
  }
  local title, titleColor = titles[menu.screen], nil
  if menu.screen == "keys" or menu.screen == "pad" then
    title, titleColor = remapTitle(title)
    -- A click or tap anywhere lets go of a waiting row, and does nothing else.
    if capture and ui.clicked then
      capture = nil
      ui.clicked = false
    end
  end
  -- A failure takes over the title, because the full list leaves no room below it.
  local failed = menu.screen == "online" and network.status == "error"
  local w = drawBoard(sw, sh, s, not failed and title or nil, titleColor)
  if failed then ui.text(network.statusText(), 14 * s, 53 * s, 5 * s, colors.kerb, "left", w - 28 * s) end
  local x = 8 * s
  local listW = w - 22 * s
  local size = 7 * s

  if ui.consumeBack() then
    if menu.screen == "main" then
      -- nothing to go back to
    else
      if menu.screen == "online" then network.disconnect() end
      if menu.screen == "profile" then account.cancel() end
      local up = { host = "online", profile = "online", buttons = "controls", keys = "controls", pad = "controls" }
      menu.go(up[menu.screen] or "main")
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
        ui.text(ASSIST_HINTS[settings[driverKeys(splitting()).assists]], 14 * s, sh - 34 * s, 5 * s, colors.muted,
          "left", w - 28 * s)
      elseif focused.label == "RULES" then
        ui.text(RULE_HINTS[settings.trialRules], 14 * s, sh - 34 * s, 5 * s, colors.muted, "left", w - 28 * s)
      elseif focused.label == "MUSIC FOLDER" then
        ui.text(MUSIC_HINT, 14 * s, sh - 34 * s, 5 * s, colors.muted, "left", w - 28 * s)
      elseif focused.label == "PLAYERS" or focused.label == "DRIVER" then
        ui.text(splitHint(), 14 * s, sh - 34 * s, 5 * s, colors.muted, "left", w - 28 * s)
      end
    end
    if menu.screen == "profile" then
      ui.text(menu.profileText(), 14 * s, y + #rows * rowH + 8 * s, 6 * s, colors.marshal, "left", w - 28 * s)
    end
    if menu.screen == "online" and not failed then
      ui.text(network.statusText(), 14 * s, y + #rows * rowH + 8 * s, 6 * s, colors.marshal, "left", w - 28 * s)
    end
  else
    local back = menu.screen == "buttons" and "controls" or "main"
    local rows = { { label = "BACK", activate = function() menu.go(back) end } }
    if menu.screen == "buttons" then drawButtonList(sw, sh, s, w)
    else drawCredits(sw, sh, s, w) end
    ui.list(menu.screen, rows, x, sh - 34 * s, listW, 15 * s, size, s)
  end
end

function menu.update(dt)
  updateRemap(dt)
  account.update(dt)
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
      slot = peer.slot, name = network.names[peer.slot], spec = spec, color = paint and paint.color or spec.color,
      state = network.stateOf(peer.slot), setup = setupText(peer.handling, peer.gearbox) or "ARCADE",
    }
  end
  menu.startRace({
    entry = entry, laps = cfg.laps, time = TIME_NAMES[cfg.time] and cfg.time or "day",
    online = { slot = cfg.slot, peers = peers, startIn = network.startIn,
      setup = setupText(settings.assists, settings.gearbox) },
  })
  network.raceLoaded()
end

-- Pause and results overlays ---------------------------------------------------

local RESULTS_SLIDE = 0.3

local function quitRace()
  local opts = rm.race() and rm.opts()
  local fromEditor = opts and opts.fromEditor
  menu.voting = false
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

-- Leaves a quick match's results and looks for another race in one press.
local function findAnother()
  menu.voting = false
  network.findAnother()
  rm.stop()
  ui.nav = {}
  menu.demoRunning = false
  menu.enter()
  menu.go("online")
  ui.focus.online = 1
end

-- The other drivers, to vote one out of a quick match. Two votes remove them.
local function voteRows()
  local rows = {}
  for _, peer in ipairs(network.peerList()) do
    local spec = peer.car and garage.byId(peer.car)
    local voted = network.hasVotedOut(peer.slot)
    rows[#rows + 1] = {
      label = network.nameOf(peer.slot) .. "  " .. (spec and spec.name or "..."),
      value = voted and function() return "VOTED" end or nil,
      disabled = voted,
      activate = function()
        network.voteOut(peer.slot)
        menu.voting = false
      end,
    }
  end
  rows[#rows + 1] = { label = "BACK", activate = function() menu.voting = false end }
  return rows
end

-- Freestyle's car and paint, changed on the road from the pause menu. The
-- saved settings follow, so the setup screen shows them next time too.
function menu.applyCar(index)
  rm.swapCar(index, driverCar(index))
end

-- With two at the screen, DRIVER picks whose car CAR and PAINT change, as in setup.
local function pauseCarRows(rows)
  if not rm.canSwapCars() then return false end
  local two = rm.isSplit()
  local index = two and menu.driver or 1
  local keys = driverKeys(two)
  local apply = function() menu.applyCar(index) end
  if two then rows[#rows + 1] = driverRow() end
  rows[#rows + 1] = carRow("CAR", keys.car, apply)
  rows[#rows + 1] = paintRow("PAINT", keys.hue, apply)
  return true
end

function menu.drawPause(sw, sh)
  local s = ui.scale(sw, sh)
  love.graphics.setColor(0, 0, 0, 0.55)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  local fromEditor = rm.opts().fromEditor
  local canVote = rm.isOnline() and network.canVoteOut()
  if not canVote then menu.voting = false end
  local rows = {
    { label = "RESUME", activate = function() rm.setPaused(false) end },
  }
  if not rm.isOnline() then
    rows[#rows + 1] = { label = "RESTART", activate = function() rm.restart() end }
  end
  -- After RESTART, so RESUME and RESTART stay where hands know them.
  local cars = pauseCarRows(rows)
  if canVote then
    rows[#rows + 1] = { label = "VOTE OUT", activate = function()
      menu.voting = true
      ui.focus.vote = 1
    end }
  end
  rows[#rows + 1] = { label = fromEditor and "BACK TO EDITOR" or "QUIT TO MENU", activate = quitRace }
  local list, heading = "pause", nil
  if menu.voting then
    rows, list, heading = voteRows(), "vote", "VOTE OUT"
  end
  -- Wide enough for "PAINT  < SUNSET ORANGE >".
  local w = (cars and 230 or 190) * s
  local x = (sw - w) / 2
  local y = sh * 0.3
  ui.panel(x, y, w, 28 * s + #rows * 16 * s, 0.95)
  ui.kerb(x, y, w, 3 * s, s)
  -- An online race can't stop for one player, and their car is coasting.
  ui.text(heading or (rm.isOnline() and "RACE STILL RUNNING" or "PAUSED"), x, y + 10 * s, 8 * s, colors.marshal,
    "center", w)
  ui.list(list, rows, x + 8 * s, y + 24 * s, w - 16 * s, 16 * s, 7 * s, s)
  if ui.consumeBack() then
    if menu.voting then menu.voting = false else rm.setPaused(false) end
  end
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
  if #race.players > 1 then heading, headingColor = hud.splitHeading(race.players) end
  ui.text(heading, x, y + 12 * s, 12 * s, headingColor, "center", w)

  local listY = y + 36 * s
  for i, car in ipairs(order) do
    local ry = listY + (i - 1) * rowH
    if car.isPlayer then
      love.graphics.setColor(colors.marshal[1], colors.marshal[2], colors.marshal[3], 0.18)
      love.graphics.rectangle("fill", x + 6 * s, ry - 2 * s, w - 12 * s, rowH)
    end
    local name = car.setupText and (car.name .. "  " .. car.spec.name .. "  " .. car.setupText) or car.name
    ui.text(i .. "  " .. name, x + 10 * s, ry, 6 * s, colors.paint)
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
  if rm.isOnline() and network.isMatch() then
    rows[#rows + 1] = { label = "FIND ANOTHER", activate = findAnother }
  end
  rows[#rows + 1] = { label = rm.opts().fromEditor and "BACK TO EDITOR" or "QUIT TO MENU", activate = quitRace }
  ui.list("results", rows, x + 8 * s, y + h - 36 * s, w - 16 * s, 15 * s, 7 * s, s)
end

return menu
