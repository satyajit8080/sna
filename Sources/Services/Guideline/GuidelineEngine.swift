import Foundation
import Observation
import SwiftUI

/// Holds the active guideline and resolves categories and their presentation.
///
/// Every category badge in the app goes through here. The design boards are
/// authoritative for layout only — never for clinical labels or thresholds.
@Observable
@MainActor
final class GuidelineEngine {

    private(set) var active: BPGuideline

    /// Static so it can be read during init, before all stored properties are
    /// assigned. An instance property here is a compile error.
    private static let defaultsKey = "guideline.active"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: Self.defaultsKey)
            .flatMap(BPGuidelineID.init(rawValue:)) ?? .accAha2017
        self.active = Self.guideline(for: stored)
        self.defaults = defaults
    }

    static func guideline(for id: BPGuidelineID) -> BPGuideline {
        switch id {
        case .accAha2017: ACCAHA2017Guideline()
        case .escEsh2023: ESCESH2023Guideline()
        case .custom: ACCAHA2017Guideline()   // until a custom set is configured
        }
    }

    func select(_ id: BPGuidelineID) {
        active = Self.guideline(for: id)
        defaults.set(id.rawValue, forKey: Self.defaultsKey)
    }

    func category(for reading: BPReading) -> BPCategory {
        active.category(for: reading)
    }

    func category(systolic: Int, diastolic: Int) -> BPCategory {
        active.category(systolic: systolic, diastolic: diastolic)
    }

    /// Presentation colour for a severity. Colour is a UI concern; the severity
    /// it renders is not.
    nonisolated static func color(for severity: BPCategory.Severity) -> Color {
        switch severity {
        case .normal: Theme.statusNormal
        case .elevated: Theme.statusElevated
        case .mild: Theme.statusMild
        case .moderate: Theme.statusModerate
        case .severe, .crisis: Theme.statusSevere
        }
    }

    func color(for reading: BPReading) -> Color {
        Self.color(for: category(for: reading).severity)
    }
}
