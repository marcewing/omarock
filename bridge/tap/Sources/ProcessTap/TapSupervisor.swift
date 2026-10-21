import CoreAudio
import Foundation
import os

public enum TapTarget: CustomStringConvertible {
    case pid(pid_t)
    case bundleID(String)
    /// A process and every process it is responsible for (its XPC services).
    case responsibleTo(pid_t)

    public var description: String {
        switch self {
        case .pid(let pid): return "pid \(pid)"
        case .bundleID(let id): return id
        case .responsibleTo(let pid): return "pid \(pid) and its helpers"
        }
    }
}

/// Keeps a ProcessTap on whatever processes `target` currently maps to, feeding `writer`,
/// and re-taps whenever that set changes. Polls once a second on its own queue, because
/// Core Audio calls can block for a long time (starting a tap waits on the audio capture
/// permission prompt) and callers must stay responsive.
public final class TapSupervisor {
    public enum Event {
        case status(String)
        /// A `.pid` target exited; it will not come back.
        case targetExited
        /// The tap's rate no longer matches the writer's; the caller must rebuild both.
        case rateMismatch(Double)
    }

    public let target: TapTarget
    public let writer: PCMWriter
    public let mute: Bool
    /// Called on the supervisor's queue.
    public var onEvent: (Event) -> Void = { _ in }

    private let queue = DispatchQueue(label: "ProcessTap.TapSupervisor")
    private var timer: DispatchSourceTimer?
    private var tap: ProcessTap?
    private var lastStatus = ""
    private var exited = false
    private var lock = os_unfair_lock()
    private var snapshot = (capturing: false, status: "not started", pids: [pid_t]())
    private var listener: AudioObjectPropertyListenerBlock?
    private var generation = 0  // under lock; read on the IO thread

    public init(target: TapTarget, writer: PCMWriter, mute: Bool = true) {
        self.target = target
        self.writer = writer
        self.mute = mute
    }

    /// Whether a tap is delivering audio, and the latest status line. Safe from any thread.
    /// Whether a tap is delivering audio, the latest status line, and the pids tapped.
    public var state: (capturing: Bool, status: String, pids: [pid_t]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshot
    }

    /// Looks again right away (say, just before something is about to play).
    public func refreshNow() {
        queue.async { [weak self] in self?.refresh() }
    }

    public func start() {
        // Re-tap as soon as Core Audio's process list changes, not on the next poll: a
        // helper that just opened its audio must be muted before it sounds.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        self.listener = listener

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    /// Stops polling and tears the tap down, waiting at most `timeout`: stopping an aggregate
    /// whose tapped process just died can hang in coreaudiod. Returns false on timeout.
    @discardableResult
    public func stop(timeout: TimeInterval = 1) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let listener {
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                self.listener = nil
            }
            let current = tap
            tap = nil
            writer.live = false
            setSnapshot(capturing: false, status: "stopped")
            DispatchQueue.global().async {
                current?.invalidate()
                done.signal()
            }
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func refresh() {
        do {
            let processes = try currentProcesses()
            if processes == tap?.processes ?? [] {
                if processes.isEmpty { report("waiting for \(target) to start audio", capturing: false) }
                return
            }
            guard !processes.isEmpty else {
                dropTap()
                return report("waiting for \(target) to start audio", capturing: false)
            }

            // The new tap (muting its processes) exists before the old one goes, so a
            // process that's playing is never unmuted in between.
            let newTap = try ProcessTap(processes: processes, mute: mute)
            let format = newTap.format
            guard format.isFloat32 else {
                newTap.invalidate()
                return report("unsupported tap format: \(format.summary)", capturing: false)
            }
            guard format.mSampleRate == writer.sampleRate else {
                newTap.invalidate()
                report("tap rate \(Int(format.mSampleRate)) differs from \(Int(writer.sampleRate))", capturing: false)
                return onEvent(.rateMismatch(format.mSampleRate))
            }
            let old = tap
            report("starting capture of \(processes) (blocks until audio capture is allowed)", capturing: false)
            // Only the newest tap feeds the writer; the old one keeps muting until it's gone.
            // (Stopping it here could hang if one of its processes just died.)
            let generation = nextGeneration()
            let writer = self.writer
            try newTap.start { [weak self] list in
                if self?.isCurrent(generation) == true { writer.push(list, format: format) }
            }
            tap = newTap
            writer.live = true
            if let old { DispatchQueue.global().async { old.invalidate() } }
            report("tapping \(processes.count) process object(s) \(processes), \(format.summary)", capturing: true)
        } catch {
            dropTap()
            report("\(error)", capturing: false)
        }
    }

    /// The process objects the target maps to now; empty if it has no audio client yet.
    private func currentProcesses() throws -> [AudioObjectID] {
        switch target {
        case .pid(let pid):
            if let object = try CoreAudio.processObject(pid: pid) { return [object] }
            if !exited && kill(pid, 0) != 0 && errno == ESRCH {
                exited = true
                report("\(target) has exited", capturing: false)
                onEvent(.targetExited)
            }
            return []
        case .bundleID(let bundleID):
            return try CoreAudio.processObjects(bundleID: bundleID)
        case .responsibleTo(let pid):
            return try CoreAudio.processObjects(responsibleTo: pid)
        }
    }

    /// Teardown runs off the queue, since it can hang when the tapped process has died.
    private func dropTap() {
        guard let current = tap else { return }
        tap = nil
        writer.live = false
        DispatchQueue.global().async { current.invalidate() }
    }

    private func report(_ status: String, capturing: Bool) {
        setSnapshot(capturing: capturing, status: status)
        if status != lastStatus { onEvent(.status(status)) }
        lastStatus = status
    }

    private func nextGeneration() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        generation += 1
        return generation
    }

    private func isCurrent(_ candidate: Int) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return candidate == generation
    }

    private func setSnapshot(capturing: Bool, status: String) {
        os_unfair_lock_lock(&lock)
        snapshot = (capturing, status, capturing ? (tap?.processes ?? []).compactMap(CoreAudio.pid(ofProcess:)) : [])
        os_unfair_lock_unlock(&lock)
    }
}
