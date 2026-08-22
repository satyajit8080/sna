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
    /// Set when a notification asks the coach something specific.
    var pendingCoachQuestion: String?

    func handle(_ url: URL) {
        switch url.host() {
        case "medication": tab = .more
        case "measurement", "bp": isPresentingAddBP = true
        case "drift", "history": isPresentingHistory = true
        case "scan": tab = .scan
        case "coach":
            tab = .coach
            // Carried through so the coach can open with the question the
            // notification was about.
            if let question = url.queryValue(for: "question") { pendingCoachQuestion = question }
        default: tab = .home
        }
    }
}

extension URL {
    /// A query parameter, or nil. Used to carry a notification's question into
    /// the coach.
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var router = Router()
    @State private var isPresentingAddMenu = false

    var body: some View {
        @Bindable var router = router

        return Group {
            if app.hasCompletedOnboarding {
                mainInterface(Bindable(router))
            } else {
                OnboardingFlow()
            }
        }
        .animation(.snappy, value: app.hasCompletedOnboarding)
    }

    /// The main interface.
    ///
    /// Taken as a parameter rather than read from a computed property: declaring
    /// `@Bindable` inside a computed `var` does not participate in the view's
    /// dependency tracking, so tab changes did not reliably invalidate the body
    /// and tapping a tab appeared to do nothing.
    ///
    /// The tab bar is a VStack sibling, not an overlay or a safe-area inset.
    /// Both of those left the bar covering the coach composer: whether a bottom
    /// inset reaches a screen inside a NavigationStack turned out not to be
    /// something worth relying on. A VStack cannot overlap its children — the
    /// screen gets the height that is left, and that is the end of it.
    ///
    /// `.id` gives each tab its own NavigationStack. Without it SwiftUI reuses
    /// one across all four and a screen pushed in one tab reappears in another.
    @ViewBuilder
    private func mainInterface(_ router: Bindable<Router>) -> some View {
        VStack(spacing: 0) {
            Group {
                switch router.wrappedValue.tab {
                case .home: NavigationStack { HomeView() }
                case .scan: NavigationStack { ScanHubView() }
                case .coach: NavigationStack { CoachView() }
                case .more: NavigationStack { MoreView() }
                }
            }
            .id(router.wrappedValue.tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Clears the raised centre button, which overhangs the bar and
            // would otherwise sit on top of whatever is directly above it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: BrandTabBar.contentClearance)
            }

            BrandTabBar(selection: router.tab, onAdd: { isPresentingAddMenu = true })
        }
        .background(Brand.background.ignoresSafeArea())
        .sheet(isPresented: $isPresentingAddMenu) { AddMenuView() }
        .sheet(isPresented: router.isPresentingAddBP) { AddBPView() }
        .sheet(isPresented: router.isPresentingHistory) {
            NavigationStack { UnifiedHistoryView() }
        }
        .onOpenURL { router.wrappedValue.handle($0) }
        .environment(router.wrappedValue)
    }
}

/// The tab bar from the Figma design.
///
/// Order is Home · Scan · [Ai Coach] · Add · More, with the coach raised into a
/// circle above the bar. `TabView` cannot do this — the raised button overlaps
/// the bar — so the bar is drawn directly and the screen switched by hand.
///
/// Add is a normal bar item that opens a sheet rather than selecting a tab,
/// which is why it is not part of `AppTab`.
struct BrandTabBar: View {
    /// How far the centre button rises above the bar.
    ///
    /// The design reduced this: the button was a 59pt circle raised 29pt into a
    /// 97pt bar, and is now a 44pt circle raised 8pt into a 78pt one. It sits
    /// almost flush, with its icon on the same baseline as the other tabs.
    static let raisedOverhang: CGFloat = 8
    /// Diameter of the raised centre button.
    static let raisedDiameter: CGFloat = 44
    /// The bar's own height.
    static let barHeight: CGFloat = 70
    /// What content must leave clear above the bar.
    ///
    /// The overhang plus breathing room — with exactly the overhang the button
    /// touches whatever sits above it, which reads as a clipping bug.
    static let contentClearance: CGFloat = raisedOverhang + 12

    @Binding var selection: AppTab
    let onAdd: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                item(.home, "Home", "house.fill")
                item(.scan, "Scan", "viewfinder")

                // The coach's label sits in the bar; its icon is the raised
                // circle above, so only the label is drawn here.
                VStack(spacing: 7) {
                    Color.clear.frame(height: 21)
                    Text("Ai Coach")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == .coach ? Brand.accent : Brand.tabInactive)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = .coach
                    Haptics.selection()
                }
                .accessibilityHidden(true)

                addItem
                item(.more, "More", "square.grid.2x2.fill")
            }
            .frame(height: Self.barHeight)
            .background(Brand.background)
            .overlay(alignment: .top) {
                Rectangle().fill(Brand.cardStroke).frame(height: 1)
            }

            coachButton.offset(y: -Self.raisedOverhang)
        }
        // Room for the overhang is reserved by the caller, so the bar's own
        // frame is just the bar. No background on this outer stack: the bar
        // strip is already opaque, and painting here would put a block behind
        // the raised button instead of letting it float over the content.
        //
        // As the last child of a VStack the bar sits on the home indicator, so
        // its background extends down into that area while its content does not.
        .background(
            Brand.background.ignoresSafeArea(edges: .bottom)
        )
    }

    private func item(_ tab: AppTab, _ title: String, _ symbol: String) -> some View {
        Button {
            selection = tab
            Haptics.selection()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selection == tab ? Brand.accent : Brand.tabInactive)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
    }

    /// Opens the Add sheet. Never a selected tab.
    private var addItem: some View {
        Button(action: onAdd) {
            VStack(spacing: 7) {
                Image(systemName: "plus.circle").font(.system(size: 19))
                Text("Add").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Brand.tabInactive)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a record")
    }

    private var coachButton: some View {
        Button {
            selection = .coach
            Haptics.selection()
        } label: {
            Circle()
                .fill(Brand.accent)
                .frame(width: Self.raisedDiameter, height: Self.raisedDiameter)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Brand.onAccent)
                }
                // Softer now that the button sits close to the bar; the old
                // glow suited a circle floating well clear of it.
                .shadow(color: Brand.accent.opacity(0.25), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ai Coach")
        .accessibilityAddTraits(selection == .coach ? [.isButton, .isSelected] : .isButton)
    }
}
