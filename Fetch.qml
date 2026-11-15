import QtQuick
import Quickshell.Io

// HTTP for the panel, through curl. Qt's XMLHttpRequest keeps every byte of
// an answer until the answer ends, with no cap and no word while it comes,
// and has no deadline of its own: an answer of gigabytes, or one that
// trickles forever, held the shell. curl stops an answer as it passes
// maxBytes (--max-filesize, as the bytes arrive since curl 8.4) and the whole
// request at its deadline (--max-time); a watchdog here gives up on a curl
// that doesn't, and kills it. The request goes to curl on stdin, as its
// config (-K -): its address and headers, a token among them, are never on a
// command line, where any account on this machine can read them (ps). A few
// run at once (slots), and the rest wait their turn, their deadlines running.
Item {
  id: root

  property int slots: 4
  // The most of an answer read, unless a request says.
  property int maxBytes: 1048576
  // The program (the harness gives one that can't start, or never ends).
  property string curl: "curl"
  readonly property string userAgent: "omarock (https://github.com/marcewing/omarock)"

  // Requests running, and waiting: { spec, callback, deadline, job, done }.
  property var running: []
  property var waiting: []

  // spec: url (http or https), method ("GET"), headers ({ name: value }),
  // json (a body, sent as JSON), maxBytes, timeoutMs (10 s), resolve (curl's
  // "host:port:address": where to reach host:port, without looking it up).
  // callback(reply), once: { status (the HTTP status; 0: no answer), text
  // (the body, only if it came whole), timedOut, tooBig }.
  function request(spec, callback) {
    var entry = { spec: spec, callback: callback, deadline: Date.now() + (spec.timeoutMs || 10000), job: null, done: false }
    root.waiting = root.waiting.concat([entry])
    Qt.callLater(root.next)
  }

  function next() {
    // Torn down (a plugin reload) since it was asked for.
    if (!root || typeof root.start !== "function") return
    while (root.running.length < root.slots && root.waiting.length > 0) {
      var entry = root.waiting[0]
      root.waiting = root.waiting.slice(1)
      if (Date.now() >= entry.deadline) root.settle(entry, { status: 0, text: null, timedOut: true, tooBig: false })
      else root.start(entry)
    }
  }

  function start(entry) {
    var left = entry.deadline - Date.now()
    var job = jobs.createObject(root, { deadline: left + 5000 })
    entry.job = job
    // The entry in a closure: given to the job as a property, it would be a copy.
    job.ended.connect(function(code, bytes, text, status) { root.finished(entry, code, bytes, text, status) })
    root.running = root.running.concat([entry])
    // -q first: no ~/.curlrc, which could follow redirects or skip TLS checks.
    job.feed([root.curl, "-q", "-K", "-"], root.config(entry.spec, left))
  }

  // A value in curl's config: quoted, its backslashes and quotes escaped.
  // A line break would end it, so none is kept.
  function quoted(value) {
    return '"' + String(value).replace(/[\r\n\0]/g, "").replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  // A URL with its host in lower case, as Qt sent it (curl sends it as
  // given): the bridge builds the addresses it hands out from it.
  function lowerHost(url) {
    return String(url).replace(/^([a-z][a-z0-9+.-]*:\/\/)([^\/?#@]*)/i, function(all, scheme, host) {
      return scheme.toLowerCase() + host.toLowerCase()
    })
  }

  // The status goes to stderr (write-out), the body alone to stdout.
  function config(spec, left) {
    var method = spec.method || "GET"
    var lines = ["silent", "globoff", 'proto = "=http,https"', 'noproxy = "*"', 'write-out = "%{stderr}%{http_code}"',
      "max-filesize = " + Math.max(1, Math.floor(spec.maxBytes || root.maxBytes)),
      "max-time = " + Math.max(0.1, left / 1000).toFixed(3),
      "user-agent = " + root.quoted(root.userAgent),
      "url = " + root.quoted(root.lowerHost(spec.url))]
    if (method !== "GET") lines.push("request = " + root.quoted(method))
    var headers = spec.headers || {}
    Object.keys(headers).forEach(function(name) { lines.push("header = " + root.quoted(name + ": " + headers[name])) })
    if (spec.json !== undefined && spec.json !== null) {
      lines.push("header = " + root.quoted("Content-Type: application/json"))
      // JSON never starts with "@", which would have curl read a file.
      lines.push("data-binary = " + root.quoted(JSON.stringify(spec.json)))
    } else if (method === "POST" || method === "PUT") {
      lines.push('data-binary = ""')
    }
    if (spec.resolve) lines.push("resolve = " + root.quoted(spec.resolve))
    return lines.join("\n") + "\n"
  }

  // curl's end: its exit code (0 whole, 63 over the cap, 28 out of time,
  // 127 when it couldn't start), the body's size and text, and its stderr
  // (the HTTP status).
  function finished(entry, code, bytes, text, status) {
    entry.job.destroy()
    entry.job = null
    if (entry.done) return
    var cap = entry.spec.maxBytes || root.maxBytes
    var m = /(\d{3})\s*$/.exec(status || "")
    var http = m ? parseInt(m[1], 10) : 0
    var big = code === 63 || (code === 0 && bytes > cap)
    root.settle(entry, { status: code === 0 || big ? http : 0, text: code === 0 && !big ? text : null,
      timedOut: code === 28, tooBig: big })
  }

  function settle(entry, reply) {
    entry.done = true
    root.running = root.running.filter(function(e) { return e !== entry })
    Qt.callLater(root.next)
    if (entry.callback) entry.callback(reply)
  }

  // curl's deadline, should it not keep it, and the waiting's.
  Timer {
    interval: 250
    repeat: true
    running: root.running.length > 0 || root.waiting.length > 0
    onTriggered: {
      var now = Date.now()
      root.running.forEach(function(entry) {
        if (entry.done || now < entry.deadline + 1500) return
        root.settle(entry, { status: 0, text: null, timedOut: true, tooBig: false })
        if (entry.job) entry.job.signal(9)
      })
      var late = root.waiting.filter(function(entry) { return now >= entry.deadline })
      if (late.length === 0) return
      root.waiting = root.waiting.filter(function(entry) { return now < entry.deadline })
      late.forEach(function(entry) { root.settle(entry, { status: 0, text: null, timedOut: true, tooBig: false }) })
    }
  }

  Component {
    id: jobs

    StdinProcess {
      id: job
      property int code: -1
      property bool outEnded: false
      property bool errEnded: false
      signal ended(int code, int bytes, string text, string status)
      stdout: StdioCollector {
        id: out
        waitForEnd: true
        onStreamFinished: {
          job.outEnded = true
          job.end()
        }
      }
      stderr: StdioCollector {
        id: err
        waitForEnd: true
        onStreamFinished: {
          job.errEnded = true
          job.end()
        }
      }
      onExited: function(exitCode) {
        job.code = exitCode
        job.end()
      }
      function end() {
        if (job.code < 0 || !job.outEnded || !job.errEnded) return
        job.ended(job.code, out.data ? out.data.byteLength : 0, out.text, err.text)
      }
    }
  }
}
