-- Drivers: a name the others see online, kept by the server. There's no email
-- and no password. Picking a name makes two random keys on this device: a device
-- key, which proves it's you each time you take a seat, and a recovery key, shown
-- as a recovery code, which signs another device in. Each is sent to the server
-- once, when it's made. After that the game only sends proofs: an HMAC over the
-- relay's cookie, which only this address sees and which changes every 30 s.
--
-- A driver belongs to one server, so the file keeps one for each server address.
-- Requests use a socket of their own and wait on nothing: each is repeated four
-- times a second until the server answers, as the room requests are.
local socket = require("socket")
local bit = require("bit")
local settings = require("src/settings")

local account = {
  FILE = "account.lua",
  busy = nil,      -- the request waiting on an answer
  message = "",    -- what the last one came to
  profile = nil,   -- { since, devices } from the last profile answer
}

local PROTOCOL = 5
local KEY_BYTES = 16
local PROOF_CHARS = 22
local REGISTER_BYTES = 64
local RESEND = 0.25
local TIMEOUT = 6
local NAME_MIN, NAME_MAX = 3, 12

local saved = {}   -- driver by server address

-- Encodings -------------------------------------------------------------------

function account.base64url(raw)
  local text = love.data.encode("string", "base64", raw)
  return (text:gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

function account.unbase64url(text)
  if not text:match("^[%w_%-]*$") then return nil end
  local padded = text:gsub("%-", "+"):gsub("_", "/")
  padded = padded .. string.rep("=", (4 - #padded % 4) % 4)
  local ok, raw = pcall(love.data.decode, "string", "base64", padded)
  return ok and raw or nil
end

local BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

function account.base32(raw)
  local out, buffer, bits = {}, 0, 0
  for i = 1, #raw do
    buffer = bit.bor(bit.lshift(buffer, 8), raw:byte(i))
    bits = bits + 8
    while bits >= 5 do
      bits = bits - 5
      local index = bit.band(bit.rshift(buffer, bits), 31)
      out[#out + 1] = BASE32:sub(index + 1, index + 1)
    end
    buffer = bit.band(buffer, bit.lshift(1, bits) - 1)
  end
  if bits > 0 then
    local index = bit.band(bit.lshift(buffer, 5 - bits), 31)
    out[#out + 1] = BASE32:sub(index + 1, index + 1)
  end
  return table.concat(out)
end

-- Reads n bytes back, or nil. Letters that look like the digits typed by mistake
-- are read as them.
function account.unbase32(text, n)
  text = text:upper():gsub("0", "O"):gsub("1", "I"):gsub("8", "B")
  local out, buffer, bits = {}, 0, 0
  for i = 1, #text do
    local index = BASE32:find(text:sub(i, i), 1, true)
    if not index then return nil end
    buffer = bit.bor(bit.lshift(buffer, 5), index - 1)
    bits = bits + 5
    if bits >= 8 then
      bits = bits - 8
      out[#out + 1] = string.char(bit.band(bit.rshift(buffer, bits), 255))
      buffer = bit.band(buffer, bit.lshift(1, bits) - 1)
    end
  end
  local raw = table.concat(out)
  if #raw < n then return nil end
  return raw:sub(1, n)
end

-- HMAC-SHA-256, as the relay checks it. tests/test_account.lua and the relay's
-- tests share a vector.
function account.hmac(key, message)
  local block = 64
  if #key > block then key = love.data.hash("sha256", key) end
  key = key .. string.rep("\0", block - #key)
  local inner, outer = {}, {}
  for i = 1, block do
    local b = key:byte(i)
    inner[i] = string.char(bit.bxor(b, 0x36))
    outer[i] = string.char(bit.bxor(b, 0x5c))
  end
  local first = love.data.hash("sha256", table.concat(inner) .. message)
  return love.data.hash("sha256", table.concat(outer) .. first)
end

function account.proofOf(key, message)
  return account.base64url(account.hmac(key, message)):sub(1, PROOF_CHARS)
end

-- Random keys come from the system where it has a source, which Linux and
-- Android do. Elsewhere, what's to hand is stirred through SHA-256: clocks, the
-- addresses tables land at, and how long a little busy work takes, many times.
local function randomBytes(n)
  local file = io.open("/dev/urandom", "rb")
  if file then
    local raw = file:read(n)
    file:close()
    if raw and #raw == n then return raw end
  end
  local parts = { tostring(os.time()), tostring(os.clock()), tostring({}), tostring(account), tostring(love.timer.getTime()) }
  for i = 1, 200 do
    local start = love.timer.getTime()
    local x = 0
    for j = 1, 200 + i do x = x + j * j end
    parts[#parts + 1] = string.format("%.12f%d%s", love.timer.getTime() - start, love.math.random(0, 2 ^ 30), tostring({}))
  end
  local seed = table.concat(parts, "|")
  local raw = ""
  while #raw < n do
    seed = love.data.hash("sha256", seed .. #raw)
    raw = raw .. seed
  end
  return raw:sub(1, n)
end
account.randomBytes = randomBytes

-- Names -----------------------------------------------------------------------

-- The shape the server takes. It also refuses some names this doesn't know about.
function account.nameProblem(name)
  if #name < NAME_MIN or #name > NAME_MAX or not name:match("^[%w_%-]+$") then
    return "Names are 3 to 12 letters, numbers, - or _"
  end
  return nil
end

-- Saved drivers ----------------------------------------------------------------

function account.load()
  saved = {}
  local data = settings.loadTable(account.FILE)
  if type(data) ~= "table" then return end
  for server, driver in pairs(data) do
    if type(server) == "string" and type(driver) == "table" and type(driver.id) == "number"
      and type(driver.name) == "string" and type(driver.key) == "string" and type(driver.recovery) == "string" then
      saved[server] = { id = driver.id, name = driver.name, key = driver.key, recovery = driver.recovery }
    end
  end
end

local function save()
  love.filesystem.write(account.FILE, "return " .. settings.serialize(saved) .. "\n")
end

-- The driver on the server in the settings, or nil.
function account.driver()
  return saved[settings.server]
end

local function setDriver(driver)
  saved[settings.server] = driver
  account.profile = nil
  save()
end

-- For a seat request: ACCOUNT and PROOF, or two empty fields.
function account.seatFields(intent, cookie)
  local driver = account.driver()
  local key = driver and account.unbase64url(driver.key)
  if not key or not cookie then return "", "" end
  return tostring(driver.id), account.proofOf(key, intent .. "|" .. cookie)
end

-- The recovery code: the driver's number and the recovery key, in groups of five.
function account.recoveryCode()
  local driver = account.driver()
  local raw = driver and account.unbase64url(driver.recovery)
  if not raw then return nil end
  local text, groups = account.base32(raw), {}
  for i = 1, #text, 5 do groups[#groups + 1] = text:sub(i, i + 4) end
  return driver.id .. "-" .. table.concat(groups, "-")
end

-- Reads a recovery code as typed: a number, a dash, then the key.
function account.readCode(code)
  code = code:upper():gsub("%s", "")
  local id, rest = code:match("^(%d+)%-(.+)$")
  if not id then return nil end
  local raw = account.unbase32((rest:gsub("%-", "")), KEY_BYTES)
  if not raw then return nil end
  return tonumber(id), raw
end

-- The server renamed this driver: what a room or the profile says is now its name.
function account.renamedTo(name)
  local driver = account.driver()
  if not driver or driver.name == name then return end
  driver.name = name
  save()
  account.message = "The server changed your name to " .. name
end

-- Requests ----------------------------------------------------------------------

local function closeSocket()
  if account.udp then
    account.udp:close()
    account.udp = nil
  end
end

local function send()
  local busy = account.busy
  local text = "event|" .. busy.intent .. "|" .. PROTOCOL .. "|" .. (busy.cookie or "") .. "|"
    .. table.concat(busy.fields(busy.cookie or ""), "|") .. "|"
  account.udp:send(text .. string.rep(".", REGISTER_BYTES - #text))
end

local function finish(message)
  closeSocket()
  account.busy = nil
  account.message = message
end

-- Starts a request. `fields(cookie)` gives what follows the cookie.
local function request(intent, fields, onDriver)
  if account.busy then return end
  local udp = socket.udp()
  udp:settimeout(0)
  local host, port = settings.serverAddress()
  if not udp:setpeername(host, port) then
    udp:close()
    account.message = "Can't reach the server. Check the address on the ONLINE screen."
    return
  end
  account.udp = udp
  account.busy = { intent = intent, fields = fields, onDriver = onDriver, since = love.timer.getTime(), resend = RESEND }
  account.message = ""
  send()
end

local function onAnswer(data)
  local busy = account.busy
  local kind, rest = data:match("^event|([^|]+)|?(.*)$")
  if kind == "cookie" then
    busy.cookie = rest:match("^[%w_%-]+")
    if busy.cookie then send() end
  elseif kind == "driver" then
    local id, name = rest:match("^(%d+)|([%w_%-]+)$")
    if not id then return end
    if busy.onDriver then busy.onDriver(tonumber(id), name) end
    finish(account.message)
  elseif kind == "profile" then
    local name, since, devices = rest:match("^([%w_%-]+)|([%d%-]+)|(%d+)")
    if not name then return end
    account.renamedTo(name)
    finish(account.message)
    account.profile = { since = since, devices = tonumber(devices) }
  elseif kind == "signedout" or kind == "nodriver" then
    local intent = busy.intent
    setDriver(nil)
    if intent == "forget" then
      finish("Driver deleted")
    elseif intent == "signout" then
      finish("Signed out of this device")
    elseif kind == "nodriver" then
      finish("That driver doesn't exist any more")
    else
      finish("This device isn't signed in any more. Use your recovery code")
    end
  elseif kind == "denied" then
    local message = rest:match("^[^|]*|(.*)$")
    finish(message and message ~= "" and message or "The server said no")
  end
end

function account.update(dt)
  local busy = account.busy
  if not busy or not account.udp then return end
  while account.udp do
    local data = account.udp:receive()
    if not data then break end
    onAnswer(data)
  end
  if not account.busy then return end
  if love.timer.getTime() - busy.since > TIMEOUT then
    finish("No answer from the server. It may not have drivers yet.")
    return
  end
  busy.resend = busy.resend - dt
  if busy.resend <= 0 then
    busy.resend = RESEND
    send()
  end
end

function account.cancel()
  if account.busy then finish("") end
end

-- What the player can do ----------------------------------------------------------

function account.signUp(name)
  name = name:upper()
  local problem = account.nameProblem(name)
  if problem then
    account.message = problem
    return
  end
  local key, recovery = account.base64url(randomBytes(KEY_BYTES)), account.base64url(randomBytes(KEY_BYTES))
  local label = love.system.getOS()
  request("signup", function() return { name, key, recovery, label } end, function(id, given)
    setDriver({ id = id, name = given, key = key, recovery = recovery })
    account.message = "You're " .. given .. ". Keep your recovery code somewhere safe"
  end)
end

function account.recover(code)
  local id, raw = account.readCode(code)
  if not id then
    account.message = "That isn't a recovery code. It looks like 1042-ABCDE-..."
    return
  end
  local key = account.base64url(randomBytes(KEY_BYTES))
  local recovery = account.base64url(raw)
  request("recover", function(cookie)
    return { tostring(id), key, love.system.getOS(), account.proofOf(raw, "recover|" .. cookie .. "|" .. key) }
  end, function(given, name)
    setDriver({ id = given, name = name, key = key, recovery = recovery })
    account.message = "Signed in as " .. name
  end)
end

-- A request from this device as its driver: ID and PROOF, then `extra`.
local function asDriver(intent, extra, onDriver)
  local driver = account.driver()
  local key = driver and account.unbase64url(driver.key)
  if not key then return end
  request(intent, function(cookie)
    local fields = { tostring(driver.id), account.proofOf(key, intent .. "|" .. cookie) }
    for _, value in ipairs(extra or {}) do fields[#fields + 1] = value end
    return fields
  end, onDriver)
end

function account.rename(name)
  name = name:upper()
  local problem = account.nameProblem(name)
  if problem then
    account.message = problem
    return
  end
  asDriver("rename", { name }, function(_, given)
    local driver = account.driver()
    driver.name = given
    save()
    account.message = "You're " .. given .. " now"
  end)
end

function account.refresh()
  asDriver("profile")
end

function account.signOut()
  asDriver("signout")
end

function account.forget()
  asDriver("forget")
end

return account
