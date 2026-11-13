import Darwin
import Foundation

/// Talking to the bridge's Icecast on 127.0.0.1:8000, and only to it.
///
/// Anything that carries Icecast's passwords, the stream's mount or its audio goes over a
/// connection that `connect` has checked reached an Icecast of this account: a process run
/// by this user from config.json's `icecast`, holding the other end of this very connection
/// (the same addresses and ports, which no other connection can have). Whatever else
/// answers on the port gets nothing. On macOS another account can listen on a free
/// 127.0.0.1:8000 before the bridge starts it, and anyone can beside a wildcard bind of
/// their own; neither can pass as a process of this user.
enum Icecast {
    static let port: UInt16 = 8000

    struct NotOurs: Error, CustomStringConvertible {
        var port = Icecast.port
        var description: String { "something else answered on 127.0.0.1:\(port), not this account's Icecast; sent it nothing" }
    }

    /// `--encode`'s exit status when it found NotOurs.
    static let notOursStatus: Int32 = 3

    enum Holder: Equatable {
        /// Nothing listens on the port.
        case free
        /// An Icecast of this account took the connection.
        case ours(pid_t)
        /// Something else did.
        case taken
    }

    /// Who takes a connection to the port. Sends nothing; blocks for up to `timeout`.
    static func holder(executable: String, port: UInt16 = port, timeout: TimeInterval = 1) -> Holder {
        do {
            let (fd, pid) = try connect(executable: executable, port: port, timeout: timeout)
            close(fd)
            return .ours(pid)
        } catch is NotOurs {
            return .taken
        } catch {
            return .free
        }
    }

    /// A connection to 127.0.0.1:`port` that an Icecast of this account has accepted, and
    /// that Icecast's pid. Throws NotOurs (the socket closed, nothing sent) when something
    /// else took it, and BridgeError when nothing did.
    static func connect(executable: String, port: UInt16 = port, timeout: TimeInterval = 2) throws -> (Int32, pid_t) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("socket(): \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        // A closed connection is EPIPE, not SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw BridgeError("cannot connect to Icecast on 127.0.0.1:\(port): \(reason)")
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0, local.sin_family == sa_family_t(AF_INET) else {
            close(fd)
            throw NotOurs(port: port)
        }
        // The connection appears among Icecast's sockets once it accepts it, at once in practice.
        let candidates = processes(executable: executable)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for pid in candidates where accepted(pid: pid, port: port, from: UInt16(bigEndian: local.sin_port)) {
                return (fd, pid)
            }
            usleep(5_000)
        } while !candidates.isEmpty && Date() < deadline
        close(fd)
        throw NotOurs(port: port)
    }

    /// The processes of this user running `executable` (symlinks resolved, as Homebrew's are).
    static func processes(executable: String) -> [pid_t] {
        let want = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let uid = getuid()
        let count = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        let got = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.prefix(Int(got) / MemoryLayout<pid_t>.stride).filter { pid in
            guard pid > 0 else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == uid
                && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == want
        }
    }

    /// Whether `pid` holds the server end of the connection 127.0.0.1:`from` → 127.0.0.1:`port`.
    private static func accepted(pid: pid_t, port: UInt16, from: UInt16) -> Bool {
        tcpSockets(pid).contains { socket in
            socket.state == TSI_S_ESTABLISHED && socket.localPort == port && socket.foreignPort == from
                && socket.localIsLoopback && socket.foreignIsLoopback
        }
    }

    /// Whether `pid` listens on `port`.
    static func listens(pid: pid_t, port: UInt16 = port) -> Bool {
        tcpSockets(pid).contains { $0.state == TSI_S_LISTEN && $0.localPort == port }
    }

    private struct TCPSocket {
        var state: Int32
        var localPort: UInt16
        var foreignPort: UInt16
        var localIsLoopback: Bool
        var foreignIsLoopback: Bool
    }

    private static func tcpSockets(_ pid: pid_t) -> [TCPSocket] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return [] }
        return fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd in
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { return nil }
            let tcp = info.psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            // An IPv4 connection to a dual-stack listener is an IPv4 socket once accepted;
            // an IPv6 one may still carry it as ::ffff:127.0.0.1.
            func loopback(_ address: in4in6_addr, _ v6: in6_addr) -> Bool {
                if Int32(ini.insi_vflag) & INI_IPV4 != 0 { return UInt32(bigEndian: address.i46a_addr4.s_addr) >> 24 == 127 }
                var v6 = v6
                return withUnsafeBytes(of: &v6) { b in
                    b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF && b[12] == 127
                }
            }
            return TCPSocket(state: tcp.tcpsi_state,
                             localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)),
                             foreignPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)),
                             localIsLoopback: loopback(ini.insi_laddr.ina_46, ini.insi_laddr.ina_6),
                             foreignIsLoopback: loopback(ini.insi_faddr.ina_46, ini.insi_faddr.ina_6))
        }
    }

    /// GET `path` from our Icecast with the admin password: the status code and body.
    /// Blocking (up to a few seconds), so off the main thread.
    static func admin(_ path: String, executable: String, port: UInt16 = port) throws -> (Int, String) {
        let password = try Secrets.adminPassword()
        let (fd, _) = try connect(executable: executable, port: port)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = [
            "GET \(path) HTTP/1.0",
            "Host: 127.0.0.1:\(port)",
            "Authorization: Basic " + Data("admin:\(password)".utf8).base64EncodedString(),
            "User-Agent: omarock-bridge",
            "", "",
        ].joined(separator: "\r\n")
        guard writeAll(fd, Array(request.utf8)) else { throw BridgeError("Icecast closed the connection") }
        // HTTP/1.0: the answer ends with the connection.
        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16384)
        while response.count < 1 << 20 {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            response += buffer[0..<n]
        }
        let text = String(decoding: response, as: UTF8.self)
        guard let status = text.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap({ Int($0) }) else {
            throw BridgeError("no answer from Icecast")
        }
        let body = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        return (status, body)
    }
}

/// Icecast's source protocol, as libshout speaks it: an HTTP PUT to the mount with the
/// source password, then the stream as the request's body for as long as it lasts.
enum IcecastSource {
    /// A socket to our Icecast (Icecast.connect) that it has taken as the mount's source.
    static func connect(mount: String, executable: String, port: UInt16 = Icecast.port) throws -> Int32 {
        let password = try Secrets.sourcePassword()
        let (fd, _) = try Icecast.connect(executable: executable, port: port)
        var on: Int32 = 1
        // Each page goes out as it's written.
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = [
            "PUT \(mount) HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
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
