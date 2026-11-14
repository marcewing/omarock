import QtQuick
import Quickshell.Io

// Whether what listens on 127.0.0.1:PORT is this account's. Any account can
// bind a free loopback port first (while omarock-spotify or omarock-sxm is
// down, say), and would then get omarock's requests and choose its answers.
// The listening socket's owner comes from /proc/net/tcp: 127.0.0.1's, else
// the wildcard address's, as a connection to 127.0.0.1 would reach them.
// verify(then) checks again, then calls then().
Process {
  id: check

  property int port: 0
  property bool ours: false
  // The account that holds the port instead, or "" (ours, or nobody's).
  property string owner: ""
  property var waiting: []

  function verify(then) {
    check.waiting = check.waiting.concat([then || null])
    if (!check.running) check.running = true
  }

  command: ["sh", "-c", "id -u; awk -v p=\":$1\" '$4 == \"0A\" && ($2 == \"0100007F\" p || $2 == \"00000000\" p) {print $2, $8}' /proc/net/tcp | head -n 8",
    "sh", ("0000" + check.port.toString(16).toUpperCase()).slice(-4)]
  stdout: StdioCollector {
    onStreamFinished: {
      var lines = text.split("\n").filter(function(l) { return l !== "" })
      var me = lines.shift() || ""
      var rows = lines.map(function(l) { return l.split(" ") })
      var row = rows.filter(function(r) { return r[0].indexOf("0100007F") === 0 })[0] || rows[0]
      check.ours = !!row && row[1] === me
      check.owner = row && row[1] !== me ? row[1] : ""
      var waiting = check.waiting
      check.waiting = []
      waiting.forEach(function(then) { if (then) then() })
    }
  }
}
