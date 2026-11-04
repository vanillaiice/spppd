-- Writes every sound the game makes to WAV files, for tests/sound/analyze.py:
-- `love . --sounds new dist/sfx/new` or `love . --sounds old dist/sfx/old`.
-- "old" is tests/sound/audio_original.lua, the sounds before the 2026-11 pass.
--
-- No list of sounds to keep up to date: it runs the real audio.load with the cache
-- and love.audio stood in for, so it catches whatever that renders, under the
-- names it uses. The JIT is off, as it is on a phone, so the times in _render.tsv
-- rank what's expensive at first launch.
--
-- It then drives the real audio.update through tests/sound/scenes.lua and logs
-- each frame's volumes and pitches for tests/sound/mix.py. That's the level the
-- code asks for, from the samples above. It is not a recording of the game.
local realCache = require("src/sound_cache")
local garage = require("src/entities/garage")
local scenes = require("tests/sound/scenes")

local MODULES = { new = "src/audio", old = "tests/sound/audio_original" }
local FRAME = 1 / 60
local RATE = 44100

local function fakeSource(data, record)
  local source = {
    data = data, volume = 1, pitch = 1, playing = false, looping = false, at = 0, fx = "dry",
    x = 0, y = 0,
  }
  record.sources[#record.sources + 1] = source
  function source.setLooping(_, looping)
    source.looping = looping
    record.loops[data] = looping
  end
  function source.setVolume(_, v) source.volume = v end
  function source.getVolume() return source.volume end
  function source.setPitch(_, p) source.pitch = p end
  function source.getPitch() return source.pitch end
  function source.setPosition(_, x, y) source.x, source.y = x, y end
  function source.setRelative() end
  function source.setAttenuationDistances() end
  function source.setRolloff() end
  function source.play() source.playing = true end
  function source.pause() source.playing = false end
  function source.stop()
    source.playing = false
    source.at = 0
  end
  function source.seek(_, seconds) source.at = seconds end
  function source.tell() return source.at end
  function source.isPlaying() return source.playing end
  function source.clone() return fakeSource(data, record) end
  return source
end

-- Every source that's sounding, as frame, name, volume, pitch, position in seconds.
local function logFrame(file, frame, record)
  for _, source in ipairs(record.sources) do
    if source.playing then
      if source.volume > 0 then
        file:write(string.format("%d\t%s\t%.5f\t%.5f\t%.5f\t%.3f\n", frame, record.names[source.data],
          source.volume, source.pitch, source.at, source.x))
      end
      local length = source.data:getDuration()
      source.at = source.at + FRAME * source.pitch
      if source.at >= length then
        if source.looping then source.at = source.at % length else source.stop() end
      end
    end
  end
end

local function runScenes(audio, folder, record)
  local clock = 1000
  love.timer.getTime = function() return clock end
  local list = assert(io.open(folder .. "/_trace.tsv", "w"))
  list:write("scene\tcar\tseconds\tevents\n")
  for _, spec in ipairs(garage) do
    for _, scene in ipairs(scenes.list) do
      audio.silence()
      local car = scenes.car(spec)
      local frames = math.floor(scene.seconds / FRAME)
      local name = scene.name .. "-" .. spec.id
      local file = assert(io.open(folder .. "/_trace/" .. name .. ".tsv", "w"))
      file:write("frame\tname\tvolume\tpitch\tat\tpan\n")
      local fired, labels = 1, {}
      for frame = 0, frames - 1 do
        local t = frame * FRAME
        clock = clock + FRAME
        scene.drive(car, t / scene.seconds, t)
        local event = scene.events and scene.events[fired]
        if event and t >= event.at then
          event.fire(audio)
          labels[#labels + 1] = string.format("%.2f=%s", event.at, event.label)
          fired = fired + 1
        end
        audio.update(FRAME, car, nil, 0)
        logFrame(file, frame, record)
      end
      file:close()
      list:write(string.format("%s\t%s\t%.3f\t%s\n", scene.name, spec.id, scene.seconds, table.concat(labels, ",")))
    end
  end
  list:close()
end

return function(which, folder)
  jit.off()
  assert(MODULES[which], "--sounds takes old or new")
  assert(folder, "--sounds needs a folder to write to")
  os.execute("mkdir -p '" .. folder .. "/_trace'")

  local record = { names = {}, order = {}, loops = {}, sources = {} }
  local stub = { open = function() end, finish = function() end }
  function stub.get(name, render, ...)
    local started = love.timer.getTime()
    local data = render(...)
    local took = love.timer.getTime() - started
    record.names[data] = name
    record.order[#record.order + 1] = { data = data, name = name, took = took }
    local file = assert(io.open(folder .. "/" .. name .. ".wav", "wb"))
    file:write(realCache.wav(data))
    file:close()
    return data
  end

  package.loaded["src/sound_cache"] = stub
  love.audio = { newSource = function(data) return fakeSource(data, record) end }
  local audio = require(MODULES[which])
  audio.load()
  assert(audio.ready, "audio.load failed: see the message above")

  local file = assert(io.open(folder .. "/_render.tsv", "w"))
  file:write("name\tkind\tseconds\trender_ms\n")
  local total = 0
  for _, entry in ipairs(record.order) do
    total = total + entry.took
    file:write(string.format("%s\t%s\t%.3f\t%.1f\n", entry.name, record.loops[entry.data] and "loop" or "shot",
      entry.data:getDuration(), entry.took * 1000))
  end
  -- The menu music, off the load path: it renders over menu frames instead.
  local songs = {}
  if which == "new" then
    local music = require("src/music")
    for _, id in ipairs(music.ORDER) do
      local started = love.timer.getTime()
      local data = music.render(id)
      local took = love.timer.getTime() - started
      local name = "music_" .. id
      local wav = assert(io.open(folder .. "/" .. name .. ".wav", "wb"))
      wav:write(realCache.wav(data))
      wav:close()
      file:write(string.format("%s\tloop\t%.3f\t%.1f\n", name, data:getDuration(), took * 1000))
      songs[#songs + 1] = string.format("%s %.2f s", id, took)
    end
  end
  file:close()
  print(string.format("%d sounds in %s, rendered in %.2f s with the JIT off", #record.order, folder, total))
  if #songs > 0 then print("menu music, rendered over menu frames: " .. table.concat(songs, ", ")) end
  runScenes(audio, folder, record)
end
