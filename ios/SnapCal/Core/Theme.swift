import SwiftUI

/// One source of truth for the visual language. Deliberately restrained:
/// a single accent, generous type scale, no decorative chrome.
enum Theme {
    // Accent: a warm signal green that reads as "on track" without looking clinical.
    static let accent      = Color(hex: 0x14B87A)
    static let accentSoft  = Color(hex: 0x14B87A).opacity(0.14)
    static let protein     = Color(hex: 0x3B82F6)
    static let carbs       = Color(hex: 0xF59E0B)
    static let fat         = Color(hex: 0xEC4899)
    static let danger      = Color(hex: 0xEF4444)

    static let bg          = Color("Background")   // asset: #FAFAF8 / #0B0B0C
    static let card        = Color("Card")         // asset: #FFFFFF / #161618
    static let hairline    = Color.primary.opacity(0.07)

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 16
        static let l: CGFloat = 24, xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 20, pill: CGFloat = 999, control: CGFloat = 14
    }

    /// Fast, never bouncy — the app must feel instant, not playful.
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.18)
}

extension Font {
    static let hero    = Font.system(size: 56, weight: .bold, design: .rounded).monospacedDigit()
    static let bigNum  = Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    static let title   = Font.system(size: 22, weight: .semibold)
    static let body_   = Font.system(size: 16, weight: .regular)
    static let label   = Font.system(size: 13, weight: .medium)
    static let caption_ = Font.system(size: 12, weight: .regular)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.m)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(Theme.accent, in: Capsule())
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}
