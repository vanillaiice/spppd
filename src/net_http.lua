-- Fetches web pages over HTTPS on a thread of its own (src/https_worker.lua).
-- Only LÖVE 12 has HTTPS; the browser build (LÖVE 11.4) and 11.x have none, and
-- callers then open the page in the browser instead. update runs every frame.
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

-- Calls done(body) for a 200 reply, else done(nil, why). Returns an id to cancel.
function net.get(url, done)
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
  pending[nextId] = done
  requests:push({ id = nextId, url = url, agent = "SPPPD/" .. config.VERSION })
  return nextId
end

-- The reply is dropped when it comes.
function net.cancel(id)
  if id then pending[id] = nil end
end

function net.update()
  if not replies then return end
  local reply = replies:pop()
  while reply do
    local done = pending[reply.id]
    pending[reply.id] = nil
    if done then
      if reply.code == 200 then
        done(reply.body)
      else
        done(nil, reply.err or ("HTTP " .. tostring(reply.code)))
      end
    end
    reply = replies:pop()
  end
  -- A thread that died takes every request still waiting with it.
  if thread and not thread:isRunning() then
    local why = thread:getError() or "stopped"
    thread = nil
    for id, done in pairs(pending) do
      pending[id] = nil
      done(nil, why)
    end
  end
end

return net
