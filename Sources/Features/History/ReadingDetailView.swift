import Charts
import SwiftData
import SwiftUI

/// A single reading, implemented from the Figma "Blood Pressure" screen.
///
/// Shows what was recorded and the guidance that follows from it. Everything
/// here is derived from the reading and the active guideline — nothing is
/// generated, and the safety wording comes from `SafetyEngine` rather than being
/// written per screen.
struct ReadingDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]

    let reading: BPReading

    @State private var isEditing = false
    @State private var isConfirmingDelete = false

    private var category: BPCategory { guidelines.category(for: reading) }
    private var assessment: SafetyEngine.Assessment { SafetyEngine.assess(reading) }

    private var recent: [BPReading] {
        allReadings.filter { $0.profileID == reading.profileID }
    }

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Blood Pressure",
                showsBack: true,
                onBack: { dismiss() },
                trailing: [("square.and.pencil", { isEditing = true })]
            )

            heroCard
            readingCard

            if assessment.urgency > .none {
                SafetyBanner(assessment: assessment)
            }

            contextCard

            if recent.count >= 2 { comparisonCard }

            Button("Delete this reading", role: .destructive) {
                isConfirmingDelete = true
            }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .sheet(isPresented: $isEditing) { EditBPView(reading: reading) }
        .confirmationDialog(
            "Delete this reading?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                context.delete(reading)
                try? context.save()
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Your averages and trends will be recalculated without it.")
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        BrandCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Track your BP")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("Keep a log to see your trends.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                }

                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    Text("\(reading.systolic)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.accent)
                    Rectangle()
                        .fill(Brand.cardStroke)
                        .frame(width: 32, height: 1)
                        .padding(.vertical, 3)
                    Text("\(reading.diastolic)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.accent)
                    Text("mmHg")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 2)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(reading.systolic) over \(reading.diastolic) millimetres of mercury")
            }
        }
    }

    // MARK: - The reading

    private var readingCard: some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(reading.systolic)/\(reading.diastolic)")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("mmHg")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                    Spacer()
                    BrandPill(
                        text: category.label,
                        tint: GuidelineEngine.color(for: category.severity)
                    )
                }

                Text(reading.recordedAt.formatted(date: .long, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 8)

                Divider().background(Brand.cardStroke).padding(.vertical, 16)

                HStack(spacing: 0) {
                    metric("\(reading.systolic)", "Systolic", Brand.restingHeartRate)
                    divider
                    metric("\(reading.diastolic)", "Diastolic", Brand.weight)
                    divider
                    metric(reading.pulse.map(String.init) ?? "—", "Pulse", Brand.sleep)
                }
            }
        }
    }

    private func metric(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(value == "—" ? Brand.textSecondary : tint)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Brand.cardStroke).frame(width: 1, height: 38)
    }

    // MARK: - Context

    private var contextCard: some View {
        BrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("How it was taken")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)

                row("Source", reading.source.label, "hand.tap")
                row("Time of day", reading.timeOfDay.label, "clock")
                row("Counts toward home average",
                    reading.source.isHomeMeasurement ? "Yes" : "No — clinic reading",
                    "house")

                // Derived values the model already computes. Shown because they
                // are occasionally what a clinician asks about, and they cost
                // nothing to display.
                row("Pulse pressure", "\(reading.pulsePressure) mmHg", "arrow.up.arrow.down")
                row("Mean arterial pressure",
                    String(format: "%.0f mmHg", reading.meanArterialPressure),
                    "waveform.path")

                if !reading.tags.isEmpty {
                    row("Tags", reading.tags.joined(separator: ", "), "tag")
                }

                if let notes = reading.notes, !notes.isEmpty {
                    Divider().background(Brand.cardStroke)
                    Text(notes)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Category from \(guidelines.active.displayName).")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 2)
            }
        }
    }

    private func row(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Brand.accent)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Brand.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.textPrimary)
        }
    }

    // MARK: - Comparison

    /// How this reading sits against the user's own recent average — which is
    /// more informative than the category alone, since a "normal" reading well
    /// above someone's usual is still worth noticing.
    private var comparisonCard: some View {
        let average = BPStatistics.homeAverage(recent, days: 30)

        return Group {
            if let average, average.count >= 2 {
                BrandCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Against your 30-day average")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)

                        HStack {
                            Text("\(average.systolic)/\(average.diastolic)")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Brand.textSecondary)
                            Text("from \(average.count) readings")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                            Spacer()
                        }

                        let delta = reading.systolic - average.systolic
                        HStack(spacing: 6) {
                            Image(systemName: delta > 0 ? "arrow.up" : delta < 0 ? "arrow.down" : "equal")
                                .font(.system(size: 10, weight: .bold))
                            Text(
                                delta == 0
                                    ? "Exactly on your average"
                                    : "\(abs(delta)) mmHg \(delta > 0 ? "above" : "below") your systolic average"
                            )
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.accent)

                        Text("Home readings only — clinic readings are kept separate.")
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
        }
    }
}
