local h = require("tests/harness")
local touch = require("src/touch")
local input = require("src/input")
local settings = require("src/settings")
local ui = require("src/ui")

local SW, SH = 1280, 720

local function fresh(mode)
  input.clear()
  touch.reset()
  settings.touch = mode or "on"
  settings.autoGas = true
  settings.touchSteer = "stick"
  return { steer = 0, throttle = 0, brake = 0 }
end

local function apply()
  local t = { steer = 0, throttle = 0, brake = 0 }
  input.applyTo(t)
  touch.applyTo(t)
  return t
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

  h.it("the stick appears where the thumb lands", function()
    fresh()
    touch.pressed(1, 200, 500, SW, SH)
    h.assertEq(touch.stick.baseX, 200)
    h.assertEq(touch.stick.baseY, 500)
    h.assertEq(apply().steer, 0, "touching alone doesn't steer")
    touch.moved(1, 280, 500)
    h.assertTrue(apply().steer > 0.4, "right is right")
    touch.moved(1, 120, 500)
    h.assertTrue(apply().steer < -0.4, "left is left")
    touch.released(1)
    h.assertEq(touch.stick, nil, "gone with the thumb")
  end)

  h.it("steers gently around the centre and fully at the edge", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, 200, 500, SW, SH)
    touch.moved(1, 200 + r * 0.25, 500)
    h.assertBetween(apply().steer, 0.01, 0.2, "a quarter of the way")
    touch.moved(1, 200 + r, 500)
    h.assertEq(apply().steer, 1, "full lock")
  end)

  h.it("the base follows a thumb past the edge, so turning back is instant", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, 200, 500, SW, SH)
    touch.moved(1, 200 + r * 3, 500)
    h.assertEq(touch.stick.x, 1)
    touch.moved(1, 200 + r * 2, 500)
    h.assertEq(touch.stick.x, 0, "one radius back is the centre, not still full lock")
  end)

  h.it("auto gas drives until the stick pulls down", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    local t = apply()
    h.assertEq(t.throttle, 1, "no thumb on the stick yet")
    touch.pressed(1, 200, 500, SW, SH)
    touch.moved(1, 200, 500 + r)
    t = apply()
    h.assertEq(t.brake, 1)
    h.assertEq(t.throttle, 0, "the brake lifts the gas, so the car can reverse")
  end)

  h.it("steering doesn't brake by accident", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, 200, 500, SW, SH)
    touch.moved(1, 200 + r, 500 + r * 0.2)
    local t = apply()
    h.assertEq(t.steer, 1)
    h.assertEq(t.brake, 0)
    h.assertEq(t.throttle, 1)
  end)

  h.it("full lock and full brake work together", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    touch.pressed(1, 200, 500, SW, SH)
    touch.moved(1, 200 - r, 500 + r)
    local t = apply()
    h.assertEq(t.steer, -1)
    h.assertEq(t.brake, 1)
  end)

  h.it("with auto gas off the stick is the throttle too", function()
    fresh()
    settings.autoGas = false
    local r = touch.layout(SW, SH).radius
    h.assertEq(apply().throttle, 0, "no gas by itself")
    touch.pressed(1, 200, 500, SW, SH)
    touch.moved(1, 200, 500 - r)
    h.assertEq(apply().throttle, 1)
    settings.autoGas = true
  end)

  h.it("a second finger on the left doesn't steal the stick", function()
    fresh()
    touch.pressed(1, 200, 500, SW, SH)
    touch.pressed(2, 400, 300, SW, SH)
    h.assertEq(touch.stick.id, 1)
    touch.released(2)
    h.assertTrue(touch.stick ~= nil, "still held")
  end)

  h.it("drift holds, and works alongside the stick", function()
    fresh()
    local r = touch.layout(SW, SH).radius
    local b = button("handbrake")
    touch.pressed(1, 200, 500, SW, SH)
    touch.moved(1, 200 + r, 500)
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
    touch.pressed(1, 100, 200, SW, SH)
    h.assertEq(touch.revs(), 0, "resting thumb")
    touch.moved(1, 100, 200 - touch.stick.radius)
    h.assertEq(touch.revs(), 1, "full push")
    touch.reset()
  end)

  h.it("a tap shorter than one frame still fires nitro", function()
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
  local function eachLayout(fn)
    local sizes = { { 640, 480 }, { 800, 360 }, { 1280, 720 }, { 2400, 1080 }, { 640, 360, true }, { 853, 384, true } }
    for _, steer in ipairs({ "stick", "buttons" }) do
      for _, gas in ipairs({ true, false }) do
        for _, size in ipairs(sizes) do
          settings.touchSteer, settings.autoGas, ui.mobile = steer, gas, size[3] or false
          fn(touch.layout(size[1], size[2]), size[1], size[2],
            string.format("%s %s %dx%d", steer, gas and "auto gas" or "gas", size[1], size[2]))
        end
      end
    end
    settings.touchSteer, settings.autoGas, ui.mobile = "stick", true, false
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
        local nx = math.max(dx, math.min(b.x, dx + dw))
        local ny = math.max(dy, math.min(b.y, dy + dh))
        h.assertTrue((b.x - nx) ^ 2 + (b.y - ny) ^ 2 > b.r ^ 2, b.action .. " covers the dash on " .. name)
        h.assertTrue(b.x - b.r >= 0 and b.x + b.r <= sw and b.y - b.r >= 0 and b.y + b.r <= sh,
          b.action .. " off the screen on " .. name)
      end
    end)
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
    touch.pressed(1, 200, 500, SW, SH)
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

  h.it("forces the automatic box, as there are no shift buttons", function()
    fresh()
    local t = { steer = 0, throttle = 0, brake = 0 }
    input.applyTo(t, true)
    touch.applyTo(t)
    h.assertTrue(not t.manual)
    settings.touch = "auto"
  end)
end)
