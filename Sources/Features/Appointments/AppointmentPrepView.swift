import SwiftData
import SwiftUI

/// A summary to take to an appointment.
///
/// Everything here is computed from stored readings — no AI, no generated
/// claims. What a doctor needs is the numbers and how they were taken.
struct AppointmentPrepView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]
    @Query(sort: \SymptomEntry.recordedAt, order: .reverse) private var allSymptoms: [SymptomEntry]

    let appointment: Appointment

    @State private var exportURL: URL?
    @State private var error: AppError?

    private var readings: [BPReading] {
        allReadings.filter { $0.profileID == app.activeProfile.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    header
                    averagesCard
                    patternsCard
                    medicationCard
                    symptomsCard
                    questionsCard
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.background)
            .navigationTitle("For your appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(readings.isEmpty)
                    .accessibilityLabel("Export readings")
                }
            }
            .sheet(item: Binding(
                get: { exportURL.map(ShareItem.init) },
                set: { _ in exportURL = nil }
            )) { ShareSheet(url: $0.url) }
        }
    }

    private var header: some View {
        CardView {
            VStack(alignment: .leading, spacing: 4) {
                Text(appointment.doctorName).font(.headline)
                Text(appointment.scheduledFor.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text("Measured with \(guidelines.active.displayName) categories.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var averagesCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Averages", subtitle: "Home readings only")
                ForEach([7, 30, 90], id: \.self) { days in
                    HStack {
                        Text("\(days) days").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if let avg = BPStatistics.homeAverage(readings, days: days) {
                            Text("\(avg.systolic)/\(avg.diastolic)")
                                .font(Theme.number(17, weight: .semibold))
                            Text("· \(avg.count) readings")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            Text("No data").foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var patternsCard: some View {
        Group {
            if let morning = BPStatistics.morningVsEvening(readings) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Patterns", subtitle: "From your own readings")
                        HStack {
                            StatTile(
                                title: "Morning",
                                value: "\(morning.first.systolic)/\(morning.first.diastolic)",
                                caption: "\(morning.first.count) readings"
                            )
                            StatTile(
                                title: "Evening",
                                value: "\(morning.second.systolic)/\(morning.second.diastolic)",
                                caption: "\(morning.second.count) readings"
                            )
                        }
                        if let variability = BPStatistics.variability(readings) {
                            Text(String(format: "Systolic varies by about ±%.1f between readings.",
                                        variability.systolicSD))
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var medicationCard: some View {
        let mine = allMedications.filter { $0.profileID == app.activeProfile.id && !$0.isArchived }
        let doses = allDoses.filter { $0.profileID == app.activeProfile.id }

        return Group {
            if !mine.isEmpty {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Medication")
                        ForEach(mine) { medication in
                            let own = doses.filter { $0.medicationID == medication.id }
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(medication.name).font(.subheadline)
                                    Text("\(medication.dose) · \(medication.frequency.label)")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                if let percent = MedicationEngine.adherence(for: own).percentage {
                                    Text("\(Int(percent))% taken")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var symptomsCard: some View {
        let recent = allSymptoms.filter {
            $0.profileID == app.activeProfile.id
                && $0.recordedAt > Date.now.addingTimeInterval(-90 * 86_400)
        }

        return Group {
            if !recent.isEmpty {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Symptoms logged", subtitle: "Last 90 days")
                        ForEach(Array(Dictionary(grouping: recent, by: \.kind)), id: \.key) { kind, entries in
                            HStack {
                                Label(kind.label, systemImage: kind.symbol)
                                Spacer()
                                Text("\(entries.count)×")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var questionsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(
                    title: "Worth asking",
                    subtitle: "General prompts, not advice about your case"
                )
                ForEach(questions, id: \.self) { question in
                    Label(question, systemImage: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// Fixed prompts. Deliberately not generated: questions to ask a doctor are
    /// exactly where an AI could invent something misleading.
    private var questions: [String] {
        var list = [
            "Is my home average where you would want it?",
            "Should I be measuring at different times?",
        ]
        if BPStatistics.homeVsClinic(readings) != nil {
            list.append("My home and clinic readings differ — does that change anything?")
        }
        if !allMedications.filter({ $0.profileID == app.activeProfile.id && !$0.isArchived }).isEmpty {
            list.append("Is my current medication still the right choice?")
        }
        return list
    }

    private func exportCSV() {
        do {
            let csv = DataExporter.readingsCSV(readings, guideline: guidelines.active)
            exportURL = try DataExporter.write(csv, filename: "bp-readings.csv")
        } catch {
            self.error = .exportFailed(error.localizedDescription)
        }
    }
}
