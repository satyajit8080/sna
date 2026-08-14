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
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "circle.circle.fill", value: 0) { DashboardView() }
            Tab("Diary", systemImage: "list.bullet", value: 1) { DiaryView() }
            Tab("Progress", systemImage: "chart.xyaxis.line", value: 2) { ProgressHubView() }
            Tab("Settings", systemImage: "gearshape", value: 3) { SettingsView() }
        }
    }
}
