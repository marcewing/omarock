import Combine
import Foundation
import IOKit.pwr_mgt
import MusicKit

/// ApplicationMusicPlayer, the status long poll, and the keep-awake assertion.
/// `seq` goes up on every change omarock would show (song, state, queue, shuffle,
/// repeat), never for position alone.
@MainActor
final class Player {
    private let player = ApplicationMusicPlayer.shared
    private(set) var seq = 1
    private var fingerprint = ""
    private var waiters: [Int: ([String: Any]) -> Void] = [:]
    private var nextWaiter = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    /// Confirms the process that renders playback is tapped (muted on the Mac). Nothing
    /// starts sounding unless it says yes.
    var ensureMuted: () async -> Bool = { false }

    func start() {
        // MusicKit publishes changes as objectWillChange; look once the change has landed.
        player.state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.check() }
        }.store(in: &subscriptions)
        player.queue.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.check() }
        }.store(in: &subscriptions)
        // And poll, in case a change slips past the publishers.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        fingerprint = currentFingerprint()
    }

    var isPlaying: Bool { player.state.playbackStatus == .playing }

    // MARK: Status

    func snapshot() -> [String: Any] {
        let entries = Array(player.queue.entries)
        let index = player.queue.currentEntry.flatMap { current in entries.firstIndex { $0.id == current.id } } ?? 0
        // At most 200 entries, from a little before the current one.
        let offset = max(0, min(index - 20, entries.count - 200))
        let window = entries.dropFirst(offset).prefix(200)

        var status: [String: Any] = [
            "seq": seq, "state": stateName,
            "position": position(), "positionAt": Date().timeIntervalSince1970,
            "queue": window.compactMap { song(of: $0) }.map(normalize),
            "queueIndex": index, "queueOffset": offset, "queueLength": entries.count,
            "shuffle": player.state.shuffleMode == .songs,
            "repeat": repeatName,
        ]
        if let song = player.queue.currentEntry.flatMap({ song(of: $0) }) { status["song"] = normalize(song) }
        return status
    }

    /// The entry `lastPosition` was read for, and the stale reading to hide after a change.
    private var positionEntry: String?
    private var lastPosition = 0.0
    private var staleAbove: (position: Double, until: Date)?
    /// Above 0 while play builds a new queue.
    private var settling = 0

    /// The player moves to a new entry a moment before its playbackTime leaves the old
    /// song's timeline (a jump read 203.8 s on a 198 s song). Until the time drops back,
    /// for at most 5 s, report the new song at 0.
    private func position() -> Double {
        let time = player.playbackTime
        let entry = player.queue.currentEntry
        if entry?.id != positionEntry {
            if positionEntry != nil, lastPosition > 1 { staleAbove = (lastPosition - 0.5, Date() + 5) }
            positionEntry = entry?.id
        }
        lastPosition = time
        if let stale = staleAbove {
            if time >= stale.position, Date() < stale.until { return 0 }
            staleAbove = nil
        }
        if let duration = entry.flatMap({ song(of: $0) })?.duration { return min(time, duration) }
        return time
    }

    /// Answers at once unless `since` is the current seq; then waits up to 25 s for a change.
    func status(since: Int?, respond: @escaping ([String: Any]) -> Void) {
        check()
        guard let since, since == seq else { return respond(snapshot()) }
        let id = nextWaiter
        nextWaiter += 1
        waiters[id] = respond
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                waiter(self.snapshot())
            }
        }
    }

    /// The songs in the whole queue, for { kind: "queue" }.
    var queueSongs: [Song] { player.queue.entries.compactMap { song(of: $0) } }

    // MARK: Transport

    /// `expanded` has nil for songs that can't play; `start` indexes it (the rows omarock
    /// shows), and playback starts at that song or the next playable one.
    func play(_ expanded: [Song?], start: Int, mode: String) async throws {
        let songs = expanded.compactMap { $0 }
        guard !songs.isEmpty else { throw APIError(status: 409, message: "Nothing in those items is available to play.") }
        remember(songs)
        switch mode {
        case "play":
            // Long polls see only where the queue lands, not the first song or a pause
            // on the way there.
            settling += 1
            defer { settling -= 1; check() }
            let from = max(0, min(start, expanded.count - 1))
            let first = expanded[from...].lazy.compactMap { $0 }.first ?? songs[0]
            // Catalog songs as a start item make prepareToPlay fail ("Prepare queue failed
            // with unexpected start item"), so start those queues at the top and move.
            let catalogStart = Source.guess(first.id) == .catalog && first.id != songs[0].id
            queued = songs
            queuedByEntry = [:]
            player.queue = catalogStart ? ApplicationMusicPlayer.Queue(for: songs)
                                        : ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
            if catalogStart {
                try await player.prepareToPlay()
                try await moveTo(first)
            }
            try await startSafely()
        case "next":
            if player.queue.entries.isEmpty { return try await play(expanded, start: 0, mode: "play") }
            let current = currentIndex ?? -1
            try await player.queue.insert(songs, position: .afterCurrentEntry)
            queued.insert(contentsOf: songs, at: min(current + 1, queued.count))
        case "add":
            if player.queue.entries.isEmpty { return try await play(expanded, start: 0, mode: "play") }
            try await player.queue.insert(songs, position: .tail)
            queued += songs
        default:
            throw APIError.badRequest("mode is play, next or add.")
        }
        check()
    }

    /// The player sometimes ignores the start item (catalog songs): move to it by hand
    /// before anything plays.
    private func moveTo(_ song: Song) async throws {
        // Right after prepareToPlay the queue may hold only its first entry; the rest
        // arrive a moment later.
        var entries = Array(player.queue.entries)
        for _ in 0..<50 where !entries.contains(where: { self.song(of: $0)?.id == song.id }) {
            try await Task.sleep(nanoseconds: 100_000_000)
            entries = Array(player.queue.entries)
        }
        let current = player.queue.currentEntry.flatMap { self.song(of: $0) }
        Log.info("player: queue of \(entries.count), current \(current?.title ?? "none"), wanted \(song.title)")
        guard current?.id != song.id,
              let entry = entries.first(where: { self.song(of: $0)?.id == song.id }) else { return }
        player.queue.currentEntry = entry
        Log.info("player: moved to \(player.queue.currentEntry.flatMap { self.song(of: $0) }?.title ?? "none")")
    }

    func pause() {
        player.pause()
        check()
    }

    /// pause, answering once the player says it paused (it takes a moment).
    func pauseSettled() async {
        pause()
        for _ in 0..<20 where isPlaying { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func resume() async throws {
        guard player.queue.currentEntry != nil else { return }
        try await startSafely()
        check()
    }

    /// Prepares the player (so its rendering helper opens its audio), waits for the tap to
    /// hold that helper, and only then plays. Never sounds on the Mac's speakers.
    private func startSafely() async throws {
        try await player.prepareToPlay()
        guard await ensureMuted() else {
            Log.error("player: playback isn't captured (not tapped yet), so not starting it")
            throw APIError(status: 503, message: "The bridge couldn't confirm its playback is captured and muted on the Mac, so it didn't start.")
        }
        try await player.play()
        // So the reply shows it playing, not the state from a moment before.
        for _ in 0..<20 where !isPlaying { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    func toggle() async throws {
        if isPlaying { await pauseSettled() } else { try await resume() }
    }

    func next() async throws {
        let from = player.queue.currentEntry?.id
        try await player.skipToNextEntry()
        // MusicKit moves a moment after skipToNextEntry returns; reply with where it went
        // (at most a second's wait, as at the end of the queue it doesn't move).
        for _ in 0..<20 where player.queue.currentEntry?.id == from {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check()
    }

    func previous() async throws {
        let wasPlaying = isPlaying
        try await player.skipToPreviousEntry()
        // MusicKit can pause a moment after skipping back; carry on playing, as next does.
        if wasPlaying {
            for _ in 0..<10 where isPlaying { try await Task.sleep(nanoseconds: 100_000_000) }
            if !isPlaying { try await startSafely() }
        }
        check()
    }

    func seek(to position: Double) {
        staleAbove = nil
        player.playbackTime = max(0, position)
    }

    func jump(to index: Int) async throws {
        let entries = Array(player.queue.entries)
        guard entries.indices.contains(index) else { throw APIError.notFound("No queue entry \(index).") }
        player.queue.currentEntry = entries[index]
        if !isPlaying { try await startSafely() }
        check()
    }

    func remove(at index: Int) throws {
        guard player.queue.entries.indices.contains(index) else { throw APIError.notFound("No queue entry \(index).") }
        if queued.count == player.queue.entries.count { queued.remove(at: index) }
        player.queue.entries.remove(at: index)
        check()
    }

    func setShuffle(_ on: Bool) {
        player.state.shuffleMode = on ? .songs : .off
        check()
    }

    func setRepeat(_ mode: String) throws {
        switch mode {
        case "off": player.state.repeatMode = MusicPlayer.RepeatMode.none
        case "one": player.state.repeatMode = .one
        case "all": player.state.repeatMode = .all
        default: throw APIError.badRequest("repeat mode is off, one or all.")
        }
        check()
    }

    // MARK: Changes

    private func check() {
        _ = position()  // keeps lastPosition at most a second old
        guard settling == 0 else { return }
        let now = currentFingerprint()
        if now != fingerprint {
            fingerprint = now
            seq += 1
            let pending = waiters
            waiters.removeAll()
            let state = snapshot()
            for waiter in pending.values { waiter(state) }
        }
        holdAwake(isPlaying)
    }

    private func currentFingerprint() -> String {
        // An entry's item can arrive after the entry; that changes what omarock shows.
        let ids = player.queue.entries.map { $0.id + ($0.item == nil ? "" : "+") }.joined(separator: ",")
        return [stateName, player.queue.currentEntry?.id ?? "", ids,
                "\(player.state.shuffleMode == .songs)", repeatName].joined(separator: "|")
    }

    private var stateName: String {
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: return "playing"
        case .paused, .interrupted: return "paused"
        default: return player.queue.currentEntry == nil ? "stopped" : "paused"
        }
    }

    private var repeatName: String {
        switch player.state.repeatMode {
        case .one: return "one"
        case .all: return "all"
        default: return "off"
        }
    }

    // MARK: Queue entries back to library songs

    /// The player turns the library songs it's given into entries with catalog ids, so a
    /// queue built from the library would read back as catalog songs (with artwork only
    /// Apple's API can fetch). Remember the library songs queued, and report those.
    private var librarySongs: [String: Song] = [:]

    private static func matchKey(_ song: Song) -> String {
        "\(song.title.lowercased())|\(song.artistName.lowercased())|\(Int((song.duration ?? 0).rounded()))"
    }

    private func remember(_ songs: [Song]) {
        if librarySongs.count > 20000 { librarySongs.removeAll() }
        for song in songs where Source.guess(song.id) == .library {
            librarySongs[Self.matchKey(song)] = song
        }
    }

    /// Library songs are reported as the ITLib song, with the ids and artwork the
    /// library details use.
    private func normalize(_ song: Song) -> [String: Any] {
        let song = Source.guess(song.id) == .catalog ? librarySongs[Self.matchKey(song)] ?? song : song
        if Source.guess(song.id) == .library { return Normalize.librarySong(song) }
        return Normalize.song(song)
    }

    /// The songs the bridge queued, in queue order, and which entry each went to.
    private var queued: [Song] = []
    private var queuedByEntry: [String: Song] = [:]
    private var reportedMissingItems = false

    private var currentIndex: Int? {
        player.queue.currentEntry.flatMap { current in player.queue.entries.firstIndex { $0.id == current.id } }
    }

    /// The entry's song. MusicKit can give entries no item at all (a library album of
    /// ripped songs: every entry, for as long as it played); those are the song the
    /// bridge queued with the entry's title, nearest its place, or at its place if
    /// MusicKit gives no title.
    private func song(of entry: ApplicationMusicPlayer.Queue.Entry) -> Song? {
        if case .song(let song) = entry.item { return song }
        if let song = queuedByEntry[entry.id] { return song }
        let entries = Array(player.queue.entries)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let titled = queued.indices.filter { queued[$0].title == entry.title }
        let pick = titled.min { abs($0 - index) < abs($1 - index) }
            ?? (entry.title.isEmpty && entries.count == queued.count ? index : nil)
        if !reportedMissingItems {
            reportedMissingItems = true
            Log.info("player: queue entries without a song item (\"\(entry.title)\"); "
                + (pick == nil ? "no queued song matches" : "reporting the songs queued"))
        }
        guard let pick else { return nil }
        queuedByEntry[entry.id] = queued[pick]
        return queued[pick]
    }

    /// The Mac stays awake while playing, and only then.
    private func holdAwake(_ awake: Bool) {
        if awake, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "omarock bridge is streaming Apple Music" as CFString, &sleepAssertion)
        } else if !awake, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
