import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public var description: String { "\(operation) failed: \(fourCC(status))" }
}

/// Renders an OSStatus as its four-char code when it is one ('who?', '!obj', ...).
func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }), let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)' (\(status))"
    }
    return "\(status)"
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(operation: operation(), status: status) }
}

/// Small typed wrappers over AudioObjectGetPropertyData.
public enum CoreAudio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "get property \(fourCC(OSStatus(bitPattern: selector))) of object \(object)")
        return value
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "get property \(fourCC(OSStatus(bitPattern: selector))) of object \(object)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func getObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "get size of object list")
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list), "get object list")
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// The device macOS plays system sounds through; process taps are clocked by it.
    public static func defaultOutputDevice() throws -> AudioObjectID {
        try get(system, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
    }

    public static func deviceUID(_ device: AudioObjectID) throws -> String {
        try getString(device, kAudioDevicePropertyDeviceUID)
    }

    public static func nominalSampleRate(_ device: AudioObjectID) throws -> Double {
        try get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    /// The Core Audio process object for `pid`, or nil if that process has no audio client yet.
    public static func processObject(pid: pid_t) throws -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                             &size, &object),
                  "translate pid \(pid) to process object")
        return object == kAudioObjectUnknown ? nil : object
    }

    /// The pid behind a process object.
    public static func pid(ofProcess object: AudioObjectID) -> pid_t? {
        try? get(object, kAudioProcessPropertyPID, initial: pid_t(0))
    }

    /// Every process object whose process `pid` is responsible for: the process itself and
    /// the XPC services working for it (MusicKit plays through MediaPlayer's
    /// RemotePlayerService, which is responsible to the app that asked).
    public static func processObjects(responsibleTo pid: pid_t) throws -> [AudioObjectID] {
        try getObjectList(system, kAudioHardwarePropertyProcessObjectList).filter { object in
            guard let owner = Self.pid(ofProcess: object) else { return false }
            return owner == pid || responsiblePID(for: owner) == pid
        }
    }

    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFor? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsibleFor.self) }

    /// The process macOS holds responsible for `pid` (itself for an ordinary app).
    public static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let responsibleFor else { return nil }
        let owner = responsibleFor(pid)
        return owner > 0 ? owner : nil
    }

    /// Every process object whose bundle ID is `bundleID` (an app can have several audio clients).
    public static func processObjects(bundleID: String) throws -> [AudioObjectID] {
        try getObjectList(system, kAudioHardwarePropertyProcessObjectList).filter {
            (try? getString($0, kAudioProcessPropertyBundleID)) == bundleID
        }
    }
}
