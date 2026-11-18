-- Each car's SPEED, ACCEL, BRAKE, HANDLING and TIRES, measured by driving it
-- through the real dynamics on SPORT, the realistic tier, rather than typed in.
--
-- Measuring the garage takes about half a second with the JIT off, as it is on a
-- phone, so the numbers ship in car_stats_data.lua, written by `make car-stats`.
-- A test measures again and fails when a car's tuning no longer matches them.
local dynamics = require("src/sim/dynamics")
local config = require("src/config")

local stats = {}

local DT = config.PHYSICS_DT
local G = config.GRAVITY
local TIER = "sport"

-- Where each measure scores 0 and 1. Fixed rather than taken from the garage,
-- so a new car doesn't change the others' bars.
stats.RANGES = {
  speed = { 180, 380 },      -- top speed, km/h
  accel = { 8.5, 2.0 },      -- 0-100 km/h, s
  brake = { 50, 28 },        -- 100-0 km/h, m
  handling = { 0.76, 1.04 }, -- slalom at 90 km/h: mean yaw rate, rad/s
  tires = { 0.95, 1.3 },     -- steady cornering, g
}
stats.ORDER = { "speed", "accel", "brake", "handling", "tires" }
stats.LABELS = { speed = "SPEED", accel = "ACCEL", brake = "BRAKE", handling = "HANDLING", tires = "TIRES" }

-- A free body under the tyre model: just the car, no track or walls.
local function body(spec)
  local s = { c = dynamics.new(spec, TIER), vx = 0, vy = 0, r = 0 }
  function s.step(input)
    local fx, fy, mz = dynamics.step(s.c, input, s.vx, s.vy, s.r, DT)
    s.vx = s.vx + (fx / spec.mass + s.r * s.vy) * DT
    s.vy = s.vy + (fy / spec.mass - s.r * s.vx) * DT
    s.r = s.r + mz / spec.inertia * DT
  end
  return s
end

local function pedals(throttle, brake, steer)
  return { throttle = throttle, brake = brake, steer = steer, handbrake = false, boost = false, keyboard = false }
end

local FULL_GAS = pedals(1, 0, 0)
local FULL_BRAKE = pedals(0, 1, 0)

-- 0-100 km/h, then on to where the car stops gaining: its top speed.
local function straight(spec)
  local s = body(spec)
  local t, t100 = 0, nil
  local lastCheck, lastSpeed = 0, 0
  while t < 90 do
    s.step(FULL_GAS)
    t = t + DT
    if not t100 and s.vx >= 100 / 3.6 then t100 = t end
    if t - lastCheck >= 2 then
      if s.vx - lastSpeed < 0.05 then break end
      lastCheck, lastSpeed = t, s.vx
    end
  end
  return s.vx * 3.6, t100 or math.huge
end

local function stopping(spec)
  local s = body(spec)
  s.vx = 100 / 3.6
  local dist = 0
  while s.vx > 0.5 and dist < 200 do
    s.step(FULL_BRAKE)
    dist = dist + s.vx * DT
  end
  return dist
end

-- A slalom at 90 km/h, full lock one way then the other every half second. The
-- quicker a car turns and turns back, the more yaw it builds: the mean of it.
local function slalom(spec)
  local s = body(spec)
  s.vx = 25
  local sum, n, t = 0, 0, 0
  while t < 6 do
    local dir = math.floor(t / 0.5) % 2 == 0 and 1 or -1
    local v = math.sqrt(s.vx ^ 2 + s.vy ^ 2)
    s.step(pedals(v < 25 and 0.6 or 0, 0, dir))
    t = t + DT
    if t > 2 then sum, n = sum + math.abs(s.r), n + 1 end
  end
  return sum / n
end

-- Peak sideways g in a held full-lock corner at about 108 km/h.
local function cornering(spec)
  local s = body(spec)
  s.vx = 30
  local peak = 0
  for i = 1, 6 / DT do
    local v = math.sqrt(s.vx ^ 2 + s.vy ^ 2)
    s.step(pedals(v < 30 and 0.5 or 0, 0, 1))
    if i > 2 / DT then peak = math.max(peak, math.abs(s.c.ay)) end
  end
  return peak / G
end

-- The raw numbers for one car, measured now.
function stats.measure(spec)
  local top, t100 = straight(spec)
  return { speed = top, accel = t100, brake = stopping(spec), handling = slalom(spec), tires = cornering(spec) }
end

-- Rounded as the data file keeps them.
local DIGITS = { speed = 1, accel = 2, brake = 1, handling = 3, tires = 3 }
function stats.round(raw)
  local out = {}
  for _, key in ipairs(stats.ORDER) do
    local f = 10 ^ DIGITS[key]
    out[key] = math.floor(raw[key] * f + 0.5) / f
  end
  return out
end

local function score(key, value)
  local lo, hi = stats.RANGES[key][1], stats.RANGES[key][2]
  return math.max(0, math.min(1, (value - lo) / (hi - lo)))
end

local ok, shipped = pcall(require, "src/sim/car_stats_data")
stats.shipped = ok and type(shipped) == "table" and shipped or {}
local cache = {}

-- { speed = { value, score, text }, ... } with score 0..1, from the shipped
-- numbers, or measured once for a car they don't have.
function stats.of(spec)
  local done = cache[spec]
  if done then return done end
  local raw = stats.shipped[spec.id] or stats.round(stats.measure(spec))
  local texts = {
    speed = string.format("%.0f KM/H", raw.speed),
    accel = string.format("%.1f S", raw.accel),
    brake = string.format("%.0f M", raw.brake),
    tires = string.format("%.2f G", raw.tires),
  }
  done = {}
  for _, key in ipairs(stats.ORDER) do
    local s = score(key, raw[key])
    done[key] = { value = raw[key], score = s, text = texts[key] or string.format("%d/10", math.floor(s * 10 + 0.5)) }
  end
  cache[spec] = done
  return done
end

-- The data file's text, for the whole garage.
function stats.file(garage)
  local lines = {
    "-- Written by `make car-stats` from src/sim/car_stats.lua. Don't edit by hand.",
    "return {",
  }
  for _, spec in ipairs(garage) do
    local r = stats.round(stats.measure(spec))
    lines[#lines + 1] = string.format("  %s = { speed = %s, accel = %s, brake = %s, handling = %s, tires = %s },",
      spec.id:match("^[%a_][%w_]*$") and spec.id or string.format("[%q]", spec.id),
      r.speed, r.accel, r.brake, r.handling, r.tires)
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

return stats
