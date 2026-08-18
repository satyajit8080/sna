import Foundation
import SwiftUI

/// Severity-ordered category. Ordering is what makes `max(systolic, diastolic)`
/// meaningful, so `rank` is the single source of truth for comparison.
struct BPCategory: Equatable, Hashable, Sendable {
    let identifier: String
    let label: String
    let rank: Int
    let severity: Severity

    enum Severity: Int, Comparable, Sendable {
        case normal, elevated, mild, moderate, severe, crisis
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
}

extension BPCategory: Comparable {
    static func < (a: BPCategory, b: BPCategory) -> Bool { a.rank < b.rank }
}

enum BPGuidelineID: String, CaseIterable, Codable, Sendable {
    case accAha2017, escEsh2023, custom

    var displayName: String {
        switch self {
        case .accAha2017: "ACC/AHA 2017"
        case .escEsh2023: "ESC/ESH 2023"
        case .custom: "Custom"
        }
    }

    var summary: String {
        switch self {
        case .accAha2017:
            "United States. Calls 130/80 and above high blood pressure — a lower threshold than most other guidelines."
        case .escEsh2023:
            "Europe. Uses grades rather than stages and treats 140/90 as the threshold for hypertension."
        case .custom:
            "Thresholds you or your clinician have set. Use only on medical advice."
        }
    }
}

/// A blood pressure classification system.
///
/// Nothing in the app hard-codes a threshold. Every badge, colour and category
/// label resolves through the active guideline, so switching guidelines changes
/// what the user sees without rewriting stored readings.
protocol BPGuideline: Sendable {
    var id: BPGuidelineID { get }
    var displayName: String { get }
    var citation: String { get }
    var categories: [BPCategory] { get }

    func systolicCategory(_ value: Int) -> BPCategory
    func diastolicCategory(_ value: Int) -> BPCategory
}

extension BPGuideline {
    /// Category of a reading is the more severe of its two components.
    func category(systolic: Int, diastolic: Int) -> BPCategory {
        max(systolicCategory(systolic), diastolicCategory(diastolic))
    }

    func category(for reading: BPReading) -> BPCategory {
        category(systolic: reading.systolic, diastolic: reading.diastolic)
    }

    /// True when systolic and diastolic disagree — worth surfacing, because the
    /// displayed badge comes from only one of them.
    func componentsDisagree(systolic: Int, diastolic: Int) -> Bool {
        systolicCategory(systolic) != diastolicCategory(diastolic)
    }
}
