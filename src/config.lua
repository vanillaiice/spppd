-- Global tuning constants. Everything here is shared by the simulation,
-- the renderer and the tests, so it must stay free of LÖVE calls.
local config = {
  VERSION = "2.1.0",

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

  LAPS_MIN = 1,
  LAPS_MAX = 20,
  OPPONENTS_MAX = 5,
}

return config
