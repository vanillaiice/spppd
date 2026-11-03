local h = require("tests/harness")
local cheats = require("src/cheats")
local settings = require("src/settings")
local input = require("src/input")
local audio = require("src/audio")

local function typeWord(word)
  local effect
  for char in word:gmatch(".") do effect = cheats.type(char) or effect end
  return effect
end

h.describe("cheats", function()
  h.it("a code word typed in among other letters is caught", function()
    cheats.reset()
    h.assertEq(typeWord("xxBLiTz"), "flames")
    h.assertEq(typeWord("BLIT"), nil)
    -- The buffer clears on a match, so its tail can't finish another word.
    cheats.reset()
    h.assertEq(typeWord("tooty"), "tuneHorn")
    h.assertEq(typeWord("lu"), nil)
    h.assertEq(typeWord("x"), "neon")
  end)

  h.it("a whole word from the menu toggles its effect", function()
    local saved = settings.neon
    settings.neon = false
    h.assertEq(cheats.enter("nope"), nil)
    local effect = cheats.enter("lux")
    h.assertEq(effect, "neon")
    h.assertEq(cheats.apply(effect), "NEON ON")
    h.assertTrue(settings.neon)
    h.assertEq(cheats.apply(effect), "NEON OFF")
    h.assertTrue(not settings.neon)
    settings.neon = saved
    settings.save()
  end)

  h.it("the flame code fires once per entry", function()
    cheats.reset()
    h.assertEq(cheats.apply("flames"), "FLAMES ARMED")
    h.assertTrue(cheats.takeFlames())
    h.assertTrue(not cheats.takeFlames())
  end)

  h.it("no code word presses a driving or menu key", function()
    local bound = { w = true, a = true, s = true, d = true }
    for _, keys in pairs(input.binds) do
      for _, key in ipairs(keys) do
        if #key == 1 then bound[key] = true end
      end
    end
    for word in pairs(cheats.CODES) do
      for char in word:lower():gmatch(".") do
        h.assertTrue(not bound[char], word .. " uses " .. char)
      end
    end
  end)

  h.it("the tune horn plays its tune and loops", function()
    local ratio, sounding = audio.hornTuneNote(0)
    h.assertNear(ratio, 2 ^ (-5 / 12), 1e-9)
    h.assertTrue(sounding)
    local length = audio.hornTuneLength()
    local again = audio.hornTuneNote(length + 0.01)
    h.assertNear(again, ratio, 1e-9)
    -- Repeated notes part: the end of the first G is silent.
    local _, tail = audio.hornTuneNote(0.125)
    h.assertTrue(not tail)
  end)

  h.it("a tap of the tune horn plays the whole song, once", function()
    local car = { hornTune = true, horn = true }
    local dt = 1 / 60
    audio.hornStep(car, dt)
    h.assertTrue(car.hornSounding)
    car.horn = false
    local played, t = 0, dt
    while car.tuneTime do
      audio.hornStep(car, dt)
      if car.hornSounding then played = played + dt end
      t = t + dt
    end
    h.assertNear(t, audio.hornTuneLength(), 2 * dt)
    h.assertTrue(played > audio.hornTuneLength() * 0.5, "sounded for " .. played)
    audio.hornStep(car, dt)
    h.assertTrue(not car.hornSounding, "silent once it's over")
  end)

  h.it("a held tune horn plays the song again, and the plain horn just honks", function()
    local car = { hornTune = true, horn = true }
    for _ = 1, math.ceil(audio.hornTuneLength() * 60) + 2 do audio.hornStep(car, 1 / 60) end
    h.assertTrue(car.tuneTime and car.tuneTime < 0.1, "started over")
    local plain = { horn = true }
    audio.hornStep(plain, 1 / 60)
    h.assertEq(plain.hornRatio, 1)
    h.assertTrue(plain.hornSounding)
  end)

  h.it("other drivers learn about the cheats, and older games ignore it", function()
    local network = require("src/network_manager")
    local packet = network.packLook({ round = 4, neon = true, tune = false, flames = 2, flameLeft = 2.5 })
    local look = network.unpackLook(packet)
    h.assertEq(look.round, 4)
    h.assertTrue(look.neon and not look.tune)
    h.assertEq(look.flames, 2)
    h.assertNear(look.flameLeft, 2.5, 0.01)
    h.assertEq(network.unpackLook("look|1|2|0|0|0"), nil)
    h.assertEq(network.unpackLook("look|1|1|1|1|999").flameLeft, 5)
    -- A game from before reads only the packets it knows.
    h.assertEq(network.unpackState(packet), nil)
  end)
end)
