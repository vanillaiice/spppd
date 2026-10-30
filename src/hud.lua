-- Race HUD, laid out like a broadcast timing screen: the tower top left,
-- the dash bottom right, and everything else out of the way of the road.
local ui = require("src/ui")
local colors = require("src/colors")
local settings = require("src/settings")
local minimap = require("src/minimap")

local hud = {}

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

local function drawTower(race, s)
  local order = race:standings()
  local x, y = 8 * s, 8 * s
  local rowH, size = 11 * s, 6 * s
  local w = 118 * s
  ui.panel(x, y, w, rowH * (#order + 1), 0.8)
  local lap = race:currentLap(race.player)
  ui.text("LAP " .. lap .. "/" .. race.laps, x + 4 * s, y + 3 * s, size, colors.marshal)
  ui.text(hud.formatTime(race.time - race.player.lapStart):sub(1, 7), x, y + 3 * s, size, colors.paint, "right", w - 4 * s)
  y = y + rowH

  local leader = order[1]
  for i, car in ipairs(order) do
    local ry = y + (i - 1) * rowH
    if car == race.player then
      love.graphics.setColor(colors.marshal[1], colors.marshal[2], colors.marshal[3], 0.2)
      love.graphics.rectangle("fill", x, ry, w, rowH)
    end
    love.graphics.setColor(car.color)
    love.graphics.rectangle("fill", x + 2 * s, ry + 2 * s, 2 * s, rowH - 4 * s)
    local gap
    if car == leader then
      gap = "LEAD"
    elseif car.finished and car.finishTime and leader.finishTime then
      gap = string.format("+%.1f", car.finishTime - leader.finishTime)
    else
      -- Convert the distance gap into seconds at the follower's pace.
      local behind = leader.distance - car.distance
      local pace = math.max(12, car:getSpeed() * 12)
      gap = string.format("+%.1f", behind / pace)
    end
    ui.text(i .. " " .. car.name, x + 7 * s, ry + 3 * s, size, car == race.player and colors.marshal or colors.paint)
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
  ui.text(hud.formatTime(ctx.bestLap), x, y + rowH * 2 + 3 * s, size, colors.sectorPurple, "right", w - 4 * s)
end

local function drawDrift(ctx, sw, s)
  local drift = ctx.drift
  if not drift then return end
  local y = 8 * s
  ui.text(string.format("%d", math.floor(drift.total)), 0, y, 14 * s, colors.paint, "center", sw)
  ui.text("DRIFT SCORE", 0, y + 17 * s, 6 * s, colors.muted, "center", sw)
  if drift.combo > 1 then
    ui.text(string.format("+%d", math.floor(drift.combo)), 0, y + 27 * s, 8 * s, colors.marshal, "center", sw)
  end
end

local function drawDash(car, sw, sh, s)
  local model = car.model
  local spec = car.spec
  local w, h = 112 * s, 44 * s
  local x, y = sw - w - 8 * s, sh - h - 8 * s
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

  local speed, unit = speedText(car)
  ui.text(tostring(speed), x, y + 14 * s, 16 * s, colors.paint, "right", w - 28 * s)
  ui.text(unit, x, y + 33 * s, 5 * s, colors.muted, "right", w - 28 * s)

  local gear = model.reverse and "R" or tostring(model.gear)
  local boxX = x + w - 24 * s
  love.graphics.setColor(colors.paint)
  love.graphics.rectangle("fill", boxX, y + 13 * s, 20 * s, 20 * s)
  ui.text(gear, boxX, y + 15 * s, 16 * s, colors.asphaltDeep, "center", 20 * s + 2)

  -- Nitro gauge
  local fill, c = 1, colors.sectorGreen
  if model.boostState == "active" then
    fill, c = model.boostTimer / spec.boostTime, colors.sectorPurple
  elseif model.boostState == "cooldown" then
    fill, c = 1 - model.boostCooldown / spec.boostCooldown, colors.muted
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
local function drawSlipstream(car, sw, sh, s)
  local amount = car.model.slipstream
  if amount < 0.03 then return end
  local w, h = 112 * s, 12 * s
  local x, y = sw - w - 8 * s, sh - 44 * s - 8 * s - h - 2 * s
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
end

function hud.lightsOn(race)
  if race.phase ~= "countdown" then return 0 end
  return math.min(5, math.floor(race.timer / (race.startDelay / 6)))
end

local function drawPaceNote(ctx, sw, s)
  local pace = ctx.pace
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

local function drawToast(ctx, sw, sh, s)
  local t = ctx.toast
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

function hud.draw(sw, sh, race, ctx)
  local s = ui.scale(sw, sh)
  local car = race.player

  if race.mode == "race" then
    drawTower(race, s)
  elseif race.mode == "trial" then
    drawTrialPanel(race, ctx, s)
  else
    drawDrift(ctx, sw, s)
  end

  if settings.minimap and race.track then
    local size = 84 * s
    ui.panel(8 * s, sh - size - 16 * s, size + 8 * s, size + 8 * s, 0.55)
    minimap.draw(12 * s, sh - size - 12 * s, size, race.cars, car)
  end

  drawDash(car, sw, sh, s)
  drawSlipstream(car, sw, sh, s)
  drawPaceNote(ctx, sw, s)
  drawStartLights(race, sw, sh, s)
  drawToast(ctx, sw, sh, s)

  if car.wrongWay then
    local pulse = math.sin(love.timer.getTime() * 8) > 0
    if pulse then ui.text("WRONG WAY", 0, sh * 0.34, 12 * s, colors.kerb, "center", sw) end
  end

  if settings.showFps then
    ui.text(love.timer.getFPS() .. " FPS", sw - 72 * s, 8 * s, 6 * s, colors.muted, "right", 64 * s)
  end
end

return hud
