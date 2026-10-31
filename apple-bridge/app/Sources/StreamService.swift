import AppKit
import ProcessTap

/// The sound path: tap → PCMWriter → pipe → `OmarockBridge --encode` (libFLAC, Ogg FLAC;
/// see FlacEncoder) → ffmpeg (0.2 s pages) → Icecast /omarock.ogg.
///
/// The pipe outlives the encoder: we keep its read end open too, so when the encoder exits
/// the writer just blocks (the tap side drops audio) instead of failing with EPIPE, and the
/// restarted encoder reads from the same pipe. (Not Foundation's Pipe: Process closes the
/// parent's copy of a Pipe it hands to a child.) Icecast is started as our child unless one is
/// already serving on 127.0.0.1:8000.
final class StreamService {
    private let config: Config
    private let sampleRate: Double
    private let pipeRead: Int32
    private let pipeWrite: Int32
    private let writer: PCMWriter
    private let supervisor: TapSupervisor
    /// ffmpeg, and the FLAC encoder in front of it.
    private var encoder: Process?
    private var flac: Process?
    private var icecast: Process?
    private var stopping = false

    init(config: Config) throws {
        self.config = config
        sampleRate = try CoreAudio.nominalSampleRate(CoreAudio.defaultOutputDevice())
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { throw BridgeError("pipe() failed: \(String(cString: strerror(errno)))") }
        pipeRead = fds[0]
        pipeWrite = fds[1]
        // Only children we hand a dup of the read end to should inherit the pipe.
        _ = fcntl(pipeRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipeWrite, F_SETFD, FD_CLOEXEC)
        writer = PCMWriter(fd: pipeWrite, sampleRate: sampleRate)

        let target: TapTarget
        if let pid = config.tapPid {
            target = .pid(pid)
        } else if let bundle = config.tapBundle {
            target = .bundleID(bundle)
        } else {
            // The bridge's own playback. MusicKit renders it in MediaPlayer's
            // RemotePlayerService, an XPC service responsible to the bridge, so tap the
            // bridge and everything it is responsible for, and nothing else.
            target = .responsibleTo(getpid())
        }
        supervisor = TapSupervisor(target: target, writer: writer)
    }

    var capturing: Bool { supervisor.state.capturing }

    /// Waits until a helper of the bridge (the process that actually renders MusicKit's
    /// audio) is tapped, and so muted on the Mac. Call before starting playback.
    @MainActor
    func waitUntilPlaybackIsTapped(timeout: TimeInterval = 3) async -> Bool {
        if config.tapPid != nil || config.tapBundle != nil { return supervisor.state.capturing }
        let me = getpid()
        let deadline = Date().addingTimeInterval(timeout)
        supervisor.refreshNow()
        while Date() < deadline {
            let state = supervisor.state
            if state.capturing, state.pids.contains(where: { $0 != me }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
    var encoderRunning: Bool { (encoder?.isRunning ?? false) && (flac?.isRunning ?? false) }

    func start() {
        Log.info("stream: s16le \(Int(sampleRate)) Hz stereo, tapping \(supervisor.target)")
        writer.onOverflow = { frames in Log.error("stream: encoder fell behind, dropped \(frames) frames") }
        writer.onClosed = { err in Log.error("stream: pipe write failed: \(String(cString: strerror(err)))") }
        supervisor.onEvent = { event in
            switch event {
            case .status(let message):
                Log.info("tap: \(message)")
            case .targetExited:
                Log.info("tap: target exited; streaming silence")
            case .rateMismatch(let rate):
                // The output device changed rate under us. Restarting is the simple way
                // to rebuild the writer and encoder at the new rate.
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.restart(because: "the output rate is now \(Int(rate)) Hz")
                }
            }
        }
        startIcecastIfNeeded { [self] in
            startEncoder()
            writer.start()
            supervisor.start()
        }
    }

    func stop() {
        stopping = true
        supervisor.stop()
        flac?.terminate()
        encoder?.terminate()
        icecast?.terminate()
    }

    // MARK: Icecast

    private func startIcecastIfNeeded(then next: @escaping () -> Void) {
        icecastAnswers { [self] up in
            if up {
                Log.info("icecast: already running on 127.0.0.1:8000, using it")
                // Icecast only notices a dead source (say, ours before a restart) at its
                // source-timeout, and refuses a new one until then; the mount is ours, so clear it.
                killStaleSource(then: next)
            } else {
                launchIcecast()
                // Give a fresh Icecast a moment to bind before ffmpeg connects; ffmpeg retries anyway.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: next)
            }
        }
    }

    private func launchIcecast() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.icecast)
        process.arguments = ["-c", Paths.icecastConfig.path]
        process.currentDirectoryURL = Paths.support
        process.standardOutput = logFile("icecast.stdout")
        process.standardError = logFile("icecast.stdout")
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                Log.error("icecast: exited with status \(p.terminationStatus); restarting in 2 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.launchIcecast() }
            }
        }
        do {
            try process.run()
            icecast = process
            Log.info("icecast: started, pid \(process.processIdentifier)")
        } catch {
            Log.error("icecast: cannot start \(config.icecast): \(error)")
        }
    }

    private func killStaleSource(then next: @escaping () -> Void) {
        guard let password = try? String(contentsOf: Paths.adminPassword, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return next() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/admin/killsource?mount=/omarock.ogg")!)
        request.timeoutInterval = 2
        request.setValue("Basic " + Data("admin:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // 200 with "Source Removed" if there was one; 400 if the mount was free.
            if status == 200, body.contains("Removed") { Log.info("icecast: removed a stale source from /omarock.ogg") }
            DispatchQueue.main.async(execute: next)
        }.resume()
    }

    private func icecastAnswers(_ done: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/status-json.xsl")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let up = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(up) }
        }.resume()
    }

    // MARK: Encoder

    private func startEncoder() {
        guard !stopping else { return }
        let password: String
        do {
            password = try Secrets.sourcePassword()
        } catch {
            Log.error("encoder: cannot read \(Paths.sourcePassword.path): \(error)")
            return
        }
        // The encoder and ffmpeg start and stop together: a new ffmpeg needs the stream's headers.
        if let old = flac, old.isRunning {
            old.terminate()
            old.waitUntilExit()
        }
        let encoded = Pipe()
        let flac = Process()
        flac.executableURL = Bundle.main.executableURL
        flac.arguments = ["--encode", String(Int(sampleRate))]
        // Each encoder gets its own copy of the read end; Process may close it after launch.
        flac.standardInput = FileHandle(fileDescriptor: dup(pipeRead), closeOnDealloc: true)
        flac.standardOutput = encoded
        flac.standardError = logFile("ffmpeg.log")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.ffmpeg)
        process.arguments = [
            "-hide_banner", "-nostdin", "-loglevel", "warning",
            "-f", "ogg", "-i", "pipe:0",
            "-c:a", "copy",
            "-f", "ogg", "-page_duration", "200000", "-flush_packets", "1",
            "-content_type", "application/ogg", "-ice_name", "omarock", "-ice_public", "0",
            "icecast://source:\(password)@127.0.0.1:8000/omarock.ogg",
        ]
        process.standardInput = encoded
        process.standardOutput = logFile("ffmpeg.log")
        process.standardError = logFile("ffmpeg.log")
        flac.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, !self.stopping, p.terminationReason == .exit else { return }
                // ffmpeg then ends at the end of its input, and starts them both again.
                Log.error("encoder: the FLAC encoder exited with status \(p.terminationStatus)")
            }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                Log.error("encoder: ffmpeg exited with status \(p.terminationStatus); restarting in 1 s")
                if flac.isRunning { flac.terminate() }
                // If Icecast is what went away (say, one started by hand before the bridge),
                // run our own before the encoder reconnects.
                self.icecastAnswers { up in
                    if !up, self.icecast?.isRunning != true {
                        Log.error("icecast: not answering on 127.0.0.1:8000; starting it")
                        self.launchIcecast()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startEncoder() }
                }
            }
        }
        do {
            try flac.run()
            self.flac = flac
        } catch {
            return Log.error("encoder: cannot start the FLAC encoder: \(error)")
        }
        do {
            try process.run()
            encoder = process
            Log.info("encoder: libFLAC pid \(flac.processIdentifier), ffmpeg pid \(process.processIdentifier)")
        } catch {
            flac.terminate()
            Log.error("encoder: cannot start \(config.ffmpeg): \(error)")
        }
    }

    private func logFile(_ name: String) -> FileHandle {
        let url = Paths.logs.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }
}
