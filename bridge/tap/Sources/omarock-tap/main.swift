// omarock-tap: capture one process's (or one app's) audio with a Core Audio process tap
// and write it to stdout as interleaved s16le stereo at the tap's native rate.
//
//   omarock-tap --pid 1234
//   omarock-tap --bundle com.apple.Music
//   omarock-tap --rate        # print the rate a capture would use, then exit
//
// stderr gets one "format ..." line, then status and errors. The target is muted on the
// Mac's own output while tapped. Silence is written while the target has no audio client
// (not started yet, or between processes), so the stream never stalls.
//
// Exit status: 0 on SIGTERM/SIGINT/SIGHUP or when the reader closes the pipe, 3 when a
// --pid target has exited, 4 when the tap's rate changed (restart to pick up the new one).

import CoreAudio
import Foundation
import ProcessTap

let timestamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(timestamp.string(from: Date())) omarock-tap: \(message)\n".utf8))
}

func usage() -> Never {
    log("usage: omarock-tap (--pid N | --bundle BUNDLE_ID) [--no-mute] | --rate")
    exit(2)
}

var target: TapTarget?
var mute = true
var printRate = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--pid":
        guard let value = args.popFirst(), let pid = pid_t(value) else { usage() }
        target = .pid(pid)
    case "--bundle":
        guard let value = args.popFirst() else { usage() }
        target = .bundleID(value)
    case "--no-mute":
        mute = false
    case "--rate":
        printRate = true
    default:
        usage()
    }
}
guard printRate || target != nil else { usage() }

if !printRate { becomeResponsibleProcess() }

// Writes to a closed pipe fail with EPIPE instead of killing us, so we can clean up.
signal(SIGPIPE, SIG_IGN)

let sampleRate: Double
do {
    sampleRate = try CoreAudio.nominalSampleRate(CoreAudio.defaultOutputDevice())
} catch {
    log("\(error)")
    exit(1)
}
if printRate {
    print(Int(sampleRate))
    exit(0)
}
guard let target else { usage() }
log("format s16le rate=\(Int(sampleRate)) channels=2")

let writer = PCMWriter(fd: STDOUT_FILENO, sampleRate: sampleRate)
let supervisor = TapSupervisor(target: target, writer: writer, mute: mute)

func shutdown(_ code: Int32) -> Never {
    if !supervisor.stop() { log("tap teardown timed out") }
    exit(code)
}

writer.onClosed = { err in
    if err != EPIPE { log("write to stdout failed: \(String(cString: strerror(err)))") }
    DispatchQueue.main.async { shutdown(err == EPIPE ? 0 : 1) }
}
writer.onOverflow = { frames in log("reader fell behind, dropped \(frames) frames") }

supervisor.onEvent = { event in
    switch event {
    case .status(let message):
        log(message)
    case .targetExited:
        DispatchQueue.main.async { shutdown(3) }
    case .rateMismatch:
        log("exiting so the caller restarts at the new rate")
        DispatchQueue.main.async { shutdown(4) }
    }
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { shutdown(0) }
    source.resume()
    signalSources.append(source)
}

writer.start()
supervisor.start()
dispatchMain()
