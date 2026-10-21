import Foundation

/// Pauses playback when the Icecast mount has had no listener for 30 s while playing,
/// so the Mac doesn't stream Apple Music for nobody.
///
/// The mount is hidden, so status-json.xsl leaves it out; /admin/stats (admin password)
/// still reports its listeners.
@MainActor
final class ListenerWatch {
    private static let grace: TimeInterval = 30

    private let player: Player
    private let onPause: () -> Void
    private var timer: Timer?
    private var silentSince: Date?

    init(player: Player, onPause: @escaping () -> Void) {
        self.player = player
        self.onPause = onPause
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard player.isPlaying else {
            silentSince = nil
            return
        }
        Task {
            guard let listeners = await Self.listeners() else { return }  // Icecast unreachable: don't guess
            if listeners > 0 {
                silentSince = nil
            } else if let since = silentSince {
                if Date().timeIntervalSince(since) >= Self.grace, player.isPlaying {
                    Log.info("player: no listener on the stream for \(Int(Self.grace)) s; pausing")
                    silentSince = nil
                    onPause()
                }
            } else {
                silentSince = Date()
            }
        }
    }

    private static func listeners() async -> Int? {
        guard let password = try? String(contentsOf: Paths.adminPassword, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/admin/stats")!)
        request.timeoutInterval = 2
        request.setValue("Basic " + Data("admin:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        // <source mount="/omarock.ogg">…<listeners>N</listeners>…</source>
        guard let mount = xml.range(of: "<source mount=\"/omarock.ogg\">") else { return 0 }  // no source: nobody hears it
        let rest = xml[mount.upperBound...]
        let end = rest.range(of: "</source>")?.lowerBound ?? rest.endIndex
        let source = rest[..<end]
        guard let open = source.range(of: "<listeners>"), let close = source.range(of: "</listeners>", range: open.upperBound..<source.endIndex)
        else { return nil }
        return Int(source[open.upperBound..<close.lowerBound])
    }
}
