-- `love . --test [filter]` runs the headless test suite instead of the game.
-- `love . --perf` measures a race instead.
-- `love . --sounds <old|new> <folder>` writes every sound out as a WAV.
for i, a in ipairs(arg or {}) do
  if a == "--sounds" then
    local which, folder = arg[i + 1], arg[i + 2]
    function love.load()
      require("tests/sound/dump")(which, folder)
      love.event.quit(0)
    end
    return
  end
  if a == "--test" then
    function love.load(args)
      local filter
      for i, v in ipairs(args) do
        if v == "--test" then filter = args[i + 1] end
      end
      local ok = require("tests/run")(filter)
      love.event.quit(ok and 0 or 1)
    end
    return
  end
end

local state = require("src/state")
local settings = require("src/settings")
local input = require("src/input")
local touch = require("src/touch")
local ui = require("src/ui")
local splash = require("src/splash")
local menu = require("src/menu")
local rm = require("src/race_manager")
local editor = require("src/editor")
local audio = require("src/audio")
local radio = require("src/radio")
local music = require("src/music")
local post = require("src/render/post")
local textures = require("src/render/textures")
local catalog = require("src/tracks/catalog")
local network = require("src/network_manager")
local cheats = require("src/cheats")

-- Slow phones take seconds over this, so it runs a step at a time between
-- frames, with the splash on screen.
local loading

local function loadGame()
  post.load()
  post.quality = settings.quality
  coroutine.yield()
  textures.load()
  coroutine.yield()
  audio.load()
  audio.setVolume(settings.volume)
end

local function stepLoading()
  local ok, err = coroutine.resume(loading)
  if not ok then error(debug.traceback(loading, err), 0) end
  if coroutine.status(loading) == "dead" then loading = nil end
end

function love.load(args)
  love.graphics.setDefaultFilter("linear", "linear")
  love.keyboard.setKeyRepeat(false)
  settings.load()
  music.setTake(settings.musicTake)
  if settings.fullscreen then love.window.setFullscreen(true, "desktop") end
  loading = coroutine.create(loadGame)

  for _, a in ipairs(args) do
    if a == "--perf" then
      while loading do stepLoading() end
      rm.keepRunningUnfocused = true
      require("tests/perf").start()
      return
    end
    if a == "--visual" then
      while loading do stepLoading() end
      rm.keepRunningUnfocused = true
      for _, b in ipairs(args) do
        if b == "flow" then
          require("tests/flow").start()
          return
        end
        if b == "online" then
          require("tests/flow_online").start()
          return
        end
        if b == "listen" then
          require("tests/sound/listen").start()
          return
        end
      end
      require("tests/visual").start(args)
      return
    end
  end
end

-- Says goodbye, so nobody waits for the relay to notice.
function love.quit()
  network.disconnect()
end

function love.update(dt)
  -- Menus only. It renders ahead anywhere but a race, where frames matter.
  if not loading then
    music.update(dt, state.screen == "menu" and settings.music, settings.music and state.screen ~= "race")
  end
  if loading then
    stepLoading()
  elseif state.screen == "splash" then
    if splash.update(dt) then menu.enter() end
  elseif state.screen == "menu" then
    menu.update(dt)
  elseif state.screen == "race" then
    if input.consume("pause") and not rm.isFinished() then
      rm.setPaused(not rm.isPaused())
      -- Esc is also the menu's "back" key and Start its "ok", and the pause
      -- menu draws this same frame: this press has now been used.
      ui.nav.back, ui.nav.ok = nil, nil
    end
    rm.update(dt)
    menu.updateOnline(dt)
  elseif state.screen == "editor" then
    editor.update(dt)
  end
end

function love.draw()
  local sw, sh = love.graphics.getDimensions()
  if state.screen == "splash" then
    splash.draw(sw, sh, loading ~= nil)
  elseif state.screen == "menu" then
    menu.draw(sw, sh)
  elseif state.screen == "race" then
    rm.draw(sw, sh)
    if rm.resultsAge() then
      menu.drawResults(sw, sh)
    elseif rm.isPaused() then
      menu.drawPause(sw, sh)
    end
  elseif state.screen == "editor" then
    editor.draw(sw, sh)
  end

  if ui.played then
    audio.play(ui.played, 0.3, audio.variedPitch(0.03))
    ui.played = nil
  end
  ui.endFrame()
end

function love.keypressed(key, scancode, isRepeat)
  if state.screen == "editor" then
    editor.keypressed(key)
    return
  end
  ui.keypressed(key)
  if not isRepeat then input.press(key) end
  -- Only in a race: a phone's on-screen keyboard presses keys in the menus.
  if state.screen == "race" then touch.active = false end
end

function love.keyreleased(key)
  input.release(key)
end

function love.textinput(t)
  if state.screen == "editor" then
    editor.textinput(t)
  elseif ui.editing then
    ui.textinput(t)
  else
    -- Cheat codes typed blind. In the menus a flame code waits for the next race.
    local effect = cheats.type(t)
    if effect then
      local label = cheats.apply(effect)
      if state.screen == "race" then
        rm.cheat(effect, label)
      else
        audio.play("select", 0.5)
      end
    end
  end
end

local function drivingByTouch()
  return state.screen == "race" and not rm.isPaused() and not rm.isFinished() and touch.shown()
end

-- Taps also arrive below as mouse events marked istouch, which is what works
-- the menus. A real mouse drives the on-screen controls like a single finger.
function love.touchpressed(id, x, y)
  touch.active = true
  if drivingByTouch() then touch.pressed(id, x, y, love.graphics.getDimensions()) end
end

function love.touchmoved(id, x, y)
  touch.moved(id, x, y)
end

function love.touchreleased(id)
  touch.released(id)
end

function love.mousepressed(x, y, button, istouch)
  ui.mousepressed(x, y, button)
  if state.screen == "editor" then editor.mousepressed(x, y, button) end
  if button == 1 and not istouch and drivingByTouch() then
    touch.pressed("mouse", x, y, love.graphics.getDimensions())
  end
end

function love.mousereleased(x, y, button, istouch)
  if state.screen == "editor" then editor.mousereleased(x, y, button) end
  if button == 1 and not istouch then touch.released("mouse") end
end

function love.mousemoved(x, y, dx, dy, istouch)
  ui.mousemoved(x, y)
  if state.screen == "editor" then editor.mousemoved(x, y, dx, dy) end
  if not istouch then touch.moved("mouse", x, y) end
end

function love.wheelmoved(x, y)
  if state.screen == "editor" then editor.wheelmoved(x, y) end
end

function love.gamepadpressed(joystick, button)
  touch.padUsed(joystick)
  input.gamepadPress(joystick, button)
  ui.gamepadpressed(button)
end

function love.gamepadreleased(joystick, button)
  input.gamepadRelease(joystick, button)
end

function love.gamepadaxis(joystick, axis, value)
  touch.padAxis(joystick, value)
end

function love.joystickadded(joystick)
  touch.padAdded(joystick)
end

-- Losing the pad mid-race pauses, so the car isn't left driving itself. With two
-- at a screen, that's either driver's pad.
function love.joystickremoved(joystick)
  local driving = touch.padRemoved(joystick)
  if not driving and not rm.usesPad(joystick) then return end
  if state.screen == "race" and rm.isRunning() and not rm.isFinished() and not rm.isPaused() then
    rm.setPaused(true)
    input.clear()
  end
end

function love.filedropped(file)
  radio.addFile(file)
end

function love.focus(focused)
  -- Coming back from a file manager: there may be new songs or tracks.
  if focused then
    radio.scan()
    catalog.refresh()
  end
  if not focused and state.screen == "race" and not rm.isFinished() and not rm.keepRunningUnfocused then
    rm.setPaused(true)
    input.clear()
  end
end
