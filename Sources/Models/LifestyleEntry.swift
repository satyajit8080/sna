import Foundation
import SwiftData

enum LifestyleKind: String, Codable, CaseIterable, Sendable {
    case meal, sodium, caffeine, alcohol, stress, weight, sleep, activity

    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .meal: "fork.knife"
        case .sodium: "drop.fill"
        case .caffeine: "cup.and.saucer.fill"
        case .alcohol: "wineglass.fill"
        case .stress: "brain.head.profile"
        case .weight: "scalemass.fill"
        case .sleep: "bed.double.fill"
        case .activity: "figure.walk"
        }
    }
}

/// How a numeric value was arrived at. Estimates are labelled everywhere they
/// appear, including in doctor reports.
enum ValueProvenance: String, Codable, CaseIterable, Sendable {
    case userEntered, deviceMeasured, databaseLookup, estimated

    var isEstimate: Bool { self == .estimated }

    var label: String {
        switch self {
        case .userEntered: "Entered by you"
        case .deviceMeasured: "Measured"
        case .databaseLookup: "From food data"
        case .estimated: "Estimate"
        }
    }
}

@Model
final class LifestyleEntry {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var kindRaw: String = LifestyleKind.sodium.rawValue
    var recordedAt: Date = Date.now
    var value: Double = 0
    var unit: String = ""
    var label: String = ""
    var notes: String?
    var provenanceRaw: String = ValueProvenance.userEntered.rawValue

    init(
        profileID: UUID,
        kind: LifestyleKind,
        value: Double,
        unit: String,
        label: String,
        recordedAt: Date = .now,
        provenance: ValueProvenance = .userEntered
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.kindRaw = kind.rawValue
        self.value = value
        self.unit = unit
        self.label = label
        self.recordedAt = recordedAt
        self.provenanceRaw = provenance.rawValue
    }

    var kind: LifestyleKind { LifestyleKind(rawValue: kindRaw) ?? .sodium }
    var provenance: ValueProvenance { ValueProvenance(rawValue: provenanceRaw) ?? .userEntered }
    var isEstimate: Bool { provenance.isEstimate }
}
