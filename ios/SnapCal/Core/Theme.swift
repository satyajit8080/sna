import SwiftUI
import UIKit

/// One source of truth for the visual language. Deliberately restrained:
/// a single accent, generous type scale, no decorative chrome.
enum Theme {
    // Values below come from the Figma file. Names are unchanged so a palette
    // revision stays a one-file edit.
    static let accent      = Color(hex: 0x15B87B)
    static let accentSoft  = Color(hex: 0x15B87B).opacity(0.10)
    static let protein     = Color(hex: 0x15B87B)
    static let carbs       = Color(hex: 0x60A5FA)
    static let fat         = Color(hex: 0xFB923C)
    static let danger      = Color(hex: 0xEF4444)

    /// Metric tile accents.
    static let steps       = Color(hex: 0x15B87B)
    static let weight      = Color(hex: 0x5296ED)
    static let activeCal   = Color(hex: 0xEC5F28)
    static let water       = Color(hex: 0x997AF3)
    static let streak      = Color(hex: 0xF86A3C)

    /// Secondary label used throughout the design.
    static let secondary   = Color(hex: 0x7C7D89)

    static let bg          = Color("Background")   // asset: #F1F1F1 / #0B0B0C
    static let card        = Color("Card")         // asset: #FFFFFF / #161618
    static let hairline    = Color.primary.opacity(0.07)

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 16
        static let l: CGFloat = 24, xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 17      // Today Overview + metric tiles
        static let row: CGFloat = 13       // meal rows
        static let control: CGFloat = 11
        static let tile: CGFloat = 6       // small icon squares
        static let pill: CGFloat = 999
    }

    /// Screen gutter from the design (25pt, not the 16pt default).
    static let gutter: CGFloat = 25

    /// Fast, never bouncy — the app must feel instant, not playful.
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.18)
}

extension Font {
    /// Plus Jakarta Sans, per the design.
    ///
    /// Falls back to the system font when the family is not bundled, so the
    /// app never renders in Times New Roman if the .ttf files are missing —
    /// it just looks like stock iOS until they are added.
    static func jakarta(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "PlusJakartaSans-Bold"
        case .semibold:             name = "PlusJakartaSans-SemiBold"
        case .medium:               name = "PlusJakartaSans-Medium"
        default:                    name = "PlusJakartaSans-Regular"
        }
        guard UIFont(name: name, size: size) != nil else {
            return .system(size: size, weight: weight, design: .default)
        }
        return .custom(name, size: size)
    }

    // Design type scale.
    static let hero     = Font.jakarta(56, .bold)
    static let bigNum   = Font.jakarta(20, .bold)      // tile values, ring total
    static let title    = Font.jakarta(20, .bold)      // screen greeting
    static let section  = Font.jakarta(16, .bold)      // "Today Overview"
    static let rowTitle = Font.jakarta(16, .bold)      // "Breakfast"
    static let body_    = Font.jakarta(16, .regular)
    static let label    = Font.jakarta(13, .semibold)
    static let caption_ = Font.jakarta(12, .semibold)
    static let micro    = Font.jakarta(10, .semibold)  // timestamps, "kcal"
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
    var radius: CGFloat = Theme.Radius.card
    var padding: CGFloat = Theme.Space.m

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func card(radius: CGFloat = Theme.Radius.card,
              padding: CGFloat = Theme.Space.m) -> some View {
        modifier(CardModifier(radius: radius, padding: padding))
    }
}

/// Tinted rounded square behind a metric icon.
struct IconTile: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 41

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
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
