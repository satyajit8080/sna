import SwiftUI

/// The four selectable destinations.
///
/// Add is deliberately absent: it opens a sheet rather than selecting a tab, so
/// modelling it as one would leave an unreachable case that every switch has to
/// pretend to handle.
enum AppTab: Hashable {
    case home, scan, coach, more
}

/// Deep link destinations. Every notification resolves to one of these.
@Observable
@MainActor
final class Router {
    var tab: AppTab = .home
    var isPresentingAddBP = false
    /// History no longer has a tab, so a deep link presents it instead.
    var isPresentingHistory = false

    func handle(_ url: URL) {
        switch url.host() {
        case "medication": tab = .more
        case "measurement", "bp": isPresentingAddBP = true
        case "drift", "history": isPresentingHistory = true
        case "scan": tab = .scan
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

        return ZStack(alignment: .bottom) {
            Brand.background.ignoresSafeArea()

            // The selected screen is shown directly rather than through TabView,
            // so the custom bar can float above it with the raised Add button.
            Group {
                switch router.tab {
                case .home: NavigationStack { HomeView() }
                case .scan: NavigationStack { ScanHubView() }
                case .coach: NavigationStack { CoachView() }
                case .more: NavigationStack { MoreView() }
                }
            }
            // Room for the bar, so content is never hidden behind it.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 70) }

            BrandTabBar(selection: $router.tab) { isPresentingAddMenu = true }
        }
        .sheet(isPresented: $isPresentingAddMenu) { AddMenuView() }
        .sheet(isPresented: $router.isPresentingAddBP) { AddBPView() }
        .sheet(isPresented: $router.isPresentingHistory) {
            NavigationStack { UnifiedHistoryView() }
        }
        .onOpenURL { router.handle($0) }
        .environment(router)
    }
}

/// The tab bar from the Figma design.
///
/// SwiftUI's `TabView` cannot produce this: the Add button sits above the bar,
/// overlapping it, and opens a sheet instead of selecting a tab. So the bar is
/// drawn directly and the selected screen is switched by hand.
struct BrandTabBar: View {
    @Binding var selection: AppTab
    let onAdd: () -> Void

    private let items: [(tab: AppTab, title: String, symbol: String)] = [
        (.home, "Home", "house.fill"),
        (.scan, "Scan", "viewfinder"),
        (.coach, "Ai Coach", "bubble.left.and.text.bubble.right.fill"),
        (.more, "More", "square.grid.2x2.fill"),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                item(items[0])
                item(items[1])
                // Space for the raised button, which overlaps the bar.
                Color.clear.frame(maxWidth: .infinity)
                item(items[2])
                item(items[3])
            }
            .frame(height: 70)
            .background(Brand.background)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Brand.cardStroke)
                    .frame(height: 1)
            }

            addButton
                .offset(y: -29)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func item(_ entry: (tab: AppTab, title: String, symbol: String)) -> some View {
        Button {
            selection = entry.tab
            Haptics.selection()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 19))
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selection == entry.tab ? Brand.accent : Brand.tabInactive)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selection == entry.tab ? [.isButton, .isSelected] : .isButton)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Circle()
                .fill(Brand.accent)
                .frame(width: 59, height: 59)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Brand.onAccent)
                }
                .shadow(color: Brand.accent.opacity(0.25), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a record")
    }
}
