import SwiftUI
import StoreKit

/// The upgrade screen.
///
/// Written to be honest rather than urgent: no countdown, no fake scarcity, no
/// pre-ticked anything. Apple removed Cal AI over exactly that kind of
/// pattern, and beyond the review risk it is the wrong first impression for a
/// product whose whole pitch is trustworthiness.
///
/// Prices come from StoreKit — never hardcoded — so a change in App Store
/// Connect is reflected without a build.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(SubscriptionManager.self) private var store
    @Environment(EntitlementStore.self) private var entitlements

    var context: PaywallContext = .general
    /// Where this was opened from. Kept separate from `context` because two
    /// screens can raise the same context, and conversion is only meaningful
    /// when attributed to the actual entry point.
    var source: String = "unknown"

    @State private var selected: SnapCalProduct = .yearly
    @State private var purchasing = false
    @State private var restoring = false
    @State private var error: String?

    private var products: [Product] { store.products }

    private var chosen: Product? {
        products.first { $0.id == selected.rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    hero
                    benefits
                    plans
                    reassurance
                    Color.clear.frame(height: 140)
                }
                .padding(.horizontal, Theme.gutter)
            }
            .background(Theme.bg)
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .task {
                Analytics.track(.paywallViewed, ["context": context.rawValue, "source": source])
                await store.load()
            }
            .alert("Something went wrong", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, Theme.Space.m)

            Text(context.headline)
                .font(.jakarta(28, .bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(context.subhead)
                .font(.body_)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benefits: some View {
        VStack(spacing: Theme.Space.m) {
            ForEach(context.benefits) { benefit in
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: benefit.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 38, height: 38)
                        .background(Theme.accent.opacity(0.10), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(benefit.title)
                            .font(.jakarta(16, .semibold))
                        // The detail is what makes the claim credible. A bare
                        // tick list gets skimmed.
                        Text(benefit.detail)
                            .font(.jakarta(13, .medium))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var plans: some View {
        VStack(spacing: Theme.Space.s) {
            if products.isEmpty {
                // Never invent a price. If StoreKit hasn't answered, say so.
                HStack {
                    ProgressView().tint(Theme.secondary)
                    Text("Loading plans…")
                        .font(.jakarta(13, .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.l)
            } else {
                ForEach(SnapCalProduct.allCases, id: \.rawValue) { tier in
                    if let product = products.first(where: { $0.id == tier.rawValue }) {
                        planRow(tier, product)
                    }
                }
            }
        }
    }

    private func planRow(_ tier: SnapCalProduct, _ product: Product) -> some View {
        let isSelected = selected == tier
        let savings = tier.isYearly ? store.savingsPercent() : nil

        return Button {
            Haptics.tap()
            withAnimation(Theme.quick) { selected = tier }
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondary.opacity(0.45))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(tier.isYearly ? "Yearly" : "Monthly")
                            .font(.jakarta(16, .semibold))

                        if let savings, savings > 0 {
                            Text("Save \(savings)%")
                                .font(.jakarta(11, .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                        }
                    }

                    Text(store.priceString(for: product))
                        .font(.jakarta(13, .medium))
                        .foregroundStyle(Theme.secondary)
                }

                Spacer(minLength: 0)

                if tier.isYearly, let monthly = store.monthlyEquivalent(for: product) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(monthly)
                            .font(.jakarta(15, .bold))
                        Text("per month")
                            .font(.jakarta(10, .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(isSelected ? Theme.accent : .clear, lineWidth: 1.7)
            )
        }
        .buttonStyle(.plain)
    }

    private var reassurance: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Cancel anytime in Settings", systemImage: "checkmark.circle")
            Label("Your health data is never sold or used for ads", systemImage: "lock")
        }
        .font(.jakarta(12, .medium))
        .foregroundStyle(Theme.secondary)
    }

    private var purchaseBar: some View {
        VStack(spacing: Theme.Space.s) {
            Button {
                Task { await purchase() }
            } label: {
                if purchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(chosen == nil ? "Continue" : "Start \(selected.isYearly ? "yearly" : "monthly")")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(purchasing || chosen == nil)

            // Renewal terms in plain words, above the fold of the button. Apple
            // requires them disclosed; burying them is also just bad manners.
            if let product = chosen {
                Text("\(store.priceString(for: product)), renews automatically until cancelled.")
                    .font(.jakarta(11, .medium))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: Theme.Space.m) {
                Button("Restore") { Task { await restore() } }
                    .disabled(restoring)
                Link("Terms", destination: URL(string: "https://snapcal.app/terms")!)
                Link("Privacy", destination: URL(string: "https://snapcal.app/privacy")!)
            }
            .font(.jakarta(12, .medium))
            .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .background(.bar)
    }

    // MARK: - Actions

    private func purchase() async {
        guard let product = chosen else { return }
        purchasing = true
        defer { purchasing = false }

        Analytics.track(.purchaseStarted,
                        ["context": context.rawValue, "source": source,
                         "product": product.id])

        if await store.purchase(product) {
            Analytics.track(.purchaseCompleted,
                            ["context": context.rawValue, "source": source,
                             "product": product.id])
            Haptics.success()
            await app.refresh()
            dismiss()
        } else {
            // A cancelled purchase is not an error, and shouldn't look like one.
            if store.purchaseError != nil {
                Analytics.track(.purchaseFailed, ["context": context.rawValue, "source": source])
                error = "That didn't go through. You haven't been charged."
            }
        }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }

        Analytics.track(.restorePurchase, [:])
        await store.restore()
        await app.refresh()

        if store.isPro || entitlements.isPro {
            Haptics.success()
            dismiss()
        } else {
            error = "We couldn't find a subscription on this Apple ID."
        }
    }
}
