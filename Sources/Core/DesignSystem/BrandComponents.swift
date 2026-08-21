import SwiftUI

/// Screen title with an optional back button and trailing actions.
///
/// The design puts the title centred with circular 35pt controls either side,
/// which is not what `navigationTitle` produces — hence a custom header.
struct BrandHeader: View {
    let title: String
    var subtitle: String?
    var showsBack = false
    var onBack: (() -> Void)?
    var trailing: [(symbol: String, action: () -> Void)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if showsBack {
                    circleButton("chevron.left") { onBack?() }
                        .accessibilityLabel("Back")
                }

                if subtitle == nil {
                    Spacer()
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)
                        Text(subtitle ?? "")
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Spacer()
                }

                ForEach(Array(trailing.enumerated()), id: \.offset) { _, item in
                    circleButton(item.symbol, action: item.action)
                }
            }
        }
        .padding(.top, 8)
    }

    /// Filled rather than outlined, as in the design — a subtle lift off the
    /// page rather than a hairline ring.
    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 35, height: 35)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.textPrimary)
                }
        }
        .buttonStyle(.plain)
    }
}

/// The intro card at the top of most screens: a headline, a line of copy, and a
/// large circular glyph on the right.
struct BrandHeroCard: View {
    let title: String
    let message: String
    let symbol: String
    var bullets: [String] = []

    var body: some View {
        BrandCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(bullets, id: \.self) { bullet in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Brand.accent)
                                    Text(bullet)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Brand.textPrimary)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }

                Circle()
                    .fill(Brand.accent.opacity(0.1))
                    .frame(width: 69, height: 69)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 30))
                            .foregroundStyle(Brand.accent)
                    }
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The standard row used across Add, Scan, More and the appointment screens.
struct BrandListRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: Color = Brand.accent
    var isAvailable = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BrandCard(padding: 12) {
                HStack(spacing: 14) {
                    BrandIconTile(symbol: symbol, tint: tint, size: 49)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(isAvailable ? Brand.textPrimary : Brand.textSecondary)
                            if !isAvailable {
                                Text("Unavailable")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Brand.cardStroke)
                                    .foregroundStyle(Brand.textSecondary)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)

                    if isAvailable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityElement(children: .combine)
    }
}

/// Full-width accent button, as used at the bottom of most detail screens.
struct BrandPrimaryButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(isEnabled ? Brand.accent : Brand.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Section heading with an optional trailing link.
struct BrandSectionHeader<Destination: View>: View {
    let title: String
    var actionTitle: String?
    @ViewBuilder var destination: Destination

    init(
        _ title: String,
        actionTitle: String? = nil,
        @ViewBuilder destination: () -> Destination = { EmptyView() }
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.destination = destination()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Spacer()
            if let actionTitle {
                NavigationLink { destination } label: {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Brand.accent)
                }
            }
        }
    }
}

/// Screen scaffold: dark background, standard padding, hidden nav bar.
struct BrandScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // The background is a modifier rather than a ZStack child. As a child
        // that ignores the safe area it enlarges the container past the screen
        // edge, and anything filling it is pushed out of view.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(.horizontal, Brand.Metric.pagePadding)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }
}
