import Foundation
import iTunesLibrary
import MusicKit

/// GET /v1/info/{source}/{kind}/{id}: everything known about one song or album, for
/// omarock's info card (bridge/API.md, "Info").
///
/// Whether a catalog item is in the library comes from Apple's relate=library and from
/// the ITLib index (title, artist and length). Apple's relation alone misses songs ripped
/// from CD and uploaded: they relate to nothing.
extension MusicService {
    func info(kind: String, id: MusicItemID, source: Source) async throws -> [String: Any] {
        switch (kind, source) {
        case ("song", .library): return try await librarySongInfo(id)
        case ("song", .catalog): return try await catalogSongInfo(id)
        case ("album", .library): return try await libraryAlbumInfo(id)
        case ("album", .catalog): return try await catalogAlbumInfo(id)
        default: throw APIError.badRequest("kind is song or album.")
        }
    }

    // MARK: Songs

    private func librarySongInfo(_ id: MusicItemID) async throws -> [String: Any] {
        guard let item = LibraryIndex.shared.item(forMusicKitID: id.rawValue) else {
            throw APIError.notFound("No library song with id \(id.rawValue).")
        }
        var info: [String: Any] = ["item": Normalize.song(item: item), "inLibrary": true,
                                   "library": Self.details(item)]
        // The catalog copy MusicKit plays it as, else the catalog song that looks like it.
        let itlibID = Self.itlibID(item.persistentID)
        var catalog: Song?
        if let song = try? await librarySongs(ids: [itlibID]).first ?? nil,
           let catalogID = Normalize.catalogID(song, source: .library) {
            catalog = try? await catalogResource(Song.self, "songs", catalogID)?.item
        }
        if catalog == nil {
            catalog = await catalogSong(like: item.title, artist: item.artist?.name ?? "",
                                        duration: item.totalTime > 0 ? Double(item.totalTime) / 1000 : nil)
        }
        if let catalog { info["catalog"] = Self.link(catalog.id, catalog.url) }
        return info
    }

    private func catalogSongInfo(_ id: MusicItemID) async throws -> [String: Any] {
        guard let (song, related, relationships) = try await catalogResource(Song.self, "songs", id.rawValue) else {
            throw APIError.notFound("No catalog song with id \(id.rawValue).")
        }
        // MusicKit doesn't decode the relationships of a raw resource; the detail routes give these.
        var item = Normalize.song(song, source: .catalog)
        item["albumId"] = item["albumId"] ?? Self.firstID(relationships, "albums") ?? Self.albumID(fromURL: song.url)
        item["artistId"] = item["artistId"] ?? Self.firstID(relationships, "artists")
        var info: [String: Any] = ["item": item,
                                   "catalog": Self.link(song.id, song.url)]
        guard LibraryIndex.shared.isLoaded else {
            if related != nil { info["inLibrary"] = true }
            return info
        }
        // The copy on the same album first (a song can also be on a compilation), else the
        // one Apple relates it to, when the titles or artists differ too much to match
        // ("Song (feat. X)" by "A & B" can be "Song feat. X - Vocal Mix" by "A, B, X").
        let album = LibraryIndex.fold(song.albumTitle ?? "")
        let copies = LibraryIndex.shared.songs(like: song.title, artist: song.artistName, duration: song.duration)
        var copy = copies.first { LibraryIndex.fold($0.album.title ?? "") == album } ?? copies.first
        if copy == nil, let related { copy = await libraryItem(forCloudID: related) }
        info["inLibrary"] = related != nil || copy != nil
        if let copy { info["library"] = Self.details(copy) }
        return info
    }

    // MARK: Albums

    private func libraryAlbumInfo(_ id: MusicItemID) async throws -> [String: Any] {
        guard let entry = LibraryIndex.shared.album(id.rawValue) else {
            throw APIError.notFound("No library album with id \(id.rawValue).")
        }
        var info: [String: Any] = ["item": Normalize.album(entry: entry), "inLibrary": true,
                                   "library": Self.summary(entry)]
        // Through a track's catalog copy, else the catalog album that looks like it.
        var catalog: Album?
        for trackID in entry.trackIDs.prefix(2) where catalog == nil {
            guard let song = try? await librarySongs(ids: [trackID]).first ?? nil,
                  let catalogID = Normalize.catalogID(song, source: .library),
                  let full = try? await catalogResource(Song.self, "songs", catalogID)?.item,
                  let albumID = Self.albumID(fromURL: full.url) else { continue }
            catalog = try? await catalogResource(Album.self, "albums", albumID)?.item
        }
        if catalog == nil, let artist = entry.artist {
            catalog = await catalogAlbum(like: entry.title, artist: artist)
        }
        if let catalog { info["catalog"] = Self.link(catalog.id, catalog.url) }
        return info
    }

    private func catalogAlbumInfo(_ id: MusicItemID) async throws -> [String: Any] {
        guard let (album, related, relationships) = try await catalogResource(Album.self, "albums", id.rawValue) else {
            throw APIError.notFound("No catalog album with id \(id.rawValue).")
        }
        var item = Normalize.album(album, source: .catalog)
        item["artistId"] = item["artistId"] ?? Self.firstID(relationships, "artists")
        var info: [String: Any] = ["item": item,
                                   "catalog": Self.link(album.id, album.url)]
        guard LibraryIndex.shared.isLoaded else {
            if related != nil { info["inLibrary"] = true }
            return info
        }
        let copy = LibraryIndex.shared.albums(like: album.title, artist: album.artistName).first
        info["inLibrary"] = related != nil || copy != nil
        if let copy { info["library"] = Self.summary(copy) }
        return info
    }

    // MARK: Apple's catalog

    /// A catalog song or album fetched raw with relate=library, and the library item Apple
    /// relates it to (an iCloud id, i.… or l.…). nil if Apple has no such item.
    private func catalogResource<T: Decodable>(_ type: T.Type, _ path: String, _ id: String) async throws
        -> (item: T, libraryID: String?, relationships: [String: Any])? {
        let storefront = try await MusicDataRequest.currentCountryCode
        let data: Data
        do {
            data = try await appleData("/v1/catalog/\(storefront)/\(path)/\(id)?relate=library")
        } catch let error as MusicDataRequest.Error where error.status == 404 {
            return nil
        }
        guard let item = try JSONDecoder().decode(CatalogResponse<T>.self, from: data).data.first else { return nil }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (json?["data"] as? [[String: Any]])?.first
        let relationships = first?["relationships"] as? [String: Any] ?? [:]
        return (item, Self.firstID(relationships, "library"), relationships)
    }

    /// The ITLib item for one of MusicKit's iCloud library song ids.
    private func libraryItem(forCloudID id: String) async -> ITLibMediaItem? {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let song = try? await request.response().items.first else { return nil }
        return LibraryIndex.shared.item(for: song)
    }

    /// The catalog song with this title, artist and (within a few seconds) length.
    private func catalogSong(like title: String, artist: String, duration: Double?) async -> Song? {
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
        request.limit = 10
        guard let songs = try? await request.response().songs else { return nil }
        return songs.first { song in
            LibraryIndex.core(song.title) == LibraryIndex.core(title)
                && LibraryIndex.sameArtist(LibraryIndex.fold(song.artistName), LibraryIndex.fold(artist))
                && (duration == nil || song.duration == nil || abs(song.duration! - duration!) <= 6)
        }
    }

    /// The catalog album with this title (ignoring an edition in brackets) and artist.
    private func catalogAlbum(like title: String, artist: String) async -> Album? {
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Album.self])
        request.limit = 10
        guard let albums = try? await request.response().albums else { return nil }
        let matches = albums.filter { album in
            LibraryIndex.core(album.title) == LibraryIndex.core(title)
                && LibraryIndex.sameArtist(LibraryIndex.fold(album.artistName), LibraryIndex.fold(artist))
        }
        return matches.first { LibraryIndex.fold($0.title) == LibraryIndex.fold(title) } ?? matches.first
    }

    /// …/album/{slug}/{album id}, with or without ?i={song id} → the album id.
    private static func albumID(fromURL url: URL?) -> String? {
        guard let url, url.path.contains("/album/") else { return nil }
        let last = url.lastPathComponent
        return !last.isEmpty && last.allSatisfy(\.isNumber) ? last : nil
    }

    /// The catalog id in Apple's canonical link (…?i={song} or …/{album}), which can be
    /// newer than the id asked for: a library song's playParams can give an old id that
    /// Apple now redirects to another.
    /// The id of the first item in one of a raw resource's relationships.
    private static func firstID(_ relationships: [String: Any], _ name: String) -> String? {
        ((relationships[name] as? [String: Any])?["data"] as? [[String: Any]])?.first?["id"] as? String
    }

    private static func link(_ id: MusicItemID, _ url: URL?) -> [String: Any] {
        var canonical = id.rawValue
        if let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let song = components.queryItems?.first { $0.name == "i" }?.value
            if let song, !song.isEmpty, song.allSatisfy(\.isNumber) {
                canonical = song
            } else if song == nil, let album = albumID(fromURL: url) {
                canonical = album
            }
        }
        var o: [String: Any] = ["id": canonical]
        o["url"] = url?.absoluteString
        return o
    }

    // MARK: The library copy (ITLib)

    private static func details(_ item: ITLibMediaItem) -> [String: Any] {
        let id = itlibID(item.persistentID)
        var o: [String: Any] = ["id": id, "playCount": item.playCount, "skipCount": item.skipCount,
                                "cloud": item.isCloud, "drm": item.isDRMProtected,
                                // ITLib's isPurchased reads false even for "Purchased AAC audio file".
                                "purchased": item.isPurchased || (item.kind ?? "").hasPrefix("Purchased")]
        o["added"] = iso(item.addedDate)
        o["modified"] = iso(item.modifiedDate)
        o["lastPlayed"] = iso(item.lastPlayedDate)
        if item.rating > 0, !item.isRatingComputed { o["rating"] = item.rating }
        o["loved"] = LibraryIndex.shared.isFavorite(id)
        o["fileKind"] = item.kind
        if item.bitrate > 0 { o["bitrate"] = item.bitrate }
        if item.sampleRate > 0 { o["sampleRate"] = item.sampleRate }
        if item.fileSize > 0 { o["fileSize"] = item.fileSize }
        o["comments"] = nonEmpty(item.comments)
        o["grouping"] = nonEmpty(item.grouping)
        if item.beatsPerMinute > 0 { o["bpm"] = item.beatsPerMinute }
        return o
    }

    /// For an album: the songs in the library, their plays summed, the latest play and the
    /// newest song added.
    private static func summary(_ entry: LibraryIndex.AlbumEntry) -> [String: Any] {
        let items = entry.trackIDs.compactMap { LibraryIndex.shared.item($0) }
        var o: [String: Any] = ["id": entry.id, "trackCount": items.count,
                                "playCount": items.reduce(0) { $0 + $1.playCount }]
        o["added"] = iso(items.compactMap(\.addedDate).max())
        o["lastPlayed"] = iso(items.compactMap(\.lastPlayedDate).max())
        return o
    }

    private static func iso(_ date: Date?) -> String? { date.map { ISO8601DateFormatter().string(from: $0) } }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func itlibID(_ id: NSNumber) -> String { String(Int64(bitPattern: id.uint64Value)) }
}

private struct CatalogResponse<T: Decodable>: Decodable { let data: [T] }
