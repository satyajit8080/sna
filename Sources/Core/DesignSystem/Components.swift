import SwiftUI

/// Standard card container.
struct CardView<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

/// Category badge. Text always accompanies the colour — colour alone is not an
/// accessible way to communicate severity.
struct CategoryBadge: View {
    let category: BPCategory
    var compact = false

    var body: some View {
        Text(category.label)
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .foregroundStyle(.white)
            .background(GuidelineEngine.color(for: category.severity))
            .clipShape(Capsule())
            .accessibilityLabel("Category: \(category.label)")
    }
}

/// The large systolic-over-diastolic display.
struct BPValueView: View {
    let systolic: Int
    let diastolic: Int
    var pulse: Int?
    var size: CGFloat = 44

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(systolic)").font(Theme.number(size, weight: .bold))
                Text("/").font(Theme.number(size * 0.7, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("\(diastolic)").font(Theme.number(size, weight: .bold))
            }
            Text("mmHg")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)

            if let pulse {
                Spacer(minLength: Theme.Spacing.sm)
                Label("\(pulse)", systemImage: "heart.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.pulseColor)
                    .accessibilityLabel("Pulse \(pulse) beats per minute")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(systolic) over \(diastolic) millimetres of mercury"
        if let pulse { text += ", pulse \(pulse)" }
        return text
    }
}

/// Compact metric tile used across Home and History.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var tint: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.number(22, weight: .semibold))
                .foregroundStyle(tint)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when a section has no data. States what is missing and what to do —
/// never a fake number or a placeholder chart.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }
}

/// Marks a value the app inferred rather than measured. Required wherever an
/// estimate is displayed, including in exports.
struct EstimateTag: View {
    var body: some View {
        Text("Estimate")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accentSoft)
            .foregroundStyle(Theme.accent)
            .clipShape(Capsule())
            .accessibilityLabel("This value is an estimate")
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
