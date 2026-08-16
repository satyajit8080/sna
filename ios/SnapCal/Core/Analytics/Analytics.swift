import Foundation

/// Thin wrapper over the existing backend analytics endpoint. No third-party
/// SDK is added: events already flow to our own database, which is where the
/// conversion funnel is queried from.
enum AnalyticsEvent: String {
    case onboardingCompleted = "onboarding_completed"
    case healthkitConnected = "healthkit_connected"
    case firstFoodScan = "first_food_scan"
    case foodScanCompleted = "food_scan_completed"
    case coachOpened = "coach_opened"
    case coachQuestionSent = "coach_question_sent"
    case mealPlannerOpened = "meal_planner_opened"
    case mealPlanGenerated = "meal_plan_generated"
    case freeLimitWarning = "free_limit_warning"
    case freeLimitReached = "free_limit_reached"
    case paywallViewed = "paywall_viewed"
    case premiumCTAClicked = "premium_cta_clicked"
    case purchaseStarted = "purchase_started"
    case purchaseCompleted = "purchase_completed"
    case purchaseFailed = "purchase_failed"
    case restorePurchase = "restore_purchase"
    case subscriptionActive = "subscription_active"
    case subscriptionCancelled = "subscription_cancelled"
    case notificationPermissionGranted = "notification_permission_granted"
    case notificationOpened = "notification_opened"
    case premiumNotificationOpened = "premium_notification_opened"
}

/// Buffers and flushes in batches — one network call per event would be wasteful
/// and would fight the API rate limit during a busy session.
actor Analytics {
    static let shared = Analytics()

    private var buffer: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?

    nonisolated static func track(_ event: AnalyticsEvent, _ props: [String: Any] = [:]) {
        Task { await shared.enqueue(event, props) }
    }

    private func enqueue(_ event: AnalyticsEvent, _ props: [String: Any]) {
        // Only primitives survive: the endpoint validates types and would 400.
        let clean = props.filter { $0.value is String || $0.value is Int
                                || $0.value is Double || $0.value is Bool }
        buffer.append(["name": event.rawValue, "props": clean])

        if buffer.count >= 20 {
            flushNow()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.flushNow()
            }
        }
    }

    func flushNow() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        flushTask?.cancel()
        flushTask = nil

        Task { [weak self, batch] in
            do {
                try await APIClient.shared.sendEvents(batch)
            } catch {
                // Analytics must never break a user flow, but dropping silently
                // would skew the funnel, so failed batches are re-queued once.
                await self?.requeue(batch)
            }
        }
    }

    private func requeue(_ batch: [[String: Any]]) {
        guard buffer.count < 100 else { return }
        buffer.insert(contentsOf: batch, at: 0)
    }
}
