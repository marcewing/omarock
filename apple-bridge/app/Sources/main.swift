// The omarock bridge: an agent app (no Dock icon) that serves apple-bridge/API.md on the
// tailnet and streams its own playback to Icecast. See apple-bridge/API.md.

import AppKit

// Whatever ends the bridge (exit, NSApp.terminate), its last log lines go to the file first.
atexit { Log.flush() }

// `OmarockBridge --unregister`: remove the launch agent through SMAppService and exit, for
// the uninstalls (a `launchctl bootout` alone leaves SMAppService's record enabled).
if CommandLine.arguments.dropFirst().first == "--unregister" {
    exit(LoginAgent.unregister() ? 0 : 1)
}

// `OmarockBridge --setup`: make the token, Icecast's passwords and config, print what the
// Linux side needs as JSON, and exit. Touches nothing that asks for permission (build.sh
// runs it).
if CommandLine.arguments.dropFirst().first == "--setup" {
    do {
        let config = try Config.load()
        guard let host = config.host else {
            FileHandle.standardError.write(Data("No Tailscale address on this Mac: is Tailscale running and logged in?\n".utf8))
            exit(2)
        }
        _ = try Secrets.token()
        try IcecastConfig.prepare(host: host, icecast: config.icecast)
        let info: [String: Any] = ["bridge": "http://\(host):\(config.port)", "stream": config.stream(host: host),
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

        startWhenOnTailnet()
    }

    private var waitingLogged = false

    /// Serves only on the tailnet, so waits for Tailscale's address (at login it can come
    /// up after the bridge).
    @MainActor private func startWhenOnTailnet() {
        let config: Config
        do {
            config = try Config.load()
        } catch {
            Log.error("startup failed: cannot read \(Paths.config.path): \(error)")
            return NSApp.terminate(nil)
        }
        guard let host = config.host else {
            if !waitingLogged { Log.info("waiting for a Tailscale address (100.64.0.0/10) to serve on") }
            waitingLogged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startWhenOnTailnet() }
            return
        }
        do {
            let bridge = try Bridge(config: config, host: host)
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
