local h = require("tests.harness")
local json = require("src.lib.json")
local model = require("src.editor_model")
local catalog = require("src.tracks.catalog")
local share = require("src.tracks.share")
local online = require("src.tracks.online")

-- A track as someone would send it in from the editor.
local function sent(title)
  local doc = model.new("sent")
  doc.title, doc.author = title, "BOB"
  model.insertNode(doc, 0, 640)
  return model.definition(doc)
end

local function reply(tracks)
  return json.encode({ tracks = tracks })
end

h.describe("tracks online", function()
  h.it("reads the list, and leaves out what isn't a track", function()
    local def = sent("ONLINE LOOP")
    local tracks = online.parse(reply({
      { id = 4, title = "ONLINE LOOP", author = "BOB", theme = "meadow", metres = 2140,
        outline = { { 0, 0 }, { 100, 50 }, { "x", 3 } }, code = share.export(def), added = "2026-11-18" },
      { id = 5, title = "BAD", code = "SPPPD-TRACK:nope" },
      { id = 6, title = "NO CODE" },
    }))
    h.assertEq(#tracks, 1, "only the real one")
    local t = tracks[1]
    h.assertEq(t.title, "ONLINE LOOP")
    h.assertEq(t.author, "BOB")
    h.assertEq(t.metres, 2140)
    h.assertEq(t.added, "2026-11-18")
    h.assertEq(#t.outline, 2, "a broken point is dropped")
    h.assertTrue(online.parse("not json") == nil, "not a list")
    h.assertTrue(online.parse(json.encode({ nope = true })) == nil, "no tracks field")
  end)

  h.it("saves a track once, as the same road, and knows it has it", function()
    local def = sent("TAKEN LOOP")
    local t = online.parse(reply({ { id = 1, code = share.export(def) } }))[1]
    h.assertTrue(not online.have(t), "not had yet")
    local name = online.take(t)
    h.assertTrue(name ~= nil, "saved")
    catalog.refresh()
    local entry = online.have(t)
    h.assertTrue(entry ~= nil, "found again by its shape, after a reload")
    h.assertEq(entry.name, name)
    h.assertEq(entry.author, "BOB", "the maker's name is kept")
    h.assertEq(online.take(t), name, "taking it again doesn't make a copy")
    catalog.remove(name)
  end)

  h.it("knows it has a track with runoff once it's taken (MONTE CARLO GP)", function()
    local def = sent("RUNOFF LOOP")
    def.runoff = 4.5
    def.scale = 2.5
    local t = online.parse(reply({ { id = 2, code = share.export(def) } }))[1]
    local name = online.take(t)
    catalog.refresh()
    h.assertTrue(online.have(t) ~= nil, "GOT after saving, not GET again")
    h.assertEq(catalog.find(name).def.runoff, 4.5, "the runoff is saved")
    h.assertEq(online.take(t), name, "no second copy")
    catalog.remove(name)
  end)

  h.it("keeps the runoff through the editor", function()
    local def = sent("EDITED RUNOFF")
    def.runoff = 6
    local doc = model.fromEntry({ name = "edited_runoff", title = def.title, def = def })
    h.assertEq(model.definition(doc).runoff, 6)
  end)

  h.it("deletes saved tracks, never the built-ins", function()
    local t = online.parse(reply({ { id = 3, code = share.export(sent("GONE LOOP")) } }))[1]
    local name = online.take(t)
    h.assertTrue(catalog.find(name) ~= nil, "saved")
    h.assertTrue(catalog.remove(name), "deleted")
    h.assertTrue(catalog.find(name) == nil, "gone from the list")
    h.assertTrue(not online.have(t), "GET again")
    h.assertTrue(not catalog.remove("mirage"), "a built-in stays")
    h.assertTrue(catalog.find("mirage") ~= nil)
    h.assertTrue(not catalog.remove("../settings"), "only a track's own file")
  end)

  h.it("names a new track after its title, without taking a name in use", function()
    h.assertEq(catalog.uniqueName("Hill & Dale!"), "hill_dale")
    h.assertEq(catalog.uniqueName("MIRAGE"), "mirage_2", "a built-in's name is taken")
    h.assertEq(catalog.uniqueName("!!!"), "shared_track")
  end)

  h.it("finds the tracks where the relay says, or at https://HOST", function()
    h.assertEq(online.webBase("https://spppd.xyz/", "spppd.xyz"), "https://spppd.xyz")
    h.assertEq(online.webBase("http://:8081", "192.168.1.5"), "http://192.168.1.5:8081", "no host: the relay's")
    h.assertEq(online.webBase("http://:8081", "::1"), "http://[::1]:8081", "IPv6 in brackets")
    h.assertEq(online.webBase("http://", "home.lan"), "http://home.lan")
    h.assertEq(online.webBase("http://other.example:9/x", "a"), "http://other.example:9/x")
    h.assertTrue(online.webBase("ftp://x", "a") == nil, "only http and https")
    h.assertTrue(online.webBase("https://a b", "a") == nil, "one address only")
    h.assertEq(online.hostOf("http://[fd00::5]:8081/x"), "fd00::5")
    h.assertEq(online.hostOf("https://spppd.xyz:443"), "spppd.xyz")
  end)

  h.it("knows a home network from the internet", function()
    local net = require("src.net_http")
    for _, host in ipairs({ "localhost", "127.0.0.1", "10.100.0.1", "172.16.4.2", "192.168.1.5",
      "169.254.3.3", "100.101.2.3", "::1", "[::1]", "fd12:3456::1", "fe80::1", "box.local", "pi.lan" }) do
      h.assertTrue(net.isLocal(host), host .. " is local")
    end
    for _, host in ipairs({ "spppd.xyz", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1",
      "2001:db8::1", "999.168.1.1", "local", "notlocal.xyz" }) do
      h.assertTrue(not net.isLocal(host), host .. " isn't local")
    end
  end)

  -- The relay's answer and the web reply, as the worker thread would give them.
  local function fake(answer, post)
    local net = require("src.net_http")
    local saved = { net.askWeb, net.get, net.post }
    local seen = {}
    net.askWeb = function(host, port, done) seen.asked = host .. ":" .. port done(answer) end
    net.get = function(url, done) seen.url = url done(reply({})) end
    net.post = function(url, body, done) seen.url, seen.body = url, body post(done) end
    return seen, function() net.askWeb, net.get, net.post = saved[1], saved[2], saved[3] end
  end

  h.it("reads the list from the server the settings name, where its relay says", function()
    local settings = require("src.settings")
    local before = settings.server
    settings.server = "old.example.org:9000"
    local seen, undo = fake(nil)
    online.fetch()
    h.assertEq(seen.asked, "old.example.org:9000", "the relay is asked")
    h.assertEq(seen.url, "https://old.example.org/api/tracks", "no answer: HTTPS at its host")
    h.assertEq(online.status, "ready")
    undo()
    settings.server = "192.168.1.5"
    seen, undo = fake("http://:8081")
    online.fetch()
    h.assertEq(seen.url, "http://192.168.1.5:8081/api/tracks", "a relay at home, in plain HTTP")
    undo()
    settings.server = "notracks.example.org"
    seen, undo = fake("")
    online.fetch()
    h.assertEq(online.status, "error")
    h.assertEq(online.message, "notracks.example.org has no tracks")
    undo()
    settings.server = before
  end)

  h.it("sends a track in, but not over plain HTTP past the home network", function()
    local settings = require("src.settings")
    local before = settings.server
    local def = sent("SENT LOOP")
    settings.server = "10.0.0.2"
    local seen, undo = fake("http://:8081", function(done)
      done(json.encode({ id = 3, message = "Thanks!" }), nil, 202)
    end)
    local ok, message
    online.send(def, "BOB", "bob@example.org", function(a, b) ok, message = a, b end)
    h.assertTrue(ok, "sent")
    h.assertEq(message, "Sent. It shows in TRACKS ONLINE once it's been checked")
    h.assertEq(seen.url, "http://10.0.0.2:8081/api/tracks")
    local body = json.decode(seen.body)
    h.assertEq(body.author, "BOB")
    h.assertEq(body.contact, "bob@example.org")
    h.assertEq(share.import(body.track).title, "SENT LOOP", "the track goes as its code")
    undo()

    settings.server = "203.0.113.7"
    seen, undo = fake("http://:8081", function() error("shouldn't post") end)
    online.send(def, "", "", function(a, b) ok, message = a, b end)
    h.assertTrue(not ok, "refused")
    h.assertEq(message, "203.0.113.7 has no HTTPS, so tracks can't be sent to it from here")
    undo()

    settings.server = "spppd.example.org"
    seen, undo = fake("https://spppd.example.org", function(done)
      done(nil, "HTTP 429", 429, json.encode({ error = "That's enough tracks for now" }))
    end)
    online.send(def, "", "", function(a, b) ok, message = a, b end)
    h.assertTrue(not ok)
    h.assertEq(message, "That's enough tracks for now", "the server's reason")
    undo()
    settings.server = before
  end)

  h.it("without HTTPS, says so instead of hanging on LOADING", function()
    local net = require("src.net_http")
    local ask = net.askWeb
    net.askWeb = function(_, _, done) done(nil, "no https") end
    online.fetch()
    net.askWeb = ask
    h.assertEq(online.status, "error")
    h.assertEq(online.message, "This version can't fetch tracks")
  end)
end)
