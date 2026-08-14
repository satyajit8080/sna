import SwiftUI
import Observation

/// Single source of entitlement truth on the client — and it is only a cache of
/// the server's answer. Nothing here decides access; it decides what to render.
@Observable
@MainActor
final class EntitlementStore {
    private(set) var entitlements: Entitlements = .free
    private(set) var isLoading = false

    /// Set when the backend refuses a request; drives which paywall opens.
    var pendingPaywall: PaywallContext?

    var isPro: Bool { entitlements.isPro }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        if let fresh = try? await APIClient.shared.entitlements() {
            withAnimation(Theme.snap) { entitlements = fresh }
        }
    }

    /// Applies the copy the backend returned with a 402 and opens the paywall.
    func handle(_ error: Error, source: String) -> Bool {
        guard case APIError.premiumRequired(let info) = error else { return false }
        Analytics.track(.freeLimitReached, ["feature": info.feature, "source": source])
        pendingPaywall = info.context
        // Capped and preference-gated inside the service; never for subscribers.
        NotificationService.shared.scheduleConversionNudge(context: info.context, isPro: isPro)
        Task { await refresh() }
        return true
    }

    func present(_ context: PaywallContext, source: String) {
        Analytics.track(.paywallViewed, ["context": context.rawValue, "source": source])
        pendingPaywall = context
    }

    /// "1 free scan remaining" nudges land after value, not before it.
    func warningAfterUse(of feature: FeatureUsage) -> String? {
        guard !isPro, !feature.isUnlimited, let left = feature.remaining else { return nil }
        return left == 1 ? feature.badge(noun: "scan") : nil
    }
}
