-- The thread src/net_http.lua starts: lua-https and the relay's answer both keep
-- whoever asks waiting, so they run here, where waiting doesn't stop the game.
-- Takes jobs off requests and puts replies on them:
--   { id, url, agent, method, body, type } -> { id, code, body } or { id, err }
--   { id, ask = "web", host, port }        -> { id, web } or { id, err }
require("love.thread")

local requests, replies = ...
local ok, https = pcall(require, "https")
local hasSocket, socket = pcall(require, "socket")

-- What the relay at host:port says about its web side (see server/web.go). The ask
-- is padded, as the relay never answers with more than it was sent.
local ASK = "event|web|" .. string.rep(".", 150)
local TRIES, WAIT = 3, 0.4

local function askWeb(job)
  if not hasSocket then return { id = job.id, err = "no sockets" } end
  local udp = socket.udp()
  udp:settimeout(WAIT)
  local fine, why = udp:setpeername(job.host, job.port)
  if not fine then
    udp:close()
    return { id = job.id, err = tostring(why) }
  end
  for _ = 1, TRIES do
    udp:send(ASK)
    local data = udp:receive()
    local web = data and data:match("^event|web|(.*)$")
    if web then
      udp:close()
      return { id = job.id, web = web }
    end
  end
  udp:close()
  return { id = job.id, err = "no answer" }
end

local function fetch(job)
  if not ok then return { id = job.id, err = "no https" } end
  local headers = { ["User-Agent"] = job.agent }
  if job.type then headers["Content-Type"] = job.type end
  local fine, code, body = pcall(https.request, job.url,
    { method = job.method or "GET", data = job.body, headers = headers })
  if not fine then return { id = job.id, err = tostring(code) } end
  if not code or code == 0 then return { id = job.id, err = tostring(body or "no reply") } end
  return { id = job.id, code = code, body = body or "" }
end

while true do
  local job = requests:demand()
  if job == "stop" then break end
  replies:push(job.ask == "web" and askWeb(job) or fetch(job))
end
