-- Measures a race frame by frame: `love . --perf`. Each case drives an AI around a
-- real circuit and prints one PERF line. GPU work doesn't show in these timers: it
-- appears as waiting in present, and as frames taking longer than the vsync. Any
-- touch during a case adds the time from reaching the game to leaving for the screen.
local state = require("src/state")
local rm = require("src/race_manager")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")
local settings = require("src/settings")
local AI = require("src/ai_controller")
local hud = require("src/hud")
local post = require("src/render/post")
local renderer = require("src/render/track_renderer")
local vfx = require("src/vfx_manager")

local perf = {}

local WARMUP, SAMPLE = 4, 12  -- seconds

local CASES = {
  { name = "mirage-day-low", track = "mirage", time = "day", quality = "low" },
  { name = "harbour-night-low", track = "harbour", time = "night", quality = "low" },
  { name = "harbour-midnight-low", track = "harbour", time = "midnight", quality = "low" },
  { name = "mirage-day-high", track = "mirage", time = "day", quality = "high" },
  { name = "highlands-dusk-high", track = "highlands", time = "dusk", quality = "high" },
  { name = "harbour-night-high", track = "harbour", time = "night", quality = "high" },
  { name = "harbour-midnight-high", track = "harbour", time = "midnight", quality = "high" },
  { name = "mirage-midnight-boost-high", track = "mirage", time = "midnight", quality = "high", boost = true },
  -- The worst of it: speed blur, the warp and a full minute for a phone to heat up.
  { name = "mirage-night-boost-high", track = "mirage", time = "night", quality = "high", boost = true, sample = 60 },
  -- Freestyle's lot: lapping the slalom, through the cones.
  { name = "lot-night-high", lot = true, time = "night", quality = "high" },
}

-- Fires the boost again whenever braking for a corner has cancelled it.
local function boosting(ai)
  return { update = function(_, car, race, dt)
    ai:update(car, race, dt)
    car.input.boost = car.model.boostState ~= "active"
  end }
end

local spent = {}
local touches, touchAt = {}, nil

local function timed(owner, key, label)
  local fn = owner[key]
  owner[key] = function(...)
    local start = love.timer.getTime()
    local a, b, c = fn(...)
    spent[label] = (spent[label] or 0) + love.timer.getTime() - start
    return a, b, c
  end
end

local function percentile(sorted, p)
  return sorted[math.max(1, math.floor(#sorted * p))] or 0
end

local function report(case, frames, drawcalls, switches, garbage)
  table.sort(frames)
  local total = 0
  for _, t in ipairs(frames) do total = total + t end
  local parts = {}
  local labels = {}
  for label in pairs(spent) do labels[#labels + 1] = label end
  table.sort(labels)
  for _, label in ipairs(labels) do
    parts[#parts + 1] = string.format("%s=%.1f", label, spent[label] / #frames * 1000)
  end
  table.sort(touches)
  if #touches > 0 then
    parts[#parts + 1] = string.format("touch(n=%d)=%.1f/%.1f", #touches,
      percentile(touches, 0.5) * 1000, touches[#touches] * 1000)
  end
  print(string.format("PERF %s fps=%.1f p50=%.1f p95=%.1f max=%.1f draws=%d canvases=%d gc=%.0fkB %s",
    case.name, #frames / total, percentile(frames, 0.5) * 1000, percentile(frames, 0.95) * 1000,
    frames[#frames] * 1000, drawcalls, switches, garbage / #frames, table.concat(parts, " ")))
  touches = {}
end

function perf.start()
  print("PERF os=" .. love.system.getOS() .. " jit=" .. tostring(jit and jit.status())
    .. " size=" .. love.graphics.getWidth() .. "x" .. love.graphics.getHeight())
  timed(love, "update", "update")
  timed(love, "draw", "draw")
  timed(love.graphics, "present", "present")
  local present = love.graphics.present
  love.graphics.present = function()
    present()
    if touchAt then
      touches[#touches + 1] = love.timer.getTime() - touchAt
      touchAt = nil
    end
  end
  local touchpressed = love.touchpressed
  love.touchpressed = function(...)
    touchAt = touchAt or love.timer.getTime()
    touchpressed(...)
  end
  timed(renderer, "drawGround", "ground")
  timed(hud, "draw", "hud")
  timed(post, "drawGlow", "glow")
  timed(post, "present", "composite")
  timed(vfx, "draw", "vfx")

  -- CPU time since launch. Everything has loaded by now, so this covers rendering
  -- the sounds on a first launch, and reading them from the cache after that.
  print(string.format("PERF loaded after %.1f s", os.clock()))

  local index, clock, last = 0, 0, nil
  local frames, gcStart, draws, switches = {}, 0, 0, 0

  local function nextCase()
    index = index + 1
    local case = CASES[index]
    if not case then
      print("PERF done")
      love.event.quit()
      return
    end
    settings.quality = case.quality
    post.quality = case.quality
    settings.time = case.time
    rm.start({
      mode = case.lot and "freestyle" or "race", entry = case.track and catalog.find(case.track), spec = garage[3],
      laps = 99, opponents = case.lot and 0 or 5,
      difficulty = "pro", time = case.time, startDelay = 0.2, seed = 3, assist = "arcade",
    })
    state.screen = "race"
    local race = rm.race()
    if case.lot then
      local M = require("src/config").METER
      race.player:teleport(40 * M, -50 * M, -math.pi / 2)
      race.player.driver = { update = function(_, c) c.input.throttle, c.input.steer = 0.75, 0.3 end }
    else
      race.player.driver = AI.new(race.track, race.player, { skill = 0.92 })
    end
    if case.boost then race.player.driver = boosting(race.player.driver) end
    clock, frames = 0, {}
  end

  local draw = love.draw
  love.draw = function()
    draw()
    local stats = love.graphics.getStats()
    draws, switches = stats.drawcalls, stats.canvasswitches
  end

  local update = love.update
  love.update = function(dt)
    update(dt)
    local now = love.timer.getTime()
    if last and clock >= WARMUP then frames[#frames + 1] = now - last end
    last = now
    clock = clock + dt
    if clock < WARMUP then
      spent = {}
      gcStart = collectgarbage("count")
    elseif clock >= WARMUP + (CASES[index].sample or SAMPLE) then
      report(CASES[index], frames, draws, switches, collectgarbage("count") - gcStart)
      nextCase()
      last = nil
    end
  end
  nextCase()
end

return perf
