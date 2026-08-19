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

/// Brand tokens shared by the redesigned screens.
///
/// The Figma design is dark-only: a glowing accent on near-black, with each
/// health metric carrying its own colour. Those metric colours are the point —
/// steps, heart rate, sleep and weight are told apart at a glance rather than
/// by reading the labels.
///
/// Values are copied verbatim from the design rather than approximated.
enum Brand {

    // MARK: - Surfaces

    /// `#09111f` — page background and card fill. Cards are the same colour as
    /// the page; a hairline border separates them rather than a fill change.
    static let background = Color(hex: 0x09111F)
    static let cardStroke = Color.white.opacity(0.1)
    static let accent = Color(hex: 0x15B87B)
    /// `#091220` — text on an accent-filled control.
    static let onAccent = Color(hex: 0x091220)

    // MARK: - Text

    static let textPrimary = Color.white
    /// `#bbc8d7` — captions, units, supporting copy.
    static let textSecondary = Color(hex: 0xBBC8D7)
    /// `#7c7d89` — the quietest text, e.g. the greeting above a name.
    static let textTertiary = Color(hex: 0x7C7D89)
    /// `#9d9d9d` — unselected tab labels.
    static let tabInactive = Color(hex: 0x9D9D9D)

    // MARK: - Metric colours

    static let steps = Color(hex: 0x15B87B)
    static let restingHeartRate = Color(hex: 0xF1595C)
    static let sleep = Color(hex: 0x835FCD)
    static let weight = Color(hex: 0x5296ED)
    static let medication = Color(hex: 0x8664C3)
    /// `#2b975e` — progress bars for sodium and movement.
    static let progress = Color(hex: 0x2B975E)

    // MARK: - Metrics

    enum Metric {
        static let pagePadding: CGFloat = 25
        static let cardRadius: CGFloat = 16
        /// The 2×2 metric tiles use a slightly larger radius than wide cards.
        static let tileRadius: CGFloat = 18
        static let iconTile: CGFloat = 41
        static let iconTileRadius: CGFloat = 6
        static let progressHeight: CGFloat = 7
        static let barHeight: CGFloat = 5
        static let pillRadius: CGFloat = 11
    }
}

/// Card in the brand style: same fill as the page, separated by a hairline.
struct BrandCard<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = Brand.Metric.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.background)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Brand.cardStroke, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Rounded square behind a metric icon, tinted to that metric's colour at 10%.
struct BrandIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = Brand.Metric.iconTile

    var body: some View {
        RoundedRectangle(cornerRadius: Brand.Metric.iconTileRadius, style: .continuous)
            .fill(tint.opacity(0.1))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

/// Track-and-fill bar. The track is the same colour at 10%, which is what makes
/// a part-filled bar read as progress rather than as two unrelated shapes.
struct BrandProgressBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = Brand.Metric.progressHeight

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Small status pill, e.g. the category beside a reading.
struct BrandPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .frame(height: 22)
            .background(tint.opacity(0.2))
            .clipShape(Capsule())
    }
}
