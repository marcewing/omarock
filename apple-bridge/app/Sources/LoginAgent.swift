import Foundation
import ServiceManagement

/// Start at login, through the launch agent embedded in the app
/// (Contents/Library/LaunchAgents/{bundle id}.plist, written by the build), which launchd
/// also restarts after a crash.
///
/// The copy launchd runs has OMAROCK_BRIDGE_AGENT=1 and just runs. A copy opened by hand
/// (Finder, `open`) registers the agent if needed, hands over to it and quits, so there is
/// only ever one bridge, and it's the one launchd keeps alive.
enum LoginAgent {
    static let label = Bundle.main.bundleIdentifier ?? "org.omarock.bridge"
    private static let service = SMAppService.agent(plistName: "\(label).plist")

    static var isAgentCopy: Bool { ProcessInfo.processInfo.environment["OMAROCK_BRIDGE_AGENT"] == "1" }

    /// Call before anything else at launch. Returns true if this copy should quit, because
    /// the launch agent runs the bridge instead.
    static func handOverIfNeeded(enabled: Bool) -> Bool {
        guard !isAgentCopy else { return false }
        guard enabled else {
            if service.status == .enabled {
                try? service.unregister()
                Log.info("login: startAtLogin is off; unregistered the launch agent")
            }
            return false
        }
        do {
            if service.status != .enabled {
                try service.register()
                Log.info("login: registered the launch agent (\(describe(service.status)))")
            }
        } catch {
            Log.error("login: cannot register the launch agent: \(error); running this copy instead")
            return false
        }
        switch service.status {
        case .enabled:
            // Make sure launchd's copy runs (it may already, if registering started it).
            let kick = Process()
            kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            kick.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            try? kick.run()
            kick.waitUntilExit()
            Log.info("login: handing over to the launch agent")
            return true
        case .requiresApproval:
            Log.error("login: the launch agent needs approval in System Settings → General → Login Items; running this copy for now")
            return false
        default:
            Log.error("login: launch agent status \(describe(service.status)); running this copy instead")
            return false
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
