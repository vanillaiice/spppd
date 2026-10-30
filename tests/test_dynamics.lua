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
    keyboard = t.keyboard or false,
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
      h.assertBetween(t100, 2.8, 8.5, "0-100 km/h")
      h.assertBetween(top * 3.6, 185, 340, "top speed")
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

  h.it("SPORT and SIM keep the realistic physics", function()
    for _, name in ipairs({ "sport", "sim" }) do
      local assist = dynamics.ASSISTS[name]
      for _, field in ipairs({ "grip", "transfer", "keyRate", "brake", "shift" }) do
        h.assertEq(assist[field], 1, name .. " " .. field)
      end
      for _, field in ipairs({ "turn", "carry", "drift", "offroad" }) do
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

  h.it("nitrous fires once on a press and has a cooldown", function()
    local spec = garage[1]
    local s = sim(spec, "sport")
    s:step(input({ boost = true }))
    h.assertEq(s.c.boostState, "active")
    for _ = 1, (spec.boostTime + 0.1) / DT do s:step(input()) end
    h.assertEq(s.c.boostState, "cooldown", "after burn")
    for _ = 1, 1 / DT do s:step(input({ boost = true })) end
    h.assertEq(s.c.boostState, "cooldown", "no refire during cooldown")
    for _ = 1, (spec.boostCooldown + 0.1) / DT do s:step(input()) end
    h.assertEq(s.c.boostState, "ready", "refilled")
  end)

  h.it("nitrous actually accelerates the car harder", function()
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
