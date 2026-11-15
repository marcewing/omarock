import QtQuick
import Quickshell.Io

// A command given its input on stdin, never on its command line, where other
// accounts on this machine can read it (ps). It's how the panel writes its
// files: the settings (which can hold the Apple Music stream's private
// address), History and its caches, and HTTP (Fetch.qml). feed() runs it;
// the input is written as it starts, then stdin closes. A Job: it has a
// deadline, and a start that fails ends as an exit.
Job {
  id: root

  property string input: ""

  function feed(command, text) {
    root.command = command
    root.input = text
    root.stdinEnabled = true
    root.running = true
  }

  onStarted: {
    write(root.input)
    root.input = ""
    root.stdinEnabled = false
  }
}
