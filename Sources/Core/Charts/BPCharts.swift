import Charts
import SwiftUI

/// Systolic and diastolic over time, with the guideline's own thresholds drawn as
/// reference lines rather than hard-coded gridlines.
struct BPTrendChart: View {
    @Environment(GuidelineEngine.self) private var guidelines
    let readings: [BPReading]
    let days: Int

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    title: "Blood pressure",
                    subtitle: "Last \(days) days · \(guidelines.active.displayName)"
                )

                if readings.count < 2 {
                    Text("At least two readings in this window are needed to draw a trend.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Chart {
                        ForEach(readings) { reading in
                            LineMark(
                                x: .value("Date", reading.recordedAt),
                                y: .value("mmHg", reading.systolic),
                                series: .value("Series", "Systolic")
                            )
                            .foregroundStyle(Theme.systolicColor)
                            .interpolationMethod(.monotone)

                            PointMark(
                                x: .value("Date", reading.recordedAt),
                                y: .value("mmHg", reading.systolic)
                            )
                            .foregroundStyle(Theme.systolicColor)
                            .symbolSize(28)

                            LineMark(
                                x: .value("Date", reading.recordedAt),
                                y: .value("mmHg", reading.diastolic),
                                series: .value("Series", "Diastolic")
                            )
                            .foregroundStyle(Theme.diastolicColor)
                            .interpolationMethod(.monotone)

                            PointMark(
                                x: .value("Date", reading.recordedAt),
                                y: .value("mmHg", reading.diastolic)
                            )
                            .foregroundStyle(Theme.diastolicColor)
                            .symbolSize(28)
                        }
                    }
                    .chartYScale(domain: yDomain)
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 220)
                    .accessibilityLabel("Blood pressure trend over \(days) days")
                    .accessibilityValue(accessibilitySummary)

                    HStack(spacing: Theme.Spacing.lg) {
                        ChartLegendItem(label: "Systolic", color: Theme.systolicColor)
                        ChartLegendItem(label: "Diastolic", color: Theme.diastolicColor)
                    }
                }
            }
        }
    }

    /// Domain padded around the actual data rather than fixed, so a narrow range
    /// is not flattened into a straight line.
    private var yDomain: ClosedRange<Int> {
        let values = readings.flatMap { [$0.systolic, $0.diastolic] }
        let low = max(40, (values.min() ?? 60) - 15)
        let high = min(220, (values.max() ?? 160) + 15)
        return low...high
    }

    private var accessibilitySummary: String {
        guard let average = BPStatistics.average(readings) else { return "No data" }
        return "Average \(average.systolic) over \(average.diastolic) across \(average.count) readings"
    }
}

struct PulseTrendChart: View {
    let readings: [BPReading]

    private var withPulse: [BPReading] {
        readings.filter { $0.pulse != nil }
    }

    var body: some View {
        Group {
            if withPulse.count >= 2 {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Pulse", subtitle: "Beats per minute")
                        Chart(withPulse) { reading in
                            LineMark(
                                x: .value("Date", reading.recordedAt),
                                y: .value("bpm", reading.pulse ?? 0)
                            )
                            .foregroundStyle(Theme.pulseColor)
                            .interpolationMethod(.monotone)
                        }
                        .frame(height: 140)
                        .accessibilityLabel("Pulse trend")
                    }
                }
            }
        }
    }
}

struct SodiumTrendChart: View {
    let dailyTotals: [(date: Date, milligrams: Double)]
    let targetMilligrams: Int

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Sodium", subtitle: "Daily total against your target")

                if dailyTotals.isEmpty {
                    Text("No sodium recorded yet.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Chart {
                        ForEach(dailyTotals, id: \.date) { entry in
                            BarMark(
                                x: .value("Date", entry.date, unit: .day),
                                y: .value("mg", entry.milligrams)
                            )
                            .foregroundStyle(
                                entry.milligrams > Double(targetMilligrams)
                                    ? Theme.statusElevated
                                    : Theme.statusNormal
                            )
                        }
                        RuleMark(y: .value("Target", targetMilligrams))
                            .foregroundStyle(Theme.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Target \(targetMilligrams) mg")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Daily sodium against a target of \(targetMilligrams) milligrams")
                }
            }
        }
    }
}

struct AdherenceChart: View {
    let weekly: [(week: Date, percentage: Double)]

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Adherence", subtitle: "Doses taken each week")

                if weekly.isEmpty {
                    Text("No dose history yet.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Chart(weekly, id: \.week) { entry in
                        BarMark(
                            x: .value("Week", entry.week, unit: .weekOfYear),
                            y: .value("Percent", entry.percentage)
                        )
                        .foregroundStyle(entry.percentage >= 80 ? Theme.statusNormal : Theme.statusElevated)
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 160)
                    .accessibilityLabel("Weekly medication adherence percentage")
                }
            }
        }
    }
}

struct ChartLegendItem: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
