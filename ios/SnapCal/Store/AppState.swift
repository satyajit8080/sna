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

    /// Namespaces the on-device cache so two accounts on one device stay
    /// separate.
    private var cacheKey = "anonymous"

    /// Set when a guest taps something that needs an account; drives the sheet.
    var guestPromptFeature: String?

    /// Items with a save in flight. A double tap on "Add to Diary" would
    /// otherwise POST twice and double-count the calories — the optimistic
    /// ring update makes the second tap look plausible.
    private var inFlightLogs = Set<String>()
    var dashboard: Dashboard = .placeholder
    var quota: Quota?
    var isRefreshing = false
    var banner: String?

    /// Profile bits the Home header needs. Cached from /profile so the greeting
    /// does not wait on a second request.
    var profileFirstName = ""
    var startWeightKg: Double?

    /// One-line coach line for the Home insight card. Reuses the free
    /// suggestion endpoint's reason text — no extra AI call.
    var coachInsight: String?

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
        DashboardCache.save(dashboard, userKey: cacheKey)
    }

    func enterGuestMode() {
        isGuest = true
        dashboard = .guest
        profileFirstName = ""
        coachInsight = "Sign up to start tracking — your first scan takes a few seconds."
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

    /// Logs an already-priced item (coach suggestion or planned meal).
    ///
    /// Macros are known, so this never touches the AI. The ring moves
    /// immediately from the optimistic update and reconciles on refresh.
    @discardableResult
    func logKnownItem(_ item: FoodItem, slot: MealSlot, method: String = "manual") async -> Bool {
        guard requireAccount(for: "save meals") else { return false }

        // Keyed on identity, portion and slot: logging the same food twice
        // deliberately is fine, but only once the first save has landed.
        let key = "\(item.foodId ?? item.name)|\(slot.rawValue)|\(Int(item.grams))"
        guard !inFlightLogs.contains(key) else { return false }
        inFlightLogs.insert(key)
        defer { inFlightLogs.remove(key) }

        applyLocally([item], slot: slot)
        do {
            _ = try await APIClient.shared.saveMeal(
                slot: slot, method: method, items: [item], confidence: nil)
            await refresh()
            Haptics.success()
            return true
        } catch {
            // Roll the optimistic update back rather than leaving the ring wrong.
            await refresh()
            banner = (error as? APIError)?.errorDescription ?? "Couldn't save that."
            return false
        }
    }

    func bootstrap() async {
        guard let token = await APIClient.shared.token else { phase = .welcome; return }
        cacheKey = DashboardCache.userKey(for: token)

        // Show the last known numbers immediately so a cold launch never looks
        // like the history was wiped. Replaced as soon as the server answers.
        if let cached = DashboardCache.load(userKey: cacheKey, today: DashboardCache.localToday) {
            dashboard = cached
        }

        do {
            let fresh = try await APIClient.shared.dashboard()
            dashboard = fresh
            DashboardCache.save(fresh, userKey: cacheKey)
            quota = try? await APIClient.shared.usage()
            await loadProfileBits()
            coachInsight = try? await APIClient.shared.coachInsight()
            phase = .ready
        } catch APIError.unauthorized {
            // Only a genuine auth failure clears state.
            await APIClient.shared.setToken(nil)
            DashboardCache.clear()
            dashboard = .placeholder
            phase = .welcome
        } catch {
            // Offline or a server blip: keep whatever we already had rather
            // than replacing real history with zeros.
            phase = .ready
            banner = "Couldn't reach SnapCal. Showing your last saved day."
        }
    }

    /// Name and start weight for the header. Cheap and rarely changes.
    private func loadProfileBits() async {
        guard let profile = try? await APIClient.shared.profile() else { return }
        profileFirstName = profile.name.split(separator: " ").first.map(String.init) ?? ""
        startWeightKg = profile.startWeightKg
    }

    func refresh() async {
        // A guest has no token; refreshing would just 401 in a loop.
        guard !isGuest else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // A failed refresh leaves the previous values in place. Overwriting
        // with an empty dashboard is what made data look lost.
        if let d = try? await APIClient.shared.dashboard() {
            withAnimation(Theme.snap) { dashboard = d }
            DashboardCache.save(d, userKey: cacheKey)
            banner = nil
        }
        quota = try? await APIClient.shared.usage()
        coachInsight = try? await APIClient.shared.coachInsight()
    }

    func signOut() async {
        await APIClient.shared.setToken(nil)
        // Nothing from this account may survive to the next one on this device.
        DashboardCache.clear()
        isGuest = false
        guestPromptFeature = nil
        cacheKey = "anonymous"
        profileFirstName = ""
        startWeightKg = nil
        coachInsight = nil
        quota = nil
        dashboard = .placeholder
        phase = .welcome
    }
}
