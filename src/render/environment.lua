-- Light and colour for each time of day, and the look of each circuit.
local environment = {}

environment.TIMES = {
  day = {
    ambient = { 1, 1, 1 }, lights = false, grade = { 1.02, 1.0, 0.97 },
    sun = { 0.62, 0.78 }, shadowLength = 7, shadowAlpha = 0.42, glow = 0.8, vignette = 0.42,
  },
  dusk = {
    ambient = { 1.0, 0.8, 0.68 }, lights = true, grade = { 1.05, 0.99, 0.94 },
    sun = { 0.9, 0.42 }, shadowLength = 20, shadowAlpha = 0.38, glow = 1.0, vignette = 0.6,
  },
  night = {
    ambient = { 0.2, 0.23, 0.34 }, lights = true, grade = { 0.98, 1.0, 1.08 },
    sun = { 0.3, 0.9 }, shadowLength = 4, shadowAlpha = 0.25, glow = 1.25, vignette = 0.7,
  },
}

environment.THEMES = {
  meadow = {
    groundA = { 0.20, 0.31, 0.15 }, groundB = { 0.27, 0.37, 0.17 }, stripes = 0.05,
    gravel = { 0.71, 0.63, 0.47 }, dust = { 0.45, 0.38, 0.24 }, scenery = "trees",
    barrierA = { 0.92, 0.92, 0.9 }, barrierB = { 0.78, 0.13, 0.14 },
  },
  desert = {
    groundA = { 0.72, 0.59, 0.40 }, groundB = { 0.80, 0.68, 0.48 }, stripes = 0,
    gravel = { 0.60, 0.47, 0.30 }, dust = { 0.80, 0.68, 0.48 }, scenery = "palms",
    barrierA = { 0.92, 0.92, 0.9 }, barrierB = { 0.11, 0.42, 0.62 },
  },
  marina = {
    groundA = { 0.33, 0.34, 0.35 }, groundB = { 0.40, 0.41, 0.41 }, stripes = 0,
    gravel = { 0.62, 0.58, 0.5 }, dust = { 0.52, 0.5, 0.46 }, scenery = "containers",
    barrierA = { 0.8, 0.8, 0.78 }, barrierB = { 0.8, 0.8, 0.78 },
  },
}

function environment.time(name)
  return environment.TIMES[name] or environment.TIMES.day
end

function environment.theme(name)
  return environment.THEMES[name] or environment.THEMES.meadow
end

return environment
