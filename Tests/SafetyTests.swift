import Foundation
import Testing

@testable import BPCoach

/// The safety engine must be fully deterministic — same input, same output, every
/// time, with no model in the path.
@Suite("Safety rules")
struct SafetyTests {

    @Test("Normal readings produce no alert")
    func normalIsClear() {
        #expect(SafetyEngine.assess(systolic: 118, diastolic: 76).urgency == .none)
    }

    @Test("Crisis range asks about symptoms before deciding")
    func crisisAsksFirst() {
        let result = SafetyEngine.assess(systolic: 185, diastolic: 95)
        #expect(result.urgency == .urgent)
        #expect(result.showsSymptomCheck)
    }

    @Test("Crisis plus symptoms escalates to emergency")
    func symptomsEscalate() {
        let result = SafetyEngine.assess(systolic: 185, diastolic: 95, hasRedFlagSymptoms: true)
        #expect(result.urgency == .emergency)
        #expect(!result.showsSymptomCheck)
    }

    @Test("Crisis without symptoms advises re-measure and doctor contact")
    func noSymptomsDeescalates() {
        let result = SafetyEngine.assess(systolic: 185, diastolic: 95, hasRedFlagSymptoms: false)
        #expect(result.urgency == .urgent)
        #expect(!result.showsSymptomCheck)
    }

    @Test("Crisis threshold is exclusive at the boundary", arguments: [
        (180, 119, false), (181, 119, true), (180, 121, true), (179, 120, false),
    ])
    func crisisBoundary(systolic: Int, diastolic: Int, expectCrisis: Bool) {
        let result = SafetyEngine.assess(systolic: systolic, diastolic: diastolic)
        #expect(result.showsSymptomCheck == expectCrisis)
    }

    @Test("Diastolic alone can trigger crisis handling")
    func diastolicTriggersCrisis() {
        let result = SafetyEngine.assess(systolic: 130, diastolic: 125)
        #expect(result.showsSymptomCheck)
    }

    @Test("Low readings are flagged without alarm")
    func lowReading() {
        let result = SafetyEngine.assess(systolic: 85, diastolic: 55)
        #expect(result.urgency == .remeasure)
    }

    @Test("Assessment is deterministic across repeated calls")
    func deterministic() {
        let first = SafetyEngine.assess(systolic: 190, diastolic: 100, hasRedFlagSymptoms: true)
        for _ in 0..<50 {
            #expect(SafetyEngine.assess(systolic: 190, diastolic: 100, hasRedFlagSymptoms: true) == first)
        }
    }
}
