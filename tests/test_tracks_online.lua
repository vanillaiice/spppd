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

  h.it("names a new track after its title, without taking a name in use", function()
    h.assertEq(catalog.uniqueName("Hill & Dale!"), "hill_dale")
    h.assertEq(catalog.uniqueName("MIRAGE"), "mirage_2", "a built-in's name is taken")
    h.assertEq(catalog.uniqueName("!!!"), "shared_track")
  end)

  h.it("reads the list from the server the settings name, at its host", function()
    local settings = require("src.settings")
    local before = settings.server
    settings.server = "spppd.xyz"
    h.assertEq(online.url(), "https://spppd.xyz/api/tracks")
    settings.server = "race.example.org:9000"
    h.assertEq(online.url(), "https://race.example.org/api/tracks", "the port is the relay's")
    settings.server = before
  end)

  h.it("without HTTPS, says so instead of hanging on LOADING", function()
    local net = require("src.net_http")
    local get = net.get
    net.get = function(_, done) done(nil, "no https") end
    online.fetch()
    net.get = get
    h.assertEq(online.status, "error")
    h.assertEq(online.message, "This version can't fetch tracks")
  end)
end)
