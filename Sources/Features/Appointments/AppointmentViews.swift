import SwiftData
import SwiftUI

struct AppointmentListView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Appointment.scheduledFor) private var allAppointments: [Appointment]

    @State private var isAdding = false
    @State private var editing: Appointment?

    private var mine: [Appointment] {
        allAppointments.filter { $0.profileID == app.activeProfile.id }
    }

    private var upcoming: [Appointment] { mine.filter(\.isUpcoming) }
    private var past: [Appointment] {
        mine.filter { !$0.isUpcoming }.sorted { $0.scheduledFor > $1.scheduledFor }
    }

    var body: some View {
        Group {
            if mine.isEmpty {
                EmptyStateView(
                    symbol: "calendar",
                    title: "No appointments",
                    message: "Add your next appointment and BP Coach will remind you, and help you prepare.",
                    actionTitle: "Add appointment",
                    action: { isAdding = true }
                )
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        if let next = upcoming.first {
                            NextAppointmentCard(appointment: next) { editing = next }
                        }

                        if upcoming.count > 1 {
                            section("Also coming up", Array(upcoming.dropFirst()))
                        }
                        if !past.isEmpty {
                            section("Past", past)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Appointments")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add appointment")
            }
        }
        .sheet(isPresented: $isAdding) { AppointmentEditorView(appointment: nil) }
        .sheet(item: $editing) { AppointmentEditorView(appointment: $0) }
    }

    private func section(_ title: String, _ items: [Appointment]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: title)
            ForEach(items) { appointment in
                Button { editing = appointment } label: {
                    AppointmentRow(appointment: appointment)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct NextAppointmentCard: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    let appointment: Appointment
    let onEdit: () -> Void

    @State private var isPreparingReport = false

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Next appointment", subtitle: relative)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appointment.doctorName).font(.headline)
                    if let specialty = appointment.specialty {
                        Text(specialty).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    Label(
                        appointment.scheduledFor.formatted(date: .complete, time: .shortened),
                        systemImage: "calendar"
                    )
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                    if let location = appointment.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if appointment.remindersEnabled, !appointment.pendingReminderDates().isEmpty {
                    Label(
                        "\(appointment.pendingReminderDates().count) reminder\(appointment.pendingReminderDates().count == 1 ? "" : "s") set",
                        systemImage: "bell.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Prepare report") { isPreparingReport = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    Button("Edit", action: onEdit).buttonStyle(.bordered)
                }
                .font(.subheadline)
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $isPreparingReport) {
            AppointmentPrepView(appointment: appointment)
        }
    }

    private var relative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: appointment.scheduledFor, relativeTo: .now)
    }
}

struct AppointmentRow: View {
    let appointment: Appointment

    var body: some View {
        CardView(padding: Theme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appointment.doctorName).font(.subheadline.weight(.medium))
                    Text(appointment.scheduledFor.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One editor for add and edit, so the two paths cannot drift apart.
struct AppointmentEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let appointment: Appointment?

    @State private var doctorName = ""
    @State private var specialty = ""
    @State private var scheduledFor = Date.now.addingTimeInterval(7 * 86_400)
    @State private var location = ""
    @State private var notes = ""
    @State private var remindersEnabled = true
    @State private var selectedOffsets: Set<Int> = [7 * 24 * 60, 24 * 60]
    @State private var isConfirmingDelete = false

    private let offsetOptions: [(String, Int)] = [
        ("1 week before", 7 * 24 * 60),
        ("1 day before", 24 * 60),
        ("Morning of", 6 * 60),
        ("2 hours before", 120),
    ]

    private var isEditing: Bool { appointment != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appointment") {
                    TextField("Doctor", text: $doctorName)
                        .textInputAutocapitalization(.words)
                    TextField("Specialty (optional)", text: $specialty)
                        .textInputAutocapitalization(.words)
                    DatePicker("When", selection: $scheduledFor)
                    TextField("Location (optional)", text: $location)
                }

                Section {
                    Toggle("Remind me", isOn: $remindersEnabled)
                    if remindersEnabled {
                        ForEach(offsetOptions, id: \.1) { option in
                            Button {
                                toggle(option.1)
                            } label: {
                                HStack {
                                    Text(option.0).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if selectedOffsets.contains(option.1) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    if remindersEnabled {
                        Text("Reminders that have already passed are skipped rather than firing straight away.")
                    }
                }

                Section("Notes") {
                    TextField("Questions to ask, symptoms to mention…", text: $notes, axis: .vertical)
                        .lineLimit(1...6)
                }

                if isEditing {
                    Section {
                        Button("Delete appointment", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit appointment" : "Add appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(doctorName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
            .confirmationDialog(
                "Delete this appointment?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Keep", role: .cancel) {}
            }
        }
    }

    private func toggle(_ offset: Int) {
        if selectedOffsets.contains(offset) { selectedOffsets.remove(offset) }
        else { selectedOffsets.insert(offset) }
    }

    private func load() {
        guard let appointment else { return }
        doctorName = appointment.doctorName
        specialty = appointment.specialty ?? ""
        scheduledFor = appointment.scheduledFor
        location = appointment.location ?? ""
        notes = appointment.notes ?? ""
        remindersEnabled = appointment.remindersEnabled
        selectedOffsets = Set(appointment.reminderOffsets)
    }

    private func save() {
        let target: Appointment
        if let appointment {
            target = appointment
        } else {
            target = Appointment(
                profileID: app.activeProfile.id,
                doctorName: doctorName,
                scheduledFor: scheduledFor
            )
            context.insert(target)
        }

        target.doctorName = doctorName
        target.specialty = specialty.isEmpty ? nil : specialty
        target.scheduledFor = scheduledFor
        target.location = location.isEmpty ? nil : location
        target.notes = notes.isEmpty ? nil : notes
        target.remindersEnabled = remindersEnabled
        target.reminderOffsets = Array(selectedOffsets).sorted(by: >)

        try? context.save()

        Task {
            if remindersEnabled {
                await NotificationEngine.shared.requestAuthorization()
                await NotificationEngine.shared.scheduleAppointmentReminders(
                    appointmentID: target.id,
                    doctorName: target.doctorName,
                    scheduledFor: target.scheduledFor,
                    reminderDates: target.pendingReminderDates()
                )
            } else {
                NotificationEngine.shared.cancelAppointment(target.id)
            }
        }

        Haptics.success()
        dismiss()
    }

    private func delete() {
        guard let appointment else { return }
        NotificationEngine.shared.cancelAppointment(appointment.id)
        context.delete(appointment)
        try? context.save()
        dismiss()
    }
}
