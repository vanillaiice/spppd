-- Scripted screenshots for checking the look: `love . --visual <scene> <out>`.
local state = require("src/state")
local rm = require("src/race_manager")
local menu = require("src/menu")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")
local settings = require("src/settings")
local input = require("src/input")
local ui = require("src/ui")

local visual = {}

local function race(opts)
  rm.start({
    mode = opts.mode or "race", entry = opts.track and catalog.find(opts.track), spec = opts.spec or garage[3],
    laps = 3, opponents = opts.opponents or 5, difficulty = "pro", time = opts.time or "day",
    startDelay = 0.2, seed = 3, assist = "sport",
  })
  state.screen = "race"
end

local function autopilot()
  local AI = require("src/ai_controller")
  local r = rm.race()
  r.player.driver = AI.new(r.track, r.player, { skill = 0.92 })
end

-- Round and round on the lot, which has no line for the AI to follow.
local function circle()
  rm.race().player.driver = { update = function(_, c) c.input.throttle, c.input.steer = 0.6, 0.5 end }
end

-- Lay the game out as a phone would. Pair with SPPPD_SIZE=800x360.
-- SPPPD_GEARBOX=manual adds the shift buttons, and SPPPD_TOUCHSIZE (small, large)
-- and SPPPD_OPACITY (0.25 to 1) set the touch controls' size and opacity.
local function phone()
  ui.mobile = true
  settings.touch = "auto"
  settings.gearbox = os.getenv("SPPPD_GEARBOX") or "auto"
  settings.touchSize = os.getenv("SPPPD_TOUCHSIZE") or "medium"
  settings.touchOpacity = tonumber(os.getenv("SPPPD_OPACITY")) or 1
  require("src/touch").active = true
end

-- Two at one screen, both on autopilot, with a pretend pad for the second:
-- SPPPD_MODE=freestyle for the lot, SPPPD_TIME and SPPPD_TRACK as elsewhere.
local function split()
  local pad = { isConnected = function() return true end, getID = function() return 99 end,
    getGamepadAxis = function() return 0 end, isVibrationSupported = function() return false end }
  local mode = os.getenv("SPPPD_MODE") or "race"
  rm.start({
    mode = mode, entry = mode == "race" and catalog.find(os.getenv("SPPPD_TRACK") or "mirage") or nil,
    spec = garage[3], color = { 0.78, 0.07, 0.09 }, laps = 3, opponents = mode == "race" and 4 or 0,
    difficulty = "pro", time = os.getenv("SPPPD_TIME") or "day", startDelay = 0.2, seed = 3, assist = "sport",
    playerName = "P1", player2 = { spec = garage[6], color = { 0.07, 0.2, 0.62 }, name = "P2" },
    readers = { input.reader(true, nil), input.reader(false, pad) },
  })
  state.screen = "race"
  local AI = require("src/ai_controller")
  local r = rm.race()
  for i, car in ipairs(r.players) do
    if mode == "race" then
      car.driver = AI.new(r.track, car, { skill = 0.92 - i * 0.02 })
    else
      car.driver = { update = function(_, c)
        c.input.throttle, c.input.steer = 1, i == 1 and -0.9 or 0.9
        c.input.handbrake = (love.timer.getTime() * 2 + i) % 1 < 0.2
      end }
    end
  end
end

-- Race setup with a pad plugged in and two players chosen.
local function splitSetup()
  local pad = { isConnected = function() return true end, getID = function() return 99 end,
    getName = function() return "Xbox Wireless Controller" end }
  input.gamepads = function() return { pad } end
  settings.players, settings.car2, settings.hue2 = 2, 6, 6
  menu.enter()
  settings.mode = os.getenv("SPPPD_MODE") or "race"
  menu.go("setup")
  -- Whose rows show: SPPPD_DRIVER=2 for P2's.
  menu.driver = tonumber(os.getenv("SPPPD_DRIVER")) or 1
  ui.focus.setup = 2
end

local SCENES = {
  split = split,
  splitsetup = splitSetup,
  -- The finish with two: P1 home, P2 still out, then both and the results.
  splitfinish = split,
  menu = function() state.screen = "splash" require("src/splash").timer = 99 end,
  setup = function() menu.enter() settings.mode = "race" menu.go("setup") end,
  newestcar = function() settings.car = #garage menu.enter() settings.mode = "race" menu.go("setup") end,
  -- Any one car's panel in race setup: SPPPD_CAR=cyber.
  carcard = function()
    for i, spec in ipairs(garage) do
      if spec.id == os.getenv("SPPPD_CAR") then settings.car = i end
    end
    menu.enter() settings.mode = "race" menu.go("setup")
  end,
  settings = function() menu.enter() menu.go("settings") end,
  freesetup = function()
    menu.enter()
    settings.mode = "freestyle"
    menu.go("setup")
    ui.focus.setup = 7
  end,
  -- Any one car, by id: SPPPD_CAR=cyber.
  car = function()
    race({ track = "mirage", time = "day", spec = garage.byId(os.getenv("SPPPD_CAR") or "cyber"), opponents = 2 })
    autopilot()
  end,
  day = function() race({ track = "mirage", time = "day" }) autopilot() end,
  dusk = function() race({ track = "highlands", time = "dusk" }) autopilot() end,
  night = function() race({ track = "harbour", time = "night" }) autopilot() end,
  -- Any track in the dark: SPPPD_TRACK=touge.
  midnight = function() race({ track = os.getenv("SPPPD_TRACK") or "highlands", time = "midnight" }) autopilot() end,
  -- No other headlights to see by.
  midnightsolo = function()
    race({ track = os.getenv("SPPPD_TRACK") or "touge", time = "midnight", mode = "trial", opponents = 0 })
    autopilot()
  end,
  marina = function() race({ track = "harbour", time = "day" }) autopilot() end,
  start = function()
    race({ track = "mirage", time = "day" })
    local r = rm.race()
    r.startDelay = 100
    r.player.driver = { revs = function() return 0.68 end }
  end,
  trial = function() race({ track = "highlands", time = "day", mode = "trial", opponents = 0 }) autopilot() end,
  free = function()
    race({ time = "day", mode = "freestyle", opponents = 0 })
    rm.race().player.driver = { update = function(_, c)
      c.input.throttle, c.input.steer, c.input.handbrake = 1, 0.9, (love.timer.getTime() * 2) % 1 < 0.2
    end }
  end,
  -- Freestyle's lot, parked by one of its spots: SPPPD_SPOT=donut, slalom, wall,
  -- blocks or start, and SPPPD_TIME for the time of day.
  lot = function()
    race({ time = os.getenv("SPPPD_TIME") or "day", mode = "freestyle", opponents = 0 })
    local M = require("src/config").METER
    local spots = {
      start = { 0, 0, -math.pi / 2 }, donut = { -12, -72, -math.pi / 4 }, slalom = { 60, -40, -math.pi / 2 },
      wall = { -66, 10, -math.pi / 2 }, blocks = { 0, 105, math.pi / 2 },
    }
    local spot = spots[os.getenv("SPPPD_SPOT") or "start"] or spots.start
    local r = rm.race()
    r.player:teleport(spot[1] * M, spot[2] * M, spot[3])
    rm.syncCamera(1)
    r.player.driver = { update = function(_, c) c.input.throttle, c.input.handbrake = 0, true end }
  end,
  editor = function()
    local em = require("src/editor_model")
    local doc = em.fromEntry(catalog.find("highlands"))
    require("src/editor").open(doc)
    state.screen = "editor"
  end,
  boost = function()
    race({ track = "highlands", time = "day", opponents = 2 })
    autopilot()
    local r = rm.race()
    local ai = r.player.driver
    r.player.driver = { update = function(self, car, rc, dt)
      ai:update(car, rc, dt)
      -- Keeps the power on, since braking for a corner would cancel the boost.
      if rc.time > 7 then car.input.throttle, car.input.brake = 1, 0 end
      car.input.boost = rc.time > 7 and car.model.boostState ~= "active"
    end }
  end,
  slipstream = function()
    race({ time = "day", mode = "freestyle", opponents = 0 })
    local r = rm.race()
    local M = require("src/config").METER
    local rival = require("src/entities/car").new(garage[1], 0, -12 * M, -math.pi / 2, { name = "RIVAL" })
    r.cars[2] = rival
    r:initProgress(rival)
    for _, car in ipairs(r.cars) do
      car.driver = { update = function(_, c) c.input.throttle = 1 end }
    end
  end,
  touch = function()
    phone()
    race({ track = "mirage", time = "day" })
    autopilot()
    local touch = require("src/touch")
    local sw, sh = love.graphics.getDimensions()
    local layout = touch.layout(sw, sh)
    touch.pressed(1, 150, sh * 0.7, sw, sh)
    touch.moved(1, 150 + layout.radius * 0.7, sh * 0.7 + layout.radius * 0.5)
  end,
  touchbuttons = function()
    phone()
    settings.touchSteer = "buttons"
    settings.autoGas = os.getenv("SPPPD_AUTOGAS") ~= "off"
    race({ track = "mirage", time = "day" })
    autopilot()
    local touch = require("src/touch")
    local sw, sh = love.graphics.getDimensions()
    touch.pressed(1, 40, sh - 40, sw, sh)
  end,
  phonemain = function() phone() menu.enter() end,
  phonesetup = function() phone() menu.enter() settings.mode = "race" menu.go("setup") end,
  phonesettings = function() phone() menu.enter() menu.go("settings") end,
  controls = function() menu.enter() menu.go("controls") end,
  phonecontrols = function() phone() menu.enter() menu.go("controls") end,
  buttons = function() menu.enter() menu.go("buttons") end,
  phonebuttons = function() phone() menu.enter() menu.go("buttons") end,
  phoneonline = function() phone() menu.enter() settings.mode = "race" menu.go("online") end,
  phonehost = function() phone() menu.enter() settings.mode = "race" menu.go("host") end,
  pause = function() race({ track = "mirage", time = "day" }) autopilot() end,
  -- Freestyle's pause menu, with its CAR and PAINT rows: on the lot, on a phone,
  -- and two at a screen (SPPPD_MODE=freestyle).
  freepause = function() race({ mode = "freestyle", time = "day", opponents = 0 }) circle() end,
  phonefreepause = function() phone() race({ mode = "freestyle", time = "day", opponents = 0 }) circle() end,
  splitpause = split,
  results = function() race({ track = "boat", time = "day", opponents = 3 }) autopilot() end,
  -- Only the player over the line: 40 frames shows the banner, 120 the results.
  finish = function() race({ track = "boat", time = "day", opponents = 3 }) autopilot() end,
}

local waitFrames = 180
local PAUSED = { pause = true, freepause = true, phonefreepause = true, splitpause = true }

function visual.start(args)
  local scene, out, frames
  for i, a in ipairs(args) do
    if a == "--visual" then scene, out, frames = args[i + 1], args[i + 2], tonumber(args[i + 3]) end
  end
  waitFrames = frames or waitFrames
  local size = os.getenv("SPPPD_SIZE")
  if size then
    local w, h = size:match("(%d+)x(%d+)")
    -- A resizable window gets resized by a tiling desktop.
    love.window.setMode(tonumber(w), tonumber(h), { resizable = false })
  end
  SCENES[scene]()
  visual.scene = scene

  local frame = 0
  local update, draw = love.update, love.draw
  love.update = function(dt)
    frame = frame + 1
    -- Fast-forward at the simulation's own step, whatever the frame rate.
    update(1 / 30)
    -- Real time, for recording the mix (SPPPD_PACE=1).
    if os.getenv("SPPPD_PACE") then love.timer.sleep(1 / 30) end
    if scene == "results" and rm.race() and frame == 5 then
      local r = rm.race()
      for _, car in ipairs(r.cars) do
        car.finished = true
        car.finishTime = 60 + car.body:getX() % 9
      end
      r.phase = "finished"
    end
    if scene == "splitfinish" and rm.race() and (frame == 60 or frame == 200) then
      local r = rm.race()
      local car = r.players[frame == 60 and 1 or 2]
      car.lapsDone = r.laps - 1
      car.distance = r.track.length * r.laps + 1
    end
    if scene == "finish" and rm.race() and frame == 60 then
      local r = rm.race()
      r.player.lapsDone = r.laps - 1
      r.player.distance = r.track.length * r.laps + 1
    end
    if PAUSED[scene] and frame == waitFrames - 2 then rm.setPaused(true) end
  end
  love.draw = function()
    draw()
    if frame == waitFrames then
      love.graphics.captureScreenshot(function(data)
        data:encode("png", out or "shot.png")
        local ok, fps = true, love.timer.getFPS()
        print("captured", scene, love.filesystem.getSaveDirectory() .. "/" .. (out or "shot.png"), ok, fps)
        love.event.quit()
      end)
    end
  end
end

return visual
