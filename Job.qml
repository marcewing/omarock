import QtQuick
import Quickshell.Io

// A command that always ends, and always says so: every Process the panel
// runs is one. Past its deadline it's stopped (SIGTERM, then SIGKILL 2 s
// later). A start that fails (no such program; no fork, under a pids or
// memory limit) ends as an exit with code 127 and no output: Quickshell then
// only says it isn't running, with no started, no exited and no end of its
// output, so whatever waited on those waited until the plugin reloaded.
// A command whose children could outlive it (a pipeline under sh) runs them
// under timeout(1), which stops them all: SIGKILL reaches only the first.
Process {
  id: job

  // How long it may run, in ms.
  property int deadline: 20000
  property bool began: false

  onStarted: {
    job.began = true
    job.stopTimer.restart()
  }
  onRunningChanged: {
    if (job.running) return
    job.stopTimer.stop()
    job.killTimer.stop()
    if (job.began) {
      job.began = false
      return
    }
    // It never started: an end of its output, then an exit, as a command
    // not found has in a shell.
    if (job.stdout && typeof job.stdout.streamFinished === "function") job.stdout.streamFinished()
    if (job.stderr && typeof job.stderr.streamFinished === "function") job.stderr.streamFinished()
    job.exited(127, 0)
  }

  property Timer stopTimer: Timer {
    interval: job.deadline
    onTriggered: {
      if (!job.running) return
      job.signal(15)
      job.killTimer.restart()
    }
  }
  property Timer killTimer: Timer {
    interval: 2000
    onTriggered: if (job.running) job.signal(9)
  }
}
