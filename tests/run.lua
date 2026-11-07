local harness = require("tests/harness")

local SUITES = { "tests/test_track", "tests/test_dynamics", "tests/test_slipstream", "tests/test_feel", "tests/test_race", "tests/test_support", "tests/test_touch", "tests/test_editor", "tests/test_network", "tests/test_cheats", "tests/test_damage", "tests/test_split", "tests/test_controls", "tests/test_account" }

return function(filter)
  io.stdout:setvbuf("no")
  jit.off()
  harness.TIME_LIMIT = tonumber(os.getenv("SPPPD_TEST_LIMIT")) or harness.TIME_LIMIT
  harness.filter = filter
  for _, name in ipairs(SUITES) do
    if love.filesystem.getInfo(name .. ".lua") then require(name) end
  end
  return harness.report()
end
