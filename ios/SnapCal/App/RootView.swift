import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            switch app.phase {
            case .launching:
                ProgressView().controlSize(.large)
            case .welcome:
                WelcomeView()
                    .transition(.opacity)
            case .onboarding:
                OnboardingFlow()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .ready:
                MainTabs()
                    .transition(.opacity)
            }
        }
        .animation(Theme.snap, value: app.phase)
    }
}

struct MainTabs: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(NotificationService.self) private var notifications

    @State private var tab = 0

    var body: some View {
        @Bindable var entitlements = entitlements

        TabView(selection: $tab) {
            Tab("Home", systemImage: "circle.circle.fill", value: 0) { DashboardView() }
            Tab("Coach", systemImage: "bubble.left.and.text.bubble.right", value: 1) { CoachView() }
            Tab("Meals", systemImage: "calendar", value: 2) { MealPlannerView() }
            Tab("Diary", systemImage: "list.bullet", value: 3) { DiaryView() }
            Tab("Progress", systemImage: "chart.xyaxis.line", value: 4) { ProgressHubView() }
            Tab("Settings", systemImage: "gearshape", value: 5) { SettingsView() }
        }
        // One paywall host for the whole app: any screen can request it by
        // setting a context, and the copy follows the blocked feature.
        .sheet(item: $entitlements.pendingPaywall) { context in
            PaywallView(context: context, source: context.rawValue)
        }
        .onChange(of: notifications.pendingDeeplink) { _, link in
            guard let link else { return }
            route(link)
            notifications.pendingDeeplink = nil
        }
    }

    /// Deep links resolve after auth because MainTabs only exists once signed
    /// in — an unauthenticated tap lands on Welcome and the link is replayed.
    private func route(_ link: String) {
        switch link {
        case let l where l.contains("coach"):   tab = 1
        case let l where l.contains("meal"):    tab = 2
        case let l where l.contains("scan"):    tab = 0
        case let l where l.contains("premium"):
            entitlements.present(.general, source: "notification")
        default:                                tab = 0
        }
    }
}

extension PaywallContext: Identifiable {
    var id: String { rawValue }
}
