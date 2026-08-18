import Foundation
import SwiftData

enum DoseStatus: String, Codable, CaseIterable, Sendable {
    case scheduled, taken, skipped, missed

    var label: String { rawValue.capitalized }
}

enum MedicationFrequency: String, Codable, CaseIterable, Sendable {
    case onceDaily, twiceDaily, threeTimesDaily, everyOtherDay, weekly, asNeeded

    var label: String {
        switch self {
        case .onceDaily: "Once daily"
        case .twiceDaily: "Twice daily"
        case .threeTimesDaily: "Three times daily"
        case .everyOtherDay: "Every other day"
        case .weekly: "Weekly"
        case .asNeeded: "As needed"
        }
    }

    var dosesPerDay: Int {
        switch self {
        case .onceDaily, .everyOtherDay, .weekly, .asNeeded: 1
        case .twiceDaily: 2
        case .threeTimesDaily: 3
        }
    }
}

@Model
final class Medication {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var name: String = ""
    var dose: String = ""
    var frequencyRaw: String = MedicationFrequency.onceDaily.rawValue
    /// Minutes past local midnight for each scheduled dose.
    var scheduleMinutes: [Int] = [8 * 60]
    var startDate: Date = Date.now
    var endDate: Date?
    var notes: String?
    var remindersEnabled: Bool = true
    var supplyCount: Int?
    var refillReminderThreshold: Int?
    var isArchived: Bool = false

    init(
        profileID: UUID,
        name: String,
        dose: String,
        frequency: MedicationFrequency = .onceDaily,
        scheduleMinutes: [Int] = [8 * 60],
        startDate: Date = .now
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.name = name
        self.dose = dose
        self.frequencyRaw = frequency.rawValue
        self.scheduleMinutes = scheduleMinutes
        self.startDate = startDate
    }

    var frequency: MedicationFrequency {
        MedicationFrequency(rawValue: frequencyRaw) ?? .onceDaily
    }

    var needsRefill: Bool {
        guard let supplyCount, let threshold = refillReminderThreshold else { return false }
        return supplyCount <= threshold
    }
}

@Model
final class MedicationDose {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var medicationID: UUID = UUID()
    var scheduledFor: Date = Date.now
    var recordedAt: Date?
    var statusRaw: String = DoseStatus.scheduled.rawValue

    init(profileID: UUID, medicationID: UUID, scheduledFor: Date) {
        self.id = UUID()
        self.profileID = profileID
        self.medicationID = medicationID
        self.scheduledFor = scheduledFor
    }

    var status: DoseStatus {
        get { DoseStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }
}
