-- The real game online through its real input handlers, with graphics on and a
-- real relay: `make test-online-visual`. Bots in this process fill the other seats.
local state = require("src/state")
local rm = require("src/race_manager")
local menu = require("src/menu")
local settings = require("src/settings")
local ui = require("src/ui")
local network = require("src/network_manager")
local flow = require("tests/flow")
local press, expect = flow.press, flow.expect

local online = {}

local function newBot()
  return love.filesystem.load("src/network_manager.lua")()
end

local bots = {}
local sendEvery = 0

-- A bot that keeps up its end: loads at once, and sits where it's told.
local function runBots(dt)
  sendEvery = sendEvery - dt
  for _, bot in pairs(bots) do
    if not bot.left then
      bot.client.update(dt)
      if bot.client.ready then
        bot.client.ready = false
        bot.client.raceLoaded()
      end
      if sendEvery <= 0 then bot.client.sendCar(bot.car) end
    end
  end
  if sendEvery <= 0 then sendEvery = 1 / 20 end
end

local function makeCar()
  local wheels = { { slide = 0 }, { slide = 0 }, { slide = 0 }, { slide = 0 } }
  return {
    curX = 0, curY = 0, curA = 0, distance = 0,
    body = { getLinearVelocity = function() return 0, 0 end },
    model = { steer = 0, rpm = 3000, throttle = 0, brake = 0, gear = 1, wheels = wheels, boostState = "ready" },
  }
end

local function addBot(role, code, carId, race)
  local client = newBot()
  local host, port = settings.server:match("^(.+):(%d+)$")
  client.connect(host, tonumber(port), role, code, { car = carId, paint = #bots + 2 }, race)
  local bot = { client = client, car = makeCar() }
  bots[#bots + 1] = bot
  return bot
end

-- Holds each bot where the game put its car, so they stay on the grid.
local function parkBots()
  local race = rm.race()
  for _, bot in ipairs(bots) do
    for _, car in ipairs(race.cars) do
      if car.slot == bot.client.slot and car ~= race.player then
        bot.car.curX, bot.car.curY, bot.car.curA = car.curX, car.curY, car.curA
      end
    end
  end
end

local function shot(name)
  love.graphics.captureScreenshot("online-" .. name .. ".png")
end

local function ownTrack()
  local nodes = {}
  for i = 1, 200 do
    local a = i / 200 * math.pi * 2
    nodes[i] = { x = math.cos(a) * 900 + 7.5, y = math.sin(a) * 620, wl = 34, wr = 30 }
  end
  return { title = "Only The Host Has This", theme = "desert", scale = 3, nodes = nodes,
    startPoint = { x = 907.5, y = 0, angle = math.pi / 2 } }
end

local function steps()
  local list = {}
  local function step(wait, fn) list[#list + 1] = { wait = wait, fn = fn } end
  local saved
  local botRoom = network.generateCode()

  step(1, function()
    if state.screen ~= "menu" then return "again" end
    settings.server = assert(os.getenv("SPPPD_RELAY"), "set SPPPD_RELAY")
    settings.track, settings.laps, settings.time = "harbour", 2, "dusk"
    saved = { track = settings.track, laps = settings.laps, time = settings.time }
    ui.focus.main = 4
    press("return")
  end)
  step(3, function()
    expect(menu.screen == "online", "ONLINE opens")
  end)
  step(5, function() shot("notice") end)
  step(3, function()
    ui.focus.online = 4
    press("return")
  end)
  step(3, function()
    expect(menu.screen == "host", "HOST A ROOM opens the race setup")
    ui.focus.host = 4
    press("return")
  end)
  step(1, function()
    if network.status ~= "lobby" or not network.slot then return "again" end
    expect(#network.roomCode == 6, "START ROOM opens a room with a code")
    expect(network.isLeader(), "and the host leads")
    expect(not network.canStart(), "with nobody to race yet")
    expect(network.statusText():find(network.roomCode), "and the code is on show")
    addBot("join", network.roomCode, "samurai")
    addBot("join", network.roomCode, "cyber")
    addBot("join", network.roomCode, "wedge")
  end)
  step(1, function()
    local count = 0
    for _ in pairs(network.peers) do count = count + 1 end
    if count < 3 or not network.canStart() then return "again" end
    expect(true, "three drivers arrive with the track")
  end)
  step(10, function()
    expect(ui.focus.online == 2, "and focus comes back to START RACE")
    shot("lobby")
  end)
  step(3, function() press("return") end)
  step(3, function()
    expect(state.screen == "race", "START RACE begins the race")
    expect(rm.isOnline(), "online")
    expect(#rm.race().cars == 4, "with four cars on the grid")
    expect(rm.race().laps == 2, "for the host's laps")
    expect(rm.race().phase == "countdown", "on the lights")
    parkBots()
  end)
  step(1, function()
    if not network.startIn() then return "again" end
    expect(network.startIn() > 3.6, "the start is called with time in hand")
  end)
  step(1, function()
    if rm.race().phase ~= "racing" then return "again" end
    expect(rm.race().time < 0.5, "lights out on the shared clock")
  end)
  step(120, function()
    expect(network.peers[2].state ~= nil, "the bots' cars arrive")
    love.keypressed("w", "w", false)
  end)
  step(60, function()
    expect(rm.race().player:getSpeed() > 1, "holding W drives the car online")
    press("escape")
  end)
  step(3, function()
    expect(rm.isPaused(), "escape opens the pause menu")
    expect(rm.race().phase == "racing", "and the race runs on behind it")
    love.keypressed("up", "up", false)
  end)
  step(6, function()
    local car = rm.race().player
    expect(car.input.throttle == 0, "keys held behind the menu don't drive the car")
    expect(car.input.brake == 0, "or brake it")
    love.keyreleased("up")
    love.keyreleased("w")
    shot("pause")
  end)
  step(3, function() press("escape") end)
  step(3, function()
    expect(not rm.isPaused(), "escape resumes")
    bots[3].client.disconnect()
    bots[3].left = true
  end)
  step(1, function()
    if #rm.race().cars ~= 3 then return "again" end
    expect(true, "a driver who quits takes their car off the road")
    expect(#rm.race().order == 4, "and stays in the standings")
  end)
  step(20, function()
    -- P2 takes the flag first, on its own clock.
    bots[1].car.distance = rm.race().track.length * 2 + 1
    bots[1].car.finishTime = rm.race().time
  end)
  step(1, function()
    if not rm.race().flagFell then return "again" end
    expect(true, "the rival's finish puts the flag out here too")
  end)
  step(20, function() shot("flag") end)
  step(3, function()
    local race = rm.race()
    race.player.lapsDone = race.laps - 1
    race.player.distance = race.track.length * race.laps + 1
    bots[2].car.distance = race.track.length * 2 + 1
    bots[2].car.finishTime = race.time + 1
  end)
  step(1, function()
    if not rm.resultsAge() then return "again" end
    local race = rm.race()
    expect(race.player.finished, "the player finishes")
    expect(race.player.place == 2, "second, behind the time the rival sent")
    expect(race.order[4].retired, "with the quitter last")
  end)
  step(1, function()
    if rm.resultsAge() < 0.5 then return "again" end
    shot("results")
    press("return")
  end)
  step(3, function()
    expect(network.hasVoted(), "REMATCH asks for another race")
    expect(network.round == 1, "which waits for everyone")
    bots[1].client.voteRematch()
    bots[2].client.voteRematch()
  end)
  step(1, function()
    if rm.race().phase ~= "countdown" then return "again" end
    expect(state.screen == "race", "everyone agreeing starts the rematch")
    expect(network.round == 2, "as the next round")
    expect(not rm.isFinished(), "with the results gone")
    expect(#rm.race().cars == 3, "and only the drivers who stayed")
    expect(not network.lost, "still connected")
  end)
  step(30, function() press("escape") end)
  step(3, function() press("down") end)
  step(2, function() press("return") end)
  step(5, function()
    expect(state.screen == "menu", "QUIT TO MENU leaves the race")
    expect(network.status == "idle", "and the room")
    expect(settings.track == saved.track and settings.laps == saved.laps and settings.time == saved.time,
      "the player's own setup is untouched")
    bots[1].client.disconnect()
    bots[2].client.disconnect()
    bots = {}
    -- Now the other way round: a stranger's room, on a track this game hasn't got.
    addBot("host", botRoom, "tofu_runner", { def = ownTrack(), title = "Only The Host Has This", laps = 1, time = "midnight" })
  end)
  step(1, function()
    if bots[1].client.status ~= "lobby" then return "again" end
    ui.focus.main = 4
    press("return")
  end)
  step(3, function()
    network.roomCode = botRoom
    ui.focus.online = 6
    press("return")
  end)
  step(1, function()
    if network.status ~= "lobby" or not network.def then return "again" end
    expect(network.setup.title:find("Only The Host"), "the joiner hears about the track")
    expect(network.def.title == network.setup.title, "and gets it, having never had it")
    expect(not menu.onlineRows()[2].label:find("START"), "and only the host can start")
  end)
  step(20, function() shot("joiner") end)
  step(3, function()
    expect(bots[1].client.canStart(), "the host sees the joiner holds the track")
    bots[1].client.startRace()
  end)
  step(1, function()
    if state.screen ~= "race" then return "again" end
    expect(rm.race().track.title:find("Only The Host"), "the race runs on the shared track")
    expect(settings.track == saved.track, "and it's not saved as the player's choice")
    expect(rm.race().player.slot == 2, "from the second seat")
    parkBots()
  end)
  step(1, function()
    if rm.race().phase ~= "racing" then return "again" end
  end)
  step(30, function() shot("shared-track") end)
  step(3, function()
    bots[1].client.disconnect()
    bots = {}
  end)
  step(1, function()
    if #rm.race().cars ~= 1 then return "again" end
    expect(true, "the host leaving a race doesn't end it for the joiner")
    print("ONLINE FLOW PASSED")
    love.event.quit(0)
  end)
  return list
end

function online.start()
  local update = love.update
  love.update = function(dt)
    runBots(1 / 60)
    update(dt)
  end
  flow.run(steps(), true)
end

return online
