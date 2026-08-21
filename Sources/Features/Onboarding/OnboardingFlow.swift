import SwiftData
import SwiftUI

/// First launch, implemented from the Figma design.
///
/// Five steps, matching the five-segment progress indicator in the design. The
/// name field from the earlier version is gone — the profile defaults to "Me"
/// and is editable in Settings → Profiles, which keeps first run shorter and
/// matches the design's step count.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines

    @State private var step = 0
    @State private var selectedGuideline: BPGuidelineID = .accAha2017
    @State private var healthError: String?
    @State private var ownerName = ""

    /// The categories BP Coach asks Health for, named so the user knows exactly
    /// what the permission sheet will cover.
    private let healthCategories: [(String, String)] = [
        ("Blood pressure", "heart.text.square.fill"),
        ("Heart rate", "waveform.path.ecg"),
        ("Steps and activity", "figure.walk"),
        ("Sleep", "bed.double.fill"),
        ("Weight", "scalemass.fill"),
    ]

    private let stepCount = 6

    var body: some View {
        ZStack {
            OnboardingTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingProgress(step: step, total: stepCount)
                    .padding(.horizontal, OnboardingTheme.Metric.horizontalPadding)
                    .padding(.top, 20)

                TabView(selection: $step) {
                    welcome.tag(0)
                    guidelineChoice.tag(1)
                    guidelineExplainer.tag(2)
                    whoIsThisFor.tag(3)
                    healthPermission.tag(4)
                    notificationPermission.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.snappy, value: step)
            }
        }
        // Onboarding is a dark composition; the accent glow does not survive a
        // light background.
        .preferredColorScheme(.dark)
    }

    // MARK: - 1 · Welcome

    private var welcome: some View {
        OnboardingScreen(
            logoSymbol: "waveform.path.ecg",
            header: {
                VStack(spacing: 6) {
                    Text("Welcome to")
                        .font(.system(size: 15))
                        .foregroundStyle(OnboardingTheme.accent)
                    (
                        Text("BP").foregroundStyle(OnboardingTheme.accent)
                            + Text(" Coach").foregroundStyle(OnboardingTheme.textPrimary)
                    )
                    .font(.system(size: 35, weight: .bold))
                    Text("Measure. Understand. Improve")
                        .font(.system(size: 15))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                }
            },
            content: {
                VStack(spacing: 15) {
                    OnboardingFeatureRow(symbol: "chart.line.uptrend.xyaxis") {
                        Text("Record your blood pressure, see what your numbers are actually doing, and walk into every appointment prepared.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OnboardingTheme.textSecondary)
                            .lineSpacing(2)
                    }

                    OnboardingFeatureRow(symbol: "lock.shield.fill") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Everything stays on this device.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OnboardingTheme.textSecondary)
                            Text("Your data. Your privacy. Your control.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(OnboardingTheme.accent)
                        }
                    }

                    SampleReadingCard().padding(.top, 21)
                }
            },
            primary: ("Get Started", { step = 1 }),
            secondary: ("I'll set this up later", { app.completeOnboarding() })
        )
    }

    // MARK: - 2 · Guideline choice

    private var guidelineChoice: some View {
        OnboardingScreen(
            logoSymbol: "list.clipboard.fill",
            header: {
                OnboardingTitle(
                    accented: "Which ",
                    plain: "Guideline?",
                    subtitle: "This decides how your readings are labelled"
                )
            },
            content: {
                VStack(spacing: 15) {
                    ForEach(BPGuidelineID.allCases, id: \.self) { id in
                        GuidelineOptionCard(
                            id: id,
                            region: region(for: id),
                            isSelected: selectedGuideline == id
                        ) {
                            selectedGuideline = id
                            Haptics.selection()
                        }
                    }
                }
            },
            primary: ("Continue", {
                guidelines.select(selectedGuideline)
                step = 2
            }),
            footnote: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingTheme.accent)
                    (
                        Text("You can change this later. Your readings will ")
                            .foregroundStyle(OnboardingTheme.textSecondary)
                            + Text("never").foregroundStyle(OnboardingTheme.accent)
                            + Text(" change.").foregroundStyle(OnboardingTheme.textSecondary)
                    )
                    .font(.system(size: 14, weight: .medium))
                }
            }
        )
    }

    private func region(for id: BPGuidelineID) -> String? {
        switch id {
        case .accAha2017: "United States"
        case .escEsh2023: "Europe"
        case .custom: nil
        }
    }

    // MARK: - 3 · Why it matters

    private var guidelineExplainer: some View {
        OnboardingScreen(
            logoSymbol: "list.clipboard.fill",
            header: {
                OnboardingTitle(
                    accented: "Why ",
                    plain: "it matters",
                    subtitle: guidelines.active.displayName
                )
            },
            content: {
                VStack(alignment: .leading, spacing: 14) {
                    Text(explainerText)
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: OnboardingTheme.Metric.cardRadius, style: .continuous)
                        .strokeBorder(OnboardingTheme.cardStroke, lineWidth: 1)
                }
            },
            primary: ("Got It", { step = 3 })
        )
    }

    /// Thresholds and category names are emphasised, since they are the point
    /// being made: the same numbers carry different labels.
    private var explainerText: AttributedString {
        var text = AttributedString(
            """
            Guidelines disagree. A reading of 135/85 is Stage 1 under ACC/AHA and \
            only High normal under ESC/ESH — the same numbers, different labels.

            BP Coach shows you the labels from the guideline you pick. Changing it \
            later never alters your stored readings — only how they are described.

            If your doctor follows a particular guideline, choose that one.
            """
        )
        for phrase in ["135/85", "Stage 1", "High normal"] {
            if let range = text.range(of: phrase) {
                text[range].foregroundColor = OnboardingTheme.accent
                text[range].font = .system(size: 13, weight: .bold)
            }
        }
        return text
    }

    // MARK: - 4 · Who is this for?

    /// Names the owner profile.
    ///
    /// Asked here rather than at the very start because a name means nothing
    /// until the person knows what the app does. It also sets up the one thing
    /// that genuinely differs per profile: only the device owner can use Apple
    /// Health, and saying so now avoids a confusing refusal later.
    private var whoIsThisFor: some View {
        OnboardingScreen(
            logoSymbol: "person.crop.circle.fill",
            header: {
                OnboardingTitle(
                    accented: "Who ",
                    plain: "is this for?",
                    subtitle: "You can add other people later"
                )
            },
            content: {
                VStack(spacing: 15) {
                    TextField(
                        "",
                        text: $ownerName,
                        prompt: Text("Your name")
                            .foregroundStyle(OnboardingTheme.textSecondary)
                    )
                    .font(.system(size: 16))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .background(OnboardingTheme.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(OnboardingTheme.cardStroke, lineWidth: 1)
                    }

                    OnboardingFeatureRow(symbol: "heart.fill") {
                        Text("This profile is the one that can read Apple Health, because Health belongs to whoever owns the phone.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OnboardingTheme.textSecondary)
                            .lineSpacing(2)
                    }

                    OnboardingFeatureRow(symbol: "person.2.fill") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tracking someone else too?")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OnboardingTheme.textSecondary)
                            Text("Add family profiles in More at any time.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(OnboardingTheme.accent)
                        }
                    }
                }
            },
            primary: ("Continue", {
                let trimmed = ownerName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { app.renameOwner(to: trimmed) }
                step = 4
            }),
            secondary: ("Skip", { step = 4 })
        )
    }

    // MARK: - 5 · Apple Health

    private var healthPermission: some View {
        OnboardingScreen(
            logoSymbol: "heart.fill",
            header: {
                OnboardingTitle(
                    accented: "Apple ",
                    plain: "Health",
                    subtitle: "Optional, and you stay in control"
                )
            },
            content: {
                VStack(spacing: 15) {
                    // Mirrors the Apple Health screen in the design: an
                    // accent-bordered card with the headline and a large
                    // circular glyph, then the detail rows beneath.
                    BrandCard(strokeColor: OnboardingTheme.accent.opacity(0.5)) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Connect with Apple Health")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(OnboardingTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Sync your BP, weight, activity and more securely.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OnboardingTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)

                            Circle()
                                .fill(OnboardingTheme.accent.opacity(0.1))
                                .frame(width: 69, height: 69)
                                .overlay {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 30))
                                        .foregroundStyle(Brand.restingHeartRate)
                                }
                                .accessibilityHidden(true)
                        }
                    }

                    Text("What BP Coach reads")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)

                    // Named individually rather than as one sentence, matching
                    // the design's row list — and it is a clearer answer to
                    // "what exactly am I agreeing to?".
                    ForEach(healthCategories, id: \.0) { category in
                        OnboardingFeatureRow(symbol: category.1) {
                            Text(category.0)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OnboardingTheme.textSecondary)
                        }
                    }

                    OnboardingFeatureRow(symbol: "lock.fill") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Read-only. None of this leaves your device.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OnboardingTheme.textSecondary)
                            Text("No account needed.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(OnboardingTheme.accent)
                        }
                    }

                    if let healthError {
                        Text(healthError)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.statusModerate)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                }
            },
            primary: ("Connect Health", {
                Task {
                    do {
                        try await app.health.requestReadAuthorization(for: app.activeProfile)
                        step = 5
                    } catch {
                        // Onboarding must never dead-end. Show what happened and
                        // let the user continue without Health.
                        healthError = error.localizedDescription
                    }
                }
            }),
            secondary: ("Not now", { step = 5 })
        )
    }

    // MARK: - 6 · Reminders

    private var notificationPermission: some View {
        OnboardingScreen(
            logoSymbol: "bell.fill",
            header: {
                OnboardingTitle(
                    accented: "Gentle ",
                    plain: "reminders",
                    subtitle: "You control every category"
                )
            },
            content: {
                VStack(spacing: 15) {
                    OnboardingFeatureRow(symbol: "pills.fill") {
                        Text("Medication doses, measurement nudges and appointment reminders.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OnboardingTheme.textSecondary)
                            .lineSpacing(2)
                    }

                    OnboardingFeatureRow(symbol: "slider.horizontal.3") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scheduled on this device only.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OnboardingTheme.textSecondary)
                            Text("Turn any of them off in Settings.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(OnboardingTheme.accent)
                        }
                    }
                }
            },
            primary: ("Enable reminders", {
                Task {
                    await NotificationEngine.shared.requestAuthorization()
                    app.completeOnboarding()
                }
            }),
            secondary: ("Skip", { app.completeOnboarding() })
        )
    }
}

/// Shared layout: logo, header, divider, content, buttons pinned to the bottom.
struct OnboardingScreen<Header: View, Content: View, Footnote: View>: View {
    let logoSymbol: String
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    let primary: (String, () -> Void)
    var secondary: (String, () -> Void)?
    @ViewBuilder var footnote: Footnote

    init(
        logoSymbol: String,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        primary: (String, () -> Void),
        secondary: (String, () -> Void)? = nil,
        @ViewBuilder footnote: () -> Footnote = { EmptyView() }
    ) {
        self.logoSymbol = logoSymbol
        self.header = header()
        self.content = content()
        self.primary = primary
        self.secondary = secondary
        self.footnote = footnote()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    OnboardingLogo(symbol: logoSymbol)
                        .padding(.top, 46)

                    header.padding(.top, 21)

                    OnboardingDivider().padding(.top, 35)

                    content
                        .padding(.horizontal, OnboardingTheme.Metric.horizontalPadding)
                        .padding(.top, 31)
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 15) {
                OnboardingPrimaryButton(title: primary.0, action: primary.1)

                if let secondary {
                    OnboardingSecondaryButton(title: secondary.0, action: secondary.1)
                }

                footnote
            }
            .padding(.horizontal, OnboardingTheme.Metric.horizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
    }
}
