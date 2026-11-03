-- Finds tracks: the built-ins in src/tracks plus anything saved from the
-- editor into the save directory.
local wire = require("src/tracks/wire")

local catalog = {}

local BUILTIN = { "mirage", "highlands", "harbour", "boat", "speedway", "temple", "riviera", "ardennes", "touge", "oasis" }
local USER_DIR = "tracks"

-- The menus ask for the list every frame, and reading it runs every saved file.
-- Kept until something can have changed the folder, so the same file keeps the
-- same `def` table until then.
local userEntries

local function loadDefinition(path)
  local loaded, chunk = pcall(love.filesystem.load, path)
  if not loaded or not chunk then return nil end
  setfenv(chunk, {})
  local ok, def = pcall(chunk)
  if ok and type(def) == "table" then return def end
  return nil
end

function catalog.builtin()
  local manifest = require("src/tracks/manifest")
  local out = {}
  for _, name in ipairs(BUILTIN) do
    if manifest[name] then
      out[#out + 1] = { name = name, title = manifest[name].title or name:upper(), def = manifest[name], builtin = true }
    end
  end
  return out
end

function catalog.user()
  if userEntries then return userEntries end
  local out = {}
  userEntries = out
  if not love.filesystem.getInfo(USER_DIR) then return out end
  for _, file in ipairs(love.filesystem.getDirectoryItems(USER_DIR)) do
    local name = file:match("^(.+)%.lua$")
    if name then
      local def = loadDefinition(USER_DIR .. "/" .. file)
      -- Old innerWall/outerWall files from v1 are skipped; those tracks are built in now.
      if def and (def.nodes or def.left) then
        out[#out + 1] = { name = name, title = def.title or name:upper(), def = def }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function catalog.refresh()
  userEntries = nil
end

function catalog.all()
  local out = catalog.builtin()
  for _, entry in ipairs(catalog.user()) do out[#out + 1] = entry end
  return out
end

function catalog.find(name)
  for _, entry in ipairs(catalog.all()) do
    if entry.name == name then return entry end
  end
  return nil
end

-- A track's shape as text, and a hash of that text. Two players are on the same
-- road when their hashes match, whatever the tracks are called.
local fingerprints = setmetatable({}, { __mode = "k" })
function catalog.fingerprint(def)
  local known = fingerprints[def]
  if not known then
    local text = wire.encode(def)
    local digest = love.data.encode("string", "hex", love.data.hash("md5", text))
    known = { text = text, hash = digest:sub(1, 16) }
    fingerprints[def] = known
  end
  return known.text, known.hash
end

function catalog.findByHash(hash)
  for _, entry in ipairs(catalog.all()) do
    local _, found = catalog.fingerprint(entry.def)
    if found == hash then return entry end
  end
  return nil
end

-- Writes a spline definition to the save directory.
function catalog.save(name, def)
  love.filesystem.createDirectory(USER_DIR)
  local lines = { "return {" }
  lines[#lines + 1] = string.format("  title = %q,", def.title or name:upper())
  lines[#lines + 1] = string.format("  theme = %q,", def.theme or "meadow")
  if def.scale then lines[#lines + 1] = string.format("  scale = %.2f,", def.scale) end
  lines[#lines + 1] = "  nodes = {"
  for _, n in ipairs(def.nodes) do
    lines[#lines + 1] = string.format("    {x = %.1f, y = %.1f, wl = %.1f, wr = %.1f},", n.x, n.y, n.wl, n.wr)
  end
  lines[#lines + 1] = "  },"
  if def.startPoint then
    lines[#lines + 1] = string.format("  startPoint = {x = %.1f, y = %.1f, angle = %.3f},",
      def.startPoint.x, def.startPoint.y, def.startPoint.angle or 0)
  end
  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  catalog.refresh()
  return love.filesystem.write(USER_DIR .. "/" .. name .. ".lua", table.concat(lines, "\n"))
end

function catalog.remove(name)
  catalog.refresh()
  return love.filesystem.remove(USER_DIR .. "/" .. name .. ".lua")
end

return catalog
