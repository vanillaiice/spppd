-- Immediate-mode UI: one list widget that works the same with mouse,
-- keyboard and gamepad, plus text and shape helpers.
local colors = require("src.colors")

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

-- A button fires when the finger lifts, not when it lands, and only if it lifts on
-- the button it landed on, so sliding off cancels the tap. ui.press is where it
-- landed; the list drawn that frame claims it for whatever row is under it.
-- ui.clicked means "lifted this frame".
function ui.mousepressed(x, y, button)
  ui.mx, ui.my = x, y
  -- A tap arrives with no movement before it.
  ui.usingMouse = true
  if button == 1 then
    ui.press = { x = x, y = y, fresh = true }
    ui.down = true
  end
end

function ui.mousereleased(x, y, button)
  if button ~= 1 then return end
  ui.mx, ui.my = x, y
  ui.down = false
  ui.clicked = true
end

-- Whatever the finger is on can no longer fire: the screen changed under it.
function ui.cancelPress()
  ui.press = nil
end

-- The mouse wheel, for a long list. Turned into scrolling by the list drawn next.
function ui.wheelmoved(_, y)
  ui.wheel = (ui.wheel or 0) + y
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
  return ui.editing
end

-- Takes what's typed so far, as Enter would.
function ui.commitEditing()
  local e = ui.editing
  if not e then return end
  stopEditing()
  e.done(e.value)
end

-- Clicks and key presses live for one frame only, so changing screen can't
-- carry a press through to whatever appears underneath.
function ui.endFrame()
  ui.clicked = false
  ui.nav = {}
  ui.wheel = 0
  -- Only the frame a press lands in can claim it, so a list that turns up under
  -- a finger already down (the pause menu after II) doesn't fire when it lifts.
  if ui.press then
    ui.press.fresh = false
    if not ui.down then ui.press = nil end
  end
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

local function within(px, py, x, y, w, h)
  local mx, my = love.graphics.inverseTransformPoint(px, py)
  return mx >= x and mx < x + w and my >= y and my < y + h
end

local function inside(x, y, w, h)
  return within(ui.mx, ui.my, x, y, w, h)
end

-- Whether the press is on this part of this list. A press that's new this frame
-- is claimed by the first part drawn under it.
local function claims(id, item, part, x, y, w, h)
  local p = ui.press
  if not p then return false end
  if p.fresh and not p.claim and within(p.x, p.y, x, y, w, h) then
    p.claim = { list = id, item = item, part = part }
    ui.played = "click"
  end
  local c = p.claim
  return c ~= nil and c.list == id and c.item == item and c.part == part
end

-- A claimed part looks held while the finger is still on it, and fires if it
-- lifts there.
local function pressState(id, item, part, x, y, w, h)
  if not claims(id, item, part, x, y, w, h) then return false, false end
  local on = inside(x, y, w, h)
  return on and ui.down, on and ui.clicked
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

-- What a finger is holding down: lit until it lifts or slides off.
local function heldBar(x, y, w, h)
  love.graphics.setColor(colors.marshal)
  love.graphics.rectangle("fill", x, y, w, h)
end

-- A phone's < or > on a row with choices.
-- onBar: the row it's on is held, so it's drawn dark on the lit bar.
local function arrowBox(glyph, x, y, w, h, size, s, held, bright, onBar)
  local inset = 3 * s
  local bx, by, bw, bh = x + inset, y + inset, w - 2 * inset, h - 2 * inset
  local c = onBar and colors.asphaltDeep or (bright and colors.paint or colors.muted)
  if held then
    love.graphics.setColor(colors.marshal)
    love.graphics.rectangle("fill", bx, by, bw, bh)
    c = colors.asphaltDeep
  else
    love.graphics.setColor(c)
    love.graphics.setLineWidth(math.max(1, s))
    love.graphics.rectangle("line", bx, by, bw, bh)
  end
  ui.text(glyph, x, y + (h - size) / 2, size, c, "center", w)
end

function ui.panel(x, y, w, h, alpha)
  local c = colors.asphaltDeep
  love.graphics.setColor(c[1], c[2], c[3], alpha or 0.88)
  love.graphics.rectangle("fill", x, y, w, h)
end

-- List widget ---------------------------------------------------------------

-- On a phone, a row with choices has a < and a > to tap, each box wide. The <
-- stands in one column for the whole list, clear of the widest value, so it
-- doesn't jump about. Returns that column (nil without such rows) and each row's
-- value as shown.
function ui.arrowColumn(items, first, last, x, w, box, size, s)
  local values, leftX = {}, nil
  local font = ui.font(size)
  for i = first, last do
    local value = items[i].value
    if type(value) == "function" then value = value() end
    values[i] = value
    if ui.mobile and value and (items[i].left or items[i].right) then
      local at = x + w - 2 * box - font:getWidth(value) - 8 * s
      leftX = math.min(leftX or at, at)
    end
  end
  return leftX, values
end
-- items: { label =, value = string|nil, activate = fn, left = fn, right = fn,
--          disabled = bool, hint = string }
-- Returns the focused item so a screen can show context for it.
-- maxRows, if given, is as many rows as there's room for. A longer list scrolls:
-- with the focus, with the wheel, and with a MORE row at either end to tap.
ui.scroll = {}

-- The first and last items shown when the list starts at first, and whether a
-- MORE row stands above or below them.
local function window(first, count, slots)
  first = math.max(1, math.min(count, first))
  local above = first > 1
  local room = slots - (above and 1 or 0)
  local below = first + room - 1 < count
  if below then room = room - 1 end
  return first, math.min(count, first + room - 1), above, below, room
end

function ui.list(id, items, x, y, w, rowH, size, s, maxRows)
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

  -- Which rows show, and the MORE rows around them.
  local first, last, above, below, room = 1, count, false, false, count
  local scrolls = maxRows and maxRows >= 3 and count > maxRows
  -- items.pinLast keeps the last item in the bottom slot on every page, so a
  -- screen's main action is always in reach. The rest page above it.
  local pinned = scrolls and items.pinLast and maxRows >= 4
  local paged = pinned and count - 1 or count
  local slots = pinned and maxRows - 1 or maxRows
  if scrolls then
    first = ui.scroll[id] or 1
    if ui.wheel and ui.wheel ~= 0 then
      first = first - ui.wheel
      ui.wheel = 0
    end
    first, last, above, below, room = window(first, paged, slots)
    -- A tap on a MORE row turns a page.
    -- Only a MORE row that's there can take the press, or row 1 would lose it.
    local up = above and select(2, pressState(id, "more", "up", x, y, w, rowH))
    local down = below and select(2, pressState(id, "more", "down", x, y + (slots - 1) * rowH, w, rowH))
    if up then
      first, ui.clicked, ui.played = first - room, false, "click"
    elseif down then
      first, ui.clicked, ui.played = first + room, false, "click"
    end
    -- The furthest it goes still fills the window.
    first = math.min(first, paged - slots + 2)
    first, last, above, below, room = window(first, paged, slots)
    if not ui.usingMouse and focus <= paged then
      -- The keys and the pad move the focus, and the window follows it.
      if focus < first then first = focus end
      first, last, above, below, room = window(first, paged, slots)
      if focus > last then
        first, last, above, below, room = window(focus - room + 1, paged, slots)
        if focus > last then first, last, above, below, room = window(first + 1, paged, slots) end
      end
    end
    ui.scroll[id] = first
    for slot, more in pairs({ [0] = above, [slots - 1] = below }) do
      if more then
        local ry = y + slot * rowH
        local held = pressState(id, "more", slot == 0 and "up" or "down", x, ry, w, rowH)
        local hovered = ui.usingMouse and inside(x, ry, w, rowH)
        if held then heldBar(x, ry, w, rowH) end
        ui.text("- MORE -", x + 14 * s, ry + (rowH - size) / 2, size,
          held and colors.asphaltDeep or (hovered and colors.marshal or colors.muted))
      end
    end
  end
  local offset = above and 1 or 0

  local box = rowH
  local leftX, values = ui.arrowColumn(items, first, last, x, w, box, size, s)

  local shown = {}
  for i = first, last do shown[#shown + 1] = { i, y + (i - first + offset) * rowH } end
  if pinned then shown[#shown + 1] = { count, y + (maxRows - 1) * rowH } end

  for _, at in ipairs(shown) do
    local i, ry = at[1], at[2]
    local item = items[i]
    local hovered = ui.usingMouse and inside(x, ry, w, rowH) and not item.disabled
    if hovered then
      if focus ~= i then ui.played = "click" end
      focus = i
    end
    local selected = i == focus
    local boxes = ui.mobile and leftX and values[i] and (item.left or item.right)

    -- The arrows are claimed before the row they sit in.
    local heldLeft, fireLeft, heldRight, fireRight, held, fire = false, false, false, false, false, false
    if not item.disabled then
      if boxes then
        heldLeft, fireLeft = pressState(id, i, "left", leftX, ry, box, rowH)
        heldRight, fireRight = pressState(id, i, "right", x + w - box, ry, box, rowH)
      end
      held, fire = pressState(id, i, "row", x, ry, w, rowH)
    end

    if held then heldBar(x, ry, w, rowH) end
    local labelColor = item.disabled and colors.muted or (selected and colors.marshal or colors.paint)
    if held then labelColor = colors.asphaltDeep end

    if selected then
      ui.kerb(x, ry + rowH * 0.5 - 2.5 * s, 8 * s, 5 * s, s)
    end
    local textX = x + 14 * s
    local textY = ry + (rowH - size) / 2
    ui.text(item.label, textX, textY, size, labelColor)

    local value = values[i]
    if value then
      local valueColor = held and colors.asphaltDeep or (selected and colors.paint or colors.muted)
      if boxes then
        arrowBox("<", leftX, ry, box, rowH, size, s, heldLeft, selected, held)
        arrowBox(">", x + w - box, ry, box, rowH, size, s, heldRight, selected, held)
        ui.text(value, leftX + box, textY, size, valueColor, "center", x + w - leftX - 2 * box)
      else
        local arrows = (item.left or item.right) and selected
        local shown = arrows and ("< " .. value .. " >") or value
        ui.text(shown, x, textY, size, valueColor, "right", w)
      end
    end

    local run
    if fireLeft then
      run = item.left
    elseif fireRight then
      run = item.right
    elseif fire then
      if boxes then
        -- The rest of the row steps on, as > does.
        run = item.right or item.left
      elseif item.left and pointer() < x + w * 0.62 then
        run = item.left
      else
        run = item.right or item.activate
      end
    end
    if run then
      focus = i
      run()
      ui.played = "select"
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
