import Charts
import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]

    @State private var section: Section = .trends
    @State private var window = 30
    @State private var granularity: BPGrouping.Granularity = .daily
    @State private var editing: BPReading?

    enum Section: String, CaseIterable { case trends, readings, analysis, metrics }

    private var readings: [BPReading] {
        allReadings.filter { $0.profileID == app.activeProfile.id }
    }

    private var windowed: [BPReading] {
        BPStatistics.within(readings, days: window)
    }

    var body: some View {
        Group {
            if readings.isEmpty {
                EmptyStateView(
                    symbol: "chart.xyaxis.line",
                    title: "Nothing to chart yet",
                    message: "Once you have a few readings, your trends and patterns appear here."
                )
            } else {
                content
            }
        }
        .background(Theme.background)
        .navigationTitle("History")
        .sheet(item: $editing) { EditBPView(reading: $0) }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    switch section {
                    case .trends: trendsSection
                    case .readings: readingsSection
                    case .analysis: analysisSection
                    case .metrics: metricsSection
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
    }

    // MARK: - Trends

    private var trendsSection: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Picker("Window", selection: $window) {
                ForEach([7, 14, 30, 90], id: \.self) { Text("\($0)d").tag($0) }
            }
            .pickerStyle(.segmented)

            BPTrendChart(readings: windowed, days: window)

            if let extremes = BPGrouping.extremes(windowed) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Range", subtitle: "Last \(window) days")
                        HStack(spacing: Theme.Spacing.md) {
                            StatTile(
                                title: "Highest",
                                value: "\(extremes.highest.systolic)/\(extremes.highest.diastolic)",
                                caption: extremes.highest.recordedAt.formatted(date: .abbreviated, time: .omitted),
                                tint: Theme.statusModerate
                            )
                            StatTile(
                                title: "Lowest",
                                value: "\(extremes.lowest.systolic)/\(extremes.lowest.diastolic)",
                                caption: extremes.lowest.recordedAt.formatted(date: .abbreviated, time: .omitted),
                                tint: Theme.statusNormal
                            )
                        }
                    }
                }
            }

            PulseTrendChart(readings: windowed)
        }
    }

    // MARK: - Readings, grouped

    private var readingsSection: some View {
        VStack(spacing: Theme.Spacing.md) {
            Picker("Group by", selection: $granularity) {
                ForEach(BPGrouping.Granularity.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.segmented)

            ForEach(BPGrouping.bucket(readings, by: granularity)) { bucket in
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack {
                            SectionHeader(
                                title: BPGrouping.title(for: bucket.start, granularity: granularity),
                                subtitle: "\(bucket.average.count) reading\(bucket.average.count == 1 ? "" : "s")"
                            )
                            Spacer()
                            Text("\(bucket.average.systolic)/\(bucket.average.diastolic)")
                                .font(Theme.number(18, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityLabel("Average \(bucket.average.systolic) over \(bucket.average.diastolic)")
                        }

                        Divider()

                        ForEach(bucket.readings) { reading in
                            Button {
                                editing = reading
                            } label: {
                                ReadingRow(reading: reading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Analysis

    private var analysisSection: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let comparison = BPStatistics.morningVsEvening(readings) {
                ComparisonCard(
                    title: "Morning vs evening",
                    subtitle: nil,
                    firstLabel: "Morning",
                    secondLabel: "Evening",
                    comparison: comparison,
                    narrative: morningNarrative(comparison)
                )
            }

            if let comparison = BPStatistics.homeVsClinic(readings) {
                ComparisonCard(
                    title: "Home vs clinic",
                    subtitle: "A gap can suggest a white-coat pattern",
                    firstLabel: "Home",
                    secondLabel: "Clinic",
                    comparison: comparison,
                    narrative: "This is a pattern in your own numbers, not a diagnosis. Your doctor interprets it."
                )
            }

            if let variability = BPStatistics.variability(readings) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        SectionHeader(
                            title: "Variability",
                            subtitle: "How much your readings move around"
                        )
                        HStack {
                            StatTile(
                                title: "Systolic spread",
                                value: String(format: "±%.1f", variability.systolicSD)
                            )
                            StatTile(
                                title: "Diastolic spread",
                                value: String(format: "±%.1f", variability.diastolicSD)
                            )
                        }
                        Text("Standard deviation across all your readings. Lower means steadier.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            if readings.count < 5 {
                CardView {
                    Text("Patterns get more reliable after about a week of regular readings.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func morningNarrative(_ comparison: BPStatistics.Comparison) -> String {
        let delta = comparison.first.systolic - comparison.second.systolic
        if delta >= 5 {
            return "Your mornings run about \(delta) points higher than your evenings."
        } else if delta <= -5 {
            return "Your evenings run about \(abs(delta)) points higher than your mornings."
        }
        return "Your mornings and evenings are broadly similar."
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let latest = readings.first {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Latest reading", subtitle: "Derived values")
                        HStack {
                            StatTile(
                                title: "MAP",
                                value: String(format: "%.0f", latest.meanArterialPressure),
                                caption: "Mean arterial pressure"
                            )
                            StatTile(
                                title: "Pulse pressure",
                                value: "\(latest.pulsePressure)",
                                caption: "Systolic minus diastolic"
                            )
                        }
                    }
                }
            }

            CardView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    SectionHeader(title: "Averages", subtitle: "Home readings only")
                    ForEach([7, 30, 90], id: \.self) { days in
                        HStack {
                            Text("\(days) days").foregroundStyle(Theme.textSecondary)
                            Spacer()
                            if let avg = BPStatistics.homeAverage(readings, days: days) {
                                Text("\(avg.systolic)/\(avg.diastolic)")
                                    .font(Theme.number(17, weight: .semibold))
                                Text("· \(avg.count)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            } else {
                                Text("No data").foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .font(.subheadline)
                    }
                }
            }

            if let health = app.health.snapshot.restingHeartRate {
                CardView {
                    StatTile(
                        title: "Resting heart rate",
                        value: "\(health) bpm",
                        caption: "From Apple Health",
                        tint: Theme.pulseColor
                    )
                }
            }
        }
    }
}

// MARK: - Rows and cards

struct ReadingRow: View {
    @Environment(GuidelineEngine.self) private var guidelines
    let reading: BPReading

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                BPValueView(systolic: reading.systolic, diastolic: reading.diastolic, size: 20)
                HStack(spacing: Theme.Spacing.xs) {
                    Text(reading.recordedAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text(reading.timeOfDay.label)
                    if reading.source != .manual {
                        Text("·")
                        Text(reading.source.label)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            CategoryBadge(category: guidelines.category(for: reading), compact: true)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }
}

struct ComparisonCard: View {
    let title: String
    let subtitle: String?
    let firstLabel: String
    let secondLabel: String
    let comparison: BPStatistics.Comparison
    let narrative: String

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: title, subtitle: subtitle)
                HStack {
                    StatTile(
                        title: firstLabel,
                        value: "\(comparison.first.systolic)/\(comparison.first.diastolic)",
                        caption: "\(comparison.first.count) readings"
                    )
                    StatTile(
                        title: secondLabel,
                        value: "\(comparison.second.systolic)/\(comparison.second.diastolic)",
                        caption: "\(comparison.second.count) readings"
                    )
                }
                Text(narrative)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
