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

local SCENES = {
  menu = function() state.screen = "splash" require("src/splash").timer = 99 end,
  setup = function() menu.enter() settings.mode = "race" menu.go("setup") end,
  settings = function() menu.enter() menu.go("settings") end,
  day = function() race({ track = "lusail", time = "day" }) autopilot() end,
  dusk = function() race({ track = "highlands", time = "dusk" }) autopilot() end,
  night = function() race({ track = "harbour", time = "night" }) autopilot() end,
  start = function() race({ track = "lusail", time = "day" }) rm.race().startDelay = 100 end,
  trial = function() race({ track = "highlands", time = "day", mode = "trial", opponents = 0 }) autopilot() end,
  free = function()
    race({ time = "day", mode = "freestyle", opponents = 0 })
    rm.race().player.driver = { update = function(_, c)
      c.input.throttle, c.input.steer, c.input.handbrake = 1, 0.9, (love.timer.getTime() * 2) % 1 < 0.2
    end }
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
      car.input.boost = rc.time > 7
    end }
  end,
  pause = function() race({ track = "lusail", time = "day" }) autopilot() end,
  results = function() race({ track = "boat", time = "day", opponents = 3 }) autopilot() end,
}

local waitFrames = 180

function visual.start(args)
  local scene, out, frames
  for i, a in ipairs(args) do
    if a == "--visual" then scene, out, frames = args[i + 1], args[i + 2], tonumber(args[i + 3]) end
  end
  waitFrames = frames or waitFrames
  local size = os.getenv("SPPPD_SIZE")
  if size then
    local w, h = size:match("(%d+)x(%d+)")
    love.window.setMode(tonumber(w), tonumber(h), { resizable = true })
  end
  SCENES[scene]()
  visual.scene = scene

  local frame = 0
  local update, draw = love.update, love.draw
  love.update = function(dt)
    frame = frame + 1
    -- Fast-forward at the simulation's own step, whatever the frame rate.
    update(1 / 30)
    if scene == "results" and rm.race() and frame == 5 then
      local r = rm.race()
      for _, car in ipairs(r.cars) do
        car.finished = true
        car.finishTime = 60 + car.body:getX() % 9
      end
      r.phase = "finished"
    end
    if scene == "pause" and frame == waitFrames - 2 then rm.setPaused(true) end
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
