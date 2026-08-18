import SwiftUI

struct ReadingDetailView: View {
    @Environment(GuidelineEngine.self) private var guidelines
    let reading: BPReading

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack {
                            BPValueView(
                                systolic: reading.systolic,
                                diastolic: reading.diastolic,
                                pulse: reading.pulse
                            )
                            Spacer()
                        }
                        CategoryBadge(category: category)
                        Text(explanation)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        SectionHeader(title: "Details")
                        detailRow("Recorded", reading.recordedAt.formatted(date: .long, time: .shortened))
                        detailRow("Time of day", reading.timeOfDay.label)
                        detailRow("Source", reading.source.label)
                        detailRow("MAP", String(format: "%.0f mmHg", reading.meanArterialPressure))
                        detailRow("Pulse pressure", "\(reading.pulsePressure) mmHg")
                        if let notes = reading.notes, !notes.isEmpty {
                            detailRow("Notes", notes)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var category: BPCategory {
        guidelines.category(for: reading)
    }

    /// Explains which number drove the badge — useful when systolic and diastolic
    /// fall in different bands, which is common and confusing.
    private var explanation: String {
        let guideline = guidelines.active
        let systolicCategory = guideline.systolicCategory(reading.systolic)
        let diastolicCategory = guideline.diastolicCategory(reading.diastolic)

        if systolicCategory == diastolicCategory {
            return "Both numbers fall in \(category.label) under \(guideline.displayName)."
        }
        let driver = systolicCategory > diastolicCategory ? "systolic" : "diastolic"
        return """
        Your \(driver) number is the higher category here, so the reading is classed \
        as \(category.label) under \(guideline.displayName). A reading takes the more \
        serious of its two categories.
        """
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
