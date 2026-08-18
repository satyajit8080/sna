import Foundation
import SwiftData

enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case walk, run, cycle, swim, gym, yoga, other

    var label: String {
        switch self {
        case .walk: "Walk"
        case .run: "Run"
        case .cycle: "Cycle"
        case .swim: "Swim"
        case .gym: "Gym"
        case .yoga: "Yoga"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .cycle: "figure.outdoor.cycle"
        case .swim: "figure.pool.swim"
        case .gym: "dumbbell"
        case .yoga: "figure.mind.and.body"
        case .other: "figure.mixed.cardio"
        }
    }
}

/// A manually logged workout.
///
/// Separate from `LifestyleEntry` because activity has structure that a single
/// value cannot carry — type, duration and optional distance — and because
/// HealthKit-sourced activity is read live rather than stored.
@Model
final class ActivityEntry {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var kindRaw: String = ActivityKind.walk.rawValue
    var startedAt: Date = Date.now
    var minutes: Int = 0
    var distanceKilometres: Double?
    var steps: Int?
    var notes: String?
    var sourceRaw: String = BPSource.manual.rawValue

    init(
        profileID: UUID,
        kind: ActivityKind,
        minutes: Int,
        startedAt: Date = .now,
        distanceKilometres: Double? = nil,
        steps: Int? = nil,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.kindRaw = kind.rawValue
        self.minutes = minutes
        self.startedAt = startedAt
        self.distanceKilometres = distanceKilometres
        self.steps = steps
        self.notes = notes
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .walk }
}
