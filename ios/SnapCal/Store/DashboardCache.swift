import Foundation

/// Last-known dashboard, persisted per user.
///
/// Without this, a cold launch on a slow or failed network reset the UI to a
/// zeroed placeholder — which reads as "all my history is gone". The cache is
/// only ever a *display* fallback: the server remains the source of truth, and
/// the cache is replaced the moment a real response arrives.
///
/// Keyed by user id so a second account on the same device can never see the
/// first account's numbers.
enum DashboardCache {
    private static let key = "dashboard.cache.v1"

    private struct Envelope: Codable {
        let userKey: String
        let date: String
        let dashboard: Dashboard
        let savedAt: Date
    }

    /// Stable per-user key derived from the auth token — no PII stored.
    static func userKey(for token: String?) -> String {
        guard let token, !token.isEmpty else { return "anonymous" }
        return String(token.suffix(24))
    }

    static func save(_ dashboard: Dashboard, userKey: String) {
        let envelope = Envelope(userKey: userKey, date: dashboard.date,
                                dashboard: dashboard, savedAt: .now)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Returns the cached dashboard only when it belongs to this user *and*
    /// this local day. Yesterday's totals must never be shown as today's.
    static func load(userKey: String, today: String) -> Dashboard? {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.userKey == userKey
        else { return nil }

        guard envelope.date == today else { return nil }
        return envelope.dashboard
    }

    /// Called on sign-out and account deletion so nothing survives to the next
    /// account on this device.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// The device's local day, matching the backend's day boundary.
    static var localToday: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: .now)
    }
}
