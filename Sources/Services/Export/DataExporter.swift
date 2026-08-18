import Foundation

/// CSV export. Local file only — written to a temporary URL and handed to the
/// system share sheet. Nothing is uploaded.
enum DataExporter {

    /// Escapes a field for CSV. Notes routinely contain commas and quotes, and an
    /// unescaped one silently corrupts every column after it.
    private static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func readingsCSV(
        _ readings: [BPReading],
        guideline: BPGuideline
    ) -> String {
        var lines = [
            "Recorded,Systolic,Diastolic,Pulse,Category,Guideline,TimeOfDay,Source,Notes"
        ]

        let formatter = ISO8601DateFormatter()
        for reading in readings.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            let fields = [
                formatter.string(from: reading.recordedAt),
                "\(reading.systolic)",
                "\(reading.diastolic)",
                reading.pulse.map(String.init) ?? "",
                guideline.category(for: reading).label,
                guideline.displayName,
                reading.timeOfDay.label,
                reading.source.label,
                reading.notes ?? "",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func medicationCSV(_ doses: [MedicationDose], medications: [Medication]) -> String {
        var lines = ["Scheduled,Recorded,Medication,Dose,Status"]
        let byID = Dictionary(uniqueKeysWithValues: medications.map { ($0.id, $0) })
        let formatter = ISO8601DateFormatter()

        for dose in doses.sorted(by: { $0.scheduledFor < $1.scheduledFor }) {
            let medication = byID[dose.medicationID]
            let fields = [
                formatter.string(from: dose.scheduledFor),
                dose.recordedAt.map(formatter.string(from:)) ?? "",
                medication?.name ?? "Unknown",
                medication?.dose ?? "",
                dose.status.label,
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Writes to a temporary file and returns its URL for the share sheet.
    static func write(_ contents: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
