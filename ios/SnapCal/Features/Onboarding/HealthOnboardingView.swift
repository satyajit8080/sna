import SwiftUI

/// The health onboarding, driven entirely by the API.
///
/// The screen list, the field types, which screens are skippable and — most
/// importantly — how many screens there are all come from the server. The
/// count varies per user: someone who has connected Health and filled a
/// profile sees five screens, a fresh install sees eight. A hardcoded
/// denominator produces "6 of 5", which is exactly the bug this avoids.
struct HealthOnboardingView: View {
    @Environment(AppState.self) private var app

    var onComplete: () -> Void

    @State private var plan: HealthOnboardingPlan?
    @State private var index = 0
    /// Answers for the screen on display, cleared on each advance.
    @State private var answers: [String: Any] = [:]
    /// Everything answered so far — sent back so the plan can adapt.
    @State private var allAnswers: [String: Any] = [:]
    @State private var saving = false
    @State private var loading = true
    @State private var error: String?

    private var screen: OnboardingScreen? {
        guard let plan, index < plan.screens.count else { return nil }
        return plan.screens[index]
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if loading {
                ProgressView().tint(Theme.accent)
            } else if let screen {
                content(screen)
            } else {
                finished
            }
        }
        .task { await load() }
        .alert("Couldn't save that", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: - Layout

    private func content(_ screen: OnboardingScreen) -> some View {
        VStack(spacing: 0) {
            header(screen)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ForEach(screen.fields) { field in
                        FieldView(field: field, value: binding(for: field))
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, Theme.Space.l)
            }
            .scrollIndicators(.hidden)

            footer(screen)
        }
    }

    private func header(_ screen: OnboardingScreen) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                if index > 0 {
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.snap) { index -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                // Both the number and the bar come from the API. Never a
                // constant — the total differs per user.
                if let plan {
                    Text("\(index + 1) of \(plan.totalScreens)")
                        .font(.jakarta(12, .semibold))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.border)
                            Capsule().fill(Theme.accentBright)
                                .frame(width: geo.size.width
                                       * CGFloat(index + 1) / CGFloat(max(plan.totalScreens, 1)))
                        }
                    }
                    .frame(height: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(screen.title)
                    .font(.jakarta(26, .bold))

                if let subtitle = screen.subtitle {
                    Text(subtitle)
                        .font(.jakarta(14, .medium))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.Space.m)
    }

    private func footer(_ screen: OnboardingScreen) -> some View {
        HStack(spacing: Theme.Space.m) {
            // Always visible on a sensitive screen. People give better answers
            // when declining is obviously allowed.
            if screen.skippable {
                Button("Skip for now") {
                    Haptics.tap()
                    Task { await advance(skipping: true) }
                }
                .font(.jakarta(14, .medium))
                .foregroundStyle(Theme.secondary)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                Task { await advance(skipping: false) }
            } label: {
                HStack(spacing: 8) {
                    if saving {
                        ProgressView().tint(Theme.bg)
                    } else {
                        Text(isLastScreen ? "Finish" : "Next")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .font(.jakarta(16, .semibold))
                .foregroundStyle(Theme.bg)
                .frame(maxWidth: screen.skippable ? 200 : .infinity)
                .frame(height: 52)
                .background(canAdvance ? Theme.accentBright : Theme.accentBright.opacity(0.35),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canAdvance || saving)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.Space.m)
    }

    private var finished: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accentBright)
            Text("All set")
                .font(.jakarta(24, .bold))
            Text("I've got what I need to start. Everything else I'll pick up as we go.")
                .font(.body_)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.xl)
            Spacer()

            Button("Continue") {
                Haptics.success()
                Task {
                    try? await APIClient.shared.finishOnboarding()
                    onComplete()
                }
            }
            .font(.jakarta(16, .semibold))
            .foregroundStyle(Theme.bg)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Theme.accentBright, in: Capsule())
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, Theme.Space.l)
        }
    }

    // MARK: - State

    private var isLastScreen: Bool {
        guard let plan else { return true }
        return index >= plan.screens.count - 1
    }

    /// Required fields must be answered; optional ones never block.
    private var canAdvance: Bool {
        guard let screen else { return false }
        return screen.fields
            .filter { !$0.isOptional }
            .allSatisfy { answers[$0.key] != nil }
    }

    private func binding(for field: OnboardingField) -> Binding<Any?> {
        Binding(
            get: { answers[field.key] },
            set: { answers[field.key] = $0 }
        )
    }

    private func load() async {
        loading = true
        plan = try? await APIClient.shared.onboardingPlan()
        loading = false

        // Nothing left to ask — a returning user, or one whose data is already
        // complete.
        if plan?.screens.isEmpty == true { onComplete() }
    }

    private func advance(skipping: Bool) async {
        guard let screen else { return }
        saving = true
        defer { saving = false }

        do {
            let payload = skipping ? [:] : answers
            if !skipping { allAnswers.merge(answers) { _, new in new } }

            // The server returns a fresh plan: an answer can remove a later
            // screen, so the total is re-read rather than assumed.
            let updated = try await APIClient.shared.saveOnboardingScreen(
                screen.id, answers: payload, skipped: skipping)

            withAnimation(Theme.snap) {
                plan = updated
                answers = [:]
                // The saved screen is gone from the new plan, so the index
                // stays put rather than advancing past it.
                index = min(index, max(updated.screens.count - 1, 0))
                if updated.screens.isEmpty { index = 0 }
            }

            if updated.screens.isEmpty {
                try? await APIClient.shared.finishOnboarding()
            }
        } catch {
            self.error = (error as? APIError)?.errorDescription
                ?? "Couldn't save that. Try again?"
        }
    }
}

// MARK: - Fields

/// One field, rendered by type.
///
/// Kept in one place so a new field type from the server needs one change
/// here rather than a change per screen.
private struct FieldView: View {
    let field: OnboardingField
    @Binding var value: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Text(field.label)
                    .font(.jakarta(15, .semibold))
                if field.isOptional {
                    Text("Optional")
                        .font(.jakarta(10, .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.surfaceSunken, in: Capsule())
                }
            }

            control

            if let hint = field.hint {
                Text(hint)
                    .font(.jakarta(11, .medium))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch field.type {
        case "chips", "chips_multi":
            ChipGrid(options: field.options ?? [],
                     multi: field.type == "chips_multi",
                     value: $value)

        case "toggle":
            Toggle(isOn: Binding(
                get: { value as? Bool ?? false },
                set: { value = $0 }
            )) { EmptyView() }
            .labelsHidden()
            .tint(Theme.accent)

        case "slider":
            SliderField(field: field, value: $value)

        case "time":
            TimeField(field: field, value: $value)

        case "number":
            NumberField(field: field, value: $value)

        case "list":
            ListField(field: field, value: $value)

        default:
            TextFieldRow(field: field, value: $value)
        }
    }
}

private struct ChipGrid: View {
    let options: [OnboardingOption]
    let multi: Bool
    @Binding var value: Any?

    private var selected: Set<String> {
        if multi { return Set(value as? [String] ?? []) }
        if let single = value as? String { return [single] }
        return []
    }

    var body: some View {
        FlowLayout(spacing: Theme.Space.s) {
            ForEach(options) { option in
                let isOn = selected.contains(option.value)

                Button {
                    Haptics.tap()
                    withAnimation(Theme.quick) { toggle(option.value) }
                } label: {
                    HStack(spacing: 5) {
                        Text(option.label)
                            .font(.jakarta(14, .semibold))
                        if isOn && multi {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundStyle(isOn ? Theme.bg : Theme.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(isOn ? Theme.accentBright : Theme.surfaceRaised, in: Capsule())
                    .overlay(Capsule().stroke(isOn ? .clear : Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ option: String) {
        if multi {
            var current = Set(value as? [String] ?? [])
            if current.contains(option) { current.remove(option) } else { current.insert(option) }
            value = Array(current)
        } else {
            // Tapping the selected chip clears it, so a single-select field
            // can be un-answered without restarting.
            value = (value as? String) == option ? nil : option
        }
    }
}

private struct SliderField: View {
    let field: OnboardingField
    @Binding var value: Any?

    private var current: Double {
        value as? Double ?? (field.min ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Int(current))\(field.unit.map { " \($0)" } ?? "")")
                .font(.jakarta(18, .bold))
                .foregroundStyle(Theme.accent)
                .monospacedDigit()

            Slider(value: Binding(get: { current }, set: { value = $0.rounded() }),
                   in: (field.min ?? 1)...(field.max ?? 10), step: 1)
                .tint(Theme.accentBright)
        }
    }
}

private struct TimeField: View {
    let field: OnboardingField
    @Binding var value: Any?

    @State private var date = Calendar.current.date(
        bySettingHour: 23, minute: 0, second: 0, of: .now) ?? .now

    var body: some View {
        DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.compact)
            .onChange(of: date) { _, new in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: new)
                value = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            }
    }
}

private struct NumberField: View {
    let field: OnboardingField
    @Binding var value: Any?
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(field.placeholder ?? "", text: $text)
                .keyboardType(.numberPad)
                .font(.jakarta(16, .semibold))
                .onChange(of: text) { _, new in
                    value = Double(new)
                }
            if let unit = field.unit {
                Text(unit)
                    .font(.jakarta(14, .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(Theme.border, lineWidth: 1))
    }
}

private struct TextFieldRow: View {
    let field: OnboardingField
    @Binding var value: Any?
    @State private var text = ""

    var body: some View {
        TextField(field.placeholder ?? "", text: $text, axis: .vertical)
            .lineLimit(1...4)
            .font(.jakarta(16, .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 15)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Theme.border, lineWidth: 1))
            .onChange(of: text) { _, new in
                value = new.isEmpty ? nil : new
            }
    }
}

/// Free-form list — allergies, conditions, medications.
private struct ListField: View {
    let field: OnboardingField
    @Binding var value: Any?
    @State private var draft = ""

    private var items: [String] { value as? [String] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.jakarta(14, .medium))
                    Spacer(minLength: 0)
                    Button {
                        Haptics.tap()
                        value = items.filter { $0 != item }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField(field.placeholder ?? "Add", text: $draft)
                    .font(.jakarta(15, .medium))
                    .onSubmit(add)

                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .frame(width: 34, height: 34)
                        .background(Theme.accentBright, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    private func add() {
        let entry = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        value = items + [entry]
        draft = ""
        Haptics.tap()
    }
}

/// Wrapping row layout for chips. `LazyVGrid` forces a column count, which
/// leaves long labels truncated and short ones stranded.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
