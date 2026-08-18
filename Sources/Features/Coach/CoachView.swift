import SwiftData
import SwiftUI

struct CoachView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]
    @Query private var allLifestyle: [LifestyleEntry]

    @State private var draft = ""
    @State private var transcript: [ChatMessage] = []
    @State private var isThinking = false
    @State private var error: AppError?
    @State private var section: Section = .dashboard

    enum Section: String, CaseIterable { case dashboard, chat }

    struct ChatMessage: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    private var snapshot: BPContextSnapshot {
        app.contextEngine.makeSnapshot(
            profileID: app.activeProfile.id,
            readings: allReadings,
            medications: allMedications,
            doses: allDoses,
            lifestyle: allLifestyle,
            healthSnapshot: app.health.snapshot
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            switch section {
            case .dashboard: dashboard
            case .chat: chat
            }
        }
        .background(Theme.background)
        .navigationTitle("Coach")
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                if !app.coach.isConfigured { unconfiguredCard }
                contextCards
                guardrailsCard
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private var unconfiguredCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Label("Coach not set up yet", systemImage: "sparkles")
                    .font(.headline)
                Text("""
                No AI service is connected. When one is, the coach will explain your own \
                readings and trends in plain language — using only the summary shown below.

                Everything else in BP Coach works without it.
                """)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shows exactly what would be sent. The user should be able to inspect the
    /// payload rather than take it on trust.
    private var contextCards: some View {
        let context = snapshot

        return VStack(spacing: Theme.Spacing.lg) {
            CardView {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    SectionHeader(
                        title: "What the coach would see",
                        subtitle: "A summary capped at \(AIContextEngine.readingLimit) readings — never your full database"
                    )
                    contextRow("Readings", "\(context.recentReadings.count)")
                    contextRow("Average windows", "\(context.averages.count)")
                    contextRow("Medications", "\(context.medications.count)")
                    contextRow("Lifestyle categories", "\(context.lifestyle.count)")
                    contextRow("Guideline", context.guidelineName)
                    contextRow("Profile", app.activeProfile.name)

                    if context.isTooSparse {
                        Text("Not enough readings yet for the coach to say anything useful.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, Theme.Spacing.xs)
                    }
                }
            }

            if !context.averages.isEmpty {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "BP context")
                        ForEach(context.averages, id: \.days) { average in
                            HStack {
                                Text("\(average.days)-day average")
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text("\(average.systolic)/\(average.diastolic)")
                                    .font(Theme.number(16, weight: .semibold))
                            }
                            .font(.subheadline)
                        }
                        if let sd = context.variabilitySD {
                            HStack {
                                Text("Variability").foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(String(format: "±%.1f", sd))
                                    .font(Theme.number(16, weight: .semibold))
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }

            if !context.medications.isEmpty {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Medication context")
                        ForEach(context.medications, id: \.name) { medication in
                            HStack {
                                Text(medication.name).foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(medication.adherencePercent.map { "\(Int($0))%" } ?? "No doses")
                                    .font(Theme.number(16, weight: .semibold))
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }

            if context.stepsToday != nil || context.restingHeartRate != nil {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Activity context")
                        HStack {
                            if let steps = context.stepsToday {
                                StatTile(title: "Steps", value: "\(steps)")
                            }
                            if let hr = context.restingHeartRate {
                                StatTile(title: "Resting HR", value: "\(hr) bpm")
                            }
                        }
                    }
                }
            }
        }
    }

    private var guardrailsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(
                    title: "What the coach will never do",
                    subtitle: "Enforced in code, not just in instructions"
                )
                ForEach(CoachGuardrails.prohibited, id: \.self) { rule in
                    Label(rule.capitalized, systemImage: "xmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("Urgency is decided by fixed clinical rules the AI cannot reach.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
    }

    private func contextRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    // MARK: - Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        if transcript.isEmpty {
                            EmptyStateView(
                                symbol: "bubble.left.and.text.bubble.right",
                                title: app.coach.isConfigured ? "Ask anything about your data" : "Chat unavailable",
                                message: app.coach.isConfigured
                                    ? "Try: what moved my blood pressure this week?"
                                    : "The AI service is not configured, so the coach cannot answer. Your readings and trends still work."
                            )
                        }

                        ForEach(transcript) { message in
                            MessageBubble(message: message).id(message.id)
                        }

                        if isThinking {
                            LoadingView(message: "Thinking")
                        }

                        if let error {
                            ErrorBanner(error: error) { self.error = nil }
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
                .onChange(of: transcript.count) { _, _ in
                    withAnimation { proxy.scrollTo(transcript.last?.id, anchor: .bottom) }
                }
            }

            composer
        }
    }

    private var composer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("Ask about your readings", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(!app.coach.isConfigured)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
            .accessibilityLabel("Send")
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.surface)
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        draft = ""
        transcript.append(ChatMessage(isUser: true, text: question))
        isThinking = true

        let context = snapshot

        Task {
            defer { isThinking = false }
            do {
                let response = try await app.coach.respond(to: .freeform(question), context: context)
                transcript.append(ChatMessage(isUser: false, text: response.text))
                error = nil
            } catch {
                self.error = .coachUnavailable
            }
        }
    }
}

struct MessageBubble: View {
    let message: CoachView.ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            Text(message.text)
                .padding(Theme.Spacing.md)
                .background(message.isUser ? Theme.accentSoft : Theme.surface)
                .foregroundStyle(Theme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            if !message.isUser { Spacer(minLength: 48) }
        }
    }
}
