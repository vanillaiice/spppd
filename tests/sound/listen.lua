-- A bench for judging the sounds by ear: `love . --visual listen`, or `make listen`.
-- TAB swaps between the sounds before the 2026-11 pass and the current ones while
-- anything is playing. Both sides are the real modules, each running its own
-- audio.update on the same fake car, so this compares what the game does and not
-- only the samples. The old side renders on every start, so opening takes a moment.
local garage = require("src/entities/garage")
local audio = require("src/audio")
local scenes = require("tests/sound/scenes")

local listen = {}

local WIDTH, HEIGHT = 1040, 680
local SWEEP_UP, SWEEP_DOWN = 5, 3  -- seconds
local SHIFT_TIME = 0.11

local INK = { 0.92, 0.94, 0.97 }
local DIM = { 0.68, 0.72, 0.78 }
local BAR = { 0.2, 0.24, 0.3 }
local NEW_COLOUR = { 0.25, 0.85, 0.55 }
local OLD_COLOUR = { 0.95, 0.6, 0.2 }
-- A plain typeface at the window's real pixels, because this is mostly small print.
-- The game's pixel font only holds together at whole multiples of its own size.
local TEXT, SMALL, HEADING, TITLE = 15, 13, 20, 26
local ROW = 22

local sides = {}
local side = "new"
local car, spec
local carIndex = 1
local running = true
local sweeping
local held = { throttle = false }
local toggles = { nitro = false, grass = false, wall = false, brake = false, limiter = false }
local sliders = {
  { key = "revs", label = "Revs", value = 0, max = 1 },
  { key = "throttle", label = "Throttle", value = 0, max = 1 },
  { key = "speed", label = "Speed", value = 0, max = 90, unit = " m/s" },
  { key = "slide", label = "Slide", value = 0, max = 1 },
}
local focus, dragging = 1, nil
local fonts = {}
local lastPlayed = ""

local function slider(key)
  for _, s in ipairs(sliders) do
    if s.key == key then return s end
  end
end

-- The sounds as they stood, from the untouched copy of the old module. It keeps its
-- samples in memory: writing them to the cache would clear out the current ones.
local function loadOriginal()
  local real = package.loaded["src/sound_cache"]
  local function nothing() end
  package.loaded["src/sound_cache"] = {
    open = nothing, finish = nothing,
    get = function(_, render, ...) return render(...) end,
  }
  local old = require("tests/sound/audio_original")
  package.loaded["src/sound_cache"] = real
  old.load()
  return old
end

local function current() return sides[side] end

local function setCar(index)
  carIndex = (index - 1) % #garage + 1
  spec = garage[carIndex]
  car = scenes.car(spec)
  current().silence()
end

local function setSituation(values)
  sweeping = nil
  for key in pairs(toggles) do toggles[key] = false end
  for key, value in pairs(values) do
    if slider(key) then slider(key).value = value else toggles[key] = value end
  end
end

-- As the game calls them, at the game's own levels.
local function playShift()
  car.model.shiftTimer = SHIFT_TIME
  current().play("shift", current().SHIFT_LEVEL or 0.42, current().variedPitch())
end

local SHOTS = {
  { key = "1", label = "Graze, 0.1", fire = function() scenes.hit(current(), 0.1, spec) end },
  { key = "2", label = "Tap, 0.4", fire = function() scenes.hit(current(), 0.4, spec) end },
  { key = "3", label = "Hit, 1", fire = function() scenes.hit(current(), 1, spec) end },
  { key = "4", label = "Hit, 3", fire = function() scenes.hit(current(), 3, spec) end },
  { key = "5", label = "Crash, 8", fire = function() scenes.hit(current(), 8, spec) end },
  { key = "6", label = "Crash, 25", fire = function() scenes.hit(current(), 25, spec) end },
  { key = "7", label = "Upshift", fire = playShift },
  { key = "8", label = "Blow-off", fire = function() current().play("blowoff", 0.6, current().variedPitch()) end },
  { key = "9", label = "Lap", fire = function() current().play("lap", 0.5) end },
  { key = "0", label = "Finish", fire = function() current().play("finish", 0.6) end },
  { key = "-", label = "Start light", fire = function() current().play("beep", 0.6) end },
  { key = "=", label = "Go", fire = function() current().play("go", 0.7) end },
  { key = ";", label = "Menu move", fire = function() current().play("click", 0.3, current().variedPitch(0.03)) end },
  { key = "'", label = "Menu pick", fire = function() current().play("select", 0.3, current().variedPitch(0.03)) end },
  { key = "/", label = "Startup", fire = function() current().play("startup", 0.8) end },
}

local SITUATIONS = {
  { key = "z", label = "Idle", values = { revs = 0, throttle = 0, speed = 0, slide = 0 } },
  { key = "x", label = "Cruise", values = { revs = 0.7, throttle = 1, speed = 40, slide = 0 } },
  { key = "c", label = "Coast", values = { revs = 0.55, throttle = 0, speed = 40, slide = 0 } },
  { key = "v", label = "Hard corner", values = { revs = 0.7, throttle = 1, speed = 30, slide = 0.5 } },
  { key = "f", label = "Full drift", values = { revs = 0.75, throttle = 1, speed = 28, slide = 1 } },
  { key = "g", label = "Off road", values = { revs = 0.7, throttle = 1, speed = 28, slide = 0, grass = true } },
  { key = "b", label = "Along a wall", values = { revs = 0.7, throttle = 1, speed = 35, slide = 0, wall = true } },
  { key = "t", label = "Flat out, nitro", values = { revs = 0.9, throttle = 1, speed = 75, slide = 0, nitro = true } },
  { key = "l", label = "Limiter", values = { revs = 1, throttle = 1, speed = 0, slide = 0, limiter = true } },
}

local function drive(dt)
  local model = car.model
  if sweeping then
    sweeping.at = sweeping.at + dt
    local total = SWEEP_UP + SWEEP_DOWN
    local t = sweeping.at % total
    local rising = t < SWEEP_UP
    slider("revs").value = rising and t / SWEEP_UP or 1 - (t - SWEEP_UP) / SWEEP_DOWN
    slider("throttle").value = rising and 1 or 0
    slider("speed").value = 8 + slider("revs").value * 52
  end
  local revs, throttle = slider("revs").value, slider("throttle").value
  model.rpm = spec.idleRpm + (spec.redline - spec.idleRpm) * revs
  model.throttle = held.throttle and 1 or throttle
  model.brake = toggles.brake and 1 or 0
  model.limiting = toggles.limiter and spec.cylinders > 0
  model.boostState = toggles.nitro and "active" or "ready"
  model.shiftTimer = math.max(0, model.shiftTimer - dt)
  car.speed = slider("speed").value
  car.scraping = toggles.wall and 1 or 0
  for _, wheel in ipairs(model.wheels) do
    wheel.slide = slider("slide").value
    wheel.surface = toggles.grass and "grass" or "asphalt"
  end
end

-- Every loop that's sounding, for seeing what you're hearing.
local function playing()
  local list = {}
  local module = current()
  local function add(name, source)
    if source and source:isPlaying() and source:getVolume() > 0.002 then
      list[#list + 1] = { name = name, volume = source:getVolume(), pitch = source:getPitch() }
    end
  end
  local voice = module.voiceOf(spec)
  if voice and module.engines then
    local engine = module.engines[voice.key]
    for i, source in ipairs(engine.speeds) do add("engine " .. voice.rpms[i], source) end
    add("engine idle", engine.idle)
    add("overrun", engine.overrun)
    add("limiter", engine.limiter)
  end
  if module.turbos then add("turbo", module.turbos[spec.turbos]) end
  if module.turboBoosts then add("turbo boost", module.turboBoosts[spec.turbos]) end
  for _, name in ipairs({ "blower", "motor", "road", "wind", "scrub", "squeal", "grind", "loose", "nitro", "horn" }) do
    add(name, module[name])
  end
  return list
end

-- Text at the window's own pixel size, on a whole pixel: a font scaled afterwards
-- loses strokes.
local function label(text, x, y, colour, size)
  local scale = listen.scale
  local pixels = math.floor((size or TEXT) * scale + 0.5)
  fonts[pixels] = fonts[pixels] or love.graphics.newFont(pixels)
  love.graphics.setFont(fonts[pixels])
  love.graphics.setColor(colour or INK)
  love.graphics.print(text, math.floor(x * scale + 0.5) / scale, math.floor(y * scale + 0.5) / scale, 0, 1 / scale)
end

local function bar(x, y, width, height, share, colour)
  love.graphics.setColor(BAR)
  love.graphics.rectangle("fill", x, y, width, height)
  love.graphics.setColor(colour)
  love.graphics.rectangle("fill", x, y, width * math.min(1, share), height)
end

local SLIDER_X, SLIDER_Y, SLIDER_W, SLIDER_GAP = 32, 228, 340, 46

local function drawSliders(colour)
  for i, s in ipairs(sliders) do
    local y = SLIDER_Y + (i - 1) * SLIDER_GAP
    local shown = s.value * (s.max == 1 and 100 or 1)
    label(string.format("%s  %d%s", s.label, shown, s.unit or (s.max == 1 and "%" or "")),
      SLIDER_X, y, i == focus and INK or DIM)
    if i == focus then label("selected", SLIDER_X + SLIDER_W - 60, y, colour, SMALL) end
    bar(SLIDER_X, y + 21, SLIDER_W, 14, s.value / s.max, colour)
  end
end

local function keyRow(key, text, x, y, colour)
  label(key == "tab" and "Tab" or key:upper(), x, y, DIM)
  label(text, x + 30, y, colour)
end

local function drawList(title, x, y, list)
  label(title, x, y, DIM, SMALL)
  for i, item in ipairs(list) do keyRow(item.key, item.label, x, y + 4 + i * ROW) end
end

local function drawToggles(x, y)
  label("Hold or toggle", x, y, DIM, SMALL)
  local rows = {
    { "W", "Hold: full throttle", held.throttle }, { "H", "Hold: horn", car.horn },
    { "N", "Nitro", toggles.nitro }, { "K", "Brakes on", toggles.brake }, { "A", "Sweep the revs", sweeping ~= nil },
    { "E", "Engine on or off", running },
  }
  for i, row in ipairs(rows) do keyRow(row[1], row[2], x, y + 4 + i * ROW, row[3] and NEW_COLOUR or INK) end
end

local function drawPlaying(x, y, colour)
  label("Playing: volume and pitch", x, y, DIM, SMALL)
  for i, item in ipairs(playing()) do
    local row = y + 2 + i * 20
    label(item.name, x, row, nil, SMALL)
    bar(x + 130, row + 3, 150, 10, item.volume, colour)
    label(string.format("%.2f", item.pitch), x + 292, row, DIM, SMALL)
  end
end

function listen.draw()
  local w, h = love.graphics.getDimensions()
  listen.scale = math.min(w / WIDTH, h / HEIGHT)
  love.graphics.clear(0.07, 0.08, 0.1)
  love.graphics.push()
  love.graphics.scale(listen.scale)
  local colour = side == "new" and NEW_COLOUR or OLD_COLOUR
  label(side == "new" and "New sounds" or "Old sounds", 32, 22, colour, TITLE)
  label("Tab swaps old and new at any time", 32, 58, DIM)
  label(spec.name, 32, 88, nil, HEADING)
  label(string.format("%d cyl, %d turbo%s%s, %d kg", spec.cylinders, spec.turbos,
    spec.supercharged and ", blown" or "", spec.raceExhaust and ", race" or "", spec.mass), 32, 116, DIM)
  label("[ and ] change car", 32, 138, DIM)
  label("Arrow keys or the mouse move the sliders", 32, 160, DIM)
  label(string.format("%d rpm", car.model.rpm), 32, 194, colour, HEADING)
  drawSliders(colour)
  drawPlaying(32, 424, colour)
  drawList("Situations", 410, 24, SITUATIONS)
  drawToggles(410, 262)
  drawList("Hits and events", 720, 24, SHOTS)
  if lastPlayed ~= "" then label("Last: " .. lastPlayed, 720, 400, DIM) end
  love.graphics.pop()
end

function listen.update(dt)
  dt = math.min(dt, 1 / 20)
  if love.keyboard.isDown("left") then
    local s = sliders[focus]
    s.value = math.max(0, s.value - s.max * dt * 0.5)
  elseif love.keyboard.isDown("right") then
    local s = sliders[focus]
    s.value = math.min(s.max, s.value + s.max * dt * 0.5)
  end
  drive(dt)
  if running then current().update(dt, car, nil, 0) end
end

local function swapSide()
  current().silence()
  side = side == "new" and "old" or "new"
end

function listen.keypressed(key)
  if key == "escape" then love.event.quit() return end
  if key == "tab" then swapSide()
  elseif key == "[" then setCar(carIndex - 1)
  elseif key == "]" then setCar(carIndex + 1)
  elseif key == "up" then focus = (focus - 2) % #sliders + 1
  elseif key == "down" then focus = focus % #sliders + 1
  elseif key == "w" then held.throttle = true
  elseif key == "h" then car.horn = true
  elseif key == "n" then toggles.nitro = not toggles.nitro
  elseif key == "k" then toggles.brake = not toggles.brake
  elseif key == "a" then sweeping = not sweeping and { at = 0 } or nil
  elseif key == "e" then
    running = not running
    if not running then current().silence() end
  end
  for _, shot in ipairs(SHOTS) do
    if shot.key == key then
      shot.fire()
      lastPlayed = shot.label
    end
  end
  for _, situation in ipairs(SITUATIONS) do
    if situation.key == key then
      setSituation(situation.values)
      lastPlayed = situation.label
    end
  end
end

function listen.keyreleased(key)
  if key == "w" then held.throttle = false end
  if key == "h" then car.horn = false end
end

local function sliderAt(mx, my)
  local x, y = mx / listen.scale, my / listen.scale
  for i, s in ipairs(sliders) do
    local top = SLIDER_Y + (i - 1) * SLIDER_GAP + 14
    if x >= SLIDER_X and x <= SLIDER_X + SLIDER_W and y >= top and y <= top + 28 then return i, s end
  end
end

local function dragTo(mx)
  local s = sliders[dragging]
  local x = mx / listen.scale
  s.value = math.max(0, math.min(1, (x - SLIDER_X) / SLIDER_W)) * s.max
end

function listen.mousepressed(mx, my)
  local index = sliderAt(mx, my)
  if index then
    focus, dragging, sweeping = index, index, nil
    dragTo(mx)
  end
end

function listen.mousemoved(mx)
  if dragging then dragTo(mx) end
end

function listen.mousereleased()
  dragging = nil
end

function listen.start()
  love.window.setVSync(1)
  love.keyboard.setKeyRepeat(false)
  sides.new, sides.old = audio, loadOriginal()
  assert(audio.ready and sides.old.ready, "the sounds didn't load")
  setCar(3)
  love.update, love.draw = listen.update, listen.draw
  love.keypressed, love.keyreleased = listen.keypressed, listen.keyreleased
  love.mousepressed, love.mousemoved, love.mousereleased = listen.mousepressed, listen.mousemoved, listen.mousereleased
  -- Everything else a real race would receive doesn't apply here.
  love.textinput, love.wheelmoved, love.filedropped = nil, nil, nil
  love.gamepadpressed, love.gamepadreleased = nil, nil
  love.touchpressed, love.touchmoved, love.touchreleased = nil, nil, nil
  love.focus = nil
end

return listen
