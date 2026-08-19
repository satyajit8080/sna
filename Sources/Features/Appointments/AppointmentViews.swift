import SwiftData
import SwiftUI

/// Doctor Appointments, implemented from the Figma design.
struct AppointmentListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Appointment.scheduledFor) private var allAppointments: [Appointment]

    @State private var isAdding = false
    @State private var editing: Appointment?
    @State private var isPreparingReport = false
    @State private var isShowingPast = false

    private var mine: [Appointment] {
        allAppointments.filter { $0.profileID == app.activeProfile.id }
    }

    private var upcoming: [Appointment] { mine.filter(\.isUpcoming) }

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Doctor Appointment",
                showsBack: true,
                onBack: { dismiss() }
            )

            BrandHeroCard(
                title: "Manage your appointments effortlessly",
                message: "Book, reschedule and get reminders for your visits.",
                symbol: "calendar"
            )

            HStack {
                Text("Upcoming Appointment")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                if upcoming.count > 1 {
                    Button("See All") { isShowingPast = true }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                }
            }

            if let next = upcoming.first {
                upcomingCard(next)
            } else {
                BrandCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing scheduled")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("Add your next appointment and BP Coach will remind you, and help you prepare.")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Quick Actions")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)

            VStack(spacing: 12) {
                BrandListRow(
                    title: "Book New Appointment",
                    subtitle: "Add a visit and set reminders",
                    symbol: "calendar.badge.plus"
                ) { isAdding = true }

                BrandListRow(
                    title: "Past Appointments",
                    subtitle: "View your appointment history",
                    symbol: "clock.arrow.circlepath",
                    tint: Brand.textSecondary
                ) { isShowingPast = true }

                BrandListRow(
                    title: "Health Report for Doctor",
                    subtitle: "Share your health summary",
                    symbol: "square.and.arrow.up.on.square.fill",
                    tint: Brand.sleep
                ) { isPreparingReport = true }
            }
        }
        .sheet(isPresented: $isAdding) { AppointmentEditorView(appointment: nil) }
        .sheet(item: $editing) { AppointmentEditorView(appointment: $0) }
        .sheet(isPresented: $isShowingPast) { PastAppointmentsView(appointments: mine) }
        .sheet(isPresented: $isPreparingReport) {
            NavigationStack { HealthReportView() }
        }
    }

    private func upcomingCard(_ appointment: Appointment) -> some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    // Date block, as in the design.
                    VStack(spacing: 2) {
                        Text(appointment.scheduledFor.formatted(.dateTime.month(.abbreviated)).uppercased())
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.accent)
                        Text(appointment.scheduledFor.formatted(.dateTime.day()))
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)
                        Text(appointment.scheduledFor.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .frame(width: 59, height: 90)
                    .background(Brand.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appointment.doctorName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)
                        if let specialty = appointment.specialty {
                            Text(specialty)
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        if let location = appointment.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        Label(
                            appointment.scheduledFor.formatted(date: .omitted, time: .shortened),
                            systemImage: "clock"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                    }

                    Spacer(minLength: 0)
                }

                if appointment.remindersEnabled, !appointment.pendingReminderDates().isEmpty {
                    let count = appointment.pendingReminderDates().count
                    Label("\(count) reminder\(count == 1 ? "" : "s") set", systemImage: "bell.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.accent)
                }

                HStack(spacing: 12) {
                    Button { editing = appointment } label: {
                        Text("Reschedule")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Brand.cardStroke, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)

                    Button { isPreparingReport = true } label: {
                        Text("Prepare")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Brand.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Past and upcoming appointments in one list.
struct PastAppointmentsView: View {
    @Environment(\.dismiss) private var dismiss
    let appointments: [Appointment]

    private var past: [Appointment] {
        appointments.filter { !$0.isUpcoming }.sorted { $0.scheduledFor > $1.scheduledFor }
    }
    private var upcoming: [Appointment] {
        appointments.filter(\.isUpcoming).sorted { $0.scheduledFor < $1.scheduledFor }
    }

    var body: some View {
        NavigationStack {
            BrandScreen {
                BrandHeader(title: "All Appointments", showsBack: true, onBack: { dismiss() })

                if !upcoming.isEmpty {
                    Text("Upcoming")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    ForEach(upcoming) { row($0) }
                }

                if !past.isEmpty {
                    Text("Past")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    ForEach(past) { row($0) }
                }

                if appointments.isEmpty {
                    BrandCard {
                        Text("No appointments recorded yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
        }
    }

    private func row(_ appointment: Appointment) -> some View {
        BrandCard(padding: 12) {
            HStack(spacing: 14) {
                BrandIconTile(symbol: "calendar", tint: Brand.sleep, size: 49)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appointment.doctorName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Text(appointment.scheduledFor.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer(minLength: 0)
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
