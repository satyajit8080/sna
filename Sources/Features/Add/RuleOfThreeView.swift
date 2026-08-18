import SwiftData
import SwiftUI

/// Rule of 3: rest, then two or three readings about a minute apart, averaged.
///
/// The session average is what gets classified, not the individual readings —
/// which is why the first of three is discarded, as it reliably runs high.
struct RuleOfThreeView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .rest
    @State private var secondsRemaining = 300
    @State private var entries: [(systolic: Int, diastolic: Int, pulse: Int?)] = []
    @State private var systolic = 120
    @State private var diastolic = 80
    @State private var pulse: Int?
    @State private var timer: Timer?

    enum Stage { case rest, measuring, review }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .rest: restStage
                case .measuring: measuringStage
                case .review: reviewStage
                }
            }
            .background(Theme.background)
            .navigationTitle("Rule of 3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { stop(); dismiss() }
                }
            }
            .onDisappear { stop() }
        }
    }

    // MARK: - Rest

    private var restStage: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Theme.border, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: 1 - (Double(secondsRemaining) / 300.0))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: secondsRemaining)

                VStack(spacing: Theme.Spacing.xs) {
                    Text(timeString)
                        .font(Theme.number(44, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("resting").foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 220, height: 220)
            .accessibilityLabel("Rest timer, \(timeString) remaining")

            VStack(spacing: Theme.Spacing.sm) {
                Text("Sit quietly").font(.title3.weight(.semibold))
                Text("""
                Back supported, feet flat, legs uncrossed. Arm resting at heart height. \
                No talking, no phone.
                """)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            }

            Spacer()

            VStack(spacing: Theme.Spacing.sm) {
                Button("I'm ready — start measuring") { beginMeasuring() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Skipping the rest usually adds a few points.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .onAppear(perform: startTimer)
    }

    private var timeString: String {
        String(format: "%d:%02d", secondsRemaining / 60, secondsRemaining % 60)
    }

    // MARK: - Measuring

    private var measuringStage: some View {
        Form {
            Section {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack {
                        Text("Reading \(index + 1)")
                        Spacer()
                        Text("\(entry.systolic)/\(entry.diastolic)")
                            .font(Theme.number(17, weight: .semibold))
                        if index == 0 && entries.count >= 3 {
                            Text("discarded")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            } header: {
                Text("Recorded so far")
            } footer: {
                if entries.count >= 3 {
                    Text("With three readings the first is discarded, as it typically runs high.")
                }
            }

            Section("Reading \(entries.count + 1)") {
                BPStepperRow(label: "Systolic", value: $systolic, range: 60...300, tint: Theme.systolicColor)
                BPStepperRow(label: "Diastolic", value: $diastolic, range: 30...200, tint: Theme.diastolicColor)
                PulseStepperRow(pulse: $pulse)
            }

            Section {
                Button("Add this reading") { addEntry() }
                    .disabled(!BPReading.isPlausible(systolic: systolic, diastolic: diastolic))

                if entries.count >= 2 {
                    Button("Finish and save") { stage = .review }
                        .fontWeight(.semibold)
                }
            } footer: {
                Text("Wait about a minute between readings.")
            }
        }
    }

    // MARK: - Review

    private var reviewStage: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let average = averageOfEntries {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(
                            title: "Session average",
                            subtitle: "From \(entries.count) readings"
                        )
                        BPValueView(
                            systolic: average.systolic,
                            diastolic: average.diastolic,
                            pulse: average.pulse
                        )
                        CategoryBadge(
                            category: guidelines.category(
                                systolic: average.systolic,
                                diastolic: average.diastolic
                            )
                        )

                        let assessment = SafetyEngine.assess(
                            systolic: average.systolic,
                            diastolic: average.diastolic
                        )
                        if assessment.urgency > .none {
                            SafetyBanner(assessment: assessment)
                        }
                    }
                }

                Button("Save session") { save(average: average) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
            }
            Spacer()
        }
        .padding(Theme.Spacing.lg)
    }

    private var averageOfEntries: (systolic: Int, diastolic: Int, pulse: Int?)? {
        guard !entries.isEmpty else { return nil }
        let used = entries.count >= 3 ? Array(entries.dropFirst()) : entries
        let sys = used.map(\.systolic).reduce(0, +) / used.count
        let dia = used.map(\.diastolic).reduce(0, +) / used.count
        let pulses = used.compactMap(\.pulse)
        return (sys, dia, pulses.isEmpty ? nil : pulses.reduce(0, +) / pulses.count)
    }

    // MARK: - Actions

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                if secondsRemaining > 0 {
                    secondsRemaining -= 1
                    if secondsRemaining == 0 {
                        Haptics.success()
                        beginMeasuring()
                    }
                }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func beginMeasuring() {
        stop()
        stage = .measuring
    }

    private func addEntry() {
        entries.append((systolic, diastolic, pulse))
        Haptics.selection()
        if entries.count >= 3 { stage = .review }
    }

    private func save(average: (systolic: Int, diastolic: Int, pulse: Int?)) {
        let session = BPMeasurementSession(profileID: app.activeProfile.id)
        session.completedAt = .now
        session.averageSystolic = average.systolic
        session.averageDiastolic = average.diastolic
        session.averagePulse = average.pulse
        context.insert(session)

        // The saved reading is the session average — that is what gets classified
        // and what appears in history and trends.
        let reading = BPReading(
            profileID: app.activeProfile.id,
            systolic: average.systolic,
            diastolic: average.diastolic,
            pulse: average.pulse,
            source: .ruleOfThree
        )
        reading.sessionID = session.id
        context.insert(reading)
        session.readingIDs = [reading.id]

        try? context.save()
        Haptics.success()
        dismiss()
    }
}
