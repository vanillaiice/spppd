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
  mobile = love._os == "Android" or love._os == "iOS",
}

local FONT = "assets/fonts/PressStart2P.ttf"

-- Layout unit: 1 at 640x360, 2 at 1280x720. A phone's screen is physically
-- small for its resolution, so everything goes up a size to read and tap.
function ui.scale(sw, sh)
  sw, sh = sw or love.graphics.getWidth(), sh or love.graphics.getHeight()
  local fit = math.min(sw / 640, sh / 360) * (ui.mobile and 1.5 or 1)
  return math.max(1, math.floor(fit * 2 + 0.25) / 2)
end

-- The part of the screen clear of a camera notch or rounded corners, as x, y, w,
-- h. The race and menu backdrops still fill the screen; what's read or pressed
-- sits in here. SPPPD_SAFE=left,top,right,bottom fakes a notch on a desktop.
function ui.safeArea(sw, sh)
  local fake = os.getenv("SPPPD_SAFE")
  if fake then
    local l, t, r, b = fake:match("^(%d+),(%d+),(%d+),(%d+)$")
    if l then return tonumber(l), tonumber(t), sw - l - r, sh - t - b end
  end
  if ui.mobile and love.window and love.window.getSafeArea then
    local ok, x, y, w, h = pcall(love.window.getSafeArea)
    if ok and w and w > sw * 0.5 and h > sh * 0.5 then
      return math.floor(x), math.floor(y), math.floor(math.min(w, sw - x)), math.floor(math.min(h, sh - y))
    end
  end
  return 0, 0, sw, sh
end

-- Draws fn(w, h) inside the safe area, with the origin at its corner.
function ui.inSafeArea(sw, sh, fn)
  local x, y, w, h = ui.safeArea(sw, sh)
  love.graphics.push()
  love.graphics.translate(x, y)
  fn(w, h)
  love.graphics.pop()
end

-- A clip in the current drawing's own coordinates, kept inside any clip already set.
-- Returns what to hand back to love.graphics.setScissor afterwards.
function ui.clip(x, y, w, h)
  local before = { love.graphics.getScissor() }
  local sx, sy = love.graphics.transformPoint(x, y)
  love.graphics.intersectScissor(sx, sy, w, h)
  return before
end

function ui.unclip(before)
  love.graphics.setScissor(unpack(before))
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
  -- A tap arrives with no movement before it.
  ui.usingMouse = true
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

local function stopEditing()
  ui.editing = nil
  if love.keyboard.hasScreenKeyboard() then love.keyboard.setTextInput(false) end
end

function ui.keypressed(key)
  if ui.editing then
    if key == "return" or key == "kpenter" then
      local e = ui.editing
      stopEditing()
      e.done(e.value)
    elseif key == "escape" then
      stopEditing()
    elseif key == "backspace" then
      ui.editing.value = ui.editing.value:sub(1, -2)
    elseif key == "v" and love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui") then
      ui.textinput(love.system.getClipboardText() or "")
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

-- Text arrives a letter at a time when typed, or all at once when pasted: a
-- phone's keyboard pastes this way, and so does ctrl+V. Letters the field doesn't
-- take are dropped, so a pasted code can carry spaces and line breaks.
function ui.textinput(t)
  local e = ui.editing
  if not e then return end
  for c in t:gmatch(".") do
    if #e.value >= (e.max or 24) then break end
    if c:match(e.pattern or "^[%w_%.:%- ]$") then e.value = e.value .. c end
  end
end

function ui.startEditing(value, done, pattern, maxLength)
  ui.editing = { value = value, done = done, pattern = pattern, max = maxLength }
  if love.keyboard.hasScreenKeyboard() then love.keyboard.setTextInput(true) end
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

-- The pointer in the coordinates being drawn in, which differ from the screen's
-- inside the safe area.
local function pointer()
  return love.graphics.inverseTransformPoint(ui.mx, ui.my)
end

local function inside(x, y, w, h)
  local mx, my = pointer()
  return mx >= x and mx < x + w and my >= y and my < y + h
end

-- Drawing helpers ----------------------------------------------------------

-- The kerb stripe marks whatever is selected.
function ui.kerb(x, y, w, h, s)
  local band = 6 * s
  local columns = math.ceil(w / band)
  local before = ui.clip(x, y, w, h)
  for i = 0, columns do
    local c = i % 2 == 0 and colors.kerb or colors.paint
    love.graphics.setColor(c)
    local bx = x + i * band
    love.graphics.polygon("fill", bx, y + h, bx + band, y + h, bx + band + h * 0.5, y, bx + h * 0.5, y)
  end
  ui.unclip(before)
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
      if item.left and pointer() < x + w * 0.62 then
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
