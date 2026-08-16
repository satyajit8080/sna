import SwiftUI
import StoreKit

/// Context-aware paywall: the copy speaks to whatever the user just tried to
/// do. A generic offer converts worse than one that names the blocked action.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var store
    @Environment(EntitlementStore.self) private var entitlements

    var context: PaywallContext = .general
    var source: String = "unknown"

    @State private var selected: SnapCalProduct = .monthly

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                header
                benefits
                plans

                Button {
                    guard let product = store.products.first(where: { $0.id == selected.rawValue }) else { return }
                    Analytics.track(.purchaseStarted, ["product": product.id, "source": source])
                    Task {
                        if await store.purchase(product) {
                            Analytics.track(.purchaseCompleted, ["product": product.id, "source": source])
                            await entitlements.refresh()
                            dismiss()
                        } else if store.purchaseError != nil {
                            Analytics.track(.purchaseFailed, ["product": product.id])
                        }
                    }
                } label: {
                    if store.isPurchasing { ProgressView().tint(.white) } else { Text("Unlock Premium") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.products.isEmpty || store.isPurchasing)

                Button("Maybe Later") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                footer
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.bg)
        .overlay(alignment: .top) {
            if EntitlementStore.testingUnlock {
                Text("TESTING BUILD — premium already unlocked")
                    .font(.jakarta(11, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.streak, in: Capsule())
                    .padding(.top, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                    .padding(9).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain).padding(Theme.Space.m)
        }
        .task {
            Analytics.track(.paywallViewed, ["context": context.rawValue, "source": source])
            if store.products.isEmpty { await store.load() }
        }
        .alert("Purchase failed", isPresented: .constant(store.purchaseError != nil)) {
            Button("OK") {}
        } message: { Text(store.purchaseError ?? "") }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent)

            Text(context.headline)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(context.subhead)
                .font(.body_).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Space.l)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(context.benefits, id: \.self) { benefit in
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                    Text(benefit).font(.body_)
                    Spacer(minLength: 0)
                }
            }
        }
        .card()
    }

    private var plans: some View {
        VStack(spacing: Theme.Space.s) {
            if store.products.isEmpty {
                ProgressView().padding()
            } else {
                ForEach(store.products, id: \.id) { product in
                    planRow(product)
                }
            }
        }
    }

    private func planRow(_ product: Product) -> some View {
        let plan = SnapCalProduct(rawValue: product.id) ?? .monthly
        let isSelected = selected == plan

        return Button {
            Haptics.tap()
            withAnimation(Theme.quick) { selected = plan }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.s) {
                        Text(plan.isYearly ? "Yearly" : "Monthly")
                            .font(.system(size: 16, weight: .semibold))
                        if plan.isYearly, let savings = store.savingsPercent(), savings > 0 {
                            Text("SAVE \(savings)%")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    // Price comes from StoreKit, never hardcoded — it is
                    // localized and reflects whatever App Store Connect says.
                    Text(store.priceString(for: product))
                        .font(.caption_).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.l) {
                Button("Restore Purchases") {
                    Analytics.track(.restorePurchase)
                    Task {
                        await store.restore()
                        await entitlements.refresh()
                        if store.isPro { dismiss() }
                    }
                }
                Link("Terms of Use", destination: URL(string: "https://snapcal.app/terms")!)
                Link("Privacy Policy", destination: URL(string: "https://snapcal.app/privacy")!)
            }
            .font(.caption_)
            .foregroundStyle(.secondary)

            Text("Subscription renews automatically until cancelled. Cancel any time in the App Store.")
                .font(.caption_).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}
