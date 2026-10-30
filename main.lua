-- `love . --test [filter]` runs the headless test suite instead of the game.
for _, a in ipairs(arg or {}) do
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
local ui = require("src/ui")
local splash = require("src/splash")
local menu = require("src/menu")
local rm = require("src/race_manager")
local editor = require("src/editor")
local audio = require("src/audio")
local post = require("src/render/post")
local textures = require("src/render/textures")
local network = require("src/network_manager")

function love.load(args)
  love.graphics.setDefaultFilter("linear", "linear")
  love.keyboard.setKeyRepeat(false)
  settings.load()
  if settings.fullscreen then love.window.setFullscreen(true, "desktop") end
  post.load()
  post.quality = settings.quality
  textures.load()
  audio.load()
  audio.setVolume(settings.volume)

  for _, a in ipairs(args) do
    if a == "--visual" then
      rm.keepRunningUnfocused = true
      for _, b in ipairs(args) do
        if b == "flow" then
          require("tests/flow").start()
          return
        end
      end
      require("tests/visual").start(args)
      return
    end
  end
end

function love.update(dt)
  if state.screen == "splash" then
    if splash.update(dt) then menu.enter() end
  elseif state.screen == "menu" then
    menu.update(dt)
  elseif state.screen == "race" then
    if input.consume("pause") and not rm.isFinished() then
      rm.setPaused(not rm.isPaused())
      -- Esc is also the menu's "back" key: this press has now been used.
      ui.nav.back = nil
    end
    rm.update(dt)
    network.update(dt)
  elseif state.screen == "editor" then
    editor.update(dt)
  end
end

function love.draw()
  local sw, sh = love.graphics.getDimensions()
  if state.screen == "splash" then
    splash.draw(sw, sh)
  elseif state.screen == "menu" then
    menu.draw(sw, sh)
  elseif state.screen == "race" then
    rm.draw(sw, sh)
    if rm.isFinished() then
      menu.drawResults(sw, sh)
    elseif rm.isPaused() then
      menu.drawPause(sw, sh)
    end
  elseif state.screen == "editor" then
    editor.draw(sw, sh)
  end

  if ui.played then
    audio.play(ui.played, 0.3)
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
end

function love.keyreleased(key)
  input.release(key)
end

function love.textinput(t)
  if state.screen == "editor" then
    editor.textinput(t)
  else
    ui.textinput(t)
  end
end

function love.mousepressed(x, y, button)
  ui.mousepressed(x, y, button)
  if state.screen == "editor" then editor.mousepressed(x, y, button) end
end

function love.mousereleased(x, y, button)
  if state.screen == "editor" then editor.mousereleased(x, y, button) end
end

function love.mousemoved(x, y, dx, dy)
  ui.mousemoved(x, y)
  if state.screen == "editor" then editor.mousemoved(x, y, dx, dy) end
end

function love.wheelmoved(x, y)
  if state.screen == "editor" then editor.wheelmoved(x, y) end
end

function love.gamepadpressed(joystick, button)
  input.gamepadPress(joystick, button)
  ui.gamepadpressed(button)
end

function love.gamepadreleased(joystick, button)
  input.gamepadRelease(joystick, button)
end

function love.joystickadded(joystick)
  input.joystickAdded(joystick)
end

function love.joystickremoved(joystick)
  input.joystickRemoved(joystick)
end

function love.focus(focused)
  if not focused and state.screen == "race" and not rm.isFinished() and not rm.keepRunningUnfocused then
    rm.setPaused(true)
    input.clear()
  end
end
