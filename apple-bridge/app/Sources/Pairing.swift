import Foundation
import Security

/// Pairing (apple-bridge/API.md): the Mac's installer opens a 6-digit code and shows it,
/// and omarock on the Omarchy machine trades it for the token. A code works once, for 10
/// minutes and 5 wrong tries; opening a new one replaces it. Neither the code nor the
/// token is logged.
@MainActor
final class Pairing {
    static let lifetime: TimeInterval = 600
    static let tries = 5

    private enum Claim {
        case paired
        case wrong(triesLeft: Int)
        case notOpen
    }

    private let token: String
    private var code: [UInt8]?
    private var expires = Date.distantPast
    private var triesLeft = 0
    /// How the last code closed (paired, expired, tries, cancelled), and who paired.
    private var closed: String?
    private var client: String?
    private var expiry: DispatchWorkItem?

    init(token: String) {
        self.token = token
    }

    /// /v1/pair/ROUTE: POST /pair from anywhere, without the token; opening, reading and
    /// closing a code from this Mac only (by the connection's address), with it. nil: not
    /// a pairing endpoint.
    func respond(to request: HTTPRequest, route: [String], authorized: Bool, client: String?) -> HTTPResponse? {
        switch (request.method, route) {
        case ("POST", []):
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let digits = (body?["code"] as? String)?.filter { $0.isASCII && $0.isNumber } ?? ""
            guard digits.count == 6 else { return .error(400, "A pairing code is 6 digits.") }
            switch claim(digits, client: client) {
            case .paired:
                return .json(200, ["token": token])
            case .wrong(let left) where left > 0:
                return .json(403, ["error": "That isn't the code the Mac shows.", "triesLeft": left])
            case .wrong:
                return .json(403, ["error": "That isn't the code the Mac shows, and that was the last try: run ./install pair on the Mac for a new one.",
                                   "triesLeft": 0])
            case .notOpen:
                return .error(409, "No pairing code is open on the Mac: run ./install pair there.")
            }
        case ("GET", []), ("POST", ["open"]), ("POST", ["close"]):
            guard request.fromLoopback else { return .error(403, "Pairing codes are opened on the Mac: run ./install pair there.") }
            guard authorized else { return .error(401, "Missing or wrong bearer token.") }
            switch route {
            case ["open"]: return .json(200, open())
            case ["close"]: cancel()
            default: break
            }
            return .json(200, state)
        default:
            return nil
        }
    }

    private func open() -> [String: Any] {
        let replacing = code != nil
        let digits = Self.randomCode()
        code = Array(digits.utf8)
        expires = Date().addingTimeInterval(Self.lifetime)
        triesLeft = Self.tries
        closed = nil
        client = nil
        expiry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close("expired") }
        expiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: item)
        Log.info("pairing: code opened\(replacing ? ", replacing the open one" : "") (\(Int(Self.lifetime / 60)) min, \(Self.tries) tries)")
        return ["code": digits, "expiresIn": Int(Self.lifetime), "tries": Self.tries]
    }

    private var state: [String: Any] {
        if code != nil {
            return ["open": true, "expiresIn": max(0, Int(expires.timeIntervalSinceNow.rounded(.up))), "triesLeft": triesLeft]
        }
        var state: [String: Any] = ["open": false]
        if let closed { state["closed"] = closed }
        if let client { state["client"] = client }
        return state
    }

    private func cancel() { if code != nil { close("cancelled") } }

    /// `digits` is 6 ASCII digits.
    private func claim(_ digits: String, client: String?) -> Claim {
        if code != nil, Date() >= expires { close("expired") }
        guard let code else { return .notOpen }
        let given = Array(digits.utf8)
        let same = given.count == code.count && zip(given, code).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        let who = client ?? "a machine that didn't say"
        if same {
            self.client = client
            Log.info("pairing: paired with \(who)")
            close("paired")
            return .paired
        }
        triesLeft -= 1
        Log.info("pairing: wrong code from \(who), \(triesLeft) \(triesLeft == 1 ? "try" : "tries") left")
        if triesLeft == 0 { close("tries") }
        return .wrong(triesLeft: triesLeft)
    }

    private func close(_ reason: String) {
        guard code != nil else { return }
        code = nil
        closed = reason
        expiry?.cancel()
        expiry = nil
        Log.info("pairing: code closed (\(reason))")
    }

    /// Uniform over 000000–999999: 32 random bits, drawing again above the largest
    /// multiple of a million.
    private static func randomCode() -> String {
        let limit = UInt32.max - UInt32.max % 1_000_000
        var value: UInt32
        repeat {
            value = 0
            let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        } while value >= limit
        return String(format: "%06u", value % 1_000_000)
    }
}
