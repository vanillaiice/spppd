-- Talks to web servers on a thread of its own (src/https_worker.lua), over HTTPS,
-- or plain HTTP where a server run at home has nothing else. Only LÖVE 12 has
-- lua-https; the browser build (LÖVE 11.4) and 11.x have none, and callers then
-- open the page in the browser instead. update runs every frame.
local config = require("src.config")

local net = {}

local thread, requests, replies
local pending = {}
local nextId = 0
local probed, can

function net.available()
  if probed then return can end
  probed = true
  can = love.thread ~= nil and love.system.getOS() ~= "Web" and (pcall(require, "https"))
  return can
end

local function start(job, done)
  if not net.available() then
    done(nil, "no https")
    return nil
  end
  if not thread then
    requests, replies = love.thread.newChannel(), love.thread.newChannel()
    thread = love.thread.newThread("src/https_worker.lua")
    thread:start(requests, replies)
  end
  nextId = nextId + 1
  job.id = nextId
  pending[nextId] = { done = done, ask = job.ask }
  requests:push(job)
  return nextId
end

-- Calls done(body, nil, code) for a 2xx reply, else done(nil, why, code, body),
-- with the body a server sent with its refusal. Returns an id to cancel.
function net.request(url, done, method, body, contentType)
  return start({ url = url, method = method, body = body, type = contentType,
    agent = "SPPPD/" .. config.VERSION }, done)
end

function net.get(url, done)
  return net.request(url, done)
end

function net.post(url, body, done)
  return net.request(url, done, "POST", body, "application/json")
end

-- Asks the relay at host:port where its web side is: done(address), "" when it has
-- none, or done(nil, why) when it didn't answer, as relays before 4.0 don't.
function net.askWeb(host, port, done)
  return start({ ask = "web", host = host, port = port }, done)
end

-- The reply is dropped when it comes.
function net.cancel(id)
  if id then pending[id] = nil end
end

-- On this computer or its own network, where plain HTTP is all a server run at
-- home has, and nobody else is on the way: loopback, private and link-local
-- addresses, shared address space (Tailscale and the like), and home names.
function net.isLocal(host)
  host = (host or ""):lower():gsub("^%[(.*)%]$", "%1")
  if host == "localhost" or host:match("%.localhost$") or host:match("%.local$")
    or host:match("%.lan$") or host:match("%.home%.arpa$") then
    return true
  end
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a then
    a, b = tonumber(a), tonumber(b)
    if a > 255 or b > 255 or tonumber(c) > 255 or tonumber(d) > 255 then return false end
    return a == 127 or a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
      or (a == 169 and b == 254) or (a == 100 and b >= 64 and b <= 127)
  end
  if host:find(":", 1, true) then
    return host == "::1" or host:match("^f[cd]%x%x?:") ~= nil or host:match("^fe[89ab]%x?:") ~= nil
  end
  return false
end

function net.update()
  if not replies then return end
  local reply = replies:pop()
  while reply do
    local job = pending[reply.id]
    pending[reply.id] = nil
    if job then
      if job.ask == "web" then
        job.done(reply.web, reply.err)
      elseif reply.code and reply.code >= 200 and reply.code < 300 then
        job.done(reply.body, nil, reply.code)
      else
        job.done(nil, reply.err or ("HTTP " .. tostring(reply.code)), reply.code, reply.body)
      end
    end
    reply = replies:pop()
  end
  -- A thread that died takes every request still waiting with it.
  if thread and not thread:isRunning() then
    local why = thread:getError() or "stopped"
    thread = nil
    for id, job in pairs(pending) do
      pending[id] = nil
      job.done(nil, why)
    end
  end
end

return net
