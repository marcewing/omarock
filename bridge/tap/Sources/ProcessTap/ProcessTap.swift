import AudioToolbox
import CoreAudio
import Foundation

/// A Core Audio process tap on a fixed set of processes: a stereo mixdown of their output,
/// read through a private aggregate device. With `mute`, those processes stop sounding on
/// the Mac's own output; nothing else on the system is affected.
///
/// Everything is torn down by `invalidate()` (or deinit). To follow a changing set of
/// processes, invalidate and create a new tap.
public final class ProcessTap {
    public let processes: [AudioObjectID]
    /// The tap's native format (normally Float32, 2 channels, at the output device's rate).
    public let format: AudioStreamBasicDescription

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    public init(processes: [AudioObjectID], mute: Bool = true, name: String = "omarock-tap") throws {
        self.processes = processes

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = name
        description.isPrivate = true
        description.muteBehavior = mute ? .muted : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        do {
            format = try CoreAudio.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())

            let outputUID = try CoreAudio.deviceUID(CoreAudio.defaultOutputDevice())
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: name,
                kAudioAggregateDeviceUIDKey: "\(name)-\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device),
                      "AudioHardwareCreateAggregateDevice")
            aggregateID = device
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    /// Starts capture. `handler` gets each input buffer list on Core Audio's real-time IO
    /// thread, so it must not block, allocate much, or take contended locks.
    public func start(_ handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        precondition(ioProcID == nil, "ProcessTap already started")
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            handler(input)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    public func invalidate() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }
}

extension AudioStreamBasicDescription {
    public var isFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM && mFormatFlags & kAudioFormatFlagIsFloat != 0 && mBitsPerChannel == 32
    }

    public var isInterleaved: Bool { mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 }

    public var summary: String {
        let kind = isFloat32 ? "f32" : "fmt=\(fourCC(OSStatus(bitPattern: mFormatID))) flags=\(mFormatFlags) bits=\(mBitsPerChannel)"
        return "\(kind) \(Int(mSampleRate)) Hz \(mChannelsPerFrame)ch \(isInterleaved ? "interleaved" : "planar")"
    }
}
