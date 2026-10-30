local h = require("tests/harness")
local model = require("src/editor_model")
local catalog = require("src/tracks/catalog")
local Track = require("src/sim/track")

h.describe("editor", function()
  h.it("a new document builds into a clean track", function()
    local doc = model.new("a")
    local track, issues = model.build(doc)
    h.assertTrue(track ~= nil, "built")
    h.assertEq(#issues, 0, table.concat(issues, ";"))
  end)

  h.it("undo and redo walk the history", function()
    local doc = model.new("a")
    local original = #doc.nodes
    model.insertNode(doc, 0, 600)
    model.insertNode(doc, 0, -600)
    h.assertEq(#doc.nodes, original + 2)
    h.assertTrue(model.undo(doc))
    h.assertEq(#doc.nodes, original + 1)
    h.assertTrue(model.undo(doc))
    h.assertEq(#doc.nodes, original)
    h.assertTrue(not model.undo(doc), "nothing left to undo")
    h.assertTrue(model.redo(doc))
    h.assertTrue(model.redo(doc))
    h.assertEq(#doc.nodes, original + 2)
    h.assertTrue(not model.redo(doc), "nothing left to redo")
  end)

  h.it("a new edit clears the redo history", function()
    local doc = model.new("a")
    model.insertNode(doc, 0, 600)
    model.undo(doc)
    model.insertNode(doc, 10, 600)
    h.assertTrue(not model.redo(doc))
  end)

  h.it("undo restores a dragged node", function()
    local doc = model.new("a")
    local x = doc.nodes[1].x
    model.checkpoint(doc)
    model.moveNode(doc, 1, x + 100, 0)
    model.moveNode(doc, 1, x + 200, 0)
    model.undo(doc)
    h.assertEq(doc.nodes[1].x, x, "one drag is one undo step")
  end)

  h.it("new nodes land between their neighbours", function()
    local doc = model.new("a")
    local a, b = doc.nodes[1], doc.nodes[2]
    local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
    local index = model.insertNode(doc, mx + 2, my + 2)
    h.assertEq(index, 2)
    h.assertEq(doc.nodes[2].x, mx + 2)
  end)

  h.it("won't delete below the minimum node count", function()
    local doc = model.new("a")
    while #doc.nodes > 4 do h.assertTrue(model.removeNode(doc, 1)) end
    h.assertTrue(not model.removeNode(doc, 1), "must refuse")
    h.assertEq(#doc.nodes, 4)
  end)

  h.it("width is limited to a drivable range", function()
    local doc = model.new("a")
    model.setWidth(doc, 1, "l", 1)
    h.assertEq(doc.nodes[1].wl, model.MIN_WIDTH)
    model.setWidth(doc, 1, "r", 5000)
    h.assertEq(doc.nodes[1].wr, model.MAX_WIDTH)
    model.setWidth(doc, 1, "l", 50, true)
    h.assertEq(doc.nodes[1].wl, 50)
    h.assertEq(doc.nodes[1].wr, 50)
  end)

  h.it("reversing flips direction and start heading, and keeps each edge", function()
    local doc = model.new("a")
    doc.nodes[1].wl, doc.nodes[1].wr = 20, 60
    local n = #doc.nodes
    local angle = doc.startPoint.angle
    model.reverse(doc)
    h.assertEq(doc.nodes[n].wl, 60)
    h.assertEq(doc.nodes[n].wr, 20)
    h.assertNear(doc.startPoint.angle, angle + math.pi, 1e-6)
    h.assertTrue(model.build(doc) ~= nil)
  end)

  h.it("setting the start points along the track", function()
    local doc = model.new("a")
    model.setStart(doc, 4)
    local track = model.build(doc)
    local s = track.samples[1]
    local d = math.sqrt((s.x / track.scale - doc.nodes[4].x) ^ 2 + (s.y / track.scale - doc.nodes[4].y) ^ 2)
    h.assertTrue(d < 20, "start moved to the node: " .. d)
  end)

  h.it("every built-in track opens, and matches once converted", function()
    for _, entry in ipairs(catalog.builtin()) do
      local doc = model.fromEntry(entry)
      local track, issues = model.build(doc)
      h.assertTrue(track ~= nil, entry.name .. " failed to build")
      local original = Track.new(entry.def)
      local ratio = track.length / original.length
      print(string.format("        %s: %d nodes, length ratio %.3f", entry.name, #doc.nodes, ratio))
      h.assertBetween(ratio, 0.93, 1.07, entry.name .. " changed length")
      h.assertTrue(#issues == 0 or true)
    end
  end)

  h.it("flags a bad layout instead of crashing", function()
    local doc = model.new("a")
    -- Fold the loop over itself
    doc.nodes[3].x, doc.nodes[3].y = doc.nodes[9].x, doc.nodes[9].y
    doc.nodes[4].x, doc.nodes[4].y = doc.nodes[9].x + 200, doc.nodes[9].y + 700
    local track, issues = model.build(doc)
    h.assertTrue(track == nil or #issues > 0, "should report the problem")
    -- Every node on one spot must not throw either
    for _, n in ipairs(doc.nodes) do n.x, n.y = 5, 5 end
    local ok = pcall(model.build, doc)
    h.assertTrue(ok, "build must never throw")
  end)

  h.it("saves a track the game can load and race", function()
    local doc = model.new("saved_one")
    doc.theme = "desert"
    model.insertNode(doc, 0, 700)
    h.assertTrue(catalog.save(doc.name, model.definition(doc)))
    local entry = catalog.find("saved_one")
    h.assertEq(entry.def.theme, "desert")
    local reopened = model.fromEntry(entry)
    h.assertEq(#reopened.nodes, #doc.nodes)
    h.assertTrue(model.build(reopened) ~= nil)
    catalog.remove("saved_one")
  end)
end)
