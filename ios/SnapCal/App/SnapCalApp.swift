import SwiftUI

@main
struct SnapCalApp: App {
    @State private var app = AppState()
    @State private var store = SubscriptionManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(store)
                .tint(Theme.accent)
                .task {
                    await store.load()
                    await app.bootstrap()
                }
        }
    }
}
