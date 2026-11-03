-- Cheat codes. Each one only changes how your own car looks or sounds, on your own
-- screen: nothing reaches the simulation or the other players.
--
-- A word can be typed anywhere outside the editor, with nothing shown, or entered
-- in SETTINGS > CODE, which is how a phone gets at them. The words use only letters
-- that no driving key or menu key is bound to, so typing one in a race does nothing
-- else.
local settings = require("src/settings")

local cheats = {
  CODES = {
    BLITZ = "flames",   -- fire from the exhaust, once
    TOOTY = "tuneHorn", -- the horn plays a tune
    LUX = "neon",       -- a glow under the car
  },
  FLAME_TIME = 3,       -- seconds of fire
  flamesArmed = false,
}

local MEMORY = 8  -- letters kept, as long as the longest word
local typed = ""

-- Takes one typed character. Returns the effect when it finishes a code word.
function cheats.type(char)
  if not char:match("^%a$") then return nil end
  typed = (typed .. char:upper()):sub(-MEMORY)
  for word, effect in pairs(cheats.CODES) do
    if typed:sub(-#word) == word then
      typed = ""
      return effect
    end
  end
  return nil
end

-- A whole word, as entered in the menu.
function cheats.enter(word)
  return cheats.CODES[word:upper()]
end

local TOGGLES = { tuneHorn = "TUNE HORN", neon = "NEON" }

-- Turns an effect on, or a toggle off again. Returns what to tell the player.
function cheats.apply(effect)
  if effect == "flames" then
    cheats.flamesArmed = true
    return "FLAMES ARMED"
  end
  settings[effect] = not settings[effect]
  settings.save()
  return TOGGLES[effect] .. (settings[effect] and " ON" or " OFF")
end

-- True once per arming.
function cheats.takeFlames()
  local armed = cheats.flamesArmed
  cheats.flamesArmed = false
  return armed
end

function cheats.reset()
  typed = ""
  cheats.flamesArmed = false
end

return cheats
