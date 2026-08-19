import SwiftUI

/// Active profile switcher.
///
/// Lives here rather than inside a feature because More and Home both use it,
/// and a second copy would drift.
struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            ForEach(app.profiles) { profile in
                Button {
                    app.setActive(profile)
                } label: {
                    Label(
                        profile.name,
                        systemImage: profile.id == app.activeProfile.id ? "checkmark" : "person"
                    )
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.accent)
                Text(app.activeProfile.name).fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                Spacer()
                if !app.activeProfile.isOwner {
                    Text("Manual entry only")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(Theme.Spacing.md)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .accessibilityLabel("Active profile: \(app.activeProfile.name). Double tap to switch.")
    }
}

/// Deterministic safety guidance.
///
/// Wording comes from `SafetyEngine`, never from a language model, and the
/// colour follows the urgency rather than being chosen per screen.
struct SafetyBanner: View {
    let assessment: SafetyEngine.Assessment

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(assessment.title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            Text(assessment.message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(tint.opacity(0.12))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch assessment.urgency {
        case .emergency, .urgent: "exclamationmark.triangle.fill"
        case .contactDoctor: "phone.fill"
        default: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch assessment.urgency {
        case .emergency, .urgent: Theme.statusSevere
        case .contactDoctor, .remeasure: Theme.statusElevated
        case .none: Theme.textSecondary
        }
    }
}
