const test = require("node:test")
const assert = require("node:assert/strict")
const Setup = require("../Setup.js")
const Settings = require("../Settings.js")
const fs = require("node:fs")
const path = require("node:path")

test("each piece set up from the settings has a setup window", () => {
  for (const piece of ["spotify", "siriusxm", "apple-music", "sound"]) {
    assert.ok(Setup.pages[piece], piece)
    assert.ok(Setup.title(piece).startsWith("Set up "))
    assert.ok(Setup.pages[piece].after.length > 0)
  }
  assert.equal(Setup.title("sound"), "Set up omarock's sound output")
  // Every piece the settings set up, and nothing else.
  assert.deepEqual(Object.keys(Setup.pages).sort(), Object.values(Settings.pieces).filter(p => p).sort())
})

test("every account a window saves is one omarock-account takes", () => {
  const verbs = ["sxm-user", "sxm-password", "spotify-client", "soloist-key", "bridge-token", "apple-bridge"]
  for (const piece of Object.keys(Setup.pages))
    for (const f of Setup.fields(piece)) if (f.account) assert.ok(verbs.includes(f.account), f.account)
})

test("Spotify: Start setup waits for a Client ID that looks like one, and the Soloist key", () => {
  const id = "0123456789abcdef0123456789ABCDEF"
  assert.equal(Setup.blocker("spotify", Setup.initial("spotify", {}), {}), "Needs the app's Client ID")
  assert.equal(Setup.blocker("spotify", { spotifyClient: "abc", soloistKey: "k" }, {}), "A Client ID is 32 letters and digits")
  assert.equal(Setup.blocker("spotify", { spotifyClient: id, soloistKey: "" }, {}), "Needs the Soloist key")
  assert.equal(Setup.blocker("spotify", { spotifyClient: " " + id + " ", soloistKey: "k" }, {}), "")
  // A key that's set already: empty keeps it.
  assert.equal(Setup.blocker("spotify", { spotifyClient: id, soloistKey: "" }, { soloistKey: true }), "")
})

test("what's set already fills a line in; a secret starts empty", () => {
  const known = { spotifyClient: "0123456789abcdef0123456789abcdef", soloistKey: true, sxmUser: "me@example.com",
    sxmPassword: true, appleBridge: "http://100.64.0.10:8710" }
  assert.deepEqual(Setup.initial("spotify", known), { spotifyClient: known.spotifyClient, soloistKey: "" })
  assert.deepEqual(Setup.initial("siriusxm", known), { sxmTerms: false, sxmUser: "me@example.com", sxmPassword: "" })
  assert.equal(Setup.initial("apple-music", known).appleMac, "http://100.64.0.10:8710")
  assert.equal(Setup.initial("sound", {}, "alsa_output.speakers").output, "alsa_output.speakers")
  assert.equal(Setup.initial("sound", {}, "omarock").output, "")
})

test("the values saved first: what was typed, a line only if it changed", () => {
  const known = { sxmUser: "me@example.com", sxmPassword: true }
  assert.deepEqual(Setup.writes("siriusxm", { sxmTerms: true, sxmUser: "me@example.com", sxmPassword: " pass word " }, known),
    [["sxm-password", " pass word "]])
  assert.deepEqual(Setup.writes("siriusxm", { sxmTerms: true, sxmUser: " new@example.com ", sxmPassword: "" }, known),
    [["sxm-user", "new@example.com"]])
  assert.deepEqual(Setup.writes("apple-music", { appleMac: "100.64.0.10", bridgeToken: "t" }, {}),
    [["apple-bridge", "http://100.64.0.10:8710"], ["bridge-token", "t"]])
  assert.deepEqual(Setup.writes("apple-music", { appleMac: "http://100.64.0.10:8710", bridgeToken: "" },
    { appleBridge: "http://100.64.0.10:8710" }), [])
})

test("SiriusXM: the risk is ticked, and the login filled in", () => {
  assert.equal(Setup.blocker("siriusxm", { sxmTerms: false, sxmUser: "me", sxmPassword: "p" }, {}),
    "Needs a tick that you understand the risk")
  assert.equal(Setup.blocker("siriusxm", { sxmTerms: true, sxmUser: "", sxmPassword: "p" }, {}),
    "Needs your SiriusXM email or username")
  assert.equal(Setup.blocker("siriusxm", { sxmTerms: true, sxmUser: "me", sxmPassword: "p" }, {}), "")
  assert.deepEqual(Setup.args("siriusxm", { sxmTerms: true }), ["--yes", "terms"])
})

test("Apple Music: the Mac has to answer; a token typed has to be taken", () => {
  const values = { appleMac: "my-mac", bridgeToken: "", flac: true, mpris: false }
  assert.equal(Setup.blocker("apple-music", values, {}, {}), "Checking the bridge…")
  assert.equal(Setup.blocker("apple-music", values, {}, { appleMac: { kind: "bad", text: "Nothing answers" } }), "Nothing answers")
  const answers = { appleMac: { kind: "ok", text: "The bridge answers" } }
  // No token: the terminal asks for it.
  assert.equal(Setup.blocker("apple-music", values, {}, answers), "")
  const typed = Object.assign({}, values, { bridgeToken: "abc" })
  assert.equal(Setup.blocker("apple-music", typed, {}, Object.assign({ bridgeToken: { kind: "checking" } }, answers)), "Checking the token…")
  assert.equal(Setup.blocker("apple-music", typed, {}, Object.assign({ bridgeToken: { kind: "bad", text: "Refused" } }, answers)), "Refused")
  assert.equal(Setup.blocker("apple-music", typed, {}, Object.assign({ bridgeToken: { kind: "ok" } }, answers)), "")
  assert.deepEqual(Setup.args("apple-music", values), ["--yes", "flac", "--no", "mpris"])
})

test("a Mac's address is the bridge's URL", () => {
  assert.equal(Setup.bridgeUrl("100.64.0.10"), "http://100.64.0.10:8710")
  assert.equal(Setup.bridgeUrl(" my-mac "), "http://my-mac:8710")
  assert.equal(Setup.bridgeUrl("127.0.0.1:41000"), "http://127.0.0.1:41000")
  assert.equal(Setup.bridgeUrl("http://my-mac:8710/"), "http://my-mac:8710")
  assert.equal(Setup.bridgeUrl(""), "")
})

test("the sound output: one has to be picked, and goes to ./install", () => {
  assert.equal(Setup.blocker("sound", { output: "" }, {}), "Needs the output")
  assert.deepEqual(Setup.args("sound", { output: "alsa_output.speakers" }), ["--output", "alsa_output.speakers"])
})

test("the tailnet's Macs, from tailscale status", () => {
  const status = JSON.stringify({ Peer: {
    a: { OS: "linux", HostName: "dellxps", TailscaleIPs: ["100.64.0.2"] },
    b: { OS: "macOS", HostName: "Marc's M2 Pro", TailscaleIPs: ["100.64.0.3", "fd7a::3"] },
    c: { OS: "macOS", HostName: "Attic Mac", TailscaleIPs: ["100.64.0.4"] } } })
  assert.deepEqual(Setup.tailnetMacs(status), [
    { address: "100.64.0.4", name: "Attic Mac" }, { address: "100.64.0.3", name: "Marc's M2 Pro" }])
  assert.deepEqual(Setup.tailnetMacs("not json"), [])
  assert.deepEqual(Setup.tailnetMacs("{}"), [])
})

test("the outputs, as ./install offers them", () => {
  const sinks = JSON.stringify([
    { name: "omarock", description: "omarock" },
    { name: "alsa_output.a", description: "Speakers" },
    { name: "alsa_output.b", description: "USB Audio" },
    { name: "alsa_output.c", description: "USB Audio" },
    { name: "alsa_output.d", description: "(null)" }])
  assert.deepEqual(Setup.outputList(sinks), [
    { name: "alsa_output.a", label: "Speakers" },
    { name: "alsa_output.b", label: "USB Audio (alsa_output.b)" },
    { name: "alsa_output.c", label: "USB Audio (alsa_output.c)" }])
  assert.deepEqual(Setup.outputList(""), [])
})

test("a guide link opens omarock's own copy, which is there", () => {
  const links = Object.values(Setup.pages).flatMap(p => p.steps.flatMap(s => s.links || []))
  const guides = links.filter(l => l.guide)
  assert.ok(guides.length >= 2)
  for (const l of guides) {
    assert.ok(fs.existsSync(path.join(__dirname, "..", l.guide)), l.guide)
    assert.equal(Setup.linkUrl(l, "file:///plugins/mre.omarock/"), "file:///plugins/mre.omarock/" + l.guide)
  }
  // The web's pages stay as they are.
  for (const l of links.filter(l => l.url)) assert.ok(l.url.startsWith("https://"), l.url)
  assert.ok(!links.some(l => (l.url || "").includes("github.com/marcewing")))
})
