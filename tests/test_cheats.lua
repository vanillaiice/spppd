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
end)
