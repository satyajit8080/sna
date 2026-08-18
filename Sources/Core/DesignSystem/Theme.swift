import SwiftUI

/// Design tokens. System fonts by default — Dynamic Type works out of the box and
/// nothing silently falls back to a font that was never bundled.
///
/// Every colour here is defined for both light and dark. Status colours are
/// deliberately distinguishable without relying on hue alone: severity also
/// changes the badge's weight and its accompanying text.
enum Theme {

    // MARK: - Brand

    static let accent = Color(light: 0x0F766E, dark: 0x2DD4BF)
    static let accentSoft = Color(light: 0xCCFBF1, dark: 0x134E4A)

    // MARK: - Surfaces

    static let background = Color(light: 0xF7F8FA, dark: 0x0B0F14)
    static let surface = Color(light: 0xFFFFFF, dark: 0x151B23)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x1D252F)
    static let border = Color(light: 0xE3E7EC, dark: 0x2A3441)

    // MARK: - Text

    static let textPrimary = Color(light: 0x0D1218, dark: 0xF2F5F8)
    static let textSecondary = Color(light: 0x5A6472, dark: 0x9AA6B4)
    static let textTertiary = Color(light: 0x8B95A3, dark: 0x6B7480)

    // MARK: - Status
    // Mapped from BPCategory.Severity, never from a screen mockup.

    static let statusNormal = Color(light: 0x0E9F6E, dark: 0x34D399)
    static let statusElevated = Color(light: 0xB45309, dark: 0xFBBF24)
    static let statusMild = Color(light: 0xC2410C, dark: 0xFB923C)
    static let statusModerate = Color(light: 0xB91C1C, dark: 0xF87171)
    static let statusSevere = Color(light: 0x7F1D1D, dark: 0xEF4444)

    // MARK: - Metrics

    static let systolicColor = Color(light: 0x1D4ED8, dark: 0x60A5FA)
    static let diastolicColor = Color(light: 0x7C3AED, dark: 0xA78BFA)
    static let pulseColor = Color(light: 0xBE185D, dark: 0xF472B6)

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
