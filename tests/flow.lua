-- Plays the real game through its real input handlers, with graphics on:
-- `love . --visual flow`. Each step presses keys or clicks, then checks the
-- screen it should have arrived at.
local state = require("src/state")
local rm = require("src/race_manager")
local menu = require("src/menu")
local settings = require("src/settings")
local catalog = require("src/tracks/catalog")
local ui = require("src/ui")
local touch = require("src/touch")
local audio = require("src/audio")
local world = require("src/world")

local flow = {}

local function press(key)
  love.keypressed(key, key, false)
  love.keyreleased(key)
end

local function click(x, y)
  love.mousemoved(x, y, 0, 0)
  love.mousepressed(x, y, 1)
  love.mousereleased(x, y, 1)
end

local function expect(value, message)
  if not value then error("FLOW FAILED: " .. message, 2) end
  print("  ok    " .. message)
end

-- Each entry runs after `wait` frames have passed since the previous one.
local function steps()
  local list = {}
  local function step(wait, fn) list[#list + 1] = { wait = wait, fn = fn } end

  step(2, function()
    expect(state.screen == "splash", "the game opens on the splash")
    expect(audio.shots.startup:isPlaying(), "the engine starts over it")
  end)
  step(140, function() expect(state.screen == "menu", "the splash leads to the menu") end)
  step(4, function()
    expect(menu.screen == "main", "main menu shows")
    expect(rm.race() ~= nil, "a live race runs behind the menu")
    flow.playImpact = audio.impact
    audio.impact = function() flow.demoImpacts = true end
    world.events[#world.events + 1] = {
      x = 0, y = 0, nx = 1, ny = 0, impulse = 9000, carA = rm.race().player,
    }
    press("down")
  end)
  step(2, function()
    audio.impact = flow.playImpact
    expect(not flow.demoImpacts, "crashes in the race behind the menu make no sound")
    expect(ui.focus.main == 2, "down moves the selection")
    press("up")
  end)
  step(2, function()
    expect(ui.focus.main == 1, "up moves it back")
    press("return")
  end)
  step(3, function()
    expect(menu.screen == "setup", "enter opens race setup")
    settings.track = "harbour"
    settings.car = 1
    settings.opponents = 3
    settings.laps = 1
    press("left") press("right")
    press("escape")
  end)
  step(3, function()
    expect(menu.screen == "main", "escape goes back")
    press("return")
  end)
  -- Move to START with the keyboard: track, car, paint, laps, opponents,
  -- difficulty, time, assists, start. One press per frame, like a person.
  for _ = 1, 8 do step(3, function() press("down") end) end
  step(3, function()
    expect(ui.focus.setup == 9, "selection reached START")
    press("return")
  end)
  step(3, function()
    expect(state.screen == "race", "START begins the race")
    expect(rm.race().phase == "countdown", "the race opens on the lights")
    love.keypressed("w", "w", false)
    expect(#rm.race().cars == 4, "three opponents on the grid")
  end)
  step(120, function()
    local car = rm.race().player
    expect(rm.race().phase == "countdown", "still on the lights")
    expect(car.model.rpm > car.spec.redline * 0.85, "holding W revs the engine at the lights")
    expect(car:getSpeed() < 0.5, "and the car stays put")
  end)
  step(120, function()
    expect(rm.race().phase == "racing", "lights out")
    local car = rm.race().player
    love.keypressed("w", "w", false)
    flow.startX, flow.startY = car.curX, car.curY
    flow.play = audio.play
    audio.play = function(name, ...)
      if name == "blowoff" then flow.blowoffs = true end
      flow.play(name, ...)
    end
    -- Every upshift dumps the pressure, so listen for the whole pull.
    flow.mix = audio.update
    audio.update = function(...)
      flow.mix(...)
      flow.whistled = flow.whistled or audio.turbo:isPlaying()
      flow.motored = flow.motored or audio.motor:isPlaying()
    end
  end)
  step(120, function()
    local car = rm.race().player
    local moved = math.abs(car.curX - flow.startX) + math.abs(car.curY - flow.startY)
    expect(moved > 100, "holding W drives the car")
    audio.update = flow.mix
    expect(flow.whistled, "the turbo car whistles under power")
    expect(not flow.motored, "and has no electric motor")
    love.keyreleased("w")
  end)
  step(20, function()
    audio.play = flow.play
    expect(flow.blowoffs, "the turbo blows off when the power comes off")
    press("space")
  end)
  step(3, function()
    expect(rm.race().player.model.boostState == "active", "space fires the nitro")
    expect(audio.nitro:isPlaying(), "and it hisses")
    press("r")
  end)
  step(3, function()
    expect(rm.race().player:getSpeed() < 8, "R resets the car to the track")
    love.keypressed("w", "w", false)
  end)
  step(400, function()
    love.keyreleased("w")
    expect(rm.race().phase == "racing", "still racing under load")
    expect(not touch.shown(), "no touch controls for a keyboard player")
    flow.sw, flow.sh = love.graphics.getDimensions()
    love.touchpressed(1, flow.sw * 0.2, flow.sh * 0.7)
    love.touchmoved(1, flow.sw * 0.2 + 300, flow.sh * 0.7)
  end)
  step(3, function()
    expect(touch.shown(), "a touch brings up the controls")
    local car = rm.race().player
    expect(car.input.steer == 1, "the stick steers the car")
    expect(car.input.throttle == 1, "with auto gas on")
    local drift = touch.layout(flow.sw, flow.sh).buttons[2]
    love.touchpressed(2, drift.x, drift.y)
  end)
  step(3, function()
    expect(rm.race().player.input.handbrake, "the drift button holds the handbrake")
    love.touchreleased(2)
    love.touchreleased(1)
    local pause = touch.layout(flow.sw, flow.sh).buttons[3]
    love.touchpressed(3, pause.x, pause.y)
    love.touchreleased(3)
  end)
  step(3, function()
    expect(rm.isPaused(), "the pause button pauses")
    -- A tap on a menu arrives as a mouse click marked as a touch, with no move.
    local s = ui.scale()
    local x, y = flow.sw / 2, flow.sh * 0.3 + 32 * s
    love.mousepressed(x, y, 1, true)
    love.mousereleased(x, y, 1, true)
  end)
  step(3, function()
    expect(not rm.isPaused(), "tapping RESUME resumes")
    love.keypressed("w", "w", false)
    love.keyreleased("w")
    expect(not touch.shown(), "a key press hands back to the keyboard")
    press("escape")
  end)
  step(3, function()
    expect(rm.isPaused(), "escape pauses")
    flow.pausedTime = rm.race().time
  end)
  step(5, function() expect(rm.isPaused(), "and it stays paused") end)
  step(20, function()
    expect(rm.race().time == flow.pausedTime, "the race stands still while paused")
    press("escape")
  end)
  step(3, function()
    expect(not rm.isPaused(), "escape resumes")
    press("p")
  end)
  step(3, function()
    expect(rm.isPaused(), "p pauses too")
    press("down")
  end)
  step(2, function() press("return") end)
  step(3, function()
    expect(rm.race().phase == "countdown", "restart returns to the lights")
    expect(not rm.isPaused(), "restart unpauses")
    press("escape")
  end)
  step(3, function() press("down") end)
  step(2, function() press("down") end)
  step(2, function() press("return") end)
  step(4, function()
    expect(state.screen == "menu", "quit returns to the menu")
    expect(menu.screen == "main", "at the main menu")
    settings.mode = "race"
    -- Mouse: click TRACK EDITOR, the fifth row
    local s = ui.scale()
    click(100 * s, 62 * s + 15 * s * 4.5)
  end)
  step(4, function()
    expect(state.screen == "editor", "clicking TRACK EDITOR opens it")
    local sw, sh = love.graphics.getDimensions()
    flow.nodes = #require("src/editor").currentDoc().nodes
    click(sw * 0.72, sh * 0.5)
  end)
  step(3, function()
    expect(#require("src/editor").currentDoc().nodes == flow.nodes + 1, "clicking adds a node")
    love.keyboard.isDown = function(...)
      for _, k in ipairs({ ... }) do if k == "lctrl" then return true end end
      return false
    end
    press("z")
    love.keyboard.isDown = nil
  end)
  step(3, function()
    expect(#require("src/editor").currentDoc().nodes == flow.nodes, "ctrl+z undoes it")
    press("t")
  end)
  step(4, function()
    expect(state.screen == "race", "T starts a test drive")
    expect(rm.opts().fromEditor, "the race knows it came from the editor")
    press("escape")
  end)
  step(3, function() press("down") end)
  step(2, function() press("down") end)
  step(2, function() press("return") end)
  step(4, function()
    expect(state.screen == "editor", "the test drive returns to the editor")
    expect(require("src/editor").currentDoc() ~= nil, "with the track still open")
    press("escape")
  end)
  -- An undone edit still counts as a change, so it should ask first:
  -- the second row is "leave without saving".
  step(4, function() press("down") end)
  step(2, function() press("return") end)
  step(5, function()
    expect(state.screen == "menu", "leaving the editor returns to the menu")
    print("FLOW PASSED")
    love.event.quit(0)
  end)
  return list
end

function flow.start()
  local keyboard = love.keyboard.isDown
  local list = steps()
  local index, waited = 1, 0
  local update = love.update
  local isDown = keyboard
  love.update = function(dt)
    if not love.keyboard.isDown then love.keyboard.isDown = isDown end
    -- Input first, then update, then draw: the order love.run delivers them.
    waited = waited + 1
    local current = list[index]
    if current and waited >= current.wait then
      waited = 0
      index = index + 1
      local ok, err = xpcall(current.fn, debug.traceback)
      if not ok then
        print(err)
        love.event.quit(1)
      end
    end
    update(1 / 60)
  end
end

return flow
