import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var store

    @State private var selected: SnapCalProduct = .yearly

    private let benefits: [(String, String)] = [
        ("infinity", "Unlimited AI photo scans"),
        ("barcode.viewfinder", "Barcode scanning"),
        ("mic.fill", "Voice logging"),
        ("chart.xyaxis.line", "Advanced trends and analytics"),
        ("lightbulb.fill", "AI meal suggestions"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.accent)

                    Text("SnapCal Pro")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("Scan every meal, not just two a week.")
                        .font(.body_).foregroundStyle(.secondary)
                }
                .padding(.top, Theme.Space.l)

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(benefits, id: \.1) { icon, text in
                        HStack(spacing: Theme.Space.m) {
                            Image(systemName: icon)
                                .frame(width: 24)
                                .foregroundStyle(Theme.accent)
                            Text(text).font(.body_)
                            Spacer()
                        }
                    }
                }
                .card()

                VStack(spacing: Theme.Space.s) {
                    ForEach(store.products, id: \.id) { product in
                        planRow(product)
                    }
                    if store.products.isEmpty {
                        ProgressView().padding()
                    }
                }

                Button {
                    guard let product = store.products.first(where: { $0.id == selected.rawValue }) else { return }
                    Task {
                        if await store.purchase(product) { dismiss() }
                    }
                } label: {
                    if store.isPurchasing { ProgressView().tint(.white) } else { Text("Continue") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.products.isEmpty || store.isPurchasing)

                HStack(spacing: Theme.Space.l) {
                    Button("Restore") { Task { await store.restore() } }
                    Link("Terms", destination: URL(string: "https://snapcal.app/terms")!)
                    Link("Privacy", destination: URL(string: "https://snapcal.app/privacy")!)
                }
                .font(.caption_)
                .foregroundStyle(.secondary)

                Text("Renews automatically. Cancel any time in the App Store.")
                    .font(.caption_).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.bg)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    .padding(10).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(Theme.Space.m)
        }
        .alert("Purchase failed", isPresented: .constant(store.purchaseError != nil)) {
            Button("OK") {}
        } message: { Text(store.purchaseError ?? "") }
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
                    Text(store.priceString(for: product))
                        .font(.caption_).foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
            }
            .padding(Theme.Space.m)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .stroke(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
