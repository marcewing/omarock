import AppKit
import ProcessTap

/// The sound path: tap → PCMWriter → pipe → `OmarockBridge --encode` (libFLAC, Ogg FLAC;
/// see FlacEncoder), which is Icecast's source for the stream's mount (Secrets.streamMount).
///
/// The pipe outlives the encoder: we keep its read end open too, so when the encoder exits
/// the writer just blocks (the tap side drops audio) instead of failing with EPIPE, and the
/// restarted encoder reads from the same pipe. (Not Foundation's Pipe: Process closes the
/// parent's copy of a Pipe it hands to a child.) Icecast is started as our child unless this
/// account's is already on 127.0.0.1:8000; nothing is sent to anything else there (Icecast).
final class StreamService {
    private let config: Config
    private let sampleRate: Double
    private let pipeRead: Int32
    private let pipeWrite: Int32
    private let writer: PCMWriter
    private let supervisor: TapSupervisor
    /// `OmarockBridge --encode`.
    private var encoder: Process?
    private var icecast: Process?
    private var stopping = false
    private let mount: String

    init(config: Config) throws {
        self.config = config
        mount = try Secrets.streamMount()
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
    var encoderRunning: Bool { encoder?.isRunning ?? false }

    /// Seconds from a status's position to that audio reaching Icecast. The encoder holds it
    /// about half a FLAC frame plus 12 ms (the tap's and the PCMWriter's buffers, the write);
    /// but MusicKit's position is what the output device is playing, which the tap gets that
    /// device's output latency early. On built-in speakers that's the encoder's ~0.022 s less
    /// their 0.028 s, and the stream measured 0.006 s ahead of the position (0.8.1).
    var delay: Double {
        let latency = (try? CoreAudio.outputLatency(CoreAudio.defaultPlaybackDevice())) ?? 0
        return Double(FlacEncoder.blockSize) / 2 / sampleRate + 0.012 - latency
    }

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
        ensureIcecast { [self] in
            startEncoder()
            writer.start()
            supervisor.start()
        }
    }

    func stop() {
        stopping = true
        supervisor.stop()
        encoder?.terminate()
        icecast?.terminate()
    }

    // MARK: Icecast

    /// For /v1/health: `running` (an Icecast of this account took the last connection),
    /// `starting`, `taken` (something else answers on 127.0.0.1:8000 and gets nothing; see
    /// Icecast) or `failed` (it can't be started).
    private(set) var icecastState = "starting"

    /// Makes sure our Icecast is the one on 127.0.0.1:8000, then `next`: starts one if the
    /// port is free, uses this account's if one is already there, and while anything else
    /// answers, waits (checking every 5 s) rather than start a second one beside it.
    private func ensureIcecast(then next: @escaping () -> Void) {
        let executable = config.icecast
        offMain({ Icecast.holder(executable: executable) }) { [self] holder in
            guard !stopping else { return }
            switch holder {
            case .ours(let pid) where isStale(pid):
                // Say, one that outlived a bridge before 0.9.0, still on the old addresses and mount.
                Log.info("icecast: pid \(pid) started before icecast.xml last changed; restarting it")
                kill(pid, SIGTERM)
                waitForExit(pid) { [self] in
                    launchIcecast()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.ensureIcecast(then: next) }
                }
            case .ours(let pid):
                icecastIsOurs()
                guard pid != icecast?.processIdentifier else { return next() }
                Log.info("icecast: this account's Icecast (pid \(pid)) is already on 127.0.0.1:8000; using it")
                // Icecast only notices a dead source (say, ours before a restart) at its
                // source-timeout, and refuses a new one until then; the mount is ours, so clear it.
                killStaleSource(then: next)
            case .free:
                if icecast?.isRunning != true { launchIcecast() }
                // Give a fresh Icecast a moment to bind, then check it's the one answering.
                let wait: TimeInterval = icecastState == "failed" ? 5 : 1
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.ensureIcecast(then: next) }
            case .taken:
                icecastIsTaken()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.ensureIcecast(then: next) }
            }
        }
    }

    private func icecastIsOurs() {
        if icecastState == "taken" { Log.info("icecast: 127.0.0.1:8000 is this account's Icecast again") }
        icecastState = "running"
    }

    private func icecastIsTaken() {
        if icecastState != "taken" {
            Log.error("icecast: \(Icecast.NotOurs()); checking again every 5 s")
        }
        icecastState = "taken"
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
            icecastState = "failed"
            Log.error("icecast: cannot start \(config.icecast): \(error)")
        }
    }

    /// Whether Icecast `pid` started before icecast.xml's last change, and so runs on an older one.
    private func isStale(_ pid: pid_t) -> Bool {
        guard let written = (try? FileManager.default.attributesOfItem(atPath: Paths.icecastConfig.path))?[.modificationDate] as? Date
        else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
        return started < written
    }

    private func waitForExit(_ pid: pid_t, tries: Int = 50, then next: @escaping () -> Void) {
        guard kill(pid, 0) == 0, tries > 0 else { return next() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForExit(pid, tries: tries - 1, then: next) }
    }

    private func killStaleSource(then next: @escaping () -> Void) {
        let path = "/admin/killsource?mount=\(mount)"
        let executable = config.icecast
        offMain({ Result { try Icecast.admin(path, executable: executable) } }) { [self] result in
            switch result {
            // 200 with "Source Removed" if there was one; 400 if the mount was free.
            case .success(let (status, body)) where status == 200 && body.contains("Removed"):
                Log.info("icecast: removed a stale source from the stream's mount")
            case .failure(is Icecast.NotOurs):
                icecastIsTaken()
            default:
                break
            }
            next()
        }
    }

    /// An admin page from our Icecast (Icecast.admin), or nil: not 200, or not our Icecast.
    func icecastAdmin(_ path: String) async -> String? {
        let executable = config.icecast
        return await withCheckedContinuation { continuation in
            offMain({ Result { try Icecast.admin(path, executable: executable) } }) { [self] result in
                switch result {
                case .success(let (status, body)):
                    icecastIsOurs()
                    continuation.resume(returning: status == 200 ? body : nil)
                case .failure(let error):
                    if error is Icecast.NotOurs { icecastIsTaken() }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Runs `work` off the main thread (it blocks on sockets), then `done` with its result on it.
    private func offMain<T>(_ work: @escaping () -> T, then done: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = work()
            DispatchQueue.main.async { done(result) }
        }
    }

    // MARK: Encoder

    private func startEncoder() {
        guard !stopping, encoder?.isRunning != true else { return }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        // No mount argument: the encoder works out the stream's mount itself, so its
        // secret isn't on a command line that `ps` shows.
        process.arguments = ["--encode", String(Int(sampleRate))]
        // Each encoder gets its own copy of the read end; Process may close it after launch.
        process.standardInput = FileHandle(fileDescriptor: dup(pipeRead), closeOnDealloc: true)
        process.standardOutput = logFile("encoder.log")
        process.standardError = logFile("encoder.log")
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                // A new connection needs the stream's headers again, so a new encoder.
                if p.terminationReason == .exit, p.terminationStatus == Icecast.notOursStatus {
                    self.icecastIsTaken()
                } else {
                    Log.error("encoder: exited (\(p.terminationReason == .exit ? "status" : "signal") \(p.terminationStatus), see encoder.log); restarting in 1 s")
                }
                // If Icecast is what went away (say, one started by hand before the bridge),
                // run our own before the encoder reconnects; if something else took the port, wait.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.ensureIcecast { self.startEncoder() } }
            }
        }
        do {
            try process.run()
            encoder = process
            Log.info("encoder: pid \(process.processIdentifier), \(FlacEncoder.blockSize)-sample frames")
        } catch {
            Log.error("encoder: cannot start: \(error)")
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
