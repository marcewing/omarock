import AppKit
import CryptoKit
import Foundation
import MusicKit
import os
import SwiftUI

/// GET /v1/artwork/{source}/{kind}/{id}?w=&h=&k=: JPEGs for artwork only MusicKit can open
/// (library-only items have local musicKit:// artwork). omarock loads these with a QML
/// Image, which can't send the bearer header, so each URL carries its own key:
/// k = the first 16 hex digits of HMAC-SHA256(token, "{source}/{kind}/{id}").
@MainActor
final class ArtworkServer {
    /// Templates start with this. API puts http://{the request's Host} in its place as it
    /// answers, so each URL works by whichever name or address that client used.
    nonisolated static let base = "http://omarock-bridge.invalid"

    private let key: SymmetricKey
    private let cache = Paths.support.appendingPathComponent("artwork-cache")
    /// Every Artwork handed out as a bridge URL, so /v1/artwork can draw it without asking
    /// Apple for the item again (catalog lookups need the developer token). Bounded.
    private nonisolated(unsafe) var known: [String: Artwork] = [:]
    private nonisolated(unsafe) var knownOrder: [String] = []
    private nonisolated(unsafe) var knownLock = os_unfair_lock()

    init(token: String) {
        key = SymmetricKey(data: Data(token.utf8))
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    /// The template Normalize hands out when Apple gives no https one.
    /// Remembers `artwork` for this item and returns its keyed URL template.
    nonisolated func template(for artwork: Artwork, source: Source, kind: String, id: String) -> String {
        let path = "\(source.rawValue)/\(kind)/\(id)"
        os_unfair_lock_lock(&knownLock)
        if known.updateValue(artwork, forKey: path) == nil {
            knownOrder.append(path)
            if knownOrder.count > 20000 { known[knownOrder.removeFirst()] = nil }
        }
        os_unfair_lock_unlock(&knownLock)
        return template(source: source, kind: kind, id: id)
    }

    private nonisolated func remembered(_ path: String) -> Artwork? {
        os_unfair_lock_lock(&knownLock)
        defer { os_unfair_lock_unlock(&knownLock) }
        return known[path]
    }

    nonisolated func template(source: Source, kind: String, id: String) -> String {
        let path = "\(source.rawValue)/\(kind)/\(id)"
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return "\(Self.base)/v1/artwork/\(source.rawValue)/\(kind)/\(escaped)?w={w}&h={h}&k=\(Self.sign(path, key))"
    }

    /// Whether `k` is the key for this artwork; checked before anything else.
    func verify(source: Source, kind: String, id: String, k: String?) -> Bool {
        guard let k else { return false }
        return Self.constantTimeEqual(k, Self.sign("\(source.rawValue)/\(kind)/\(id)", key))
    }

    /// Call after `verify`.
    func handle(source: Source, kind: String, id: String, query: [String: String], library: MusicService) async throws -> HTTPResponse {
        let path = "\(source.rawValue)/\(kind)/\(id)"
        let w = min(max(Int(query["w"] ?? "") ?? 600, 16), 3000)
        let h = min(max(Int(query["h"] ?? "") ?? w, 16), 3000)
        let file = cache.appendingPathComponent("\(source.rawValue)-\(kind)-\(Self.safe(id))-\(w)x\(h).jpg")
        if let data = try? Data(contentsOf: file) { return Self.jpeg(data) }

        // ITLib first: it's local, quick, and doesn't queue behind MusicKit's library requests.
        if source == .library, let image = LibraryIndex.shared.artwork(kind: kind, id: id), let data = Self.jpeg(image, w, h) {
            try? data.write(to: file, options: .atomic)
            return Self.jpeg(data)
        }
        // Then the Artwork the bridge handed this URL out for; only then ask MusicKit again.
        let artwork: Artwork
        if let known = remembered(path) {
            artwork = known
        } else {
            artwork = try await self.artwork(source: source, kind: kind, id: MusicItemID(id), library: library)
        }
        guard let data = try await render(artwork, width: w, height: h) else {
            throw APIError.notFound("No artwork for \(path).")
        }
        try? data.write(to: file, options: .atomic)
        return Self.jpeg(data)
    }

    private func artwork(source: Source, kind: String, id: MusicItemID, library: MusicService) async throws -> Artwork {
        let artwork: Artwork?
        switch kind {
        case "song": artwork = try await library.song(id, source).artwork
        case "album": artwork = try await library.album(id, source).artwork
        case "artist": artwork = try await library.artist(id, source).artwork
        case "playlist": artwork = try await library.playlist(id, source).artwork
        default: throw APIError.badRequest("kind is song, album, artist or playlist.")
        }
        guard let artwork else { throw APIError.notFound("No artwork for \(source.rawValue)/\(kind)/\(id.rawValue).") }
        return artwork
    }

    /// An https template is fetched; anything else is drawn by MusicKit's ArtworkImage,
    /// which loads asynchronously, so render until it stops being a blank placeholder.
    private func render(_ artwork: Artwork, width: Int, height: Int) async throws -> Data? {
        if let url = artwork.url(width: width, height: height), url.scheme == "https" {
            let (data, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        }
        let view = ArtworkImage(artwork, width: CGFloat(width), height: CGFloat(height))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        var image: CGImage?
        for _ in 0..<30 {
            image = renderer.cgImage
            if let image, !Self.isBlank(image) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: Helpers

    private nonisolated static func sign(_ path: String, _ key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(path.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func jpeg(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, body: data, contentType: "image/jpeg", cacheControl: "private, max-age=86400")
    }

    /// Scales to fill w×h (cropping the longer side) and encodes as JPEG.
    private static func jpeg(_ image: NSImage, _ w: Int, _ h: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = max(CGFloat(w) / size.width, CGFloat(h) / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: CGRect(x: (CGFloat(w) - drawn.width) / 2, y: (CGFloat(h) - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func safe(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber || $0 == "." ? String($0) : "_" }.joined()
    }

    /// True for an image of (nearly) one colour: ArtworkImage's placeholder before it loads.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let channels = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) + Int(pixels[$0 + 1]) + Int(pixels[$0 + 2]) }
        guard let low = channels.min(), let high = channels.max() else { return true }
        return high - low < 12
    }
}
