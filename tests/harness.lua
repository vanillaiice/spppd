-- A very small test runner. Tests register with `describe` / `it`.
local harness = { passed = 0, failed = 0, failures = {}, filter = nil, TIME_LIMIT = 120 }

local currentSuite = ""

function harness.describe(name, fn)
  currentSuite = name
  fn()
end

function harness.it(name, fn)
  local full = currentSuite .. " > " .. name
  if harness.filter and not full:lower():find(harness.filter:lower(), 1, true) then return end
  local startedAt = love.timer.getTime()
  -- A test that spins forever fails with a traceback instead of hanging the run.
  local deadline = os.clock() + harness.TIME_LIMIT
  debug.sethook(function()
    if os.clock() > deadline then
      debug.sethook()
      error("test ran past its time limit", 2)
    end
  end, "", 100000)
  local ok, err = xpcall(fn, debug.traceback)
  debug.sethook()
  local took = love.timer.getTime() - startedAt
  if ok then
    harness.passed = harness.passed + 1
    print(string.format("  ok    %s (%.2fs)", full, took))
  else
    harness.failed = harness.failed + 1
    harness.failures[#harness.failures + 1] = { name = full, err = err }
    print(string.format("  FAIL  %s\n        %s", full, tostring(err):gsub("\n", "\n        ")))
  end
end

function harness.assertTrue(value, message)
  if not value then error(message or "expected a true value", 2) end
end

function harness.assertEq(a, b, message)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", message or "values differ", tostring(b), tostring(a)), 2)
  end
end

function harness.assertNear(a, b, tolerance, message)
  if math.abs(a - b) > tolerance then
    error(string.format("%s: expected %s +/- %s, got %s", message or "not close enough",
      tostring(b), tostring(tolerance), tostring(a)), 2)
  end
end

function harness.assertBetween(value, low, high, message)
  if value < low or value > high then
    error(string.format("%s: expected %s..%s, got %s", message or "out of range",
      tostring(low), tostring(high), tostring(value)), 2)
  end
end

function harness.report()
  print(string.format("\n%d passed, %d failed", harness.passed, harness.failed))
  for _, f in ipairs(harness.failures) do print("  FAILED: " .. f.name) end
  return harness.failed == 0
end

return harness
