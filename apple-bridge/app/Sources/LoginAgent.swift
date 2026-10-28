import Foundation
import ServiceManagement

/// Start at login, through the launch agent embedded in the app
/// (Contents/Library/LaunchAgents/{bundle id}.plist, written by the build), which launchd
/// also restarts after a crash.
///
/// The copy launchd runs has OMAROCK_BRIDGE_AGENT=1 and just runs. A copy opened by hand
/// (Finder, `open`) registers the agent if needed, hands over to it and quits, so there is
/// only ever one bridge, and it's the one launchd keeps alive. It hands over only once
/// launchd has the job: SMAppService can say enabled when launchd has none (after a
/// `launchctl bootout`), and then it registers the agent again, or runs this copy.
enum LoginAgent {
    static let label = Bundle.main.bundleIdentifier ?? "org.omarock.bridge"
    private static let service = SMAppService.agent(plistName: "\(label).plist")

    static var isAgentCopy: Bool { ProcessInfo.processInfo.environment["OMAROCK_BRIDGE_AGENT"] == "1" }

    /// Call before anything else at launch. Returns true if this copy should quit, because
    /// the launch agent runs the bridge instead.
    static func handOverIfNeeded(enabled: Bool) -> Bool {
        guard !isAgentCopy else { return false }
        guard enabled else {
            if [.enabled, .requiresApproval].contains(service.status) {
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
        if service.status == .enabled, !startAgent() {
            Log.error("login: the launch agent is registered, but launchd has no such job; registering it again")
            try? service.unregister()
            do {
                try service.register()
            } catch {
                Log.error("login: cannot register the launch agent: \(error); running this copy instead")
                return false
            }
        }
        switch service.status {
        case .enabled:
            guard startAgent() else {
                Log.error("login: launchd doesn't start the launch agent; running this copy instead")
                return false
            }
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

    /// Starts launchd's copy if it isn't running (registering may already have), and says
    /// whether launchd has the job. Tries for a second, in case launchd is just loading it.
    private static func startAgent() -> Bool {
        let job = "gui/\(getuid())/\(label)"
        for attempt in 0..<5 {
            if attempt > 0 { usleep(200_000) }
            if launchctl("kickstart", job) == 0, launchctl("print", job) == 0 { return true }
        }
        return false
    }

    /// For the uninstalls (`OmarockBridge --unregister`): stops the launch agent and forgets it.
    static func unregister() -> Bool {
        guard [.enabled, .requiresApproval].contains(service.status) else {
            print("The launch agent \(label) isn't registered (\(describe(service.status))).")
            return true
        }
        do {
            try service.unregister()
        } catch {
            Log.error("login: cannot unregister the launch agent: \(error)")
            FileHandle.standardError.write(Data("Cannot unregister the launch agent \(label): \(error)\n".utf8))
            return false
        }
        Log.info("login: unregistered the launch agent (--unregister)")
        print("Unregistered the launch agent \(label).")
        return true
    }

    private static func launchctl(_ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
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
