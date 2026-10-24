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

test("Spotify's sign-in row: Sign in, and once signed in, Sign out", () => {
  const out = row(Settings.shown({ spotify: { setUp: true } }), "spotifyLogin")
  assert.equal(out.button, "Sign in")
  const signed = row(Settings.shown({ spotify: { setUp: true, signedIn: true } }), "spotifyLogin")
  assert.equal(signed.button, "Sign out")
  assert.equal(signed.label, "Signed in to Spotify")
  assert.equal(signed.type, "action")
})

test("the file-only settings aren't on the screen, and still apply from the file", () => {
  const all = { local: { setUp: true }, spotify: { setUp: true }, sxm: { setUp: true }, apple: { setUp: true }, sound: { setUp: true } }
  const fileOnly = ["socket", "spotifyService", "sxmService", "radioBrowser", "appleTokenFile", "appleBridge", "appleStream", "appleRejoin"]
  assert.ok(!keys(Settings.shown(all)).some(k => fileOnly.includes(k)))
  assert.ok(!Settings.groups.some(g => g.title === "ADVANCED"))
  assert.equal(Settings.value({ socket: "/run/mpd/socket" }, {}, "socket", ""), "/run/mpd/socket")
  assert.equal(Settings.value({}, { sxmService: "http://127.0.0.1:9" }, "sxmService", ""), "http://127.0.0.1:9")
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

test("defaults cover the stored settings only: a source's switch, not the sound output's line", () => {
  assert.equal(Settings.defaults.tuiCommand, "ncmpcpp")
  assert.equal(Settings.defaults.maxLabelWidth, 300)
  assert.equal(Settings.defaults.spotify, false)
  assert.ok(!("sxmPassword" in Settings.defaults) && !("musicFolder" in Settings.defaults) && !("sound" in Settings.defaults))
})

const keys = rows => rows.map(r => r.key)
const row = (rows, key) => rows.find(r => r.key === key)

test("a source not set up: its Set up button, and none of its other rows", () => {
  const rows = Settings.shown({ local: { setUp: true } })
  const spotify = row(rows, "spotify")
  assert.equal(spotify.type, "action")
  assert.equal(spotify.button, "Set up…")
  assert.match(spotify.description, /Premium/)
  for (const key of ["spotifyClient", "soloistKey", "spotifyLogin", "spotifyRemove", "spotifyUpdate", "sxmPassword",
    "bridgeToken", "appleRemove", "soundRemove"])
    assert.ok(!keys(rows).includes(key), key)
  assert.equal(row(rows, "sound").button, "Set up…")
  assert.ok(keys(rows).includes("musicFolder") && keys(rows).includes("radio"))
})

test("a source set up: its switch, its settings and Remove; the sound output a line", () => {
  const rows = Settings.shown({ spotify: { setUp: true }, sound: { setUp: true } })
  assert.equal(row(rows, "spotify").type, "boolean")
  assert.ok(Settings.stored(row(rows, "spotify")))
  assert.ok(["spotifyClient", "soloistKey", "spotifyLogin", "spotifyRemove"].every(k => keys(rows).includes(k)))
  assert.ok(!keys(rows).includes("spotifyUpdate"))
  assert.equal(row(rows, "sound").type, "info")
  assert.ok(keys(rows).includes("soundRemove"))
  assert.equal(row(rows, "siriusXM").type, "action")
})

test("Fix while something's wrong, else Update while one waits", () => {
  const fix = row(Settings.shown({ sxm: { setUp: true, attention: "Can't reach omarock-sxm", update: true } }), "sxmUpdate")
  assert.equal(fix.button, "Fix…")
  assert.equal(fix.label, "Set SiriusXM up again")
  const update = row(Settings.shown({ spotify: { setUp: true, update: "Soloist stops working in 9 days" } }), "spotifyUpdate")
  assert.equal(update.button, "Update…")
  assert.equal(update.description, "Soloist stops working in 9 days")
  assert.match(row(Settings.shown({ sound: { setUp: true, update: true } }), "soundUpdate").description, /sound output has changes to install/)
  assert.match(row(Settings.shown({ spotify: { setUp: true, update: true } }), "spotifyUpdate").description, /Spotify service/)
  assert.ok(!keys(Settings.shown({ spotify: { setUp: false, update: true } })).includes("spotifyUpdate"))
})

test("local music's Set up shows only while mpd can't be reached; every row is in a group", () => {
  assert.ok(keys(Settings.shown({ local: { setUp: false } })).includes("localSetUp"))
  assert.ok(!keys(Settings.shown({ local: { setUp: true } })).includes("localSetUp"))
  const grouped = Settings.groups.flatMap(g => g.keys)
  assert.deepEqual([...grouped].sort(), Settings.schema.map(f => f.key).sort())
  assert.deepEqual(Object.keys(Settings.pieces).sort(), ["apple", "local", "sound", "spotify", "sxm"])
})
