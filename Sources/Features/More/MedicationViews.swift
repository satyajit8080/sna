import Charts
import SwiftData
import SwiftUI

/// Medicine Reminder, implemented from the Figma design.
struct MedicationListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allMedications: [Medication]
    @Query(sort: \MedicationDose.scheduledFor) private var allDoses: [MedicationDose]

    @State private var isAdding = false
    @State private var editing: Medication?
    @State private var justAdded: Medication?

    private var mine: [Medication] {
        allMedications.filter { $0.profileID == app.activeProfile.id && !$0.isArchived }
    }

    private var todaysDoses: [MedicationDose] {
        allDoses.filter {
            $0.profileID == app.activeProfile.id
                && Calendar.current.isDateInToday($0.scheduledFor)
        }
    }

    private var byID: [UUID: Medication] {
        Dictionary(uniqueKeysWithValues: allMedications.map { ($0.id, $0) })
    }

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Medicine Reminder",
                showsBack: true,
                onBack: { dismiss() },
                trailing: [("bell.fill", {})]
            )

            BrandHeroCard(
                title: "Stay on Track with your medication",
                message: "We'll remind you so you never miss a dose.",
                symbol: "pills.fill"
            )

            HStack {
                Text("Today's Schedule")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                if !mine.isEmpty {
                    Button("Edit") { editing = mine.first }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
            }

            if todaysDoses.isEmpty {
                BrandCard {
                    Text(mine.isEmpty
                         ? "No medicines yet. Add one and BP Coach will remind you."
                         : "Nothing scheduled for today.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(todaysDoses) { dose in
                        doseRow(dose)
                    }
                }
            }

            BrandPrimaryButton(title: "Add Medicine") { isAdding = true }

            if !mine.isEmpty {
                Text("Medicine Insights")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                insightsCard
            }
        }
        .sheet(isPresented: $isAdding) {
            MedicationEditorView(medication: nil) { justAdded = $0 }
        }
        .sheet(item: $editing) { MedicationEditorView(medication: $0) { _ in } }
        .sheet(item: $justAdded) { MedicationAddedView(medication: $0) }
    }

    private func doseRow(_ dose: MedicationDose) -> some View {
        let medication = byID[dose.medicationID]

        return BrandCard(padding: 12) {
            HStack(spacing: 14) {
                BrandIconTile(symbol: "pills.fill", tint: Brand.medication, size: 55)

                VStack(alignment: .leading, spacing: 3) {
                    Text(dose.scheduledFor.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                    Text("\(medication?.name ?? "Medicine") \(medication?.dose ?? "")")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(medication?.frequency.label ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                }

                Spacer(minLength: 0)

                statusControl(dose)
            }
        }
    }

    /// Tapping an unanswered dose marks it taken. A dose that has already been
    /// answered shows its state rather than a button, so the record cannot be
    /// changed by a stray tap.
    @ViewBuilder
    private func statusControl(_ dose: MedicationDose) -> some View {
        switch dose.status {
        case .taken:
            statusPill("Done", tint: Brand.accent)
        case .skipped:
            statusPill("Skipped", tint: Brand.textSecondary)
        case .missed:
            statusPill("Missed", tint: Brand.restingHeartRate)
        case .scheduled:
            Button {
                dose.status = .taken
                dose.recordedAt = .now
                try? context.save()
                Haptics.success()
            } label: {
                statusPill("Upcoming", tint: Brand.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Double tap to mark as taken")
        }
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }

    /// Adherence over the last week, computed from real doses.
    private var insightsCard: some View {
        let week = allDoses.filter {
            $0.profileID == app.activeProfile.id
                && $0.scheduledFor > Date.now.addingTimeInterval(-7 * 86_400)
        }
        let adherence = MedicationEngine.adherence(for: week)

        return BrandCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline(for: adherence.percentage))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(message(for: adherence))
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if let percent = adherence.percentage {
                    ZStack {
                        Circle()
                            .stroke(Brand.accent.opacity(0.15), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: percent / 100)
                            .stroke(Brand.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(percent))%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                    }
                    .frame(width: 56, height: 56)
                }
            }
        }
    }

    private func headline(for percentage: Double?) -> String {
        guard let percentage else { return "Getting started" }
        if percentage >= 90 { return "Excellent!" }
        if percentage >= 70 { return "Going well" }
        return "Room to improve"
    }

    private func message(for adherence: MedicationEngine.Adherence) -> String {
        guard let percentage = adherence.percentage else {
            return "Once you start marking doses, your adherence shows up here."
        }
        return "You have taken \(Int(percentage))% of your medicines this week."
    }
}

/// Confirmation after adding a medicine, from the Figma "Medicine Added" screen.
struct MedicationAddedView: View {
    @Environment(\.dismiss) private var dismiss
    let medication: Medication

    var body: some View {
        NavigationStack {
            BrandScreen {
                BrandHeader(title: "Medicine Added", showsBack: true, onBack: { dismiss() })

                BrandCard {
                    VStack(spacing: 14) {
                        Circle()
                            .fill(Brand.accent.opacity(0.15))
                            .frame(width: 58, height: 58)
                            .overlay {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(Brand.accent)
                            }
                        Text("Congratulations!")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("Your medicine has been successfully added.")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }

                BrandCard(padding: 12) {
                    HStack(spacing: 14) {
                        BrandIconTile(symbol: "pills.fill", tint: Brand.medication, size: 55)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(medication.name) \(medication.dose)")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text(medication.frequency.label)
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Text("Active")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.accent)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Brand.accent.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                BrandCard {
                    VStack(spacing: 0) {
                        detailRow("calendar", "Schedule", medication.frequency.label)
                        Divider().background(Brand.cardStroke).padding(.vertical, 14)
                        detailRow(
                            "clock",
                            "Time",
                            medication.scheduleMinutes.isEmpty
                                ? "No reminder times set"
                                : medication.scheduleMinutes
                                    .sorted()
                                    .map(Self.timeLabel)
                                    .joined(separator: ", ")
                        )
                        Divider().background(Brand.cardStroke).padding(.vertical, 14)
                        detailRow(
                            "bell.fill",
                            "Reminder",
                            medication.remindersEnabled
                                ? "You will get a reminder on time"
                                : "Reminders are off for this medicine"
                        )
                    }
                }

                BrandPrimaryButton(title: "Done") { dismiss() }
            }
        }
    }

    /// Minutes past midnight rendered in the user's locale.
    private static func timeLabel(_ minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func detailRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            BrandIconTile(symbol: symbol, tint: Brand.accent, size: 55)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MedicationEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let medication: Medication?
    /// Called with the saved medicine so the caller can show the confirmation
    /// screen. Defaults to a no-op for the edit path, which needs no acknowledgement.
    var onSave: (Medication) -> Void = { _ in }

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

        // Only for a newly created medicine — editing needs no acknowledgement.
        if medication == nil { onSave(target) }

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
