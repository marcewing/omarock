import Foundation

/// Pauses playback when the Icecast mount has had no listener for 30 s while playing,
/// so the Mac doesn't stream Apple Music for nobody.
///
/// The mount is hidden (and Icecast serves no status pages); /admin/stats (admin password)
/// still reports its listeners, asked through StreamService, which checks it's our Icecast.
@MainActor
final class ListenerWatch {
    private static let grace: TimeInterval = 30

    private let player: Player
    private let stream: StreamService
    private let onPause: () -> Void
    private var timer: Timer?
    private var silentSince: Date?

    init(player: Player, stream: StreamService, onPause: @escaping () -> Void) {
        self.player = player
        self.stream = stream
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
            guard let listeners = await listeners() else { return }  // Icecast unreachable: don't guess
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

    private func listeners() async -> Int? {
        guard let xml = await stream.icecastAdmin("/admin/stats") else { return nil }
        // <source mount="/omarock-SECRET.ogg">…<listeners>N</listeners>…</source>
        guard let name = try? Secrets.streamMount() else { return nil }
        guard let mount = xml.range(of: "<source mount=\"\(name)\">") else { return 0 }  // no source: nobody hears it
        let rest = xml[mount.upperBound...]
        let end = rest.range(of: "</source>")?.lowerBound ?? rest.endIndex
        let source = rest[..<end]
        guard let open = source.range(of: "<listeners>"), let close = source.range(of: "</listeners>", range: open.upperBound..<source.endIndex)
        else { return nil }
        return Int(source[open.upperBound..<close.lowerBound])
    }
}
