import QtQuick
import Quickshell.Io
import "ArtStore.js" as Store
import "Mpd.js" as Mpd

// Remote cover art (Apple Music's, Spotify's, SiriusXM's, a station's logo, a
// stream's ICY artwork) as the files tools/omarock-art makes of it. An Image
// never gets a remote address: Qt reads one whole and decodes whatever its
// bytes say it is, on the thread the bar and every plugin share. local(url)
// is what an Image may show: a file:// URL as it is (mpd's covers), else the
// helper's file once it's made, and "" until then, for one it refused and for
// anything else. Asking is what fetches it, the newest first (the rows in
// view), a batch to each of a few helpers at once. Shared by the panels
// (ArtStore.js).
Item {
  id: root

  property int batch: 8
  // Bumped as answers come, in any panel: what a binding calling local() hears.
  property int version: 0
  signal changed()
  onChanged: Qt.callLater(root.bump)
  function bump() { root.version++ }

  readonly property string tool: decodeURIComponent(String(Qt.resolvedUrl("tools/omarock-art")).replace(/^file:\/\//, ""))
  // Waiting for a helper, the newest last. Changed in place only, so the
  // bindings that ask local() don't hear it.
  property var waiting: []

  Component.onCompleted: Store.listen(root)
  Component.onDestruction: Store.forget(root)

  function local(url) {
    var address = String(url || "")
    if (address === "" || root.version < 0) return ""
    if (address.indexOf("file://") === 0) return address
    if (!/^https?:\/\//i.test(address) || address.length > 4096) return ""
    var known = Store.answers[address]
    if (known && (known.until === 0 || known.until > Date.now())) return known.file
    if (!Store.pending[address]) {
      Store.pending[address] = root
      root.waiting.push(address)
      Qt.callLater(root.pump)
    }
    return ""
  }

  // Where a cover is: "file", "refused: why", "waiting", or "" (never asked for).
  function stateOf(url) {
    var known = Store.answers[String(url || "")]
    return known ? (known.file !== "" ? "file" : "refused: " + known.why) : Store.pending[String(url || "")] ? "waiting" : ""
  }

  function pump() {
    var helpers = [first, second, third]
    for (var i = 0; i < helpers.length && root.waiting.length > 0; i++)
      if (!helpers[i].busy) helpers[i].fetch(root.waiting.splice(Math.max(0, root.waiting.length - root.batch), root.batch))
  }

  // again: seconds until a refusal is worth asking about again; one that may
  // pass soon (a server that didn't answer) is asked again then, if a cover
  // still shows it (retry).
  function answer(url, file, again, why) {
    if (Store.pending[url] === root) delete Store.pending[url]
    var soon = file === "" && again < 3600
    Store.answers[url] = { file: file, why: why, until: soon ? Date.now() + again * 1000 : 0 }
    if (soon) retry.start()
    Store.tell()
  }
  Timer {
    id: retry
    interval: 30000
    repeat: true
    onTriggered: {
      var now = Date.now(), waiting = false, due = false
      for (var url in Store.answers) {
        var until = Store.answers[url].until
        if (until > 0 && until <= now) {
          delete Store.answers[url]
          due = true
        } else if (until > 0) waiting = true
      }
      if (due) Store.tell()
      if (!waiting) retry.stop()
    }
  }

  // One run of the helper: a batch of addresses on stdin (never its command
  // line), a line of JSON back for each as it's done. It keeps its own
  // deadlines; this one is for a helper that doesn't.
  component Helper: Process {
    id: helper
    property var urls: []
    property var answered: ({})
    property bool busy: false
    property string input: ""
    stdout: SplitParser { onRead: function(line) { helper.read(line) } }
    stderr: StdioCollector {}
    function fetch(list) {
      helper.urls = list
      helper.answered = {}
      helper.busy = true
      helper.input = list.join("\n") + "\n"
      helper.command = ["python3", "-I", root.tool]
      helper.stdinEnabled = true
      helper.running = true
      deadline.restart()
    }
    onStarted: {
      helper.write(helper.input)
      helper.input = ""
      helper.stdinEnabled = false
    }
    // After a normal exit, and the only word of a start that failed.
    onRunningChanged: if (!helper.running) helper.finish()
    function read(line) {
      var reply = null
      try { reply = JSON.parse(line) } catch (e) {}
      if (!reply || typeof reply.url !== "string" || helper.urls.indexOf(reply.url) < 0 || helper.answered[reply.url]) return
      helper.answered[reply.url] = true
      var made = typeof reply.file === "string" && /\/\.cache\/omarock\/art\/[0-9a-f]{64}\.(jpg|png)$/.test(reply.file)
      root.answer(reply.url, made ? Mpd.fileUrl(reply.file) : "", made ? 0 : Number(reply.again) || 120,
        made ? "" : String(reply.refused || "omarock-art made no file"))
    }
    function finish() {
      if (!helper.busy) return
      helper.busy = false
      deadline.stop()
      helper.urls.forEach(function(url) { if (!helper.answered[url]) root.answer(url, "", 60, "no answer from omarock-art") })
      Qt.callLater(root.pump)
    }
    property Timer deadline: Timer {
      interval: 40000
      onTriggered: if (helper.running) helper.signal(9); else helper.finish()
    }
  }
  Helper { id: first }
  Helper { id: second }
  Helper { id: third }
}
