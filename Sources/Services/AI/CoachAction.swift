import Foundation
import SwiftData

/// An action the coach has proposed.
///
/// Proposed, not performed. The coach can fill in a medicine or an appointment
/// far faster than a form can, but nothing reaches the user's records until they
/// have seen exactly what will be written and tapped confirm.
///
/// That is not caution for its own sake. A wrong appointment is an annoyance. A
/// wrong medication schedule is a reminder at 8am telling someone to take a dose
/// they were never prescribed — and the reminder is what they will trust, not
/// their memory of a chat message.
enum CoachAction: Equatable, Decodable, Sendable {
    case addMedication(Medicine)
    case addAppointment(Visit)
    case addReading(Reading)
    case addWeight(kilograms: Double)
    case addSymptom(Symptom)

    struct Medicine: Equatable, Decodable, Sendable {
        let name: String
        let dose: String
        let frequency: String
        let reminderTimes: [Int]
        let notes: String?
    }

    struct Visit: Equatable, Decodable, Sendable {
        let doctorName: String
        let scheduledFor: Date
        let specialty: String?
        let location: String?
        let notes: String?
    }

    struct Reading: Equatable, Decodable, Sendable {
        let systolic: Int
        let diastolic: Int
        let pulse: Int?
        let recordedAt: Date?
        let notes: String?
    }

    struct Symptom: Equatable, Decodable, Sendable {
        let symptom: String
        let severity: String
        let notes: String?
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let single = decoder

        switch kind {
        case "addMedication":
            self = .addMedication(try Medicine(from: single))
        case "addAppointment":
            self = .addAppointment(try Visit(from: single))
        case "addReading":
            self = .addReading(try Reading(from: single))
        case "addWeight":
            struct Weight: Decodable { let kilograms: Double }
            self = .addWeight(kilograms: try Weight(from: single).kilograms)
        case "addSymptom":
            self = .addSymptom(try Symptom(from: single))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "Unknown action kind: \(kind)"
            )
        }
    }

    // MARK: - Presentation

    var title: String {
        switch self {
        case .addMedication: "Add this medicine?"
        case .addAppointment: "Add this appointment?"
        case .addReading: "Save this reading?"
        case .addWeight: "Save this weight?"
        case .addSymptom: "Log this symptom?"
        }
    }

    var symbol: String {
        switch self {
        case .addMedication: "pills.fill"
        case .addAppointment: "calendar"
        case .addReading: "heart.text.square.fill"
        case .addWeight: "scalemass.fill"
        case .addSymptom: "list.bullet.clipboard.fill"
        }
    }

    /// Exactly what will be written, field by field.
    ///
    /// Shown in full rather than summarised: the point of the confirmation is
    /// that the user can catch a misheard dose or date, and they cannot catch
    /// what they cannot see.
    var fields: [(String, String)] {
        switch self {
        case .addMedication(let medicine):
            var rows = [
                ("Medicine", medicine.name),
                ("Dose", medicine.dose),
                ("How often", Self.frequencyLabel(medicine.frequency)),
            ]
            if !medicine.reminderTimes.isEmpty {
                rows.append((
                    "Reminders",
                    medicine.reminderTimes.sorted().map(Self.timeLabel).joined(separator: ", ")
                ))
            } else {
                rows.append(("Reminders", "None"))
            }
            if let notes = medicine.notes { rows.append(("Notes", notes)) }
            return rows

        case .addAppointment(let visit):
            var rows = [
                ("Doctor", visit.doctorName),
                ("When", visit.scheduledFor.formatted(date: .complete, time: .shortened)),
            ]
            if let specialty = visit.specialty { rows.append(("Specialty", specialty)) }
            if let location = visit.location { rows.append(("Where", location)) }
            if let notes = visit.notes { rows.append(("Notes", notes)) }
            return rows

        case .addReading(let reading):
            var rows = [("Reading", "\(reading.systolic)/\(reading.diastolic) mmHg")]
            if let pulse = reading.pulse { rows.append(("Pulse", "\(pulse) bpm")) }
            rows.append((
                "When",
                (reading.recordedAt ?? .now).formatted(date: .abbreviated, time: .shortened)
            ))
            if let notes = reading.notes { rows.append(("Notes", notes)) }
            return rows

        case .addWeight(let kilograms):
            return [("Weight", String(format: "%.1f kg", kilograms))]

        case .addSymptom(let symptom):
            var rows = [
                ("Symptom", symptom.symptom.capitalized),
                ("Severity", symptom.severity.capitalized),
            ]
            if let notes = symptom.notes { rows.append(("Notes", notes)) }
            return rows
        }
    }

    /// Shown under the fields where the action deserves a second look.
    var caution: String? {
        switch self {
        case .addMedication:
            """
            Check the name and dose against your prescription. BP Coach will \
            remind you to take exactly what is written here.
            """
        case .addReading:
            "Readings added this way are not linked to how they were taken."
        default:
            nil
        }
    }

    // MARK: - Applying

    /// Writes the action. Called only after the user confirms.
    @MainActor
    func apply(profileID: UUID, context: ModelContext) {
        switch self {
        case .addMedication(let medicine):
            let model = Medication(
                profileID: profileID,
                name: medicine.name,
                dose: medicine.dose,
                frequency: MedicationFrequency(rawValue: medicine.frequency) ?? .onceDaily,
                scheduleMinutes: medicine.reminderTimes.isEmpty ? [8 * 60] : medicine.reminderTimes
            )
            model.notes = medicine.notes
            context.insert(model)
            Task {
                await NotificationEngine.shared.requestAuthorization()
                await NotificationEngine.shared.rescheduleMedication(
                    medicationID: model.id,
                    name: model.name,
                    dose: model.dose,
                    scheduleMinutes: model.scheduleMinutes
                )
            }

        case .addAppointment(let visit):
            let model = Appointment(
                profileID: profileID,
                doctorName: visit.doctorName,
                specialty: visit.specialty,
                scheduledFor: visit.scheduledFor,
                location: visit.location,
                notes: visit.notes
            )
            context.insert(model)
            Task {
                await NotificationEngine.shared.requestAuthorization()
                await NotificationEngine.shared.scheduleAppointmentReminders(
                    appointmentID: model.id,
                    doctorName: model.doctorName,
                    scheduledFor: model.scheduledFor,
                    reminderDates: model.pendingReminderDates()
                )
            }

        case .addReading(let reading):
            context.insert(BPReading(
                profileID: profileID,
                systolic: reading.systolic,
                diastolic: reading.diastolic,
                pulse: reading.pulse,
                recordedAt: reading.recordedAt ?? .now,
                source: .manual,
                notes: reading.notes
            ))

        case .addWeight(let kilograms):
            context.insert(LifestyleEntry(
                profileID: profileID,
                kind: .weight,
                value: kilograms,
                unit: "kg",
                label: "Weight"
            ))

        case .addSymptom(let symptom):
            context.insert(SymptomEntry(
                profileID: profileID,
                kind: SymptomKind(rawValue: symptom.symptom) ?? .other,
                severity: Self.severity(from: symptom.severity),
                notes: symptom.notes
            ))
        }

        try? context.save()
        Haptics.success()
    }

    // MARK: - Labels

    /// `SymptomSeverity` is Int-backed, so the string from the model has to be
    /// mapped rather than initialised from a raw value.
    private static func severity(from raw: String) -> SymptomSeverity {
        switch raw.lowercased() {
        case "severe": .severe
        case "moderate": .moderate
        default: .mild
        }
    }

    private static func frequencyLabel(_ raw: String) -> String {
        MedicationFrequency(rawValue: raw)?.label ?? raw
    }

    private static func timeLabel(_ minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}
