-- Cheat codes. Each one only changes how your own car looks or sounds, on your own
-- screen: nothing reaches the simulation or the other players.
--
-- A word can be typed anywhere outside the editor, with nothing shown, or entered
-- in SETTINGS > CODE, which is how a phone gets at them. The words use only letters
-- that no driving key or menu key is bound to, so typing one in a race does nothing
-- else.
local settings = require("src/settings")

local cheats = {
  -- Keyed by the word's hash, so the words aren't spelled out here.
  CODES = {
    [2311943435] = "flames",   -- fire from the exhaust, once
    [2333404357] = "tuneHorn", -- the horn plays a tune
    [1556052575] = "neon",     -- a glow under the car
  },
  LENGTHS = { 3, 5 },  -- the word lengths there are codes for
  FLAME_TIME = 3,      -- seconds of fire
  flamesArmed = false,
}

local MEMORY = 8  -- letters kept, at least as long as the longest word
local typed = ""

-- djb2 over a salted, upper-cased word. Only there to keep the words out of sight.
function cheats.hash(word)
  word = "spppd:" .. word:upper()
  local h = 5381
  for i = 1, #word do h = (h * 33 + word:byte(i)) % 4294967296 end
  return h
end

-- Takes one typed character. Returns the effect when it finishes a code word.
function cheats.type(char)
  if not char:match("^%a$") then return nil end
  typed = (typed .. char:upper()):sub(-MEMORY)
  for _, length in ipairs(cheats.LENGTHS) do
    if #typed >= length then
      local effect = cheats.CODES[cheats.hash(typed:sub(-length))]
      if effect then
        typed = ""
        return effect
      end
    end
  end
  return nil
end

-- A whole word, as entered in the menu.
function cheats.enter(word)
  return cheats.CODES[cheats.hash(word)]
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
