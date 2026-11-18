-- The tracks on spppd.xyz/tracks, from inside the game: the list, and taking one
-- into the saved tracks. Each track in the list carries its full code, which goes
-- through share.import like a pasted one, so it's held to the same limits.
local config = require("src.config")
local settings = require("src.settings")
local json = require("src.lib.json")
local net = require("src.net_http")
local catalog = require("src.tracks.catalog")
local share = require("src.tracks.share")

local online = {
  status = "idle",  -- idle, loading, ready or error
  tracks = {},
  message = nil,
}

local request

local function clean(raw)
  if type(raw) ~= "table" or type(raw.code) ~= "string" then return nil end
  local def = share.import(raw.code)
  if not def then return nil end
  local outline = {}
  if type(raw.outline) == "table" then
    for _, p in ipairs(raw.outline) do
      if type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) then
        outline[#outline + 1] = { tonumber(p[1]), tonumber(p[2]) }
      end
    end
  end
  local _, hash = catalog.fingerprint(def)
  return {
    id = tonumber(raw.id),
    title = def.title,
    author = def.author,
    theme = def.theme,
    metres = tonumber(raw.metres),
    added = type(raw.added) == "string" and raw.added:match("^%d%d%d%d%-%d%d%-%d%d$") or nil,
    outline = outline,
    def = def,
    hash = hash,
  }
end

-- Reads a reply from /api/tracks. Returns the tracks, or nil if it isn't one.
function online.parse(body)
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or type(data.tracks) ~= "table" then return nil end
  local out = {}
  for _, raw in ipairs(data.tracks) do
    out[#out + 1] = clean(raw)
  end
  return out
end

-- The track list on the server the settings name, the same one online races use.
-- A port there is the relay's (UDP); the list is on HTTPS at that host.
function online.url()
  local host = settings.serverAddress()
  return "https://" .. host .. config.TRACKS_API_PATH, host
end

function online.fetch()
  net.cancel(request)
  online.status, online.message = "loading", nil
  local url, host = online.url()
  online.from = host
  request = net.get(url, function(body, why)
    request = nil
    local tracks = body and online.parse(body)
    if tracks then
      online.tracks, online.status = tracks, "ready"
    else
      online.status = "error"
      online.message = why == "no https" and "This version can't fetch tracks" or ("Couldn't reach " .. host)
    end
  end)
end

-- Fetches the list unless it's there or on its way, from the server set now.
function online.open()
  local _, host = online.url()
  if online.status == "idle" or online.status == "error" or online.from ~= host then online.fetch() end
end

-- The saved or built-in track that is this one, whatever it's called there.
function online.have(track)
  return catalog.findByHash(track.hash)
end

-- Saves the track under a name of its own. Returns that name, or nil.
function online.take(track)
  local have = online.have(track)
  if have then return have.name end
  if not track.def.nodes then return nil end
  local name = catalog.uniqueName(track.title)
  if not catalog.save(name, track.def) then return nil end
  return name
end

return online
