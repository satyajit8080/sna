import SwiftUI

@main
struct SnapCalApp: App {
    @Environment(\.scenePhase) private var scenePhase
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
                    if !app.isGuest { await entitlements.refresh() }
                    await notifications.loadPrefs()
                    // Rebuild schedules on every launch so a timezone change or
                    // a stale morning message can't survive.
                    await notifications.rescheduleAll()
                    // Activity is supplementary; a failure here never blocks launch.
                    await health.syncToday(force: true)
                    health.startObserving()
                    // A walk mid-session should move the ring without a manual pull.
                    health.onUpdate = { await app.refresh() }
                }
                .onOpenURL { url in
                    notifications.pendingDeeplink = url.absoluteString
                }
                .onChange(of: scenePhase) { _, phase in
                    // Steps move while the app is backgrounded. Re-sync on
                    // return so the calorie budget and the coach's view of
                    // "remaining" are current before the user reads them.
                    guard phase == .active, app.phase == .ready, !app.isGuest else { return }
                    Task {
                        await health.syncToday(force: true)
                        await app.refresh()
                    }
                }
        }
    }
}
