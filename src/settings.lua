-- Everything the game remembers between sessions.
local SERVER = "spppd.vanillaiice.xyz"
local SERVER_PORT = 8080  -- when the address doesn't name one

local settings = {
  assists = "arcade",
  camera = "chase",
  zoom = "near",
  units = "kmh",
  gearbox = "auto",
  volume = 0.8,
  radioVolume = 0.6,
  quality = "high",
  minimap = true,
  paceNotes = true,
  showFps = false,
  fullscreen = false,
  touch = "auto",
  autoGas = true,
  vibration = true,

  -- Last race setup
  mode = "race",
  track = "mirage",
  car = 1,
  hue = 1,
  laps = 3,
  opponents = 5,
  difficulty = "pro",
  time = "day",

  server = SERVER,
}

local records = {}
local FILE = "settings.lua"
local RECORDS = "records.lua"

-- Saved files are data: run them with no access to anything.
local function loadTable(path)
  if not love.filesystem.getInfo(path) then return nil end
  local loaded, chunk = pcall(love.filesystem.load, path)
  if not loaded or not chunk then return nil end
  setfenv(chunk, {})
  local ok, data = pcall(chunk)
  if ok and type(data) == "table" then return data end
  return nil
end

local function serialize(value, indent)
  indent = indent or ""
  local kind = type(value)
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "string" then return string.format("%q", value) end
  if kind == "table" then
    local inner = indent .. "  "
    local lines = {}
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local v = serialize(value[k], inner)
      if v then
        local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        lines[#lines + 1] = inner .. key .. " = " .. v .. ","
      end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
  end
  return nil
end
settings.serialize = serialize

function settings.load()
  local data = loadTable(FILE)
  if data then
    for k, v in pairs(data) do
      if type(settings[k]) == type(v) then settings[k] = v end
    end
  end
  -- FULL was replaced by ARCADE as the easiest handling tier.
  if settings.assists == "full" then settings.assists = "arcade" end
  -- MIRAGE replaced LUSAIL. Best laps stay under the old name: it was another road.
  if settings.track == "lusail" then settings.track = "mirage" end
  records = loadTable(RECORDS) or {}
end

-- The server as a host and a port. Only people running their own need a port.
function settings.serverAddress()
  local host, port = settings.server:match("^(.+):(%d+)$")
  return host or settings.server, tonumber(port) or SERVER_PORT
end

function settings.save()
  local out = {}
  for k, v in pairs(settings) do
    if type(v) ~= "function" then out[k] = v end
  end
  love.filesystem.write(FILE, "return " .. serialize(out) .. "\n")
end

local function recordKey(trackName, carId)
  return trackName .. "/" .. carId
end

function settings.bestLap(trackName, carId)
  local r = records[recordKey(trackName, carId)]
  return r and r.time or nil
end

function settings.ghost(trackName, carId)
  local r = records[recordKey(trackName, carId)]
  return r and r.ghost or nil
end

-- Returns true when this lap is a new record.
function settings.submitLap(trackName, carId, time, ghost)
  local key = recordKey(trackName, carId)
  local current = records[key]
  if current and current.time <= time then return false end
  records[key] = { time = time, ghost = ghost }
  love.filesystem.write(RECORDS, "return " .. serialize(records) .. "\n")
  return true
end

return settings
