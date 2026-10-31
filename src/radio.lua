-- The player's own music, for freestyle only: one station playing whatever is
-- in the music folder of the save directory, shuffled and non-stop. Songs are
-- streamed from disk, because a whole album won't fit in memory decoded.
local settings = require("src/settings")

local radio = { tracks = {} }

local DIR = "music"
local TITLE_MAX = 30
local FORMATS = { mp3 = true, ogg = true, oga = true, flac = true, wav = true }

local source         -- the song playing, if any
local current        -- its file name
local on, paused = false, false
local queue = {}     -- file names still to play this time round
local announce       -- title of a song that hasn't been shown yet

function radio.isTrack(name)
  local extension = name:match("%.([^%.]+)$")
  return extension ~= nil and FORMATS[extension:lower()] == true
end

-- The font has no use for anything past ASCII, and printing a filename that
-- isn't valid UTF-8 raises an error.
function radio.title(name)
  local title = name:gsub("%.[^%.]+$", ""):gsub("_", " "):gsub("[\128-\255]+", "?")
  if #title > TITLE_MAX then title = title:sub(1, TITLE_MAX - 3) .. "..." end
  return title
end

-- A new order, which doesn't open on `last` unless there's nothing else to play.
function radio.shuffle(names, last)
  local order = {}
  for i, name in ipairs(names) do order[i] = name end
  for i = #order, 2, -1 do
    local j = love.math.random(1, i)
    order[i], order[j] = order[j], order[i]
  end
  if #order > 1 and order[1] == last then
    local swap = love.math.random(2, #order)
    order[1], order[swap] = order[swap], order[1]
  end
  return order
end

function radio.scan()
  love.filesystem.createDirectory(DIR)
  local found = {}
  for _, name in ipairs(love.filesystem.getDirectoryItems(DIR)) do
    if radio.isTrack(name) then found[#found + 1] = name end
  end
  table.sort(found)
  radio.tracks = found
  return found
end

local function release()
  if source then
    source:stop()
    source:release()
  end
  source, current = nil, nil
end

-- A file that won't open is skipped, and when none will the station stays quiet
-- rather than trying them all again every frame.
local function playNext()
  local last = current
  release()
  for _ = 1, #radio.tracks + 1 do
    if #queue == 0 then
      queue = radio.shuffle(radio.scan(), last)
      if #queue == 0 then return end
    end
    local name = table.remove(queue, 1)
    local ok, opened = pcall(love.audio.newSource, DIR .. "/" .. name, "stream")
    if ok then
      source, current = opened, name
      source:setVolume(settings.radioVolume)
      if not paused then source:play() end
      announce = radio.title(name)
      return
    end
    print("radio: can't play " .. name .. ": " .. tostring(opened))
    last = name
  end
end

-- Copies a file dropped on the window into the music folder.
function radio.addFile(file)
  local name = file:getFilename():match("[^/\\]+$")
  if not name or not radio.isTrack(name) then return false end
  if not file:open("r") then return false end
  local data = file:read("data")
  file:close()
  love.filesystem.createDirectory(DIR)
  local written = love.filesystem.write(DIR .. "/" .. name, data)
  radio.scan()
  queue = {}
  if on and not source then playNext() end
  return written
end

function radio.tune(wanted)
  on = wanted and love.audio ~= nil and settings.radioVolume > 0
  if not on then
    release()
    queue, paused, announce = {}, false, nil
    return
  end
  paused = false
  if source then
    source:play()
  else
    playNext()
  end
end

function radio.pause(wanted)
  if not on then return end
  paused = wanted
  if not source then return end
  if wanted then source:pause() else source:play() end
end

function radio.skip()
  if on then playNext() end
end

-- Moves on when a song ends. Returns a song's title the once, to show it.
function radio.update()
  if on and not paused and source and not source:isPlaying() then playNext() end
  local title = announce
  announce = nil
  return title
end

function radio.isPlaying()
  return source ~= nil and source:isPlaying()
end

function radio.song()
  return current
end

function radio.openFolder()
  radio.scan()
  love.system.openURL("file://" .. love.filesystem.getSaveDirectory() .. "/" .. DIR)
end

return radio
