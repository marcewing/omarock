import Foundation

/// The Icecast config the bridge runs its Icecast with: the stream on the tailnet address
/// and loopback only, near-live limits, and passwords made on first launch.
///
/// It's rewritten at every launch, so it follows the tailnet address, unless someone
/// took the marker line out to keep their own edits.
enum IcecastConfig {
    static let marker = "<!-- Written by the omarock bridge at each launch. Delete this line to keep your own edits. -->"

    /// Writes icecast.xml for `host` (and the passwords it needs), unless it's the user's own.
    static func prepare(host: String, icecast: String) throws {
        let source = try Secrets.sourcePassword()
        let admin = try Secrets.adminPassword()
        let relay = try Secrets.relayPassword()
        if let existing = try? String(contentsOf: Paths.icecastConfig, encoding: .utf8), !existing.contains(marker) {
            return
        }
        try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        // Homebrew's web and admin pages: {prefix}/bin/icecast → {prefix}/share/icecast.
        let share = URL(fileURLWithPath: icecast).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/icecast").path
        let xml = """
        <icecast>
            \(marker)
            <location>omarock bridge</location>
            <admin>omarock bridge</admin>
            <hostname>\(escape(host))</hostname>

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

            <!-- Tailnet and loopback only; never a wildcard bind. -->
            <listen-socket>
                <port>8000</port>
                <bind-address>\(escape(host))</bind-address>
            </listen-socket>
            <listen-socket>
                <port>8000</port>
                <bind-address>127.0.0.1</bind-address>
            </listen-socket>

            <mount type="normal">
                <mount-name>/omarock.ogg</mount-name>
                <hidden>1</hidden>
                <public>0</public>
                <burst-size>0</burst-size>
                <stream-name>omarock</stream-name>
            </mount>

            <fileserve>1</fileserve>

            <paths>
                <basedir>\(escape(Paths.support.path))</basedir>
                <logdir>\(escape(Paths.logs.path))</logdir>
                <webroot>\(escape(share))/web</webroot>
                <adminroot>\(escape(share))/admin</adminroot>
                <pidfile>\(escape(Paths.support.appendingPathComponent("icecast.pid").path))</pidfile>
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
        try Secrets.writePrivate(xml, to: Paths.icecastConfig)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
