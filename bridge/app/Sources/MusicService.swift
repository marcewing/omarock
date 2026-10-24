import Foundation
import MusicKit

/// An error with the HTTP status the contract gives it.
struct APIError: Error {
    let status: Int
    let message: String

    static func badRequest(_ message: String) -> APIError { APIError(status: 400, message: message) }
    static func notFound(_ message: String) -> APIError { APIError(status: 404, message: message) }
    static let notAuthorized = APIError(status: 409, message: "MusicKit isn't authorized on the Mac yet.")

    /// Anything MusicKit throws is Apple's API failing, as far as omarock is concerned.
    static func from(_ error: Error) -> APIError {
        if let error = error as? APIError { return error }
        // The full error (a DecodingError's coding path, say) goes to the log only.
        Log.error("Apple Music error: \(String(describing: error))")
        return APIError(status: 502, message: "Apple Music request failed: \(error.localizedDescription)")
    }
}

/// An item in a request: { kind, id, source }, or { kind: "queue" }.
struct ItemRef {
    let kind: String
    let id: MusicItemID?
    let source: Source

    init(_ json: Any) throws {
        guard let o = json as? [String: Any], let kind = o["kind"] as? String else {
            throw APIError.badRequest("Each item needs a kind.")
        }
        self.kind = kind
        if kind == "queue" {
            id = nil
            source = .library
            return
        }
        guard let id = o["id"] as? String, !id.isEmpty else { throw APIError.badRequest("Each item needs an id.") }
        self.id = MusicItemID(id)
        source = Source(o["source"] as? String) ?? Source.guess(MusicItemID(id))
    }
}

/// Search, browse and the library, normalized for the API.
///
/// Never use MusicLibraryRequest.sort(by:): on macOS the library is ITLib underneath, and
/// unsupported sort keys abort the app. Sort the results here instead.
@MainActor
final class MusicService {
    // MARK: Fetching one item

    func song(_ id: MusicItemID, _ source: Source) async throws -> Song {
        let item: Song?
        switch source {
        case .catalog: item = try await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id).response().items.first
        case .library:
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: id)
            item = try await request.response().items.first
        }
        return try found(item, "song", id, source)
    }

    func album(_ id: MusicItemID, _ source: Source) async throws -> Album {
        let item: Album?
        switch source {
        case .catalog: item = try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id).response().items.first
        case .library:
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: id)
            item = try await request.response().items.first
        }
        return try found(item, "album", id, source)
    }

    func artist(_ id: MusicItemID, _ source: Source) async throws -> Artist {
        let item: Artist?
        switch source {
        case .catalog: item = try await MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: id).response().items.first
        case .library:
            var request = MusicLibraryRequest<Artist>()
            request.filter(matching: \.id, equalTo: id)
            item = try await request.response().items.first
        }
        return try found(item, "artist", id, source)
    }

    func playlist(_ id: MusicItemID, _ source: Source) async throws -> Playlist {
        let item: Playlist?
        switch source {
        case .catalog: item = try await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id).response().items.first
        case .library:
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: id)
            item = try await request.response().items.first
        }
        return try found(item, "playlist", id, source)
    }

    private func found<T>(_ item: T?, _ kind: String, _ id: MusicItemID, _ source: Source) throws -> T {
        guard let item else { throw APIError.notFound("No \(source.rawValue) \(kind) with id \(id.rawValue).") }
        return item
    }

    private func preferred(_ source: Source) -> MusicPropertySource { source == .library ? .library : .catalog }

    // MARK: Search

    func search(_ term: String, scope: String, limit: Int) async throws -> [String: Any] {
        var result: [String: Any] = [:]
        if scope == "all" || scope == "library" {
            // From the ITLib index: MusicLibrarySearchRequest ignores its limit and repeats items.
            let r = try index().search(term, limit: limit)
            result["library"] = [
                "songs": r.songs.map(Normalize.song(item:)),
                "albums": r.albums.map(Normalize.album(entry:)),
                "artists": r.artists.map(Normalize.artist(entry:)),
                "playlists": r.playlists.map(Normalize.playlist(listing:)),
            ]
        }
        if scope == "all" || scope == "catalog" {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
            request.limit = limit
            let r: MusicCatalogSearchResponse
            do {
                r = try await request.response()
            } catch where scope == "all" {
                // The library half still answers (before the paid team, every catalog call fails).
                result["catalogError"] = "Apple Music catalog search failed: \(error.localizedDescription)"
                return result
            }
            result["catalog"] = [
                "songs": r.songs.map { Normalize.song($0, source: .catalog) },
                "albums": r.albums.map { Normalize.album($0, source: .catalog) },
                "artists": r.artists.map { Normalize.artist($0, source: .catalog) },
                "playlists": r.playlists.map { Normalize.playlist($0, source: .catalog) },
            ]
        }
        return result
    }

    // MARK: Browse

    func albumDetail(_ id: MusicItemID, _ source: Source) async throws -> [String: Any] {
        if source == .library, let entry = LibraryIndex.shared.album(id.rawValue) {
            return ["album": Normalize.album(entry: entry),
                    "tracks": entry.trackIDs.compactMap { LibraryIndex.shared.item($0) }.map(Normalize.song(item:))]
        }
        let album = try await self.album(id, source).with([.tracks, .artists], preferredSource: preferred(source))
        let songs = Self.songs(album.tracks).sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
        var tracks = songs.map { Normalize.song($0, source: source, albumId: album.id.rawValue) }
        if source == .catalog {
            // inLibrary per song, as status songs have it: Apple's relation to the library
            // in one request per 100 songs (left unknown if that fails), the index, adds.
            var links: [String: SongLinks] = [:]
            for start in stride(from: 0, to: songs.count, by: 100) {
                let ids = songs[start..<min(start + 100, songs.count)].map(\.id.rawValue)
                guard let found = try? await Self.songLinks(ids) else { break }
                links.merge(found) { a, _ in a }
            }
            for (i, song) in songs.enumerated() {
                tracks[i]["inLibrary"] = LibraryIndex.shared.holds(
                    song: song.id.rawValue, album: album.id.rawValue, related: links[song.id.rawValue]?.related,
                    title: song.title, artist: song.artistName, duration: song.duration)
            }
        }
        return ["album": Normalize.album(album, source: source), "tracks": tracks]
    }

    func artistDetail(_ id: MusicItemID, _ source: Source) async throws -> [String: Any] {
        var result: [String: Any] = [:]
        switch source {
        case .catalog:
            let artist = try await self.artist(id, .catalog).with([.albums, .topSongs, .appearsOnAlbums])
            result["artist"] = Normalize.artist(artist, source: .catalog)
            result["albums"] = Self.byYear(artist.albums.map(Array.init) ?? []).map { Normalize.album($0, source: .catalog) }
            result["topSongs"] = (artist.topSongs.map(Array.init) ?? []).map { Normalize.song($0, source: .catalog) }
            if let appearsOn = artist.appearsOnAlbums, !appearsOn.isEmpty {
                result["appearsOn"] = appearsOn.map { Normalize.album($0, source: .catalog) }
            }
        case .library:
            let found: Artist
            do {
                found = try await self.artist(id, .library)
            } catch let error as APIError where error.status == 404 {
                // Only on songs outside the library's albums (a playlist added to the
                // library): MusicKit doesn't know the artist, but those songs carry its id.
                let index = LibraryIndex.shared
                guard let entry = index.artist(id.rawValue) else { throw error }
                return ["artist": Normalize.artist(entry: entry),
                        "albums": index.albums(byArtist: id.rawValue, anywhere: true)
                            .sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }.map(Normalize.album(entry:)),
                        "topSongs": index.songs(byArtist: id.rawValue, anywhere: true).prefix(25).map(Normalize.song(item:))]
            }
            let artist = try await found.with([.albums], preferredSource: .library)
            result["artist"] = Normalize.artist(artist, source: .library)
            result["albums"] = Self.byYear(artist.albums.map(Array.init) ?? []).compactMap(Self.libraryAlbum)
            // From the index, as the library lists are: its ids open, and MusicKit's
            // artistName filter finds nothing for some names ("10,000 Maniacs").
            let indexed = LibraryIndex.shared.songs(byArtist: id.rawValue)
            result["topSongs"] = indexed.isEmpty
                ? try await librarySongs(by: artist).prefix(25).map { Normalize.song($0, source: .library) }
                : indexed.prefix(25).map(Normalize.song(item:))
        }
        return result
    }

    /// A MusicKit library album with the index's title, year, track count and artwork, as
    /// the album's own route gives them: MusicKit's trackCount is 0 for some (singles, songs
    /// with no album tag), its title can be empty. nil for one the index has no songs on,
    /// which opens empty.
    private static func libraryAlbum(_ album: Album) -> [String: Any]? {
        var o = Normalize.album(album, source: .library)
        guard LibraryIndex.shared.isLoaded else { return o }
        guard let entry = LibraryIndex.shared.album(album.id.rawValue), entry.trackCount > 0 else { return nil }
        o.merge(Normalize.album(entry: entry)) { kit, index in (index as? String) == "" ? kit : index }
        return o
    }

    func playlistDetail(_ id: MusicItemID, _ source: Source) async throws -> [String: Any] {
        if source == .library, let row = LibraryIndex.shared.listing(id.rawValue) {
            if let entry = row.entry {
                return ["playlist": Normalize.playlist(listing: row),
                        "tracks": entry.trackIDs.compactMap { LibraryIndex.shared.item($0) }.map(Normalize.song(item:))]
            }
            // In iCloud but not synced to this Mac's library yet: ask Apple.
            let songs = try await cloudPlaylistSongs(row.id)
            LibraryIndex.shared.setCloudTrackCount(row.id, songs.count)
            var playlist = Normalize.playlist(listing: row)
            playlist["trackCount"] = songs.count
            return ["playlist": playlist, "tracks": songs.map(Normalize.librarySong)]
        }
        if source == .library, id.rawValue.hasPrefix("p.") {
            throw APIError.notFound("No library playlist \(id.rawValue).")
        }
        let playlist = try await self.playlist(id, source).with([.tracks], preferredSource: preferred(source))
        let songs = Self.songs(playlist.tracks)
        return ["playlist": Normalize.playlist(playlist, source: source, trackCount: songs.count),
                "tracks": songs.map { Normalize.song($0, source: source) }]
    }

    /// MusicKit library songs for ITLib ids, in the given order, fetched in batches (much
    /// quicker than loading an album's or playlist's tracks relationship).
    /// nil where MusicKit has no playable song for an id; those are remembered in the index,
    /// so later details say playable: false.
    ///
    /// MusicKit finds library songs by their ITLib ids, but once the app has a developer
    /// token it hands them back with iCloud library ids (i.…). So results are paired with
    /// the ids asked for by id where they still match, else by title, artist and length,
    /// and the iCloud id is remembered as an alias of the ITLib one.
    func librarySongs(ids: [String]) async throws -> [Song?] {
        var byID: [String: Song] = [:]
        var byKey: [String: [Song]] = [:]
        for start in stride(from: 0, to: ids.count, by: 200) {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, memberOf: ids[start..<min(start + 200, ids.count)].map { MusicItemID($0) })
            for song in try await request.response().items {
                byID[song.id.rawValue] = song
                byKey[Self.matchKey(song.title, song.artistName, song.duration), default: []].append(song)
            }
        }
        let songs: [Song?] = ids.map { id in
            if let song = byID[id] { return Self.playable(song) }
            guard let item = LibraryIndex.shared.item(id) else { return nil }
            let key = Self.matchKey(item.title, item.artist?.name ?? "", Double(item.totalTime) / 1000)
            guard var candidates = byKey[key], !candidates.isEmpty else { return nil }
            let song = candidates.removeFirst()
            byKey[key] = candidates
            LibraryIndex.shared.alias(song.id.rawValue, to: id)
            return Self.playable(song)
        }
        let missing = zip(ids, songs).filter { $0.1 == nil }.map(\.0)
        if !missing.isEmpty { LibraryIndex.shared.markUnplayable(missing) }
        return songs
    }

    private func librarySongs(by artist: Artist) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.artistName, equalTo: artist.name)
        return try await request.response().items.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
    }

    // MARK: Library lists (from the ITLib index; see LibraryIndex)

    private func index() throws -> LibraryIndex {
        let index = LibraryIndex.shared
        guard index.isLoaded else { throw APIError(status: 503, message: "The music library is still loading; try again in a few seconds.") }
        return index
    }

    func libraryPlaylists() throws -> [[String: Any]] {
        try index().playlistListings.map(Normalize.playlist(listing:))
    }

    func libraryAlbums(offset: Int, limit: Int) throws -> [String: Any] {
        let all = try index().albums
        return ["items": Self.page(all, offset, limit).map(Normalize.album(entry:)), "total": all.count]
    }

    func libraryArtists(offset: Int, limit: Int) throws -> [String: Any] {
        let all = try index().artists
        return ["items": Self.page(all, offset, limit).map(Normalize.artist(entry:)), "total": all.count]
    }

    /// Recently added albums, newest first. (ITLib has no date for playlists.)
    func libraryRecent(limit: Int) throws -> [[String: Any]] {
        try index().albums.sorted { $0.added > $1.added }.prefix(limit).map(Normalize.album(entry:))
    }

    /// Apple's raw JSON for a GET on api.music.apple.com (diagnostics only).
    func rawAppleGET(_ path: String) async throws -> Data {
        guard path.hasPrefix("/v1/catalog/") || path.hasPrefix("/v1/me/"), let url = URL(string: "https://api.music.apple.com" + path)
        else { throw APIError.badRequest("path must start with /v1/catalog/ or /v1/me/.") }
        return try await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data
    }

    // MARK: Genres

    func genres() async throws -> [[String: Any]] {
        let storefront = try await MusicDataRequest.currentCountryCode
        let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/genres")!
        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        let data = json?["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String, let name = (item["attributes"] as? [String: Any])?["name"] as? String,
                  id != "34" else { return nil }  // 34 is "Music", the root of them all
            return ["id": id, "name": name]
        }
    }

    /// Through MusicDataRequest: MusicCatalogChartsRequest with a genre comes back empty
    /// (MusicKit then fails to decode it) while the same chart fetched raw works, so fetch
    /// it raw and decode MusicKit's own types from Apple's JSON.
    func genreDetail(_ id: MusicItemID, limit: Int) async throws -> [String: Any] {
        let storefront = try await MusicDataRequest.currentCountryCode
        let genreJSON = try await appleJSON("/v1/catalog/\(storefront)/genres/\(id.rawValue)")
        guard let genre = (genreJSON["data"] as? [[String: Any]])?.first,
              let name = (genre["attributes"] as? [String: Any])?["name"] as? String else {
            throw APIError.notFound("No genre \(id.rawValue).")
        }
        let charts = try await appleData(
            "/v1/catalog/\(storefront)/charts?types=albums,songs&genre=\(id.rawValue)&chart=most-played&limit=\(limit)")
        let results = try JSONDecoder().decode(ChartResults.self, from: charts).results
        return ["genre": ["id": id.rawValue, "name": name],
                "albums": results.albums?.first?.data.map { Normalize.album($0, source: .catalog) } ?? [],
                "songs": results.songs?.first?.data.map { Normalize.song($0, source: .catalog) } ?? []]
    }

    private struct ChartResults: Decodable {
        struct Chart<T: Decodable>: Decodable { let data: [T] }
        struct Results: Decodable {
            let albums: [Chart<Album>]?
            let songs: [Chart<Song>]?
        }
        let results: Results
    }

    func appleData(_ path: String) async throws -> Data {
        let data = try await MusicDataRequest(urlRequest: URLRequest(url: URL(string: "https://api.music.apple.com" + path)!)).response().data
        guard !data.isEmpty else { throw APIError(status: 502, message: "Apple Music sent an empty answer.") }
        return data
    }

    private func appleJSON(_ path: String) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await appleData(path)) as? [String: Any]) ?? [:]
    }

    // MARK: Items to songs

    /// Expands items to songs, in order (bridge/API.md, "Items"), with nil where a song
    /// can't be played. The nils keep positions as the details list them, so a `start`
    /// counts the same rows omarock shows.
    func expand(_ items: [ItemRef], queue: () -> [Song]) async throws -> [Song?] {
        var songs: [Song?] = []
        for item in items {
            switch (item.kind, item.id) {
            case ("queue", _):
                songs += queue().map { $0 }
            case ("song", let id?):
                let song: Song?
                if item.source == .library {
                    song = try await librarySongs(ids: [id.rawValue]).first ?? nil
                } else {
                    song = try await self.song(id, .catalog)
                }
                guard let song, song.playParameters != nil else {
                    // A single song that won't play is an error, not an empty queue.
                    if items.count == 1 {
                        let title = song?.title ?? LibraryIndex.shared.item(id.rawValue)?.title ?? "That song"
                        throw APIError(status: 409, message: "\(title) isn't available to play.")
                    }
                    songs.append(nil)
                    continue
                }
                songs.append(song)
            case ("album", let id?) where item.source == .library && LibraryIndex.shared.album(id.rawValue) != nil:
                songs += try await librarySongs(ids: LibraryIndex.shared.album(id.rawValue)!.trackIDs)
            case ("playlist", let id?) where item.source == .library && LibraryIndex.shared.listing(id.rawValue) != nil:
                let row = LibraryIndex.shared.listing(id.rawValue)!
                if let entry = row.entry {
                    songs += try await librarySongs(ids: entry.trackIDs)
                } else {
                    songs += try await cloudPlaylistSongs(row.id).map(Self.playable)
                }
            case ("album", let id?):
                let album = try await album(id, item.source).with([.tracks], preferredSource: preferred(item.source))
                songs += try await full(Self.songs(album.tracks), item.source)
            case ("playlist", let id?):
                let playlist = try await playlist(id, item.source).with([.tracks], preferredSource: preferred(item.source))
                songs += try await full(Self.songs(playlist.tracks), item.source)
            case ("artist", let id?):
                if item.source == .catalog {
                    songs += (try await artist(id, .catalog).with([.topSongs]).topSongs.map(Array.init) ?? []).map(Self.playable)
                } else {
                    songs += try await librarySongs(by: artist(id, .library)).map(Self.playable)
                }
            default:
                throw APIError.badRequest("Unknown item kind \"\(item.kind)\".")
            }
        }
        return songs
    }

    /// Catalog tracks from an album's or playlist's tracks relationship can't start a
    /// queue ("Prepare queue failed with unexpected start item"); the same songs fetched as
    /// catalog resources can. Library tracks are used as they are.
    private func full(_ tracks: [Song], _ source: Source) async throws -> [Song?] {
        guard source == .catalog else { return tracks.map(Self.playable) }
        var found: [MusicItemID: Song] = [:]
        for start in stride(from: 0, to: tracks.count, by: 100) {
            let ids = tracks[start..<min(start + 100, tracks.count)].map(\.id)
            for song in try await MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids).response().items {
                found[song.id] = song
            }
        }
        return tracks.map { found[$0.id].flatMap(Self.playable) }
    }

    static func matchKey(_ title: String, _ artist: String, _ duration: Double?) -> String {
        "\(title.lowercased())|\(artist.lowercased())|\(Int((duration ?? 0).rounded()))"
    }

    /// Just the playable songs.
    func songs(for items: [ItemRef], queue: () -> [Song]) async throws -> [Song] {
        try await expand(items, queue: queue).compactMap { $0 }
    }

    private static func playable(_ song: Song) -> Song? { song.playParameters != nil ? song : nil }

    // MARK: Library playlists

    // MusicLibrary.createPlaylist and add(_:to:) are iOS-only, so on the Mac these go
    // through Apple Music's /v1/me/library API (MusicDataRequest adds the user token).

    func createPlaylist(name: String, songs: [Song]) async throws -> [String: Any] {
        var body: [String: Any] = ["attributes": ["name": name]]
        if !songs.isEmpty { body["relationships"] = ["tracks": ["data": Self.trackRefs(songs)]] }
        let json = try await meRequest("POST", "/v1/me/library/playlists", body)
        guard let created = (json["data"] as? [[String: Any]])?.first, let id = created["id"] as? String else {
            throw APIError(status: 502, message: "Apple Music didn't return the new playlist.")
        }
        var cloud = LibraryIndex.cloudPlaylist(id: id, name: name, attributes: created["attributes"] as? [String: Any] ?? [:])
        cloud.trackCount = songs.count
        LibraryIndex.shared.addCloudPlaylist(cloud)
        Log.info("library: created playlist \(id) \"\(name)\" with \(songs.count) songs")
        guard let row = LibraryIndex.shared.listing(id) else { throw APIError(status: 502, message: "The new playlist went missing.") }
        return Normalize.playlist(listing: row)
    }

    func appendToPlaylist(_ id: MusicItemID, songs: [Song]) async throws -> [String: Any] {
        guard !songs.isEmpty else { throw APIError.badRequest("Nothing playable in those items.") }
        let cloudID = try await cloudPlaylistID(id)
        _ = try await meRequest("POST", "/v1/me/library/playlists/\(cloudID.rawValue)/tracks", ["data": Self.trackRefs(songs)])
        LibraryIndex.shared.bumpCloudPlaylist(cloudID.rawValue, added: songs.count)
        Log.info("library: added \(songs.count) songs to playlist \(cloudID.rawValue)")
        guard let row = LibraryIndex.shared.listing(id.rawValue) ?? LibraryIndex.shared.listing(cloudID.rawValue) else {
            throw APIError.notFound("No library playlist \(id.rawValue).")
        }
        return Normalize.playlist(listing: row)
    }

    // MARK: Adding to the library

    /// POST /v1/library/add: catalog songs, albums and playlists, through Apple Music's
    /// "Add a Resource to a Library". Library items are there already, and are skipped.
    /// Apple accepts the add at once and Music syncs it a little later, so the index
    /// remembers what was added (and looks again sooner).
    func addToLibrary(_ items: [ItemRef]) async throws -> [String: Any] {
        let types = ["song": "songs", "album": "albums", "playlist": "playlists"]
        var ids: [String: [String]] = [:]
        for item in items {
            guard let type = types[item.kind], let id = item.id?.rawValue else {
                throw APIError.badRequest("kind is song, album or playlist.")
            }
            guard id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw APIError.badRequest("\(id) isn't a catalog id.")
            }
            if item.source == .catalog, !(ids[type]?.contains(id) ?? false) { ids[type, default: []].append(id) }
        }
        let count = ids.values.reduce(0) { $0 + $1.count }
        guard count > 0 else { return ["ok": true, "added": 0] }
        guard count <= 100 else { throw APIError.badRequest("At most 100 items at a time.") }
        let query = ids.keys.sorted().map { "ids%5B\($0)%5D=\(ids[$0]!.joined(separator: ","))" }.joined(separator: "&")
        do {
            _ = try await meRequest("POST", "/v1/me/library?\(query)", nil)
        } catch let error as MusicDataRequest.Error {
            Log.error("library: adding \(query): \(error)")
            let reason = error.detailText.isEmpty ? error.title : error.detailText
            throw APIError(status: 502, message: "Apple Music didn't add \(count == 1 ? "it" : "them"): \(reason)")
        }
        Log.info("library: added \(query)")
        let index = LibraryIndex.shared
        for (kind, type) in types { index.noteAdded(kind, ids[type] ?? []) }
        index.refreshSoon()
        // An album's songs too, so they show as added wherever they are (another album's
        // copy of a song has its own id). After answering: it's another request to Apple.
        let albums = ids["albums"] ?? []
        Task { @MainActor in
            for id in albums {
                guard let album = try? await self.album(MusicItemID(id), .catalog).with([.tracks]) else { continue }
                index.noteAdded("song", Self.songs(album.tracks).map(\.id.rawValue))
            }
        }
        return ["ok": true, "added": count]
    }

    /// Apple's web API knows library playlists by their iCloud id (p.…); the lists give
    /// ITLib ids, paired with iCloud twins in LibraryIndex.playlistListings.
    func cloudPlaylistID(_ id: MusicItemID) async throws -> MusicItemID {
        guard let row = LibraryIndex.shared.listing(id.rawValue) else {
            if id.rawValue.hasPrefix("p.") { return id }
            throw APIError.notFound("No library playlist \(id.rawValue).")
        }
        if let entry = row.entry, !entry.canEdit {
            throw APIError(status: 409, message: "\(row.name) is a smart playlist; it can't take songs.")
        }
        guard row.cloudLoaded else {
            throw APIError(status: 503, message: "The bridge hasn't loaded your iCloud playlists yet; try again in a minute.")
        }
        guard let cloud = row.cloud, cloud.canEdit else {
            throw APIError(status: 409, message: "\(row.name) can't be edited (it isn't one of your own iCloud playlists).")
        }
        return MusicItemID(cloud.id)
    }

    /// The songs of an iCloud library playlist, from Apple's web API.
    private func cloudPlaylistSongs(_ id: String) async throws -> [Song] {
        struct Page: Decodable {
            let data: [Song]
            let next: String?
        }
        var songs: [Song] = []
        var path: String? = "/v1/me/library/playlists/\(id)/tracks?limit=100"
        while let next = path {
            let page = try JSONDecoder().decode(Page.self, from: try await appleData(next))
            songs += page.data
            path = page.next
        }
        return songs
    }

    private func meRequest(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.music.apple.com" + path)!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await MusicDataRequest(urlRequest: request).response()
        guard !response.data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
    }

    /// Library songs by their library id, the rest by catalog id.
    private static func trackRefs(_ songs: [Song]) -> [[String: String]] {
        songs.map { song in
            ["id": song.id.rawValue, "type": Source.guess(song.id) == .library ? "library-songs" : "songs"]
        }
    }

    // MARK: Helpers

    static func songs(_ tracks: MusicItemCollection<Track>?) -> [Song] {
        (tracks ?? []).compactMap { track in
            if case .song(let song) = track { return song }
            return nil
        }
    }

    private static func byYear(_ albums: [Album]) -> [Album] {
        albums.sorted { ($0.releaseDate ?? .distantPast) < ($1.releaseDate ?? .distantPast) }
    }

    private static func page<C: Collection>(_ items: C, _ offset: Int, _ limit: Int) -> ArraySlice<C.Element> {
        Array(items).dropFirst(max(0, offset)).prefix(max(0, limit))
    }
}
