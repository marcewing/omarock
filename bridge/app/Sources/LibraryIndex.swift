import AppKit
import Foundation
import iTunesLibrary
import MusicKit
import os

/// An in-memory snapshot of the music library from ITLib (iTunesLibrary.framework), for
/// the library lists and for what MusicKit's library leaves out.
///
/// On macOS MusicKit's library is ITLib underneath, but its requests queue behind each
/// other and some (the artist list, certain playlists) take tens of seconds or never
/// return, and an album's artistName is empty unless its tracks carry an Album Artist tag.
/// ITLib loads the whole library in about 3 s, and its persistent ids are MusicKit's
/// library ids (as signed 64-bit numbers), so lists come from here and details, search
/// and playback from MusicKit.
///
/// ITLib also holds songs that are only in playlists (Apple Music songs never added to
/// the library), with no flag to tell them apart. So which albums and playlists count as
/// "the library" comes from MusicKit's own lists, fetched in the background.
final class LibraryIndex {
    struct AlbumEntry {
        let id: String
        let title: String
        let artist: String?
        let genre: String?
        let year: Int?
        let isCompilation: Bool
        let trackCount: Int
        let added: Date
        /// A track to take artwork from.
        let artworkItem: ITLibMediaItem?
        let artistIDs: Set<String>
        /// Song ids in disc and track order.
        let trackIDs: [String]
    }

    struct ArtistEntry {
        let id: String
        let name: String
    }

    struct PlaylistEntry {
        let id: String
        let name: String
        let trackCount: Int
        let canEdit: Bool
        /// Song ids in playlist order.
        let trackIDs: [String]
    }

    private struct Snapshot {
        var albums: [AlbumEntry] = []
        var albumsByID: [String: AlbumEntry] = [:]
        var artists: [ArtistEntry] = []
        var playlists: [PlaylistEntry] = []
        var items: [String: ITLibMediaItem] = [:]
        /// Songs by title|artist|seconds, to recognise MusicKit's copies of them.
        var itemsByKey: [String: ITLibMediaItem] = [:]
        /// Song ids in the Music app's Favorite Songs (once Loved Songs); nil if it has none.
        var favorites: Set<String>?
        var library: ITLibrary?
    }

    static let shared = LibraryIndex()

    private let queue = DispatchQueue(label: "omarock-bridge.LibraryIndex", qos: .utility)
    private var lock = os_unfair_lock()
    private var snapshot = Snapshot()
    private var timer: DispatchSourceTimer?
    /// Library album and playlist ids according to MusicKit; nil until first fetched.
    private var memberAlbums: Set<String>?
    private var memberPlaylists: Set<String>?

    /// Loads now and every 5 minutes, off the main queue.
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 300)
        timer.setEventHandler { [weak self] in self?.reload() }
        timer.resume()
        self.timer = timer
    }

    var isLoaded: Bool { read { $0.library != nil } }

    /// By artist (unknown last), then year, then title.
    var albums: [AlbumEntry] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let members = memberAlbums else { return snapshot.albums }
        return snapshot.albums.filter { members.contains($0.id) }
    }

    /// By name: the track artists of the library's albums.
    var artists: [ArtistEntry] {
        let ids = albums.reduce(into: Set<String>()) { $0.formUnion($1.artistIDs) }
        return read { $0.artists.filter { ids.contains($0.id) } }
    }

    /// By name; no folders, no hidden or system playlists.
    var playlists: [PlaylistEntry] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let members = memberPlaylists else { return snapshot.playlists }
        return snapshot.playlists.filter { members.contains($0.id) }
    }

    /// Fetches MusicKit's library album and playlist ids now and every 5 minutes. A fetch
    /// that hangs (they can) is abandoned after 60 s, and the last good set kept.
    @MainActor
    func startMembership() {
        guard !membershipStarted else { return }
        membershipStarted = true
        Task { @MainActor in
            while true {
                if let ids = await Self.ids(of: Album.self) { setMembers(albums: ids) }
                if let ids = await Self.ids(of: Playlist.self) { setMembers(playlists: ids) }
                if let cloud = await Self.fetchCloudPlaylists() {
                    setCloud(cloud)
                    await countCloudOnlyPlaylists()
                }
                let (a, p) = read { _ in (memberAlbums?.count ?? -1, memberPlaylists?.count ?? -1) }
                let c = read { _ in cloudPlaylists?.count ?? -1 }
                Log.info("library index: MusicKit lists \(a) albums, \(p) playlists; iCloud has \(c) playlists")
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    private var membershipStarted = false

    private func setMembers(albums: Set<String>? = nil, playlists: Set<String>? = nil) {
        os_unfair_lock_lock(&lock)
        if let albums { memberAlbums = albums }
        if let playlists { memberPlaylists = playlists }
        os_unfair_lock_unlock(&lock)
    }

    @MainActor
    private static func ids<T: MusicLibraryRequestable>(of type: T.Type) async -> Set<String>? {
        await withCheckedContinuation { (done: CheckedContinuation<Set<String>?, Never>) in
            var finished = false
            let finish: (Set<String>?) -> Void = { ids in
                guard !finished else { return }
                finished = true
                done.resume(returning: ids)
            }
            Task { @MainActor in
                let ids = try? await MusicLibraryRequest<T>().response().items.map { $0.id.rawValue }
                finish(ids.map(Set.init))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                MainActor.assumeIsolated {
                    if !finished { Log.error("library index: MusicKit's \(T.self) list didn't answer in 60 s") }
                    finish(nil)
                }
            }
        }
    }

    func albumArtist(_ albumID: String) -> String? { read { $0.albumsByID[albumID]?.artist } }

    func album(_ id: String) -> AlbumEntry? { read { $0.albumsByID[id] } }
    func playlist(_ id: String) -> PlaylistEntry? { listing(id)?.entry }
    func item(_ id: String) -> ITLibMediaItem? { read { $0.items[id] } }

    /// Whether a song is a favorite (loved); nil when the library has no Favorite Songs.
    func isFavorite(_ id: String) -> Bool? { read { $0.favorites?.contains(id) } }

    // MARK: Matching catalog items to the library

    /// Library songs (on the library's albums) that look like this song: the same title
    /// and artist, ignoring case, accents and a trailing "(Remastered)" or the like, and
    /// within a few seconds of its length. Exact titles first.
    func songs(like title: String, artist: String, duration: Double?) -> [ITLibMediaItem] {
        let memberAlbums = Set(albums.map(\.id))
        let (t, core, a) = (Self.fold(title), Self.core(title), Self.fold(artist))
        let candidates = read { snapshot in
            snapshot.items.values.filter { item in
                guard memberAlbums.contains(Self.key(item.album.persistentID)),
                      Self.sameArtist(Self.fold(item.artist?.name ?? ""), a) else { return false }
                let it = Self.fold(item.title)
                guard it == t || Self.core(item.title) == core else { return false }
                guard let duration, item.totalTime > 0 else { return true }
                return abs(Double(item.totalTime) / 1000 - duration) <= (it == t ? 3 : 6)
            }
        }
        return candidates.sorted { (Self.fold($0.title) == t ? 0 : 1) < (Self.fold($1.title) == t ? 0 : 1) }
    }

    /// Library albums that look like this album: the same title (ignoring an edition in
    /// brackets) and album artist.
    func albums(like title: String, artist: String) -> [AlbumEntry] {
        let (t, core, a) = (Self.fold(title), Self.core(title), Self.fold(artist))
        return albums.filter { Self.sameArtist(Self.fold($0.artist ?? ""), a) && (Self.fold($0.title) == t || Self.core($0.title) == core) }
            .sorted { (Self.fold($0.title) == t ? 0 : 1, -$0.trackCount) < (Self.fold($1.title) == t ? 0 : 1, -$1.trackCount) }
    }

    /// "Diane (Remastered)", "Zen Arcade [Deluxe Edition]" and "Diane - 2009 Remaster" → the bare title.
    static func core(_ title: String) -> String {
        var s = fold(title)
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, #"\s+-\s+[^-]*(remaster|version|edition|mix|live|mono|stereo)[^-]*$"#] {
            while let range = s.range(of: pattern, options: .regularExpression), range.lowerBound > s.startIndex {
                s.removeSubrange(range)
            }
        }
        return s
    }

    /// The same artist, or one is the other plus guests ("X & Y", "X feat. Y").
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b + " ") || b.hasPrefix(a + " ") || a.hasPrefix(b + ",") || b.hasPrefix(a + ",")
    }

    // MARK: iCloud playlists

    /// One of the user's iCloud library playlists, from Apple's web API.
    struct CloudPlaylist {
        let id: String  // p.…
        let name: String
        let canEdit: Bool
        var lastModified: Date?
        var trackCount: Int?
        var artwork: [String: Any]?
    }

    /// A row of /library/playlists: an ITLib playlist with its iCloud twin, or an
    /// iCloud-only playlist the local library hasn't synced yet.
    struct PlaylistListing {
        let entry: PlaylistEntry?
        let cloud: CloudPlaylist?
        let cloudLoaded: Bool
        let bumped: Date?

        var id: String { entry?.id ?? cloud!.id }
        var name: String { entry?.name ?? cloud!.name }
        var trackCount: Int? { entry?.trackCount ?? cloud?.trackCount }
        /// Regular (not smart) and, once Apple's list is in, editable there.
        var canEdit: Bool {
            if let entry, !entry.canEdit { return false }
            guard cloudLoaded else { return entry?.canEdit ?? false }
            return cloud?.canEdit ?? false
        }
        var lastModified: Date? {
            [bumped, cloud?.lastModified].compactMap { $0 }.max()
        }
    }

    /// nil until fetched.
    private var cloudPlaylists: [CloudPlaylist]?
    /// When the bridge itself last changed a playlist, by iCloud id.
    private var bumped: [String: Date] = [:]

    private func setCloud(_ cloud: [CloudPlaylist]) {
        os_unfair_lock_lock(&lock)
        // Keep counts learned for playlists the new list doesn't count.
        let known = Dictionary((cloudPlaylists ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        cloudPlaylists = cloud.map { playlist in
            var playlist = playlist
            if playlist.trackCount == nil { playlist.trackCount = known[playlist.id]?.trackCount }
            return playlist
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Records a playlist the bridge just created, so it lists at once.
    func addCloudPlaylist(_ playlist: CloudPlaylist) {
        os_unfair_lock_lock(&lock)
        cloudPlaylists = (cloudPlaylists ?? []).filter { $0.id != playlist.id } + [playlist]
        bumped[playlist.id] = Date()
        os_unfair_lock_unlock(&lock)
    }

    /// Records that the bridge added `count` songs to a playlist.
    func bumpCloudPlaylist(_ id: String, added count: Int) {
        os_unfair_lock_lock(&lock)
        bumped[id] = Date()
        if let index = cloudPlaylists?.firstIndex(where: { $0.id == id }), let n = cloudPlaylists?[index].trackCount {
            cloudPlaylists?[index].trackCount = n + count
        }
        os_unfair_lock_unlock(&lock)
    }

    func setCloudTrackCount(_ id: String, _ count: Int) {
        os_unfair_lock_lock(&lock)
        if let index = cloudPlaylists?.firstIndex(where: { $0.id == id }) { cloudPlaylists?[index].trackCount = count }
        os_unfair_lock_unlock(&lock)
    }

    /// The library's playlists: ITLib's (matched to their iCloud twins by name, and by song
    /// count where names repeat; smart playlists aren't in iCloud) plus iCloud-only ones.
    var playlistListings: [PlaylistListing] {
        let entries = playlists
        os_unfair_lock_lock(&lock)
        let cloud = cloudPlaylists
        let bumped = self.bumped
        os_unfair_lock_unlock(&lock)

        var pool = Dictionary(grouping: cloud ?? [], by: \.name)
        var rows: [PlaylistListing] = entries.map { entry in
            var twin: CloudPlaylist?
            if entry.canEdit, var candidates = pool[entry.name], !candidates.isEmpty {
                let pick = candidates.firstIndex { $0.trackCount == entry.trackCount } ?? 0
                twin = candidates.remove(at: pick)
                pool[entry.name] = candidates
            }
            return PlaylistListing(entry: entry, cloud: twin, cloudLoaded: cloud != nil, bumped: twin.flatMap { bumped[$0.id] })
        }
        rows += pool.values.joined().map {
            PlaylistListing(entry: nil, cloud: $0, cloudLoaded: true, bumped: bumped[$0.id])
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A playlist by its ITLib id or its iCloud id.
    func listing(_ id: String) -> PlaylistListing? {
        playlistListings.first { $0.entry?.id == id || $0.cloud?.id == id }
    }

    @MainActor
    private static func fetchCloudPlaylists() async -> [CloudPlaylist]? {
        var playlists: [CloudPlaylist] = []
        var path: String? = "/v1/me/library/playlists?limit=100"
        let dates = ISO8601DateFormatter()
        while let next = path {
            guard let url = URL(string: "https://api.music.apple.com" + next),
                  let data = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            for item in json["data"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any],
                      let name = a["name"] as? String else { continue }
                playlists.append(cloudPlaylist(id: id, name: name, attributes: a, dates: dates))
            }
            path = json["next"] as? String
        }
        return playlists
    }

    static func cloudPlaylist(id: String, name: String, attributes a: [String: Any],
                              dates: ISO8601DateFormatter = ISO8601DateFormatter()) -> CloudPlaylist {
        var artwork: [String: Any]?
        if let art = a["artwork"] as? [String: Any], let url = art["url"] as? String, url.hasPrefix("https://") {
            artwork = ["url": url]
            artwork?["width"] = art["width"]
            artwork?["height"] = art["height"]
            artwork?["bgColor"] = art["bgColor"]
            artwork?["textColor"] = art["textColor1"]
        }
        return CloudPlaylist(id: id, name: name, canEdit: a["canEdit"] as? Bool ?? false,
                             lastModified: ((a["lastModifiedDate"] ?? a["dateAdded"]) as? String).flatMap(dates.date(from:)),
                             trackCount: nil, artwork: artwork)
    }

    /// Song counts for iCloud-only playlists (Apple's list doesn't give them).
    @MainActor
    private func countCloudOnlyPlaylists() async {
        for row in playlistListings where row.entry == nil && row.cloud?.trackCount == nil {
            guard let id = row.cloud?.id,
                  let url = URL(string: "https://api.music.apple.com/v1/me/library/playlists/\(id)/tracks?limit=1"),
                  let data = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let total = (json["meta"] as? [String: Any])?["total"] as? Int else { continue }
            setCloudTrackCount(id, total)
        }
    }

    /// MusicKit's iCloud library ids (i.…) for ITLib song ids, as songs are played.
    private var aliases: [String: String] = [:]

    func alias(_ musicKitID: String, to itlibID: String) {
        os_unfair_lock_lock(&lock)
        aliases[musicKitID] = itlibID
        os_unfair_lock_unlock(&lock)
    }

    static func matchKey(_ title: String, _ artist: String, _ duration: Double?) -> String {
        "\(title.lowercased())|\(artist.lowercased())|\(Int((duration ?? 0).rounded()))"
    }

    /// The ITLib item for a MusicKit library song: by id, alias, or title, artist and length.
    func item(for song: Song) -> ITLibMediaItem? {
        item(forMusicKitID: song.id.rawValue)
            ?? read { $0.itemsByKey[Self.matchKey(song.title, song.artistName, song.duration)] }
    }

    /// The ITLib item for a MusicKit library song id (an ITLib id, or a known alias).
    func item(forMusicKitID id: String) -> ITLibMediaItem? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshot.items[id] ?? aliases[id].flatMap { snapshot.items[$0] }
    }

    /// Songs found to have no playable MusicKit library song (kept across reloads).
    private var unplayable: Set<String> = []

    func markUnplayable(_ ids: [String]) {
        os_unfair_lock_lock(&lock)
        unplayable.formUnion(ids)
        os_unfair_lock_unlock(&lock)
    }

    func isUnplayable(_ id: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return unplayable.contains(id)
    }

    // MARK: Search

    struct SearchResult {
        var songs: [ITLibMediaItem] = []
        var albums: [AlbumEntry] = []
        var artists: [ArtistEntry] = []
        var playlists: [PlaylistListing] = []
    }

    /// Case- and accent-insensitive search of the library, at most `limit` of each type:
    /// exact matches first, then prefixes, then word starts, then anywhere.
    func search(_ term: String, limit: Int) -> SearchResult {
        let needle = Self.fold(term)
        guard !needle.isEmpty else { return SearchResult() }
        let albums = self.albums
        let memberAlbums = Set(albums.map(\.id))
        var result = SearchResult()

        result.albums = Self.best(albums, limit) { a in
            min(Self.rank(needle, a.title), Self.rank(needle, a.artist ?? "", penalty: 1))
        }
        var names = Set<String>()
        result.artists = Self.best(artists, limit * 4) { Self.rank(needle, $0.name) }
            .filter { names.insert(Self.fold($0.name)).inserted }.prefix(limit).map { $0 }
        result.playlists = Self.best(playlistListings, limit) { Self.rank(needle, $0.name) }
        let songs = read { snapshot in
            snapshot.items.values.filter { memberAlbums.contains(Self.key($0.album.persistentID)) }
        }
        result.songs = Self.best(songs, limit) { item in
            min(Self.rank(needle, item.title), Self.rank(needle, item.artist?.name ?? "", penalty: 1),
                Self.rank(needle, item.album.title ?? "", penalty: 2))
        }
        return result
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 0 exact, 1 prefix, 2 a word starts with it, 3 anywhere, plus `penalty` for weaker
    /// fields; Int.max for no match.
    private static func rank(_ needle: String, _ haystack: String, penalty: Int = 0) -> Int {
        let hay = fold(haystack)
        let rank: Int
        if hay == needle {
            rank = 0
        } else if hay.hasPrefix(needle) {
            rank = 1
        } else if let range = hay.range(of: needle) {
            let before = hay[hay.index(before: range.lowerBound)]
            rank = before.isLetter || before.isNumber ? 3 : 2
        } else {
            return Int.max
        }
        return rank + penalty
    }

    private static func best<T>(_ items: [T], _ limit: Int, score: (T) -> Int) -> [T] {
        // Stable: equal scores keep the collection's order (by name or artist).
        items.enumerated()
            .compactMap { offset, item -> (Int, Int, T)? in
                let s = score(item)
                return s == Int.max ? nil : (s, offset, item)
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .prefix(limit).map(\.2)
    }

    /// Artwork straight from the library, if ITLib has it for this item.
    func artwork(kind: String, id: String) -> NSImage? {
        read { snapshot -> ITLibMediaItem? in
            switch kind {
            case "song": return snapshot.items[id]
            case "album": return snapshot.albumsByID[id]?.artworkItem
            default: return nil
            }
        }.flatMap { item in item.hasArtworkAvailable ? item.artwork?.image : nil }
    }

    private func read<T>(_ body: (Snapshot) -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body(snapshot)
    }

    private static func key(_ id: NSNumber) -> String { String(Int64(bitPattern: id.uint64Value)) }

    private func reload() {
        let started = Date()
        let library: ITLibrary
        do {
            library = try ITLibrary(apiVersion: "1.1", options: .lazyLoadData)
        } catch {
            return Log.error("library index: cannot open the music library: \(error)")
        }

        var next = Snapshot()
        next.library = library
        var tracks: [String: [ITLibMediaItem]] = [:]
        var artists: [String: String] = [:]
        for item in library.allMediaItems where item.mediaKind == .kindSong {
            let id = Self.key(item.persistentID)
            next.items[id] = item
            next.itemsByKey[Self.matchKey(item.title, item.artist?.name ?? "", Double(item.totalTime) / 1000)] = item
            tracks[Self.key(item.album.persistentID), default: []].append(item)
            if let artist = item.artist, let name = artist.name, !name.isEmpty {
                artists[Self.key(artist.persistentID)] = name
            }
        }

        for (id, items) in tracks {
            let album = items[0].album
            let trackArtists = Set(items.compactMap { $0.artist?.name }.filter { !$0.isEmpty })
            let artist = album.albumArtist.flatMap { $0.isEmpty ? nil : $0 }
                ?? (trackArtists.count == 1 ? trackArtists.first : trackArtists.isEmpty ? nil : "Various Artists")
            let years = items.map(\.year).filter { $0 > 0 }
            let ordered = items.sorted { ($0.album.discNumber, $0.trackNumber) < ($1.album.discNumber, $1.trackNumber) }
            let entry = AlbumEntry(
                id: id, title: album.title ?? "", artist: artist,
                genre: items.lazy.map(\.genre).first { !$0.isEmpty },
                year: years.min(), isCompilation: album.isCompilation, trackCount: items.count,
                added: items.compactMap(\.addedDate).max() ?? .distantPast,
                artworkItem: items.first { $0.hasArtworkAvailable },
                artistIDs: Set(items.compactMap { $0.artist.map { Self.key($0.persistentID) } }),
                trackIDs: ordered.map { Self.key($0.persistentID) })
            next.albumsByID[id] = entry
        }
        next.albums = next.albumsByID.values.sorted { a, b in
            let (x, y) = ((a.artist ?? "").lowercased(), (b.artist ?? "").lowercased())
            if x.isEmpty != y.isEmpty { return y.isEmpty }
            return (x, a.year ?? 0, a.title.lowercased()) < (y, b.year ?? 0, b.title.lowercased())
        }
        let favorites = library.allPlaylists.filter { $0.distinguishedKind == .kindLovedSongs }
        if !favorites.isEmpty {
            next.favorites = Set(favorites.flatMap(\.items).map { Self.key($0.persistentID) })
        }
        next.artists = artists.map { ArtistEntry(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        next.playlists = library.allPlaylists
            .filter { $0.kind != .folder && $0.isVisible && !$0.isPrimary && $0.distinguishedKind == .kindNone }
            .map { playlist in
                let songs = playlist.items.filter { $0.mediaKind == .kindSong }
                return PlaylistEntry(id: Self.key(playlist.persistentID), name: playlist.name,
                              trackCount: songs.count,
                              // Smart and Genius playlists can't take tracks. (Apple Music's own
                              // playlists added to the library look regular here; only Apple's
                              // web API can tell them apart.)
                              canEdit: playlist.kind == .regular,
                              trackIDs: songs.map { Self.key($0.persistentID) })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        os_unfair_lock_lock(&lock)
        snapshot = next
        os_unfair_lock_unlock(&lock)
        Log.info("library index: \(next.items.count) songs, \(next.albums.count) albums, \(next.artists.count) artists, "
            + "\(next.playlists.count) playlists in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    }
}
