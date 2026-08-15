import SwiftUI
import Charts

struct ProgressHubView: View {
    @Environment(AppState.self) private var app
    @Environment(EntitlementStore.self) private var entitlements

    @State private var report: WeeklyReport?
    @State private var range = "week"
    @State private var history: History?
    @State private var weight: WeightSeries?
    @State private var showWeightEntry = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    weeklyReportCard
                    weightCard
                    rangePicker
                    caloriesCard
                    proteinCard
                    summaryCard
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.bg)
            .navigationTitle("Progress")
            .refreshable { await load() }
            .task { await load() }
            .task(id: range) { history = try? await APIClient.shared.history(range: range) }
            .sheet(isPresented: $showWeightEntry) {
                WeightEntrySheet(current: weight?.currentWeightKg ?? 70) { kg in
                    Task {
                        try? await APIClient.shared.logWeight(kg: kg)
                        await load()
                    }
                }
                .presentationDetents([.height(320)])
            }
        }
    }

    @ViewBuilder private var weeklyReportCard: some View {
        if entitlements.isPro {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Your Weekly Progress").font(.system(size: 16, weight: .semibold))

                if let report {
                    HStack(spacing: Theme.Space.m) {
                        metric("Weight",
                               report.weightChangeKg.map { ($0 > 0 ? "+" : "") + $0.formatted(.number.precision(.fractionLength(1))) + " kg" } ?? "—")
                        metric("Avg calories", report.avgCalories.map { "\($0)" } ?? "—")
                        metric("Protein", report.proteinPctOfTarget.map { "\($0)%" } ?? "—")
                        metric("Steps", report.steps > 0 ? "\(report.steps)" : "—")
                    }

                    Text(report.insight)
                        .font(.body_)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Log a few days this week and your report will appear here.")
                        .font(.caption_).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else {
            Button {
                Analytics.track(.premiumCTAClicked, ["source": "weekly_report"])
                entitlements.present(.report, source: "weekly_report")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Weekly AI progress report")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Weight, calories, protein and activity in one view.")
                            .font(.caption_).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Text("Premium")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption_).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        async let h = try? APIClient.shared.history(range: range)
        async let w = try? APIClient.shared.weight()
        history = await h
        weight = await w
        // 402 for free users is expected, not an error worth surfacing.
        if entitlements.isPro { report = try? await APIClient.shared.weeklyReport() }
    }

    // MARK: - Weight

    private var weightCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weight").font(.label).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text((weight?.currentWeightKg ?? 0).formatted(.number.precision(.fractionLength(1))))
                            .font(.bigNum)
                        Text("kg").font(.body_).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let change = totalChange {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(change > 0 ? "+\(change.formatted(.number.precision(.fractionLength(1))))"
                                        : change.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(changeColor(change))
                        Text("since start").font(.caption_).foregroundStyle(.secondary)
                    }
                }
            }

            if let logs = weight?.logs, logs.count > 1 {
                Chart {
                    ForEach(logs) { point in
                        LineMark(x: .value("Date", point.loggedOn), y: .value("kg", point.weightKg))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.accent)
                        AreaMark(x: .value("Date", point.loggedOn), y: .value("kg", point.weightKg))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [Theme.accentSoft, .clear],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    if let goal = weight?.goalWeightKg {
                        RuleMark(y: .value("Goal", goal))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, alignment: .leading) {
                                Text("Goal \(goal.formatted(.number.precision(.fractionLength(0))))kg")
                                    .font(.caption_).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 130)
            } else {
                Text("Log your weight a few times to see the trend.")
                    .font(.caption_).foregroundStyle(.tertiary)
            }

            Button("Log weight") { showWeightEntry = true }
                .buttonStyle(SecondaryButtonStyle())
        }
        .card()
    }

    private var totalChange: Double? {
        guard let current = weight?.currentWeightKg, let start = weight?.startWeightKg else { return nil }
        return current - start
    }

    /// Colour is goal-relative: losing weight when you want to lose is green.
    private func changeColor(_ change: Double) -> Color {
        guard let start = weight?.startWeightKg, let goal = weight?.goalWeightKg else { return .secondary }
        if abs(goal - start) < 0.5 { return .secondary }
        let wantsLoss = goal < start
        return (wantsLoss && change < 0) || (!wantsLoss && change > 0) ? Theme.accent : .secondary
    }

    // MARK: - History

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            Text("7 days").tag("week")
            Text("30 days").tag("month")
            Text("90 days").tag("quarter")
        }
        .pickerStyle(.segmented)
    }

    private var caloriesCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Calories").font(.label).foregroundStyle(.secondary)

            if let days = history?.nutrition, !days.isEmpty {
                Chart {
                    ForEach(days) { day in
                        BarMark(x: .value("Day", day.date), y: .value("Calories", day.calories))
                            .foregroundStyle(day.calories > app.dashboard.targets.calories ? Theme.danger : Theme.accent)
                            .cornerRadius(4)
                    }
                    RuleMark(y: .value("Target", app.dashboard.targets.calories))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                }
                .chartXAxis(.hidden)
                .frame(height: 150)
            } else {
                emptyChart
            }
        }
        .card()
    }

    private var proteinCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Protein").font(.label).foregroundStyle(.secondary)

            if let days = history?.nutrition, !days.isEmpty {
                Chart {
                    ForEach(days) { day in
                        BarMark(x: .value("Day", day.date), y: .value("Protein", day.protein_g))
                            .foregroundStyle(Theme.protein)
                            .cornerRadius(4)
                    }
                    RuleMark(y: .value("Target", app.dashboard.targets.protein_g))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
            } else {
                emptyChart
            }
        }
        .card()
    }

    private var summaryCard: some View {
        HStack(spacing: Theme.Space.m) {
            stat("Avg cal", "\(history?.averages.calories ?? 0)")
            stat("Avg protein", "\(history?.averages.protein_g ?? 0)g")
            stat("Days logged", "\(history?.daysLogged ?? 0)")
        }
        .card()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(label).font(.caption_).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyChart: some View {
        Text("Log a few days to see your trend here.")
            .font(.caption_).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 100)
    }
}

struct WeightEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var current: Double
    let onSave: (Double) -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Text("Today's weight").font(.title).padding(.top, Theme.Space.l)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(current.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                Text("kg").font(.title).foregroundStyle(.secondary)
            }

            Slider(value: $current, in: 35...250, step: 0.1).tint(Theme.accent)

            Button("Save") {
                Haptics.success()
                onSave(current)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Space.l)
    }
}
