-- One of the threads audio.prerender starts on a first launch. It takes sound
-- names off the queue until it's empty, renders each into the cache folder, then
-- says so on done.
require("love.filesystem")
require("love.sound")
require("love.data")
require("love.math")
require("love.timer")

local folder, queue, done = ...
local cache = require("src/sound_cache")
local audio = require("src/audio")
local unpack = unpack or table.unpack

cache.folder, cache.complete = folder, false
local jobs = {}
for _, job in ipairs(audio.jobs()) do jobs[job.name] = job end

while true do
  local name = queue:pop()
  if not name then break end
  local job = jobs[name]
  cache.get(name, job.render, unpack(job.args))
end
done:push(true)
