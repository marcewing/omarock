import Foundation
import Security

/// ~/Library/Application Support/omarock-bridge: config, secrets and logs. Never in the repo.
/// $OMAROCK_BRIDGE_SUPPORT points a test copy (`--setup`) somewhere else.
enum Paths {
    static let support: URL = {
        if let dir = ProcessInfo.processInfo.environment["OMAROCK_BRIDGE_SUPPORT"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/omarock-bridge")
    }()
    static let config = support.appendingPathComponent("config.json")
    static let token = support.appendingPathComponent("token")
    static let icecastConfig = support.appendingPathComponent("icecast.xml")
    static let sourcePassword = support.appendingPathComponent("source.password")
    static let adminPassword = support.appendingPathComponent("admin.password")
    static let relayPassword = support.appendingPathComponent("relay.password")
    static let logs = support.appendingPathComponent("log")
}

/// config.json. Every field is optional.
struct Config: Decodable {
    /// Tap this pid instead of the bridge's own playback (testing).
    var tapPid: Int32?
    /// Tap this app instead of the bridge's own playback (testing).
    var tapBundle: String?
    /// The address the API and Icecast listen on; nil: the Mac's Tailscale address.
    var listenHost: String?
    var port: UInt16 = 8710
    /// The stream URL /health hands out; nil: http://{listenHost}:8000/omarock.ogg.
    var streamURL: String?
    var ffmpeg = Config.homebrew("ffmpeg")
    var icecast = Config.homebrew("icecast")
    /// Run as a launch agent: started at login, restarted after a crash.
    var startAtLogin = true

    enum CodingKeys: String, CodingKey {
        case tapPid, tapBundle, listenHost, port, streamURL, ffmpeg, icecast, startAtLogin
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tapPid = try c.decodeIfPresent(Int32.self, forKey: .tapPid)
        tapBundle = try c.decodeIfPresent(String.self, forKey: .tapBundle)
        listenHost = try c.decodeIfPresent(String.self, forKey: .listenHost)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? port
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL)
        ffmpeg = try c.decodeIfPresent(String.self, forKey: .ffmpeg) ?? ffmpeg
        icecast = try c.decodeIfPresent(String.self, forKey: .icecast) ?? icecast
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? startAtLogin
    }

    static func load() throws -> Config {
        guard let data = try? Data(contentsOf: Paths.config) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// The address to listen on: listenHost, else the Tailscale address (nil until it's up).
    var host: String? { listenHost ?? Tailnet.address() }

    func stream(host: String) -> String { streamURL ?? "http://\(host):8000/omarock.ogg" }

    /// A Homebrew tool, on Apple silicon (/opt/homebrew) or Intel (/usr/local). launchd's
    /// PATH has neither, so look in both.
    static func homebrew(_ tool: String) -> String {
        let candidates = ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
}

/// The Mac's address on the tailnet, so nothing listens anywhere else.
enum Tailnet {
    /// The first IPv4 address in Tailscale's range, 100.64.0.0/10, preferring a utun
    /// interface (where Tailscale puts it); nil while Tailscale is down.
    static func address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard UInt32(bigEndian: address.s_addr) & 0xFFC0_0000 == 0x6440_0000 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { continue }
            found.append((String(cString: entry.pointee.ifa_name), String(cString: text)))
        }
        return (found.first { $0.name.hasPrefix("utun") } ?? found.first)?.address
    }
}

enum Secrets {
    /// The API bearer token, created (32 random bytes, hex, mode 600) on first launch.
    static func token() throws -> String {
        try secret(Paths.token, bytes: 32)
    }

    /// Icecast's passwords, created (16 random bytes, hex, mode 600) on first launch.
    static func sourcePassword() throws -> String { try secret(Paths.sourcePassword, bytes: 16) }
    static func adminPassword() throws -> String { try secret(Paths.adminPassword, bytes: 16) }
    static func relayPassword() throws -> String { try secret(Paths.relayPassword, bytes: 16) }

    private static func secret(_ url: URL, bytes count: Int) throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeError("could not generate \(url.lastPathComponent)")
        }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePrivate(secret + "\n", to: url)
        Log.info("created \(url.path)")
        return secret
    }

    static func writePrivate(_ text: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw BridgeError("cannot create \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let data = Data(text.utf8)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw BridgeError("cannot write \(url.path)") }
    }
}

struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Appends to log/bridge.log (and stderr, for running from a shell).
enum Log {
    private static let queue = DispatchQueue(label: "omarock-bridge.log")
    private static let handle: FileHandle? = {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let url = Paths.logs.appendingPathComponent("bridge.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write("info", message) }
    static func error(_ message: String) { write("error", message) }

    private static func write(_ level: String, _ message: String) {
        let line = Data("\(formatter.string(from: Date())) \(level) \(message)\n".utf8)
        queue.async {
            handle?.write(line)
            FileHandle.standardError.write(line)
        }
    }
}
