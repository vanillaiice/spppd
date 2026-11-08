-- Who is on the boards along the fences. Text and colour only, no pictures.
--
-- A sponsor is { text = "...", board = "#rrggbb", ink = "#rrggbb" }: up to 16
-- capitals, digits, spaces and . - & ! ', on a board of one colour. ink, the
-- lettering, may be left out for black or white, whichever reads better.
--
-- Every board has an address: a built-in track's name and the board's number,
-- counted from the start line by src/render/boards.lua. A board sold on its own
-- goes in spots; every other board takes the next sponsor in the pool.
local sponsors = {}

sponsors.MAX_TEXT = 16

-- Made up, every one of them.
sponsors.pool = {
  { text = "TURBO COLA", board = "#E8202A", ink = "#FFFFFF" },
  { text = "GRIP TYRES", board = "#141820", ink = "#F5C518" },
  { text = "BOOST BURGER", board = "#F5C518", ink = "#141820" },
  { text = "SPPPD.XYZ", board = "#F2EFE6", ink = "#E8202A" },
  { text = "CHEQUER BANK", board = "#1E5BD8", ink = "#FFFFFF" },
  { text = "KERB COFFEE", board = "#6B3B22", ink = "#F2EFE6" },
  { text = "PIXEL FUEL", board = "#18B46A", ink = "#FFFFFF" },
  { text = "DRIFT DONUTS", board = "#F06BA8", ink = "#FFFFFF" },
  { text = "GRIDLOCK OIL", board = "#2A2D36", ink = "#F2EFE6" },
  { text = "PITSTOP PIZZA", board = "#F28C1E", ink = "#FFFFFF" },
  { text = "SPPPD.XYZ", board = "#141820", ink = "#F2EFE6" },
  { text = "REV LIMIT SODA", board = "#8A2BE2", ink = "#F5C518" },
  { text = "SLIPSTREAM AIR", board = "#E9F2FB", ink = "#1E5BD8" },
  { text = "LAP WATCHES", board = "#C9A227", ink = "#141820" },
}

-- Boards sold on their own, by built-in track name and board number:
--   mirage = { [3] = { text = "...", board = "#rrggbb" } },
-- SPPPD_SPOTS=1 shows each board's address in place of its sponsor.
sponsors.spots = {}

local function parseColor(hex)
  local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then return nil end
  return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 }
end

-- nil when the sponsor will do, or what's wrong with it.
function sponsors.check(entry)
  if type(entry) ~= "table" then return "not a table" end
  local text = entry.text
  if type(text) ~= "string" or #text == 0 then return "no text" end
  if #text > sponsors.MAX_TEXT then return "text longer than " .. sponsors.MAX_TEXT .. ": " .. text end
  if text:find("[^A-Z0-9 %.%-&!']") then return "text has a character the font can't show: " .. text end
  if not parseColor(entry.board) then return "board colour isn't #rrggbb: " .. tostring(entry.board) end
  if entry.ink ~= nil and not parseColor(entry.ink) then return "ink colour isn't #rrggbb: " .. tostring(entry.ink) end
  return nil
end

-- Black on a light board, white on a dark one.
local function readableInk(c)
  local light = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
  return light > 0.55 and { 0.08, 0.08, 0.1 } or { 1, 1, 1 }
end

-- The board as drawn: { text, board = {r, g, b}, ink = {r, g, b} }.
function sponsors.paint(entry)
  local board = parseColor(entry.board) or { 1, 1, 1 }
  return { text = entry.text, board = board, ink = entry.ink and parseColor(entry.ink) or readableInk(board) }
end

-- Each track starts somewhere else in the pool, so the start line doesn't
-- have the same sponsor everywhere.
local function offset(trackName)
  local sum = 0
  for i = 1, #(trackName or "") do sum = sum + trackName:byte(i) * i end
  return sum
end

-- The sponsor on board n of a built-in track (trackName nil for one of the
-- player's own, which only shows the pool).
function sponsors.forBoard(trackName, n)
  local sold = trackName and sponsors.spots[trackName] and sponsors.spots[trackName][n]
  if sold then return sold end
  local pool = sponsors.pool
  return pool[(n + offset(trackName)) % #pool + 1]
end

return sponsors
