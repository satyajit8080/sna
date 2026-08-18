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

    var body: some View {
        List {
            Section {
                switch store.status {
                case .noProductsConfigured:
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("Everything is free", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.statusNormal)
                        Text("""
                        BP Coach has no paid plan. Every feature — readings, trends, \
                        medication tracking, reports and export — is included and works \
                        without an account.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Theme.Spacing.xs)

                case .loading:
                    HStack { ProgressView(); Text("Checking…") }

                case .notSubscribed:
                    LabeledContent("Current plan", value: "Free")

                case .subscribed(let name, let renewsOn):
                    LabeledContent("Current plan", value: name)
                    if let renewsOn {
                        LabeledContent(
                            "Renews",
                            value: renewsOn.formatted(date: .abbreviated, time: .omitted)
                        )
                    }

                case .failed(let message):
                    Text(message).foregroundStyle(Theme.statusModerate)
                }
            } header: {
                Text("Subscription")
            }

            if !SubscriptionStore.productIDs.isEmpty {
                Section {
                    Button("Restore purchases") {
                        Task { await store.restore() }
                    }
                    Button("Manage subscription") {
                        // Apple requires subscription management to go through
                        // the system, not a bespoke in-app screen.
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            openURL(url)
                        }
                    }
                } footer: {
                    Text("Subscriptions are managed by Apple in your App Store account.")
                }
            }
        }
        .navigationTitle("Subscription")
        .task { await store.refresh() }
    }
}
