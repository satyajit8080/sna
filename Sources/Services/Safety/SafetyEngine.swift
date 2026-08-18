import Foundation

/// Deterministic safety assessment for a single reading.
///
/// This engine is entirely rule-based. The AI never sees this decision path and
/// never decides urgency — a language model must not be the thing standing
/// between a user and an ambulance.
///
/// Thresholds follow the widely-shared hypertensive crisis definition used by
/// both ACC/AHA and ESC/ESH: systolic above 180 or diastolic above 120.
enum SafetyEngine {

    enum Urgency: Int, Comparable, Sendable {
        case none, remeasure, contactDoctor, urgent, emergency
        static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
    }

    struct Assessment: Equatable, Sendable {
        let urgency: Urgency
        let title: String
        let message: String
        let showsSymptomCheck: Bool

        static let clear = Assessment(
            urgency: .none,
            title: "",
            message: "",
            showsSymptomCheck: false
        )
    }

    /// Symptoms that turn a crisis-range reading from "re-measure and call your
    /// doctor" into "this is an emergency". Wording is fixed and approved; it is
    /// never generated.
    enum RedFlagSymptom: String, CaseIterable, Identifiable, Sendable {
        case chestPain = "Chest pain or pressure"
        case breathlessness = "Shortness of breath"
        case weaknessOrNumbness = "Weakness or numbness on one side"
        case speechDifficulty = "Trouble speaking or understanding"
        case visionChange = "Sudden vision change"
        case severeHeadache = "Severe, unusual headache"
        case confusion = "Confusion"
        case backPain = "Severe back pain"

        var id: String { rawValue }
    }

    static let crisisSystolic = 180
    static let crisisDiastolic = 120
    static let lowSystolic = 90
    static let lowDiastolic = 60

    /// Assess a reading in isolation. `hasRedFlagSymptoms` is nil when the user
    /// has not been asked yet.
    static func assess(
        systolic: Int,
        diastolic: Int,
        hasRedFlagSymptoms: Bool? = nil
    ) -> Assessment {

        let inCrisisRange = systolic > crisisSystolic || diastolic > crisisDiastolic

        if inCrisisRange {
            if hasRedFlagSymptoms == true {
                return Assessment(
                    urgency: .emergency,
                    title: "Seek emergency care now",
                    message: """
                    This reading is very high and you have reported symptoms that need \
                    immediate attention. Call your local emergency number now. Do not \
                    wait to re-measure and do not drive yourself.
                    """,
                    showsSymptomCheck: false
                )
            }

            if hasRedFlagSymptoms == nil {
                return Assessment(
                    urgency: .urgent,
                    title: "This reading is very high",
                    message: """
                    Before anything else — are you having any symptoms right now? \
                    Your answer changes what you should do next.
                    """,
                    showsSymptomCheck: true
                )
            }

            return Assessment(
                urgency: .urgent,
                title: "Re-measure, then call your doctor",
                message: """
                Rest quietly for five minutes and measure again. If the second reading \
                is still above \(crisisSystolic)/\(crisisDiastolic), contact your doctor \
                straight away. Go to emergency care if symptoms begin.
                """,
                showsSymptomCheck: false
            )
        }

        if systolic >= 140 || diastolic >= 90 {
            return Assessment(
                urgency: .remeasure,
                title: "Higher than usual",
                message: """
                Rest for five minutes and measure again to confirm. A single high \
                reading is common and often settles on repeat.
                """,
                showsSymptomCheck: false
            )
        }

        if systolic < lowSystolic || diastolic < lowDiastolic {
            return Assessment(
                urgency: .remeasure,
                title: "This reading is low",
                message: """
                Low readings are often harmless, but tell your doctor if you feel \
                dizzy, faint or unwell.
                """,
                showsSymptomCheck: false
            )
        }

        return .clear
    }

    static func assess(_ reading: BPReading, hasRedFlagSymptoms: Bool? = nil) -> Assessment {
        assess(
            systolic: reading.systolic,
            diastolic: reading.diastolic,
            hasRedFlagSymptoms: hasRedFlagSymptoms
        )
    }
}
