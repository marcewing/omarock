import QtQuick
import Quickshell.Io
import "History.js" as History

// History's file (History.js): ~/.local/share/omarock/history.jsonl, a line
// of JSON a play. Read when the list opens; a play adds a line. The first
// play of a session, and then of each day, writes the file again without
// what's older than the days kept. Only one panel adds (Keeper.js):
// framework's two bars would each add every play. Reads and writes go in
// order, one at a time.
Item {
  id: root

  property string path: ""
  property int days: 7
  // The last days' entries, oldest first, as last read or added here.
  property var entries: []
  // When the file was last written again without what's too old.
  property real tidiedAt: 0

  // The list to show again: read, added to, cleared.
  signal changed()

  function read(callback) {
    root.run(["cat", root.path], function(text) {
      root.entries = History.prune(History.parse(text), Date.now(), root.days)
      root.changed()
      if (callback) callback(root.entries)
    })
  }

  function add(entry) {
    if (root.path === "") return
    root.entries = History.prune(root.entries.concat([entry]), Date.now(), root.days)
    root.changed()
    if (Date.now() - root.tidiedAt > 24 * 3600 * 1000) {
      // Once a day: what's in the file, less what's too old, then this.
      root.tidiedAt = Date.now()
      root.run(["cat", root.path], function(text) {
        var kept = History.prune(History.parse(text), Date.now(), root.days).concat([entry])
        root.run(["sh", "-c", 'umask 077; mkdir -p "$(dirname "$1")" && cat > "$1.new" && mv "$1.new" "$1"', "sh", root.path],
          null, kept.map(History.line).join("\n") + "\n")
      })
      return
    }
    root.run(["sh", "-c", 'umask 077; mkdir -p "$(dirname "$1")" && cat >> "$1"', "sh", root.path], null, History.line(entry) + "\n")
  }

  function clear(callback) {
    root.entries = []
    root.changed()
    root.run(["rm", "-f", root.path], callback)
  }

  // ---------- One command at a time; callback(its output) ----------
  // What's written goes on the command's stdin (input), never its command
  // line (StdinProcess).

  property var queue: []
  function run(command, callback, input) {
    root.queue = root.queue.concat([{ command: command, callback: callback || null, input: input || "" }])
    root.next()
  }
  function next() {
    if (process.running || root.queue.length === 0) return
    process.current = root.queue[0]
    root.queue = root.queue.slice(1)
    process.feed(process.current.command, process.current.input)
  }
  StdinProcess {
    id: process
    property var current: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var callback = process.current ? process.current.callback : null
        process.current = null
        // Gone with a plugin reload, mid-read.
        if (callback && root && typeof root.next === "function") callback(text)
      }
    }
    stderr: StdioCollector {}
    onExited: Qt.callLater(root.next)
  }
}
