import Charts
import SwiftData
import SwiftUI

/// One history across every kind of record.
///
/// History left the tab bar, so it has to earn its place from Home and from each
/// feature screen — which means being genuinely more useful than a list of
/// readings. Every entry the app stores appears here on one timeline, filterable
/// and searchable, over a range the user chooses.
struct UnifiedHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines

    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query(sort: \LifestyleEntry.recordedAt, order: .reverse) private var allLifestyle: [LifestyleEntry]
    @Query(sort: \MedicationDose.scheduledFor, order: .reverse) private var allDoses: [MedicationDose]
    @Query private var allMedications: [Medication]
    @Query(sort: \SymptomEntry.recordedAt, order: .reverse) private var allSymptoms: [SymptomEntry]
    @Query(sort: \ActivityEntry.startedAt, order: .reverse) private var allActivity: [ActivityEntry]
    @Query(sort: \MedicalDocument.importedAt, order: .reverse) private var allDocuments: [MedicalDocument]
    @Query(sort: \Appointment.scheduledFor, order: .reverse) private var allAppointments: [Appointment]

    @State private var range: DateRange = .month
    @State private var customStart = Date.now.addingTimeInterval(-30 * 86_400)
    @State private var customEnd = Date.now
    @State private var filters: Set<HistoryKind> = Set(HistoryKind.allCases)
    @State private var search = ""
    @State private var editingReading: BPReading?

    enum DateRange: String, CaseIterable, Identifiable {
        case week, month, quarter, year, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .week: "7d"
            case .month: "30d"
            case .quarter: "90d"
            case .year: "1y"
            case .custom: "Custom"
            }
        }

        var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            case .year: 365
            case .custom: nil
            }
        }
    }

    private var interval: DateInterval {
        if let days = range.days {
            return DateInterval(start: Date.now.addingTimeInterval(-Double(days) * 86_400), end: .now)
        }
        // Guard against an inverted custom range rather than showing nothing.
        return customStart <= customEnd
            ? DateInterval(start: customStart, end: customEnd)
            : DateInterval(start: customEnd, end: customStart)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            content
        }
        .background(Theme.background)
        .navigationTitle("History")
        .searchable(text: $search, prompt: "Search notes and labels")
        .sheet(item: $editingReading) { EditBPView(reading: $0) }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Picker("Range", selection: $range) {
                ForEach(DateRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if range == .custom {
                HStack {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
                .font(.caption)
                .labelsHidden()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(HistoryKind.allCases) { kind in
                        FilterChip(
                            kind: kind,
                            isOn: filters.contains(kind),
                            count: count(for: kind)
                        ) {
                            if filters.contains(kind) { filters.remove(kind) }
                            else { filters.insert(kind) }
                            Haptics.selection()
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Content

    private var content: some View {
        let entries = filteredEntries

        return ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                if filters.contains(.bloodPressure) {
                    let readings = readingsInRange
                    if readings.count >= 2 {
                        BPTrendChart(readings: readings, days: rangeDays)

                        // The BP-specific analysis — AM/PM, home vs clinic,
                        // variability, derived metrics — lives in its own screen
                        // rather than being duplicated here.
                        NavigationLink { HistoryView() } label: {
                            CardView(padding: Theme.Spacing.md) {
                                HStack {
                                    Label("Blood pressure analysis", systemImage: "chart.xyaxis.line")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if entries.isEmpty {
                    EmptyStateView(
                        symbol: "clock.arrow.circlepath",
                        title: search.isEmpty ? "Nothing in this range" : "No matches",
                        message: search.isEmpty
                            ? "Try a longer date range, or turn more categories back on."
                            : "No entries match “\(search)”."
                    )
                } else {
                    ForEach(groupedByDay(entries), id: \.day) { group in
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            SectionHeader(
                                title: BPGrouping.title(for: group.day, granularity: .daily),
                                subtitle: "\(group.entries.count) entr\(group.entries.count == 1 ? "y" : "ies")"
                            )
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry) {
                                    if case .bloodPressure(let reading) = entry.payload {
                                        editingReading = reading
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private var rangeDays: Int {
        range.days ?? max(1, Calendar.current.dateComponents(
            [.day], from: interval.start, to: interval.end
        ).day ?? 30)
    }

    private var readingsInRange: [BPReading] {
        allReadings.filter {
            $0.profileID == app.activeProfile.id && interval.contains($0.recordedAt)
        }
    }

    // MARK: - Assembly

    /// Every record type folded into one comparable list.
    private var filteredEntries: [HistoryEntry] {
        var entries: [HistoryEntry] = []
        let profileID = app.activeProfile.id

        if filters.contains(.bloodPressure) {
            entries += readingsInRange.map {
                HistoryEntry(
                    date: $0.recordedAt,
                    kind: .bloodPressure,
                    title: "\($0.systolic)/\($0.diastolic)",
                    detail: [guidelines.category(for: $0).label, $0.source.label]
                        .joined(separator: " · "),
                    note: $0.notes,
                    payload: .bloodPressure($0)
                )
            }
        }

        if filters.contains(.weight) {
            entries += allLifestyle
                .filter { $0.profileID == profileID && $0.kind == .weight && interval.contains($0.recordedAt) }
                .map {
                    HistoryEntry(
                        date: $0.recordedAt, kind: .weight,
                        title: String(format: "%.1f kg", $0.value),
                        detail: "Weight", note: nil, payload: .other
                    )
                }
        }

        if filters.contains(.food) {
            entries += allLifestyle
                .filter { $0.profileID == profileID && $0.kind == .sodium && interval.contains($0.recordedAt) }
                .map {
                    HistoryEntry(
                        date: $0.recordedAt, kind: .food,
                        title: $0.label,
                        detail: "\(Int($0.value)) mg sodium" + ($0.isEstimate ? " · estimate" : ""),
                        note: nil, payload: .other
                    )
                }
        }

        if filters.contains(.medicine) {
            let byID = Dictionary(uniqueKeysWithValues: allMedications.map { ($0.id, $0) })
            entries += allDoses
                .filter { $0.profileID == profileID && interval.contains($0.scheduledFor) }
                .map {
                    HistoryEntry(
                        date: $0.recordedAt ?? $0.scheduledFor, kind: .medicine,
                        title: byID[$0.medicationID]?.name ?? "Medicine",
                        detail: $0.status.label, note: nil, payload: .other
                    )
                }
        }

        if filters.contains(.symptoms) {
            entries += allSymptoms
                .filter { $0.profileID == profileID && interval.contains($0.recordedAt) }
                .map {
                    HistoryEntry(
                        date: $0.recordedAt, kind: .symptoms,
                        title: $0.kind.label, detail: $0.severity.label,
                        note: $0.notes, payload: .other
                    )
                }
        }

        if filters.contains(.activity) {
            entries += allActivity
                .filter { $0.profileID == profileID && interval.contains($0.startedAt) }
                .map {
                    HistoryEntry(
                        date: $0.startedAt, kind: .activity,
                        title: $0.kind.label, detail: "\($0.minutes) min",
                        note: $0.notes, payload: .other
                    )
                }
        }

        if filters.contains(.reports) {
            entries += allDocuments
                .filter { $0.profileID == profileID && interval.contains($0.importedAt) }
                .map {
                    HistoryEntry(
                        date: $0.importedAt, kind: .reports,
                        title: $0.title, detail: $0.kind.label,
                        note: nil, payload: .other
                    )
                }
        }

        if filters.contains(.appointments) {
            entries += allAppointments
                .filter { $0.profileID == profileID && interval.contains($0.scheduledFor) }
                .map {
                    HistoryEntry(
                        date: $0.scheduledFor, kind: .appointments,
                        title: $0.doctorName, detail: $0.specialty ?? "Appointment",
                        note: $0.notes, payload: .other
                    )
                }
        }

        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            entries = entries.filter {
                $0.title.lowercased().contains(query)
                    || $0.detail.lowercased().contains(query)
                    || ($0.note?.lowercased().contains(query) ?? false)
            }
        }

        return entries.sorted { $0.date > $1.date }
    }

    private func count(for kind: HistoryKind) -> Int {
        let profileID = app.activeProfile.id
        switch kind {
        case .bloodPressure: return readingsInRange.count
        case .weight:
            return allLifestyle.filter {
                $0.profileID == profileID && $0.kind == .weight && interval.contains($0.recordedAt)
            }.count
        case .food:
            return allLifestyle.filter {
                $0.profileID == profileID && $0.kind == .sodium && interval.contains($0.recordedAt)
            }.count
        case .medicine:
            return allDoses.filter {
                $0.profileID == profileID && interval.contains($0.scheduledFor)
            }.count
        case .symptoms:
            return allSymptoms.filter {
                $0.profileID == profileID && interval.contains($0.recordedAt)
            }.count
        case .activity:
            return allActivity.filter {
                $0.profileID == profileID && interval.contains($0.startedAt)
            }.count
        case .reports:
            return allDocuments.filter {
                $0.profileID == profileID && interval.contains($0.importedAt)
            }.count
        case .appointments:
            return allAppointments.filter {
                $0.profileID == profileID && interval.contains($0.scheduledFor)
            }.count
        }
    }

    private func groupedByDay(_ entries: [HistoryEntry]) -> [(day: Date, entries: [HistoryEntry])] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

// MARK: - Types

enum HistoryKind: String, CaseIterable, Identifiable {
    case bloodPressure, weight, food, medicine, symptoms, activity, reports, appointments

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bloodPressure: "BP"
        case .weight: "Weight"
        case .food: "Food"
        case .medicine: "Medicine"
        case .symptoms: "Symptoms"
        case .activity: "Activity"
        case .reports: "Reports"
        case .appointments: "Visits"
        }
    }

    var symbol: String {
        switch self {
        case .bloodPressure: "heart.text.square"
        case .weight: "scalemass"
        case .food: "fork.knife"
        case .medicine: "pills"
        case .symptoms: "list.bullet.clipboard"
        case .activity: "figure.walk"
        case .reports: "doc.text"
        case .appointments: "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .bloodPressure: Theme.systolicColor
        case .weight: Theme.diastolicColor
        case .food: Theme.statusElevated
        case .medicine: Theme.accent
        case .symptoms: Theme.statusModerate
        case .activity: Theme.statusNormal
        case .reports: Theme.textSecondary
        case .appointments: Theme.pulseColor
        }
    }
}

struct HistoryEntry: Identifiable {
    enum Payload {
        case bloodPressure(BPReading)
        case other
    }

    let id = UUID()
    let date: Date
    let kind: HistoryKind
    let title: String
    let detail: String
    let note: String?
    let payload: Payload
}

struct FilterChip: View {
    let kind: HistoryKind
    let isOn: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.caption2)
                Text(kind.label).font(.caption.weight(.medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isOn ? .white.opacity(0.8) : Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isOn ? kind.tint : Theme.surface)
            .foregroundStyle(isOn ? .white : Theme.textSecondary)
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(isOn ? .clear : Theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.label), \(count) entries, \(isOn ? "shown" : "hidden")")
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            CardView(padding: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: entry.kind.symbol)
                        .font(.subheadline)
                        .foregroundStyle(entry.kind.tint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline.weight(.medium))
                        Text(entry.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                        if let note = entry.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
