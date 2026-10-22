const test = require("node:test")
const assert = require("node:assert/strict")
const Settings = require("../Settings.js")

test("a value comes from settings.json, else the widget's settings, else its default", () => {
  assert.equal(Settings.value({ spotify: true }, { spotify: false }, "spotify"), true)
  assert.equal(Settings.value({}, { spotify: true }, "spotify"), true)
  assert.equal(Settings.value({ spotify: null }, {}, "spotify"), false)
  assert.equal(Settings.value(null, null, "lookup"), "Apple Music")
  assert.equal(Settings.value({}, {}, "socket", "/run/x"), "/run/x")
  assert.equal(Settings.value({ appleIdleStop: 0 }, { appleIdleStop: 60 }, "appleIdleStop"), 0)
})

test("the file parses to settings, or none; withValue changes one and keeps the rest", () => {
  const file = Settings.parse('{"radio": true, "theirs": 1}')
  assert.deepEqual(Settings.withValue(file, "spotify", false), { radio: true, theirs: 1, spotify: false })
  assert.deepEqual(file, { radio: true, theirs: 1 })
  assert.deepEqual(Settings.parse(""), {})
  assert.deepEqual(Settings.parse("not json"), {})
  assert.deepEqual(Settings.parse("[1]"), {})
  assert.deepEqual(Settings.withValue(null, "radio", false), { radio: false })
})

test("defaults cover the stored settings only", () => {
  assert.equal(Settings.defaults.tuiCommand, "ncmpcpp")
  assert.equal(Settings.defaults.maxLabelWidth, 300)
  assert.ok(!("sxmPassword" in Settings.defaults) && !("musicFolder" in Settings.defaults))
})

test("a source's rows show only while it's switched on, and every row is in a group", () => {
  const keys = rows => rows.map(r => r.key)
  assert.ok(!keys(Settings.shown({ sxm: false })).includes("sxmPassword"))
  assert.ok(keys(Settings.shown({ sxm: true })).includes("sxmPassword"))
  assert.ok(keys(Settings.shown({})).includes("musicFolder"))
  const grouped = Settings.groups.flatMap(g => g.keys)
  assert.deepEqual([...grouped].sort(), Settings.schema.map(f => f.key).sort())
})
