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

struct WeightHistoryView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \LifestyleEntry.recordedAt, order: .reverse) private var allEntries: [LifestyleEntry]
    @State private var isAdding = false

    private var weights: [LifestyleEntry] {
        allEntries.filter { $0.profileID == app.activeProfile.id && $0.kind == .weight }
    }

    var body: some View {
        Group {
            if weights.isEmpty {
                EmptyStateView(
                    symbol: "scalemass",
                    title: "No weight recorded",
                    message: "Weight changes and blood pressure often move together, so it is worth tracking.",
                    actionTitle: "Add weight",
                    action: { isAdding = true }
                )
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        currentCard
                        if weights.count >= 2 { trendCard }
                        historyList
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Weight")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add weight")
            }
        }
        .sheet(isPresented: $isAdding) { AddWeightView() }
    }

    private var currentCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(title: "Current")
                if let latest = weights.first {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.1f", latest.value))
                            .font(Theme.number(36, weight: .bold))
                        Text("kg").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if weights.count >= 2 {
                            let delta = latest.value - weights[1].value
                            Label(
                                String(format: "%+.1f", delta),
                                systemImage: delta > 0 ? "arrow.up" : "arrow.down"
                            )
                            .font(.subheadline)
                            .foregroundStyle(delta > 0 ? Theme.statusElevated : Theme.statusNormal)
                        }
                    }
                    Text(latest.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var trendCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Trend")
                Chart(weights.reversed()) { entry in
                    LineMark(
                        x: .value("Date", entry.recordedAt),
                        y: .value("kg", entry.value)
                    )
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                }
                .frame(height: 160)
                .accessibilityLabel("Weight trend over time")
            }
        }
    }

    private var historyList: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(title: "History")
                ForEach(weights.prefix(30)) { entry in
                    HStack {
                        Text(entry.recordedAt.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f kg", entry.value)).monospacedDigit()
                    }
                    .font(.subheadline)
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
        Group {
            if mine.isEmpty {
                EmptyStateView(
                    symbol: "figure.walk",
                    title: "No activity logged",
                    message: "Apple Health covers steps and workouts automatically. Log here for anything it missed.",
                    actionTitle: "Add activity",
                    action: { isAdding = true }
                )
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        CardView {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                SectionHeader(title: "This week", subtitle: "Logged manually")
                                StatTile(
                                    title: "Active minutes",
                                    value: "\(weekMinutes)",
                                    caption: "150/week is the usual guidance",
                                    tint: weekMinutes >= 150 ? Theme.statusNormal : Theme.textPrimary
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            SectionHeader(title: "Recent")
                            ForEach(mine.prefix(40)) { entry in
                                CardView(padding: Theme.Spacing.md) {
                                    HStack {
                                        Image(systemName: entry.kind.symbol)
                                            .foregroundStyle(Theme.accent)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.kind.label).font(.subheadline.weight(.medium))
                                            Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text("\(entry.minutes) min").font(.subheadline)
                                            if let km = entry.distanceKilometres {
                                                Text(String(format: "%.1f km", km))
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.textTertiary)
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
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add activity")
            }
        }
        .sheet(isPresented: $isAdding) { AddActivityView() }
    }
}
