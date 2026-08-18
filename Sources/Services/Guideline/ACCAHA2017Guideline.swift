import Foundation

/// 2017 ACC/AHA guideline for the prevention, detection, evaluation and
/// management of high blood pressure in adults.
///
/// Note the structure: Normal and Elevated both require systolic AND diastolic
/// to be in range, while Stage 1 and Stage 2 are satisfied by EITHER. Taking the
/// more severe of the two component categories reproduces that exactly — a
/// reading of 125/85 lands in Stage 1 because the diastolic does, which is the
/// intended behaviour.
struct ACCAHA2017Guideline: BPGuideline {
    let id: BPGuidelineID = .accAha2017
    let displayName = "ACC/AHA 2017"
    let citation = "Whelton et al., 2017 ACC/AHA Hypertension Guideline"

    static let normal = BPCategory(identifier: "normal", label: "Normal", rank: 0, severity: .normal)
    static let elevated = BPCategory(identifier: "elevated", label: "Elevated", rank: 1, severity: .elevated)
    static let stage1 = BPCategory(identifier: "stage1", label: "Stage 1", rank: 2, severity: .mild)
    static let stage2 = BPCategory(identifier: "stage2", label: "Stage 2", rank: 3, severity: .moderate)
    static let crisis = BPCategory(identifier: "crisis", label: "Crisis", rank: 4, severity: .crisis)

    var categories: [BPCategory] { [Self.normal, Self.elevated, Self.stage1, Self.stage2, Self.crisis] }

    func systolicCategory(_ value: Int) -> BPCategory {
        switch value {
        case ..<120: Self.normal
        case 120...129: Self.elevated
        case 130...139: Self.stage1
        case 140...180: Self.stage2
        default: Self.crisis        // > 180
        }
    }

    func diastolicCategory(_ value: Int) -> BPCategory {
        switch value {
        case ..<80: Self.normal     // no Elevated band exists for diastolic
        case 80...89: Self.stage1
        case 90...120: Self.stage2
        default: Self.crisis        // > 120
        }
    }
}
