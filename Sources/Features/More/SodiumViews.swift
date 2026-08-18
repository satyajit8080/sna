import Charts
import SwiftData
import SwiftUI

/// Sodium target, stored in defaults. Defaults to the AHA ideal rather than the
/// upper limit — the app should aim at the better number, not the tolerable one.
enum SodiumSettings {
    private static let key = "sodium.dailyTarget"

    static var dailyTarget: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            return stored > 0 ? stored : ManualSodiumEntry.ahaIdealDailyMilligrams
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum MealType: String, Codable, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack, drink

    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .breakfast: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .dinner: "moon.stars.fill"
        case .snack: "carrot.fill"
        case .drink: "cup.and.saucer.fill"
        }
    }
}

struct SodiumListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \LifestyleEntry.recordedAt, order: .reverse) private var allEntries: [LifestyleEntry]

    @State private var isAdding = false
    @State private var target = SodiumSettings.dailyTarget

    private var sodiumEntries: [LifestyleEntry] {
        allEntries.filter { $0.profileID == app.activeProfile.id && $0.kind == .sodium }
    }

    private var today: [LifestyleEntry] {
        sodiumEntries.filter { Calendar.current.isDateInToday($0.recordedAt) }
    }

    /// Daily totals for the trend chart. Days with no entries are omitted rather
    /// than charted as zero — no data is not the same as no sodium.
    private var dailyTotals: [(date: Date, milligrams: Double)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sodiumEntries.filter {
            $0.recordedAt > Date.now.addingTimeInterval(-14 * 86_400)
        }) { calendar.startOfDay(for: $0.recordedAt) }

        return grouped
            .map { (date: $0.key, milligrams: $0.value.reduce(0) { $0 + $1.value }) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                todayCard
                if !dailyTotals.isEmpty {
                    SodiumTrendChart(dailyTotals: dailyTotals, targetMilligrams: target)
                }
                entriesCard
                if !app.foodProvider.isAvailable { providerNotice }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle("Sodium")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add food")
            }
        }
        .sheet(isPresented: $isAdding) { AddSodiumView() }
    }

    private var todayCard: some View {
        let total = ManualSodiumEntry.dailyTotal(today)
        let fraction = min(total.total / Double(target), 1.5)

        return CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Today", subtitle: "Target \(target) mg")
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(total.total))")
                        .font(Theme.number(40, weight: .bold))
                        .foregroundStyle(total.total > Double(target)
                                         ? Theme.statusElevated : Theme.statusNormal)
                    Text("mg").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if total.containsEstimate { EstimateTag() }
                }
                ProgressView(value: fraction, total: 1.5)
                    .tint(total.total > Double(target) ? Theme.statusElevated : Theme.accent)
                Text(total.total > Double(target)
                     ? "You are over your target for today."
                     : "\(max(0, target - Int(total.total))) mg left before your target.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var entriesCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Today's entries")
                if today.isEmpty {
                    Text("Nothing recorded today.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(today) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                Text(entry.recordedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text("\(Int(entry.value)) mg").monospacedDigit()
                            if entry.isEstimate { EstimateTag() }
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
        }
    }

    private var providerNotice: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("No food database connected", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                Text("""
                Sodium is entered by hand from the nutrition label. A food data source can \
                be connected later without changing anything you have already recorded.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct AddSodiumView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var mealType: MealType = .lunch
    @State private var milligrams = 500.0
    @State private var calories: Int?
    @State private var recordedAt = Date.now
    @State private var entryMode: EntryMode = .label

    enum EntryMode: String, CaseIterable {
        case label, search
        var title: String { self == .label ? "From label" : "Search" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Entry mode", selection: $entryMode) {
                    ForEach(EntryMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if entryMode == .search {
                    searchSection
                } else {
                    labelSection
                }

                Section("When") {
                    Picker("Meal", selection: $mealType) {
                        ForEach(MealType.allCases, id: \.self) {
                            Label($0.label, systemImage: $0.symbol).tag($0)
                        }
                    }
                    DatePicker("Time", selection: $recordedAt, in: ...Date.now)
                }
            }
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var labelSection: some View {
        Group {
            Section("What did you eat?") {
                TextField("For example, tinned tomato soup", text: $label)
            }
            Section {
                HStack {
                    Text("Sodium")
                    Spacer()
                    Text("\(Int(milligrams)) mg")
                        .font(Theme.number(22, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Slider(value: $milligrams, in: 0...4000, step: 25)
                    .accessibilityValue("\(Int(milligrams)) milligrams")

                HStack {
                    Text("Calories")
                    Spacer()
                    TextField("Optional", value: $calories, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            } footer: {
                Text("""
                Read sodium off the nutrition label. Note that sodium and salt are different: \
                salt in grams times 400 gives roughly sodium in milligrams.
                """)
            }
        }
    }

    /// No provider is configured, so search returns nothing and says so. It does
    /// not invent food entries.
    private var searchSection: some View {
        Section {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "No food database",
                message: "Search is not available until a food data provider is connected. Enter sodium from the label instead.",
                actionTitle: "Enter from label",
                action: { entryMode = .label }
            )
        }
    }

    private func save() {
        let entry = LifestyleEntry(
            profileID: app.activeProfile.id,
            kind: .sodium,
            value: milligrams,
            unit: "mg",
            label: "\(mealType.label): \(label)",
            recordedAt: recordedAt,
            provenance: .userEntered
        )
        context.insert(entry)

        if let calories {
            let energy = LifestyleEntry(
                profileID: app.activeProfile.id,
                kind: .meal,
                value: Double(calories),
                unit: "kcal",
                label: label,
                recordedAt: recordedAt,
                provenance: .userEntered
            )
            context.insert(energy)
        }

        try? context.save()
        Haptics.success()
        dismiss()
    }
}
