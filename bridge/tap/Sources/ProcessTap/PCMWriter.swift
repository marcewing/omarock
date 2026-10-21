import CoreAudio
import Foundation
import os

/// Converts tap buffers to interleaved s16le stereo and writes them to a file descriptor
/// from its own thread, so the IO thread never blocks on a pipe.
///
/// While no tap is feeding it (`live == false`), or a live tap has delivered nothing for
/// `stallTimeout` (its process died, or Core Audio stopped calling the IOProc), it writes
/// silence in real time instead, so a downstream encoder keeps a continuous stream.
public final class PCMWriter {
    public let sampleRate: Double
    /// Called once, from the writer thread, when the fd is closed by the reader (EPIPE) or fails.
    public var onClosed: (Int32) -> Void = { _ in }
    /// Called from the writer thread when audio had to be dropped because the reader fell behind.
    public var onOverflow: (Int) -> Void = { _ in }

    private let fd: Int32
    private let maxPending: Int
    private let stallNanos: UInt64
    private let wake = DispatchSemaphore(value: 0)
    private var lock = os_unfair_lock()
    private var pending: [Int16]
    private var dropped = 0
    private var isLive = false

    public init(fd: Int32, sampleRate: Double, maxBufferedSeconds: Double = 2, stallTimeout: Double = 0.2) {
        self.fd = fd
        self.sampleRate = sampleRate
        stallNanos = UInt64(stallTimeout * 1e9)
        maxPending = Int(sampleRate * maxBufferedSeconds) * 2
        pending = []
        pending.reserveCapacity(maxPending)
    }

    public var live: Bool {
        get { withLock { isLive } }
        set { withLock { isLive = newValue } }
    }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "PCMWriter"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// IO thread entry point. Accepts Float32 in either layout; mono is duplicated, channels past 2 dropped.
    public func push(_ list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        guard format.isFloat32 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let firstData = first.mData else { return }

        @inline(__always) func s16(_ x: Float) -> Int16 { Int16(max(-1, min(1, x)) * 32767) }

        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if format.isInterleaved {
            let channels = Int(first.mNumberChannels)
            guard channels > 0 else { return }
            let samples = firstData.assumingMemoryBound(to: Float.self)
            let frames = Int(first.mDataByteSize) / (4 * channels)
            guard reserve(frames) else { return }
            for f in 0..<frames {
                let l = samples[f * channels]
                pending.append(s16(l))
                pending.append(s16(channels > 1 ? samples[f * channels + 1] : l))
            }
        } else {
            let left = firstData.assumingMemoryBound(to: Float.self)
            let right = (buffers.count > 1 ? buffers[1].mData : nil)?.assumingMemoryBound(to: Float.self) ?? left
            let frames = Int(first.mDataByteSize) / 4
            guard reserve(frames) else { return }
            for f in 0..<frames {
                pending.append(s16(left[f]))
                pending.append(s16(right[f]))
            }
        }
        wake.signal()
    }

    /// Caller holds the lock.
    private func reserve(_ frames: Int) -> Bool {
        if pending.count + frames * 2 <= maxPending { return true }
        dropped += frames
        return false
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }

    private func run() {
        var chunk: [Int16] = []
        chunk.reserveCapacity(maxPending)
        var silence: [Int16] = []
        // Time of the last real audio, or up to which silence has been written since.
        var silenceClock = DispatchTime.now().uptimeNanoseconds

        while true {
            _ = wake.wait(timeout: .now() + .milliseconds(20))

            var nowLive = false
            var lost = 0
            withLock {
                chunk.append(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
                nowLive = isLive
                lost = dropped
                dropped = 0
            }
            if lost > 0 { onOverflow(lost) }

            let now = DispatchTime.now().uptimeNanoseconds
            if !chunk.isEmpty {
                guard chunk.withUnsafeBufferPointer({ write($0) }) else { return }
                chunk.removeAll(keepingCapacity: true)
                silenceClock = now
            } else if !nowLive || now - silenceClock > stallNanos {
                let frames = Int(Double(now - silenceClock) * sampleRate / 1e9)
                guard frames > 0 else { continue }
                if silence.count < frames * 2 { silence = [Int16](repeating: 0, count: frames * 2) }
                guard silence.withUnsafeBufferPointer({ write(UnsafeBufferPointer(rebasing: $0[0..<frames * 2])) })
                else { return }
                silenceClock += UInt64(Double(frames) * 1e9 / sampleRate)
            }
        }
    }

    private func write(_ samples: UnsafeBufferPointer<Int16>) -> Bool {
        guard var base = samples.baseAddress.map(UnsafeRawPointer.init) else { return true }
        var left = samples.count * MemoryLayout<Int16>.size
        while left > 0 {
            let n = Foundation.write(fd, base, left)
            if n < 0 {
                if errno == EINTR { continue }
                onClosed(errno)
                return false
            }
            base += n
            left -= n
        }
        return true
    }
}
