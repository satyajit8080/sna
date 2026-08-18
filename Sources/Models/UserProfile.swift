import Foundation
import SwiftData

enum ProfileKind: String, Codable, CaseIterable, Sendable {
    case owner, spouse, parent, other

    var label: String { rawValue.capitalized }

    /// HealthKit belongs to the device owner. Everyone else is manual-entry only.
    /// Enforced in `HealthKitService`, not merely in the UI.
    var canUseHealthKit: Bool { self == .owner }
}

@Model
final class UserProfile {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = ProfileKind.owner.rawValue
    var createdAt: Date = Date.now
    var dateOfBirth: Date?
    var guidelineIdentifier: String = BPGuidelineID.accAha2017.rawValue

    init(name: String, kind: ProfileKind = .owner, dateOfBirth: Date? = nil) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.dateOfBirth = dateOfBirth
    }

    var kind: ProfileKind { ProfileKind(rawValue: kindRaw) ?? .other }
    var isOwner: Bool { kind == .owner }
}
