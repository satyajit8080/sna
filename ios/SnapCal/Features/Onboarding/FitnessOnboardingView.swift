import SwiftUI

/// Conversational fitness onboarding.
///
/// The server decides the next question, so it can skip anything SnapCal
/// already knows and anything an earlier answer made irrelevant. The client
/// deliberately holds no question list — duplicating it here is how the two
/// drift apart.
struct FitnessOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var state: OnboardingState?
    @State private var selected: Set<String> = []
    @State private var submitting = false
    @State private var loading = true
    @State private var error: String?

    var onComplete: (() -> Void)?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let question = state?.next {
                    questionView(question)
                } else {
                    completedView
                }
            }
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Later") { dismiss() }
                }
            }
            .task { await load() }
            .alert("Couldn't save that", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(submitting)
    }

    private func questionView(_ question: OnboardingQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // Progress is the server's count, so a skipped branch shortens
                // the bar rather than leaving phantom steps.
                ProgressView(value: Double(question.step), total: Double(question.total))
                    .tint(Theme.accent)

                Text("Step \(question.step) of \(question.total)")
                    .font(.jakarta(12, .semibold))
                    .foregroundStyle(Theme.secondary)

                // Only on the first question, and only for a new user.
                if question.step == 1, let welcome = state?.welcome {
                    Text(welcome)
                        .font(.body_)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }

                Text(question.question)
                    .font(.jakarta(24, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                if question.multiSelect {
                    Text("Pick as many as apply")
                        .font(.jakarta(12, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }

            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(question.options) { option in
                        chip(option, multiSelect: question.multiSelect)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: Theme.Space.s) {
                if question.multiSelect {
                    Button {
                        Task { await answer(question, values: Array(selected)) }
                    } label: {
                        if submitting { ProgressView().tint(.white) } else { Text("Continue") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selected.isEmpty || submitting)
                }

                if question.skippable {
                    Button("Skip this one") {
                        Task { await answer(question, skip: true) }
                    }
                    .font(.jakarta(14, .medium))
                    .foregroundStyle(Theme.secondary)
                    .disabled(submitting)
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.Space.l)
    }

    private func chip(_ option: OnboardingOption, multiSelect: Bool) -> some View {
        let isSelected = selected.contains(option.value)

        return Button {
            Haptics.tap()
            if multiSelect {
                withAnimation(Theme.quick) {
                    if isSelected { selected.remove(option.value) }
                    else { selected.insert(option.value) }
                }
            } else {
                // Single-select advances immediately — an extra Continue tap
                // per question is the difference between finishing onboarding
                // and abandoning it.
                selected = [option.value]
                if let question = state?.next {
                    Task { await answer(question, value: option.value) }
                }
            }
        } label: {
            HStack {
                Text(option.label)
                    .font(.jakarta(16, .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : .primary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.10) : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .stroke(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    private var completedView: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("That's everything")
                .font(.jakarta(22, .bold))
            Text("I can plan your training around your equipment, your time and how you're recovering.")
                .font(.body_)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.l)
            Spacer()
            Button("Done") {
                onComplete?()
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, Theme.Space.l)
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        state = try? await APIClient.shared.onboardingState()
        loading = false
    }

    private func answer(_ question: OnboardingQuestion,
                        value: String? = nil,
                        values: [String]? = nil,
                        skip: Bool = false) async {
        submitting = true
        defer { submitting = false }

        do {
            let next = try await APIClient.shared.answerOnboarding(
                field: question.field, value: value, values: values, skip: skip)

            withAnimation(Theme.snap) {
                state = next
                selected = []          // never carry a selection to the next question
            }
            if next.next == nil { Haptics.success() }
        } catch {
            self.error = (error as? APIError)?.errorDescription
                ?? "Couldn't save that answer."
            selected = []
        }
    }
}
