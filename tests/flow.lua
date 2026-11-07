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
local input = require("src/input")
local audio = require("src/audio")
local radio = require("src/radio")
local music = require("src/music")
local world = require("src/world")
local config = require("src/config")
local garage = require("src/entities/garage")

local flow = {}

local function press(key)
  love.keypressed(key, key, false)
  love.keyreleased(key)
end

local function padPress(button)
  local pad = { isConnected = function() return false end }
  love.gamepadpressed(pad, button)
  love.gamepadreleased(pad, button)
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

-- A second of silence as an 8-bit WAV: short enough to hear a song end.
local function writeSong(name)
  local samples = 44100
  local header = love.data.pack("string", "<c4I4c4c4I4I2I2I4I4I2I2c4I4",
    "RIFF", 36 + samples, "WAVE", "fmt ", 16, 1, 1, 44100, 44100, 1, 8, "data", samples)
  love.filesystem.createDirectory("music")
  love.filesystem.write("music/" .. name, header .. string.rep("\128", samples))
end

local function clearMusic()
  for _, name in ipairs(love.filesystem.getDirectoryItems("music")) do
    love.filesystem.remove("music/" .. name)
  end
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
  -- A first launch renders the music a slice a frame before it can play.
  step(1, function()
    flow.musicWait = (flow.musicWait or 0) + 1
    if not music.isPlaying() and flow.musicWait < 900 then return "again" end
    expect(music.isPlaying() and music.level() > 0, "music plays on the menu")
  end)
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
    expect(rm.race().track == menu.cachedTrack(catalog.find("harbour")).track, "on the track the menu built")
    love.keypressed("w", "w", false)
    expect(#rm.race().cars == 4, "three opponents on the grid")
  end)
  step(120, function()
    local car = rm.race().player
    expect(rm.race().phase == "countdown", "still on the lights")
    expect(not music.isPlaying(), "the music is gone for the race")
    expect(car.model.rpm > car.spec.redline * 0.85, "holding W revs the engine at the lights")
    expect(car:getSpeed() < 0.5, "and the car stays put")
    press("space")
  end)
  step(120, function()
    expect(rm.race().phase == "racing", "lights out")
    local car = rm.race().player
    expect(car.model.boostState == "ready", "a boost press at the lights is ignored")
    expect(car.model.boostTank == car.spec.boostTime, "and the tank is full")
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
      for _, whistle in pairs(audio.turbos) do flow.whistled = flow.whistled or whistle:isPlaying() end
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
    expect(rm.race().player.model.boostState == "active", "space fires the boost")
    expect(audio.boost > 0 and audio.boostKind(rm.race().player.spec) == "turbo", "and it drives the turbo")
    love.keypressed("h", "h", false)
  end)
  step(3, function()
    expect(audio.horn:isPlaying(), "holding H sounds the horn")
    love.keyreleased("h")
  end)
  step(6, function()
    expect(not audio.horn:isPlaying(), "and letting go stops it")
    -- Stays on the wall for as long as the frames below run.
    flow.mix = audio.update
    audio.update = function(dt, car, ...)
      car.scraped = true
      flow.mix(dt, car, ...)
    end
  end)
  step(6, function()
    audio.update = flow.mix
    expect(audio.grind:isPlaying(), "dragging along a wall grinds")
    press("r")
  end)
  step(3, function()
    expect(rm.race().player:getSpeed() < 8, "R resets the car to the track")
    -- Straight into the fence at 50 m/s.
    local race = rm.race()
    local car = race.player
    local s = race.track.samples[car.trackIndex]
    local M = config.METER
    local reach = s.w / 2 + s.barrierr - 6 * M
    car:teleport(s.x + s.nx * reach, s.y + s.ny * reach, math.atan2(s.ny, s.nx))
    car.body:setLinearVelocity(s.nx * 50 * M, s.ny * 50 * M)
  end)
  step(25, function()
    local car = rm.race().player
    expect(car.wreck, "a hard hit on a fence wrecks the car")
    expect(car.fx and car.fx.dents[1] and car.fx.mesh, "the wreck folds the body in")
    flow.wreckIndex = car.wreckIndex
    love.graphics.captureScreenshot("flow-wreck.png")
    love.keypressed("w", "w", false)
    press("r")
  end)
  step(3, function()
    local car = rm.race().player
    expect(car.wreck and car.input.throttle == 0, "the wreck takes no orders, and R can't skip it")
    love.keyreleased("w")
  end)
  step(110, function()
    local car = rm.race().player
    expect(not car.wreck and car.trackIndex == flow.wreckIndex, "it goes back to the road where it hit")
    expect(car.ghostTimer > 0 and car:getSpeed() < 3, "stopped, and out of the way of the traffic")
    expect(not car.fx.dents[1], "and goes back in one piece")
    love.graphics.captureScreenshot("flow-recovered.png")
    love.keypressed("w", "w", false)
  end)
  step(400, function()
    love.keyreleased("w")
    expect(rm.race().phase == "racing", "still racing under load")
    expect(not touch.shown(), "no touch controls for a keyboard player")
    flow.sw, flow.sh = love.graphics.getDimensions()
    local rest = touch.layout(flow.sw, flow.sh).rest
    love.touchpressed(1, rest.x, rest.y)
    love.touchmoved(1, rest.x + 300, rest.y)
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
    padPress("start")
  end)
  step(3, function()
    expect(rm.isPaused(), "Start on a pad pauses")
    padPress("start")
  end)
  step(3, function()
    expect(not rm.isPaused(), "and Start resumes")
    -- A pad that only moves its stick still takes over from touch.
    love.touchpressed(9, 1, 1)
    love.touchreleased(9)
    expect(touch.shown(), "a touch brings the controls up")
    flow.pad = {
      isConnected = function() return true end,
      isGamepad = function() return true end,
      isVibrationSupported = function() return false end,
      getGamepadAxis = function(_, axis) return axis == "leftx" and 0.9 or 0 end,
    }
    love.joystickadded(flow.pad)
    love.touchpressed(9, 1, 1)
    love.touchreleased(9)
    love.gamepadaxis(flow.pad, "leftx", 0.9)
  end)
  step(3, function()
    expect(not touch.shown(), "the pad's stick alone hides them")
    expect(rm.race().player.input.steer > 0.5, "and steers")
    love.joystickremoved(flow.pad)
  end)
  step(3, function()
    expect(rm.isPaused(), "pulling the pad out pauses the race")
    expect(input.gamepad == nil, "and lets it go")
    press("escape")
  end)
  step(3, function()
    expect(not rm.isPaused(), "escape resumes after the pad's gone")
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
    expect(music.isPlaying(), "and the music comes back")
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
    expect(not music.isPlaying(), "no music in the editor")
    expect(require("src/editor").currentDoc() ~= nil, "with the track still open")
    press("escape")
  end)
  -- An undone edit still counts as a change, so it should ask first:
  -- the second row is "leave without saving".
  step(4, function() press("down") end)
  step(2, function() press("return") end)
  step(5, function()
    expect(state.screen == "menu", "leaving the editor returns to the menu")
    expect(not radio.isPlaying(), "no radio in the menus")
    clearMusic()
    writeSong("one.wav")
    writeSong("two.wav")
    settings.radioVolume = 0.6
    flow.toast = rm.setToast
    rm.setToast = function(text, ...)
      if text:match("^ON AIR") then flow.onAir = text end
      flow.toast(text, ...)
    end
    ui.focus.main = 3
    press("return")
  end)
  step(3, function()
    expect(settings.mode == "freestyle", "FREESTYLE opens its setup")
    expect(#radio.tracks == 2, "and it has found the songs")
    settings.freestyleTrack = "lot"
    ui.focus.setup = 8  -- track, car, paint, time, handling, radio, music folder, start
    press("return")
  end)
  step(3, function()
    expect(state.screen == "race", "START begins freestyle")
    expect(rm.race().track == nil and rm.race().cones, "on the lot, with its cones out")
    expect(radio.isPlaying(), "the radio is on")
    expect(flow.onAir and flow.onAir:match("one") or flow.onAir:match("two"), "and names the song")
    flow.song = radio.song()
    press("n")
  end)
  step(3, function()
    expect(radio.isPlaying() and radio.song() ~= flow.song, "N moves to the other song")
    flow.song = radio.song()
    flow.waitedFor = love.timer.getTime()
  end)
  -- A real stream ends in real time, however fast the frames go.
  step(1, function()
    if radio.song() == flow.song and love.timer.getTime() - flow.waitedFor < 5 then return "again" end
    expect(radio.song() ~= flow.song, "a song ending moves on by itself")
    expect(radio.isPlaying(), "and the next one plays")
    press("escape")
  end)
  step(3, function()
    expect(rm.isPaused() and not radio.isPlaying(), "pausing pauses the radio")
    flow.song = radio.song()
    press("escape")
  end)
  step(3, function()
    expect(radio.isPlaying() and radio.song() == flow.song, "resuming carries on with the song")
    press("escape")
  end)
  step(3, function() press("down") end)
  step(2, function() press("return") end)
  step(3, function()
    expect(rm.race().phase == "countdown", "RESTART returns to the lights")
    expect(radio.isPlaying() and radio.song() == flow.song, "and the song plays on")
    flow.car, flow.hue, flow.color = settings.car, settings.hue, rm.race().player.color
    press("escape")
  end)
  -- RESUME, RESTART, CAR, PAINT, QUIT TO MENU.
  step(3, function() press("down") end)
  step(2, function() press("down") end)
  step(2, function() press("right") end)
  step(2, function()
    local car = rm.race().player
    expect(settings.car == flow.car % #garage + 1, "CAR in the pause menu moves to the next car")
    expect(car.spec == garage[settings.car] and rm.isPaused(), "and swaps it in on the road")
    press("down")
  end)
  step(2, function() press("right") end)
  step(2, function()
    expect(settings.hue == flow.hue % 9 + 1 and rm.race().player.color ~= flow.color, "PAINT repaints it")
    press("up")
  end)
  step(2, function() press("up") end)
  step(2, function() press("return") end)
  step(3, function()
    local car = rm.race().player
    expect(rm.race().phase == "countdown" and car.spec == garage[settings.car], "RESTART keeps the new car")
    press("escape")
  end)
  for _ = 1, 4 do step(2, function() press("down") end) end
  step(2, function() press("return") end)
  step(4, function()
    expect(state.screen == "menu" and not radio.isPlaying(), "quitting stops the radio")
    settings.car, settings.hue = flow.car, flow.hue
    settings.save()
    settings.mode = "race"
    menu.startRace()
  end)
  step(3, function()
    expect(state.screen == "race" and not radio.isPlaying(), "a race has no radio")
    press("n")
  end)
  step(3, function()
    expect(not radio.isPlaying(), "and N does nothing there")
    rm.stop()
    settings.mode = "freestyle"
    settings.radioVolume = 0
    menu.startRace()
  end)
  step(3, function()
    expect(not radio.isPlaying(), "RADIO OFF keeps freestyle quiet")
    rm.stop()
    settings.freestyleTrack = "mirage"
    menu.startRace()
  end)
  step(3, function()
    local race = rm.race()
    expect(race.mode == "freestyle" and race.track and not race.cones, "freestyle drives a circuit too")
    settings.freestyleTrack = "lot"
    settings.mode = "race"
    settings.radioVolume = 0.6
    rm.setToast = flow.toast
    clearMusic()
    rm.stop()
    settings.opponents = 3
    menu.startRace()
  end)
  step(1, function()
    if rm.race().phase ~= "racing" then return "again" end
    local player = rm.race().player
    player.lapsDone = rm.race().laps - 1
    player.distance = rm.race().track.length * rm.race().laps + 1
  end)
  step(3, function()
    local race = rm.race()
    expect(race.player.finished and race.phase == "racing", "the player takes the flag with the rest still racing")
    expect(rm.isFinished() and not rm.resultsAge(), "the finish banner comes first")
    expect(audio.shots.finish:isPlaying(), "and the finish sting plays")
    press("escape")
  end)
  step(3, function()
    expect(not rm.isPaused(), "there's nothing to pause past the line")
    press("return")
  end)
  step(3, function() expect(rm.race().player.finished, "a press under the banner does nothing") end)
  step(1, function()
    if not rm.resultsAge() then return "again" end
    expect(rm.race().phase == "racing", "the results open without waiting for the others")
    press("return")
  end)
  step(2, function()
    expect(rm.race().player.finished, "a press as the panel lands doesn't restart the race")
  end)
  step(30, function() press("return") end)
  step(3, function()
    expect(rm.race().phase == "countdown" and not rm.isFinished(), "RACE AGAIN restarts from the results")
    rm.stop()
    menu.enter()
  end)
  -- Two at one screen, with a pretend pad plugged in for the second driver.
  step(30, function()
    local pad = { axes = {} }
    function pad:isConnected() return true end
    function pad:isGamepad() return true end
    function pad:getID() return 7 end
    function pad:getName() return "Test Pad" end
    function pad:getGamepadAxis(axis) return self.axes[axis] or 0 end
    function pad:isVibrationSupported() return false end
    flow.pad, flow.gamepads = pad, input.gamepads
    input.gamepads = function() return { pad } end
    settings.mode, settings.players, settings.opponents = "race", 1, 2
    settings.gearbox, settings.gearbox2 = "auto", "auto"
    menu.go("setup")
    ui.focus.setup = 2
  end)
  step(3, function()
    expect(menu.canSplit(), "a pad plugged in offers a second player")
    press("right")
  end)
  -- Track, players, driver, then that driver's car, paint, handling and gearbox.
  step(3, function()
    expect(settings.players == 2, "right on PLAYERS makes it two")
    expect(menu.driver == 1, "the rows start on P1")
    ui.focus.setup = 3
    press("right")
  end)
  step(3, function()
    expect(menu.driver == 2, "right on DRIVER moves the rows to P2")
    flow.car, flow.car2 = settings.car, settings.car2
    ui.focus.setup = 4
    press("right")
  end)
  step(3, function()
    expect(settings.car2 == flow.car2 % #garage + 1 and settings.car == flow.car, "CAR then sets P2's car alone")
    ui.focus.setup = 7
    press("right")
  end)
  -- Laps, opponents, difficulty, time, start.
  step(3, function()
    expect(settings.gearbox2 == "manual" and settings.gearbox == "auto", "P2 GEARBOX is P2's alone")
    settings.car2 = flow.car2
    ui.focus.setup = 12
    press("return")
  end)
  step(3, function()
    local race = rm.race()
    expect(state.screen == "race" and rm.isSplit(), "START with two players splits the screen")
    expect(#race.players == 2 and race.players[2].name == "P2", "with a second driver on the grid")
    expect(race.players[2].input.manual and not race.players[1].input.manual, "each with their own gearbox")
    flow.neon, settings.neon = settings.neon, true
    love.keypressed("w", "w", false)
    flow.pad.axes.triggerright = 1
  end)
  step(120, function()
    local p1, p2 = rm.race().players[1], rm.race().players[2]
    expect(p1.model.rpm > p1.spec.redline * 0.85, "W revs P1 at the lights")
    expect(p2.model.rpm > p2.spec.redline * 0.85, "the second pad's trigger revs P2")
    expect(p1.neon and not p2.neon, "a code goes on P1's car alone")
    settings.neon = flow.neon
    love.keyreleased("w")
    flow.pad.axes.triggerright = 0
  end)
  step(1, function()
    if rm.race().phase ~= "racing" then return "again" end
    love.gamepadpressed(flow.pad, "rightshoulder")
  end)
  step(2, function()
    local p1, p2 = rm.race().players[1], rm.race().players[2]
    expect(p2.input.handbrake and not p1.input.handbrake, "R1 on the second pad is P2's handbrake alone")
    love.gamepadreleased(flow.pad, "rightshoulder")
    love.gamepadpressed(flow.pad, "start")
  end)
  step(3, function()
    expect(rm.isPaused(), "the second driver can pause")
    love.gamepadreleased(flow.pad, "start")
    press("escape")
  end)
  step(3, function()
    expect(not rm.isPaused(), "and escape resumes")
    love.joystickremoved(flow.pad)
  end)
  step(3, function()
    expect(rm.isPaused(), "pulling out the second driver's pad pauses")
    input.gamepads = function() return {} end
    rm.restart()
  end)
  step(3, function()
    expect(rm.race() and not rm.isSplit() and #rm.race().players == 1, "a restart with no pad left races alone")
    rm.stop()
    input.gamepads = flow.gamepads
    settings.players, settings.gearbox2 = 1, "auto"
    menu.enter()
  end)
  step(30, function()
    expect(music.isPlaying(), "music in the menu again")
    menu.go("settings")
    ui.focus.settings = 2
    press("return")
  end)
  step(30, function()
    expect(not settings.music, "the MUSIC row turns it off")
    expect(state.screen == "menu" and not music.isPlaying(), "and the menu goes quiet")
    settings.music = true
    settings.save()
    print("FLOW PASSED")
    love.event.quit(0)
  end)
  return list
end

flow.press, flow.expect = press, expect

-- `pace` runs frames at real speed, for anything talking to a real server.
function flow.run(list, pace)
  local keyboard = love.keyboard.isDown
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
      local ok, result = xpcall(current.fn, debug.traceback)
      if not ok then
        print(result)
        love.event.quit(1)
      end
      -- A step can return "again" to wait on something that takes real time.
      if result ~= "again" then index = index + 1 end
    end
    update(1 / 60)
    if pace then love.timer.sleep(1 / 60) end
  end
end

function flow.start()
  -- The flow drives with the keyboard alone, whatever pad is plugged into the
  -- machine: a real one adds the PLAYERS row and moves every row under it.
  input.gamepads = function() return {} end
  input.joystickAdded = function() end
  input.gamepad = nil
  flow.run(steps())
end

return flow
