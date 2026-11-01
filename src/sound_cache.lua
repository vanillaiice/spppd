-- Keeps rendered sounds in the save folder as WAV files, so only the first launch
-- pays to synthesise them. The folder is named after a hash of the code that
-- makes the sounds, so changing that code renders them afresh. A cache that can't
-- be read or written only costs time: the sound is rendered as usual.
local cache = {}

local ROOT = "soundcache"
local COMPLETE = "complete"  -- written last, so an interrupted first launch doesn't count

local function wav(data)
  local rate, bits, channels = data:getSampleRate(), data:getBitDepth(), data:getChannelCount()
  local size = data:getSize()
  local align = channels * bits / 8
  return love.data.pack("string", "<c4I4c4c4I4I2I2I4I4I2I2c4I4",
    "RIFF", 36 + size, "WAVE", "fmt ", 16, 1, channels, rate, rate * align, align, bits, "data", size)
    .. data:getString()
end

local function clear(path)
  for _, name in ipairs(love.filesystem.getDirectoryItems(path)) do
    local child = path .. "/" .. name
    if love.filesystem.getInfo(child, "directory") then clear(child) end
    love.filesystem.remove(child)
  end
end

function cache.key(sources)
  return love.data.encode("string", "hex", love.data.hash("md5", table.concat(sources, "\0")))
end

-- files: the source files that decide what the sounds are.
function cache.open(files)
  cache.folder, cache.complete, cache.failed = nil, false, false
  pcall(function()
    local sources = {}
    for i, file in ipairs(files) do sources[i] = assert(love.filesystem.read(file)) end
    local folder = ROOT .. "/" .. cache.key(sources)
    cache.complete = love.filesystem.getInfo(folder .. "/" .. COMPLETE) ~= nil
    if not cache.complete then
      clear(ROOT)
      assert(love.filesystem.createDirectory(folder))
    end
    cache.folder = folder
  end)
end

-- The sound called name: from disk if it's there, otherwise render(...).
function cache.get(name, render, ...)
  local folder = cache.folder
  if not folder then return render(...) end
  local path = folder .. "/" .. name .. ".wav"
  if cache.complete then
    local ok, data = pcall(love.sound.newSoundData, path)
    if ok then return data end
  end
  local data = render(...)
  local ok, written = pcall(love.filesystem.write, path, wav(data))
  if not (ok and written) then cache.failed = true end
  return data
end

function cache.finish()
  if cache.folder and not cache.complete and not cache.failed then
    cache.complete = love.filesystem.write(cache.folder .. "/" .. COMPLETE, "") and true or false
  end
end

return cache
