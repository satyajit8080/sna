import SwiftUI

/// Design tokens for onboarding, taken from the Figma file.
///
/// Onboarding is deliberately dark in both appearances. The design is a
/// dark-only composition — a glowing accent on near-black — and rendering it
/// against the light `Theme.background` would lose the glow entirely and leave
/// the accent unreadable. The rest of the app still follows the system
/// appearance; this is the one fixed-appearance surface.
///
/// Hex values are copied verbatim from the design rather than approximated.
enum OnboardingTheme {

    // MARK: - Surfaces

    /// `#09111f` — page background and unselected card fill.
    static let background = Color(hex: 0x09111F)
    /// `#101824` — the logo tile behind the glow.
    static let logoTile = Color(hex: 0x101824)
    /// `#06090e` — text on the accent button. Near-black, not pure black.
    static let onAccent = Color(hex: 0x06090E)

    // MARK: - Accent and text

    /// `#15b87b` — the single accent throughout onboarding.
    static let accent = Color(hex: 0x15B87B)
    static let textPrimary = Color.white
    /// `#bbc8d7` — body copy and captions.
    static let textSecondary = Color(hex: 0xBBC8D7)

    // MARK: - Strokes and fills

    static let cardStroke = Color.white.opacity(0.1)
    static let selectedCardFill = accent.opacity(0.1)
    static let selectedCardStroke = accent.opacity(0.5)
    static let badgeFill = Color.white.opacity(0.1)
    static let iconTileFill = accent.opacity(0.1)
    static let progressInactive = Color.white.opacity(0.2)

    // MARK: - Metrics

    enum Metric {
        static let horizontalPadding: CGFloat = 25
        static let cardRadius: CGFloat = 16
        static let buttonHeight: CGFloat = 50
        /// Fully rounded: half of `buttonHeight`.
        static let buttonRadius: CGFloat = 25
        static let iconTile: CGFloat = 50
        static let iconTileRadius: CGFloat = 8
        static let logoTile: CGFloat = 70
        static let logoTileRadius: CGFloat = 15
        static let progressHeight: CGFloat = 4
        static let progressRadius: CGFloat = 10
        static let badgeHeight: CGFloat = 22
    }

    /// The glow behind the logo tile. Figma specifies a 124pt spread; SwiftUI's
    /// shadow radius is roughly half a CSS blur, so it is halved here.
    static let logoGlowRadius: CGFloat = 62
}

extension Color {
    /// Single-value hex initialiser, for colours that are identical in both
    /// appearances. `Color(light:dark:)` covers the adaptive cases.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
