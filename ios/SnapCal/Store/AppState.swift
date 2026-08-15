import SwiftUI
import Observation

@Observable
@MainActor
final class AppState {
    enum Phase { case launching, welcome, onboarding, ready }

    var phase: Phase = .launching

    /// Browsing without an account.
    ///
    /// Guest mode is a *client* state only. No token is issued, so every
    /// protected endpoint still returns 401 exactly as it would to any
    /// unauthenticated caller — nothing about the backend's auth is relaxed.
    /// The app simply shows sample content and prompts for sign-up at the
    /// first action that needs a server round-trip.
    private(set) var isGuest = false

    /// Set when a guest taps something that needs an account; drives the sheet.
    var guestPromptFeature: String?
    var dashboard: Dashboard = .placeholder
    var quota: Quota?
    var isRefreshing = false
    var banner: String?

    /// Optimistic local copy so the ring animates the instant a meal is saved,
    /// before the dashboard round-trip lands.
    func applyLocally(_ items: [FoodItem], slot: MealSlot) {
        let cal = items.reduce(0) { $0 + $1.calories }
        let p = items.reduce(0) { $0 + $1.protein }
        let c = items.reduce(0) { $0 + $1.carbs }
        let f = items.reduce(0) { $0 + $1.fat }

        withAnimation(Theme.snap) {
            dashboard.consumed.calories += cal
            dashboard.consumed.protein_g += p
            dashboard.consumed.carbs_g += c
            dashboard.consumed.fat_g += f
            dashboard.remaining.calories -= cal
            dashboard.remaining.protein_g -= p
            dashboard.remaining.carbs_g -= c
            dashboard.remaining.fat_g -= f
        }
    }

    func enterGuestMode() {
        isGuest = true
        dashboard = .guestSample
        phase = .ready
    }

    func leaveGuestMode() {
        isGuest = false
        guestPromptFeature = nil
    }

    /// Call before any action that needs the server. Returns false and raises
    /// the sign-up prompt when the user is browsing as a guest.
    @discardableResult
    func requireAccount(for feature: String) -> Bool {
        guard isGuest else { return true }
        Haptics.warn()
        guestPromptFeature = feature
        return false
    }

    func bootstrap() async {
        guard await APIClient.shared.token != nil else { phase = .welcome; return }
        do {
            dashboard = try await APIClient.shared.dashboard()
            quota = try? await APIClient.shared.usage()
            phase = .ready
        } catch APIError.unauthorized {
            await APIClient.shared.setToken(nil)
            phase = .welcome
        } catch {
            // Offline launch still shows the shell; the ring fills when we reconnect.
            phase = .ready
            banner = error.localizedDescription
        }
    }

    func refresh() async {
        // A guest has no token; refreshing would just 401 in a loop.
        guard !isGuest else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let d = try? await APIClient.shared.dashboard() {
            withAnimation(Theme.snap) { dashboard = d }
        }
        quota = try? await APIClient.shared.usage()
    }

    func signOut() async {
        await APIClient.shared.setToken(nil)
        isGuest = false
        guestPromptFeature = nil
        dashboard = .placeholder
        phase = .welcome
    }
}
