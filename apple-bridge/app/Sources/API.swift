import Foundation
import MusicKit

/// Routes apple-bridge/API.md. Runs on the main queue.
@MainActor
final class API {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private let token: Data
    private let config: Config
    private let streamURL: String
    private let music: MusicStatus
    private let library: MusicService
    private let stream: StreamService
    private let player: Player
    private let artwork: ArtworkServer

    init(token: String, config: Config, streamURL: String, music: MusicStatus, library: MusicService, stream: StreamService,
         player: Player, artwork: ArtworkServer) {
        self.token = Data(token.utf8)
        self.streamURL = streamURL
        self.artwork = artwork
        self.config = config
        self.music = music
        self.library = library
        self.stream = stream
        self.player = player
    }

    /// MusicKit calls can hang (library requests especially), so every request but the
    /// long poll and /authorize answers 504 after this long, whatever MusicKit is doing.
    private static let timeout: TimeInterval = 20

    nonisolated func handle(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        Task { @MainActor in
            let started = Date()
            var answered = false
            let once: (HTTPResponse) -> Void = { response in
                guard !answered else { return }
                answered = true
                let elapsed = Date().timeIntervalSince(started)
                if elapsed > 2 { Log.info("slow: \(request.method) \(request.path) took \(String(format: "%.1f", elapsed)) s (\(response.status))") }
                respond(response)
            }
            let work = Task { @MainActor in
                do {
                    try await route(request, respond: once)
                } catch {
                    let error = APIError.from(error)
                    if error.status >= 500 { Log.error("\(request.method) \(request.path): \(error.message)") }
                    once(.error(error.status, error.message))
                }
            }
            guard !["/v1/status", "/v1/authorize"].contains(request.path) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) {
                MainActor.assumeIsolated {
                    guard !answered else { return }
                    work.cancel()
                    Log.error("\(request.method) \(request.path): no answer from Apple Music in \(Int(Self.timeout)) s")
                    once(.error(504, "Apple Music didn't answer."))
                }
            }
        }
    }

    private func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) async throws {
        var path = request.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        guard parts.first == "v1" else { throw APIError.notFound("No such endpoint.") }
        let route = Array(parts.dropFirst())
        let method = request.method

        if route == ["health"] {
            guard method == "GET" else { throw APIError(status: 405, message: "Use GET.") }
            return respond(.json(200, health()))
        }
        if method == "GET", route.count == 4, route[0] == "artwork" {
            // Keyed by k in the URL, not the bearer token (see apple-bridge/API.md, Objects).
            let source = try source(route[1])
            guard artwork.verify(source: source, kind: route[2], id: route[3], k: request.query["k"]) else {
                throw APIError(status: 401, message: "Bad artwork key.")
            }
            guard music.authorized else {
                throw APIError(status: 409, message: "MusicKit isn't authorized on the Mac yet (\(music.authorizationName)).")
            }
            return respond(try await artwork.handle(source: source, kind: route[2], id: route[3],
                                                    query: request.query, library: library))
        }
        guard authorized(request) else { throw APIError(status: 401, message: "Missing or wrong bearer token.") }
        let client = Self.client(request)

        // Endpoints that work without MusicKit.
        switch (method, route) {
        case ("GET", ["status"]):
            return player.status(since: request.query["since"].flatMap(Int.init), client: client) { respond(.json(200, $0)) }
        case ("POST", ["authorize"]):
            // Not in the contract: asks macOS for Apple Music access (a dialog on the Mac).
            let status = await MusicAuthorization.request()
            music.refresh()
            if music.authorized {
                LibraryIndex.shared.start()
                LibraryIndex.shared.startMembership()
            }
            Log.info("MusicKit authorization: \(status)")
            return respond(.json(200, health()))
        default:
            break
        }

        guard music.authorized else {
            throw APIError(status: 409, message: "MusicKit isn't authorized on the Mac yet (\(music.authorizationName)).")
        }
        let body = try json(request)

        // Routes with ids in the path.
        if method == "GET", route.count == 3, let fetch = ["albums": library.albumDetail, "artists": library.artistDetail,
                                                           "playlists": library.playlistDetail][route[0]] {
            return respond(.json(200, try await fetch(MusicItemID(route[2]), try source(route[1]))))
        }
        if method == "GET", route.count == 4, route[0] == "info" {
            return respond(.json(200, try await library.info(kind: route[2], id: MusicItemID(route[3]), source: try source(route[1]))))
        }
        if method == "GET", route.count == 3, route[0] == "genres", route[1] == "library" {
            return respond(.json(200, try library.libraryGenreDetail(route[2])))
        }
        if method == "GET", route.count == 2, route[0] == "genres" {
            return respond(.json(200, try await library.genreDetail(MusicItemID(route[1]), limit: limit(request, 25, max: 50))))
        }
        if method == "POST", route.count == 4, route[0] == "library", route[1] == "playlists", route[3] == "tracks" {
            let items = try (body["items"] as? [Any] ?? []).map(ItemRef.init)
            guard !items.isEmpty else { throw APIError.badRequest("items is empty.") }
            let songs = try await library.songs(for: items) { player.queueSongs }
            return respond(.json(200, try await library.appendToPlaylist(MusicItemID(route[2]), songs: songs)))
        }

        // Only the machine the Mac plays for can pause or skip it; Play takes it over.
        if method == "POST", [["pause"], ["next"], ["previous"], ["seek"]].contains(route),
           let owner = player.elsewhere(for: client) {
            throw APIError(status: 409, message: "Apple Music is playing on \(owner): Play moves it here")
        }

        switch (method, route) {
        // Transport
        case ("POST", ["play"]):
            let items = try (body["items"] as? [Any] ?? []).map(ItemRef.init)
            guard !items.isEmpty else { throw APIError.badRequest("items is empty.") }
            let started = Date()
            let songs = try await library.expand(items) { player.queueSongs }
            let expanded = Date()
            let mode = body["mode"] as? String ?? "play"
            try await player.play(songs, start: body["start"] as? Int ?? 0, mode: mode)
            Log.info("play (\(mode)): \(items.count) item(s), \(songs.compactMap { $0 }.count) songs; found in "
                + "\(String(format: "%.1f", expanded.timeIntervalSince(started))) s, queued in \(String(format: "%.1f", Date().timeIntervalSince(expanded))) s")
            if mode == "play" { player.setOwner(client) }
        case ("POST", ["pause"]): await player.pauseSettled()
        case ("POST", ["resume"]):
            try await player.resume()
            player.setOwner(client)
        case ("POST", ["toggle"]): try await player.toggle(for: client)
        case ("POST", ["next"]): try await player.next()
        case ("POST", ["previous"]): try await player.previous()
        case ("POST", ["seek"]):
            guard let position = (body["position"] as? NSNumber)?.doubleValue else { throw APIError.badRequest("position is required.") }
            player.seek(to: position)
        case ("POST", ["queue", "jump"]):
            try await player.jump(to: try int(body, "index"))
            player.setOwner(client)
        case ("POST", ["queue", "remove"]): try player.remove(at: try int(body, "index"))
        case ("POST", ["shuffle"]):
            guard let on = body["on"] as? Bool else { throw APIError.badRequest("on is required.") }
            player.setShuffle(on)
        case ("POST", ["repeat"]):
            try player.setRepeat(body["mode"] as? String ?? "")

        // Search and browse
        case ("GET", ["search"]):
            let term = request.query["q"] ?? ""
            guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError.badRequest("q is required.") }
            let scope = request.query["scope"] ?? "all"
            guard ["all", "library", "catalog"].contains(scope) else { throw APIError.badRequest("scope is all, library or catalog.") }
            return respond(.json(200, try await library.search(term, scope: scope, limit: limit(request, 8, max: 25))))
        case ("GET", ["library", "playlists"]):
            return respond(.json(200, try library.libraryPlaylists()))
        case ("GET", ["library", "albums"]):
            return respond(.json(200, try library.libraryAlbums(offset: offset(request), limit: limit(request, 100, max: 500))))
        case ("GET", ["library", "artists"]):
            return respond(.json(200, try library.libraryArtists(offset: offset(request), limit: limit(request, 100, max: 500))))
        case ("GET", ["library", "recent"]):
            return respond(.json(200, try library.libraryRecent(limit: limit(request, 25, max: 100))))
        case ("GET", ["debug", "librarysong"]):
            // Diagnostics, outside the contract: what MusicKit's library gives for a song id.
            let id = MusicItemID(request.query["id"] ?? "")
            var one = MusicLibraryRequest<Song>()
            one.filter(matching: \.id, equalTo: id)
            var many = MusicLibraryRequest<Song>()
            many.filter(matching: \.id, memberOf: [id])
            func describe(_ songs: MusicItemCollection<Song>) -> [[String: Any]] {
                songs.map { ["id": $0.id.rawValue, "title": $0.title, "playParameters": $0.playParameters != nil] }
            }
            let a = try await one.response().items, b = try await many.response().items
            return respond(.json(200, ["equalTo": describe(a), "memberOf": describe(b)]))
        case ("POST", ["debug", "expand"]):
            // Diagnostics: how long POST /play's items take to become songs, without playing them.
            let items = try (body["items"] as? [Any] ?? []).map(ItemRef.init)
            let started = Date()
            let songs = try await library.expand(items) { player.queueSongs }
            return respond(.json(200, ["items": items.count, "songs": songs.count, "playable": songs.compactMap { $0 }.count,
                                       "seconds": Date().timeIntervalSince(started)]))
        case ("GET", ["debug", "cloudplaylist"]):
            // Diagnostics: the iCloud id the bridge would edit for a library playlist id.
            let id = try await library.cloudPlaylistID(MusicItemID(request.query["id"] ?? ""))
            return respond(.json(200, ["cloudId": id.rawValue]))
        case ("GET", ["debug", "apple"]):
            // Diagnostics, outside the contract: Apple's raw JSON for ?path=/v1/catalog/....
            let data = try await library.rawAppleGET(request.query["path"] ?? "")
            return respond(HTTPResponse(status: 200, body: data))
        case ("GET", ["genres"]):
            return respond(.json(200, try await library.genres()))

        // The library
        case ("POST", ["library", "add"]):
            let items = try (body["items"] as? [Any] ?? []).map(ItemRef.init)
            guard !items.isEmpty else { throw APIError.badRequest("items is empty.") }
            let result = try await library.addToLibrary(items)
            player.libraryChanged()
            return respond(.json(200, result))
        case ("POST", ["library", "playlists"]):
            guard let name = body["name"] as? String, !name.isEmpty else { throw APIError.badRequest("name is required.") }
            let items = try (body["items"] as? [Any] ?? []).map(ItemRef.init)
            let songs = try await library.songs(for: items) { player.queueSongs }
            return respond(.json(200, try await library.createPlaylist(name: name, songs: songs)))

        default:
            throw APIError.notFound("No such endpoint.")
        }
        // Transport endpoints answer with the new status.
        respond(.json(200, player.snapshot(for: client)))
    }

    private func health() -> [String: Any] {
        var health: [String: Any] = [
            "ok": true,
            "version": Self.version,
            "authorized": music.authorized,
            "musicAuthorization": music.authorizationName,
            "canPlayCatalog": music.canPlayCatalog,
            "stream": streamURL,
            "capturing": stream.capturing,
            "encoding": stream.encoderRunning,
        ]
        if let storefront = music.storefront { health["storefront"] = storefront }
        return health
    }

    // MARK: Request helpers

    /// The machine a request comes from (X-Omarock-Client: its hostname), if it says.
    private static func client(_ request: HTTPRequest) -> String? {
        guard let name = request.headers["x-omarock-client"]?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, name.count <= 64, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) })
        else { return nil }
        return name
    }

    /// Constant-time comparison of the bearer token.
    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let given = Data(header.dropFirst("Bearer ".count).utf8)
        guard given.count == token.count else { return false }
        return zip(given, token).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func json(_ request: HTTPRequest) throws -> [String: Any] {
        guard !request.body.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            throw APIError.badRequest("The body isn't a JSON object.")
        }
        return object
    }

    private func source(_ name: String) throws -> Source {
        guard let source = Source(name) else { throw APIError.badRequest("source is catalog or library.") }
        return source
    }

    private func int(_ body: [String: Any], _ key: String) throws -> Int {
        guard let value = body[key] as? Int else { throw APIError.badRequest("\(key) is required.") }
        return value
    }

    private func limit(_ request: HTTPRequest, _ fallback: Int, max: Int) -> Int {
        Swift.min(Swift.max(Int(request.query["limit"] ?? "") ?? fallback, 1), max)
    }

    private func offset(_ request: HTTPRequest) -> Int {
        Swift.max(Int(request.query["offset"] ?? "") ?? 0, 0)
    }
}

/// Owns the pieces and their lifetimes.
@MainActor
final class Bridge {
    private let config: Config
    private let music = MusicStatus()
    private let library = MusicService()
    private let player = Player()
    private let listeners: ListenerWatch
    private let stream: StreamService
    private let server: HTTPServer

    /// `host`: the address to serve on (the Mac's Tailscale address, or config's listenHost).
    init(config: Config, host: String) throws {
        try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        self.config = config
        let token = try Secrets.token()
        try IcecastConfig.prepare(host: host, icecast: config.icecast)
        stream = try StreamService(config: config)
        listeners = ListenerWatch(player: player) { [player] in player.pause() }
        player.ensureMuted = { [stream] in await stream.waitUntilPlaybackIsTapped() }
        let artwork = ArtworkServer(token: token, base: "http://\(host):\(config.port)")
        Normalize.artworkServer = artwork
        let api = API(token: token, config: config, streamURL: config.stream(host: host), music: music, library: library,
                      stream: stream, player: player, artwork: artwork)
        server = HTTPServer(host: host, port: config.port) { request, respond in
            api.handle(request, respond: respond)
        }
    }

    func start() {
        Log.info("omarock bridge \(API.version) starting (pid \(getpid()), MusicKit \(music.authorizationName))")
        music.refresh()
        if music.authorized {
            LibraryIndex.shared.start()
            LibraryIndex.shared.startMembership()
        } else if music.authorization == .notDetermined {
            // First launch: ask for Apple Music access (a dialog on the Mac). Later answers
            // are changed in System Settings → Privacy & Security → Media & Apple Music.
            Task { @MainActor [music] in
                let status = await MusicAuthorization.request()
                Log.info("MusicKit authorization: \(status)")
                music.refresh()
                if music.authorized {
                    LibraryIndex.shared.start()
                    LibraryIndex.shared.startMembership()
                }
            }
        }
        player.start()
        listeners.start()
        stream.start()
        server.start()
    }

    func stop() {
        server.stop()
        stream.stop()
    }
}
