import Foundation
import SwiftData

/// What the person usually does, and when.
///
/// Worth knowing for a reason beyond encouragement: blood pressure stays raised
/// for a while after exercise, so a reading taken shortly after the gym is high
/// for an ordinary reason. Without the routine, the app sees an unexplained
/// spike and the person sees a number that worries them.
///
/// Collected by tapping, not typing. It is a handful of fixed choices, and
/// asking someone to describe their week in a text box is a worse version of the
/// same question.
@Model
final class ActivityRoutine {
    var id: UUID = UUID()
    var profileID: UUID = UUID()

    /// Raw values of `ActivityKind`. Empty means asked and answered "nothing
    /// regular", which is different from never having been asked.
    var kindsRaw: [String] = []
    /// Raw value of `RoutineTime`.
    var timeRaw: String = RoutineTime.varies.rawValue
    /// Weekday numbers, 1 = Sunday, matching `Calendar`.
    var weekdays: [Int] = []
    var updatedAt: Date = Date.now

    init(profileID: UUID) {
        self.id = UUID()
        self.profileID = profileID
    }

    var kinds: [ActivityKind] {
        get { kindsRaw.compactMap(ActivityKind.init(rawValue:)) }
        set { kindsRaw = newValue.map(\.rawValue) }
    }

    var time: RoutineTime {
        get { RoutineTime(rawValue: timeRaw) ?? .varies }
        set { timeRaw = newValue.rawValue }
    }

    /// Nothing regular is a valid answer, and a useful one.
    var isActive: Bool { !kindsRaw.isEmpty }

    /// A sentence for the AI context, or nil when there is nothing to say.
    var summary: String? {
        guard isActive else { return "No regular exercise routine." }
        let what = kinds.map(\.label).joined(separator: ", ").lowercased()
        return "Usually does \(what), \(time.contextPhrase)."
    }
}

/// When the routine happens.
///
/// Coarse on purpose. "Morning" is enough to explain a raised reading at 8am;
/// asking for a precise time would be a worse question with no better answer.
enum RoutineTime: String, Codable, CaseIterable, Sendable {
    case morning, afternoon, evening, varies

    var label: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .varies: "It varies"
        }
    }

    var contextPhrase: String {
        switch self {
        case .morning: "usually in the morning"
        case .afternoon: "usually in the afternoon"
        case .evening: "usually in the evening"
        case .varies: "at no fixed time"
        }
    }

    /// The hours this covers, for judging whether a reading came soon after.
    var hourRange: ClosedRange<Int>? {
        switch self {
        case .morning: 5...11
        case .afternoon: 12...17
        case .evening: 18...22
        case .varies: nil
        }
    }
}
