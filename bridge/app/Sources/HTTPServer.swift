import Darwin
import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// Lowercased names.
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType = "application/json; charset=utf-8"
    var cacheControl = "no-store"

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return HTTPResponse(status: status, body: body)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }
}

/// A minimal HTTP/1.1 server on one local IPv4 address: one request per connection
/// (Connection: close), bodies by Content-Length only. Enough for omarock and curl.
///
/// Plain BSD sockets and GCD rather than NWListener: on macOS 27 an NWListener with a
/// required local endpoint on the Tailscale interface accepts each flow and then fails
/// to attach it ("connectx ... Address already in use"), so no request ever arrives.
final class HTTPServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var stopped = false

    init(host: String, port: UInt16, queue: DispatchQueue = .main, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.queue = queue
        self.handler = handler
    }

    func start() {
        stopped = false
        do {
            listenFD = try bindAndListen()
        } catch {
            // Typically the tailnet address isn't up yet (Tailscale starting after login).
            Log.error("cannot listen on \(host):\(port): \(error); retrying in 5 s")
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !stopped else { return }
                start()
            }
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { [fd = listenFD] in close(fd) }
        source.resume()
        acceptSource = source
        Log.info("API listening on http://\(host):\(port)")
    }

    func stop() {
        stopped = true
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
    }

    private func bindAndListen() throws -> Int32 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw BridgeError("\(host) is not an IPv4 address") }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw BridgeError(message)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }  // EAGAIN: nothing more to accept
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            HTTPConnection(fd: fd, queue: queue, handler: handler).start()
        }
    }
}

private final class HTTPConnection {
    private static let maxHeader = 64 * 1024
    private static let maxBody = 1024 * 1024

    private let fd: Int32
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var received = false
    private var answered = false
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.fd = fd
        self.queue = queue
        self.handler = handler
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // The source holds the connection alive until the request is read.
        source.setEventHandler { [self] in readAvailable() }
        source.resume()
        readSource = source
        // Drop clients that never finish sending a request (long polls are already received).
        queue.asyncAfter(deadline: .now() + 30) { [self] in
            if !received { finish() }
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return finish()
        }
        if n == 0 { return finish() }  // client closed before a full request
        buffer.append(contentsOf: chunk[0..<n])

        switch parse() {
        case .incomplete:
            return
        case .bad(let message):
            send(.error(400, message))
        case .tooLarge:
            send(.error(413, "The request is too large."))
        case .request(let request):
            received = true
            // Stop reading; the reply (maybe after a long poll) closes the connection.
            readSource?.cancel()
            readSource = nil
            handler(request) { [self] response in send(response) }
        }
    }

    private enum Parse {
        case incomplete, bad(String), tooLarge, request(HTTPRequest)
    }

    private func parse() -> Parse {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeader ? .tooLarge : .incomplete
        }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .bad("The request isn't UTF-8.") }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .bad("Malformed request line.") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .bad("Malformed header.") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad("Bad Content-Length.") }
        guard length <= Self.maxBody else { return .tooLarge }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }

        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(HTTPRequest(method: String(parts[0]), path: components?.percentEncodedPath ?? target,
                                    query: query, headers: headers,
                                    body: buffer.subdata(in: bodyStart..<bodyStart + length)))
    }

    private func send(_ response: HTTPResponse) {
        guard !answered, !closed else { return }
        answered = true
        readSource?.cancel()
        readSource = nil
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: \(response.cacheControl)\r\n"
        head += "Connection: close\r\n\r\n"
        let data = Data(head.utf8) + response.body
        closed = true

        // Replies are small; write them blocking, off the main queue, then close.
        let fd = self.fd
        DispatchQueue.global().async {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 { if errno == EINTR { continue } else { break } }
                    offset += n
                }
            }
            close(fd)
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        close(fd)
    }
}
