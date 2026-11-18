-- Tracks passed around by hand: as a file of the same text online races send
-- (src/tracks/wire.lua), or as a code, one line of that text deflated and base64'd,
-- for the clipboard. Importing goes through wire.decode, so a code from a stranger is
-- held to the same limits as a track from another player online.
local wire = require("src.tracks.wire")

local share = {}

share.PREFIX = "SPPPD-TRACK:"
-- A deflated stream can inflate about a thousand times over, so a cap on the code
-- caps what a bad one can make the game unpack. A 1500-node track comes to ~30 KB.
share.MAX_CODE = 40000

-- A track file's contents: the plain wire text, which can be read and edited.
function share.text(def)
  return wire.encode(def) .. "\n"
end

function share.export(def)
  local text = wire.encode(def)
  local packed = love.data.compress("string", "zlib", text, 9)
  return share.PREFIX .. love.data.encode("string", "base64", packed)
end

-- Returns a definition Track.new can take, or nil and why not. Takes a code, or a
-- track's plain wire text.
function share.import(text)
  if type(text) ~= "string" then return nil, "nothing to import" end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "nothing to import" end
  if text:sub(1, #share.PREFIX):upper() == share.PREFIX then
    if #text > share.MAX_CODE then return nil, "code too long" end
    local body = text:sub(#share.PREFIX + 1):gsub("%s", "")
    if not body:match("^[%w%+/]+=*$") then return nil, "not a track code" end
    local ok, raw = pcall(love.data.decode, "string", "base64", body)
    if not ok or not raw then return nil, "not a track code" end
    local inflated
    ok, inflated = pcall(love.data.decompress, "string", "zlib", raw)
    if not ok or not inflated then return nil, "not a track code" end
    text = inflated
  end
  -- Line endings from a chat window or a Windows notepad.
  text = text:gsub("\r\n?", "\n")
  return wire.decode(text)
end

return share
