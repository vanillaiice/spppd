-- The selectable cars, in menu order. Settings save a position in this list,
-- so new cars go on the end.
local garage = {
  require("src/entities/vehicles/hot_hatch"),
  require("src/entities/vehicles/4wd_monster"),
  require("src/entities/vehicles/rocket"),
  require("src/entities/vehicles/samurai"),
  require("src/entities/vehicles/big_bull"),
  require("src/entities/vehicles/muscle_monster"),
  require("src/entities/vehicles/cyber"),
}

function garage.byId(id)
  for _, spec in ipairs(garage) do
    if spec.id == id then return spec end
  end
  return garage[1]
end

return garage
