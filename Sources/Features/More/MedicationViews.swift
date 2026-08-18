import Charts
import SwiftData
import SwiftUI

struct MedicationListView: View {
    @Environment(AppModel.self) private var app
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]
    @State private var isAdding = false
    @State private var editing: Medication?

    private var medications: [Medication] {
        allMedications.filter { $0.profileID == app.activeProfile.id && !$0.isArchived }
    }

    private var doses: [MedicationDose] {
        allDoses.filter { $0.profileID == app.activeProfile.id }
    }

    var body: some View {
        Group {
            if medications.isEmpty {
                EmptyStateView(
                    symbol: "pills",
                    title: "No medications",
                    message: "Add a medication to track doses and see your adherence over time.",
                    actionTitle: "Add medication",
                    action: { isAdding = true }
                )
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        adherenceSummary
                        ForEach(medications) { medication in
                            MedicationCard(
                                medication: medication,
                                doses: doses.filter { $0.medicationID == medication.id },
                                onEdit: { editing = medication }
                            )
                        }
                        if !weeklyAdherence.isEmpty {
                            AdherenceChart(weekly: weeklyAdherence)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Medications")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add medication")
            }
        }
        .sheet(isPresented: $isAdding) { MedicationEditorView(medication: nil) }
        .sheet(item: $editing) { MedicationEditorView(medication: $0) }
    }

    private var adherenceSummary: some View {
        let adherence = MedicationEngine.adherence(for: doses)
        return CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Overall adherence", subtitle: "Pending doses are not counted")
                HStack(spacing: Theme.Spacing.md) {
                    StatTile(
                        title: "Taken",
                        value: "\(adherence.taken)",
                        tint: Theme.statusNormal
                    )
                    StatTile(title: "Skipped", value: "\(adherence.skipped)")
                    StatTile(
                        title: "Missed",
                        value: "\(adherence.missed)",
                        tint: adherence.missed > 0 ? Theme.statusElevated : Theme.textPrimary
                    )
                    StatTile(title: "Pending", value: "\(adherence.scheduled)")
                }
                if let percent = adherence.percentage {
                    ProgressView(value: percent, total: 100)
                        .tint(percent >= 80 ? Theme.statusNormal : Theme.statusElevated)
                    Text("\(Int(percent))% of resolved doses taken")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// Adherence per calendar week, for the trend chart.
    private var weeklyAdherence: [(week: Date, percentage: Double)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: doses) { dose in
            calendar.dateInterval(of: .weekOfYear, for: dose.scheduledFor)?.start
                ?? calendar.startOfDay(for: dose.scheduledFor)
        }
        return grouped
            .compactMap { week, items -> (Date, Double)? in
                guard let percent = MedicationEngine.adherence(for: items).percentage else {
                    return nil
                }
                return (week, percent)
            }
            .sorted { $0.0 < $1.0 }
            .map { (week: $0.0, percentage: $0.1) }
    }
}

struct MedicationCard: View {
    @Environment(\.modelContext) private var context
    let medication: Medication
    let doses: [MedicationDose]
    let onEdit: () -> Void

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(medication.name).font(.headline)
                        Text("\(medication.dose) · \(medication.frequency.label)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(scheduleSummary)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if let percent = MedicationEngine.adherence(for: doses).percentage {
                        VStack(spacing: 0) {
                            Text("\(Int(percent))%")
                                .font(Theme.number(20, weight: .semibold))
                                .foregroundStyle(percent >= 80 ? Theme.statusNormal : Theme.statusElevated)
                            Text("taken").font(.caption2).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Button { record(.taken) } label: {
                        Label("Taken", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                    Button { record(.skipped) } label: {
                        Label("Skip", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Edit", action: onEdit)
                        .buttonStyle(.bordered)
                }
                .font(.subheadline)
                .controlSize(.small)

                if medication.needsRefill {
                    Label("Running low — time to refill", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.statusElevated)
                }

                if !recentDoses.isEmpty {
                    Divider()
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("Recent").font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(recentDoses) { dose in
                            Circle()
                                .fill(color(for: dose.status))
                                .frame(width: 10, height: 10)
                                .accessibilityLabel(dose.status.label)
                        }
                    }
                }
            }
        }
    }

    private var recentDoses: [MedicationDose] {
        Array(doses.sorted { $0.scheduledFor > $1.scheduledFor }.prefix(14))
    }

    private var scheduleSummary: String {
        let calendar = Calendar.current
        let times = medication.scheduleMinutes.compactMap { minutes -> String? in
            guard let date = calendar.date(
                byAdding: .minute, value: minutes, to: calendar.startOfDay(for: .now)
            ) else { return nil }
            return date.formatted(date: .omitted, time: .shortened)
        }
        return times.isEmpty ? "No schedule" : times.joined(separator: ", ")
    }

    private func color(for status: DoseStatus) -> Color {
        switch status {
        case .taken: Theme.statusNormal
        case .skipped: Theme.textTertiary
        case .missed: Theme.statusModerate
        case .scheduled: Theme.border
        }
    }

    private func record(_ status: DoseStatus) {
        let dose = MedicationDose(
            profileID: medication.profileID,
            medicationID: medication.id,
            scheduledFor: .now
        )
        dose.status = status
        dose.recordedAt = .now
        context.insert(dose)

        if status == .taken, let supply = medication.supplyCount, supply > 0 {
            medication.supplyCount = supply - 1
        }

        try? context.save()
        Haptics.success()
    }
}

/// Add or edit. One editor for both, so the two paths cannot drift apart.
struct MedicationEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let medication: Medication?

    @State private var name = ""
    @State private var dose = ""
    @State private var frequency: MedicationFrequency = .onceDaily
    @State private var times: [Date] = [Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now]
    @State private var remindersOn = true
    @State private var supply: Int?
    @State private var notes = ""
    @State private var isConfirmingDelete = false

    private var isEditing: Bool { medication != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Medication") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Dose, for example 5 mg", text: $dose)
                    Picker("Frequency", selection: $frequency) {
                        ForEach(MedicationFrequency.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                }

                if frequency != .asNeeded {
                    Section("Times") {
                        ForEach(times.indices, id: \.self) { index in
                            DatePicker(
                                "Dose \(index + 1)",
                                selection: $times[index],
                                displayedComponents: .hourAndMinute
                            )
                        }
                        Toggle("Remind me", isOn: $remindersOn)
                    }
                }

                Section("Supply") {
                    HStack {
                        Text("Doses remaining")
                        Spacer()
                        TextField("Optional", value: $supply, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text("""
                    BP Coach records what you take. It never suggests starting, stopping or \
                    changing a medication — that is between you and your doctor.
                    """)
                }

                if isEditing {
                    Section {
                        Button("Delete medication", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit medication" : "Add medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
            .onChange(of: frequency) { _, new in adjustTimes(for: new) }
            .confirmationDialog(
                "Delete this medication?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Its dose history is removed too. This cannot be undone.")
            }
        }
    }

    private func load() {
        guard let medication else { return }
        name = medication.name
        dose = medication.dose
        frequency = medication.frequency
        remindersOn = medication.remindersEnabled
        supply = medication.supplyCount
        notes = medication.notes ?? ""

        let calendar = Calendar.current
        times = medication.scheduleMinutes.compactMap {
            calendar.date(byAdding: .minute, value: $0, to: calendar.startOfDay(for: .now))
        }
        if times.isEmpty { times = [.now] }
    }

    /// Keeps the number of time pickers in step with the chosen frequency.
    private func adjustTimes(for frequency: MedicationFrequency) {
        let needed = frequency.dosesPerDay
        let calendar = Calendar.current
        while times.count < needed {
            let hour = min(8 + times.count * 6, 22)
            times.append(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now)
        }
        if times.count > needed { times = Array(times.prefix(needed)) }
    }

    private func save() {
        let calendar = Calendar.current
        let minutes = times.map {
            calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)
        }

        let target: Medication
        if let medication {
            target = medication
        } else {
            target = Medication(profileID: app.activeProfile.id, name: name, dose: dose)
            context.insert(target)
        }

        target.name = name
        target.dose = dose
        target.frequencyRaw = frequency.rawValue
        target.scheduleMinutes = minutes
        target.remindersEnabled = remindersOn
        target.supplyCount = supply
        target.refillReminderThreshold = supply != nil ? 7 : nil
        target.notes = notes.isEmpty ? nil : notes

        try? context.save()

        Task {
            if remindersOn && frequency != .asNeeded {
                await NotificationEngine.shared.requestAuthorization()
                await NotificationEngine.shared.rescheduleMedication(
                    medicationID: target.id,
                    name: target.name,
                    dose: target.dose,
                    scheduleMinutes: minutes
                )
            } else {
                NotificationEngine.shared.cancelMedication(target.id)
            }
        }

        Haptics.success()
        dismiss()
    }

    private func delete() {
        guard let medication else { return }
        NotificationEngine.shared.cancelMedication(medication.id)

        let id = medication.id
        if let doses = try? context.fetch(FetchDescriptor<MedicationDose>()) {
            for dose in doses where dose.medicationID == id {
                context.delete(dose)
            }
        }
        context.delete(medication)
        try? context.save()
        dismiss()
    }
}
