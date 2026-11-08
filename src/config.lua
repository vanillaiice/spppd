-- Global tuning constants. Everything here is shared by the simulation,
-- the renderer and the tests, so it must stay free of LÖVE calls.
local config = {
  VERSION = "3.2.0",
  -- What the official server keeps, and its rules: PRIVACY.md on the website, which
  -- links to TERMS.md.
  PRIVACY_URL = "https://spppd.xyz/privacy/",

  -- World units are pixels; the vehicle model works in SI units.
  METER = 12,          -- world px per metre
  TRACK_SCALE = 3.0,   -- track-file units -> world px
  PHYSICS_DT = 1 / 120,
  MAX_STEPS_PER_FRAME = 8,

  GRAVITY = 9.81,

  -- Track layout (metres)
  KERB_WIDTH = 1.6,
  RUNOFF_WIDTH = 12,
  BARRIER_THICKNESS = 0.9,
  SAMPLE_SPACING = 2.5,

  START_DELAY = 3.6,   -- seconds of red lights

  LAPS_MIN = 1,
  LAPS_MAX = 20,
  OPPONENTS_MAX = 5,
}

return config
