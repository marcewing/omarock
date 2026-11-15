import QtQuick
import Quickshell.Io

// Whether what listens on 127.0.0.1:PORT is this account's. Any account can
// bind a free loopback port first (while omarock-spotify or omarock-sxm is
// down, say), and would then get omarock's requests and choose its answers.
// The listening sockets a connection to 127.0.0.1 could reach come from
// /proc/net/tcp and tcp6: 127.0.0.1's and the wildcard's, and IPv6's :: and
// ::ffff:127.0.0.1 (an IPv6 socket on :: takes IPv4 connections too, and is
// only in tcp6). Ours only if every one is this account's.
// verify(then) checks again, then calls then(). One that can't run finds
// nobody's: not ours.
Job {
  id: check

  deadline: 5000
  property int port: 0
  property bool ours: false
  // The account that holds the port instead, or "" (ours, or nobody's).
  property string owner: ""
  property var waiting: []

  function verify(then) {
    check.waiting = check.waiting.concat([then || null])
    if (!check.running) check.running = true
  }

  command: ["sh", "-c", "id -u; awk -v p=\":$1\" '$4 == \"0A\" && ($2 == \"0100007F\" p || $2 == \"00000000\" p || $2 == \"0000000000000000FFFF00000100007F\" p || $2 == \"00000000000000000000000000000000\" p) {print $8}' /proc/net/tcp /proc/net/tcp6 | head -n 8",
    "sh", ("0000" + check.port.toString(16).toUpperCase()).slice(-4)]
  stdout: StdioCollector {
    onStreamFinished: {
      var lines = text.split("\n").filter(function(l) { return l !== "" })
      var me = lines.shift() || ""
      var other = lines.filter(function(uid) { return uid !== me })[0] || ""
      check.ours = lines.length > 0 && other === ""
      check.owner = other
      var waiting = check.waiting
      check.waiting = []
      waiting.forEach(function(then) { if (then) then() })
    }
  }
}
