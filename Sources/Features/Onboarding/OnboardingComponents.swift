import SwiftUI

/// Five-segment step indicator across the top.
struct OnboardingProgress: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? OnboardingTheme.accent : OnboardingTheme.progressInactive)
                    .frame(height: OnboardingTheme.Metric.progressHeight)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(total)")
    }
}

/// The glowing app mark at the top of each screen.
struct OnboardingLogo: View {
    let symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: OnboardingTheme.Metric.logoTileRadius, style: .continuous)
            .fill(OnboardingTheme.logoTile)
            .frame(width: OnboardingTheme.Metric.logoTile, height: OnboardingTheme.Metric.logoTile)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(OnboardingTheme.accent)
            }
            .shadow(color: OnboardingTheme.accent.opacity(0.55),
                    radius: OnboardingTheme.logoGlowRadius)
            .accessibilityHidden(true)
    }
}

/// Two-tone title: accent first word, white remainder.
struct OnboardingTitle: View {
    let accented: String
    let plain: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            (
                Text(accented).foregroundStyle(OnboardingTheme.accent)
                    + Text(plain).foregroundStyle(OnboardingTheme.textPrimary)
            )
            .font(.system(size: 35, weight: .bold))
            .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(OnboardingTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hairline that fades out at both ends.
struct OnboardingDivider: View {
    var body: some View {
        LinearGradient(
            colors: [
                OnboardingTheme.accent.opacity(0),
                OnboardingTheme.accent.opacity(0.5),
                OnboardingTheme.accent.opacity(0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

/// Icon tile beside a feature line.
struct OnboardingFeatureRow<Content: View>: View {
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 17) {
            RoundedRectangle(cornerRadius: OnboardingTheme.Metric.iconTileRadius, style: .continuous)
                .fill(OnboardingTheme.iconTileFill)
                .frame(width: OnboardingTheme.Metric.iconTile,
                       height: OnboardingTheme.Metric.iconTile)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(OnboardingTheme.accent)
                }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Full-width pill button.
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnboardingTheme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: OnboardingTheme.Metric.buttonHeight)
                .background(OnboardingTheme.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingTheme.accent)
        }
        .buttonStyle(.plain)
    }
}

/// The 120 / 80 / 72 sample reading, with hairline separators.
struct SampleReadingCard: View {
    var body: some View {
        HStack(spacing: 0) {
            metric("120", "Systolic")
            separator
            metric("80", "Diastolic")
            separator
            metric("72", "Pulse")
        }
        .frame(height: 78)
        .background(OnboardingTheme.background)
        .overlay {
            RoundedRectangle(cornerRadius: OnboardingTheme.Metric.cardRadius, style: .continuous)
                .strokeBorder(OnboardingTheme.cardStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.Metric.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example reading: 120 over 80, pulse 72")
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(OnboardingTheme.textPrimary)
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Rectangle()
            .fill(OnboardingTheme.cardStroke)
            .frame(width: 1, height: 44)
    }
}

/// Selectable guideline card.
struct GuidelineOptionCard: View {
    let id: BPGuidelineID
    let region: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(isSelected ? OnboardingTheme.accent : OnboardingTheme.textSecondary)

                    Text(id.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.textPrimary)

                    if let region {
                        Text(region)
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .frame(height: OnboardingTheme.Metric.badgeHeight)
                            .background(OnboardingTheme.badgeFill)
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }

                // The threshold inside each summary is emphasised in the design,
                // since the number is the whole point of the choice.
                Text(highlighted(id.summary))
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 27)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? OnboardingTheme.selectedCardFill : OnboardingTheme.background)
            .overlay {
                RoundedRectangle(cornerRadius: OnboardingTheme.Metric.cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? OnboardingTheme.selectedCardStroke : OnboardingTheme.cardStroke,
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.Metric.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Renders "130/80"-style thresholds in the accent colour.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for threshold in ["130/80", "140/90", "135/85"] {
            if let range = attributed.range(of: threshold) {
                attributed[range].foregroundColor = OnboardingTheme.accent
                attributed[range].font = .system(size: 13, weight: .bold)
            }
        }
        return attributed
    }
}
