import CoreGraphics
import Foundation
import iTunesLibrary
import MusicKit

/// Where an id lives. Catalog ids are short numbers (or pl.… for playlists). On macOS,
/// library ids are ITLib persistent ids, signed 64-bit numbers (elsewhere i.…, l.…, p.…, r.…).
enum Source: String {
    case catalog, library

    init?(_ name: String?) {
        guard let name, let source = Source(rawValue: name) else { return nil }
        self = source
    }

    static func guess(_ id: MusicItemID) -> Source {
        let raw = id.rawValue
        if ["i.", "l.", "p.", "r."].contains(where: raw.hasPrefix) { return .library }
        let digits = raw.hasPrefix("-") ? raw.dropFirst() : Substring(raw)
        let numeric = !digits.isEmpty && digits.allSatisfy(\.isNumber)
        return numeric && (raw.hasPrefix("-") || digits.count >= 15) ? .library : .catalog
    }
}

/// Turns MusicKit items into the contract's objects (apple-bridge/API.md, "Objects"). Fields
/// Apple doesn't give are left out, never null.
enum Normalize {
    /// Set at startup: the bridge's own artwork URLs, for artwork without an https template.
    nonisolated(unsafe) static var artworkServer: ArtworkServer?

    static func song(_ song: Song, source: Source? = nil, albumId: String? = nil) -> [String: Any] {
        let source = source ?? Source.guess(song.id)
        var o: [String: Any] = ["kind": "song", "id": song.id.rawValue, "source": source.rawValue, "title": song.title,
                                "artist": song.artistName, "playable": song.playParameters != nil]
        o["catalogId"] = catalogID(song, source: source)
        o["album"] = song.albumTitle
        o["albumId"] = nonEmpty(albumId ?? song.albums?.first?.id.rawValue)
        o["artistId"] = nonEmpty(song.artists?.first?.id.rawValue)
        if !song.genreNames.isEmpty { o["genres"] = song.genreNames.map(genreName) }
        date(song.releaseDate, into: &o)
        o["duration"] = song.duration
        o["trackNumber"] = song.trackNumber
        o["discNumber"] = song.discNumber
        o["composer"] = song.composerName
        o["explicit"] = song.contentRating == .explicit
        traits(song.audioVariants, into: &o)
        o["isrc"] = song.isrc
        o["artwork"] = artwork(song.artwork, source, "song", song.id)
        return o
    }

    static func album(_ album: Album, source: Source? = nil) -> [String: Any] {
        let source = source ?? Source.guess(album.id)
        var o: [String: Any] = ["kind": "album", "id": album.id.rawValue, "source": source.rawValue, "title": album.title]
        o["artist"] = artistName(of: album, source: source)
        o["catalogId"] = catalogID(album, source: source)
        o["artistId"] = nonEmpty(album.artists?.first?.id.rawValue)
        if !album.genreNames.isEmpty { o["genres"] = album.genreNames.map(genreName) }
        date(album.releaseDate, into: &o)
        o["trackCount"] = album.trackCount
        o["recordLabel"] = album.recordLabelName
        o["copyright"] = album.copyright
        o["editorialNotes"] = notes(album.editorialNotes)
        o["isCompilation"] = album.isCompilation
        o["isSingle"] = album.isSingle
        o["explicit"] = album.contentRating == .explicit
        traits(album.audioVariants, into: &o)
        o["artwork"] = artwork(album.artwork, source, "album", album.id)
        return o
    }

    /// The album's artist, from ITLib's tracks when MusicKit's library leaves it empty.
    static func artistName(of album: Album, source: Source) -> String? {
        nonEmpty(album.artistName) ?? (source == .library ? LibraryIndex.shared.albumArtist(album.id.rawValue) : nil)
    }

    static func artist(_ artist: Artist, source: Source? = nil) -> [String: Any] {
        let source = source ?? Source.guess(artist.id)
        var o: [String: Any] = ["kind": "artist", "id": artist.id.rawValue, "source": source.rawValue, "name": artist.name]
        o["catalogId"] = catalogID(artist, source: source)
        if let genres = artist.genreNames, !genres.isEmpty { o["genres"] = genres }
        o["editorialNotes"] = notes(artist.editorialNotes)
        o["artwork"] = artwork(artist.artwork, source, "artist", artist.id)
        return o
    }

    static func playlist(_ playlist: Playlist, source: Source? = nil, trackCount: Int? = nil) -> [String: Any] {
        let source = source ?? Source.guess(playlist.id)
        var o: [String: Any] = ["kind": "playlist", "id": playlist.id.rawValue, "source": source.rawValue, "name": playlist.name]
        o["curator"] = playlist.curatorName
        o["description"] = playlist.standardDescription ?? playlist.shortDescription
        o["trackCount"] = trackCount ?? playlist.tracks?.count
        if let modified = playlist.lastModifiedDate { o["lastModified"] = ISO8601DateFormatter().string(from: modified) }
        if let canEdit = attributes(playlist)?["canEdit"] as? Bool { o["canEdit"] = canEdit }
        o["artwork"] = artwork(playlist.artwork, source, "playlist", playlist.id)
        return o
    }

    static func genre(_ genre: Genre) -> [String: Any] {
        ["id": genre.id.rawValue, "name": genre.name]
    }

    // MARK: From the ITLib index

    static func genre(entry: LibraryIndex.GenreEntry) -> [String: Any] {
        ["kind": "genre", "id": entry.name, "source": "library", "name": entry.name, "songs": entry.songIDs.count,
         "years": Dictionary(uniqueKeysWithValues: entry.years.map { (String($0.key), $0.value) })]
    }

    static func album(entry: LibraryIndex.AlbumEntry) -> [String: Any] {
        var o: [String: Any] = ["kind": "album", "id": entry.id, "source": "library", "title": entry.title,
                                "isCompilation": entry.isCompilation, "trackCount": entry.trackCount]
        o["artist"] = entry.artist
        if let genre = entry.genre { o["genres"] = [genreName(genre)] }
        o["year"] = entry.year
        if entry.artworkItem != nil, let server = artworkServer {
            o["artwork"] = ["url": server.template(source: .library, kind: "album", id: entry.id)]
        }
        return o
    }

    static func song(item: ITLibMediaItem) -> [String: Any] {
        let id = itlibID(item.persistentID)
        var o: [String: Any] = ["kind": "song", "id": id, "source": "library", "title": item.title,
                                "playable": !item.isUserDisabled && !LibraryIndex.shared.isUnplayable(id)]
        o["artist"] = nonEmpty(item.artist?.name)
        o["album"] = nonEmpty(item.album.title)
        o["albumId"] = itlibID(item.album.persistentID)
        o["artistId"] = item.artist.map { itlibID($0.persistentID) }
        if !item.genre.isEmpty { o["genres"] = [genreName(item.genre)] }
        if item.year > 0 { o["year"] = item.year }
        if let released = item.releaseDate {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            let d = c.dateComponents([.year, .month, .day], from: released)
            o["releaseDate"] = String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 1, d.day ?? 1)
        }
        if item.totalTime > 0 { o["duration"] = Double(item.totalTime) / 1000 }
        if item.trackNumber > 0 { o["trackNumber"] = item.trackNumber }
        if item.album.discNumber > 0 { o["discNumber"] = item.album.discNumber }
        o["composer"] = nonEmpty(item.composer)
        o["explicit"] = item.lyricsContentRating == .explicit
        if item.hasArtworkAvailable, let server = artworkServer {
            o["artwork"] = ["url": server.template(source: .library, kind: "song", id: id)]
        }
        return o
    }

    private static func itlibID(_ id: NSNumber) -> String { String(Int64(bitPattern: id.uint64Value)) }

    static func artist(entry: LibraryIndex.ArtistEntry) -> [String: Any] {
        ["kind": "artist", "id": entry.id, "source": "library", "name": entry.name]
    }

    /// A MusicKit library song, as the ITLib song when the index knows it (same ids and
    /// artwork as the library details).
    static func librarySong(_ song: Song) -> [String: Any] {
        if let item = LibraryIndex.shared.item(for: song) { return Normalize.song(item: item) }
        return Normalize.song(song, source: .library)
    }

    static func playlist(listing row: LibraryIndex.PlaylistListing) -> [String: Any] {
        var o: [String: Any] = ["kind": "playlist", "id": row.id, "source": "library", "name": row.name,
                                "canEdit": row.canEdit]
        o["trackCount"] = row.trackCount
        if let modified = row.lastModified { o["lastModified"] = ISO8601DateFormatter().string(from: modified) }
        if row.entry != nil, let server = artworkServer {
            o["artwork"] = ["url": server.template(source: .library, kind: "playlist", id: row.id)]
        } else if let artwork = row.cloud?.artwork {
            o["artwork"] = artwork
        }
        return o
    }

    /// Apple's artwork template, with {w} and {h} left for omarock to fill in. Library
    /// artwork can be a local musicKit:// URL that only works on this Mac; then the
    /// template points at the bridge's /v1/artwork, which renders it.
    static func artwork(_ artwork: Artwork?, _ source: Source, _ kind: String, _ id: MusicItemID) -> [String: Any]? {
        guard let artwork else { return nil }
        let probe = artwork.url(width: 7777, height: 8888)?.absoluteString ?? ""
        let url: String
        if probe.hasPrefix("https://") {
            url = probe.replacingOccurrences(of: "7777", with: "{w}").replacingOccurrences(of: "8888", with: "{h}")
        } else if let server = artworkServer {
            url = server.template(for: artwork, source: source, kind: kind, id: id.rawValue)
        } else {
            return nil
        }
        var o: [String: Any] = ["url": url]
        if artwork.maximumWidth > 0 { o["width"] = artwork.maximumWidth }
        if artwork.maximumHeight > 0 { o["height"] = artwork.maximumHeight }
        o["bgColor"] = hex(artwork.backgroundColor)
        o["textColor"] = hex(artwork.primaryTextColor)
        return o
    }

    // MARK: Helpers

    /// Some Apple Music songs keep Apple's genre key in the library instead of its name
    /// ("MZGenre.Music.HipHopRap", on some songs added from Apple Music). Names as the catalog gives them.
    static func genreName(_ genre: String) -> String {
        guard genre.hasPrefix("MZGenre.") else { return genre }
        let key = genre.split(separator: ".").last.map(String.init) ?? genre
        let names = ["HipHopRap": "Hip-Hop/Rap", "SingerSongwriter": "Singer/Songwriter", "RnBSoul": "R&B/Soul",
                     "PopInSpanish": "Pop in Spanish", "AlternativoRockLatino": "Alternativo & Rock Latino",
                     "LatinUrban": "Urbano Latino", "ChristianGospel": "Christian & Gospel",
                     "FitnessWorkout": "Fitness & Workout", "ChildrensMusic": "Children's Music",
                     "KPop": "K-Pop", "JPop": "J-Pop", "CPop": "C-Pop"]
        if let name = names[key] { return name }
        // "MarchingBands" → "Marching Bands", "ChamberMusic" → "Chamber Music".
        return key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    /// MusicKit's library gives "" for missing names and ids; the contract omits them.
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    private static func date(_ date: Date?, into o: inout [String: Any]) {
        guard let date else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        o["year"] = c.year
        o["releaseDate"] = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    private static func traits(_ variants: [AudioVariant]?, into o: inout [String: Any]) {
        guard let variants, !variants.isEmpty else { return }
        o["audioTraits"] = variants.map(trait)
    }

    /// An audio variant by Apple's audioTraits name (songs' audioTraits, status's audioVariant).
    static func trait(_ variant: AudioVariant) -> String {
        switch variant {
        case .lossless: return "lossless"
        case .highResolutionLossless: return "hi-res-lossless"
        case .lossyStereo: return "lossy-stereo"
        case .dolbyAtmos: return "atmos"
        case .dolbyAudio: return "dolby-audio"
        case .spatialAudio: return "spatial"
        default: return String(describing: variant)
        }
    }

    private static func notes(_ notes: EditorialNotes?) -> String? {
        guard let text = notes?.short ?? notes?.standard else { return nil }
        // Apple's notes can carry light HTML.
        return text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color, let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return nil }
        return String(format: "%02x%02x%02x", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
    }

    /// The item's raw attributes, as MusicKit encodes them (Apple's JSON shape).
    static func attributes<T: Encodable>(_ item: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(item),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["attributes"] as? [String: Any]
    }

    /// For library items that are also in the catalog: the catalog id from playParams.
    static func catalogID<T: Encodable & MusicItem>(_ item: T, source: Source) -> String? {
        if source == .catalog { return item.id.rawValue }
        let params = attributes(item)?["playParams"] as? [String: Any]
        return (params?["catalogId"] as? String) ?? (params?["purchasedId"] as? String)
    }
}
