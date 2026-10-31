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
  h.it("a phone's first run starts on low effects, and a saved choice stands", function()
    ui.mobile = true
    love.filesystem.remove("settings.lua")
    settings.quality = "high"
    settings.load()
    h.assertEq(settings.quality, "low")
    settings.quality = "high"
    settings.save()
    settings.load()
    h.assertEq(settings.quality, "high")
    ui.mobile = false
    love.filesystem.remove("settings.lua")
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

  h.it("buttons don't overlap, even with their slop", function()
    for _, size in ipairs({ { 640, 480 }, { 800, 360 }, { 1280, 720 }, { 2400, 1080 } }) do
      local list = touch.layout(size[1], size[2]).buttons
      for i = 1, #list do
        for j = i + 1, #list do
          local a, b = list[i], list[j]
          local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
          h.assertTrue(d > a.r + b.r, a.action .. " overlaps " .. b.action)
        end
      end
    end
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
