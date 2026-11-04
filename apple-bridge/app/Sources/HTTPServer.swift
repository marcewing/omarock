import Darwin
import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// Lowercased names.
    let headers: [String: String]
    let body: Data
    /// How the client reached the bridge, "host:port": its Host header, or else the address
    /// it connected to. URLs the bridge hands out are built from it (apple-bridge/API.md).
    let authority: String

    /// The authority's host, with an IPv6 address's brackets.
    var host: String {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") { return String(authority[...close]) }
        return authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
    }
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

/// A minimal HTTP/1.1 server: one request per connection (Connection: close), bodies by
/// Content-Length only. Enough for omarock and curl. It listens on every address, IPv4 and
/// IPv6, through one dual-stack socket, or on just the addresses it's given.
///
/// Plain BSD sockets and GCD rather than NWListener: on macOS 27 an NWListener with a
/// required local endpoint on the Tailscale interface accepts each flow and then fails
/// to attach it ("connectx ... Address already in use"), so no request ever arrives.
final class HTTPServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    /// Empty: every address.
    private let hosts: [String]
    private let port: UInt16
    private let queue: DispatchQueue
    private let handler: Handler
    private var acceptSources: [DispatchSourceRead] = []
    private var stopped = false

    init(hosts: [String], port: UInt16, queue: DispatchQueue = .main, handler: @escaping Handler) {
        self.hosts = hosts
        self.port = port
        self.queue = queue
        self.handler = handler
    }

    private var addresses: String {
        hosts.isEmpty ? "every address, port \(port)" : hosts.map { "\($0.contains(":") ? "[\($0)]" : $0):\(port)" }.joined(separator: " and ")
    }

    func start() {
        stopped = false
        var fds: [Int32] = []
        do {
            for host in hosts.isEmpty ? [nil] : hosts.map(Optional.some) { fds.append(try bindAndListen(host)) }
        } catch {
            // The port in use (a bridge that hasn't quite quit), or listenHost not up yet.
            fds.forEach { close($0) }
            Log.error("cannot listen on \(addresses): \(error); retrying in 5 s")
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !stopped else { return }
                start()
            }
            return
        }
        for fd in fds {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending(fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            acceptSources.append(source)
        }
        Log.info("API listening on \(addresses)")
    }

    func stop() {
        stopped = true
        acceptSources.forEach { $0.cancel() }
        acceptSources = []
    }

    /// `host` nil: IPv6's any address, with IPV6_V6ONLY off, so IPv4 too.
    private func bindAndListen(_ host: String?) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = host == nil ? AF_INET6 : AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let numeric = host.map { $0.hasPrefix("[") && $0.hasSuffix("]") ? String($0.dropFirst().dropLast()) : $0 }
        let status = getaddrinfo(numeric, String(port), &hints, &info)
        guard status == 0, let address = info?.pointee else {
            throw BridgeError("\(host ?? "::") is not an IP address (\(String(cString: gai_strerror(status))))")
        }
        defer { freeaddrinfo(info) }

        let fd = socket(address.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if address.ai_family == AF_INET6 {
            var v6only: Int32 = host == nil ? 0 : 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
        }
        guard bind(fd, address.ai_addr, address.ai_addrlen) == 0, listen(fd, 64) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw BridgeError(message)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private func acceptPending(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }  // EAGAIN: nothing more to accept
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            HTTPConnection(fd: fd, local: Self.localAuthority(fd), queue: queue, handler: handler).start()
        }
    }

    /// "address:port" of the connection's end on this Mac: IPv4 as itself (not IPv4-mapped),
    /// IPv6 in brackets, with any zone as %25.
    private static func localAuthority(_ fd: Int32) -> String {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let found = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getsockname(fd, address, &length) == 0
                    && getnameinfo(address, length, &host, socklen_t(host.count), &service, socklen_t(service.count),
                                   NI_NUMERICHOST | NI_NUMERICSERV) == 0
            }
        }
        guard found else { return "127.0.0.1" }
        var address = String(cString: host)
        if address.hasPrefix("::ffff:"), address.contains(".") { address.removeFirst("::ffff:".count) }
        if address.contains(":") { address = "[\(address.replacingOccurrences(of: "%", with: "%25"))]" }
        return "\(address):\(String(cString: service))"
    }
}

private final class HTTPConnection {
    private static let maxHeader = 64 * 1024
    private static let maxBody = 1024 * 1024

    private let fd: Int32
    private let local: String
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var received = false
    private var answered = false
    private var closed = false

    init(fd: Int32, local: String, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.fd = fd
        self.local = local
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
                                    body: buffer.subdata(in: bodyStart..<bodyStart + length),
                                    authority: Self.authority(headers["host"], local: local)))
    }

    /// The Host header if it's a plain name or address (it ends up in JSON and URLs), else `local`.
    private static func authority(_ host: String?, local: String) -> String {
        guard let host, !host.isEmpty, host.count <= 255,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]%".contains($0)) })
        else { return local }
        return host
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
