import SwiftUI

enum AppTab: Hashable {
    case home, history, add, coach, more
}

/// Deep link destinations. Every notification resolves to one of these.
@Observable
@MainActor
final class Router {
    var tab: AppTab = .home
    var isPresentingAddBP = false

    func handle(_ url: URL) {
        switch url.host() {
        case "medication": tab = .more
        case "measurement", "bp": isPresentingAddBP = true
        case "drift", "history": tab = .history
        case "coach": tab = .coach
        default: tab = .home
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var router = Router()
    @State private var isPresentingAddMenu = false

    var body: some View {
        Group {
            if app.hasCompletedOnboarding {
                mainInterface
            } else {
                OnboardingFlow()
            }
        }
        .animation(.snappy, value: app.hasCompletedOnboarding)
    }

    private var mainInterface: some View {
        @Bindable var router = router

        return TabView(selection: $router.tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.history)

            // The centre tab opens the Add sheet rather than owning a screen.
            Color.clear
                .tabItem { Label("Add", systemImage: "plus.circle.fill") }
                .tag(AppTab.add)

            NavigationStack { CoachView() }
                .tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .tag(AppTab.coach)

            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.more)
        }
        .onChange(of: router.tab) { previous, new in
            if new == .add {
                router.tab = previous == .add ? .home : previous
                isPresentingAddMenu = true
            }
        }
        .sheet(isPresented: $isPresentingAddMenu) { AddMenuView() }
        .sheet(isPresented: $router.isPresentingAddBP) { AddBPView() }
        .onOpenURL { router.handle($0) }
        .environment(router)
    }
}
