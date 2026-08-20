import SwiftUI
import UIKit

/// Design tokens. System fonts by default — Dynamic Type works out of the box and
/// nothing silently falls back to a font that was never bundled.
///
/// Every colour here is defined for both light and dark. Status colours are
/// deliberately distinguishable without relying on hue alone: severity also
/// changes the badge's weight and its accompanying text.
/// The original token set.
///
/// Its colours now resolve to the `Brand` palette so screens that have not yet
/// been redesigned still render dark and on-brand. Layout and typography in
/// those screens is unchanged; only the colours follow. Each will be rebuilt
/// against the Figma in turn.
enum Theme {

    // MARK: - Brand

    static let accent = Brand.accent
    static let accentSoft = Brand.accent.opacity(0.15)

    // MARK: - Surfaces

    static let background = Brand.background
    static let surface = Brand.background
    static let surfaceRaised = Brand.background
    static let border = Brand.cardStroke

    // MARK: - Text

    static let textPrimary = Brand.textPrimary
    static let textSecondary = Brand.textSecondary
    static let textTertiary = Brand.textSecondary

    // MARK: - Status
    // Mapped from BPCategory.Severity, never from a screen mockup.

    static let statusNormal = Color(light: 0x0E9F6E, dark: 0x34D399)
    static let statusElevated = Color(light: 0xB45309, dark: 0xFBBF24)
    static let statusMild = Color(light: 0xC2410C, dark: 0xFB923C)
    static let statusModerate = Color(light: 0xB91C1C, dark: 0xF87171)
    static let statusSevere = Color(light: 0x7F1D1D, dark: 0xEF4444)

    // MARK: - Metrics

    static let systolicColor = Brand.restingHeartRate
    static let diastolicColor = Brand.weight
    static let pulseColor = Brand.sleep

    // MARK: - Layout

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let pill: CGFloat = 999
    }

    // MARK: - Typography
    // Rounded design for numerals reads better at a glance on a health dashboard.

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    /// Hex initialiser with explicit light and dark values, so no colour is
    /// defined for only one appearance.
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
