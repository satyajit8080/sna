import Foundation
import Testing

@testable import BPCoach

/// Boundary tests for both guidelines. Off-by-one at a category edge is the most
/// consequential bug this app could ship, so every threshold is pinned explicitly.
@Suite("Guideline boundaries")
struct GuidelineTests {

    let acc = ACCAHA2017Guideline()
    let esc = ESCESH2023Guideline()

    // MARK: - ACC/AHA 2017

    @Test("ACC/AHA systolic boundaries", arguments: [
        (119, "Normal"), (120, "Elevated"), (129, "Elevated"),
        (130, "Stage 1"), (139, "Stage 1"),
        (140, "Stage 2"), (180, "Stage 2"), (181, "Crisis"),
    ])
    func accSystolic(value: Int, expected: String) {
        #expect(acc.systolicCategory(value).label == expected)
    }

    @Test("ACC/AHA diastolic boundaries", arguments: [
        (79, "Normal"), (80, "Stage 1"), (89, "Stage 1"),
        (90, "Stage 2"), (120, "Stage 2"), (121, "Crisis"),
    ])
    func accDiastolic(value: Int, expected: String) {
        #expect(acc.diastolicCategory(value).label == expected)
    }

    @Test("ACC/AHA has no Elevated band for diastolic")
    func accDiastolicSkipsElevated() {
        // Elevated is defined as 120-129 systolic AND under 80 diastolic, so no
        // diastolic value on its own can produce it.
        for value in 30...200 {
            #expect(acc.diastolicCategory(value).label != "Elevated")
        }
    }

    // MARK: - Mixed components

    @Test("Category takes the more severe component")
    func mixedComponents() {
        // Systolic Elevated, diastolic Stage 1 -> Stage 1.
        #expect(acc.category(systolic: 125, diastolic: 85).label == "Stage 1")
        // Systolic Stage 2, diastolic Normal -> Stage 2.
        #expect(acc.category(systolic: 145, diastolic: 75).label == "Stage 2")
        // Both normal.
        #expect(acc.category(systolic: 110, diastolic: 70).label == "Normal")
    }

    @Test("Crisis in either component wins")
    func crisisDominates() {
        #expect(acc.category(systolic: 185, diastolic: 70).severity == .crisis)
        #expect(acc.category(systolic: 110, diastolic: 125).severity == .crisis)
    }

    @Test("Component disagreement is detectable")
    func disagreement() {
        #expect(acc.componentsDisagree(systolic: 125, diastolic: 85))
        #expect(!acc.componentsDisagree(systolic: 110, diastolic: 70))
    }

    // MARK: - ESC/ESH 2023

    @Test("ESC/ESH systolic boundaries", arguments: [
        (119, "Optimal"), (120, "Normal"), (129, "Normal"),
        (130, "High normal"), (139, "High normal"),
        (140, "Grade 1"), (159, "Grade 1"),
        (160, "Grade 2"), (179, "Grade 2"), (180, "Grade 3"),
    ])
    func escSystolic(value: Int, expected: String) {
        #expect(esc.systolicCategory(value).label == expected)
    }

    @Test("ESC/ESH diastolic boundaries", arguments: [
        (79, "Optimal"), (80, "Normal"), (84, "Normal"),
        (85, "High normal"), (89, "High normal"),
        (90, "Grade 1"), (99, "Grade 1"),
        (100, "Grade 2"), (109, "Grade 2"), (110, "Grade 3"),
    ])
    func escDiastolic(value: Int, expected: String) {
        #expect(esc.diastolicCategory(value).label == expected)
    }

    /// The same reading is labelled differently by the two guidelines. This is
    /// the behaviour that makes hard-coding a single guideline unacceptable.
    @Test("Guidelines disagree on the same reading")
    func guidelinesDiverge() {
        let acc135 = acc.category(systolic: 135, diastolic: 85)
        let esc135 = esc.category(systolic: 135, diastolic: 85)
        #expect(acc135.label == "Stage 1")
        #expect(esc135.label == "High normal")
        #expect(acc135.label != esc135.label)
    }

    @Test("Every guideline covers the full plausible range")
    func exhaustiveCoverage() {
        for guideline in [acc as BPGuideline, esc as BPGuideline] {
            for systolic in 60...300 {
                _ = guideline.systolicCategory(systolic)
            }
            for diastolic in 30...200 {
                _ = guideline.diastolicCategory(diastolic)
            }
        }
    }
}
