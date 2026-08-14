import SwiftUI

@main
struct SnapCalApp: App {
    @State private var app = AppState()
    @State private var store = SubscriptionManager()
    @State private var entitlements = EntitlementStore()
    @State private var notifications = NotificationService.shared
    @State private var health = HealthService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(store)
                .environment(entitlements)
                .environment(notifications)
                .environment(health)
                .tint(Theme.accent)
                .task {
                    await store.load()
                    await app.bootstrap()
                    await entitlements.refresh()
                    await notifications.loadPrefs()
                    // Rebuild schedules on every launch so a timezone change or
                    // a stale morning message can't survive.
                    await notifications.rescheduleAll()
                    // Activity is supplementary; a failure here never blocks launch.
                    await health.syncToday()
                }
                .onOpenURL { url in
                    notifications.pendingDeeplink = url.absoluteString
                }
        }
    }
}
