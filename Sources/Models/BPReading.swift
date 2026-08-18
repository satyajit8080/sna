import Foundation
import SwiftData

/// Where a reading came from. Affects reliability and how it is grouped in analysis.
enum BPSource: String, Codable, CaseIterable, Sendable {
    case manual, ruleOfThree, bluetooth, healthKit, clinic

    var label: String {
        switch self {
        case .manual: "Manual"
        case .ruleOfThree: "Rule of 3"
        case .bluetooth: "Connected cuff"
        case .healthKit: "Apple Health"
        case .clinic: "Clinic"
        }
    }

    /// Clinic readings are excluded from home averages; the white-coat effect makes
    /// mixing them into a home baseline misleading.
    var isHomeMeasurement: Bool { self != .clinic }
}

/// Morning / evening classification, fixed at capture time.
///
/// Stored rather than derived, so a device timezone change never silently
/// reclassifies historical readings.
enum BPTimeOfDay: String, Codable, CaseIterable, Sendable {
    case morning, afternoon, evening, night

    static func classify(_ date: Date, calendar: Calendar = .current) -> BPTimeOfDay {
        switch calendar.component(.hour, from: date) {
        case 4..<12: .morning
        case 12..<17: .afternoon
        case 17..<22: .evening
        default: .night
        }
    }

    var label: String { rawValue.capitalized }
}

@Model
final class BPReading {
    var id: UUID = UUID()
    var profileID: UUID = UUID()

    var systolic: Int = 0
    var diastolic: Int = 0
    var pulse: Int?

    var recordedAt: Date = Date.now
    /// Seconds from GMT at capture, so history renders in the zone it was taken in.
    var timeZoneOffset: Int = 0
    var timeOfDayRaw: String = BPTimeOfDay.morning.rawValue
    var sourceRaw: String = BPSource.manual.rawValue

    var notes: String?
    var tags: [String] = []

    /// Set when this reading belongs to a Rule-of-3 session.
    var sessionID: UUID?
    /// HealthKit sample UUID, when the reading came from or was written to Health.
    var healthKitUUID: String?

    init(
        profileID: UUID,
        systolic: Int,
        diastolic: Int,
        pulse: Int? = nil,
        recordedAt: Date = .now,
        source: BPSource = .manual,
        notes: String? = nil,
        tags: [String] = [],
        calendar: Calendar = .current
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.systolic = systolic
        self.diastolic = diastolic
        self.pulse = pulse
        self.recordedAt = recordedAt
        self.timeZoneOffset = TimeZone.current.secondsFromGMT(for: recordedAt)
        self.timeOfDayRaw = BPTimeOfDay.classify(recordedAt, calendar: calendar).rawValue
        self.sourceRaw = source.rawValue
        self.notes = notes
        self.tags = tags
    }

    var source: BPSource { BPSource(rawValue: sourceRaw) ?? .manual }
    var timeOfDay: BPTimeOfDay { BPTimeOfDay(rawValue: timeOfDayRaw) ?? .morning }

    /// Mean arterial pressure, the standard one-third / two-thirds estimate.
    var meanArterialPressure: Double {
        Double(diastolic) + (Double(systolic - diastolic) / 3.0)
    }

    var pulsePressure: Int { systolic - diastolic }

    /// Shared plausibility definition so the entry form and the tests agree.
    static func isPlausible(systolic: Int, diastolic: Int) -> Bool {
        systolic >= 60 && systolic <= 300
            && diastolic >= 30 && diastolic <= 200
            && systolic > diastolic
    }
}
