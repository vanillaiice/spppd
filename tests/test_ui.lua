local h = require("tests.harness")
local ui = require("src.ui")

-- Three rows 40 tall from the top left, 400 wide: ONE, TWO, and a row with choices.
local W, ROW, SIZE = 400, 40, 10

local log

-- `--test` runs without love.graphics, so the list draws into a stand-in. Press
-- Start 2P is monospaced, every letter as wide as the font is tall.
local function fakeGraphics()
  local nothing = function() end
  local font = function(size)
    return { getWidth = function(_, text) return #text * size end, getHeight = function() return size end,
      setFilter = nothing, setLineHeight = nothing }
  end
  return {
    push = nothing, pop = nothing, origin = nothing, translate = nothing,
    setColor = nothing, rectangle = nothing, polygon = nothing, setLineWidth = nothing,
    setFont = nothing, print = nothing, printf = nothing,
    getScissor = nothing, setScissor = nothing, intersectScissor = nothing,
    transformPoint = function(x, y) return x, y end,
    inverseTransformPoint = function(x, y) return x, y end,
    newFont = function(_, size) return font(size) end,
  }
end

local function rows()
  return {
    { label = "ONE", activate = function() log[#log + 1] = "one" end },
    { label = "TWO", activate = function() log[#log + 1] = "two" end },
    { label = "PICK", value = "X", left = function() log[#log + 1] = "left" end,
      right = function() log[#log + 1] = "right" end },
  }
end

local function fresh(mobile)
  log = {}
  ui.press, ui.down, ui.clicked, ui.nav = nil, false, false, {}
  ui.focus = {}
  ui.mobile = mobile or false
end

-- One frame: whatever arrived is drawn, then the frame ends.
local function frame()
  love.graphics.push()
  love.graphics.origin()
  ui.list("test", rows(), 0, 0, W, ROW, SIZE, 1)
  love.graphics.pop()
  ui.endFrame()
  ui.played = nil
end

local function press(x, y)
  ui.mousemoved(x, y)
  ui.mousepressed(x, y, 1)
end

local function lift(x, y)
  ui.mousemoved(x, y)
  ui.mousereleased(x, y, 1)
end

h.describe("ui", function()
  local real, fonts = love.graphics, ui.fonts
  if not real then love.graphics, ui.fonts = fakeGraphics(), {} end

  h.it("a tap fires its row once, on the lift", function()
    fresh()
    press(100, 20)
    frame()
    h.assertEq(#log, 0, "nothing while the finger is down")
    lift(100, 20)
    frame()
    frame()
    h.assertEq(table.concat(log, ","), "one")
  end)

  h.it("a press and a lift in the same frame still fire", function()
    fresh()
    press(100, 60)
    lift(100, 60)
    frame()
    h.assertEq(table.concat(log, ","), "two")
  end)

  h.it("lifting on another row fires nothing", function()
    fresh()
    press(100, 20)
    frame()
    ui.mousemoved(100, 60)
    frame()
    lift(100, 60)
    frame()
    h.assertEq(#log, 0)
  end)

  h.it("lifting off the list fires nothing", function()
    fresh()
    press(100, 20)
    frame()
    lift(100, 500)
    frame()
    h.assertEq(#log, 0)
  end)

  h.it("sliding off and back on still fires", function()
    fresh()
    press(100, 20)
    frame()
    ui.mousemoved(100, 500)
    frame()
    lift(100, 20)
    frame()
    h.assertEq(table.concat(log, ","), "one")
  end)

  h.it("a press no list saw land never fires", function()
    -- The finger came down on something else, then a list turned up under it.
    fresh()
    press(100, 20)
    ui.endFrame()
    frame()
    lift(100, 20)
    frame()
    h.assertEq(#log, 0)
  end)

  h.it("a press let go of by a screen change never fires", function()
    fresh()
    press(100, 20)
    frame()
    ui.cancelPress()
    lift(100, 20)
    frame()
    h.assertEq(#log, 0)
  end)

  h.it("on a phone, < and > step a row with choices, and the rest of it steps on", function()
    fresh(true)
    local leftX = ui.arrowColumn(rows(), 1, 3, 0, W, ROW, SIZE, 1)
    h.assertTrue(leftX, "a column for <")
    for _, tap in ipairs({ { leftX + ROW / 2, "left" }, { W - ROW / 2, "right" }, { 100, "right" } }) do
      log = {}
      press(tap[1], 100)
      lift(tap[1], 100)
      frame()
      h.assertEq(table.concat(log, ","), tap[2], "tap at " .. tap[1])
    end
    fresh()
  end)

  h.it("a long list's first row and its MORE row each take their own taps", function()
    fresh()
    local long = {}
    for i = 1, 8 do
      long[i] = { label = "ROW" .. i, activate = function() log[#log + 1] = "row" .. i end }
    end
    local function draw()
      ui.list("long", long, 0, 0, W, ROW, SIZE, 1, 4)
      ui.endFrame()
    end
    ui.scroll.long = 1
    press(100, 20)
    lift(100, 20)
    draw()
    h.assertEq(table.concat(log, ","), "row1", "the first row")
    -- Four slots: three rows, then MORE.
    press(100, 140)
    lift(100, 140)
    draw()
    h.assertTrue(ui.scroll.long > 1, "MORE turns the page")
    h.assertEq(#log, 1, "and fires no row")
    ui.scroll.long = 1
  end)

  h.it("a pinned last row stays in the bottom slot on every page", function()
    fresh()
    local long = { pinLast = true }
    for i = 1, 8 do
      long[i] = { label = "ROW" .. i, activate = function() log[#log + 1] = "row" .. i end }
    end
    local function draw()
      ui.list("pinned", long, 0, 0, W, ROW, SIZE, 1, 5)
      ui.endFrame()
    end
    ui.scroll.pinned = 1
    -- Five slots: three rows, MORE, then ROW8. Two MOREs reach the last page.
    for _ = 1, 2 do
      press(100, 180)
      lift(100, 180)
      draw()
      press(100, 140)
      lift(100, 140)
      draw()
    end
    h.assertEq(ui.scroll.pinned, 5, "on the last page")
    press(100, 180)
    lift(100, 180)
    draw()
    h.assertEq(table.concat(log, ","), "row8,row8,row8")
    ui.scroll.pinned = 1
  end)

  h.it("a phone's race setup always shows START", function()
    local menu = require("src.menu")
    local settings = require("src.settings")
    fresh(true)
    local before = settings.mode
    for _, mode in ipairs({ "race", "trial", "freestyle" }) do
      settings.mode = mode
      local list = menu.rows("setup")
      h.assertEq(list[#list].label, "START", mode)
      h.assertTrue(list.pinLast, mode .. " pins it")
    end
    settings.mode = before
    fresh()
  end)

  h.it("on a desktop, the row's left side steps back", function()
    fresh()
    press(100, 100)
    lift(100, 100)
    frame()
    press(350, 100)
    lift(350, 100)
    frame()
    h.assertEq(table.concat(log, ","), "left,right")
  end)

  h.it("a phone's menus have thumb-sized rows that stay on screen and clear of the arrows", function()
    local menu = require("src.menu")
    local settings = require("src.settings")
    fresh(true)
    local before = settings.mode
    for _, size in ipairs({ { 853, 384 }, { 800, 360 } }) do
      local sw, sh = size[1], size[2]
      local s = ui.scale(sw, sh)
      for _, screen in ipairs({ "setup", "settings", "controls", "pad", "online", "profile", "tracks" }) do
        for _, mode in ipairs(screen == "setup" and { "race", "trial", "freestyle" } or { "race" }) do
          settings.mode = mode
          local list = menu.rows(screen)
          local where = string.format("%s %s %dx%d", screen, mode, sw, sh)
          local y, rowH, maxRows = menu.listLayout(screen, #list, sh, s)
          h.assertTrue(rowH >= 32, where .. ": row height " .. rowH)
          h.assertTrue(y + math.min(#list, maxRows) * rowH <= sh - 16 * s, where .. ": runs off the bottom")
          -- As the menu draws it: 8 in from the board, 22 narrower.
          local x, w, size7 = 8 * s, menu.boardWidth(sw, sh, s) - 22 * s, 7 * s
          local leftX = ui.arrowColumn(list, 1, #list, x, w, rowH, size7, s)
          for _, row in ipairs(list) do
            if leftX and row.value and (row.left or row.right) then
              local labelEnd = x + 14 * s + ui.font(size7):getWidth(row.label)
              h.assertTrue(labelEnd + 2 * s <= leftX, where .. ": " .. row.label .. " runs into its <")
            end
          end
        end
      end
    end
    settings.mode = before
    fresh()
  end)

  h.it("a lone button fires on the lift, and not when slid off", function()
    local function button()
      love.graphics.push()
      love.graphics.origin()
      local fired = ui.button("header", "BACK", 300, 0, 48, 24, SIZE, 1)
      love.graphics.pop()
      ui.endFrame()
      return fired
    end
    fresh(true)
    press(320, 10)
    h.assertTrue(not button(), "nothing while the finger is down")
    lift(320, 10)
    h.assertTrue(button(), "fires on the lift")
    h.assertTrue(not button(), "and only once")
    press(320, 10)
    button()
    lift(100, 200)
    h.assertTrue(not button(), "sliding off cancels")
    fresh()
  end)

  h.it("a phone's screens have no BACK rows, as BACK is in the header", function()
    local menu = require("src.menu")
    local settings = require("src.settings")
    local before = settings.mode
    for _, mobile in ipairs({ false, true }) do
      fresh(mobile)
      for _, screen in ipairs({ "setup", "settings", "controls", "pad", "keys", "online", "host", "profile", "tracks" }) do
        local backs = 0
        for _, row in ipairs(menu.rows(screen)) do
          if row.label == "BACK" then backs = backs + 1 end
        end
        h.assertEq(backs, mobile and 0 or 1, screen .. (mobile and " on a phone" or " on a desktop"))
      end
    end
    settings.mode = "race"
    h.assertTrue(menu.rows("setup").pinLast, "a phone's race setup still pins START")
    settings.mode = before
    fresh()
  end)

  h.it("leaving a screen drops what was being typed there", function()
    local menu = require("src.menu")
    local was = menu.screen
    ui.startEditing("AB", function() error("should not be taken") end)
    menu.go("main")
    h.assertTrue(ui.editing == nil)
    menu.go(was or "main")
  end)

  if not real then love.graphics, ui.fonts = nil, fonts end
end)
