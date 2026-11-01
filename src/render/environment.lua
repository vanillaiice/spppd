-- Light and colour for each time of day, and the look of each circuit.
local environment = {}

-- How far headlights reach, in metres. Past 70 m they run off the top of the
-- screen, so a floodlit circuit barely needs them.
local BEAMS = {
  low = { length = 74, width = 46, power = 1.1 },
  high = { length = 120, width = 52, power = 1.4 },
}
-- With nothing else lit these have to end on screen, so the road runs out into
-- the dark, and a corner stays out of the light until the car turns in.
local DARK_BEAMS = {
  low = { length = 48, width = 38, power = 1.2 },
  high = { length = 72, width = 44, power = 1.4 },
}

environment.TIMES = {
  day = {
    ambient = { 1, 1, 1 }, lights = false, grade = { 1, 1, 1 }, saturation = 1.15,
    sun = { 0.62, 0.78 }, shadowLength = 9, shadowAlpha = 0.26, glow = 0.8, vignette = 0,
  },
  dusk = {
    ambient = { 1.0, 0.72, 0.78 }, lights = true, floodlit = true, beams = BEAMS, grade = { 1.04, 0.98, 1.0 }, saturation = 1.25,
    sun = { 0.9, 0.42 }, shadowLength = 20, shadowAlpha = 0.34, glow = 1.0, vignette = 0.15,
  },
  night = {
    ambient = { 0.3, 0.32, 0.55 }, lights = true, floodlit = true, beams = BEAMS, grade = { 1, 1, 1.04 }, saturation = 1.3,
    sun = { 0.3, 0.9 }, shadowLength = 4, shadowAlpha = 0.25, glow = 1.25, vignette = 0.25,
  },
  -- No floodlights: a car sees by its own headlights, and by the moon just enough
  -- to make out the shape of things. Studs mark the road's edges beyond the beams.
  -- Cars start on high beam, because a phone has no lights button.
  midnight = {
    ambient = { 0.075, 0.09, 0.17 }, lights = true, floodlit = false, beams = DARK_BEAMS, highBeams = true,
    studs = true, grade = { 1, 1, 1.02 }, saturation = 1.1,
    sun = { 0.3, 0.9 }, shadowLength = 3, shadowAlpha = 0.2, glow = 1.3, vignette = 0.3,
  },
}

-- The look is flat toy-track colour: solid shapes and crisp edges, no photo
-- texture. `pattern` picks how the ground is painted: 0 mown stripes,
-- 1 wavy dunes, 2 tiled slabs.
environment.THEMES = {
  meadow = {
    groundA = { 0.36, 0.78, 0.27 }, groundB = { 0.30, 0.70, 0.24 }, pattern = 0,
    road = { 0.30, 0.31, 0.40 },
    gravel = { 0.98, 0.86, 0.55 }, dust = { 0.85, 0.74, 0.5 }, scenery = "trees",
    barrierA = { 0.98, 0.98, 0.96 }, barrierB = { 0.93, 0.13, 0.18 },
  },
  desert = {
    groundA = { 0.98, 0.79, 0.42 }, groundB = { 0.95, 0.70, 0.35 }, pattern = 1,
    road = { 0.30, 0.31, 0.40 },
    gravel = { 0.99, 0.91, 0.68 }, dust = { 0.98, 0.84, 0.58 }, scenery = "palms",
    barrierA = { 0.98, 0.98, 0.96 }, barrierB = { 0.05, 0.45, 0.92 },
  },
  marina = {
    groundA = { 0.72, 0.77, 0.84 }, groundB = { 0.65, 0.71, 0.79 }, pattern = 2,
    road = { 0.28, 0.29, 0.38 },
    gravel = { 0.96, 0.84, 0.48 }, dust = { 0.8, 0.82, 0.86 }, scenery = "containers",
    barrierA = { 0.98, 0.82, 0.12 }, barrierB = { 0.14, 0.15, 0.2 },
  },
}

function environment.time(name)
  return environment.TIMES[name] or environment.TIMES.day
end

function environment.theme(name)
  return environment.THEMES[name] or environment.THEMES.meadow
end

return environment
