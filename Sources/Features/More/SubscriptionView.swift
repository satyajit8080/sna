import StoreKit
import SwiftUI

/// Subscription status via StoreKit 2.
///
/// BP Coach ships no paid products today: every feature is free and works
/// offline. This screen reports what StoreKit actually says rather than
/// pretending there is a plan to manage — a "Restore purchases" button that
/// silently does nothing is worse than one that tells you there is nothing to
/// restore.
///
/// If products are added later, `productIDs` is the only thing that changes.
@Observable
@MainActor
final class SubscriptionStore {

    /// Empty by design. No products are configured for this build.
    static let productIDs: Set<String> = []

    enum Status: Equatable {
        case noProductsConfigured
        case loading
        case notSubscribed
        case subscribed(productName: String, renewsOn: Date?)
        case failed(String)
    }

    private(set) var status: Status = .noProductsConfigured

    func refresh() async {
        guard !Self.productIDs.isEmpty else {
            status = .noProductsConfigured
            return
        }
        status = .loading

        var active: (String, Date?)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard Self.productIDs.contains(transaction.productID) else { continue }
            active = (transaction.productID, transaction.expirationDate)
        }

        status = active.map { .subscribed(productName: $0.0, renewsOn: $0.1) } ?? .notSubscribed
    }

    /// Asks StoreKit to re-sync with the App Store. Only meaningful once
    /// products exist.
    func restore() async {
        guard !Self.productIDs.isEmpty else { return }
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

struct SubscriptionView: View {
    @State private var store = SubscriptionStore()
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Subscription",
                subtitle: "Your plan and purchases",
                showsBack: true,
                onBack: { dismiss() }
            )

            switch store.status {
            case .noProductsConfigured:
                BrandCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            BrandIconTile(symbol: "checkmark.seal.fill", tint: Brand.accent, size: 49)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Everything is free")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(Brand.textPrimary)
                                Text("No plan, no account")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.accent)
                            }
                            Spacer(minLength: 0)
                        }
                        Text("""
                        Every feature — readings, trends, medication tracking, reports and \
                        export — is included and works without an account.
                        """)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

            case .loading:
                BrandCard {
                    HStack(spacing: 10) {
                        ProgressView().tint(Brand.accent)
                        Text("Checking…")
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }

            case .notSubscribed:
                BrandFormSection("Current plan") {
                    BrandValueRow(title: "Plan", value: "Free", symbol: "person.fill")
                }

            case .subscribed(let name, let renewsOn):
                BrandFormSection("Current plan") {
                    BrandValueRow(
                        title: "Plan", value: name,
                        symbol: "star.fill", valueTint: Brand.accent
                    )
                    if let renewsOn {
                        BrandRowDivider()
                        BrandValueRow(
                            title: "Renews",
                            value: renewsOn.formatted(date: .abbreviated, time: .omitted),
                            symbol: "calendar"
                        )
                    }
                }

            case .failed(let message):
                BrandCard(padding: 16) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.restingHeartRate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !SubscriptionStore.productIDs.isEmpty {
                BrandFormSection(
                    "Manage",
                    footer: "Subscriptions are managed by Apple in your App Store account."
                ) {
                    BrandActionRow(
                        title: "Restore purchases",
                        symbol: "arrow.clockwise"
                    ) { Task { await store.restore() } }
                    BrandRowDivider()
                    BrandActionRow(
                        title: "Manage subscription",
                        detail: "Opens the App Store",
                        symbol: "creditcard.fill",
                        tint: Brand.weight
                    ) {
                        // Apple requires subscription management to go through
                        // the system, not a bespoke in-app screen.
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            openURL(url)
                        }
                    }
                }
            }
        }
        .task { await store.refresh() }
    }
}
