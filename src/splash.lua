local ui = require("src/ui")
local colors = require("src/colors")
local audio = require("src/audio")

local splash = { timer = 0, length = audio.STARTUP_LENGTH }

function splash.update(dt)
  if splash.timer == 0 then audio.play("startup", 0.8) end
  splash.timer = splash.timer + dt
  return splash.timer >= splash.length
end

function splash.draw(sw, sh, loading)
  local s = ui.scale(sw, sh)
  love.graphics.clear(colors.asphaltDeep)
  -- The title goes up while the game loads, so it only ever fades out.
  local fade = math.min(1, (splash.length - splash.timer) * 4)
  local c = colors.marshal
  ui.text("SPPPD", 0, sh / 2 - 28 * s, 28 * s, { c[1], c[2], c[3], fade }, "center", sw)
  if loading then
    ui.text("LOADING", 0, sh / 2 + 12 * s, 7 * s, c, "center", sw)
    return
  end
  local w = 120 * s * math.min(1, splash.timer / audio.STARTUP_PEAK)
  ui.kerb(sw / 2 - w / 2, sh / 2 + 12 * s, w, 5 * s, s)
end

return splash
