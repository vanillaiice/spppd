-- Race HUD, laid out like a broadcast timing screen: the tower top left,
-- the dash bottom right, and everything else out of the way of the road.
local ui = require("src/ui")
local colors = require("src/colors")
local settings = require("src/settings")
local minimap = require("src/minimap")
local touch = require("src/touch")
local dynamics = require("src/sim/dynamics")

local hud = {}

local DASH_W, DASH_H = 112, 44

-- How long the finish banner holds the screen before the results open.
hud.FINISH_HOLD = 3
local BANNER_IN, BANNER_OUT = 0.35, 0.25

-- The dash moves out from under the right thumb when touch controls are up.
-- With two at a screen, each dash sits at the outside edge of its own half, away
-- from the map on the seam.
local function dashX(sw, s, left)
  if left then return 8 * s end
  if touch.shown() then return (sw - DASH_W * s) / 2 end
  return sw - DASH_W * s - 8 * s
end

function hud.formatTime(t)
  if not t then return "--:--.---" end
  local minutes = math.floor(t / 60)
  local seconds = t - minutes * 60
  return string.format("%d:%06.3f", minutes, seconds)
end

local function speedText(car)
  local v = car:getSpeed()
  if settings.units == "mph" then return math.floor(v * 2.237 + 0.5), "MPH" end
  return math.floor(v * 3.6 + 0.5), "KM/H"
end

hud.TOWER_W = 118

-- The lap and its time are the focus car's: the player's, or with two at a
-- screen, whoever of them is ahead.
local function drawTower(race, s, x, y, focus)
  local order = race.order
  x, y = x or 8 * s, y or 8 * s
  focus = focus or race.player
  local rowH, size = 11 * s, 6 * s
  local w = hud.TOWER_W * s
  ui.panel(x, y, w, rowH * (#order + 1), 0.8)
  local lap = race:currentLap(focus)
  ui.text("LAP " .. lap .. "/" .. race.laps, x + 4 * s, y + 3 * s, size, colors.marshal)
  ui.text(hud.formatTime(race.time - focus.lapStart):sub(1, 7), x, y + 3 * s, size, colors.paint, "right", w - 4 * s)
  y = y + rowH

  local leader = order[1]
  for i, car in ipairs(order) do
    local ry = y + (i - 1) * rowH
    if car.isPlayer then
      love.graphics.setColor(colors.marshal[1], colors.marshal[2], colors.marshal[3], 0.2)
      love.graphics.rectangle("fill", x, ry, w, rowH)
    end
    love.graphics.setColor(car.color)
    love.graphics.rectangle("fill", x + 2 * s, ry + 2 * s, 2 * s, rowH - 4 * s)
    local gap
    if car == leader then
      gap = "LEAD"
    elseif car.retired then
      gap = "OUT"
    elseif car.finished and car.finishTime and leader.finishTime then
      gap = string.format("+%.1f", car.finishTime - leader.finishTime)
    else
      -- Convert the distance gap into seconds at the follower's pace.
      local behind = leader.distance - car.distance
      local pace = math.max(12, car:getSpeed() * 12)
      gap = string.format("+%.1f", behind / pace)
    end
    ui.text(i .. " " .. car.name, x + 7 * s, ry + 3 * s, size, car.isPlayer and colors.marshal or colors.paint)
    ui.text(gap, x, ry + 3 * s, size, colors.muted, "right", w - 4 * s)
  end
end

local function drawTrialPanel(race, ctx, s)
  local x, y = 8 * s, 8 * s
  local rowH, size = 11 * s, 6 * s
  local w = 118 * s
  local car = race.player
  ui.panel(x, y, w, rowH * 3, 0.8)
  local current = race.phase == "racing" and race.time - car.lapStart or 0
  ui.text("NOW", x + 4 * s, y + 3 * s, size, colors.muted)
  ui.text(hud.formatTime(current), x, y + 3 * s, size, car.lapClean and colors.paint or colors.kerb, "right", w - 4 * s)
  ui.text("LAST", x + 4 * s, y + rowH + 3 * s, size, colors.muted)
  ui.text(hud.formatTime(car.lastLap), x, y + rowH + 3 * s, size, colors.paint, "right", w - 4 * s)
  ui.text("BEST", x + 4 * s, y + rowH * 2 + 3 * s, size, colors.muted)
  -- Each rule keeps its own best, so say whose this is.
  ui.text(race.rules == "open" and "OPEN" or "CLEAN", x + 31 * s, y + rowH * 2 + 4 * s, 4 * s, colors.muted)
  ui.text(hud.formatTime(ctx.bestLap), x, y + rowH * 2 + 3 * s, size, colors.sectorPurple, "right", w - 4 * s)
end

local function drawDrift(view, sw, s)
  local drift = view.drift
  if not drift then return end
  local y = 8 * s
  ui.text(string.format("%d", math.floor(drift.total)), 0, y, 14 * s, colors.paint, "center", sw)
  ui.text("DRIFT SCORE", 0, y + 17 * s, 6 * s, colors.muted, "center", sw)
  if drift.combo > 1 then
    ui.text(string.format("+%d", math.floor(drift.combo)), 0, y + 27 * s, 8 * s, colors.marshal, "center", sw)
  end
end

local function drawDash(car, sw, sh, s, left)
  local model = car.model
  local spec = car.spec
  local w, h = DASH_W * s, DASH_H * s
  local x, y = dashX(sw, s, left), sh - h - 8 * s
  ui.panel(x, y, w, h, 0.8)

  -- Rev lights, the way a real wheel shows them
  local blocks = 16
  local bw = (w - 8 * s) / blocks
  local ratio = model.rpm / spec.redline
  for i = 1, blocks do
    local t = i / blocks
    local c = t < 0.62 and colors.sectorGreen or (t < 0.86 and colors.marshal or colors.kerb)
    local lit = ratio >= t - 0.02
    love.graphics.setColor(c[1], c[2], c[3], lit and 1 or 0.14)
    love.graphics.rectangle("fill", x + 4 * s + (i - 1) * bw, y + 4 * s, bw - s, 5 * s)
  end
  -- At the lights, a bar marks where the revs should be for the launch.
  if model.rev then
    local span = blocks * bw
    love.graphics.setColor(colors.paint)
    love.graphics.rectangle("fill", x + 4 * s + span * dynamics.LAUNCH_LOW, y + 10 * s,
      span * (dynamics.LAUNCH_HIGH - dynamics.LAUNCH_LOW), 2 * s)
  end

  local speed, unit = speedText(car)
  ui.text(tostring(speed), x, y + 14 * s, 16 * s, colors.paint, "right", w - 28 * s)
  ui.text(unit, x, y + 33 * s, 5 * s, colors.muted, "right", w - 28 * s)

  local gear = model.reverse and "R" or tostring(model.gear)
  local boxX = x + w - 24 * s
  love.graphics.setColor(colors.paint)
  love.graphics.rectangle("fill", boxX, y + 13 * s, 20 * s, 20 * s)
  ui.text(gear, boxX, y + 15 * s, 16 * s, colors.asphaltDeep, "center", 20 * s + 2)

  -- Boost gauge
  local fill, c = model.boostTank / spec.boostTime, colors.sectorGreen
  if model.boostState == "active" then
    c = colors.sectorPurple
  elseif model.boostFilling then
    c = colors.marshal
  elseif model.boostState == "cooldown" then
    c = colors.muted
  end
  local bx, by, bwidth = x + 4 * s, y + 36 * s, 56 * s
  love.graphics.setColor(1, 1, 1, 0.12)
  love.graphics.rectangle("fill", bx, by, bwidth, 4 * s)
  love.graphics.setColor(c)
  love.graphics.rectangle("fill", bx, by, bwidth * fill, 4 * s)

  -- Assist activity
  local tagY = y + 14 * s
  if model.tcActive > 0 then ui.text("TC", x + 4 * s, tagY, 5 * s, colors.marshal) end
  if model.absActive > 0 then ui.text("ABS", x + 4 * s, tagY + 7 * s, 5 * s, colors.marshal) end
  if model.escActive > 0.15 then ui.text("ESC", x + 4 * s, tagY + 14 * s, 5 * s, colors.marshal) end
end

-- Sits on top of the dash while the car is being towed.
local function drawSlipstream(car, sw, sh, s, left)
  local amount = car.model.slipstream
  if amount < 0.03 then return end
  local w, h = DASH_W * s, 12 * s
  local x, y = dashX(sw, s, left), sh - DASH_H * s - 8 * s - h - 2 * s
  local alpha = math.min(1, amount * 4)
  local panel = colors.asphaltDeep
  love.graphics.setColor(panel[1], panel[2], panel[3], 0.8 * alpha)
  love.graphics.rectangle("fill", x, y, w, h)
  local c = colors.marshal
  love.graphics.setColor(c[1], c[2], c[3], alpha)
  love.graphics.rectangle("fill", x + 4 * s, y + h - 3 * s, (w - 8 * s) * amount, 2 * s)
  ui.text("SLIPSTREAM", x + 4 * s, y + 2 * s, 5 * s, { c[1], c[2], c[3], alpha })
end

-- Five red lights, then lights out.
local function drawStartLights(race, sw, sh, s)
  if race.phase ~= "countdown" and not (race.time < 1.2 and race.phase == "racing") then return end
  local on = hud.lightsOn(race)
  local r, gap = 7 * s, 18 * s
  local total = gap * 5
  local x = (sw - total) / 2
  local y = sh * 0.2
  ui.panel(x, y - 12 * s, total, 24 * s, 0.9)
  for i = 1, 5 do
    local cx = x + gap * (i - 0.5)
    if race.phase == "racing" then
      love.graphics.setColor(colors.sectorGreen)
    elseif i <= on then
      love.graphics.setColor(colors.kerb)
    else
      love.graphics.setColor(0.2, 0.05, 0.06)
    end
    love.graphics.circle("fill", cx, y, r)
  end
  if race.phase == "countdown" then
    ui.panel((sw - 200 * s) / 2, y + 15 * s, 200 * s, 12 * s, 0.8)
    ui.text(race.holding and "WAITING FOR THE OTHER DRIVERS" or "HOLD THE REVS ON THE WHITE BAR",
      0, y + 18 * s, 6 * s, colors.paint, "center", sw)
  end
end

function hud.lightsOn(race)
  if race.phase ~= "countdown" then return 0 end
  return math.max(0, math.min(5, math.floor(race.timer / (race.startDelay / 6))))
end

local function drawPaceNote(view, sw, s)
  local pace = view.pace
  if not pace then return end
  local w, h = 58 * s, 26 * s
  local x, y = (sw - w) / 2, 8 * s
  ui.panel(x, y, w, h, 0.8)

  -- An arrow bending the way the corner goes, tighter for a slower corner.
  local c = pace.brake and colors.kerb or colors.marshal
  local d = pace.direction
  local bend = ({ 1.0, 0.72, 0.46, 0.24 })[pace.grade]
  local cx, cy = x + 14 * s, y + 18 * s
  local tipX = cx + d * 9 * s * bend
  local tipY = cy - 11 * s * (1 - bend * 0.35)
  love.graphics.setColor(c)
  love.graphics.setLineWidth(2.5 * s)
  love.graphics.setLineJoin("miter")
  love.graphics.line(cx, cy, cx, cy - 6 * s, tipX, tipY)
  local ax, ay = tipX - cx, tipY - (cy - 6 * s)
  local len = math.sqrt(ax * ax + ay * ay)
  ax, ay = ax / len, ay / len
  love.graphics.polygon("fill",
    tipX + ax * 4 * s, tipY + ay * 4 * s,
    tipX - ay * 3.5 * s, tipY + ax * 3.5 * s,
    tipX + ay * 3.5 * s, tipY - ax * 3.5 * s)

  ui.text(tostring(pace.grade), x + 27 * s, y + 5 * s, 8 * s, colors.paint)
  ui.text(pace.brake and "BRAKE" or "LIFT", x + 27 * s, y + 16 * s, 5 * s, c)
end

local function drawToast(view, sw, sh, s)
  local t = view.toast
  if not t or t.time <= 0 then return end
  local alpha = math.min(1, t.time * 3)
  local c = t.color or colors.paint
  local y = sh * 0.26
  local size = t.size or 8 * s
  local width = ui.font(size):getWidth(t.text) + 16 * s
  local panel = colors.asphaltDeep
  love.graphics.setColor(panel[1], panel[2], panel[3], 0.8 * alpha)
  love.graphics.rectangle("fill", (sw - width) / 2, y - 5 * s, width, size + 10 * s)
  ui.text(t.text, 0, y, size, { c[1], c[2], c[3], alpha }, "center", sw)
end

local ORDINALS = { "1ST", "2ND", "3RD", "4TH", "5TH", "6TH" }

-- "P2" is a seat online, so a place reads as a place.
function hud.finishHeading(place, timedOut)
  if timedOut then return "DID NOT FINISH", colors.kerb end
  if place == 1 then return "YOU WIN", colors.marshal end
  return "FINISHED " .. (ORDINALS[place] or place), colors.paint
end

-- The results' heading with two at a screen: whichever of them came home ahead.
function hud.splitHeading(players)
  local best
  for _, car in ipairs(players) do
    if not car.timedOut and (not best or car.place < best.place) then best = car end
  end
  if not best then return "DID NOT FINISH", colors.kerb end
  if best.place == 1 then return best.name .. " WINS", colors.marshal end
  return best.name .. " FINISHES AHEAD", colors.paint
end

-- Two rows of chequers across the width, drifting along like a waved flag.
local function drawChequers(x, y, width, size, drift)
  local c = colors.paint
  love.graphics.setColor(c[1], c[2], c[3], 1)
  local offset = drift % (size * 2)
  for row = 0, 1 do
    for column = -2, math.ceil(width / size) do
      if (column + row) % 2 == 0 then
        local left = math.max(x, x + column * size + offset)
        local right = math.min(x + width, x + (column + 1) * size + offset)
        if right > left then love.graphics.rectangle("fill", left, y + row * size, right - left, size) end
      end
    end
  end
end

-- A band of chequered flag sweeps in from both sides as the car crosses.
local function drawFinishBanner(car, clock, sw, sh, s)
  if clock >= hud.FINISH_HOLD then return end
  local enter = 1 - (1 - math.min(1, clock / BANNER_IN)) ^ 3
  local open = math.min((hud.FINISH_HOLD - clock) / BANNER_OUT, 1)
  local square = 5 * s
  local bandH = 44 * s
  local y = sh * 0.3 - bandH / 2
  local reach = sw * enter
  local bodyH = bandH * open
  local top = y + (bandH - bodyH) / 2

  -- A scissor is in screen space, and with two at a screen this half may sit to
  -- the right of the window's left edge inside a scissor of its own.
  local ox, oy = love.graphics.transformPoint(0, 0)
  local kx, ky, kw, kh = love.graphics.getScissor()
  love.graphics.intersectScissor(ox, oy + top - square * 2, sw, bodyH + square * 4)
  ui.panel(sw - reach, top - square * 2, reach, bodyH + square * 4, 0.9)
  drawChequers(0, top - square * 2, reach, square, clock * 40 * s)
  drawChequers(sw - reach, top + bodyH, reach, square, -clock * 40 * s)
  love.graphics.setScissor(kx, ky, kw, kh)

  local alpha = math.max(0, math.min(1, (clock - BANNER_IN * 0.5) / BANNER_IN)) * open
  local heading, c = hud.finishHeading(car.place, car.timedOut)
  ui.text(heading, 0, y + 6 * s, 20 * s, { c[1], c[2], c[3], alpha }, "center", sw)
  local m = colors.muted
  ui.text(hud.formatTime(car.finishTime), 0, y + 30 * s, 8 * s, { m[1], m[2], m[3], alpha }, "center", sw)
end

local function drawWrongWay(car, sw, sh, s)
  if not car.wrongWay then return end
  local pulse = math.sin(love.timer.getTime() * 8) > 0
  if pulse then ui.text("WRONG WAY", 0, sh * 0.34, 12 * s, colors.kerb, "center", sw) end
end

local function drawDriving(sw, sh, race, ctx, view, s)
  local car = view.car

  if race.mode == "race" then
    drawTower(race, s)
  elseif race.mode == "trial" then
    drawTrialPanel(race, ctx, s)
  else
    drawDrift(view, sw, s)
  end

  if settings.minimap and race.track then
    local size = 84 * s
    local x, y = 8 * s, sh - size - 16 * s
    -- The left thumb lives bottom left, so the map moves under the top buttons.
    if touch.shown() then x, y = sw - size - 16 * s, 46 * s end
    ui.panel(x, y, size + 8 * s, size + 8 * s, 0.55)
    minimap.draw(x + 4 * s, y + 4 * s, size, race.cars, car)
  end

  drawDash(car, sw, sh, s)
  drawSlipstream(car, sw, sh, s)
  drawPaceNote(view, sw, s)
  drawStartLights(race, sw, sh, s)
  drawToast(view, sw, sh, s)
  drawWrongWay(car, sw, sh, s)

  if not ctx.paused then touch.draw(sw, sh, car) end
end

-- ctx is the session, view the player's own part of it.
function hud.draw(sw, sh, race, ctx, view)
  local s = ui.scale(sw, sh)
  -- Past the line there's nothing left to drive, so the road gets the screen.
  if view.finishClock then
    drawFinishBanner(view.car, view.finishClock, sw, sh, s)
  else
    drawDriving(sw, sh, race, ctx, view, s)
  end

  if settings.showFps then
    local x = touch.shown() and sw - 158 * s or sw - 72 * s
    ui.text(love.timer.getFPS() .. " FPS", x, 8 * s, 6 * s, colors.muted, "right", 64 * s)
  end
end

-- Two at a screen ---------------------------------------------------------------

-- A half is half as wide, so the HUD comes down a size from the window's.
function hud.splitScale(sw, sh)
  return math.max(1, math.floor(ui.scale(sw, sh) * 0.75 * 2) / 2)
end

local function ordinal(place)
  return ORDINALS[place] or tostring(place)
end

-- Whose half this is, top outside corner: name, place, lap.
local function drawPlayerTag(race, view, sw, s)
  local car = view.car
  local w, h = 64 * s, race.mode == "race" and 30 * s or 14 * s
  local left = view.index == 1
  local x, y = left and 8 * s or sw - w - 8 * s, 8 * s
  ui.panel(x, y, w, h, 0.8)
  love.graphics.setColor(car.color)
  love.graphics.rectangle("fill", x + 2 * s, y + 2 * s, 2 * s, h - 4 * s)
  ui.text(car.name, x + 7 * s, y + 4 * s, 7 * s, colors.marshal)
  if race.mode == "race" then
    ui.text(ordinal(car.place), x, y + 4 * s, 7 * s, colors.paint, "right", w - 4 * s)
    ui.text("LAP " .. race:currentLap(car) .. "/" .. race.laps, x + 7 * s, y + 18 * s, 5 * s, colors.muted)
  end
end

-- After the banner a driver home first waits on the other, with their result up.
local function drawWaiting(race, view, sw, sh, s)
  local car = view.car
  local heading, c = hud.finishHeading(car.place, car.timedOut)
  if race.mode ~= "race" then heading, c = "FINISHED", colors.paint end
  local y = sh * 0.3
  ui.panel(0, y - 8 * s, sw, 40 * s, 0.75)
  ui.text(heading, 0, y, 12 * s, c, "center", sw)
  ui.text("WAITING FOR THE OTHER DRIVER", 0, y + 18 * s, 5 * s, colors.muted, "center", sw)
end

-- A small chip over each driver's car, so each can tell P1 from P2 at a glance,
-- in their own half and the other's. Faint, and drawn under the rest of the HUD.
local MARK_ALPHA = 0.75

local function drawMarks(view, s)
  for _, mark in ipairs(view.marks or {}) do
    local car = mark.car
    local size = 5 * s
    local w, h = ui.font(size):getWidth(car.name) + 7 * s, size + 4 * s
    local x, y = mark.x - w / 2, mark.y - mark.reach - h - 3 * s
    local panel = colors.asphaltDeep
    love.graphics.setColor(panel[1], panel[2], panel[3], 0.6 * MARK_ALPHA)
    love.graphics.rectangle("fill", x, y, w, h)
    local paint = car.color
    love.graphics.setColor(paint[1], paint[2], paint[3], MARK_ALPHA)
    love.graphics.rectangle("fill", x + s, y + s, 2 * s, h - 2 * s)
    local c = colors.paint
    ui.text(car.name, x + 4.5 * s, y + 2 * s, size, { c[1], c[2], c[3], MARK_ALPHA })
  end
end

-- One driver's half, drawn at 0, 0 in its own space. fullW, fullH are the
-- window's, which set the scale.
function hud.drawView(sw, sh, race, ctx, view, fullW, fullH)
  local s = hud.splitScale(fullW, fullH)
  local car = view.car
  if view.finishClock then
    if view.finishClock < hud.FINISH_HOLD then
      drawFinishBanner(car, view.finishClock, sw, sh, s)
    elseif not ctx.finishClock then
      drawWaiting(race, view, sw, sh, s)
    end
    return
  end
  local left = view.index == 1
  drawMarks(view, s)
  drawPlayerTag(race, view, sw, s)
  if race.mode == "freestyle" then drawDrift(view, sw, s) end
  drawDash(car, sw, sh, s, left)
  drawSlipstream(car, sw, sh, s, left)
  -- The drift score has the top middle in freestyle.
  if race.mode ~= "freestyle" then drawPaceNote(view, sw, s) end
  drawStartLights(race, sw, sh, s)
  drawToast(view, sw, sh, s)
  drawWrongWay(car, sw, sh, s)
end

-- What both drivers share, over the seam: the line between the halves, the
-- timing tower and the map.
function hud.drawShared(sw, sh, race, ctx)
  local s = hud.splitScale(sw, sh)
  local mid = math.floor(sw / 2)
  love.graphics.setColor(colors.asphaltDeep)
  love.graphics.rectangle("fill", mid - s, 0, 2 * s, sh)

  local results = ctx.finishClock and ctx.finishClock >= hud.FINISH_HOLD
  if race.mode == "race" and not results then
    -- The lap counter follows whichever of the two is ahead.
    local focus = race.player
    for _, car in ipairs(race.players) do
      if car.place < focus.place then focus = car end
    end
    drawTower(race, s, mid - hud.TOWER_W * s / 2, 8 * s, focus)
  end

  if settings.minimap and race.track and not results then
    local size = 84 * s
    local x, y = mid - (size + 8 * s) / 2, sh - size - 16 * s
    ui.panel(x, y, size + 8 * s, size + 8 * s, 0.55)
    minimap.draw(x + 4 * s, y + 4 * s, size, race.cars, race.players)
  end

  if settings.showFps then
    ui.text(love.timer.getFPS() .. " FPS", mid - 32 * s, sh - 10 * s, 5 * s, colors.muted, "center", 64 * s)
  end
end

return hud
