import Foundation

/// 2023 ESC/ESH guideline for the management of arterial hypertension.
///
/// Uses optimal / normal / high-normal below the hypertension threshold, then
/// three grades above it. The threshold for hypertension is 140/90 — higher than
/// ACC/AHA, which is why the same reading can carry different labels depending
/// on which guideline is active.
struct ESCESH2023Guideline: BPGuideline {
    let id: BPGuidelineID = .escEsh2023
    let displayName = "ESC/ESH 2023"
    let citation = "ESH 2023 Guidelines for the management of arterial hypertension"

    static let optimal = BPCategory(identifier: "optimal", label: "Optimal", rank: 0, severity: .normal)
    static let normal = BPCategory(identifier: "normal", label: "Normal", rank: 1, severity: .normal)
    static let highNormal = BPCategory(identifier: "highNormal", label: "High normal", rank: 2, severity: .elevated)
    static let grade1 = BPCategory(identifier: "grade1", label: "Grade 1", rank: 3, severity: .mild)
    static let grade2 = BPCategory(identifier: "grade2", label: "Grade 2", rank: 4, severity: .moderate)
    static let grade3 = BPCategory(identifier: "grade3", label: "Grade 3", rank: 5, severity: .severe)

    var categories: [BPCategory] {
        [Self.optimal, Self.normal, Self.highNormal, Self.grade1, Self.grade2, Self.grade3]
    }

    func systolicCategory(_ value: Int) -> BPCategory {
        switch value {
        case ..<120: Self.optimal
        case 120...129: Self.normal
        case 130...139: Self.highNormal
        case 140...159: Self.grade1
        case 160...179: Self.grade2
        default: Self.grade3        // >= 180
        }
    }

    func diastolicCategory(_ value: Int) -> BPCategory {
        switch value {
        case ..<80: Self.optimal
        case 80...84: Self.normal
        case 85...89: Self.highNormal
        case 90...99: Self.grade1
        case 100...109: Self.grade2
        default: Self.grade3        // >= 110
        }
    }
}
