import SwiftUI
import Observation

@Observable
@MainActor
final class AppState {
    enum Phase { case launching, welcome, onboarding, ready }

    var phase: Phase = .launching
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
        isRefreshing = true
        defer { isRefreshing = false }
        if let d = try? await APIClient.shared.dashboard() {
            withAnimation(Theme.snap) { dashboard = d }
        }
        quota = try? await APIClient.shared.usage()
    }

    func signOut() async {
        await APIClient.shared.setToken(nil)
        dashboard = .placeholder
        phase = .welcome
    }
}
