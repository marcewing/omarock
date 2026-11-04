// The omarock bridge: an agent app (no Dock icon) that serves apple-bridge/API.md on the
// Mac's networks and streams its own playback to Icecast. See apple-bridge/API.md.

import AppKit

// Whatever ends the bridge (exit, NSApp.terminate), its last log lines go to the file first.
atexit { Log.flush() }

// `OmarockBridge --unregister`: remove the launch agent through SMAppService and exit, for
// the uninstalls (a `launchctl bootout` alone leaves SMAppService's record enabled).
if CommandLine.arguments.dropFirst().first == "--unregister" {
    exit(LoginAgent.unregister() ? 0 : 1)
}

// `OmarockBridge --encode RATE [MOUNT]`: the stream's FLAC encoder, PCM in and Ogg FLAC out
// to Icecast's MOUNT (the stream's, Secrets.streamMount, if none; StreamService runs it),
// or to stdout for `-`.
if CommandLine.arguments.dropFirst().first == "--encode" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard let mount = args.dropFirst().first ?? (try? Secrets.streamMount()) else {
        FileHandle.standardError.write(Data("cannot read the token for the stream's mount\n".utf8))
        exit(1)
    }
    exit(FlacEncoder.run(sampleRate: UInt32(args.first ?? "") ?? 48000, mount: mount))
}

// `OmarockBridge --setup`: make the token, Icecast's passwords and config, print what the
// Linux side needs as JSON, and exit. Touches nothing that asks for permission (build.sh
// runs it). The stream's address isn't there: /v1/health gives it to token holders.
if CommandLine.arguments.dropFirst().first == "--setup" {
    do {
        let config = try Config.load()
        _ = try Secrets.token()
        try IcecastConfig.prepare(listenHost: config.listenHost, icecast: config.icecast)
        let host = config.listenHost ?? LocalName.bonjour() ?? "localhost"
        let info: [String: Any] = ["bridge": "http://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host):\(config.port)",
                                   "token": Paths.token.path, "support": Paths.support.path]
        let json = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(json + Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("setup failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var bridge: Bridge?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writes to a pipe whose reader died must fail with EPIPE, not kill the bridge.
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        // A copy opened by hand hands over to the launch agent and quits.
        if LoginAgent.handOverIfNeeded(enabled: (try? Config.load())?.startAtLogin ?? true) {
            exit(0)
        }

        start()
    }

    @MainActor private func start() {
        let config: Config
        do {
            config = try Config.load()
        } catch {
            Log.error("startup failed: cannot read \(Paths.config.path): \(error)")
            return NSApp.terminate(nil)
        }
        do {
            let bridge = try Bridge(config: config)
            bridge.start()
            self.bridge = bridge
        } catch {
            Log.error("startup failed: \(error)")
            NSApp.terminate(nil)
        }
    }

    /// Quits with a failure status, so launchd starts a fresh bridge (KeepAlive restarts
    /// only unsuccessful exits).
    @MainActor func restart(because reason: String) -> Never {
        Log.info("restarting: \(reason)")
        bridge?.stop()
        exit(75)
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
        Log.info("stopped")
    }
}
