local h = require("tests/harness")
local dynamics = require("src/sim/dynamics")
local rumble = require("src/rumble")
local Race = require("src/sim/race")
local Track = require("src/sim/track")
local catalog = require("src/tracks/catalog")
local garage = require("src/entities/garage")
local settings = require("src/settings")
local input = require("src/input")
local ui = require("src/ui")
local config = require("src/config")

local DT = config.PHYSICS_DT

local function pedals(extra)
  local i = { throttle = 0, brake = 0, steer = 0, handbrake = false, boost = false }
  for k, v in pairs(extra or {}) do i[k] = v end
  return i
end

-- How much tank comes back in a second, with the car sliding or not.
local function refilled(beta)
  local spec = garage[1]
  local c = dynamics.new(spec, "arcade")
  c.boostTank = 1
  local vx, vy = 25, 0
  for _ = 1, 1 / DT do
    if beta then c.beta = beta end
    -- The step measures beta for itself, so feed it the matching velocity.
    if beta then vx, vy = 25 * math.cos(beta), 25 * math.sin(beta) end
    dynamics.step(c, pedals(), vx, vy, 0, DT)
  end
  return c.boostTank - 1, c
end

h.describe("drift nitro", function()
  h.it("a slide fills the tank three times faster than cruising", function()
    local cruising = refilled(nil)
    local sliding = refilled(math.rad(25))
    h.assertNear(sliding / cruising, 3, 0.1, "refill ratio")
  end)

  h.it("the gauge knows when a slide is filling it", function()
    local _, straight = refilled(nil)
    local _, slid = refilled(math.rad(25))
    h.assertTrue(not straight.boostFilling, "cruising isn't a slide")
    h.assertTrue(slid.boostFilling, "a slide should show on the gauge")
  end)

  h.it("nothing fills while the nitro is burning", function()
    local c = dynamics.new(garage[1], "arcade")
    dynamics.step(c, pedals({ boost = true }), 25, 0, 0, DT)
    h.assertEq(c.boostState, "active")
    local before = c.boostTank
    for _ = 1, 0.5 / DT do dynamics.step(c, pedals({ boost = true }), 25 * math.cos(0.4), 25 * math.sin(0.4), 0, DT) end
    h.assertTrue(c.boostTank < before, "the tank should drain")
    h.assertTrue(not c.boostFilling, "a burning tank isn't filling")
  end)

  h.it("driving the racing line isn't a slide", function()
    local AI = require("src/ai_controller")
    for _, spec in ipairs(garage) do
      local track = Track.new(catalog.find("lusail").def)
      local race = Race.new({ mode = "race", track = track, laps = 1, opponents = 0, spec = spec,
        assist = "arcade", seed = 7, startDelay = 0.2 })
      race.player.driver = AI.new(track, race.player, { skill = 0.98 })
      local sliding, steps = 0, 0
      while not race.player.finished and steps < 200 / DT do
        race:step(DT)
        steps = steps + 1
        if dynamics.sliding(race.player.model, race.player:getSpeed()) then sliding = sliding + 1 end
      end
      print(string.format("        %-12s sliding %.1f%% of a clean lap", spec.name, sliding / steps * 100))
      h.assertTrue(sliding / steps < 0.02, spec.name .. " slid for " .. sliding / steps)
      race:destroy()
    end
  end)

  h.it("a crawl or reversing isn't a slide", function()
    local c = dynamics.new(garage[1], "arcade")
    c.beta = math.rad(40)
    h.assertTrue(not dynamics.sliding(c, 3), "too slow")
    c.reverse = true
    h.assertTrue(not dynamics.sliding(c, 25), "in reverse")
  end)
end)

h.describe("vibration", function()
  local calm = function()
    local model = dynamics.new(garage[1], "arcade")
    return model
  end

  local function fakePad()
    local pad = { calls = {} }
    function pad:isConnected() return true end
    function pad:isVibrationSupported() return true end
    function pad:setVibration(l, r) self.calls[#self.calls + 1] = { l or 0, r or 0 } end
    return pad
  end

  local function car(model, speed)
    return { model = model, getSpeed = function() return speed or 20 end }
  end

  local function withPad(fn)
    local pad = fakePad()
    local before = input.gamepad
    input.gamepad = pad
    settings.vibration = true
    rumble.stop()
    fn(pad)
    rumble.stop()
    input.gamepad = before
  end

  h.it("a quiet road is quiet", function()
    local l, r = rumble.levels(calm(), 30, 0, 0)
    h.assertEq(l, 0)
    h.assertEq(r, 0)
  end)

  h.it("nitro, kerbs and grass each have their own feel", function()
    local boost = calm()
    boost.boostState = "active"
    local bl, br = rumble.levels(boost, 30, 0, 0)
    h.assertTrue(bl > br and br > 0, "nitro leans on the heavy motor")

    local kerb = calm()
    kerb.wheels[1].surface = "kerb"
    local kl, kr = rumble.levels(kerb, 30, 0, 0)
    h.assertEq(kl, 0, "a kerb is a light buzz")
    h.assertTrue(kr > 0, "a kerb buzzes")

    local grass = calm()
    grass.wheels[3].surface = "grass"
    local gl, gr = rumble.levels(grass, 30, 0, 0)
    h.assertTrue(gl > 0, "grass is a heavy rumble")
    h.assertEq(gr, 0)
  end)

  h.it("never asks a motor for more than full power", function()
    local model = calm()
    model.boostState = "active"
    model.slip = 1
    for i = 1, 4 do model.wheels[i].surface = i < 3 and "kerb" or "gravel" end
    local l, r = rumble.levels(model, 80, 1, 1)
    h.assertEq(l, 1)
    h.assertEq(r, 1)
  end)

  h.it("a crash reaches the pad and dies away", function()
    withPad(function(pad)
      rumble.crash(0.8)
      rumble.update(1 / 60, car(calm()))
      h.assertTrue(#pad.calls >= 1, "the pad should feel it")
      h.assertTrue(pad.calls[1][1] > 0.8, "heavy motor")
      for _ = 1, 120 do rumble.update(1 / 60, car(calm())) end
      h.assertEq(pad.calls[#pad.calls][1], 0, "motors stop")
      h.assertEq(pad.calls[#pad.calls][2], 0, "motors stop")
    end)
  end)

  h.it("doesn't flood the pad with messages", function()
    withPad(function(pad)
      local model = calm()
      model.boostState = "active"
      for _ = 1, 120 do rumble.update(1 / 120, car(model)) end
      h.assertTrue(#pad.calls <= 12, "sent " .. #pad.calls .. " messages in a second")
      h.assertTrue(#pad.calls >= 5, "motors would run out between messages: " .. #pad.calls)
    end)
  end)

  h.it("stops the motors when told to, and stays off in Settings", function()
    withPad(function(pad)
      local model = calm()
      model.boostState = "active"
      rumble.update(1 / 60, car(model))
      rumble.stop()
      h.assertEq(pad.calls[#pad.calls][1], 0, "stopped")

      local count = #pad.calls
      settings.vibration = false
      for _ = 1, 30 do rumble.update(1 / 60, car(model)) end
      h.assertEq(#pad.calls, count, "the setting turns it off")
      settings.vibration = true
    end)
  end)

  h.it("a phone buzzes for hits but not for every gear, and not on repeat", function()
    local buzzes = 0
    local real, mobile = love.system.vibrate, ui.mobile
    love.system.vibrate = function() buzzes = buzzes + 1 end
    ui.mobile = true
    settings.vibration = true
    rumble.stop()
    for _ = 1, 30 do rumble.update(1, car(calm())) end

    rumble.shift()
    h.assertEq(buzzes, 0, "gears stay quiet")
    rumble.crash(1)
    h.assertEq(buzzes, 1, "a crash buzzes")
    rumble.crash(1)
    h.assertEq(buzzes, 1, "too soon after the last")
    rumble.update(1, car(calm()))

    local model = calm()
    model.boostState = "active"
    for _ = 1, 60 do rumble.update(1 / 60, car(model)) end
    h.assertEq(buzzes, 2, "nitro buzzes once as it lights, not all the way through")

    love.system.vibrate, ui.mobile = real, mobile
    rumble.stop()
  end)
end)
