// The setup windows (Set up… on a source's tab of the settings): for each
// piece set up on its own, what it is and how it works, what it needs and
// where to get it, and the fields to fill in there and then. The fields'
// values go into their files first (tools/omarock-account: `account`), so
// ./install PIECE finds them there and doesn't ask; a few choices go to it
// as options (`arg`). Pure functions, so node can test them
// (tests/setup.test.js).
//
// A step is { title, warning, text, copies (lines to copy), links, fields,
// bullets }; `{host}` in its text or bullets is this machine's name.
//
// A field is { key, type, label, lead (a line above it), description,
// placeholder, required, needs (what the footer says while it's missing),
// account, arg }:
//   "text": a line, filled in with what's set already;
//   "secret": a key or a password, never shown; empty keeps one that's set;
//   "check": a tick (ticked to start with if `defaultValue` is true), which
//     goes to ./install as --yes ARG or --no ARG;
//   "mac": the Mac running the bridge, from the tailnet's Macs or typed,
//     checked live: it has to answer;
//   "output": one of PipeWire's outputs, which goes to ./install as
//     --output NAME.
// `pattern` and `wrong`: what a text has to look like, and what's said when
// it doesn't. `checked` (a secret): the window checks it live, against the
// bridge. `scp` (the bridge's token): left blank, setup copies it from the
// Mac with scp (--yes ARG), so the window checks the Mac's Remote Login
// first.

var GUIDES = "https://github.com/marcewing/omarock/blob/main/"
var REDIRECT = "http://127.0.0.1:8730/callback"
var BRIDGE_PORT = 8710

var pages = {
  spotify: {
    name: "Spotify",
    intro: [
      "Spotify plays here through Soloist, Spotify's own player, which omarock-spotify drives. Search, browsing and your library come through Spotify's Web API.",
      "You need Spotify Premium, and a Spotify developer app of your own: free, made with your Spotify account."
    ],
    steps: [
      { title: "Your developer app",
        text: ["In Spotify's developer dashboard, create an app. Give it this redirect URI, and tick Web API:"],
        copies: [REDIRECT],
        links: [{ label: "Spotify's developer dashboard", url: "https://developer.spotify.com/dashboard" }],
        fields: [{ key: "spotifyClient", type: "text", lead: "From the developer dashboard, copy the app's Client ID and paste it here:",
          placeholder: "32 letters and digits", required: true, needs: "the app's Client ID", pattern: "^[0-9A-Fa-f]{32}$",
          wrong: "A Client ID is 32 letters and digits", account: "spotify-client" }] },
      { title: "The Soloist key",
        text: ["Soloist's API key, from its page in the developer dashboard. It's kept in a file only you can read, and never shown."],
        links: [{ label: "Soloist's API key, in the dashboard", url: "https://developer.spotify.com/dashboard/soloist" }],
        fields: [{ key: "soloistKey", type: "secret", label: "The Soloist key", required: true, needs: "the Soloist key",
          account: "soloist-key" }] },
      { title: "After pressing \"Start setup\"",
        bullets: [
          "Soloist will be downloaded from Spotify and started by omarock-spotify.",
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
          needs: "a tick that you understand the risk", arg: "terms" }] },
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
      "Both machines need to reach each other, over Tailscale, say."
    ],
    steps: [
      { title: "The bridge, on your Mac",
        text: ["It's built with your own Apple Developer membership. On the Mac, clone omarock and run ./install there: it builds the bridge, and starts it at login."],
        copies: ["git clone https://github.com/marcewing/omarock.git && cd omarock && ./install"],
        links: [
          { label: "The bridge's guide", url: GUIDES + "bridge/README.md" },
          { label: "Apple Developer Program", url: "https://developer.apple.com/programs/" }
        ] },
      { title: "Which Mac",
        text: ["The Mac running the bridge: one of the Macs on your tailnet, or its address."],
        fields: [{ key: "appleMac", type: "mac", required: true, needs: "the Mac running the bridge", placeholder: "100.64.0.10 or my-mac",
          account: "apple-bridge" }] },
      { title: "The bridge's token",
        text: ["On the Mac, the token is in ~/Library/Application Support/omarock-bridge/token. Paste it here or leave blank to scp it during setup (Remote Login must be enabled on the Mac)."],
        fields: [{ key: "bridgeToken", type: "secret", checked: true, scp: true, arg: "scp-token", account: "bridge-token" }] },
      { title: "Smooth playback (optional, recommended)",
        text: ["Two fixes for mpd that aren't in Arch's packages yet (patches/README.md). Each is built here, for omarock only, and sudo asks for your password to install the build tools."],
        fields: [
          { key: "flac", type: "check", defaultValue: true, label: "A fixed libFLAC (a few minutes; needs cmake and ninja)", arg: "flac",
            description: "Without it, mpd falls behind the Mac, and omarock catches it up after each change, with a short stutter." },
          { key: "mpris", type: "check", defaultValue: true, label: "A patched mpd-mpris (a minute; needs Go)", arg: "mpris",
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
// show), for a line or the Mac; nothing typed for a secret; a tick as its
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
  })
  return out
}

// What's wrong with a field, or "": value is what's in it, known what's set
// already, live the window's check of it ({ kind: "checking"|"ok"|"bad", text }).
function problem(field, value, known, live) {
  known = known || {}
  var set = known[field.key] === true || (typeof known[field.key] === "string" && known[field.key] !== "")
  if (field.type === "check") return field.required && value !== true ? "Needs " + field.needs : ""
  if (field.type === "mac" || field.type === "output") {
    if (String(value || "").trim() === "") return field.required ? "Needs " + field.needs : ""
    if (field.type === "output") return ""
    return !live || live.kind === "checking" ? "Checking the bridge…" : live.kind === "ok" ? "" : live.text
  }
  // A password's spaces are its own; a line's aren't.
  var typed = field.type === "secret" ? String(value || "") : String(value || "").trim()
  if (typed === "" && field.required && !set) return "Needs " + field.needs
  // Left blank to be copied from the Mac: its Remote Login has to answer.
  if (typed === "" && field.scp && !set)
    return !live || live.kind === "checking" ? "Checking the Mac's Remote Login…" : live.kind === "bad" ? live.text : ""
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

// ./install's words after the piece: --yes or --no for each tick, the output.
function args(piece, values) {
  values = values || {}
  var out = []
  fields(piece).forEach(function(f) {
    if (!f.arg) return
    if (f.type === "check") out.push(values[f.key] === true ? "--yes" : "--no", f.arg)
    else if (f.type === "output" && values[f.key]) out.push("--output", String(values[f.key]))
    else if (f.scp && String(values[f.key] || "") === "") out.push("--yes", f.arg)
  })
  return out
}

// The host in a bridge's URL, for ssh: "http://100.64.0.10:8710" is 100.64.0.10.
function bridgeHost(url) {
  return String(url || "").replace(/^https?:\/\//, "").replace(/:\d+$/, "")
}

// What `ssh -o BatchMode=yes HOST true` says of the Mac's Remote Login,
// for under the token field: whether setup's scp can copy the token from it.
function scpState(code, stderr) {
  var e = String(stderr || "")
  if (code === 0) return { kind: "ok", text: "Mac scp enabled" }
  if (/Host key verification failed/.test(e)) return { kind: "ok", text: "Mac scp enabled (setup asks once to trust the Mac)" }
  if (/Permission denied/.test(e)) return { kind: "ok", text: "Mac scp enabled (setup asks for your password on the Mac)" }
  if (/Connection refused/.test(e))
    return { kind: "bad", text: "Remote Login is off on the Mac: paste the token, or turn it on there (System Settings, General, Sharing)" }
  return { kind: "bad", text: "Can't reach the Mac with ssh: paste the token" }
}

// The Macs on a tailnet, from `tailscale status --json`: [{ address, name }].
function tailnetMacs(text) {
  var status
  try { status = JSON.parse(text) } catch (e) { return [] }
  var peers = status && status.Peer ? status.Peer : {}
  var out = []
  for (var id in peers) {
    var p = peers[id]
    if (p && p.OS === "macOS" && p.TailscaleIPs && p.TailscaleIPs.length > 0)
      out.push({ address: p.TailscaleIPs[0], name: p.HostName || p.DNSName || p.TailscaleIPs[0] })
  }
  return out.sort(function(a, b) { return a.name.localeCompare(b.name) })
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
    problem: problem, blocker: blocker, writes: writes, args: args, bridgeHost: bridgeHost, scpState: scpState,
    tailnetMacs: tailnetMacs, outputList: outputList }
}
