import FLAC
import Foundation

/// `OmarockBridge --encode RATE [MOUNT]`: s16le stereo PCM on stdin → Ogg FLAC, sent to
/// Icecast as the mount's source (IcecastSource), or to stdout if MOUNT is `-`. It ends when
/// the connection does, and StreamService starts a new one, with new headers.
///
/// libFLAC rather than ffmpeg's FLAC encoder for its limit_min_bitrate: a frame is never
/// all constant subframes, so digital silence costs at least 1 bit a sample (about 6 KB/s)
/// instead of almost nothing. At ~300 B/s an Ogg FLAC client behind Icecast (mpd with a
/// stock libFLAC) waits so long for its buffer that it ends up tens of seconds behind.
/// Even 6 KB/s is slow: a stock libFLAC fills each 8 KiB read before it returns, so mpd
/// sits ~1.9 s behind. So after `quietSeconds` of (near) digital silence, every |sample| ≤ 1,
/// the encoder replaces it with noise of -1, 0 or +1, about 24 KB/s, until a louder sample.
/// Everything else goes through bit-exact.
///
/// The Ogg pages are the bridge's own, one per frame, written the moment libFLAC hands a
/// frame over; a frame is `blockSize` samples.
enum FlacEncoder {
    /// 21 ms at 48 kHz, against libFLAC's default 4096.
    static let blockSize: UInt32 = 1024
    static let quietSeconds = 0.1

    static func run(sampleRate: UInt32, mount: String) -> Int32 {
        let out: Int32
        if mount == "-" {
            out = STDOUT_FILENO
        } else {
            do {
                out = try IcecastSource.connect(mount: mount)
            } catch {
                return fail("\(error)")
            }
        }
        guard let encoder = FLAC__stream_encoder_new() else { return fail("cannot make a FLAC encoder") }
        FLAC__stream_encoder_set_channels(encoder, 2)
        FLAC__stream_encoder_set_bits_per_sample(encoder, 16)
        FLAC__stream_encoder_set_sample_rate(encoder, sampleRate)
        FLAC__stream_encoder_set_compression_level(encoder, 5)
        FLAC__stream_encoder_set_blocksize(encoder, blockSize)
        FLAC__stream_encoder_set_limit_min_bitrate(encoder, 1)

        let ogg = OggFLACWriter(fd: out)
        let status = FLAC__stream_encoder_init_stream(encoder, { _, buffer, bytes, samples, _, context in
            let ogg = Unmanaged<OggFLACWriter>.fromOpaque(context!).takeUnretainedValue()
            return ogg.write(UnsafeBufferPointer(start: buffer, count: bytes), samples: Int(samples))
                ? FLAC__STREAM_ENCODER_WRITE_STATUS_OK : FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR
        }, nil, nil, nil, Unmanaged.passUnretained(ogg).toOpaque())
        guard status == FLAC__STREAM_ENCODER_INIT_STATUS_OK else {
            return fail("FLAC encoder: \(String(cString: FLAC__stream_encoder_get_resolved_state_string(encoder)))")
        }

        let capacity = 1 << 16
        var input = [UInt8](repeating: 0, count: capacity)
        var samples = [Int32](repeating: 0, count: capacity / 2)
        var have = 0
        let quietFrames = Int(Double(sampleRate) * quietSeconds)
        var quiet = 0
        var noise = UInt64.random(in: 1...UInt64.max)
        func faint() -> Int32 {
            noise ^= noise << 13
            noise ^= noise >> 7
            noise ^= noise << 17
            return Int32((noise >> 32) % 3) - 1
        }
        // (Not into a file: there all of stdin is the input.)
        if mount != "-" { skipBacklog() }
        while true {
            let n = input.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress! + have, capacity - have) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            have += n
            let frames = have / 4
            for f in 0..<frames {
                var left = Int32(Int16(bitPattern: UInt16(input[4 * f]) | UInt16(input[4 * f + 1]) << 8))
                var right = Int32(Int16(bitPattern: UInt16(input[4 * f + 2]) | UInt16(input[4 * f + 3]) << 8))
                if abs(left) <= 1, abs(right) <= 1 {
                    quiet += 1
                    if quiet > quietFrames {
                        left = faint()
                        right = faint()
                    }
                } else {
                    quiet = 0
                }
                samples[2 * f] = left
                samples[2 * f + 1] = right
            }
            guard FLAC__stream_encoder_process_interleaved(encoder, samples, UInt32(frames)) != 0 else {
                if ogg.failure != 0 { return fail("the connection to Icecast ended: \(String(cString: strerror(ogg.failure)))") }
                return fail("FLAC encoder: \(String(cString: FLAC__stream_encoder_get_resolved_state_string(encoder)))")
            }
            // Keep a partial sample frame for the next read.
            let used = frames * 4
            input.replaceSubrange(0..<have - used, with: input[used..<have])
            have -= used
        }
        FLAC__stream_encoder_finish(encoder)
        FLAC__stream_encoder_delete(encoder)
        return 0
    }

    /// Drops what queued up while no encoder was reading (the pipe's 64 KB and up to 2 s in the
    /// PCMWriter), so a restarted stream starts at the tap's present rather than seconds behind.
    /// The queue has run out once 5 ms pass with nothing to read: the tap writes every ~10 ms.
    private static func skipBacklog() {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var skipped = 0
        var stdin = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while poll(&stdin, 1, 5) > 0 {
            let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            skipped += n
        }
        // The rest of a sample frame it ended in the middle of.
        var rest = (4 - skipped % 4) % 4
        while rest > 0 {
            let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress!, rest) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            rest -= n
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("omarock bridge --encode: \(message)\n".utf8))
        return 1
    }
}

/// Icecast's source protocol, as libshout speaks it: an HTTP PUT to the mount with the
/// source password, then the stream as the request's body for as long as it lasts.
enum IcecastSource {
    /// A socket to 127.0.0.1:8000 that Icecast has taken as the mount's source.
    static func connect(mount: String) throws -> Int32 {
        let password = try Secrets.sourcePassword()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("socket(): \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        // A closed connection is EPIPE, not SIGPIPE; and each page goes out as it's written.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(8000).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw BridgeError("cannot connect to Icecast on 127.0.0.1:8000: \(reason)")
        }
        let request = [
            "PUT \(mount) HTTP/1.1",
            "Host: 127.0.0.1:8000",
            "Authorization: Basic " + Data("source:\(password)".utf8).base64EncodedString(),
            "User-Agent: omarock-bridge",
            "Content-Type: application/ogg",
            "Ice-Name: omarock",
            "Ice-Public: 0",
            "Expect: 100-continue",
            "", "",
        ].joined(separator: "\r\n")
        // Icecast answers 100 Continue once it takes the source; 401 for a wrong password,
        // 403 when the mount already has one.
        var response: [UInt8] = []
        var byte: UInt8 = 0
        if writeAll(fd, Array(request.utf8)) {
            while !response.ends(with: [13, 10, 13, 10]), response.count < 4096, read(fd, &byte, 1) == 1 {
                response.append(byte)
            }
        }
        let status = String(decoding: response, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
        let code = status.split(separator: " ").dropFirst().first
        guard code == "100" || code == "200" else {
            close(fd)
            throw BridgeError("Icecast refused the source for \(mount.hasPrefix("/omarock-") ? "the stream's mount" : mount): \(status.isEmpty ? "no answer" : status)")
        }
        return fd
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool { count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix }
}

/// Writes all of `bytes`, retrying after signals; false once the fd fails.
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { buffer in
        var at = 0
        while at < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress! + at, buffer.count - at)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            at += n
        }
        return true
    }
}

/// Native FLAC from libFLAC's write callback → the Ogg FLAC mapping (xiph.org/flac/ogg_mapping.html):
/// a first packet with the mapping's header and STREAMINFO, a packet for each other metadata
/// block, then a packet for each frame.
final class OggFLACWriter {
    private let fd: Int32
    private let serial = UInt32.random(in: 0...UInt32.max)
    private var sequence: UInt32 = 0
    private var granule: Int64 = 0
    /// errno from the write that failed.
    private(set) var failure: Int32 = 0
    /// "fLaC" and the metadata blocks, until the first frame.
    private var header: [UInt8]? = []

    init(fd: Int32) { self.fd = fd }

    func write(_ bytes: UnsafeBufferPointer<UInt8>, samples: Int) -> Bool {
        if samples == 0, header != nil {
            header! += bytes
            return true
        }
        if let header {
            self.header = nil
            guard writeHeaders(header) else { return false }
        }
        granule += Int64(samples)
        return page(Array(bytes), granule: granule)
    }

    private func writeHeaders(_ native: [UInt8]) -> Bool {
        // "fLaC", then blocks of a 4-byte header (last-block flag and type, then a 24-bit length) and a body.
        guard native.count >= 8, native.starts(with: Array("fLaC".utf8)) else { return false }
        var blocks: [[UInt8]] = []
        var at = 4
        while at + 4 <= native.count {
            let length = Int(native[at + 1]) << 16 | Int(native[at + 2]) << 8 | Int(native[at + 3])
            guard at + 4 + length <= native.count else { return false }
            blocks.append(Array(native[at..<at + 4 + length]))
            at += 4 + length
        }
        guard let streaminfo = blocks.first, streaminfo[0] & 0x7F == 0 else { return false }
        let others = blocks.dropFirst()
        let first = [0x7F] + Array("FLAC".utf8) + [1, 0, UInt8(others.count >> 8), UInt8(others.count & 0xFF)]
            + Array("fLaC".utf8) + streaminfo
        guard page(first, granule: 0, flags: 0x02) else { return false }
        return others.allSatisfy { page($0, granule: 0) }
    }

    /// Writes one packet as one page (or more, for one over 255 lacing segments).
    private func page(_ packet: [UInt8], granule: Int64, flags: UInt8 = 0) -> Bool {
        var at = 0
        var continued = false
        var ended = false
        repeat {
            let rest = packet.count - at
            let full = rest / 255
            // A page holds 255 segments; a packet that ends on it needs one for its last (< 255) bytes.
            let ends = full < 255
            ended = ends
            let segments = ends ? [UInt8](repeating: 255, count: full) + [UInt8(rest % 255)] : [UInt8](repeating: 255, count: 255)
            let body = packet[at..<at + (ends ? rest : 255 * 255)]
            var page = Array("OggS".utf8) + [0, (continued ? 0x01 : 0) | (at == 0 ? flags : 0)]
            page += withUnsafeBytes(of: (ends ? granule : -1).littleEndian, Array.init)
            page += withUnsafeBytes(of: serial.littleEndian, Array.init)
            page += withUnsafeBytes(of: sequence.littleEndian, Array.init)
            page += [0, 0, 0, 0, UInt8(segments.count)] + segments + body
            let crc = Self.crc(page)
            page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
            guard writeAll(fd, page) else {
                failure = errno
                return false
            }
            sequence += 1
            at += body.count
            continued = true
        } while !ended
        return true
    }

    // Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, starting from 0.
    private static let table: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i) << 24) { c, _ in c & 0x8000_0000 != 0 ? c << 1 ^ 0x04C1_1DB7 : c << 1 }
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { c, b in c << 8 ^ table[Int(UInt8(c >> 24) ^ b)] }
    }
}
