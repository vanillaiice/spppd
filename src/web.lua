-- The browser build (love.js). Two things the page has to do for the game, through
-- web/bridge.js, which reads lines the game prints that start with PREFIX:
--
-- * The game can't see the browser window, so the page writes its size into the
--   save folder as viewport.txt, and the window follows it here. Everything else
--   reads love.graphics.getDimensions each frame, so nothing more is needed after
--   a resize. A phone's browser gets touch controls and big menus.
-- * love.js keeps the save folder in IndexedDB but only copies it there as the page
--   closes, which a phone often never says it's doing. So every write here asks the
--   page to copy it now, once the writes have stopped for a moment.
local ui = require("src.ui")
local touch = require("src.touch")

local web = {
  on = love.system ~= nil and love.system.getOS() == "Web",
}

local PREFIX = "SPPPD_WEB|"
local SYNC_DELAY = 1  -- seconds of quiet after a write
local check, size = 0, nil
local syncIn = nil

local function ask(what)
  print(PREFIX .. love.filesystem.getSaveDirectory() .. "|" .. what)
end

if web.on then
  local write, remove, append = love.filesystem.write, love.filesystem.remove, love.filesystem.append
  local function later() syncIn = SYNC_DELAY end
  -- viewport.txt is the page's own and changes on every resize; it needs no saving.
  love.filesystem.write = function(name, ...)
    if name ~= "viewport.txt" then later() end
    return write(name, ...)
  end
  love.filesystem.remove = function(...) later() return remove(...) end
  love.filesystem.append = function(...) later() return append(...) end
end

function web.update(dt)
  if not web.on then return end
  if syncIn then
    syncIn = syncIn - dt
    if syncIn <= 0 then
      syncIn = nil
      ask("sync")
    end
  end
  check = check - dt
  if check > 0 then return end
  check = 0.5
  -- love.js raises on a missing file instead of returning nil. The first answer
  -- can land before the save folder exists, so ask again until a size arrives.
  if not love.filesystem.getInfo("viewport.txt") then
    if not size then
      love.filesystem.createDirectory("web")
      ask("hello")
      check = 2
    end
    return
  end
  local ok, text = pcall(love.filesystem.read, "viewport.txt")
  if not ok or not text or text == size then return end
  local w, h, phone = text:match("^(%d+) (%d+) ?(%d?)")
  w, h = tonumber(w), tonumber(h)
  if not w or w < 100 or h < 100 then return end
  size = text
  if phone == "1" and not ui.mobile then
    ui.mobile = true
    touch.active = true
  end
  local cw, ch = love.graphics.getDimensions()
  if cw ~= w or ch ~= h then
    love.window.setMode(w, h, { resizable = true, vsync = 1, msaa = 0 })
  end
end

return web
