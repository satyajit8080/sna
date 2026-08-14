import Foundation
import UserNotifications
import Observation

/// Local notifications only. The daily coach message is fetched from the
/// backend and scheduled on-device — no push infrastructure is needed for a
/// message that fires at a time the user chose.
@Observable
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private(set) var permission: UNAuthorizationStatus = .notDetermined
    private(set) var prefs: NotificationPrefs = .default

    /// Set when a notification is tapped; RootView consumes it after auth.
    var pendingDeeplink: String?

    private let center = UNUserNotificationCenter.current()

    private enum ID {
        static let morning = "snapcal.morning"
        static let lunch = "snapcal.meal.lunch"
        static let dinner = "snapcal.meal.dinner"
        static let logging = "snapcal.logging"
        static let coach = "snapcal.coach"
    }

    override init() {
        super.init()
        center.delegate = self
    }

    func refreshStatus() async {
        permission = await center.notificationSettings().authorizationStatus
    }

    func loadPrefs() async {
        if let remote = try? await APIClient.shared.notificationPrefs() { prefs = remote }
        await refreshStatus()
    }

    /// Asks iOS only after our own explanation screen. One shot: if denied, we
    /// never ask again — iOS would not show the sheet a second time anyway.
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()

        var updated = prefs
        updated.permission = granted ? "granted" : "denied"
        prefs = updated
        _ = try? await APIClient.shared.updateNotificationPrefs(updated)

        if granted {
            Analytics.track(.notificationPermissionGranted)
            await rescheduleAll()
        }
        return granted
    }

    func update(_ new: NotificationPrefs) async {
        prefs = new
        if let saved = try? await APIClient.shared.updateNotificationPrefs(new) { prefs = saved }
        await rescheduleAll()
    }

    /// Rebuilds every schedule from scratch. Cheap, and it means a timezone
    /// change or a settings edit can never leave a stale notification behind.
    func rescheduleAll() async {
        center.removePendingNotificationRequests(withIdentifiers: [
            ID.morning, ID.lunch, ID.dinner, ID.logging, ID.coach,
        ])
        guard permission == .authorized else { return }

        if prefs.dailyCoach {
            let message = (try? await APIClient.shared.morningMessage())
                ?? MorningMessage(title: "Good morning",
                                  body: "Ready to make progress today?",
                                  deeplink: "snapcal://today")
            schedule(id: ID.morning, title: message.title, body: message.body,
                     hour: prefs.morningHour, minute: prefs.morningMinute, deeplink: message.deeplink)
        }

        if prefs.mealReminders {
            schedule(id: ID.lunch, title: "Lunch logged?",
                     body: "A quick scan keeps today accurate.",
                     hour: 13, minute: 30, deeplink: "snapcal://scan")
            schedule(id: ID.dinner, title: "Dinner time",
                     body: "Scan your plate before you eat — it takes seconds.",
                     hour: 20, minute: 0, deeplink: "snapcal://scan")
        }

        if prefs.foodLogging {
            schedule(id: ID.logging, title: "Anything left to log?",
                     body: "Close out your day so tomorrow's plan is right.",
                     hour: 21, minute: 30, deeplink: "snapcal://scan")
        }

        if prefs.coachReminder {
            schedule(id: ID.coach, title: "Your coach is here",
                     body: "Ask anything about today's food or progress.",
                     hour: 18, minute: 0, deeplink: "snapcal://coach")
        }
    }

    private func schedule(id: String, title: String, body: String,
                          hour: Int, minute: Int, deeplink: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["deeplink": deeplink]

        // Calendar triggers use the device's current timezone, so a user who
        // flies somewhere still gets their 8am at 8am local.
        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        center.add(UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        ))
    }

    /// Conversion nudges are local, capped, and never sent to subscribers.
    func scheduleConversionNudge(context: PaywallContext, isPro: Bool) {
        guard !isPro, prefs.premiumOffers, permission == .authorized else { return }

        let key = "conversion.last"
        let last = UserDefaults.standard.double(forKey: key)
        // At most one promotional nudge every three days.
        guard Date().timeIntervalSince1970 - last > 3 * 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)

        let content = UNMutableNotificationContent()
        switch context {
        case .coach:
            content.title = "You've been using your AI Coach"
            content.body = "Unlock unlimited coaching with Premium."
        case .mealPlan:
            content.title = "Want personalized meal plans?"
            content.body = "Premium builds them around your targets."
        default:
            content.title = "Make meal tracking easier"
            content.body = "Unlock unlimited AI Food Scans."
        }
        content.userInfo = ["deeplink": "snapcal://premium", "promotional": true]
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: "snapcal.conversion.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2 * 3600, repeats: false)
        ))
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let link = info["deeplink"] as? String
        let promotional = info["promotional"] as? Bool ?? false

        Analytics.track(promotional ? .premiumNotificationOpened : .notificationOpened,
                        ["deeplink": link ?? "none"])
        await MainActor.run { self.pendingDeeplink = link }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
