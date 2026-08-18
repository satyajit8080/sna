import Foundation
import SwiftData

/// Symptoms a user can log alongside readings.
///
/// The list is deliberately fixed rather than free text: a closed vocabulary is
/// what makes "you logged headaches on four of your five highest mornings"
/// possible. `other` carries a note for anything not covered.
enum SymptomKind: String, Codable, CaseIterable, Sendable {
    case headache, dizziness, chestDiscomfort, breathlessness
    case palpitations, blurredVision, fatigue, nausea
    case swelling, nosebleed, anxiety, other

    var label: String {
        switch self {
        case .headache: "Headache"
        case .dizziness: "Dizziness"
        case .chestDiscomfort: "Chest discomfort"
        case .breathlessness: "Breathlessness"
        case .palpitations: "Palpitations"
        case .blurredVision: "Blurred vision"
        case .fatigue: "Fatigue"
        case .nausea: "Nausea"
        case .swelling: "Swelling"
        case .nosebleed: "Nosebleed"
        case .anxiety: "Anxiety"
        case .other: "Something else"
        }
    }

    var symbol: String {
        switch self {
        case .headache: "brain.head.profile"
        case .dizziness: "arrow.trianglehead.2.clockwise.rotate.90"
        case .chestDiscomfort: "heart.slash"
        case .breathlessness: "lungs"
        case .palpitations: "waveform.path.ecg"
        case .blurredVision: "eye.trianglebadge.exclamationmark"
        case .fatigue: "zzz"
        case .nausea: "face.dashed"
        case .swelling: "hand.raised"
        case .nosebleed: "drop"
        case .anxiety: "wind"
        case .other: "questionmark.circle"
        }
    }

    /// Symptoms that, alongside a crisis-range reading, escalate to emergency.
    ///
    /// This mirrors `SafetyEngine.RedFlagSymptom`. Logging one of these does not
    /// itself trigger an alert — `SafetyEngine` owns that decision — but the
    /// flag lets the UI prompt appropriately.
    var isRedFlag: Bool {
        switch self {
        case .chestDiscomfort, .breathlessness, .blurredVision: true
        default: false
        }
    }
}

enum SymptomSeverity: Int, Codable, CaseIterable, Sendable {
    case mild = 1, moderate = 2, severe = 3

    var label: String {
        switch self {
        case .mild: "Mild"
        case .moderate: "Moderate"
        case .severe: "Severe"
        }
    }
}

@Model
final class SymptomEntry {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var kindRaw: String = SymptomKind.headache.rawValue
    var severityRaw: Int = SymptomSeverity.mild.rawValue
    var recordedAt: Date = Date.now
    var notes: String?
    /// Set when logged immediately after a reading, so the two can be correlated.
    var relatedReadingID: UUID?

    init(
        profileID: UUID,
        kind: SymptomKind,
        severity: SymptomSeverity,
        recordedAt: Date = .now,
        notes: String? = nil,
        relatedReadingID: UUID? = nil
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.kindRaw = kind.rawValue
        self.severityRaw = severity.rawValue
        self.recordedAt = recordedAt
        self.notes = notes
        self.relatedReadingID = relatedReadingID
    }

    var kind: SymptomKind { SymptomKind(rawValue: kindRaw) ?? .other }
    var severity: SymptomSeverity { SymptomSeverity(rawValue: severityRaw) ?? .mild }
}
