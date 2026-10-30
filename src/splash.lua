local ui = require("src/ui")
local colors = require("src/colors")

local splash = { timer = 0, length = 1.6 }

function splash.update(dt)
  splash.timer = splash.timer + dt
  return splash.timer >= splash.length
end

function splash.draw(sw, sh)
  local s = ui.scale(sw, sh)
  love.graphics.clear(colors.asphaltDeep)
  local fade = math.min(1, splash.timer * 3) * math.min(1, (splash.length - splash.timer) * 4)
  local c = colors.marshal
  ui.text("SPPPD", 0, sh / 2 - 28 * s, 28 * s, { c[1], c[2], c[3], fade }, "center", sw)
  local w = 120 * s * math.min(1, splash.timer / 1.1)
  ui.kerb(sw / 2 - w / 2, sh / 2 + 12 * s, w, 5 * s, s)
end

return splash
