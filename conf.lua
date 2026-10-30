local function hasArg(name)
  for _, a in ipairs(arg or {}) do
    if a == name then return true end
  end
  return false
end

function love.conf(t)
  t.identity = "spppd"
  t.version = "11.5"
  t.window.title = "SPPPD"
  t.window.width = 1280
  t.window.height = 720
  t.window.minwidth = 640
  t.window.minheight = 480
  t.window.resizable = true
  t.window.highdpi = true
  t.window.vsync = 1
  t.window.msaa = 0
  t.modules.video = false

  -- `love . --test` runs the simulation tests without opening a window.
  if hasArg("--test") then
    t.identity = "spppd-test"
    t.window = nil
    t.modules.window = false
    t.modules.graphics = false
    t.modules.audio = false
  elseif hasArg("--visual") then
    t.identity = "spppd-test"
    t.window.vsync = 0
  end
end
