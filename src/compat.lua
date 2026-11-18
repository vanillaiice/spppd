-- The few places LÖVE 11 and 12 differ. The game runs on LÖVE 12, but the
-- browser build is love.js, which is LÖVE 11.4, so both must keep working.
local compat = {}

local major = love.getVersion()
compat.v12 = major >= 12

-- love.data.hash(alg, data) became hash("string", alg, data) in 12. Same digest.
function compat.hash(alg, data)
  if compat.v12 then return love.data.hash("string", alg, data) end
  return love.data.hash(alg, data)
end

-- Text objects became TextBatch in 12.
function compat.newTextBatch(font, text)
  local make = love.graphics.newTextBatch or love.graphics.newText
  return make(font, text)
end

-- 11's 2-D noise is 12's simplexNoise (to six places; 12 computes in doubles).
function compat.noise(x, y)
  return (love.math.simplexNoise or love.math.noise)(x, y)
end

-- 12 requires non-power-of-two textures, so the feature flag may not be there.
function compat.fullnpot()
  if compat.v12 then return true end
  return love.graphics.getSupported().fullnpot
end

-- A canvas's pixels back on the CPU.
function compat.readback(canvas)
  if love.graphics.readbackTexture then return love.graphics.readbackTexture(canvas) end
  return canvas:newImageData()
end

-- A mesh's vertex format, from { name, location, components } per attribute. 12
-- binds attributes by location; LÖVE's own are VertexPosition 0, VertexTexCoord 1
-- and VertexColor 2, so a shader's own start at 3.
function compat.vertexFormat(attributes)
  local out = {}
  for i, a in ipairs(attributes) do
    if compat.v12 then
      out[i] = { format = "floatvec" .. a[3], location = a[2] }
    else
      out[i] = { a[1], "float", a[3] }
    end
  end
  return out
end

-- The declarations a vertex shader needs for those attributes (only its own,
-- not LÖVE's).
function compat.attributeDeclarations(attributes)
  local lines = {}
  for _, a in ipairs(attributes) do
    if a[2] >= 3 then
      local kind = "vec" .. a[3]
      if compat.v12 then
        lines[#lines + 1] = string.format("layout (location = %d) in %s %s;", a[2], kind, a[1])
      else
        lines[#lines + 1] = string.format("attribute %s %s;", kind, a[1])
      end
    end
  end
  return table.concat(lines, "\n")
end

-- A shape fastened to a body, with what LÖVE 11 called a fixture's settings.
-- 11 makes the shape and then a fixture for it; in 12 the shape is the fixture.
-- kind is "Polygon", "Circle" or "Chain"; the rest are that shape's arguments.
function compat.attach(body, density, kind, ...)
  local new = love.physics["new" .. kind .. "Shape"]
  if not compat.v12 then
    return love.physics.newFixture(body, new(...), density or 1)
  end
  local shape = new(body, ...)
  if density and density ~= 1 then
    shape:setDensity(density)
    body:resetMassData()
  end
  return shape
end

-- Box2D 2.4 (LÖVE 12) made chains one-sided: they stop things on one side and
-- let them through from the other. Barriers must hold from both sides, so on 12
-- a chain goes in twice, once each way round. A chain keeps the smooth corners
-- that loose edges would lose, which is why it's not two-sided edges instead.
function compat.attachChain(body, loop, coords)
  local first = compat.attach(body, nil, "Chain", loop, coords)
  if not compat.v12 then return { first } end
  local back = {}
  for i = #coords - 1, 1, -2 do
    back[#back + 1] = coords[i]
    back[#back + 1] = coords[i + 1]
  end
  return { first, compat.attach(body, nil, "Chain", loop, back) }
end

return compat
