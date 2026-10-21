import Foundation
import MusicKit

/// What the bridge knows about its MusicKit access. Reading it never prompts; asking
/// for authorization is a separate, deliberate step (it shows a dialog on the Mac).
final class MusicStatus {
    private(set) var canPlayCatalog = false
    private(set) var storefront: String?

    var authorization: MusicAuthorization.Status { MusicAuthorization.currentStatus }
    var authorized: Bool { authorization == .authorized }

    var authorizationName: String {
        switch authorization {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Refreshes the subscription and storefront. Only asks Apple once authorized: before
    /// that (or without a MusicKit-enabled App ID) these calls just fail.
    func refresh() {
        guard authorized else {
            canPlayCatalog = false
            storefront = nil
            return
        }
        Task {
            let subscription = try? await MusicSubscription.current
            let country = try? await MusicDataRequest.currentCountryCode
            await MainActor.run {
                canPlayCatalog = subscription?.canPlayCatalogContent ?? false
                storefront = country
            }
        }
    }
}
