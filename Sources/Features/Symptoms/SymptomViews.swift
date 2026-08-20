import SwiftData
import SwiftUI

struct AddSymptomView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Set when logging straight after a reading, so the two can be correlated.
    var relatedReadingID: UUID?
    /// Preselected when arriving from a tile on the symptoms grid.
    var preselected: SymptomKind?

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
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(selected.isEmpty)
                }
            }
            .onAppear {
                if let preselected { selected.insert(preselected) }
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

/// Symptoms, implemented from the Figma design: a tappable grid of the common
/// ones, then recent entries.
struct SymptomHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SymptomEntry.recordedAt, order: .reverse) private var allSymptoms: [SymptomEntry]

    @State private var quickLog: SymptomKind?
    @State private var isAdding = false

    /// The six shown as tiles. The rest are reachable through "Other".
    private let featured: [SymptomKind] = [
        .headache, .dizziness, .fatigue, .palpitations, .swelling, .other,
    ]

    private var mine: [SymptomEntry] {
        allSymptoms.filter { $0.profileID == app.activeProfile.id }
    }

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Symptoms",
                showsBack: true,
                onBack: { dismiss() },
                trailing: [("plus", { isAdding = true })]
            )

            BrandHeroCard(
                title: "How are you feeling?",
                message: "Track your symptoms to help your coach understand you better.",
                symbol: "heart.text.square.fill"
            )

            Text("Add New Symptom")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                spacing: 15
            ) {
                ForEach(featured, id: \.self) { kind in
                    Button { quickLog = kind } label: {
                        VStack(spacing: 12) {
                            BrandIconTile(symbol: kind.symbol, tint: tint(for: kind))
                            Text(kind.label)
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Brand.background)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Brand.cardStroke, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log \(kind.label)")
                }
            }

            BrandSectionHeader("Recent Symptoms")

            if mine.isEmpty {
                BrandCard {
                    Text("Nothing logged yet. Tap a symptom above to record one.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(mine.prefix(20)) { entry in
                        BrandCard(padding: 12) {
                            HStack(spacing: 14) {
                                BrandIconTile(
                                    symbol: entry.kind.symbol,
                                    tint: tint(for: entry.kind),
                                    size: 49
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.kind.label)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Brand.textPrimary)
                                    HStack(spacing: 8) {
                                        Text(entry.severity.label)
                                        Circle().fill(Brand.textSecondary).frame(width: 4, height: 4)
                                        Text(entry.recordedAt.formatted(
                                            .dateTime.month().day().hour().minute()
                                        ))
                                    }
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.textSecondary)
                                }
                                Spacer(minLength: 0)
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
        }
        .sheet(isPresented: $isAdding) { AddSymptomView() }
        .sheet(item: $quickLog) { kind in
            AddSymptomView(preselected: kind)
        }
    }

    /// Red-flag symptoms carry the warning colour so they stand apart in the
    /// grid — the same distinction `SafetyEngine` makes.
    private func tint(for kind: SymptomKind) -> Color {
        kind.isRedFlag ? Brand.restingHeartRate : Brand.accent
    }
}

extension SymptomKind: Identifiable {
    var id: String { rawValue }
}
