import SwiftData
import SwiftUI

struct AddSymptomView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Set when logging straight after a reading, so the two can be correlated.
    var relatedReadingID: UUID?

    @State private var selected: Set<SymptomKind> = []
    @State private var severity: SymptomSeverity = .mild
    @State private var recordedAt = Date.now
    @State private var notes = ""

    private var hasRedFlag: Bool { selected.contains(where: \.isRedFlag) }

    var body: some View {
        NavigationStack {
            Form {
                Section("What are you feeling?") {
                    ForEach(SymptomKind.allCases, id: \.self) { kind in
                        Button {
                            toggle(kind)
                        } label: {
                            HStack {
                                Label(kind.label, systemImage: kind.symbol)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if selected.contains(kind) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }

                if hasRedFlag {
                    Section {
                        // Deterministic wording. This is guidance about seeking
                        // care, not an assessment of the user's situation — the
                        // app never decides urgency from symptoms alone.
                        Label {
                            Text("""
                            Chest discomfort, breathlessness or sudden vision changes \
                            are worth medical attention rather than logging alone. If \
                            they are severe or came on suddenly, seek care now.
                            """)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(Theme.statusSevere)
                    }
                }

                Section("How bad is it?") {
                    Picker("Severity", selection: $severity) {
                        ForEach(SymptomSeverity.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("When") {
                    DatePicker("Time", selection: $recordedAt, in: ...Date.now)
                }

                Section("Notes") {
                    TextField("Anything else worth remembering", text: $notes, axis: .vertical)
                        .lineLimit(1...5)
                }
            }
            .navigationTitle("Log symptoms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(selected.isEmpty)
                }
            }
        }
    }

    private func toggle(_ kind: SymptomKind) {
        if selected.contains(kind) { selected.remove(kind) } else { selected.insert(kind) }
        Haptics.selection()
    }

    private func save() {
        // One record per symptom, so each can be counted and trended on its own.
        for kind in selected {
            let entry = SymptomEntry(
                profileID: app.activeProfile.id,
                kind: kind,
                severity: severity,
                recordedAt: recordedAt,
                notes: notes.isEmpty ? nil : notes,
                relatedReadingID: relatedReadingID
            )
            context.insert(entry)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

struct SymptomHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \SymptomEntry.recordedAt, order: .reverse) private var allSymptoms: [SymptomEntry]

    @State private var isAdding = false

    private var mine: [SymptomEntry] {
        allSymptoms.filter { $0.profileID == app.activeProfile.id }
    }

    private var last90: [SymptomEntry] {
        mine.filter { $0.recordedAt > Date.now.addingTimeInterval(-90 * 86_400) }
    }

    var body: some View {
        Group {
            if mine.isEmpty {
                EmptyStateView(
                    symbol: "list.bullet.clipboard",
                    title: "No symptoms logged",
                    message: "Logging how you feel alongside your readings makes patterns easier to spot.",
                    actionTitle: "Log a symptom",
                    action: { isAdding = true }
                )
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        frequencyCard
                        recentList
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Symptoms")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Log a symptom")
            }
        }
        .sheet(isPresented: $isAdding) { AddSymptomView() }
    }

    private var frequencyCard: some View {
        let grouped = Dictionary(grouping: last90, by: \.kind)
            .map { (kind: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        return CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Most frequent", subtitle: "Last 90 days")
                if grouped.isEmpty {
                    Text("Nothing logged in the last 90 days.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(grouped, id: \.kind) { item in
                        HStack {
                            Label(item.kind.label, systemImage: item.kind.symbol)
                            Spacer()
                            Text("\(item.count)×").foregroundStyle(Theme.textSecondary)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Recent")
            ForEach(mine.prefix(50)) { entry in
                CardView(padding: Theme.Spacing.md) {
                    HStack {
                        Image(systemName: entry.kind.symbol)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.kind.label).font(.subheadline.weight(.medium))
                            Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                            if let notes = entry.notes, !notes.isEmpty {
                                Text(notes).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer()
                        Text(entry.severity.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(severityColor(entry.severity).opacity(0.15))
                            .foregroundStyle(severityColor(entry.severity))
                            .clipShape(Capsule())
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

    private func severityColor(_ severity: SymptomSeverity) -> Color {
        switch severity {
        case .mild: Theme.statusNormal
        case .moderate: Theme.statusElevated
        case .severe: Theme.statusModerate
        }
    }
}
