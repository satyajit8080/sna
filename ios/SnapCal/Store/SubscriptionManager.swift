import StoreKit
import Observation

/// Holds the update-listener task outside actor isolation so `deinit`, which is
/// nonisolated, can cancel it. Written once in `init`, read once in `deinit`.
private final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}

/// StoreKit 2. Product IDs and prices live in one place so pricing experiments
/// are a config change, not a refactor.
enum SnapCalProduct: String, CaseIterable {
    case monthly = "app.snapcal.pro.monthly"
    case yearly  = "app.snapcal.pro.yearly"

    var isYearly: Bool { self == .yearly }
}

@Observable
@MainActor
final class SubscriptionManager {
    private(set) var products: [Product] = []
    private(set) var isPro = false
    private(set) var isPurchasing = false
    var purchaseError: String?

    /// `deinit` is nonisolated, so this cannot be a main-actor-isolated stored
    /// property if we want to cancel from there. The task is written once in
    /// `init` and only ever read in `deinit`, so unchecked access is safe.
    private nonisolated let updatesBox = TaskBox()

    init() {
        updatesBox.task = Task { [weak self] in
            // Renewals, refunds and Ask-to-Buy approvals arrive here, not from the UI.
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
    }

    deinit { updatesBox.task?.cancel() }

    func load() async {
        products = (try? await Product.products(for: SnapCalProduct.allCases.map(\.rawValue)))?
            .sorted { $0.price < $1.price } ?? []
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let tx) = entitlement,
                  SnapCalProduct(rawValue: tx.productID) != nil,
                  tx.revocationDate == nil else { continue }

            isPro = true
            await sync(entitlement)
            return
        }
        isPro = false
    }

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        // Cleared up front: a cancellation must not surface last attempt's error.
        purchaseError = nil
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified = verification else {
                    purchaseError = "We couldn't verify that purchase."
                    return false
                }
                await handle(verification)
                isPro = true
                Haptics.success()
                return true

            case .userCancelled, .pending:
                return false

            @unknown default:
                return false
            }
        } catch {
            purchaseError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - Internals

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let tx) = result else { return }
        await sync(result)
        await tx.finish()
    }

    /// The server is the source of truth for entitlement; the client only reports.
    /// `jwsRepresentation` lives on the VerificationResult, not on Transaction —
    /// it is the signed envelope, and the transaction is its decoded payload.
    private func sync(_ result: VerificationResult<Transaction>) async {
        let jws = result.jwsRepresentation
        guard !jws.isEmpty else { return }
        try? await APIClient.shared.verifySubscription(signedTransaction: jws)
    }

    // MARK: - Display

    func priceString(for product: Product) -> String {
        guard let sub = product.subscription else { return product.displayPrice }
        let unit = sub.subscriptionPeriod.unit == .year ? "year" : "month"
        return "\(product.displayPrice) / \(unit)"
    }

    /// Yearly price expressed per month, in the store's own currency and
    /// formatting. Built from `priceFormatStyle` so it is correct in every
    /// locale — dividing and prepending "$" is wrong nearly everywhere.
    func monthlyEquivalent(for product: Product) -> String? {
        guard product.id == SnapCalProduct.yearly.rawValue else { return nil }
        let perMonth = product.price / Decimal(12)
        return perMonth.formatted(product.priceFormatStyle)
    }

    /// "Save 52%" badge, computed from live App Store prices rather than hardcoded.
    /// Product.price is a Decimal, which has no `rounded()` and does not mix with
    /// integer literals in arithmetic — hence the explicit conversions.
    func savingsPercent() -> Int? {
        guard
            let monthly = products.first(where: { $0.id == SnapCalProduct.monthly.rawValue }),
            let yearly = products.first(where: { $0.id == SnapCalProduct.yearly.rawValue })
        else { return nil }

        let annualised: Decimal = monthly.price * Decimal(12)
        guard annualised > 0 else { return nil }

        let saved: Decimal = (annualised - yearly.price) / annualised
        let percent = NSDecimalNumber(decimal: saved * Decimal(100)).doubleValue
        guard percent.isFinite, percent > 0 else { return nil }

        return Int(percent.rounded())
    }
}
