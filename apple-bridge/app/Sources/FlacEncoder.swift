import FLAC
import Foundation

/// `OmarockBridge --encode RATE`: s16le stereo PCM on stdin → Ogg FLAC on stdout, for
/// ffmpeg to re-page and send to Icecast (StreamService).
///
/// libFLAC rather than ffmpeg's FLAC encoder for its limit_min_bitrate: a frame is never
/// all constant subframes, so digital silence costs at least 1 bit a sample (about 6 KB/s)
/// instead of almost nothing. At ~300 B/s an Ogg FLAC client behind Icecast (mpd with a
/// stock libFLAC) waits so long for its buffer that it ends up tens of seconds behind.
///
/// The Ogg pages are the bridge's own, one per frame, written unbuffered the moment
/// libFLAC hands a frame over: native FLAC through ffmpeg's flac demuxer is held back
/// about 10 frames (its parser waits for that many frame headers), Ogg isn't.
enum FlacEncoder {
    static func run(sampleRate: UInt32) -> Int32 {
        guard let encoder = FLAC__stream_encoder_new() else { return fail("cannot make a FLAC encoder") }
        FLAC__stream_encoder_set_channels(encoder, 2)
        FLAC__stream_encoder_set_bits_per_sample(encoder, 16)
        FLAC__stream_encoder_set_sample_rate(encoder, sampleRate)
        FLAC__stream_encoder_set_compression_level(encoder, 5)
        FLAC__stream_encoder_set_limit_min_bitrate(encoder, 1)

        let ogg = OggFLACWriter(fd: STDOUT_FILENO)
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
        while true {
            let n = input.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress! + have, capacity - have) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            have += n
            let frames = have / 4
            for i in 0..<frames * 2 { samples[i] = Int32(Int16(bitPattern: UInt16(input[2 * i]) | UInt16(input[2 * i + 1]) << 8)) }
            guard FLAC__stream_encoder_process_interleaved(encoder, samples, UInt32(frames)) != 0 else {
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

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("omarock bridge --encode: \(message)\n".utf8))
        return 1
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
            guard writeAll(page) else { return false }
            sequence += 1
            at += body.count
            continued = true
        } while !ended
        return true
    }

    private func writeAll(_ bytes: [UInt8]) -> Bool {
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

    // Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, starting from 0.
    private static let table: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i) << 24) { c, _ in c & 0x8000_0000 != 0 ? c << 1 ^ 0x04C1_1DB7 : c << 1 }
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { c, b in c << 8 ^ table[Int(UInt8(c >> 24) ^ b)] }
    }
}
