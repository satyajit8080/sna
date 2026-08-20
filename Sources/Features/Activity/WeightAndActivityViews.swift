import Charts
import SwiftData
import SwiftUI

// MARK: - Weight

struct AddWeightView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \LifestyleEntry.recordedAt, order: .reverse) private var allEntries: [LifestyleEntry]

    @State private var kilograms = 70.0
    @State private var recordedAt = Date.now
    @State private var usesPounds = Locale.current.measurementSystem != .metric

    private var previous: LifestyleEntry? {
        allEntries.first { $0.profileID == app.activeProfile.id && $0.kind == .weight }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Weight")
                        Spacer()
                        Text(displayValue)
                            .font(Theme.number(26, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Slider(value: $kilograms, in: 30...250, step: 0.1)
                    Picker("Units", selection: $usesPounds) {
                        Text("kg").tag(false)
                        Text("lb").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    if let previous {
                        let delta = kilograms - previous.value
                        Text(deltaText(delta, since: previous.recordedAt))
                    }
                }

                Section("When") {
                    DatePicker("Time", selection: $recordedAt, in: ...Date.now)
                }
            }
            .navigationTitle("Add weight")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear { if let previous { kilograms = previous.value } }
        }
    }

    /// Stored in kilograms always; pounds is a display choice. Storing whatever
    /// unit was on screen would make every historical comparison unreliable.
    private var displayValue: String {
        usesPounds
            ? String(format: "%.1f lb", kilograms * 2.20462)
            : String(format: "%.1f kg", kilograms)
    }

    private func deltaText(_ delta: Double, since: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: since, relativeTo: .now)
        if abs(delta) < 0.05 { return "Unchanged since \(when)." }
        let amount = usesPounds
            ? String(format: "%.1f lb", abs(delta) * 2.20462)
            : String(format: "%.1f kg", abs(delta))
        return "\(delta > 0 ? "Up" : "Down") \(amount) since \(when)."
    }

    private func save() {
        let entry = LifestyleEntry(
            profileID: app.activeProfile.id,
            kind: .weight,
            value: kilograms,
            unit: "kg",
            label: "Weight",
            recordedAt: recordedAt,
            provenance: .userEntered
        )
        context.insert(entry)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

/// Weight, implemented from the Figma design.
struct WeightHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LifestyleEntry.recordedAt, order: .reverse) private var allEntries: [LifestyleEntry]
    @State private var isAdding = false

    private var weights: [LifestyleEntry] {
        allEntries.filter { $0.profileID == app.activeProfile.id && $0.kind == .weight }
    }

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Weight",
                showsBack: true,
                onBack: { dismiss() },
                trailing: [("plus", { isAdding = true })]
            )

            currentCard

            if weights.count >= 2 {
                Text("Trend")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                trendCard
            }

            if !weights.isEmpty {
                Text("History")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                historyList
            }

            BrandPrimaryButton(title: "Add Weight") { isAdding = true }
        }
        .sheet(isPresented: $isAdding) { AddWeightView() }
    }

    private var currentCard: some View {
        BrandCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current Weight")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)

                    if let latest = weights.first {
                        Text(app.settings.displayWeight(latest.value))
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)

                        Text(latest.recordedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)

                        if weights.count >= 2 {
                            let delta = latest.value - weights[1].value
                            HStack(spacing: 6) {
                                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 10, weight: .bold))
                                Text(String(format: "%.1f kg since last time", abs(delta)))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            // Neither direction is inherently good: what matters
                            // depends on the person's situation, so both use the
                            // neutral accent rather than red or green.
                            .foregroundStyle(Brand.accent)
                            .padding(.top, 2)
                        }
                    } else {
                        Text("—")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Brand.textSecondary)
                        Text("Weight and blood pressure often move together, so it is worth tracking.")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
                BrandIconTile(symbol: "scalemass.fill", tint: Brand.weight, size: 55)
            }
        }
    }

    private var trendCard: some View {
        BrandCard(padding: 16) {
            Chart(weights.reversed()) { entry in
                LineMark(
                    x: .value("Date", entry.recordedAt),
                    y: .value("kg", entry.value)
                )
                .foregroundStyle(Brand.weight)
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Date", entry.recordedAt),
                    y: .value("kg", entry.value)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Brand.weight.opacity(0.25), Brand.weight.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 170)
            .accessibilityLabel("Weight trend over time")
        }
    }

    private var historyList: some View {
        VStack(spacing: 12) {
            ForEach(weights.prefix(30)) { entry in
                BrandCard(padding: 12) {
                    HStack(spacing: 14) {
                        BrandIconTile(symbol: "scalemass.fill", tint: Brand.weight, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.settings.displayWeight(entry.value))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Activity

struct AddActivityView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ActivityKind = .walk
    @State private var minutes = 30
    @State private var distance: Double?
    @State private var startedAt = Date.now
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    Picker("Type", selection: $kind) {
                        ForEach(ActivityKind.allCases, id: \.self) {
                            Label($0.label, systemImage: $0.symbol).tag($0)
                        }
                    }
                    Stepper("\(minutes) minutes", value: $minutes, in: 1...600, step: 5)
                    HStack {
                        Text("Distance")
                        Spacer()
                        TextField("Optional", value: $distance, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("km").foregroundStyle(Theme.textSecondary)
                    }
                }

                Section("When") {
                    DatePicker("Started", selection: $startedAt, in: ...Date.now)
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text("""
                    Activity read automatically from Apple Health is shown on Home. \
                    Log here for anything Health did not capture.
                    """)
                }
            }
            .navigationTitle("Add activity")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        let entry = ActivityEntry(
            profileID: app.activeProfile.id,
            kind: kind,
            minutes: minutes,
            startedAt: startedAt,
            distanceKilometres: distance,
            notes: notes.isEmpty ? nil : notes
        )
        context.insert(entry)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

struct ActivityHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ActivityEntry.startedAt, order: .reverse) private var allActivity: [ActivityEntry]
    @State private var isAdding = false

    private var mine: [ActivityEntry] {
        allActivity.filter { $0.profileID == app.activeProfile.id }
    }

    private var weekMinutes: Int {
        mine.filter { $0.startedAt > Date.now.addingTimeInterval(-7 * 86_400) }
            .reduce(0) { $0 + $1.minutes }
    }

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Activity",
                showsBack: true,
                onBack: { dismiss() },
                trailing: [("plus", { isAdding = true })]
            )

            BrandCard {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This week")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(weekMinutes)")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(Brand.textPrimary)
                            Text("min")
                                .font(.system(size: 14))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        // 150 minutes a week is the standard guidance, so it is
                        // a target rather than an app invention.
                        BrandProgressBar(
                            fraction: Double(weekMinutes) / 150,
                            tint: weekMinutes >= 150 ? Brand.accent : Brand.progress
                        )
                        .padding(.top, 4)
                        Text("of 150 minutes — the usual weekly guidance")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Spacer(minLength: 0)
                    BrandIconTile(symbol: "figure.walk", tint: Brand.accent, size: 55)
                }
            }

            BrandCard(padding: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                    Text("""
                    Steps and workouts from Apple Health appear on Home. Log here for \
                    anything Health did not capture.
                    """)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if mine.isEmpty {
                BrandCard {
                    Text("Nothing logged yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                }
            } else {
                Text("Recent")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)

                VStack(spacing: 12) {
                    ForEach(mine.prefix(40)) { entry in
                        BrandCard(padding: 12) {
                            HStack(spacing: 14) {
                                BrandIconTile(symbol: entry.kind.symbol, tint: Brand.accent, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.kind.label)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Brand.textPrimary)
                                    Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Brand.textSecondary)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(entry.minutes) min")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Brand.textPrimary)
                                    if let km = entry.distanceKilometres {
                                        Text(String(format: "%.1f km", km))
                                            .font(.system(size: 12))
                                            .foregroundStyle(Brand.textSecondary)
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                context.delete(entry)
                                try? context.save()
                            }
                        }
                    }
                }
            }

            BrandPrimaryButton(title: "Add Activity") { isAdding = true }
        }
        .sheet(isPresented: $isAdding) { AddActivityView() }
    }
}
