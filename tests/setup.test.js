const test = require("node:test")
const assert = require("node:assert/strict")
const Setup = require("../Setup.js")
const Settings = require("../Settings.js")

test("each piece set up from the settings has a setup window", () => {
  for (const piece of ["spotify", "siriusxm", "apple-music", "sound"]) {
    assert.ok(Setup.pages[piece], piece)
    assert.ok(Setup.title(piece).startsWith("Set up "))
    assert.ok(Setup.pages[piece].steps.length > 0)
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
  const values = { appleMac: "my-mac", bridgeToken: "", mpris: false }
  assert.equal(Setup.blocker("apple-music", values, {}, {}), "Checking the bridge…")
  assert.equal(Setup.blocker("apple-music", values, {}, { appleMac: { kind: "bad", text: "Nothing answers" } }), "Nothing answers")
  const answers = { appleMac: { kind: "ok", text: "The bridge answers" } }
  // No token: setup copies it from the Mac with scp, once its Remote Login answers.
  assert.equal(Setup.blocker("apple-music", values, {}, answers), "Checking the Mac's Remote Login…")
  const off = Setup.scpState(255, "ssh: connect to host 100.64.0.10 port 22: Connection refused")
  assert.equal(Setup.blocker("apple-music", values, {}, Object.assign({ bridgeToken: off }, answers)), off.text)
  assert.equal(Setup.blocker("apple-music", values, {}, Object.assign({ bridgeToken: Setup.scpState(0, "") }, answers)), "")
  // A token set already: no need.
  assert.equal(Setup.blocker("apple-music", values, { bridgeToken: true }, Object.assign({ bridgeToken: off }, answers)), "")
  const typed = Object.assign({}, values, { bridgeToken: "abc" })
  assert.equal(Setup.blocker("apple-music", typed, {}, Object.assign({ bridgeToken: { kind: "checking" } }, answers)), "Checking the token…")
  assert.equal(Setup.blocker("apple-music", typed, {}, Object.assign({ bridgeToken: { kind: "bad", text: "Refused" } }, answers)), "Refused")
  assert.equal(Setup.blocker("apple-music", typed, {}, Object.assign({ bridgeToken: { kind: "ok" } }, answers)), "")
  assert.deepEqual(Setup.args("apple-music", values), ["--yes", "scp-token", "--no", "mpris"])
  assert.deepEqual(Setup.args("apple-music", typed), ["--no", "mpris"])
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
    { address: "100.64.0.4", name: "Attic Mac", via: "tailnet" }, { address: "100.64.0.3", name: "Marc's M2 Pro", via: "tailnet" }])
  assert.deepEqual(Setup.tailnetMacs("not json"), [])
  assert.deepEqual(Setup.tailnetMacs("{}"), [])
})

test("the bridges on this network, from avahi-browse, each Mac once by its host name", () => {
  const text = [
    "+;enp1s0;IPv4;Studio\\032Mac;_omarock._tcp;local",
    "=;enp1s0;IPv4;Studio\\032Mac;_omarock._tcp;local;Studio-Mac.local;192.0.2.5;8710;\"version=0.9.0\"",
    "=;enp1s0;IPv6;Studio\\032Mac;_omarock._tcp;local;Studio-Mac.local;fe80::5;8710;\"version=0.9.0\"",
    "=;wlan0;IPv4;Studio\\032Mac;_omarock._tcp;local;Studio-Mac.local;192.0.2.5;8710;\"version=0.9.0\"",
    "=;wlan0;IPv4;Mina\\226\\128\\153s\\032Mac;_omarock._tcp;local;Minas-Mac.local;192.0.2.6;8711;\"\"",
    "=;enp1s0;IPv4;Printer;_ipp._tcp;local;printer.local;192.0.2.9;631;\"\""
  ].join("\n")
  assert.deepEqual(Setup.bonjourMacs(text), [
    { address: "Minas-Mac.local:8711", name: "Mina’s Mac", via: "network" },
    { address: "Studio-Mac.local", name: "Studio Mac", via: "network" }])
  assert.deepEqual(Setup.bonjourMacs(""), [])
  assert.equal(Setup.unescapeAvahi("Marc\\039s\\032M2\\032Pro"), "Marc's M2 Pro")
})

test("the Macs offered: by name, a Mac's tailnet address before its address on this network", () => {
  const tailnet = [{ address: "100.64.0.10", name: "Studio Mac", via: "tailnet" }]
  const network = [{ address: "Attic.local", name: "Attic", via: "network" }, { address: "Studio-Mac.local", name: "Studio Mac", via: "network" }]
  assert.deepEqual(Setup.macList(tailnet, network).map(Setup.macLabel), [
    "Attic  ·  Attic.local  (this network)",
    "Studio Mac  ·  100.64.0.10  (Tailscale)",
    "Studio Mac  ·  Studio-Mac.local  (this network)"])
  assert.deepEqual(Setup.macList([], []), [])
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

test("the Mac's Remote Login, from ssh in batch mode", () => {
  assert.deepEqual(Setup.scpState(0, ""), { kind: "ok", text: "Mac scp enabled" })
  assert.equal(Setup.scpState(255, "marc@100.64.0.10: Permission denied (publickey,password,keyboard-interactive).").kind, "ok")
  assert.match(Setup.scpState(255, "marc@100.64.0.10: Permission denied (publickey,password).").text, /password on the Mac/)
  assert.match(Setup.scpState(255, "Host key verification failed.").text, /trust the Mac/)
  assert.match(Setup.scpState(255, "ssh: connect to host 100.64.0.10 port 22: Connection refused").text, /^Remote Login is off/)
  assert.equal(Setup.scpState(255, "ssh: connect to host 100.64.0.10 port 22: Connection timed out").kind, "bad")
  assert.equal(Setup.bridgeHost("http://100.64.0.10:8710"), "100.64.0.10")
  assert.equal(Setup.bridgeHost("http://my-mac:8710"), "my-mac")
})

test("tokenCopyState: what Copy with ssh says, by ssh's exit and its errors", () => {
  assert.deepEqual(Setup.tokenCopyState(0, "", "mac"), { kind: "ok", text: "Copied from the Mac" })
  assert.match(Setup.tokenCopyState(255, "ssh: connect to host mac port 22: Connection refused", "mac").text, /^Remote Login is off/)
  assert.match(Setup.tokenCopyState(255, "marc@mac: Permission denied (publickey,password).", "mac").text, /password/)
  assert.match(Setup.tokenCopyState(255, "Host key verification failed.", "100.64.0.10").text, /run ssh 100\.64\.0\.10 once/)
  assert.match(Setup.tokenCopyState(1, "cat: Library/Application Support/omarock-bridge/token: No such file or directory", "mac").text,
    /no bridge token/)
  assert.match(Setup.tokenCopyState(3, "", "mac").text, /empty/)
  assert.equal(Setup.tokenCopyState(4, "omarock-account: nothing on stdin\n", "mac").text, "Couldn't save it: omarock-account: nothing on stdin")
  assert.equal(Setup.tokenCopyState(255, "ssh: Could not resolve hostname mac", "mac").kind, "bad")
})

test("the windows as Marc laid them out: no Tailscale link, no list of what the terminal does", () => {
  const all = Object.values(Setup.pages)
  assert.ok(!all.some(p => p.after || p.introLinks))
  assert.ok(!all.some(p => p.steps.some(s => (s.links || []).some(l => /tailscale/i.test(l.label + l.url)))))
  const apple = Setup.pages["apple-music"]
  assert.equal(apple.steps[3].title, "Smooth playback (optional, recommended)")
  // The recommended fix starts ticked; the libFLAC one is gone (bridge 0.7.0's stream needs none).
  assert.deepEqual(Setup.args("apple-music", Setup.initial("apple-music", {})), ["--yes", "scp-token", "--yes", "mpris"])
  assert.ok(!apple.steps[3].fields.some(f => f.key === "flac"))
  // Spotify: where the Client ID comes from, Soloist's own page, and what Start setup does next, as step 3.
  const spotify = Setup.pages.spotify
  assert.match(spotify.steps[0].fields[0].lead, /copy the app's Client ID and paste it here/)
  assert.equal(spotify.steps[1].links[0].url, "https://developer.spotify.com/dashboard/soloist")
  assert.equal(spotify.steps[2].title, 'After pressing "Start setup"')
  assert.equal(spotify.steps[2].bullets.length, 4)
  assert.ok(spotify.steps[2].bullets[1].includes("{host}"))
})
