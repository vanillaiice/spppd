local h = require("tests/harness")
local account = require("src/account")
local settings = require("src/settings")
local socket = require("socket")

local KEY = string.char(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)

-- Points the account module at a file of its own and a server, then puts both back.
local function withAccount(server, file, run)
  local oldFile, oldServer = account.FILE, settings.server
  account.FILE, settings.server = file, server
  love.filesystem.remove(file)
  account.load()
  local ok, err = pcall(run)
  account.cancel()
  love.filesystem.remove(file)
  account.FILE, settings.server = oldFile, oldServer
  account.load()
  account.message = ""
  if not ok then error(err, 0) end
end

h.describe("account", function()
  -- The same key, message and proof are in server/drivers_test.go.
  h.it("proofs match the relay's", function()
    h.assertEq(account.base64url(KEY), "AAECAwQFBgcICQoLDA0ODw")
    h.assertEq(account.proofOf(KEY, "host|AbCdEfGhIjKlMnOpQrStUv"), "gbQf53MRd0ygIfyg4uDLEd")
  end)

  h.it("keys survive base64url and base32", function()
    for _ = 1, 20 do
      local raw = account.randomBytes(16)
      h.assertEq(account.unbase64url(account.base64url(raw)), raw)
      h.assertEq(account.unbase32(account.base32(raw), 16), raw)
    end
    h.assertTrue(account.randomBytes(16) ~= account.randomBytes(16), "keys differ")
    h.assertEq(account.unbase64url("not base64!"), nil)
  end)

  h.it("a recovery code reads back however it's typed", function()
    withAccount("test.invalid", "test-account.lua", function()
      local raw = account.randomBytes(16)
      love.filesystem.write(account.FILE, "return " .. settings.serialize({
        ["test.invalid"] = { id = 1042, name = "SPEEDY", key = account.base64url(KEY), recovery = account.base64url(raw) },
      }))
      account.load()
      local code = account.recoveryCode()
      h.assertTrue(code:match("^1042%-%u") ~= nil, code)
      local id, back = account.readCode(code)
      h.assertEq(id, 1042)
      h.assertEq(back, raw)
      -- Lower case, spaces, and 0 for O or 1 for I.
      id, back = account.readCode(" " .. code:lower():gsub("o", "0"):gsub("i", "1") .. " ")
      h.assertEq(id, 1042)
      h.assertEq(back, raw)
      h.assertEq(account.readCode("1042"), nil)
      h.assertEq(account.readCode("SPEEDY-ABCDE"), nil)
    end)
  end)

  h.it("names have the shape the server takes", function()
    for _, name in ipairs({ "BOB", "SPEED_DEMON", "A-1", "TWELVECHARSX" }) do
      h.assertEq(account.nameProblem(name), nil, name)
    end
    for _, name in ipairs({ "AB", "THIRTEENCHARS", "HAS SPACE", "PIPE|", "COMMA,", "COLON:" }) do
      h.assertTrue(account.nameProblem(name) ~= nil, name)
    end
  end)

  h.it("a driver is kept for each server, and a bad file is ignored", function()
    withAccount("a.example", "test-account.lua", function()
      love.filesystem.write(account.FILE, "return " .. settings.serialize({
        ["a.example"] = { id = 1001, name = "ONE", key = "k", recovery = "r" },
        ["b.example"] = { id = 1002, name = "TWO", key = "k", recovery = "r" },
        ["c.example"] = { id = "x" },
      }))
      account.load()
      h.assertEq(account.driver().name, "ONE")
      settings.server = "b.example"
      h.assertEq(account.driver().name, "TWO")
      settings.server = "c.example"
      h.assertEq(account.driver(), nil)
      love.filesystem.write(account.FILE, "os.exit()")
      account.load()
      h.assertEq(account.driver(), nil)
    end)
  end)

  h.it("a seat request carries no proof without a driver or a cookie", function()
    withAccount("a.example", "test-account.lua", function()
      local id, proof = account.seatFields("host", "COOKIE")
      h.assertEq(id, "")
      h.assertEq(proof, "")
      love.filesystem.write(account.FILE, "return " .. settings.serialize({
        ["a.example"] = { id = 1001, name = "ONE", key = account.base64url(KEY), recovery = "r" },
      }))
      account.load()
      id, proof = account.seatFields("host", nil)
      h.assertEq(proof, "")
      id, proof = account.seatFields("host", "AbCdEfGhIjKlMnOpQrStUv")
      h.assertEq(id, "1001")
      h.assertEq(proof, "gbQf53MRd0ygIfyg4uDLEd")
    end)
  end)
end)

-- Against a real relay, as make test-online runs it. The relay takes three
-- sign-ups an hour from one address, so these make two.
h.describe("network drivers", function()
  local function relay()
    local host, port = require("tests/relay").address()
    if not host then
      print("        skipped: " .. port)
      return nil
    end
    return host .. ":" .. port
  end

  local function wait(seconds)
    local deadline = socket.gettime() + seconds
    while account.busy and socket.gettime() < deadline do
      account.update(0.02)
      socket.sleep(0.01)
    end
    h.assertTrue(not account.busy, "the server should answer: " .. account.message)
  end

  h.it("a driver signs up, renames, moves to another device and is deleted", function()
    local server = relay()
    if not server then return end
    local name = "T" .. love.math.random(100000, 999999)
    withAccount(server, "test-account.lua", function()
      account.signUp(name:lower())
      wait(3)
      local driver = account.driver()
      h.assertTrue(driver and driver.name == name, account.message)
      local code = account.recoveryCode()

      account.refresh()
      wait(3)
      h.assertEq(account.profile.devices, 1)

      -- Someone else can't have the name.
      local mine = account.FILE
      account.FILE = "test-account-2.lua"
      love.filesystem.remove(account.FILE)
      account.load()
      account.signUp(name)
      wait(3)
      h.assertEq(account.driver(), nil)
      h.assertEq(account.message, "That name is taken")

      -- The recovery code signs this second device in.
      account.recover(code)
      wait(3)
      h.assertEq(account.driver().name, name, account.message)
      account.rename(name .. "X")
      wait(3)
      h.assertEq(account.driver().name, name .. "X", account.message)
      account.refresh()
      wait(3)
      h.assertEq(account.profile.devices, 2)
      account.signOut()
      wait(3)
      h.assertEq(account.driver(), nil)
      love.filesystem.remove(account.FILE)

      -- The first device hears about the rename, then deletes the driver.
      account.FILE = mine
      account.load()
      account.refresh()
      wait(3)
      h.assertEq(account.driver().name, name .. "X")
      h.assertTrue(account.message:find("changed your name") ~= nil, account.message)
      account.forget()
      wait(3)
      h.assertEq(account.driver(), nil)
      h.assertEq(account.message, "Driver deleted")
    end)
  end)

  h.it("rooms show the names of drivers who signed in", function()
    local server = relay()
    if not server then return end
    local host, port = server:match("^(.+):(%d+)$")
    port = tonumber(port)
    local name = "N" .. love.math.random(100000, 999999)
    withAccount(server, "test-account.lua", function()
      account.signUp(name)
      wait(3)
      local a = love.filesystem.load("src/network_manager.lua")()
      local code = "D" .. love.math.random(1000, 9999)
      a.connect(host, port, "host", code, { car = "rocket", paint = 1 },
        { def = require("src/tracks/catalog").builtin()[1].def, title = "T", laps = 1, time = "day" })
      -- The joiner has no driver: the account module is shared, so it signs out first.
      local deadline = socket.gettime() + 3
      while a.status ~= "lobby" and socket.gettime() < deadline do
        a.update(0.02)
        socket.sleep(0.01)
      end
      h.assertEq(a.status, "lobby")
      local saved = account.FILE
      account.FILE = "test-account-none.lua"
      account.load()
      local b = love.filesystem.load("src/network_manager.lua")()
      b.connect(host, port, "join", code, { car = "cyber", paint = 2 })
      deadline = socket.gettime() + 3
      while (b.status ~= "lobby" or not a.peers[2]) and socket.gettime() < deadline do
        a.update(0.02)
        b.update(0.02)
        socket.sleep(0.01)
      end
      h.assertEq(b.nameOf(1), name, "the joiner sees the host's name")
      h.assertEq(a.nameOf(1), name, "and the host its own")
      h.assertEq(a.nameOf(2), "P2", "a driver who didn't sign in is their seat")
      a.disconnect()
      b.disconnect()
      account.FILE = saved
      account.load()
      account.forget()
      wait(3)
    end)
  end)
end)
