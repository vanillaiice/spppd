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

-- Where the server the settings name keeps its tracks, the same server online races
-- use. SERVER names the relay, a UDP port, so the game asks it where its web side
-- is (server/web.go): spppd.xyz says https://spppd.xyz, and a relay run at home
-- says http://:8081, its own host in plain HTTP. A relay that doesn't answer is
-- from before 4.0, and its web side is taken to be https://HOST.
local bases = {}  -- settings.server -> the address its relay gave

-- A host as it goes in an address: IPv6 in brackets.
local function urlHost(host)
  if host:find(":", 1, true) and not host:match("^%[") then return "[" .. host .. "]" end
  return host
end

-- The address the relay answered with, made whole: no host there means the host the
-- relay was reached at. Nil for anything that isn't one plain address.
function online.webBase(answer, host)
  local scheme, rest = answer:match("^(https?://)(.*)$")
  if not scheme or rest:find("[%s|\\\"'<>]") or #answer > 120 then return nil end
  rest = rest:gsub("/+$", "")
  if rest == "" or rest:sub(1, 1) == ":" or rest:sub(1, 1) == "/" then
    return scheme .. urlHost(host) .. rest
  end
  return scheme .. rest
end

-- The host in an address, without brackets or port.
function online.hostOf(base)
  local rest = base:match("^https?://([^/]*)") or ""
  return rest:match("^%[(.-)%]") or rest:match("^[^:]*")
end

-- Calls done(base) with where the tracks are, or done(nil, message). Returns an id
-- to cancel the asking.
function online.resolve(done)
  local server = settings.server
  if bases[server] then
    done(bases[server])
    return nil
  end
  local host, port = settings.serverAddress()
  return net.askWeb(host, port, function(answer, why)
    if why == "no https" then
      done(nil, "This version can't fetch tracks")
    elseif not answer then
      done("https://" .. urlHost(host))  -- not kept: the relay may only be down
    elseif answer == "" then
      done(nil, host .. " has no tracks")
    else
      bases[server] = online.webBase(answer, host) or ("https://" .. urlHost(host))
      done(bases[server])
    end
  end)
end

function online.fetch()
  net.cancel(request)
  online.status, online.message = "loading", nil
  local host = settings.serverAddress()
  online.from = settings.server
  local function failed(message)
    request = nil
    online.status, online.message = "error", message
  end
  -- A known address answers at once, and the list's request is then the one to keep.
  local asking = online.resolve(function(base, why)
    if not base then return failed(why) end
    request = net.get(base .. config.TRACKS_API_PATH, function(body, err)
      request = nil
      local tracks = body and online.parse(body)
      if tracks then
        online.tracks, online.status = tracks, "ready"
      else
        failed(err == "no https" and "This version can't fetch tracks" or ("Couldn't reach " .. host))
      end
    end)
  end)
  if asking then request = asking end
end

-- Fetches the list unless it's there or on its way, from the server set now.
function online.open()
  if online.status == "idle" or online.status == "error" or online.from ~= settings.server then online.fetch() end
end

-- Sends a track in, to wait for whoever runs the server to approve it. Plain HTTP
-- only goes as far as this computer's own network: further, anyone on the way could
-- read the email. Calls done(true, message) once it's in, else done(false, why).
function online.send(def, author, contact, done)
  local host = settings.serverAddress()
  local id
  local asking = online.resolve(function(base, why)
    if not base then return done(false, why) end
    if base:match("^http://") and not net.isLocal(online.hostOf(base)) then
      return done(false, host .. " has no HTTPS, so tracks can't be sent to it from here")
    end
    local body = json.encode({ track = share.export(def), author = author or "", contact = contact or "" })
    id = net.post(base .. config.TRACKS_API_PATH, body, function(reply, err, _, refusal)
      local ok, data = pcall(json.decode, reply or refusal or "")
      if not ok or type(data) ~= "table" then data = {} end
      if reply then
        -- The server's own thanks are worded for its web page.
        done(true, "Sent. It shows in TRACKS ONLINE once it's been checked")
      elseif err == "no https" then
        done(false, "This version can't send tracks")
      else
        done(false, type(data.error) == "string" and data.error or ("Couldn't reach " .. host))
      end
    end)
  end)
  if asking and not id then id = asking end
  return function() net.cancel(id) end
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
