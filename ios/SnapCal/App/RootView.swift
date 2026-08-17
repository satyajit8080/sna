import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            switch app.phase {
            case .launching:
                ProgressView().controlSize(.large)
            case .welcome:
                WelcomeView().transition(.opacity)
            case .onboarding:
                OnboardingFlow()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .healthOnboarding:
                HealthOnboardingView { app.completeHealthOnboarding() }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .ready:
                MainTabs().transition(.opacity)
            }
        }
        .animation(Theme.snap, value: app.phase)
    }
}

/// Four tabs, per the design: Home · Scan · AI Coach · Meal Plan.
///
/// Diary, Progress and Settings are reachable from Home — "View All" on
/// today's meals, "View Progress" on the streak card, and the profile button
/// in the header. Settings has to stay reachable in particular: account
/// deletion and subscription management live there and are App Store
/// requirements.
struct MainTabs: View {
    @Environment(AppState.self) private var app
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(NotificationService.self) private var notifications

    @State private var tab: Tab = .home
    @State private var scanRoute: LogRoute?
    @State private var keyboardVisible = false

    enum Tab: String, CaseIterable, Hashable {
        case home, scan, coach, meals

        var title: String {
            switch self {
            case .home: "Home"
            case .scan: "Scan"
            case .coach: "AI Coach"
            case .meals: "Meal Plan"
            }
        }

        var icon: String {
            switch self {
            case .home: "house.fill"
            case .scan: "camera.fill"
            case .coach: "sparkles"
            case .meals: "calendar"
            }
        }
    }

    var body: some View {
        @Bindable var entitlements = entitlements
        @Bindable var app = app

        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .home:  DashboardView()
                case .scan:  DashboardView()      // Scan presents modally; Home stays behind
                case .coach: CoachView()
                case .meals: MealPlannerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Hidden while typing: on a small screen the keyboard plus the bar
            // leaves almost no room for the conversation.
            if !keyboardVisible {
                SnapTabBar(selection: $tab) { selected in
                // Scan is an action, not a destination: tapping it opens the
                // camera and leaves the previous tab underneath.
                    guard selected == .scan else { return false }
                    Haptics.commit()
                    startScan()
                    return true
                }
                .transition(.move(edge: .bottom))
            }
        }
        .animation(Theme.quick, value: keyboardVisible)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .background(Theme.bg)
        .fullScreenCover(item: $scanRoute) { LogFlowView(route: $0) }
        .sheet(item: $entitlements.pendingPaywall) { context in
            PaywallView(context: context, source: context.rawValue)
        }
        .sheet(item: $app.guestPromptFeature) { feature in
            SignInPromptView(feature: feature)
                .presentationDetents([.height(420)])
        }
        .onChange(of: notifications.pendingDeeplink) { _, link in
            guard let link else { return }
            route(link)
            notifications.pendingDeeplink = nil
        }
    }

    private func startScan() {
        guard app.requireAccount(for: "save your meals") else { return }

        let scan = entitlements.entitlements.foodScan
        if !entitlements.isPro, scan.isExhausted {
            entitlements.present(.foodScan, source: "scan_tab")
            return
        }
        scanRoute = LogRoute(mode: .camera, slot: MealSlot.suggested())
    }

    private func route(_ link: String) {
        switch link {
        case let l where l.contains("coach"):   tab = .coach
        case let l where l.contains("meal"):    tab = .meals
        case let l where l.contains("scan"):    startScan()
        case let l where l.contains("premium"):
            entitlements.present(.general, source: "notification")
        default:                                tab = .home
        }
    }
}

/// Custom bar so the labels use the design's type and the Scan tab can act as
/// a button rather than a destination — neither is possible with `TabView`.
struct SnapTabBar: View {
    /// Content height excluding the safe-area inset. Screens with their own
    /// bottom-anchored UI reserve this so nothing hides behind the bar.
    static let height: CGFloat = 61

    @Binding var selection: MainTabs.Tab
    /// Return true to consume the tap without changing tabs.
    var onSelect: (MainTabs.Tab) -> Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTabs.Tab.allCases, id: \.self) { tab in
                Button {
                    if onSelect(tab) { return }
                    Haptics.tap()
                    withAnimation(Theme.quick) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(height: 24)
                        Text(tab.title)
                            .font(.caption_)
                    }
                    .foregroundStyle(selection == tab ? Theme.accent : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 11)
        .padding(.bottom, 6)
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
    }
}

extension PaywallContext: Identifiable {
    var id: String { rawValue }
}
