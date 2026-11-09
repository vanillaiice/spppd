local h = require("tests/harness")
local touch = require("src/touch")
local input = require("src/input")
local settings = require("src/settings")
local ui = require("src/ui")

local SW, SH = 1280, 720
-- The middle of the stick's box, set by fresh().
local CX, CY

local function fresh(mode)
  input.clear()
  touch.reset()
  settings.touch = mode or "on"
  settings.autoGas = true
  settings.touchSteer = "stick"
  settings.gearbox = "auto"
  settings.touchSize = "medium"
  settings.touchFeel = "medium"
  local rest = touch.layout(SW, SH).rest
  CX, CY = rest.x, rest.y
  return { steer = 0, throttle = 0, brake = 0 }
end

local function apply()
  local t = { steer = 0, throttle = 0, brake = 0 }
  input.applyTo(t)
  touch.applyTo(t)
  return t
end

local function mediumStick()
  local before = settings.touchSize
  settings.touchSize = "medium"
  local r = touch.layout(SW, SH).radius
  settings.touchSize = before
  return r
end

local function button(action)
  for _, b in ipairs(touch.layout(SW, SH).buttons) do
    if b.action == action then return b end
  end
end

h.describe("touch", function()
  h.it("a phone starts on high effects, and a saved choice stands", function()
    ui.mobile = true
    love.filesystem.remove("settings.lua")
    settings.quality = "high"
    settings.load()
    h.assertEq(settings.quality, "high")
    settings.quality = "low"
    settings.save()
    settings.quality = "high"
    settings.load()
    h.assertEq(settings.quality, "low")
    settings.quality = "high"
    ui.mobile = false
    love.filesystem.remove("settings.lua")
  end)

  h.it("a phone's main menu is big enough for a thumb", function()
    local menu = require("src/menu")
    local mobile = ui.mobile
    ui.mobile = true
    -- What LÖVE reports on a 1600x720 phone, in its density-independent units.
    local s = ui.scale(853, 384)
    local y, rowH = menu.listLayout("main", 8, 384, s)
    ui.mobile = mobile
    h.assertTrue(rowH >= 34, "row height " .. rowH)
    h.assertTrue(y + rowH * 8 <= 384 - 12 * s, "rows reach the version label")
  end)

  h.it("menus go up a size on a phone", function()
    h.assertEq(ui.scale(800, 360), 1)
    ui.mobile = true
    h.assertEq(ui.scale(800, 360), 1.5)
    ui.mobile = false
  end)

  h.it("the stick stays in its corner and the knob follows the thumb", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, CX, CY, SW, SH)
    h.assertEq(touch.stick.baseX, CX)
    h.assertEq(touch.stick.baseY, CY)
    h.assertEq(apply().steer, 0, "touching the middle doesn't steer")
    touch.moved(1, CX + r * 0.8, CY)
    h.assertTrue(apply().steer > 0.4, "right is right")
    touch.moved(1, CX - r * 0.8, CY)
    h.assertTrue(apply().steer < -0.4, "left is left")
    h.assertEq(touch.stick.baseX, CX, "the box didn't move")
    touch.released(1)
    h.assertEq(touch.stick, nil, "gone with the thumb")
  end)

  h.it("a thumb landing off centre in the box steers at once", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, CX + r, CY, SW, SH)
    h.assertEq(apply().steer, 1)
  end)

  h.it("a thumb away from the box doesn't take the stick", function()
    fresh()
    touch.pressed(1, 400, 300, SW, SH)
    h.assertEq(touch.stick, nil)
    h.assertEq(apply().steer, 0)
  end)

  h.it("steers gently around the centre and fully at the edge", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, CX, CY, SW, SH)
    touch.moved(1, CX + r * 0.25, CY)
    h.assertBetween(apply().steer, 0.01, 0.2, "a quarter of the way")
    touch.moved(1, CX + r, CY)
    h.assertEq(apply().steer, 1, "full lock")
  end)

  h.it("steering feel bends the stick's response, and full lock stays full lock", function()
    local r = touch.layout(SW, SH).radius
    local quarter, edge = {}, {}
    for _, feel in ipairs({ "low", "medium", "high" }) do
      fresh()
      settings.touchFeel = feel
      touch.pressed(1, CX, CY, SW, SH)
      touch.moved(1, CX + r * 0.25, CY)
      quarter[feel] = apply().steer
      touch.moved(1, CX + r, CY)
      edge[feel] = apply().steer
    end
    h.assertTrue(quarter.low < quarter.medium and quarter.medium < quarter.high,
      string.format("a quarter push: %.2f %.2f %.2f", quarter.low, quarter.medium, quarter.high))
    for feel, v in pairs(edge) do h.assertEq(v, 1, feel .. " full lock") end
    fresh()
  end)

  h.it("steering feel winds the arrows on slower or faster, and leaves keys alone", function()
    local dynamics = require("src/sim/dynamics")
    local garage = require("src/entities/garage")
    local function windOn(feel)
      fresh()
      settings.touchSteer = "buttons"
      settings.touchFeel = feel
      touch.pressed(1, 20, 300, SW, SH)
      local t = apply()
      local c = dynamics.new(garage[1], "arcade")
      for _ = 1, 6 do dynamics.step(c, t, 30, 0, 0, 1 / 60) end
      touch.released(1)
      return math.abs(c.steerInput), t.steerRate
    end
    local low, lowRate = windOn("low")
    local medium, mediumRate = windOn("medium")
    local high = windOn("high")
    h.assertTrue(low < medium and medium < high, string.format("after 0.1 s: %.3f %.3f %.3f", low, medium, high))
    h.assertEq(mediumRate, 1, "medium is as it was")
    h.assertTrue(lowRate < 1, "low winds on slower")
    fresh()
    h.assertEq(apply().steerRate, nil, "the stick and the keyboard don't use it")
  end)

  h.it("the box stays put when the thumb goes past the edge", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, CX, CY, SW, SH)
    touch.moved(1, CX + r * 3, CY - r * 3)
    h.assertEq(touch.stick.x, 1, "full lock, no further")
    h.assertEq(touch.stick.y, 1, "full gas, no further")
    h.assertEq(touch.stick.baseX, CX)
    h.assertEq(touch.stick.baseY, CY)
    touch.moved(1, CX, CY)
    h.assertEq(touch.stick.x, 0, "back in the middle is straight ahead")
  end)

  h.it("auto gas drives until the stick pulls down", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    local t = apply()
    h.assertEq(t.throttle, 1, "no thumb on the stick yet")
    touch.pressed(1, CX, CY, SW, SH)
    touch.moved(1, CX, CY + r)
    t = apply()
    h.assertEq(t.brake, 1)
    h.assertEq(t.throttle, 0, "the brake lifts the gas, so the car can reverse")
  end)

  h.it("steering doesn't brake by accident", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, CX, CY, SW, SH)
    touch.moved(1, CX + r, CY + r * 0.2)
    local t = apply()
    h.assertEq(t.steer, 1)
    h.assertEq(t.brake, 0)
    h.assertEq(t.throttle, 1)
  end)

  h.it("full lock and full brake work together", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, CX, CY, SW, SH)
    touch.moved(1, CX - r, CY + r)
    local t = apply()
    h.assertEq(t.steer, -1)
    h.assertEq(t.brake, 1)
  end)

  h.it("with auto gas off the stick is the throttle too", function()
    fresh()
    settings.autoGas = false
    local r = touch.layout(SW, SH).radius
    h.assertEq(apply().throttle, 0, "no gas by itself")
    touch.pressed(1, CX, CY, SW, SH)
    touch.moved(1, CX, CY - r)
    h.assertEq(apply().throttle, 1)
    settings.autoGas = true
  end)

  h.it("a second finger on the left doesn't steal the stick", function()
    fresh()
    touch.pressed(1, CX, CY, SW, SH)
    touch.pressed(2, 400, 300, SW, SH)
    h.assertEq(touch.stick.id, 1)
    touch.released(2)
    h.assertTrue(touch.stick ~= nil, "still held")
  end)

  h.it("drift holds, and works alongside the stick", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    local b = button("handbrake")
    touch.pressed(1, CX, CY, SW, SH)
    touch.moved(1, CX + r, CY)
    touch.pressed(2, b.x, b.y, SW, SH)
    local t = apply()
    h.assertTrue(t.handbrake, "drift held")
    h.assertEq(t.throttle, 1, "still on the gas, so the drift keeps going")
    h.assertEq(t.steer, 1, "and still steering")
    touch.released(2)
    h.assertTrue(not apply().handbrake, "released")
  end)

  h.it("only a real push on the stick revs at the lights, not auto gas", function()
    fresh()
    h.assertEq(touch.revs(), 0, "no thumb, no revs")
    touch.pressed(1, CX, CY, SW, SH)
    h.assertEq(touch.revs(), 0, "resting thumb")
    touch.moved(1, CX, CY - touch.stick.radius)
    h.assertEq(touch.revs(), 1, "full push")
    touch.reset()
  end)

  h.it("a tap shorter than one frame still fires boost", function()
    fresh()
    local b = button("boost")
    touch.pressed(1, b.x, b.y, SW, SH)
    touch.released(1)
    h.assertTrue(apply().boost, "tap fires")
    h.assertTrue(not apply().boost, "and only once")
  end)

  h.it("pause and reset press once each", function()
    fresh()
    for _, action in ipairs({ "pause", "respawn" }) do
      local b = button(action)
      touch.pressed(1, b.x, b.y, SW, SH)
      touch.released(1)
      h.assertTrue(input.consume(action), action)
      h.assertTrue(not input.consume(action), action .. " once")
    end
  end)

  h.it("a thumb near a button still hits it, and the nearest one wins", function()
    fresh()
    local b = button("boost")
    touch.pressed(1, b.x - b.r * 1.15, b.y, SW, SH)
    h.assertEq(touch.fingers[1], "boost")
    touch.released(1)
    local small = button("pause")
    touch.pressed(1, small.x + 2, small.y, SW, SH)
    h.assertEq(touch.fingers[1], "pause")
    touch.released(1)
  end)

  -- Every layout on desktop sizes and phones, 16:9 and 20:9, in LÖVE's units.
  -- With every steering, gas, gearbox and TOUCH SIZE choice.
  local function eachLayout(fn)
    local sizes = { { 640, 480 }, { 800, 360 }, { 1280, 720 }, { 2400, 1080 }, { 640, 360, true }, { 853, 384, true } }
    for _, steer in ipairs({ "stick", "buttons" }) do
      for _, gas in ipairs({ true, false }) do
        for _, box in ipairs({ "auto", "manual" }) do
          for _, grow in ipairs({ "small", "medium", "large" }) do
            for _, size in ipairs(sizes) do
              settings.touchSteer, settings.autoGas, ui.mobile = steer, gas, size[3] or false
              settings.gearbox, settings.touchSize = box, grow
              fn(touch.layout(size[1], size[2]), size[1], size[2],
                string.format("%s %s %s %s %dx%d", steer, gas and "auto gas" or "gas", box, grow, size[1], size[2]))
            end
          end
        end
      end
    end
    settings.touchSteer, settings.autoGas, ui.mobile = "stick", true, false
    settings.gearbox, settings.touchSize = "auto", "medium"
  end

  local function clearOf(b, x, y, w, h)
    local nx = math.max(x, math.min(b.x, x + w))
    local ny = math.max(y, math.min(b.y, y + h))
    return (b.x - nx) ^ 2 + (b.y - ny) ^ 2 > b.r ^ 2
  end

  h.it("buttons don't overlap, even with their slop", function()
    eachLayout(function(layout, _, _, name)
      local list = layout.buttons
      for i = 1, #list do
        for j = i + 1, #list do
          local a, b = list[i], list[j]
          local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
          h.assertTrue(d > a.r + b.r, a.action .. " overlaps " .. b.action .. " on " .. name)
        end
      end
    end)
  end)

  h.it("buttons stay off the dash and on the screen", function()
    eachLayout(function(layout, sw, sh, name)
      local s = layout.s
      local dw, dh = 112 * s, 44 * s
      local dx, dy = (sw - dw) / 2, sh - dh - 8 * s
      for _, b in ipairs(layout.buttons) do
        h.assertTrue(clearOf(b, dx, dy, dw, dh), b.action .. " covers the dash on " .. name)
        h.assertTrue(b.x - b.r >= 0 and b.x + b.r <= sw and b.y - b.r >= 0 and b.y + b.r <= sh,
          b.action .. " off the screen on " .. name)
      end
    end)
  end)

  -- The minimap moves up under the top row for touch, and the race tower holds
  -- every car there can be offline.
  h.it("buttons stay off the minimap and the race tower", function()
    local config = require("src/config")
    eachLayout(function(layout, sw, _, name)
      local s = layout.s
      local towerH = 11 * s * (config.OPPONENTS_MAX + 2)
      for _, b in ipairs(layout.buttons) do
        h.assertTrue(clearOf(b, sw - 100 * s, 46 * s, 92 * s, 92 * s), b.action .. " covers the minimap on " .. name)
        h.assertTrue(clearOf(b, 8 * s, 8 * s, 118 * s, towerH), b.action .. " covers the tower on " .. name)
      end
    end)
  end)

  h.it("touch size makes the buttons bigger or smaller where they stand", function()
    fresh()
    local medium = button("boost")
    settings.touchSize = "large"
    local large = button("boost")
    settings.touchSize = "small"
    local small = button("boost")
    h.assertTrue(large.r > medium.r and small.r < medium.r, "radius follows the size")
    h.assertEq(large.x, medium.x)
    h.assertEq(large.y, medium.y)
    h.assertTrue(touch.layout(SW, SH).radius < mediumStick(), "the stick shrinks too")
    settings.touchSize = "medium"
  end)

  h.it("with buttons, a thumb anywhere on the left steers to its side", function()
    fresh()
    settings.touchSteer = "buttons"
    local layout = touch.layout(SW, SH)
    touch.pressed(1, 20, 300, SW, SH)
    h.assertEq(touch.stick, nil, "no stick")
    local t = { steer = 0, throttle = 0, brake = 0 }
    input.applyTo(t)
    touch.applyTo(t)
    h.assertEq(t.steer, -1)
    h.assertTrue(t.keyboard, "winds on like the arrow keys")
    h.assertEq(t.throttle, 1, "auto gas")
    touch.released(1)
    touch.pressed(1, layout.divide + 40, SH - 20, SW, SH)
    h.assertEq(apply().steer, 1)
    touch.released(1)
    h.assertEq(apply().steer, 0, "let go, straight")
  end)

  h.it("a steering thumb rocks across without lifting", function()
    fresh()
    settings.touchSteer = "buttons"
    local layout = touch.layout(SW, SH)
    touch.pressed(1, layout.divide - 30, SH - 40, SW, SH)
    h.assertEq(apply().steer, -1)
    touch.moved(1, layout.divide + 30, SH - 40)
    h.assertEq(apply().steer, 1)
    h.assertTrue(not input.isDown("steerLeft"), "left let go")
    touch.moved(1, layout.divide - 30, SH - 40)
    h.assertEq(apply().steer, -1)
    touch.released(1)
    h.assertEq(apply().steer, 0)
  end)

  h.it("two thumbs on one arrow: lifting one keeps it held", function()
    fresh()
    settings.touchSteer = "buttons"
    touch.pressed(1, 20, SH - 40, SW, SH)
    touch.pressed(2, 30, SH - 100, SW, SH)
    touch.released(1)
    h.assertEq(apply().steer, -1)
    touch.released(2)
    h.assertEq(apply().steer, 0)
  end)

  h.it("brake lifts auto gas and steering keeps working", function()
    fresh()
    settings.touchSteer = "buttons"
    local b = button("brake")
    touch.pressed(1, 20, SH - 40, SW, SH)
    touch.pressed(2, b.x, b.y, SW, SH)
    local t = apply()
    h.assertEq(t.brake, 1)
    h.assertEq(t.throttle, 0)
    h.assertEq(t.steer, -1)
    touch.released(2)
    h.assertEq(apply().throttle, 1)
    touch.reset()
    h.assertTrue(not input.isDown("steerLeft"), "reset lets go of steering")
  end)

  h.it("without auto gas, gas and brake share the bottom row like pedals", function()
    fresh()
    settings.touchSteer, settings.autoGas = "buttons", false
    local gas, brake, drift = button("throttle"), button("brake"), button("handbrake")
    h.assertTrue(math.abs(gas.y - brake.y) < gas.r, "side by side")
    h.assertTrue(drift.y < brake.y - brake.r, "drift goes up out of the way")
    touch.pressed(1, gas.x, gas.y, SW, SH)
    h.assertEq(apply().throttle, 1)
    touch.moved(1, brake.x + 3, brake.y - 4)
    local t = apply()
    h.assertEq(t.brake, 1, "a thumb slides across to the brake")
    h.assertEq(t.throttle, 0, "and lets go of the gas")
    touch.moved(1, gas.x, gas.y)
    t = apply()
    h.assertEq(t.throttle, 1, "and back")
    h.assertEq(t.brake, 0)
    touch.released(1)
    h.assertEq(apply().throttle, 0)
    touch.reset()
    settings.autoGas = true
  end)

  h.it("without auto gas the buttons get a gas pedal", function()
    fresh()
    settings.touchSteer, settings.autoGas = "buttons", false
    h.assertEq(apply().throttle, 0)
    local b = button("throttle")
    touch.pressed(1, b.x, b.y, SW, SH)
    h.assertEq(apply().throttle, 1)
    h.assertEq(touch.revs(), 0, "the gas button revs through the keyboard's own throttle")
    h.assertEq(input.throttle(), 1)
    touch.released(1)
    h.assertEq(apply().throttle, 0)
    settings.autoGas = true
  end)

  h.it("the stick layout has no steering or pedal buttons", function()
    fresh()
    h.assertEq(button("steerLeft"), nil)
    h.assertEq(button("brake"), nil)
    h.assertEq(touch.layout(SW, SH).divide, nil)
  end)

  h.it("reset lets go of everything", function()
    fresh()
    local b = button("handbrake")
    touch.pressed(1, CX, CY, SW, SH)
    touch.pressed(2, b.x, b.y, SW, SH)
    touch.reset()
    h.assertEq(touch.stick, nil)
    h.assertTrue(not input.isDown("handbrake"), "not stuck on after a pause")
  end)

  h.it("stays out of the way until it's wanted", function()
    fresh("auto")
    touch.active = false
    h.assertTrue(not touch.shown(), "hidden on a desktop")
    local t = apply()
    h.assertEq(t.throttle, 0, "no auto gas for a keyboard player")
    touch.active = true
    h.assertTrue(touch.shown(), "appears after a touch")
    settings.touch = "off"
    h.assertTrue(not touch.shown(), "off means off")
    touch.active = false
    settings.touch = "auto"
  end)

  h.it("the automatic box has no shift buttons, and stays automatic", function()
    fresh()
    h.assertEq(button("shiftUp"), nil)
    h.assertEq(button("shiftDown"), nil)
    local t = { steer = 0, throttle = 0, brake = 0 }
    input.applyTo(t, false)
    touch.applyTo(t)
    h.assertTrue(not t.manual)
  end)

  h.it("the manual box gets DOWN on the left and UP on the right, a gear a tap", function()
    for _, steer in ipairs({ "stick", "buttons" }) do
      fresh()
      settings.touchSteer, settings.gearbox = steer, "manual"
      local up, down = button("shiftUp"), button("shiftDown")
      h.assertTrue(down.x < SW / 2 and up.x > SW / 2, "paddles on " .. steer)
      touch.pressed(1, down.x, down.y, SW, SH)
      h.assertEq(touch.stick, nil, "DOWN isn't the stick on " .. steer)
      touch.released(1)
      local t = { steer = 0, throttle = 0, brake = 0 }
      input.applyTo(t, true)
      touch.applyTo(t)
      h.assertTrue(t.manual, "the manual box stands on " .. steer)
      h.assertTrue(t.shiftDown and not t.shiftUp, "one tap, one gear down on " .. steer)
      h.assertEq(t.steer, 0, "and no steering")
      touch.pressed(1, up.x, up.y, SW, SH)
      touch.released(1)
      input.applyTo(t, true)
      touch.applyTo(t)
      h.assertTrue(t.shiftUp and not t.shiftDown, "one tap, one gear up on " .. steer)
      input.applyTo(t, true)
      h.assertTrue(not t.shiftUp, "and only once")
    end
    settings.gearbox = "auto"
  end)

  -- A pad that only does stick and triggers, the way an Android one reads.
  local function fakePad()
    return {
      isConnected = function() return true end,
      isGamepad = function() return true end,
      isVibrationSupported = function() return false end,
      getGamepadAxis = function() return 0 end,
    }
  end

  h.it("a pad's stick or trigger alone hands over from touch, and a touch takes back", function()
    fresh("auto")
    touch.active = true
    local pad = fakePad()
    touch.padAxis(pad, 0.1)
    h.assertTrue(touch.shown(), "a resting stick's drift doesn't count")
    touch.padAxis(pad, 0.8)
    h.assertTrue(not touch.shown(), "a trigger hands over")
    h.assertEq(input.gamepad, pad)
    h.assertTrue(input.padConnected())
    touch.active = true  -- what love.touchpressed does
    h.assertTrue(touch.shown(), "a touch brings them back")
    input.gamepad = nil
    touch.active = false
    settings.touch = "on"
  end)

  h.it("plugging a pad in hides touch, and pulling it out brings touch back on a phone", function()
    fresh("auto")
    local before = ui.mobile
    ui.mobile = true
    touch.active = true
    local pad = fakePad()
    touch.padAdded(pad)
    h.assertTrue(not touch.shown(), "hidden for the pad")
    h.assertTrue(touch.padRemoved(pad), "it was driving")
    h.assertEq(input.gamepad, nil)
    h.assertTrue(touch.shown(), "back without a touch")
    ui.mobile = before
    touch.active = false
    settings.touch = "on"
  end)

  h.it("touch size, opacity and steering feel are saved", function()
    fresh()
    settings.touchSize, settings.touchOpacity, settings.touchFeel = "large", 0.5, "high"
    settings.save()
    settings.touchSize, settings.touchOpacity, settings.touchFeel = "medium", 1, "medium"
    settings.load()
    h.assertEq(settings.touchSize, "large")
    h.assertEq(settings.touchOpacity, 0.5)
    h.assertEq(settings.touchFeel, "high")
    -- The visual tests read this file too, so it goes back to the defaults.
    settings.touch, settings.touchSize, settings.touchOpacity, settings.touchFeel = "auto", "medium", 1, "medium"
    settings.save()
  end)
end)
