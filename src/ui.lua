-- Immediate-mode UI: one list widget that works the same with mouse,
-- keyboard and gamepad, plus text and shape helpers.
local colors = require("src/colors")

local ui = {
  mx = 0, my = 0,
  clicked = false,
  nav = {},
  focus = {},
  editing = nil,
  fonts = {},
  usingMouse = false,
}

local FONT = "assets/fonts/PressStart2P.ttf"

-- Layout unit: 1 at 640x360, 2 at 1280x720.
function ui.scale(sw, sh)
  sw, sh = sw or love.graphics.getWidth(), sh or love.graphics.getHeight()
  return math.max(1, math.floor(math.min(sw / 640, sh / 360) * 2 + 0.25) / 2)
end

function ui.font(size)
  size = math.max(6, math.floor(size + 0.5))
  local font = ui.fonts[size]
  if not font then
    font = love.graphics.newFont(FONT, size)
    font:setFilter("nearest", "nearest")
    font:setLineHeight(1.5)
    ui.fonts[size] = font
  end
  return font
end

function ui.text(str, x, y, size, color, align, width)
  love.graphics.setFont(ui.font(size))
  love.graphics.setColor(color or colors.paint)
  if align then
    love.graphics.printf(str, math.floor(x), math.floor(y), width, align)
  else
    love.graphics.print(str, math.floor(x), math.floor(y))
  end
end

-- Input --------------------------------------------------------------------

function ui.mousepressed(x, y, button)
  ui.mx, ui.my = x, y
  if button == 1 then ui.clicked = true end
end

function ui.mousemoved(x, y)
  ui.mx, ui.my = x, y
  ui.usingMouse = true
end

local NAV_KEYS = {
  up = "up", down = "down", left = "left", right = "right",
  w = "up", s = "down", a = "left", d = "right",
  ["return"] = "ok", kpenter = "ok", space = "ok",
  escape = "back", backspace = "back",
}

local PAD_NAV = {
  dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
  a = "ok", b = "back", start = "ok",
}

function ui.keypressed(key)
  if ui.editing then
    if key == "return" or key == "kpenter" then
      local e = ui.editing
      ui.editing = nil
      e.done(e.value)
    elseif key == "escape" then
      ui.editing = nil
    elseif key == "backspace" then
      ui.editing.value = ui.editing.value:sub(1, -2)
    end
    return
  end
  local nav = NAV_KEYS[key]
  if nav then
    ui.nav[nav] = true
    ui.usingMouse = false
  end
end

function ui.gamepadpressed(button)
  local nav = PAD_NAV[button]
  if nav then
    ui.nav[nav] = true
    ui.usingMouse = false
  end
end

function ui.textinput(t)
  local e = ui.editing
  if e and #e.value < (e.max or 24) and t:match(e.pattern or "^[%w_%.:%- ]$") then
    e.value = e.value .. t
  end
end

function ui.startEditing(value, done, pattern, maxLength)
  ui.editing = { value = value, done = done, pattern = pattern, max = maxLength }
end

-- Clicks and key presses live for one frame only, so changing screen can't
-- carry a press through to whatever appears underneath.
function ui.endFrame()
  ui.clicked = false
  ui.nav = {}
end

function ui.consumeBack()
  local back = ui.nav.back
  ui.nav.back = nil
  return back
end

local function inside(x, y, w, h)
  return ui.mx >= x and ui.mx < x + w and ui.my >= y and ui.my < y + h
end
ui.inside = inside

-- Drawing helpers ----------------------------------------------------------

-- The kerb stripe marks whatever is selected.
function ui.kerb(x, y, w, h, s)
  local band = 6 * s
  local columns = math.ceil(w / band)
  love.graphics.setScissor(x, y, w, h)
  for i = 0, columns do
    local c = i % 2 == 0 and colors.kerb or colors.paint
    love.graphics.setColor(c)
    local bx = x + i * band
    love.graphics.polygon("fill", bx, y + h, bx + band, y + h, bx + band + h * 0.5, y, bx + h * 0.5, y)
  end
  love.graphics.setScissor()
end

function ui.panel(x, y, w, h, alpha)
  local c = colors.asphaltDeep
  love.graphics.setColor(c[1], c[2], c[3], alpha or 0.88)
  love.graphics.rectangle("fill", x, y, w, h)
end

-- List widget ---------------------------------------------------------------
-- items: { label =, value = string|nil, activate = fn, left = fn, right = fn,
--          disabled = bool, hint = string }
-- Returns the focused item so a screen can show context for it.
function ui.list(id, items, x, y, w, rowH, size, s)
  local focus = ui.focus[id] or 1
  local count = #items
  focus = math.max(1, math.min(count, focus))

  local function step(direction)
    for _ = 1, count do
      focus = (focus - 1 + direction) % count + 1
      if not items[focus].disabled then break end
    end
  end
  if ui.nav.up then step(-1) ui.played = "click" end
  if ui.nav.down then step(1) ui.played = "click" end
  if items[focus].disabled then step(1) end

  for i, item in ipairs(items) do
    local ry = y + (i - 1) * rowH
    local hovered = ui.usingMouse and inside(x, ry, w, rowH) and not item.disabled
    if hovered then
      if focus ~= i then ui.played = "click" end
      focus = i
    end
    local selected = i == focus
    local labelColor = item.disabled and colors.muted or (selected and colors.marshal or colors.paint)

    if selected then
      ui.kerb(x, ry + rowH * 0.5 - 2.5 * s, 8 * s, 5 * s, s)
    end
    local textX = x + 14 * s
    local textY = ry + (rowH - size) / 2
    ui.text(item.label, textX, textY, size, labelColor)

    local value = item.value
    if value then
      if type(value) == "function" then value = value() end
      local arrows = (item.left or item.right) and selected
      local shown = arrows and ("< " .. value .. " >") or value
      ui.text(shown, x, textY, size, selected and colors.paint or colors.muted, "right", w)
    end

    if selected and ui.clicked and hovered and not item.disabled then
      if item.left and ui.mx < x + w * 0.62 then
        item.left()
        ui.played = "select"
      elseif item.right then
        item.right()
        ui.played = "select"
      elseif item.activate then
        item.activate()
        ui.played = "select"
      end
      ui.clicked = false
    end
  end

  local current = items[focus]
  if not current.disabled then
    if ui.nav.left and current.left then current.left() ui.played = "click" end
    if ui.nav.right and current.right then current.right() ui.played = "click" end
    if ui.nav.ok and current.activate then
      ui.nav.ok = nil
      current.activate()
      ui.played = "select"
    end
  end
  ui.focus[id] = focus
  return current
end

return ui
