local h = require("tests/harness")
local dynamics = require("src/sim/dynamics")
local garage = require("src/entities/garage")
local config = require("src/config")

local DT = config.PHYSICS_DT
local G = config.GRAVITY

-- Simple free-body integrator so the tyre model can be tested alone.
local function sim(spec, assist)
  return {
    c = dynamics.new(spec, assist), vx = 0, vy = 0, r = 0, x = 0, y = 0, a = 0,
    step = function(self, input)
      local fx, fy, mz = dynamics.step(self.c, input, self.vx, self.vy, self.r, DT)
      local ax, ay = fx / spec.mass, fy / spec.mass
      -- velocity is held in the rotating body frame
      self.vx = self.vx + (ax + self.r * self.vy) * DT
      self.vy = self.vy + (ay - self.r * self.vx) * DT
      self.r = self.r + mz / spec.inertia * DT
      self.a = self.a + self.r * DT
      local ca, sa = math.cos(self.a), math.sin(self.a)
      self.x = self.x + (self.vx * ca - self.vy * sa) * DT
      self.y = self.y + (self.vx * sa + self.vy * ca) * DT
    end,
  }
end

local function input(t)
  t = t or {}
  return {
    throttle = t.throttle or 0, brake = t.brake or 0, steer = t.steer or 0,
    handbrake = t.handbrake or false, boost = t.boost or false,
    keyboard = t.keyboard or false, rev = t.rev,
  }
end

local function surface(s, name)
  for _, w in ipairs(s.c.wheels) do w.surface = name end
end

local function speedOf(s)
  return math.sqrt(s.vx ^ 2 + s.vy ^ 2)
end

-- Seconds to reach a yaw rate from a keyboard press at 30 m/s.
local function turnIn(spec, assist)
  local s = sim(spec, assist)
  s.vx = 30
  for i = 1, 2 / DT do
    s:step(input({ steer = 1, throttle = 0.4, keyboard = true }))
    if math.abs(s.r) >= 0.3 then return i * DT end
  end
  return math.huge
end

-- Speed kept after coasting through a long full-lock corner.
local function cornerCarry(spec, assist)
  local s = sim(spec, assist)
  s.vx = 30
  for _ = 1, 2.5 / DT do s:step(input({ steer = 1 })) end
  return speedOf(s) / 30
end

local function launch(spec, assist, targetSpeed, limit)
  local s = sim(spec, assist)
  local t = 0
  while s.vx < targetSpeed and t < (limit or 60) do
    s:step(input({ throttle = 1 }))
    t = t + DT
  end
  return t, s
end

h.describe("dynamics", function()
  h.it("CYBER matches a Model S Plaid", function()
    local spec = garage.byId("cyber")
    local s = sim(spec, "arcade")
    s.c.rpm = spec.redline * 0.72
    dynamics.launch(s.c)
    local t = 0
    while s.vx < 100 / 3.6 and t < 30 do
      s:step(input({ throttle = 1 }))
      t = t + DT
    end
    h.assertBetween(t, 1.9, 2.3, "0-100 km/h with a launch")
    h.assertBetween(dynamics.peakPower(spec) / 1000, 730, 800, "kW")
    h.assertBetween(dynamics.gearingTopSpeed(spec) * 3.6, 315, 335, "top speed")
    for _, other in ipairs(garage) do
      if other ~= spec then h.assertTrue(dynamics.peakPower(other) < dynamics.peakPower(spec), other.name) end
    end
  end)

  for _, spec in ipairs(garage) do
    h.it(spec.name .. " has believable performance", function()
      local t100 = launch(spec, "sport", 100 / 3.6, 30)
      local top = 0
      local s = sim(spec, "sport")
      for _ = 1, 60 / DT do s:step(input({ throttle = 1 })) top = math.max(top, s.vx) end

      local b = sim(spec, "sport")
      b.vx = 100 / 3.6
      local dist = 0
      while b.vx > 0.5 and dist < 200 do
        b:step(input({ brake = 1 }))
        dist = dist + b.vx * DT
      end
      print(string.format("        %-15s 0-100 %.1fs  top %3.0f km/h  100-0 %.1f m  %.0f kW",
        spec.name, t100, top * 3.6, dist, dynamics.peakPower(spec) / 1000))
      h.assertBetween(t100, 2.0, 8.5, "0-100 km/h")
      h.assertBetween(top * 3.6, 185, 385, "top speed")
      h.assertBetween(dist, 28, 52, "100-0 braking")
    end)

    h.it(spec.name .. " holds a steady corner near 1 g", function()
      local s = sim(spec, "sport")
      s.vx = 30
      local peak = 0
      for i = 1, 6 / DT do
        local v = math.sqrt(s.vx ^ 2 + s.vy ^ 2)
        s:step(input({ steer = 1, throttle = v < 30 and 0.5 or 0 }))
        if i > 2 / DT then peak = math.max(peak, math.abs(s.c.ay)) end
      end
      print(string.format("        %-15s lateral %.2f g", spec.name, peak / G))
      h.assertBetween(peak / G, 0.75, 1.45, "lateral g")
    end)

    h.it(spec.name .. " stays controllable when steering hard at speed (default assists)", function()
      local s = sim(spec, "sport")
      s.vx = 40
      local maxBeta = 0
      for i = 1, 5 / DT do
        local steer = (i * DT) % 1.2 < 0.6 and 1 or -1
        s:step(input({ steer = steer, throttle = 1 }))
        maxBeta = math.max(maxBeta, math.abs(s.c.beta))
      end
      print(string.format("        %-15s slalom max slip angle %.1f deg", spec.name, math.deg(maxBeta)))
      h.assertTrue(maxBeta < math.rad(22), "spun out in a slalom: " .. math.deg(maxBeta))
    end)
  end

  for _, spec in ipairs(garage) do
    h.it(spec.name .. " corners harder and carries more speed on arcade", function()
      local g = function(assist)
        local s = sim(spec, assist)
        s.vx = 30
        local peak = 0
        for i = 1, 6 / DT do
          local v = speedOf(s)
          s:step(input({ steer = 1, throttle = v < 30 and 0.5 or 0 }))
          if i > 2 / DT then peak = math.max(peak, math.abs(s.c.ay)) end
        end
        return peak / G
      end
      local arcade, sport = g("arcade"), g("sport")
      local carry = cornerCarry(spec, "arcade")
      print(string.format("        %-15s %.2f g (sport %.2f)  keeps %.0f%% through a corner",
        spec.name, arcade, sport, carry * 100))
      h.assertTrue(arcade >= sport * 1.2, "arcade should out-grip sport")
      h.assertBetween(arcade, 1.15, 1.7, "arcade lateral g")
      h.assertTrue(carry >= 0.85, "lost too much speed in a corner: " .. carry)
      h.assertTrue(carry > cornerCarry(spec, "sport"), "arcade should carry more speed than sport")
    end)

    h.it(spec.name .. " turns in faster on arcade", function()
      local arcade, sport = turnIn(spec, "arcade"), turnIn(spec, "sport")
      h.assertTrue(arcade < sport * 0.75, string.format("arcade %.2fs, sport %.2fs", arcade, sport))
    end)

    h.it(spec.name .. " drifts on a handbrake flick and gathers itself up", function()
      local s = sim(spec, "arcade")
      s.vx = 30
      local slide = 0
      for _ = 1, 0.45 / DT do
        s:step(input({ steer = 1, handbrake = true, keyboard = true }))
        slide = math.max(slide, math.abs(s.c.beta))
      end
      for _ = 1, 1 / DT do
        s:step(input({ steer = 1, throttle = 1, keyboard = true }))
        slide = math.max(slide, math.abs(s.c.beta))
      end
      local kept = speedOf(s) / 30
      local recovered
      for i = 1, 2 / DT do
        s:step(input({ throttle = 1, keyboard = true }))
        if math.abs(s.c.beta) < math.rad(5) and math.abs(s.r) < 0.3 then recovered = i * DT break end
      end
      print(string.format("        %-15s %.0f deg, keeps %.0f%%, straight in %.2fs",
        spec.name, math.deg(slide), kept * 100, recovered or -1))
      h.assertBetween(math.deg(slide), 25, 65, "drift angle")
      h.assertTrue(kept >= 0.85, "scrubbed too much speed: " .. kept)
      h.assertTrue(recovered ~= nil and recovered < 1, "did not straighten up by itself")
      h.assertTrue(s.vx > 0, "ended up going backwards")
    end)

    h.it(spec.name .. " can hold a long arcade drift without spinning", function()
      for _, start in ipairs({ 15, 30, 55 }) do
        local s = sim(spec, "arcade")
        s.vx = start
        local slide = 0
        for _ = 1, 4 / DT do
          s:step(input({ steer = 1, throttle = 1, handbrake = true, keyboard = true }))
          slide = math.max(slide, math.abs(s.c.beta))
        end
        print(string.format("        %-15s from %d m/s: %.0f deg", spec.name, start, math.deg(slide)))
        h.assertTrue(slide < math.rad(60), "spun at " .. start .. " m/s: " .. math.deg(slide))
        h.assertTrue(s.vx > 0, "ended up going backwards from " .. start .. " m/s")
      end
    end)

    h.it(spec.name .. " stays planted in an arcade slalom", function()
      local s = sim(spec, "arcade")
      s.vx = 40
      local maxBeta = 0
      for i = 1, 5 / DT do
        local steer = (i * DT) % 1.2 < 0.6 and 1 or -1
        s:step(input({ steer = steer, throttle = 1, keyboard = true }))
        maxBeta = math.max(maxBeta, math.abs(s.c.beta))
      end
      h.assertTrue(maxBeta < math.rad(22), "spun out in a slalom: " .. math.deg(maxBeta))
    end)

    h.it(spec.name .. " shrugs off the grass on arcade", function()
      local s = sim(spec, "arcade")
      surface(s, "grass")
      s.vx = 40
      for _ = 1, 2 / DT do s:step(input({ throttle = 1 })) end
      h.assertTrue(speedOf(s) / 40 >= 0.88, "too slow on grass: " .. speedOf(s))
    end)
  end

  h.it("off-road speed loss depends on the car", function()
    local function lostOnGravel(spec)
      local s = sim(spec, "arcade")
      surface(s, "gravel")
      s.vx = 40
      for _ = 1, 3 / DT do s:step(input()) end
      return 40 - speedOf(s)
    end
    local samurai = lostOnGravel(garage.byId("samurai"))
    local monster = lostOnGravel(garage.byId("4wd_monster"))
    local hatch = lostOnGravel(garage.byId("hot_hatch"))
    local rocket = lostOnGravel(garage.byId("rocket"))
    h.assertTrue(samurai < monster and monster < hatch and hatch < rocket,
      string.format("%.1f %.1f %.1f %.1f", samurai, monster, hatch, rocket))
  end)

  h.it("sport takes about 30% off the off-road penalty across the garage", function()
    local total = 0
    for _, spec in ipairs(garage) do
      h.assertTrue(spec.looseDrag <= 1, spec.name .. " would pay more than the full penalty")
      total = total + (1 - dynamics.ASSISTS.sport.offroad) * spec.looseDrag
    end
    h.assertBetween(total / #garage, 0.68, 0.72, "average penalty left")
  end)

  h.it("every car still pays for leaving the road", function()
    for _, spec in ipairs(garage) do
      local function speedAfter(name)
        local s = sim(spec, "arcade")
        surface(s, name)
        s.vx = 40
        for _ = 1, 3 / DT do s:step(input()) end
        return speedOf(s)
      end
      h.assertTrue(speedAfter("grass") < speedAfter("asphalt"), spec.name .. " on grass")
      h.assertTrue(speedAfter("gravel") < speedAfter("grass"), spec.name .. " on gravel")
    end
  end)

  -- Everything measured over the 3 s after letting go of a handbrake turn.
  local function afterDrift(spec, steer, throttle)
    local s = sim(spec, "arcade")
    s.vx = 35
    for _ = 1, 0.6 / DT do s:step(input({ steer = 0.6, throttle = 0.5, keyboard = true })) end
    for _ = 1, 0.5 / DT do s:step(input({ steer = 1, handbrake = true, keyboard = true })) end
    local side = s.c.beta > 0 and 1 or -1
    local swing, jump, last = 0, 0, nil
    for _ = 1, 3 / DT do
      local r = s.r
      s:step(input({ steer = steer, throttle = throttle, keyboard = true }))
      local yawAccel = (s.r - r) / DT
      if last then jump = math.max(jump, math.abs(yawAccel - last)) end
      last = yawAccel
      if s.c.beta * side < 0 then swing = math.max(swing, math.abs(s.c.beta)) end
    end
    return swing, jump
  end

  -- Held for a while at full lock, so the drift has fully settled.
  local function heldDrift(spec, seconds, throttle)
    local s = sim(spec, "arcade")
    s.vx = 35
    for _ = 1, seconds / DT do
      s:step(input({ steer = 1, handbrake = true, throttle = throttle, keyboard = true }))
    end
    return s
  end

  for _, spec in ipairs(garage) do
    h.it(spec.name .. " stays in a drift for as long as the handbrake is held", function()
      for _, throttle in ipairs({ 0, 1 }) do
        local s = heldDrift(spec, 1, throttle)
        local low, high = math.huge, 0
        for _ = 1, 2.5 / DT do
          s:step(input({ steer = 1, handbrake = true, throttle = throttle, keyboard = true }))
          if speedOf(s) > 12 then
            local slip = math.abs(s.c.beta)
            low, high = math.min(low, slip), math.max(high, slip)
          end
        end
        h.assertTrue(low > math.rad(25), "fell out of the drift: " .. math.deg(low))
        h.assertTrue(high < math.rad(45), "ran too wide: " .. math.deg(high))
      end
    end)

    h.it(spec.name .. " lets go of a long drift without a snap or a fishtail", function()
      for _, case in ipairs({ { 0, 0 }, { 0, 1 }, { 0.5, 1 } }) do
        local s = heldDrift(spec, 2.5, case[2])
        local side = s.c.beta > 0 and 1 or -1
        local swing, jump, last = 0, 0, nil
        for _ = 1, 3 / DT do
          local r = s.r
          s:step(input({ steer = case[1], throttle = case[2], keyboard = true }))
          local yawAccel = (s.r - r) / DT
          if last then jump = math.max(jump, math.abs(yawAccel - last)) end
          last = yawAccel
          if s.c.beta * side < 0 then swing = math.max(swing, math.abs(s.c.beta)) end
        end
        local label = string.format("steer %.1f throttle %d", case[1], case[2])
        h.assertTrue(swing < math.rad(8), label .. " swung " .. math.deg(swing))
        h.assertTrue(jump < 4, label .. " yaw kick in one step " .. jump)
      end
    end)

    h.it(spec.name .. " straightens gently if the steering comes off mid-drift", function()
      local s = heldDrift(spec, 2, 1)
      local side = s.c.beta > 0 and 1 or -1
      local swing = 0
      for _ = 1, 2 / DT do
        s:step(input({ steer = 0, handbrake = true, throttle = 1, keyboard = true }))
        if s.c.beta * side < 0 then swing = math.max(swing, math.abs(s.c.beta)) end
      end
      h.assertTrue(math.abs(s.c.beta) < math.rad(12), "still sliding: " .. math.deg(s.c.beta))
      h.assertTrue(swing < math.rad(8), "swung the other way " .. math.deg(swing))
    end)

    h.it(spec.name .. " can be flicked across or caught with the handbrake held", function()
      local across = heldDrift(spec, 1.5, 1)
      local side = across.c.beta > 0 and 1 or -1
      local spun = 0
      for _ = 1, 2.5 / DT do
        across:step(input({ steer = -1, handbrake = true, throttle = 1, keyboard = true }))
        spun = math.max(spun, math.abs(across.c.beta))
      end
      h.assertTrue(across.c.beta * side < 0 or math.abs(across.c.beta) < math.rad(45),
        "countersteer has no effect: " .. math.deg(across.c.beta))
      h.assertTrue(spun < math.rad(70), "spun: " .. math.deg(spun))
      h.assertTrue(across.vx > 0, "ended up going backwards")
    end)
  end

  for _, spec in ipairs(garage) do
    h.it(spec.name .. " comes out of a drift without a snap or a fishtail", function()
      for _, case in ipairs({ { 0, 0 }, { 0, 1 }, { 0.5, 1 } }) do
        local swing, jump = afterDrift(spec, case[1], case[2])
        local label = string.format("steer %.1f throttle %d", case[1], case[2])
        h.assertTrue(swing < math.rad(8), label .. " swung " .. math.deg(swing))
        h.assertTrue(jump < 4, label .. " yaw kick in one step " .. jump)
      end
    end)
  end

  h.it("revving spins the engine against a limiter and doesn't move the car", function()
    local spec = garage[1]
    local s = sim(spec, "arcade")
    local lowest, highest = math.huge, 0
    for i = 1, 2 / DT do
      s:step({ throttle = 0, brake = 0, steer = 0, rev = 1 })
      if i > 1 / DT then
        lowest = math.min(lowest, s.c.rpm)
        highest = math.max(highest, s.c.rpm)
      end
    end
    h.assertEq(s.vx, 0, "the clutch is in")
    h.assertBetween(highest, spec.redline * 0.95, spec.redline * 1.02, "reaches the limiter")
    h.assertTrue(lowest < spec.redline * 0.93, "and bounces off it: " .. lowest)
    h.assertTrue(lowest > spec.redline * 0.9, "a tight bounce: " .. lowest)
    h.assertEq(s.c.throttle, 1, "the engine sounds loaded")
    h.assertTrue(s.c.limiting, "and it's up against the limiter")
    for _ = 1, 1 / DT do s:step(input()) end
    h.assertTrue(s.c.rpm < spec.idleRpm * 1.2, "falls back to idle: " .. s.c.rpm)
    h.assertTrue(not s.c.limiting, "and leaves the limiter")
  end)

  h.it("an electric motor holds its revs at the lights without bouncing", function()
    local spec = garage.byId("cyber")
    local s = sim(spec, "arcade")
    local lowest = math.huge
    for i = 1, 8 / DT do
      s:step({ throttle = 0, brake = 0, steer = 0, rev = 1 })
      if i > 6 / DT then lowest = math.min(lowest, s.c.rpm) end
      h.assertTrue(not s.c.limiting, "no limiter")
    end
    h.assertTrue(lowest > spec.redline * 0.97, "steady: " .. lowest)
    h.assertEq(s.vx, 0, "the clutch is in")
  end)

  h.it("the limiter bounces quickly, but the launch window is still slow to fill", function()
    local spec = garage[1]
    local s = sim(spec, "arcade")
    local crossings, above = 0, false
    for i = 1, 2 / DT do
      s:step({ throttle = 0, brake = 0, steer = 0, rev = 1 })
      if i > 1 / DT then
        local now = s.c.rpm > spec.redline * 0.945
        if now and not above then crossings = crossings + 1 end
        above = now
      end
    end
    h.assertTrue(crossings >= 7, "bounces a second: " .. crossings)
    local held = sim(spec, "arcade")
    for _ = 1, 3 / DT do held:step({ throttle = 0, brake = 0, steer = 0, rev = 0.68 }) end
    h.assertBetween(held.c.rpm / spec.redline, dynamics.LAUNCH_LOW, dynamics.LAUNCH_HIGH, "holds the window")
    h.assertTrue(not held.c.limiting, "nowhere near the limiter")
  end)

  h.it("a launch is judged by the revs when the lights go out", function()
    local spec = garage[1]
    local c = dynamics.new(spec, "arcade")
    local function at(ratio)
      c.rpm = spec.redline * ratio
      return dynamics.launchQuality(c)
    end
    h.assertEq(at(0.7), 1, "in the window")
    h.assertEq(at(dynamics.LAUNCH_LOW), 1, "bottom of the window")
    h.assertEq(at(dynamics.LAUNCH_HIGH), 1, "top of the window")
    h.assertEq(at(0.2), 0, "bogged down")
    h.assertTrue(at(0.9) < 1, "sitting on the limiter isn't perfect")
    h.assertTrue(at(0.9) > at(0.95), "and it gets worse towards redline")
  end)

  -- Speed after two seconds on full throttle from a launch at these revs.
  local function launched(spec, ratio, throttle)
    local s = sim(spec, "arcade")
    s.c.rpm = spec.redline * ratio
    dynamics.launch(s.c)
    for _ = 1, 2 / DT do s:step(input({ throttle = throttle })) end
    return s.vx
  end

  for _, spec in ipairs(garage) do
    h.it(spec.name .. " gets a real shove from a perfect launch", function()
      local gain = launched(spec, 0.72, 1) - launched(spec, 0.2, 1)
      print(string.format("        %-15s perfect launch +%.1f m/s after 2s", spec.name, gain))
      h.assertBetween(gain, 2.5, 6, "speed gained")
    end)
  end

  h.it("a launch needs the throttle down", function()
    h.assertTrue(launched(garage[1], 0.72, 0) < 0.5, "the car stays put without gas")
  end)

  h.it("SPORT and SIM keep the realistic physics", function()
    for _, name in ipairs({ "sport", "sim" }) do
      local assist = dynamics.ASSISTS[name]
      for _, field in ipairs({ "grip", "transfer", "keyRate", "brake", "shift" }) do
        h.assertEq(assist[field], 1, name .. " " .. field)
      end
      for _, field in ipairs({ "turn", "carry", "drift" }) do
        h.assertEq(assist[field], 0, name .. " " .. field)
      end
      local s = sim(garage[1], name)
      s.vx = 30
      for _ = 1, 1 / DT do s:step(input({ steer = 1, handbrake = true })) end
      h.assertEq(s.c.drift, 0, name .. " should lock the rear, not drift")
    end
  end)

  h.it("the handbrake still stops an arcade car at low speed", function()
    local s = sim(garage[1], "arcade")
    s.vx = 8
    for _ = 1, 3 / DT do s:step(input({ handbrake = true })) end
    h.assertEq(s.c.drift, 0, "no drift at parking speed")
    h.assertBetween(s.vx, 0, 2, "speed after handbrake")
  end)

  h.it("stops dead on the brakes and doesn't creep or jitter", function()
    local spec = garage[1]
    local s = sim(spec, "sport")
    s.vx = 20
    while s.vx > 0.05 do s:step(input({ brake = 1 })) end
    for _ = 1, 3 / DT do s:step(input()) end
    h.assertBetween(math.abs(s.vx), 0, 0.2, "settled speed")
    h.assertBetween(math.abs(s.vy), 0, 0.05, "side creep")
    h.assertBetween(math.abs(s.r), 0, 0.05, "yaw creep")
  end)

  h.it("reverses when brake is held from a stop, and throttle cancels it", function()
    local s = sim(garage[1], "sport")
    for _ = 1, 2 / DT do s:step(input({ brake = 1 })) end
    h.assertBetween(s.vx, -12, -2, "reversing speed")
    h.assertTrue(s.c.reverse, "reverse flag")
    for _ = 1, 3 / DT do s:step(input({ throttle = 1 })) end
    h.assertTrue(s.vx > 2, "should drive forward again: " .. s.vx)
    h.assertTrue(s.c.gear == 1 or s.vx > 8, "sane gear after reversing")
    h.assertTrue(not s.c.reverse, "reverse flag cleared")
  end)

  h.it("rear-drive car with no assists breaks traction; assists stop it", function()
    local spec = require("src/entities/vehicles/muscle_monster")
    local raw = sim(spec, "sim")
    local tamed = sim(spec, "full")
    raw.vx, tamed.vx = 12, 12
    local rawSlide, tamedSlide = 0, 0
    for _ = 1, 2.5 / DT do
      raw:step(input({ throttle = 1, steer = 0.7 }))
      tamed:step(input({ throttle = 1, steer = 0.7 }))
      rawSlide = math.max(rawSlide, math.abs(raw.c.beta))
      tamedSlide = math.max(tamedSlide, math.abs(tamed.c.beta))
    end
    print(string.format("        raw %.0f deg, assisted %.0f deg", math.deg(rawSlide), math.deg(tamedSlide)))
    h.assertTrue(rawSlide > math.rad(25), "SIM should be able to spin the car")
    h.assertTrue(tamedSlide < math.rad(20), "FULL assists should keep it pointing straight")
  end)

  h.it("handbrake swings the tail out", function()
    local s = sim(garage[3], "sport")
    s.vx = 25
    local maxBeta = 0
    for i = 1, 2 / DT do
      s:step(input({ steer = 1, handbrake = i < 0.8 / DT }))
      maxBeta = math.max(maxBeta, math.abs(s.c.beta))
    end
    h.assertTrue(maxBeta > math.rad(14), "handbrake should rotate the car: " .. math.deg(maxBeta))
  end)

  h.it("grass cuts grip and slows the car", function()
    local spec = garage[1]
    local s = sim(spec, "sport")
    s.vx = 35
    for _, w in ipairs(s.c.wheels) do w.surface = "grass" end
    for _ = 1, 3 / DT do s:step(input()) end
    h.assertTrue(s.vx < 26, "grass should scrub speed: " .. s.vx)
  end)

  h.it("boost switches on and off with each press and saves what's left", function()
    local spec = garage[1]
    local s = sim(spec, "sport")
    s:step(input({ boost = true }))
    h.assertEq(s.c.boostState, "active")
    for _ = 1, 0.5 / DT do s:step(input({ boost = true })) end
    h.assertEq(s.c.boostState, "active", "holding the button is still one press")
    s:step(input())
    s:step(input({ boost = true }))
    h.assertEq(s.c.boostState, "ready", "second press turns it off")
    h.assertBetween(s.c.boostTank, spec.boostTime - 0.6, spec.boostTime - 0.4, "tank kept")
  end)

  h.it("an empty tank locks boost out until it has refilled a little", function()
    local spec = garage[1]
    local s = sim(spec, "sport")
    s:step(input({ boost = true }))
    for _ = 1, (spec.boostTime + 0.1) / DT do s:step(input()) end
    h.assertEq(s.c.boostState, "cooldown", "after burn")
    s:step(input({ boost = true }))
    h.assertEq(s.c.boostState, "cooldown", "no refire on an empty tank")
    s:step(input())
    for _ = 1, (spec.boostCooldown + 0.1) / DT do s:step(input()) end
    h.assertEq(s.c.boostState, "ready", "refilled")
    h.assertNear(s.c.boostTank, spec.boostTime, 0.001, "full tank")
  end)

  h.it("braking shuts the boost off", function()
    local s = sim(garage[1], "sport")
    s.vx = 30
    s:step(input({ boost = true }))
    s:step(input({ brake = 1 }))
    h.assertEq(s.c.boostState, "ready")
    s:step(input({ brake = 1, boost = true }))
    h.assertEq(s.c.boostState, "ready", "can't light it on the brakes")
  end)

  -- Speed gained in 1.5 s on full throttle, after settling into a gear.
  h.it("boost can't be lit at the lights, and a held button needs a fresh press", function()
    local spec = garage[1]
    local s = sim(spec, "sport")
    s:step(input({ rev = 1, boost = true }))
    h.assertEq(s.c.boostState, "ready", "no firing at the lights")
    h.assertEq(s.c.boostTank, spec.boostTime, "and the tank stays full")
    s:step(input({ boost = true }))
    h.assertEq(s.c.boostState, "ready", "still held at lights out")
    s:step(input())
    s:step(input({ boost = true }))
    h.assertEq(s.c.boostState, "active", "a new press lights it")
  end)

  local function pull(spec, startSpeed, steer, boost)
    local s = sim(spec, "arcade")
    s.vx = startSpeed
    for _ = 1, 0.5 / DT do s:step(input({ throttle = 1, steer = steer })) end
    local before = speedOf(s)
    for _ = 1, 1.5 / DT do s:step(input({ throttle = 1, steer = steer, boost = boost })) end
    return speedOf(s) - before
  end

  for _, spec in ipairs(garage) do
    h.it(spec.name .. " feels boost in low gears and out of corners", function()
      for _, case in ipairs({ { 0, 0 }, { 12, 0 }, { 20, 0.5 } }) do
        local gain = pull(spec, case[1], case[2], true) - pull(spec, case[1], case[2], false)
        h.assertTrue(gain > 3, string.format("%d m/s, steer %.1f: only %.1f", case[1], case[2], gain))
      end
    end)
  end

  h.it("boost actually accelerates the car harder", function()
    local spec = garage[2]
    local a, b = sim(spec, "sport"), sim(spec, "sport")
    while a.vx < 35 do a:step(input({ throttle = 1 })) end
    while b.vx < 35 do b:step(input({ throttle = 1 })) end
    for _ = 1, 2 / DT do
      a:step(input({ throttle = 1 }))
      b:step(input({ throttle = 1, boost = true }))
    end
    h.assertTrue(b.vx > a.vx + 1.5, string.format("boost %.1f vs %.1f", b.vx, a.vx))
  end)

  h.it("automatic gearbox shifts up and back down", function()
    local s = sim(garage[1], "sport")
    local topGear = 1
    for _ = 1, 15 / DT do
      s:step(input({ throttle = 1 }))
      topGear = math.max(topGear, s.c.gear)
    end
    h.assertTrue(topGear >= 4, "should reach 4th: " .. topGear)
    for _ = 1, 6 / DT do s:step(input({ brake = 1 })) end
    h.assertTrue(s.c.gear <= 2, "should drop to 1st/2nd: " .. s.c.gear)
  end)

  h.it("is frame-rate independent enough to race fairly", function()
    -- Same launch at half the step size must land within 1%.
    local spec = garage[2]
    local fine = sim(spec, "sport")
    local coarse = sim(spec, "sport")
    for _ = 1, 8 / DT do coarse:step(input({ throttle = 1 })) end
    local realDT = DT
    for _ = 1, 16 / DT do
      local fx, fy, mz = dynamics.step(fine.c, input({ throttle = 1 }), fine.vx, fine.vy, fine.r, realDT / 2)
      fine.vx = fine.vx + fx / spec.mass * realDT / 2
      fine.vy = fine.vy + fy / spec.mass * realDT / 2
      fine.r = fine.r + mz / spec.inertia * realDT / 2
    end
    h.assertNear(fine.vx, coarse.vx, coarse.vx * 0.01, "speed after 8s")
  end)
end)

-- Gas and brake together near a stop: the driven tyres spin, the others hold.
h.describe("burnouts", function()
  local function firstWith(drive)
    for _, spec in ipairs(garage) do
      if spec.drive == drive then return spec end
    end
  end

  local function burn(spec, t, seconds)
    local s = sim(spec, "arcade")
    for _ = 1, seconds / DT do s:step(input(t)) end
    return s
  end

  local function spins(s, front)
    local w = s.c.wheels[front and 1 or 3]
    return w.spin
  end

  local SPINS = { RWD = { false, true }, FWD = { true, false }, AWD = { true, true } }
  for _, spec in ipairs(garage) do
    local drive = spec.drive
    local frontSpins, rearSpins = SPINS[drive][1], SPINS[drive][2]
    h.it(spec.name .. " (" .. drive .. ") spins only its driven tyres, on the limiter in first", function()
      local s = burn(spec, { throttle = 1, brake = 1 }, 2)
      h.assertTrue(s.c.burnout > 0, "in a burnout")
      h.assertEq(spins(s, true) > 20, frontSpins, "front tyres spinning")
      h.assertEq(spins(s, false) > 20, rearSpins, "rear tyres spinning")
      h.assertEq(s.c.gear, 1)
      if not spec.motor then h.assertTrue(s.c.rpm > spec.redline * 0.85, "revs up high") end
      h.assertTrue(not s.c.reverse, "not backing up")
      if drive == "AWD" then
        h.assertBetween(s.vx, 0.5, 2, "AWD crawls: its brakes can't hold all four")
      else
        h.assertTrue(speedOf(s) < 0.3, "held on the spot")
      end
    end)
  end

  h.it("steered, RWD swings round the most and FWD the least", function()
    local function yaw(drive)
      return math.abs(burn(firstWith(drive), { throttle = 1, brake = 1, steer = 1 }, 2).r)
    end
    local rwd, fwd, awd = yaw("RWD"), yaw("FWD"), yaw("AWD")
    h.assertTrue(rwd > 0.8, "RWD turns on the spot: " .. rwd)
    h.assertTrue(fwd < awd and awd < rwd, string.format("FWD %.2f < AWD %.2f < RWD %.2f", fwd, awd, rwd))
  end)

  h.it("lets go into a launch when the brake comes off", function()
    local spec = firstWith("RWD")
    local s = burn(spec, { throttle = 1, brake = 1 }, 1)
    for _ = 1, 1.5 / DT do s:step(input({ throttle = 1 })) end
    h.assertTrue(s.c.burnout == 0 and s.vx > 4, "drives off")
  end)

  h.it("is plain braking at speed", function()
    local s = sim(firstWith("RWD"), "arcade")
    s.vx = 20
    s:step(input({ throttle = 1, brake = 1 }))
    h.assertEq(s.c.burnout, 0)
  end)

  h.it("smokes at the lights without moving the car or backing it up", function()
    for _, drive in ipairs({ "RWD", "FWD", "AWD" }) do
      local s = burn(firstWith(drive), { rev = 1, brake = 1 }, 1.5)
      h.assertTrue(s.c.burnout > 0, drive .. " burning at the lights")
      h.assertTrue(speedOf(s) < 0.05, drive .. " stays on its spot")
      h.assertTrue(not s.c.reverse, drive .. " not in reverse")
    end
  end)

  h.it("shows on a car another game drives, from its pedals", function()
    local c = dynamics.new(firstWith("FWD"), "arcade")
    c.throttle, c.brake = 1, 1
    dynamics.showBurnout(c, 0)
    h.assertTrue(c.wheels[1].spin > 20 and c.wheels[3].spin == 0, "front tyres smoke")
    c.brake = 0
    dynamics.showBurnout(c, 0)
    h.assertEq(c.wheels[1].spin, 0, "and stop when it lets go")
  end)
end)
