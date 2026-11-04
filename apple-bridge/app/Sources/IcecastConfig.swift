import Foundation

/// The Icecast config the bridge runs its Icecast with: the stream on every address (or
/// listenHost and loopback), at a mount only token holders can name, near-live limits, and
/// passwords made on first launch. Its web root is an empty folder, so port 8000 serves
/// the mount and nothing else (the admin pages need the admin password).
///
/// It's rewritten at every launch, so it follows the token and listenHost, unless someone
/// took the marker line out to keep their own edits.
enum IcecastConfig {
    static let marker = "<!-- Written by the omarock bridge at each launch. Delete this line to keep your own edits. -->"

    /// Writes icecast.xml (and the passwords it needs), unless it's the user's own. An
    /// unchanged file is left alone, so its date says when it last changed (StreamService
    /// restarts an Icecast older than that).
    static func prepare(listenHost: String?, icecast: String) throws {
        let source = try Secrets.sourcePassword()
        let admin = try Secrets.adminPassword()
        let relay = try Secrets.relayPassword()
        let mount = try Secrets.streamMount()
        let existing = try? String(contentsOf: Paths.icecastConfig, encoding: .utf8)
        if let existing, !existing.contains(marker) { return }
        try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.icecastWeb, withIntermediateDirectories: true)
        // Homebrew's admin pages: {prefix}/bin/icecast → {prefix}/share/icecast.
        let share = URL(fileURLWithPath: icecast).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/icecast").path
        // Every address: no bind-address gives one dual-stack socket, IPv4 and IPv6.
        let sockets = (listenHost.map { [$0, "127.0.0.1"] } ?? [nil]).map { host in
            """
                <listen-socket>
                    <port>8000</port>\(host.map { "\n        <bind-address>\(escape($0))</bind-address>" } ?? "")
                </listen-socket>
            """
        }.joined(separator: "\n")
        let xml = """
        <icecast>
            \(marker)
            <location>omarock bridge</location>
            <admin>omarock bridge</admin>
            <hostname>\(escape(listenHost ?? LocalName.bonjour() ?? "localhost"))</hostname>

            <limits>
                <clients>8</clients>
                <sources>2</sources>
                <!-- ~4 s of FLAC: enough slack for a hiccup, small enough to stay near-live -->
                <queue-size>524288</queue-size>
                <client-timeout>30</client-timeout>
                <header-timeout>15</header-timeout>
                <source-timeout>10</source-timeout>
                <burst-on-connect>1</burst-on-connect>
                <!-- no burst: a byte-sized burst of near-silent FLAC can be tens of seconds of lag -->
                <burst-size>0</burst-size>
            </limits>

            <authentication>
                <source-password>\(source)</source-password>
                <relay-password>\(relay)</relay-password>
                <admin-user>admin</admin-user>
                <admin-password>\(admin)</admin-password>
            </authentication>

            <!-- Every address, unless config.json's listenHost: plain HTTP, so a trusted network. -->
        \(sockets)

            <mount type="normal">
                <mount-name>\(mount)</mount-name>
                <hidden>1</hidden>
                <public>0</public>
                <burst-size>0</burst-size>
                <stream-name>omarock</stream-name>
            </mount>

            <fileserve>1</fileserve>

            <paths>
                <basedir>\(escape(Paths.support.path))</basedir>
                <logdir>\(escape(Paths.logs.path))</logdir>
                <webroot>\(escape(Paths.icecastWeb.path))</webroot>
                <adminroot>\(escape(share))/admin</adminroot>
                <pidfile>\(escape(Paths.icecastPid.path))</pidfile>
            </paths>

            <logging>
                <accesslog>access.log</accesslog>
                <errorlog>error.log</errorlog>
                <loglevel>3</loglevel>
                <logsize>10000</logsize>
                <logarchive>0</logarchive>
            </logging>

            <security>
                <chroot>0</chroot>
            </security>
        </icecast>

        """
        guard xml != existing else { return }
        try Secrets.writePrivate(xml, to: Paths.icecastConfig)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
