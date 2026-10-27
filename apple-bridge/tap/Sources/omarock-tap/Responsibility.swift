import Darwin
import Foundation

// macOS asks for audio capture permission on behalf of the "responsible" process, which for
// a tool started from a shell is the terminal app. To be our own TCC client (identified by
// our code signature and embedded Info.plist), re-spawn ourselves with responsibility
// disclaimed, the way terminal emulators and debuggers do, and relay the child's exit.

private let disclaimedEnv = "OMAROCK_TAP_DISCLAIMED"

private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

/// Returns normally in the process that should do the work; otherwise never returns.
func becomeResponsibleProcess() {
    guard getenv(disclaimedEnv) == nil else { return }
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
        log("responsibility_spawnattrs_setdisclaim unavailable; permission will be checked against the parent app")
        return
    }
    let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    guard setDisclaim(&attr, 1) == 0 else {
        log("could not disclaim responsibility; permission will be checked against the parent app")
        return
    }

    setenv(disclaimedEnv, "1", 1)
    let args = CommandLine.arguments
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let path = Bundle.main.executablePath ?? args[0]
    let err = posix_spawn(&pid, path, nil, &attr, &argv, environ)
    guard err == 0 else {
        log("posix_spawn of \(path) failed: \(String(cString: strerror(err)))")
        exit(1)
    }

    // Pass termination signals on; the child cleans up and exits, and we follow.
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { kill(pid, sig) }
        source.resume()
        relaySources.append(source)
    }
    signal(SIGPIPE, SIG_IGN)

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let low = status & 0x7f
    exit(low == 0 ? (status >> 8) & 0xff : 128 + low)
}

private var relaySources: [DispatchSourceSignal] = []
