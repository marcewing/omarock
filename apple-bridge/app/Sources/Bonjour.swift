import dnssd
import Foundation

/// Advertises the bridge as _omarock._tcp on the API's port, under the Mac's computer name,
/// with TXT version=VERSION, so omarock finds it on the network (apple-bridge/API.md).
///
/// macOS's Local Network privacy covers registering a Bonjour service (not accepting
/// connections), so the first registration asks the user; a denial leaves the bridge
/// reachable by name or address, only not found by itself.
@MainActor
final class Bonjour {
    /// advertised, waiting (for the first answer), denied (Local Network), failed, or off.
    private(set) var state: String

    private let port: UInt16
    private let version: String
    private let enabled: Bool
    private var service: DNSServiceRef?
    private var stopped = false

    init(port: UInt16, version: String, enabled: Bool) {
        self.port = port
        self.version = version
        self.enabled = enabled
        state = enabled ? "waiting" : "off"
    }

    func start() {
        guard enabled, !stopped, service == nil else { return }
        state = "waiting"
        let entry = Array("version=\(version)".utf8)
        let txt = [UInt8(entry.count)] + entry
        var ref: DNSServiceRef?
        // A nil name is the computer name, renamed by mDNSResponder if another Mac has it.
        let status = DNSServiceRegister(&ref, 0, 0, nil, "_omarock._tcp", nil, nil, port.bigEndian, UInt16(txt.count), txt,
                                        { _, _, error, name, _, _, context in
                                            guard let context else { return }
                                            let me = Unmanaged<Bonjour>.fromOpaque(context).takeUnretainedValue()
                                            let name = name.map { String(cString: $0) } ?? ""
                                            MainActor.assumeIsolated { me.registered(error, name) }
                                        }, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let ref else { return failed(status) }
        DNSServiceSetDispatchQueue(ref, .main)
        service = ref
    }

    func stop() {
        stopped = true
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
    }

    private func registered(_ error: DNSServiceErrorType, _ name: String) {
        switch Int(error) {
        case kDNSServiceErr_NoError:
            state = "advertised"
            Log.info("bonjour: advertised as \"\(name)\" (_omarock._tcp, port \(port))")
        case kDNSServiceErr_PolicyDenied:
            // mDNSResponder keeps the registration, and goes on if the user allows it later.
            if state != "denied" {
                Log.error("bonjour: Local Network access is denied, so omarock can't find this Mac by itself "
                    + "(System Settings → Privacy & Security → Local Network)")
            }
            state = "denied"
        default:
            failed(error)
        }
    }

    /// Say, mDNSResponder restarting: register again shortly.
    private func failed(_ error: DNSServiceErrorType) {
        Log.error("bonjour: can't advertise (DNSServiceErrorType \(error)); retrying in 10 s")
        state = "failed"
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.start() }
    }
}
