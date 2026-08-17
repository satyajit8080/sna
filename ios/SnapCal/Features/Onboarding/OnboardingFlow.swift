import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppState.self) private var app

    /// Phase 9: the user reaches a working app before ever seeing an offer.
    /// questions → targets → Health → first scan → (Premium comes later, from
    /// the natural limit, not from a modal on day one).
    private enum Stage { case questions, targets, health, firstScan }

    @State private var draft = ProfileDraft()
    @State private var step = 0
    @State private var computed: TargetsResponse?
    @State private var submitting = false
    @State private var error: String?
    @State private var stage: Stage = .questions

    private let steps = 7

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .questions:
                header
                content
                    .frame(maxHeight: .infinity)
                footer

            case .targets:
                if let computed {
                    TargetsRevealView(result: computed) {
                        withAnimation(Theme.snap) { stage = .health }
                    }
                }

            case .health:
                HealthConnectView { withAnimation(Theme.snap) { stage = .firstScan } }

            case .firstScan:
                FirstScanPromptView {
                    Analytics.track(.onboardingCompleted)
                    Task {
                        await app.refresh()
                        // Into the health baseline, not straight to Home.
                        await app.advanceAfterProfile()
                    }
                }
            }
        }
        .background(Theme.bg)
        .alert("Couldn't save", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: Theme.Space.m) {
            HStack {
                if step > 0 {
                    Button { withAnimation(Theme.snap) { step -= 1 } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    }
                }
                Spacer()
                Text("\(step + 1) of \(steps)").font(.label).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(steps))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                switch step {
                case 0:
                    Q("What should we call you?")
                    TextField("First name", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .textContentType(.givenName)
                        .submitLabel(.next)

                case 1:
                    Q("How old are you?")
                    Picker("Birth year", selection: $draft.birthYear) {
                        ForEach(1930...(Calendar.current.component(.year, from: .now) - 13), id: \.self) {
                            Text(String($0)).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)

                case 2:
                    Q("Sex")
                    Sub("Used for the metabolic formula only.")
                    ChoiceGroup(selection: $draft.sex, options: [
                        ("female", "Female", "figure.stand.dress"),
                        ("male", "Male", "figure.stand"),
                        ("other", "Prefer not to say", "person.fill.questionmark"),
                    ])

                case 3:
                    Q("How tall are you?")
                    MeasureRow(value: $draft.heightCm, range: 120...220, step: 1, unit: "cm")

                case 4:
                    Q("Current weight")
                    MeasureRow(value: $draft.startWeightKg, range: 35...250, step: 0.5, unit: "kg")

                case 5:
                    Q("What are you aiming for?")
                    ChoiceGroup(selection: $draft.goal, options: [
                        ("lose", "Lose weight", "arrow.down.right"),
                        ("maintain", "Maintain", "equal"),
                        ("gain", "Gain weight", "arrow.up.right"),
                    ])
                    if draft.goal != "maintain" {
                        Divider().padding(.vertical, Theme.Space.s)
                        Text("Goal weight").font(.label).foregroundStyle(.secondary)
                        MeasureRow(value: $draft.goalWeightKg, range: 35...250, step: 0.5, unit: "kg")
                    }

                case 6:
                    Q("How active are you?")
                    ChoiceGroup(selection: $draft.activityLevel, options: [
                        ("sedentary", "Mostly sitting", "chair"),
                        ("light", "Light — walks, 1-2 workouts", "figure.walk"),
                        ("moderate", "Moderate — 3-4 workouts", "figure.run"),
                        ("active", "Active — 5-6 workouts", "figure.strengthtraining.traditional"),
                        ("very_active", "Very active — daily / physical job", "flame.fill"),
                    ])

                default: EmptyView()
                }
            }
            .padding(Theme.Space.l)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var footer: some View {
        Button(step == steps - 1 ? "Calculate my targets" : "Continue") {
            Haptics.tap()
            if step == steps - 1 { submit() } else { withAnimation(Theme.snap) { step += 1 } }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!canAdvance || submitting)
        .opacity(canAdvance ? 1 : 0.4)
        .padding(Theme.Space.l)
    }

    private var canAdvance: Bool {
        switch step {
        case 0: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        case 5: draft.goal == "maintain" || abs(draft.goalWeightKg - draft.startWeightKg) >= 0.5
        default: true
        }
    }

    private func submit() {
        submitting = true
        if draft.goal == "maintain" { draft.goalWeightKg = draft.startWeightKg }
        draft.country = Locale.current.region?.identifier

        Task {
            defer { submitting = false }
            do {
                let res = try await APIClient.shared.submitProfile(draft)
                Haptics.success()
                withAnimation(Theme.snap) { computed = res; stage = .targets }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Small pieces

    private func Q(_ text: String) -> some View {
        Text(text).font(.system(size: 30, weight: .bold, design: .rounded))
    }

    private func Sub(_ text: String) -> some View {
        Text(text).font(.label).foregroundStyle(.secondary)
    }
}

private struct ChoiceGroup: View {
    @Binding var selection: String
    let options: [(String, String, String)]

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(options, id: \.0) { value, label, icon in
                Button {
                    Haptics.tap()
                    withAnimation(Theme.quick) { selection = value }
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: icon).frame(width: 24)
                        Text(label).font(.system(size: 16, weight: .medium))
                        Spacer()
                        if selection == value {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(Theme.Space.m)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(selection == value ? Theme.accentSoft : Theme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .stroke(selection == value ? Theme.accent : Theme.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MeasureRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.formatted(.number.precision(.fractionLength(step < 1 ? 1 : 0))))
                    .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                Text(unit).font(.title).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Slider(value: $value, in: range, step: step)
                .tint(Theme.accent)
        }
    }
}

private struct TargetsRevealView: View {
    let result: TargetsResponse
    let onContinue: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            Text("Your daily target")
                .font(.label).foregroundStyle(.secondary).textCase(.uppercase)

            Text("\(result.targets.calories)")
                .font(.hero)
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
                .scaleEffect(shown ? 1 : 0.7)
                .opacity(shown ? 1 : 0)

            Text("calories").font(.title).foregroundStyle(.secondary)

            HStack(spacing: Theme.Space.m) {
                MacroPill("Protein", result.targets.protein_g, Theme.protein)
                MacroPill("Carbs", result.targets.carbs_g, Theme.carbs)
                MacroPill("Fat", result.targets.fat_g, Theme.fat)
            }
            .opacity(shown ? 1 : 0)

            if let weeks = result.projectedWeeks {
                Text("At this pace you'd reach your goal in about **\(weeks) weeks**.")
                    .font(.body_)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.xl)
                    .opacity(shown ? 1 : 0)
            }

            Spacer()

            Text("These are estimates you can adjust any time in Settings.")
                .font(.caption_).foregroundStyle(.tertiary).multilineTextAlignment(.center)

            Button("Start tracking", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Space.l)
        .onAppear {
            withAnimation(Theme.snap.delay(0.1)) { shown = true }
            Haptics.success()
        }
    }

    private func MacroPill(_ label: String, _ grams: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(grams)g").font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(label).font(.caption_).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.s)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}


/// Last onboarding beat: point them at the one action the product exists for.
/// No paywall here — the offer lands after they've had value, not before.
struct FirstScanPromptView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Theme.accent)

            VStack(spacing: Theme.Space.s) {
                Text("Now scan your first meal")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text("Point your camera at whatever you're eating next. You'll have calories and macros in a few seconds.")
                    .font(.body_).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.m)
            }

            Spacer()

            Button("Start tracking", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Space.l)
        .background(Theme.bg)
    }
}
