-- Top views of the cars drawn by hand: one table per body style.
--
-- x runs -1..1 from tail to nose and y 0..1 from the centre line to the widest
-- point, in fractions of the car's own size, so a plan fits whatever length and
-- width its car has.
--
-- outline    half the body, tail to nose; a third number on a point is its own
--            corner radius in metres, otherwise `corner` applies
-- axleShift  metres to move the drawn wheels, because physics measures axles
--            from the centre of mass, and that isn't the middle of a rear-engined
--            or mid-engined body
-- headlamp, taillamp  where the night glow sits
-- parts      painted in order on top of the body. `across` is a half shape closed
--            over the centre line, `pair` is drawn on both sides, `solo` once as
--            written and `trace` is a line on both sides. `soft` rounds it off.
local GLASS = { 0.06, 0.09, 0.12, 1 }
local SHEEN = { 0.13, 0.18, 0.23, 1 }
local BLACK = { 0.045, 0.045, 0.055, 1 }
local TRIM = { 0.13, 0.13, 0.15, 1 }
local LAMP = { 0.93, 0.95, 0.9, 1 }
local TAIL = { 0.62, 0.05, 0.06, 1 }
local AMBER = { 0.95, 0.56, 0.1, 1 }
local SEAM = { 0, 0, 0, 0.32 }
local SHADE = { 0, 0, 0, 0.16 }
local DIP = { 0, 0, 0, 0.06 }
local LIGHT = { 1, 1, 1, 0.13 }

local plans = {}

-- A flat-nosed mid-engined poster car: a dart of straight lines, with the cabin
-- pushed right forward and a chevron wing over wide hips.
plans.wedge = {
  corner = 0.05, axleShift = -0.32,
  headlamp = { 0.62, 0.48 }, taillamp = { 1, 0.66 },
  outline = {
    { -1, 0.84 }, { -0.93, 1, 0.1 }, { -0.4, 1, 0.08 }, { -0.3, 0.9, 0.12 }, { 0.2, 0.9, 0.12 },
    { 0.3, 0.95, 0.08 }, { 0.66, 0.95 }, { 0.975, 0.64 }, { 1, 0.56 }, { 1, 0 },
  },
  parts = {
    -- Flanks fall away from the door crease.
    { SHADE, pair = { 0.6, 0.72, 0.2, 0.74, -0.3, 0.74, -0.3, 0.9, 0.2, 0.9, 0.3, 0.95, 0.66, 0.95 } },
    -- Bonnet creases, from the nose corners to the foot of the screen.
    { SEAM, trace = { 0.96, 0.5, 0.46, 0.7 } },
    { SEAM, trace = { 0.97, 0.18, 0.48, 0.2 } },
    -- Flat pop-up covers.
    { SEAM, trace = { 0.82, 0.36, 0.84, 0.58, 0.66, 0.68, 0.62, 0.42, 0.82, 0.36 }, width = 0.7 },
    { SHADE, pair = { 0.82, 0.36, 0.84, 0.58, 0.66, 0.68, 0.62, 0.42 } },
    -- Lights along the nose.
    { AMBER, pair = { 1, 0.3, 1, 0.54, 0.96, 0.58, 0.965, 0.3 } },
    -- Windscreen, side glass and the slot of rear window.
    { GLASS, across = { 0.44, 0.64, 0.06, 0.48 } },
    { SHEEN, solo = { 0.36, 0.46, 0.38, 0.14, 0.12, 0.08, 0.1, 0.34 } },
    { GLASS, pair = { 0.28, 0.67, 0.05, 0.53, -0.3, 0.5, -0.36, 0.64 } },
    { GLASS, across = { -0.34, 0.42, -0.42, 0.42 } },
    -- Roof seam and the door shut line.
    { SEAM, trace = { 0.08, 0.5, -0.32, 0.46 } },
    { SEAM, trace = { -0.08, 0.72, -0.08, 0.9 } },
    -- The duct cut into the door.
    { BLACK, pair = { 0.1, 0.76, -0.2, 0.86, -0.24, 0.78 } },
    -- Air boxes on the shoulders.
    { BLACK, pair = { -0.38, 0.54, -0.38, 0.84, -0.56, 0.84, -0.56, 0.5 } },
    { TRIM, pair = { -0.46, 0.56, -0.46, 0.82, -0.5, 0.82, -0.5, 0.54 } },
    -- Engine cover louvres.
    { BLACK, across = { -0.6, 0.34, -0.64, 0.34 } },
    { BLACK, across = { -0.68, 0.34, -0.72, 0.34 } },
    { BLACK, across = { -0.76, 0.34, -0.8, 0.34 } },
    -- Tail lamps, then the wing over them.
    { TAIL, pair = { -0.985, 0.42, -0.985, 0.8, -1, 0.8, -1, 0.42 } },
    { BLACK, across = { -0.76, 0, -0.86, 0.96, -0.95, 0.96, -0.86, 0 } },
  },
}

-- A rear-engined coupe: a teardrop cabin between round front wings and wide
-- hips, with its lamps on the tips of the wings and a tail that overhangs.
plans.coupe = {
  corner = 0.5, axleShift = -0.22,
  headlamp = { 0.84, 0.68 }, taillamp = { 0.97, 0.66 },
  outline = {
    { -1, 0.54 }, { -0.95, 0.82 }, { -0.78, 0.97 }, { -0.52, 1 }, { -0.28, 0.98 }, { -0.04, 0.94 }, { 0.2, 0.94 },
    { 0.42, 0.98 }, { 0.62, 0.99 }, { 0.82, 0.92 }, { 0.95, 0.74 }, { 1, 0.46 }, { 1, 0 },
  },
  parts = {
    -- Hips and front wings stand proud of the waist.
    { SHADE, pair = { 0.1, 0.84, -0.3, 0.86, -0.28, 0.98, -0.04, 0.94, 0.2, 0.94 } },
    { LIGHT, pair = { -0.36, 0.8, -0.74, 0.82, -0.76, 0.91, -0.52, 0.96 } },
    { LIGHT, pair = { 0.66, 0.86, 0.34, 0.8, 0.42, 0.92, 0.62, 0.94 } },
    -- Bonnet lid between the wings.
    { SEAM, trace = { 0.94, 0.4, 0.74, 0.46, 0.34, 0.66 } },
    { DIP, across = { 0.92, 0.38, 0.34, 0.6, 0.34, 0.1 } },
    -- Round lamps standing on the wing tips, leaning back along them.
    { TRIM, pair = { 0.92, 0.62, 0.84, 0.84, 0.7, 0.8, 0.77, 0.56 }, soft = 3 },
    { LAMP, pair = { 0.9, 0.63, 0.83, 0.8, 0.72, 0.77, 0.78, 0.59 }, soft = 3 },
    { BLACK, pair = { 0.995, 0.08, 0.99, 0.36, 0.97, 0.36, 0.975, 0.08 } },
    -- Curved screen, then the side glass round a long oval roof.
    { GLASS, across = { 0.31, 0.14, 0.29, 0.5, 0.24, 0.68, 0, 0.56, 0.03, 0.14 } },
    { SHEEN, solo = { 0.26, 0.44, 0.28, 0.2, 0.05, 0.1, 0.03, 0.26 } },
    { GLASS, pair = { 0.19, 0.74, -0.01, 0.61, -0.16, 0.6, -0.16, 0.78 } },
    { GLASS, pair = { -0.2, 0.78, -0.2, 0.6, -0.44, 0.54, -0.5, 0.66 } },
    { SEAM, trace = { -0.01, 0.59, -0.42, 0.52 } },
    { LIGHT, solo = { -0.06, -0.1, -0.06, -0.46, -0.36, -0.4, -0.36, -0.1 } },
    -- A long rear screen falling to the engine lid.
    { GLASS, across = { -0.44, 0.1, -0.44, 0.44, -0.66, 0.34, -0.68, 0.1 } },
    -- Louvres, then the lip of the tail spoiler on its shadow.
    { BLACK, across = { -0.72, 0.3, -0.74, 0.3 } },
    { BLACK, across = { -0.76, 0.3, -0.78, 0.3 } },
    { BLACK, across = { -0.81, 0.1, -0.81, 0.74, -0.83, 0.76, -0.835, 0.1 } },
    { LIGHT, across = { -0.84, 0.1, -0.84, 0.74, -0.93, 0.66, -0.955, 0.1 } },
    -- Lamps joined across the tail.
    { TAIL, across = { -0.992, 0.1, -0.985, 0.48, -0.945, 0.76, -0.935, 0.7, -0.965, 0.44, -0.97, 0.1 } },
    { BLACK, pair = { 0.3, 0.94, 0.3, 1.05, 0.25, 1.05, 0.25, 0.94 } },
  },
}

-- A rally saloon: three boxes, flared square arches, a bonnet full of vents and
-- a tall wing on the boot.
plans.sedan = {
  corner = 0.1, axleShift = 0.13,
  headlamp = { 0.88, 0.72 }, taillamp = { 1, 0.68 },
  outline = {
    { -1, 0.78 }, { -0.97, 0.9, 0.2 }, { -0.84, 0.95 }, { -0.8, 1 }, { -0.4, 1 }, { -0.34, 0.95 }, { 0.36, 0.95 },
    { 0.42, 1 }, { 0.76, 1 }, { 0.84, 0.97 }, { 0.97, 0.84 }, { 1, 0.6 }, { 1, 0 },
  },
  parts = {
    -- Arches pumped out past the doors.
    { LIGHT, pair = { 0.74, 0.9, 0.44, 0.9, 0.42, 0.98, 0.74, 0.98 } },
    { LIGHT, pair = { -0.42, 0.9, -0.78, 0.9, -0.78, 0.98, -0.42, 0.98 } },
    { SEAM, trace = { 0.92, 0.56, 0.4, 0.72 } },
    -- Bonnet scoop and the vents behind it.
    { BLACK, across = { 0.84, 0.32, 0.72, 0.26 } },
    { SEAM, across = { 0.87, 0.34, 0.84, 0.32 } },
    { BLACK, pair = { 0.6, 0.3, 0.56, 0.58, 0.5, 0.58, 0.54, 0.3 } },
    -- Swept lamps and the mouth below the bumper.
    { LAMP, pair = { 0.975, 0.5, 0.96, 0.82, 0.84, 0.92, 0.84, 0.72, 0.93, 0.62 } },
    { BLACK, across = { 0.995, 0.4, 0.97, 0.36 } },
    -- Saloon glass: screen, two side windows each side, rear screen.
    { GLASS, across = { 0.4, 0.14, 0.37, 0.7, 0.12, 0.58, 0.15, 0.14 } },
    { SHEEN, solo = { 0.33, 0.5, 0.35, 0.16, 0.18, 0.1, 0.16, 0.38 } },
    { GLASS, pair = { 0.32, 0.76, 0.11, 0.63, -0.12, 0.62, -0.12, 0.78 } },
    { GLASS, pair = { -0.17, 0.78, -0.17, 0.62, -0.4, 0.6, -0.46, 0.74 } },
    { GLASS, across = { -0.43, 0.56, -0.64, 0.64 } },
    { SEAM, trace = { -0.145, 0.8, -0.145, 0.95 } },
    { SEAM, trace = { 0.3, 0.8, 0.3, 0.95 } },
    { LIGHT, solo = { 0.1, -0.1, 0.1, -0.44, -0.34, -0.42, -0.34, -0.1 } },
    -- The row of fins at the back of the roof.
    { BLACK, pair = { -0.355, 0.06, -0.355, 0.1, -0.41, 0.1, -0.41, 0.06 } },
    { BLACK, pair = { -0.355, 0.2, -0.355, 0.24, -0.41, 0.24, -0.41, 0.2 } },
    { BLACK, pair = { -0.355, 0.34, -0.355, 0.38, -0.41, 0.38, -0.41, 0.34 } },
    { BLACK, pair = { -0.355, 0.48, -0.355, 0.52, -0.41, 0.52, -0.41, 0.48 } },
    { TAIL, pair = { -0.975, 0.5, -0.975, 0.86, -1, 0.86, -1, 0.5 } },
    -- The wing, with end plates, and its shadow on the boot lid.
    { SHADE, across = { -0.74, 0.3, -0.74, 0.92, -0.84, 0.92, -0.84, 0.3 } },
    { BLACK, across = { -0.82, 0.92, -0.92, 0.92 } },
    { TRIM, pair = { -0.8, 0.9, -0.8, 0.98, -0.94, 0.98, -0.94, 0.9 } },
    { BLACK, pair = { 0.3, 0.96, 0.3, 1.08, 0.24, 1.08, 0.24, 0.96 } },
  },
}

-- A short three-door hatch: stubby rounded nose, slanted lamps, long doors and
-- nearly all cabin, chopped off square at the back with a spoiler on the hatch.
plans.hatch = {
  corner = 0.3, axleShift = 0.12,
  headlamp = { 0.88, 0.6 }, taillamp = { 0.97, 0.76 },
  outline = {
    { -1, 0.6 }, { -0.98, 0.84 }, { -0.88, 0.96 }, { -0.66, 1 }, { -0.2, 0.99 }, { 0.2, 0.98 },
    { 0.52, 0.95 }, { 0.78, 0.86 }, { 0.93, 0.72 }, { 1, 0.44 }, { 1, 0 },
  },
  parts = {
    { SHADE, pair = { 0.34, 0.86, -0.7, 0.88, -0.84, 0.86, -0.88, 0.96, -0.66, 1, -0.2, 0.99, 0.2, 0.98, 0.34, 0.97 } },
    -- Bonnet with two pressed lines.
    { SEAM, trace = { 0.9, 0.54, 0.42, 0.72 } },
    { SEAM, trace = { 0.86, 0.26, 0.46, 0.34 } },
    { LIGHT, solo = { 0.78, -0.08, 0.78, -0.4, 0.46, -0.52, 0.46, -0.14 } },
    -- Slanted lamps, the slot of a grille and a small red badge.
    { LAMP, pair = { 0.97, 0.32, 0.93, 0.68, 0.8, 0.84, 0.84, 0.58 }, soft = 1 },
    { BLACK, across = { 0.99, 0.26, 0.955, 0.24 } },
    { TAIL, across = { 0.975, 0.05, 0.95, 0.05 } },
    -- The cabin runs almost to the tail.
    { GLASS, across = { 0.45, 0.14, 0.41, 0.74, 0.14, 0.62, 0.17, 0.14 } },
    { SHEEN, solo = { 0.36, 0.52, 0.38, 0.16, 0.2, 0.1, 0.18, 0.4 } },
    { GLASS, pair = { 0.35, 0.8, 0.13, 0.67, -0.32, 0.65, -0.32, 0.82 } },
    { GLASS, pair = { -0.37, 0.82, -0.37, 0.65, -0.68, 0.6, -0.74, 0.76 } },
    { SEAM, trace = { -0.345, 0.84, -0.345, 0.98 } },
    { SEAM, trace = { 0.36, 0.84, 0.36, 0.96 } },
    { LIGHT, solo = { 0.08, -0.1, 0.08, -0.46, -0.6, -0.42, -0.6, -0.1 } },
    -- Spoiler at the top of the hatch, then the glass below it.
    { BLACK, across = { -0.665, 0.6, -0.7, 0.6 } },
    { GLASS, across = { -0.72, 0.56, -0.91, 0.5 } },
    { SEAM, trace = { -0.95, 0.1, -0.94, 0.62, -0.86, 0.78 } },
    { TAIL, pair = { -0.985, 0.58, -0.955, 0.82, -0.87, 0.93, -0.9, 0.78, -0.95, 0.56 } },
    { BLACK, pair = { 0.36, 0.95, 0.36, 1.08, 0.3, 1.08, 0.3, 0.95 } },
  },
}

-- A big square off-roader: flat bonnet between its wings, upright glass, a roof
-- as long as the car with a rack on it, and steel at both ends.
plans.offroad = {
  corner = 0.09, axleShift = 0.18,
  headlamp = { 0.96, 0.62 }, taillamp = { 1, 0.76 },
  outline = {
    { -1, 0.9 }, { -0.96, 0.95 }, { -0.8, 0.95 }, { -0.78, 1 }, { -0.36, 1 }, { -0.34, 0.95 }, { 0.42, 0.95 },
    { 0.44, 1 }, { 0.82, 1 }, { 0.86, 0.95 }, { 0.98, 0.88 }, { 1, 0.72 }, { 1, 0 },
  },
  parts = {
    -- Square flares and the side steps between them.
    { TRIM, pair = { 0.82, 0.94, 0.44, 0.94, 0.44, 1, 0.82, 1 } },
    { TRIM, pair = { -0.36, 0.94, -0.78, 0.94, -0.78, 1, -0.36, 1 } },
    { BLACK, pair = { 0.4, 0.96, 0.4, 1, -0.33, 1, -0.33, 0.96 } },
    -- Bonnet set down between the wings, with a pressed centre.
    { SEAM, trace = { 0.96, 0.7, 0.48, 0.74 } },
    { SEAM, trace = { 0.9, 0.3, 0.5, 0.32 } },
    { SHADE, pair = { 0.96, 0.7, 0.96, 0.92, 0.48, 0.92, 0.48, 0.74 } },
    { LIGHT, solo = { 0.86, -0.1, 0.86, -0.52, 0.52, -0.54, 0.52, -0.12 } },
    -- Grille and lamps across the nose, with a steel bar in front.
    { BLACK, across = { 0.995, 0.42, 0.955, 0.42 } },
    { LAMP, pair = { 0.99, 0.48, 0.99, 0.74, 0.955, 0.74, 0.955, 0.48 } },
    { AMBER, pair = { 0.99, 0.77, 0.98, 0.87, 0.955, 0.86, 0.955, 0.77 } },
    { TRIM, across = { 1.03, 0.1, 1.03, 0.8, 1.0, 0.84, 1.0, 0.1 } },
    -- The screen stands up, so it shows as a short band.
    { GLASS, across = { 0.47, 0.14, 0.47, 0.78, 0.33, 0.72, 0.33, 0.14 } },
    { SHEEN, solo = { 0.45, 0.6, 0.45, 0.2, 0.36, 0.16, 0.36, 0.5 } },
    -- Three windows a side, seen edge on.
    { GLASS, pair = { 0.4, 0.86, 0.33, 0.75, 0.02, 0.75, 0.02, 0.87 } },
    { GLASS, pair = { -0.02, 0.87, -0.02, 0.75, -0.42, 0.75, -0.42, 0.87 } },
    { GLASS, pair = { -0.46, 0.87, -0.46, 0.75, -0.84, 0.75, -0.84, 0.87 } },
    { GLASS, across = { -0.88, 0.64, -0.94, 0.68 } },
    -- Rain gutter, and a roof rack with room on it.
    { SEAM, trace = { 0.33, 0.74, -0.87, 0.74, -0.87, 0.1 } },
    { SHADE, across = { 0.16, 0.62, -0.72, 0.62 } },
    { TRIM, pair = { 0.16, 0.56, 0.16, 0.62, -0.72, 0.62, -0.72, 0.56 } },
    { TRIM, across = { 0.16, 0.6, 0.12, 0.6 } },
    { TRIM, across = { -0.05, 0.6, -0.09, 0.6 } },
    { TRIM, across = { -0.26, 0.6, -0.3, 0.6 } },
    { TRIM, across = { -0.47, 0.6, -0.51, 0.6 } },
    { TRIM, across = { -0.68, 0.6, -0.72, 0.6 } },
    -- Snorkel up the right-hand pillar.
    { BLACK, solo = { 0.46, 0.86, 0.46, 0.93, 0.3, 0.88, 0.22, 0.86, 0.22, 0.79, 0.32, 0.81 } },
    -- Tail lamps and the spare on the back door.
    { TAIL, pair = { -0.985, 0.6, -0.985, 0.88, -1, 0.88, -1, 0.6 } },
    { BLACK, across = { -0.98, 0.36, -1.05, 0.34 } },
    { BLACK, pair = { 0.38, 0.97, 0.38, 1.12, 0.31, 1.12, 0.31, 0.97 } },
  },
}

-- A super SUV built like its low-slung cousins: all facets and hexagons, a nose
-- that narrows hard, and a coupe's falling roof over very wide hips.
plans.suv = {
  corner = 0.06, axleShift = 0.19,
  headlamp = { 0.86, 0.74 }, taillamp = { 0.96, 0.72 },
  outline = {
    { -1, 0.64 }, { -0.95, 0.86 }, { -0.82, 0.95 }, { -0.76, 1 }, { -0.36, 1 }, { -0.28, 0.93 }, { 0.36, 0.93 },
    { 0.44, 0.99 }, { 0.8, 0.98 }, { 0.92, 0.82 }, { 1, 0.6 }, { 1, 0 },
  },
  parts = {
    -- Black cladding round the arches and along the sills.
    { BLACK, pair = { 0.82, 0.92, 0.8, 0.98, 0.44, 0.99, 0.36, 0.93, 0.36, 0.89, 0.44, 0.94, 0.78, 0.93 } },
    { BLACK, pair = { -0.28, 0.93, -0.36, 1, -0.76, 1, -0.82, 0.95, -0.78, 0.92, -0.72, 0.95, -0.38, 0.95, -0.28, 0.89 } },
    { TRIM, pair = { 0.36, 0.89, 0.36, 0.93, -0.28, 0.93, -0.28, 0.89 } },
    -- Facets: the bonnet folds along two hard creases.
    { SHADE, pair = { 0.96, 0.58, 0.8, 0.9, 0.4, 0.78, 0.46, 0.64 } },
    { SEAM, trace = { 0.96, 0.46, 0.44, 0.66 } },
    { SEAM, trace = { 0.9, 0.2, 0.48, 0.26 } },
    -- Grille and the sharp lamps in their black housings.
    { BLACK, across = { 1, 0.46, 0.95, 0.5, 0.92, 0.3 } },
    { BLACK, pair = { 0.985, 0.6, 0.92, 0.78, 0.8, 0.92, 0.8, 0.72, 0.9, 0.56 } },
    { LAMP, pair = { 0.95, 0.62, 0.9, 0.74, 0.82, 0.86, 0.85, 0.72 } },
    -- Raked screen, and side glass drawn in towards the tail.
    { GLASS, across = { 0.4, 0.14, 0.37, 0.72, 0.09, 0.56, 0.12, 0.14 } },
    { SHEEN, solo = { 0.33, 0.52, 0.35, 0.16, 0.16, 0.1, 0.14, 0.38 } },
    { GLASS, pair = { 0.32, 0.76, 0.07, 0.61, -0.14, 0.6, -0.14, 0.76 } },
    { GLASS, pair = { -0.19, 0.76, -0.19, 0.59, -0.5, 0.48, -0.6, 0.62 } },
    { SEAM, trace = { 0.06, 0.58, -0.48, 0.46 } },
    -- Long glass roof, roof spoiler and a small rear screen.
    { GLASS, across = { 0.0, 0.32, -0.38, 0.27 } },
    { BLACK, across = { -0.47, 0.46, -0.52, 0.45 } },
    { GLASS, across = { -0.55, 0.43, -0.76, 0.34 } },
    -- Crease over the hips, the tail lamps and the bar between them.
    { SEAM, trace = { -0.3, 0.82, -0.7, 0.86, -0.9, 0.6 } },
    { BLACK, across = { -0.985, 0.6, -0.95, 0.62 } },
    { TAIL, pair = { -0.99, 0.5, -0.95, 0.84, -0.86, 0.92, -0.9, 0.76, -0.965, 0.5 } },
    { BLACK, pair = { 0.32, 0.92, 0.32, 1.08, 0.26, 1.08, 0.26, 0.92 } },
  },
}

return plans
