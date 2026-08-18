import Foundation
import UserNotifications

/// Local notifications only. No push, no server, no remote payloads.
///
/// Every category can be turned off independently, and every notification deep
/// links to the screen that resolves it.
@MainActor
final class NotificationEngine {

    enum Category: String, CaseIterable, Sendable {
        case medication, measurement, appointment, drift, reportPrep

        var label: String {
            switch self {
            case .medication: "Medication reminders"
            case .measurement: "Measurement reminders"
            case .appointment: "Appointment reminders"
            case .drift: "30-day trend alerts"
            case .reportPrep: "Doctor report preparation"
            }
        }

        var explanation: String {
            switch self {
            case .medication: "When a scheduled dose is due."
            case .measurement: "A nudge to take a reading at your usual time."
            case .appointment: "Ahead of an appointment, so you can prepare."
            case .drift: "If your average has shifted over the past month."
            case .reportPrep: "Before an appointment, to build your doctor report."
            }
        }

        /// Deep link target. Every notification resolves somewhere specific.
        var deepLink: URL? { URL(string: "bpcoach://\(rawValue)") }
    }

    static let shared = NotificationEngine()
    private let center = UNUserNotificationCenter.current()

    private init() {}

    func isEnabled(_ category: Category, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "notify.\(category.rawValue)") as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, for category: Category, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "notify.\(category.rawValue)")
        if !enabled { cancelAll(for: category) }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Daily nudge to take a reading. One per day at most — a blood pressure app
    /// that nags hourly gets its notifications switched off entirely.
    func scheduleMeasurementReminder(at date: Date) async {
        guard isEnabled(.measurement) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time for a reading"
        content.body = "Sit quietly for five minutes first, then measure."
        content.sound = .default
        content.userInfo = ["deepLink": Category.measurement.deepLink?.absoluteString ?? ""]

        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: "measurement.daily",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try? await center.add(request)
    }

    /// Replaces every reminder for a medication. Called after an edit, so a
    /// changed schedule never leaves the old reminders firing alongside the new.
    func rescheduleMedication(
        medicationID: UUID,
        name: String,
        dose: String,
        scheduleMinutes: [Int]
    ) async {
        cancelMedication(medicationID)
        guard isEnabled(.medication) else { return }

        let calendar = Calendar.current
        for minutes in scheduleMinutes {
            guard let date = calendar.date(
                byAdding: .minute, value: minutes, to: calendar.startOfDay(for: .now)
            ) else { continue }
            await scheduleMedicationReminder(
                medicationID: medicationID, name: name, dose: dose, at: date
            )
        }
    }

    func cancelMedication(_ medicationID: UUID) {
        Task { @MainActor in
            let requests = await center.pendingNotificationRequests()
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix("medication.\(medicationID.uuidString)") }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    func scheduleMedicationReminder(
        medicationID: UUID,
        name: String,
        dose: String,
        at date: Date
    ) async {
        guard isEnabled(.medication) else { return }

        let content = UNMutableNotificationContent()
        content.title = name
        content.body = "Time for \(dose)."
        content.sound = .default
        content.userInfo = ["deepLink": Category.medication.deepLink?.absoluteString ?? "",
                            "medicationID": medicationID.uuidString]

        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: "medication.\(medicationID.uuidString).\(components.hour ?? 0).\(components.minute ?? 0)",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    /// Fired only by `BPStatistics.hasDrifted`. The AI never triggers this.
    func scheduleDriftAlert() async {
        guard isEnabled(.drift) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your average has shifted"
        content.body = "Your blood pressure has trended up over the past month. Open History to see the change."
        content.sound = .default
        content.userInfo = ["deepLink": Category.drift.deepLink?.absoluteString ?? ""]

        let request = UNNotificationRequest(
            identifier: "drift.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        )
        try? await center.add(request)
    }

    func cancelAll(for category: Category) {
        // The async form keeps `center` on the main actor. The completion-handler
        // version captures it in a Sendable closure, which is a data race.
        Task { @MainActor in
            let requests = await center.pendingNotificationRequests()
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(category.rawValue) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
