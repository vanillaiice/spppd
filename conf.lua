local function hasArg(name)
  for _, a in ipairs(arg or {}) do
    if a == name then return true end
  end
  return false
end

function love.conf(t)
  t.identity = "spppd"
  -- Made for LÖVE 12, and still runs on 11 (src/compat.lua), which the browser
  -- build is. Naming the other would make 11 stop at a warning box.
  local v12 = (love._version_major or 11) >= 12
  t.version = v12 and "12.0" or love._version
  t.window.title = "SPPPD"
  t.window.width = 1280
  t.window.height = 720
  t.window.minwidth = 640
  t.window.minheight = 480
  t.window.resizable = true
  -- 12 moved highdpi out of the window table.
  if v12 then
    t.highdpi = true
  else
    t.window.highdpi = true
  end
  -- OpenGL (GLES on phones), as on 11, or Metal on a Mac. 12 would rather have
  -- Vulkan, which the game isn't tried on, and which hangs at start where it
  -- can't show a picture.
  if v12 then t.graphics.excluderenderers = { "vulkan" } end
  t.window.vsync = 1
  t.window.msaa = 0
  t.modules.video = false
  -- Without this a phone's tilt sensor shows up as a joystick. 12 leaves it off.
  if not v12 then t.accelerometerjoystick = false end
  -- SPPPD_SIZE=576x1024 opens a fixed window of that size, e.g. portrait for Shorts.
  local w, h = (os.getenv("SPPPD_SIZE") or ""):match("^(%d+)x(%d+)$")
  if w then
    t.window.width, t.window.height = tonumber(w), tonumber(h)
    t.window.minwidth, t.window.minheight = 1, 1
    t.window.resizable = false
  end
  if love._os == "Android" or love._os == "iOS" then
    t.window.fullscreen = true
    -- A resizable window lets the phone rotate, which Android then letterboxes.
    t.window.resizable = false
  end

  -- `love . --test` runs the simulation tests without opening a window.
  if hasArg("--test") or hasArg("--sounds") then
    -- Each shard of a parallel run saves into its own folder.
    local shard = (os.getenv("SPPPD_TEST_SHARD") or ""):match("^(%d+)/")
    t.identity = shard and ("spppd-test-" .. shard) or "spppd-test"
    t.window = nil
    t.modules.window = false
    t.modules.graphics = false
    t.modules.audio = false
  elseif hasArg("--sound-cache") then
    -- Its own save folder, so a build never touches the player's.
    t.identity = "spppd-soundcache"
    t.window = nil
    t.modules.window = false
    t.modules.graphics = false
    t.modules.audio = false
  elseif hasArg("--visual") then
    t.identity = "spppd-test"
    t.window.vsync = 0
  end
end
