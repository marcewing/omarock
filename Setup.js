// The setup windows (Set up… on a source's tab of the settings): for each
// piece set up on its own, what it is and how it works, what it needs and
// where to get it, and the fields to fill in there and then. The fields'
// values go into their files first (tools/omarock-account: `account`), so
// ./install PIECE finds them there and doesn't ask; a few choices go to it
// as options (`arg`). Pure functions, so node can test them
// (tests/setup.test.js).
//
// A step is { title, warning, text, bullets, copies (lines to copy),
// commands (lines to type on another machine: shown, with no Copy, since
// this clipboard doesn't reach it), links, fields }; `{host}` in its text or
// bullets is this machine's name.
//
// A field is { key, type, label, lead (a line above it), description,
// placeholder, required, needs (what the footer says while it's missing),
// account, arg }:
//   "text": a line, filled in with what's set already;
//   "secret": a key or a password, never shown; empty keeps one that's set;
//   "check": a switch (on to start with if `defaultValue` is true), which
//     goes to ./install as --yes ARG or --no ARG;
//   "mac": the Mac running the bridge, from the tailnet's Macs or typed,
//     checked live: it has to answer;
//   "output": one of PipeWire's outputs, which goes to ./install as
//     --output NAME;
//   "pair": the pairing code the Mac's bridge shows. The window trades it
//     for the bridge's token as soon as it's typed (tools/omarock-account
//     bridge-pair), so the token goes straight into its file; a token that
//     the bridge takes already needs no code;
//   "soloist": Soloist, downloaded from Spotify into the Downloads folder:
//     nothing to type, the window looks for it (tools/update-soloist status,
//     which reads it without running it) until it's there.
// `pattern` and `wrong`: what a text has to look like, and what's said when
// it doesn't. `checked` (a secret): the window checks it live, against the
// bridge.

var GUIDES = "https://github.com/marcewing/omarock/blob/main/"
var REDIRECT = "http://127.0.0.1:8730/callback"
var BRIDGE_PORT = 8710
var SOLOIST_PAGE = "https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates"

var pages = {
  spotify: {
    name: "Spotify",
    intro: [
      "Spotify plays here through Soloist, Spotify's own player, which omarock-spotify drives. Search, browsing and your library come through Spotify's Web API.",
      "You need Spotify Premium, and a Spotify developer app of your own: free, made with your Spotify account."
    ],
    steps: [
      { title: "Your developer app",
        text: ["In Spotify's developer dashboard, create an app. Give it this redirect URI, and check Web API:"],
        copies: [REDIRECT],
        links: [{ label: "Spotify's developer dashboard", url: "https://developer.spotify.com/dashboard" }],
        fields: [{ key: "spotifyClient", type: "text", lead: "From the developer dashboard, copy the app's Client ID and paste it here:",
          placeholder: "32 letters and digits", required: true, needs: "the app's Client ID", pattern: "^[0-9A-Fa-f]{32}$",
          wrong: "A Client ID is 32 letters and digits", account: "spotify-client" }] },
      { title: "The Soloist key",
        text: ["Soloist's API key, from its page in the developer dashboard. It's kept in a file only you can read, and never shown here. Soloist gets it from there, never on its command line."],
        links: [{ label: "Soloist's API key, in the dashboard", url: "https://developer.spotify.com/dashboard/soloist" }],
        fields: [{ key: "soloistKey", type: "secret", label: "The Soloist key", required: true, needs: "the Soloist key",
          account: "soloist-key" }] },
      { title: "Soloist, Spotify's player",
        text: ["Soloist comes from Spotify, and you download it yourself. On Spotify's Soloist page, pick Linux x86_64 (the soloist_release_x86_64.tar.gz file) and save it in your Downloads folder. omarock installs it from there, and checks that it works with omarock before it runs.",
          "Spotify's builds stop working after 90 days: a dot on Spotify in omarock's header says when to download a new one."],
        links: [{ label: "Soloist's downloads, on Spotify's site", url: SOLOIST_PAGE }],
        fields: [{ key: "soloistDownload", type: "soloist", required: true, needs: "Soloist, downloaded from Spotify" }] },
      { title: "After pressing \"Start setup\"",
        bullets: [
          "Soloist will be installed from your Downloads folder, checked with omarock, and started.",
          "Soloist must be paired with your Spotify account. Open Spotify on your phone or computer (on this network), play something and choose {host} under Connect. This only needs to be done once.",
          "If your firewall is on, you'll be asked to confirm opening Soloist's port while you pair. The port will be closed again after pairing.",
          "Spotify will be opened in your browser to confirm access."
        ] }
    ]
  },

  siriusxm: {
    name: "SiriusXM",
    intro: [
      "SiriusXM's live channels, played by mpd. omarock-sxm, a small service on this machine, signs in to your account and passes the channels on.",
      "You need a SiriusXM subscription that includes streaming."
    ],
    steps: [
      { title: "It's unofficial",
        warning: true,
        text: ["omarock-sxm signs in as SiriusXM's web player does. SiriusXM's terms forbid that, so your account could be limited or closed, and it may stop working whenever SiriusXM changes its player."],
        links: [{ label: "More in sxm/README.md", url: GUIDES + "sxm/README.md" }],
        fields: [{ key: "sxmTerms", type: "check", label: "I understand: set it up anyway", required: true,
          needs: "you to accept the risk", arg: "terms" }] },
      { title: "Your SiriusXM login",
        text: ["Kept in a file only you can read. The password is never shown."],
        fields: [
          { key: "sxmUser", type: "text", label: "SiriusXM email or username", required: true, needs: "your SiriusXM email or username",
            account: "sxm-user" },
          { key: "sxmPassword", type: "secret", label: "SiriusXM password", required: true, needs: "your SiriusXM password",
            account: "sxm-password" }
        ] }
    ]
  },

  "apple-music": {
    name: "Apple Music",
    intro: [
      "Apple Music plays on your Mac, in omarock's bridge, an app you build there. Its sound comes here as a stream that mpd plays, and omarock browses and controls it through the bridge.",
      "Both machines need to reach each other: on your home network, or over Tailscale. Nothing between them is encrypted, so use a network you trust, or Tailscale."
    ],
    steps: [
      { title: "First, on your Mac",
        text: ["The bridge is built and runs on the Mac, with your own Apple Developer membership, so this part is done there. Set aside an hour the first time. The Mac needs:"],
        bullets: [
          "Apple silicon, and macOS 15 or later",
          "A paid Apple Developer Program membership",
          "Xcode from the App Store, opened once, with your developer Apple ID in its Settings, Accounts",
          "Homebrew (brew.sh)",
          "An Apple Music subscription"
        ],
        links: [{ label: "The bridge's guide", url: GUIDES + "apple-bridge/README.md" }] },
      { title: "The bridge",
        text: ["In the Mac's Terminal, type these. ./install walks you through the rest, and ends by showing a pairing code for this machine."],
        commands: ["git clone https://github.com/marcewing/omarock", "cd omarock && ./install"] },
      { title: "Which Mac",
        text: ["The Mac running the bridge: one found on this network or your tailnet, or its address."],
        fields: [{ key: "appleMac", type: "mac", required: true, needs: "the Mac running the bridge", placeholder: "my-mac.local or 100.64.0.10",
          account: "apple-bridge" }] },
      { title: "Pairing",
        text: ["Type the pairing code the Mac shows. For a new one, run ./install pair in omarock's folder on the Mac."],
        fields: [{ key: "pairCode", type: "pair", label: "Pairing code", placeholder: "6 digits", required: true,
          needs: "the pairing code from the Mac" }] },
      { title: "Smooth playback (optional, recommended)",
        text: ["A fix for mpd-mpris that isn't in Arch's package yet (patches/README.md). It's built here, for omarock only, from a pinned release, and sudo asks for your password to install the packages it builds with (those you don't have yet; they stay afterwards)."],
        fields: [
          { key: "mpris", type: "check", defaultValue: true, label: "A patched mpd-mpris (a minute; installs go and git)", arg: "mpris",
            description: "Without it, mpd-mpris (the media keys' go-between) asks mpd for the stream's cover at every play and pause, which holds mpd for seconds." }
        ] }
    ]
  },

  sound: {
    name: "omarock's sound output",
    intro: [
      "Optional, and most don't need it. When set up, everything omarock plays (mpd, Spotify) goes into one output you pick, with one volume. It never moves to another output: if that output goes away, omarock waits, silent.",
      "That matters if some outputs must never carry music: a radio transmitter's audio interface, say, or a TV in another room."
    ],
    steps: [
      { title: "The output",
        text: ["Pick the one for your speakers or headphones."],
        fields: [{ key: "output", type: "output", required: true, needs: "the output", arg: "output" }] }
    ]
  }
}

// The window's title.
function title(piece) {
  var page = pages[piece]
  return page ? "Set up " + page.name : ""
}

// A page's fields, in order.
function fields(piece) {
  var page = pages[piece]
  var out = []
  if (page) page.steps.forEach(function(s) { (s.fields || []).forEach(function(f) { out.push(f) }) })
  return out
}

// What a Mac's address means: the bridge's URL. "my-mac" and "100.64.0.10"
// get the bridge's port; "host:port" and a URL are taken as they are.
function bridgeUrl(address) {
  var a = String(address || "").trim().replace(/\/+$/, "")
  if (a === "") return ""
  if (!/^https?:\/\//.test(a)) a = "http://" + a
  return /^https?:\/\/[^\/]*:\d+$/.test(a) ? a : a + ":" + BRIDGE_PORT
}

// What the fields start with: what's set already (known: tools/omarock-account
// show), for a line or the Mac; nothing typed for a secret; a switch as its
// default; the default output.
function initial(piece, known, defaultOutput) {
  known = known || {}
  var out = {}
  fields(piece).forEach(function(f) {
    if (f.type === "text") out[f.key] = typeof known[f.key] === "string" ? known[f.key] : ""
    else if (f.type === "secret") out[f.key] = ""
    else if (f.type === "check") out[f.key] = f.defaultValue === true
    else if (f.type === "mac") out[f.key] = typeof known.appleBridge === "string" ? known.appleBridge : ""
    else if (f.type === "output") out[f.key] = defaultOutput && defaultOutput !== "omarock" ? defaultOutput : ""
    else if (f.type === "pair" || f.type === "soloist") out[f.key] = ""
  })
  return out
}

// A pairing code's digits: "048 213" and "048-213" are 048213. Anything
// else typed stays, so it can be called wrong.
function pairDigits(value) {
  return String(value || "").replace(/[\s-]/g, "")
}

// What's wrong with a field, or "": value is what's in it, known what's set
// already, live the window's check of it ({ kind: "checking"|"ok"|"bad", text }).
function problem(field, value, known, live) {
  known = known || {}
  var set = known[field.key] === true || (typeof known[field.key] === "string" && known[field.key] !== "")
  if (field.type === "check") return field.required && value !== true ? "Needs " + field.needs : ""
  if (field.type === "soloist") return live && live.kind === "ok" ? "" : live && live.kind === "bad" ? live.text : "Needs " + field.needs
  if (field.type === "mac" || field.type === "output") {
    if (String(value || "").trim() === "") return field.required ? "Needs " + field.needs : ""
    if (field.type === "output") return ""
    return !live || live.kind === "checking" ? "Checking the bridge…" : live.kind === "ok" ? "" : live.text
  }
  // The pairing code: paired (or a token the bridge takes) is done; a code
  // tried and refused says why while it's still in the field; a bridge
  // that can't pair says so whatever is typed.
  if (field.type === "pair") {
    if (live && live.kind === "ok") return ""
    if (live && live.kind === "checking") return live.text || "Pairing…"
    var code = pairDigits(value)
    if (live && live.kind === "bad" && (live.code === undefined || live.code === code)) return live.text
    if (code !== "" && !/^\d*$/.test(code)) return "A pairing code is 6 digits"
    if (code.length < 6) return field.required ? "Needs " + field.needs : ""
    if (code.length > 6) return "A pairing code is 6 digits"
    return "Pairing…"
  }
  // A password's spaces are its own; a line's aren't.
  var typed = field.type === "secret" ? String(value || "") : String(value || "").trim()
  if (typed === "" && field.required && !set) return "Needs " + field.needs
  if (typed === "") return ""
  if (field.pattern && !new RegExp(field.pattern).test(typed)) return field.wrong
  if (field.checked && live) return live.kind === "checking" ? "Checking the token…" : live.kind === "bad" ? live.text : ""
  return ""
}

// The first thing that stops Start setup, or "" when it can go.
function blocker(piece, values, known, live) {
  values = values || {}
  live = live || {}
  var list = fields(piece)
  for (var i = 0; i < list.length; i++) {
    var p = problem(list[i], values[list[i].key], known, live[list[i].key])
    if (p !== "") return p
  }
  return ""
}

// The values to save before the terminal runs, in the page's order, as
// [omarock-account's name for it, value]: what was typed (a line only if
// it changed), and the Mac's bridge.
function writes(piece, values, known) {
  values = values || {}
  known = known || {}
  var out = []
  fields(piece).forEach(function(f) {
    if (!f.account) return
    var v = values[f.key]
    if (f.type === "secret") {
      if (String(v || "") !== "") out.push([f.account, String(v)])
    } else if (f.type === "text") {
      v = String(v || "").trim()
      if (v !== "" && v !== known[f.key]) out.push([f.account, v])
    } else if (f.type === "mac") {
      v = bridgeUrl(v)
      if (v !== "" && v !== known.appleBridge) out.push([f.account, v])
    }
  })
  return out
}

// ./install's words after the piece: --yes or --no for each switch, the output.
function args(piece, values) {
  values = values || {}
  var out = []
  fields(piece).forEach(function(f) {
    if (!f.arg) return
    if (f.type === "check") out.push(values[f.key] === true ? "--yes" : "--no", f.arg)
    else if (f.type === "output" && values[f.key]) out.push("--output", String(values[f.key]))
  })
  return out
}

// What tools/omarock-account bridge-pair (or bridge-check) came to, as a
// note { kind, text }: its exit code, and the bridge's reason on stderr.
function pairState(code, stderr) {
  var said = String(stderr || "").trim().split("\n").pop().replace(/\.$/, "")
  if (code === 0) return { kind: "ok", text: "Paired with the bridge" }
  var fallback = { 3: "That isn't the code the Mac shows", 4: "No pairing code is open on the Mac: run ./install pair there",
    5: "The bridge on the Mac is older than 0.10.0, and can't pair: update it there (git pull, then ./install)",
    6: "The bridge didn't answer", 7: "Couldn't save the bridge's token",
    9: "That name points to this machine, not a Mac: omarock sends it nothing" }
  return { kind: "bad", text: said || fallback[code] || "Pairing didn't work (" + code + ")" }
}

// Soloist, as `tools/update-soloist status` reads it (JSON: installed,
// download), for its step: { kind: "ok"|"bad"|"waiting", text }.
function soloistState(text) {
  var st
  try { st = JSON.parse(text) } catch (e) { return { kind: "bad", text: "Couldn't look for Soloist (tools/update-soloist status)" } }
  var day = function(t) { return t > 0 ? new Date(t * 1000).toISOString().slice(0, 10) : "" }
  var built = function(t) { return t > 0 ? ", built " + day(t) : "" }
  var inst = st && st.installed, dl = st && st.download
  if (dl && dl.ok && (dl.newer || !inst))
    return { kind: "ok", text: "Found it in your Downloads folder" + built(dl.built)
      + (/^https:\/\/soloist-builds\.spotifycdn\.com\//.test(dl.origin || "") ? ", from Spotify" : ", though your browser didn't record where it came from")
      + ". Start setup shows it and asks before installing it." }
  if (inst && inst.checked && inst.days < 80)
    return { kind: "ok", text: "Soloist is installed already" + built(inst.built) + ": no download needed" }
  if (inst && !inst.checked && inst.days < 80 && (!dl || dl.same))
    return { kind: "ok", text: "Soloist is installed" + built(inst.built) + ". Start setup checks it with omarock." }
  if (dl && !dl.ok) return { kind: "bad", text: dl.path.replace(/^.*\//, "") + " in your Downloads folder can't be used: " + dl.why }
  if (inst) return { kind: "waiting", text: "The Soloist installed is " + inst.days + " days old: download a new one. Waiting for it in your Downloads folder…" }
  return { kind: "waiting", text: "Waiting for it in your Downloads folder…" }
}

// The Macs on a tailnet, from `tailscale status --json`:
// [{ address, name, via: "tailnet" }].
function tailnetMacs(text) {
  var status
  try { status = JSON.parse(text) } catch (e) { return [] }
  var peers = status && status.Peer ? status.Peer : {}
  var out = []
  for (var id in peers) {
    var p = peers[id]
    if (p && p.OS === "macOS" && p.TailscaleIPs && p.TailscaleIPs.length > 0)
      out.push({ address: p.TailscaleIPs[0], name: p.HostName || p.DNSName || p.TailscaleIPs[0], via: "tailnet" })
  }
  return out.sort(function(a, b) { return a.name.localeCompare(b.name) })
}

// avahi-browse's \DDD escapes (decimal bytes, UTF-8): "Marc\039s\032Mac".
function unescapeAvahi(text) {
  var bytes = []
  var s = String(text || "")
  for (var i = 0; i < s.length; i++) {
    var m = /^\\(\d{3})/.exec(s.slice(i))
    if (m) { bytes.push(parseInt(m[1], 10)); i += 3; continue }
    var c = s.charCodeAt(i)
    if (c < 0x80) bytes.push(c)
    else encodeURIComponent(s.charAt(i)).slice(1).split("%").forEach(function(h) { bytes.push(parseInt(h, 16)) })
  }
  try { return decodeURIComponent(bytes.map(function(b) { return "%" + (b < 16 ? "0" : "") + b.toString(16) }).join("")) }
  catch (e) { return s }
}

// The bridges on this network, from `avahi-browse -rpt _omarock._tcp` (bridge
// 0.9.0 advertises itself): [{ address: the Mac's host name (my-mac.local),
// name, via: "network" }], by host name, which stays when its address changes.
// Each Mac comes once, though avahi lists it for each interface and protocol.
function bonjourMacs(text) {
  var out = []
  var seen = {}
  String(text || "").split("\n").forEach(function(line) {
    var f = line.split(";")
    // =;interface;protocol;name;type;domain;host;address;port;txt
    if (f.length < 9 || f[0] !== "=" || f[4] !== "_omarock._tcp") return
    var host = f[6].replace(/\.$/, "")
    var port = parseInt(f[8], 10)
    var address = port && port !== BRIDGE_PORT ? host + ":" + port : host
    if (host === "" || seen[address]) return
    seen[address] = true
    out.push({ address: address, name: unescapeAvahi(f[3]) || host, via: "network" })
  })
  return out.sort(function(a, b) { return a.name.localeCompare(b.name) })
}

// The Macs to offer, by name: a Mac on the tailnet first (it works away from
// home too, and Tailscale encrypts), then on this network.
function macList(tailnet, network) {
  var all = (tailnet || []).concat(network || [])
  return all.map(function(m, i) { return { m: m, i: i } }).sort(function(a, b) {
    var byName = a.m.name.localeCompare(b.m.name)
    if (byName !== 0) return byName
    if (a.m.via !== b.m.via) return a.m.via === "tailnet" ? -1 : 1
    return a.i - b.i
  }).map(function(e) { return e.m })
}

// One line for a Mac in the list: "Studio Mac  ·  100.64.0.10 (Tailscale)".
function macLabel(m) {
  return m.name + "  ·  " + m.address + (m.via === "tailnet" ? "  (Tailscale)" : m.via === "network" ? "  (this network)" : "")
}

// PipeWire's outputs from `pactl -f json list sinks`, as ./install offers
// them: by their names for people, the node's name added to tell two alike
// apart; none without a name for people, and not omarock's own.
function outputList(text) {
  var sinks
  try { sinks = JSON.parse(text) } catch (e) { return [] }
  if (!Array.isArray(sinks)) return []
  var list = sinks.filter(function(s) {
    return s && s.name && s.name !== "omarock" && s.description && s.description !== "(null)"
  }).map(function(s) { return { name: s.name, description: s.description } })
  var seen = {}
  list.forEach(function(o) { seen[o.description] = (seen[o.description] || 0) + 1 })
  return list.map(function(o) {
    return { name: o.name, label: seen[o.description] > 1 ? o.description + " (" + o.name + ")" : o.description }
  })
}

if (typeof module !== "undefined") {
  module.exports = { pages: pages, REDIRECT: REDIRECT, title: title, fields: fields, bridgeUrl: bridgeUrl, initial: initial,
    problem: problem, blocker: blocker, writes: writes, args: args, pairDigits: pairDigits, pairState: pairState,
    soloistState: soloistState, SOLOIST_PAGE: SOLOIST_PAGE,
    tailnetMacs: tailnetMacs, bonjourMacs: bonjourMacs, unescapeAvahi: unescapeAvahi, macList: macList, macLabel: macLabel,
    outputList: outputList }
}
