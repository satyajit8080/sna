import SwiftData
import SwiftUI

/// First launch. Six steps, each one earning its place: the guideline choice in
/// particular is explained rather than buried, because it changes every label the
/// user will see afterwards.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Environment(\.modelContext) private var context

    @State private var step = 0
    @State private var name = ""
    @State private var selectedGuideline: BPGuidelineID = .accAha2017

    private let stepCount = 6

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step + 1), total: Double(stepCount))
                .tint(Theme.accent)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.lg)

            TabView(selection: $step) {
                welcome.tag(0)
                profile.tag(1)
                guidelineChoice.tag(2)
                guidelineExplainer.tag(3)
                healthPermission.tag(4)
                notificationPermission.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: step)
        }
        .background(Theme.background)
    }

    // MARK: - Steps

    private var welcome: some View {
        OnboardingPage(
            symbol: "heart.text.square.fill",
            title: "BP Coach",
            subtitle: "Measure. Understand. Improve.",
            body: """
            Record your blood pressure, see what your numbers are actually doing over \
            time, and walk into your next appointment prepared.

            Everything stays on this device.
            """,
            primaryTitle: "Get started",
            primaryAction: { step = 1 }
        )
    }

    private var profile: some View {
        OnboardingPage(
            symbol: "person.crop.circle.fill",
            title: "Who is this for?",
            subtitle: "You can add family profiles later",
            body: "This profile is the device owner, and it is the only one that can connect to Apple Health.",
            primaryTitle: "Continue",
            primaryAction: {
                app.renameOwner(to: name.isEmpty ? "Me" : name)
                step = 2
            }
        ) {
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .textContentType(.givenName)
                .padding(.horizontal, Theme.Spacing.xl)
        }
    }

    private var guidelineChoice: some View {
        OnboardingPage(
            symbol: "list.clipboard.fill",
            title: "Which guideline?",
            subtitle: "This decides how your readings are labelled",
            body: "",
            primaryTitle: "Continue",
            primaryAction: {
                guidelines.select(selectedGuideline)
                step = 3
            }
        ) {
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(BPGuidelineID.allCases, id: \.self) { id in
                    Button {
                        selectedGuideline = id
                        Haptics.selection()
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            Image(systemName: selectedGuideline == id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id.displayName).font(.headline)
                                Text(id.summary)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(Theme.Spacing.md)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var guidelineExplainer: some View {
        OnboardingPage(
            symbol: "info.circle.fill",
            title: "Why it matters",
            subtitle: selectedGuideline.displayName,
            body: """
            Guidelines disagree. A reading of 135/85 is Stage 1 under ACC/AHA and only \
            High normal under ESC/ESH — the same numbers, different labels.

            BP Coach shows you the labels from the guideline you pick. Changing it later \
            never alters your stored readings, only how they are described.

            If your doctor follows a particular guideline, choose that one.
            """,
            primaryTitle: "Got it",
            primaryAction: { step = 4 }
        )
    }

    private var healthPermission: some View {
        OnboardingPage(
            symbol: "heart.fill",
            title: "Apple Health",
            subtitle: "Optional, and it works both ways",
            body: """
            BP Coach can read blood pressure, heart rate, sleep, steps and weight from \
            Health, and save readings you enter back to it.

            None of this leaves your device. BP Coach has no server and no account.
            """,
            primaryTitle: "Connect Health",
            primaryAction: {
                Task {
                    try? await app.health.requestAuthorization(for: app.activeProfile)
                    step = 5
                }
            },
            secondaryTitle: "Not now",
            secondaryAction: { step = 5 }
        )
    }

    private var notificationPermission: some View {
        OnboardingPage(
            symbol: "bell.badge.fill",
            title: "Reminders",
            subtitle: "You control every category",
            body: """
            Medication doses, measurement nudges, appointment reminders, and an alert if \
            your monthly average drifts upward.

            Each one can be turned off independently in Settings.
            """,
            primaryTitle: "Enable reminders",
            primaryAction: {
                Task {
                    await NotificationEngine.shared.requestAuthorization()
                    app.completeOnboarding()
                }
            },
            secondaryTitle: "Skip",
            secondaryAction: { app.completeOnboarding() }
        )
    }
}

/// Shared onboarding page layout.
struct OnboardingPage<Extra: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let body: String
    let primaryTitle: String
    let primaryAction: () -> Void
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    @ViewBuilder var extra: Extra

    init(
        symbol: String,
        title: String,
        subtitle: String,
        body: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
        self.extra = extra()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                Spacer(minLength: Theme.Spacing.xl)

                Image(systemName: symbol)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Theme.accent)

                VStack(spacing: Theme.Spacing.xs) {
                    Text(title).font(.largeTitle.weight(.bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .multilineTextAlignment(.center)

                if !body.isEmpty {
                    Text(body)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Spacing.xl)
                }

                extra

                Spacer(minLength: Theme.Spacing.lg)

                VStack(spacing: Theme.Spacing.sm) {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Theme.accent)

                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
