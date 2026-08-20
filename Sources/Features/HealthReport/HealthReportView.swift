import SwiftData
import SwiftUI

/// A summary the user assembles and shares with their doctor.
///
/// Every section is opt-in and off by default where it is sensitive. Health data
/// leaves the device only when the user picks what goes and taps share — a
/// report that silently included everything would be a privacy decision made on
/// their behalf.
struct HealthReportView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines

    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]
    @Query(sort: \SymptomEntry.recordedAt, order: .reverse) private var allSymptoms: [SymptomEntry]
    @Query(sort: \LifestyleEntry.recordedAt, order: .reverse) private var allLifestyle: [LifestyleEntry]
    @Query(sort: \ActivityEntry.startedAt, order: .reverse) private var allActivity: [ActivityEntry]
    @Query(sort: \MedicalDocument.importedAt, order: .reverse) private var allDocuments: [MedicalDocument]

    @State private var included: Set<ReportSection> = [.averages, .readings, .medication]
    @State private var days = 90
    @State private var exportURL: URL?
    @State private var error: AppError?

    enum ReportSection: String, CaseIterable, Identifiable {
        case averages, readings, patterns, medication, symptoms, weight, activity, sodium, documents

        var id: String { rawValue }

        var label: String {
            switch self {
            case .averages: "BP averages"
            case .readings: "Recent readings"
            case .patterns: "Patterns"
            case .medication: "Medication adherence"
            case .symptoms: "Symptoms"
            case .weight: "Weight"
            case .activity: "Activity"
            case .sodium: "Sodium"
            case .documents: "Document list"
            }
        }

        var detail: String {
            switch self {
            case .averages: "7, 30 and 90-day home averages"
            case .readings: "Every reading in the period, with categories"
            case .patterns: "Morning vs evening, home vs clinic, variability"
            case .medication: "What was taken, skipped and missed"
            case .symptoms: "What you logged and how often"
            case .weight: "Current weight and change"
            case .activity: "Logged minutes"
            case .sodium: "Daily average"
            case .documents: "Titles and dates only — no contents"
            }
        }
    }

    private var readings: [BPReading] {
        BPStatistics.within(
            allReadings.filter { $0.profileID == app.activeProfile.id },
            days: days
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Period")
            } footer: {
                Text("\(readings.count) blood pressure readings in this period.")
            }

            Section {
                ForEach(ReportSection.allCases) { section in
                    Button {
                        toggle(section)
                        Haptics.selection()
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: included.contains(section)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(included.contains(section)
                                                 ? Theme.accent : Theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.label).foregroundStyle(Theme.textPrimary)
                                Text(section.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            } header: {
                Text("What to include")
            } footer: {
                Text("""
                Only what you tick is included. Document contents are never \
                attached — only their titles and dates, so your doctor knows what \
                to ask for.
                """)
            }

            Section {
                NavigationLink {
                    ReportPreviewView(text: reportText)
                } label: {
                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    exportPDF()
                } label: {
                    Label("Share as PDF", systemImage: "doc.richtext")
                }
                .disabled(included.isEmpty)

                Button {
                    exportText()
                } label: {
                    Label("Share as text", systemImage: "doc.plaintext")
                }
                .disabled(included.isEmpty)

                Button {
                    exportCSV()
                } label: {
                    Label("Export readings as CSV", systemImage: "tablecells")
                }
                .disabled(readings.isEmpty)
            } footer: {
                if let error {
                    Text(error.errorDescription ?? "").foregroundStyle(Theme.statusModerate)
                }
            }
        }
        .navigationTitle("Health report")
            .scrollContentBackground(.hidden)
            .background(Brand.background)
        .sheet(item: Binding(
            get: { exportURL.map(ShareItem.init) },
            set: { _ in exportURL = nil }
        )) { ShareSheet(url: $0.url) }
    }

    private func toggle(_ section: ReportSection) {
        if included.contains(section) { included.remove(section) }
        else { included.insert(section) }
    }

    // MARK: - Composition

    /// Plain text rather than PDF: it pastes into an email, prints, and is
    /// readable by anyone. Nothing here is generated by AI — every line is a
    /// number the app recorded.
    private var reportText: String {
        var lines: [String] = []
        let profileID = app.activeProfile.id

        lines.append("HEALTH SUMMARY")
        lines.append("Prepared \(Date.now.formatted(date: .long, time: .shortened))")
        lines.append("Period: last \(days) days")
        lines.append("Categories from \(guidelines.active.displayName)")
        lines.append(String(repeating: "-", count: 44))

        if included.contains(.averages) {
            lines.append("")
            lines.append("BLOOD PRESSURE AVERAGES (home readings only)")
            for window in [7, 30, 90] where window <= days {
                if let avg = BPStatistics.homeAverage(readings, days: window) {
                    lines.append("  \(window) days: \(avg.systolic)/\(avg.diastolic) mmHg  (\(avg.count) readings)")
                }
            }
        }

        if included.contains(.patterns) {
            lines.append("")
            lines.append("PATTERNS")
            if let c = BPStatistics.morningVsEvening(readings) {
                lines.append("  Morning: \(c.first.systolic)/\(c.first.diastolic)  (\(c.first.count))")
                lines.append("  Evening: \(c.second.systolic)/\(c.second.diastolic)  (\(c.second.count))")
            }
            if let c = BPStatistics.homeVsClinic(readings) {
                lines.append("  Home:   \(c.first.systolic)/\(c.first.diastolic)")
                lines.append("  Clinic: \(c.second.systolic)/\(c.second.diastolic)")
            }
            if let v = BPStatistics.variability(readings) {
                lines.append(String(format: "  Systolic variability (SD): %.1f", v.systolicSD))
            }
        }

        if included.contains(.medication) {
            let mine = allMedications.filter { $0.profileID == profileID && !$0.isArchived }
            if !mine.isEmpty {
                lines.append("")
                lines.append("MEDICATION")
                for medication in mine {
                    let doses = allDoses.filter {
                        $0.medicationID == medication.id && $0.profileID == profileID
                    }
                    let adherence = MedicationEngine.adherence(for: doses)
                    let percent = adherence.percentage.map { "\(Int($0))% taken" } ?? "no dose history"
                    lines.append("  \(medication.name) \(medication.dose), \(medication.frequency.label) — \(percent)")
                }
            }
        }

        if included.contains(.symptoms) {
            let recent = allSymptoms.filter {
                $0.profileID == profileID
                    && $0.recordedAt > Date.now.addingTimeInterval(-Double(days) * 86_400)
            }
            if !recent.isEmpty {
                lines.append("")
                lines.append("SYMPTOMS LOGGED")
                for (kind, entries) in Dictionary(grouping: recent, by: \.kind)
                    .sorted(by: { $0.value.count > $1.value.count }) {
                    lines.append("  \(kind.label): \(entries.count)×")
                }
            }
        }

        if included.contains(.weight) {
            let weights = allLifestyle.filter { $0.profileID == profileID && $0.kind == .weight }
            if let latest = weights.first {
                lines.append("")
                lines.append("WEIGHT")
                lines.append(String(format: "  Current: %.1f kg", latest.value))
                if let earliest = weights.last, weights.count > 1 {
                    lines.append(String(format: "  Change over period: %+.1f kg", latest.value - earliest.value))
                }
            }
        }

        if included.contains(.activity) {
            let minutes = allActivity
                .filter {
                    $0.profileID == profileID
                        && $0.startedAt > Date.now.addingTimeInterval(-Double(days) * 86_400)
                }
                .reduce(0) { $0 + $1.minutes }
            if minutes > 0 {
                lines.append("")
                lines.append("ACTIVITY")
                lines.append("  \(minutes) minutes logged over \(days) days")
            }
        }

        if included.contains(.sodium) {
            let entries = allLifestyle.filter {
                $0.profileID == profileID && $0.kind == .sodium
                    && $0.recordedAt > Date.now.addingTimeInterval(-Double(days) * 86_400)
            }
            if !entries.isEmpty {
                let byDay = Dictionary(grouping: entries) {
                    Calendar.current.startOfDay(for: $0.recordedAt)
                }
                let average = byDay.values.map { $0.reduce(0) { $0 + $1.value } }
                    .reduce(0, +) / Double(byDay.count)
                lines.append("")
                lines.append("SODIUM")
                lines.append("  Average on days recorded: \(Int(average)) mg")
                lines.append("  Days recorded: \(byDay.count) of \(days)")
                if entries.contains(where: \.isEstimate) {
                    lines.append("  NOTE: some entries are estimates, not label values.")
                }
            }
        }

        if included.contains(.documents) {
            let documents = allDocuments.filter { $0.profileID == profileID }
            if !documents.isEmpty {
                lines.append("")
                lines.append("DOCUMENTS ON FILE (titles only)")
                for document in documents.prefix(20) {
                    let date = (document.documentDate ?? document.importedAt)
                        .formatted(date: .abbreviated, time: .omitted)
                    lines.append("  \(date) — \(document.title) (\(document.kind.label))")
                }
            }
        }

        if included.contains(.readings) {
            lines.append("")
            lines.append("READINGS")
            for reading in readings.prefix(200) {
                let time = reading.recordedAt.formatted(date: .abbreviated, time: .shortened)
                let pulse = reading.pulse.map { ", pulse \($0)" } ?? ""
                lines.append("  \(time)  \(reading.systolic)/\(reading.diastolic)\(pulse)  \(guidelines.category(for: reading).label)  [\(reading.source.label)]")
            }
        }

        lines.append("")
        lines.append(String(repeating: "-", count: 44))
        lines.append("""
        Recorded with BP Coach. Categories follow \(guidelines.active.displayName). \
        This summary describes recorded measurements only and contains no \
        diagnosis or interpretation.
        """)

        return lines.joined(separator: "\n")
    }

    private func exportText() {
        do {
            exportURL = try DataExporter.write(reportText, filename: "health-summary.txt")
        } catch {
            self.error = .exportFailed(error.localizedDescription)
        }
    }

    /// CSV for a clinician who wants the raw numbers in a spreadsheet.
    private func exportCSV() {
        do {
            let csv = DataExporter.readingsCSV(readings, guideline: guidelines.active)
            exportURL = try DataExporter.write(csv, filename: "bp-readings.csv")
        } catch {
            self.error = .exportFailed(error.localizedDescription)
        }
    }

    private func exportPDF() {
        do {
            exportURL = try PDFReportBuilder.write(pdfDocument, filename: "health-summary.pdf")
        } catch {
            self.error = .exportFailed(error.localizedDescription)
        }
    }

    /// The same content as the text report, laid out for printing.
    ///
    /// Built from the same `included` set, so what the user ticked is exactly
    /// what leaves the device in either format.
    private var pdfDocument: PDFReportBuilder.Document {
        var sections: [PDFReportBuilder.Section] = []
        let profileID = app.activeProfile.id

        if included.contains(.averages) {
            var rows: [(String, String)] = []
            for window in [7, 30, 90] where window <= days {
                if let average = BPStatistics.homeAverage(readings, days: window) {
                    rows.append((
                        "\(window)-day average",
                        "\(average.systolic)/\(average.diastolic) mmHg   (\(average.count) readings)"
                    ))
                }
            }
            if !rows.isEmpty {
                sections.append(.init(
                    title: "Blood pressure averages",
                    rows: rows,
                    note: "Home readings only. Clinic readings are excluded so the two can be compared separately."
                ))
            }
        }

        if included.contains(.patterns) {
            var rows: [(String, String)] = []
            if let c = BPStatistics.morningVsEvening(readings) {
                rows.append(("Morning", "\(c.first.systolic)/\(c.first.diastolic)   (\(c.first.count))"))
                rows.append(("Evening", "\(c.second.systolic)/\(c.second.diastolic)   (\(c.second.count))"))
            }
            if let c = BPStatistics.homeVsClinic(readings) {
                rows.append(("Home", "\(c.first.systolic)/\(c.first.diastolic)"))
                rows.append(("Clinic", "\(c.second.systolic)/\(c.second.diastolic)"))
            }
            if let v = BPStatistics.variability(readings) {
                rows.append(("Systolic variability (SD)", String(format: "%.1f", v.systolicSD)))
            }
            if !rows.isEmpty {
                sections.append(.init(title: "Patterns", rows: rows))
            }
        }

        if included.contains(.medication) {
            let mine = allMedications.filter { $0.profileID == profileID && !$0.isArchived }
            let rows = mine.map { medication -> (String, String) in
                let doses = allDoses.filter {
                    $0.medicationID == medication.id && $0.profileID == profileID
                }
                let adherence = MedicationEngine.adherence(for: doses)
                let taken = adherence.percentage.map { "\(Int($0))% taken" } ?? "no dose history"
                return ("\(medication.name) \(medication.dose), \(medication.frequency.label)", taken)
            }
            if !rows.isEmpty {
                sections.append(.init(
                    title: "Medication",
                    rows: rows,
                    note: "Adherence is calculated from doses the user marked in the app."
                ))
            }
        }

        if included.contains(.symptoms) {
            let recent = allSymptoms.filter {
                $0.profileID == profileID
                    && $0.recordedAt > Date.now.addingTimeInterval(-Double(days) * 86_400)
            }
            let rows = Dictionary(grouping: recent, by: \.kind)
                .sorted { $0.value.count > $1.value.count }
                .map { ($0.key.label, "\($0.value.count)x") }
            if !rows.isEmpty {
                sections.append(.init(title: "Symptoms logged", rows: rows))
            }
        }

        if included.contains(.weight) {
            let weights = allLifestyle.filter { $0.profileID == profileID && $0.kind == .weight }
            if let latest = weights.first {
                var rows = [("Current", String(format: "%.1f kg", latest.value))]
                if let earliest = weights.last, weights.count > 1 {
                    rows.append((
                        "Change over period",
                        String(format: "%+.1f kg", latest.value - earliest.value)
                    ))
                }
                sections.append(.init(title: "Weight", rows: rows))
            }
        }

        if included.contains(.readings) {
            let rows = readings.prefix(120).map { reading -> (String, String) in
                let when = reading.recordedAt.formatted(date: .abbreviated, time: .shortened)
                let pulse = reading.pulse.map { ", pulse \($0)" } ?? ""
                return (
                    "\(when)  [\(reading.source.label)]",
                    "\(reading.systolic)/\(reading.diastolic)\(pulse)  \(guidelines.category(for: reading).label)"
                )
            }
            if !rows.isEmpty {
                sections.append(.init(
                    title: "Readings",
                    rows: Array(rows),
                    note: readings.count > 120
                        ? "Showing the most recent 120 of \(readings.count) readings. Export the CSV for the full set."
                        : nil
                ))
            }
        }

        return .init(
            title: "Health Summary",
            subtitle: "\(app.activeProfile.name) · last \(days) days · categories from \(guidelines.active.displayName)",
            generatedAt: .now,
            sections: sections,
            disclaimer: """
            Recorded with BP Coach. This summary describes measurements the patient recorded \
            and contains no diagnosis or interpretation.
            """
        )
    }
}

struct ReportPreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
    }
}
