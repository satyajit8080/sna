import Foundation

/// What the app intends to deliver, before iOS is involved.
///
/// A plain value so a plan can be asserted against in a test. Everything about
/// *whether* and *when* to notify is decided here; `NotificationEngine` only
/// hands the result to `UNUserNotificationCenter`.
struct PlannedNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    /// Absolute moment it should fire. Resolved against the caller's calendar,
    /// so a test can pin it without touching the device clock.
    let fireDate: Date
    /// Opens the coach with this already asked.
    let coachQuestion: String

    var deepLink: String {
        let encoded = coachQuestion
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "bpcoach://coach?question=\(encoded)"
    }
}

/// Decides which check-in notifications should exist.
///
/// The whole decision behind one function. Callers pass state in explicitly
/// rather than the scheduler reaching for `Date.now`, `UserDefaults`, or a view's
/// lifecycle — which is what makes it verifiable without a device, and what
/// makes it impossible for the decision to depend on which screen is open.
///
/// The bug this shape prevents: scheduling used to live in `HomeView.task`, so
/// launching the app onto any other tab queued nothing at all. That was
/// invisible for weeks because a `.task` on a view is not reachable from a test.
enum CheckInScheduler {

    /// Everything the decision depends on, named once.
    struct Inputs: Sendable {
        var context: CheckInPrompts.Context
        /// Hour of day, 0-23.
        var hour: Int
        var quietHours: NotificationEngine.QuietHours
        var isEnabled: Bool
        var isAuthorized: Bool
        var now: Date
        var calendar: Calendar
        /// How many days ahead to queue.
        var horizonDays: Int

        init(
            context: CheckInPrompts.Context,
            hour: Int = 19,
            quietHours: NotificationEngine.QuietHours = .init(
                isEnabled: false, startHour: 22, endHour: 7
            ),
            isEnabled: Bool = true,
            isAuthorized: Bool = true,
            now: Date = .now,
            calendar: Calendar = .current,
            horizonDays: Int = 7
        ) {
            self.context = context
            self.hour = hour
            self.quietHours = quietHours
            self.isEnabled = isEnabled
            self.isAuthorized = isAuthorized
            self.now = now
            self.calendar = calendar
            self.horizonDays = horizonDays
        }
    }

    /// The notifications that should be queued, in fire order.
    ///
    /// An empty result is a legitimate outcome, not a failure: the category may
    /// be off, permission may be absent, or the rules may simply have nothing
    /// worth saying today.
    static func plan(_ inputs: Inputs) -> [PlannedNotification] {
        guard inputs.isEnabled, inputs.isAuthorized else { return [] }

        var planned: [PlannedNotification] = []

        for (day, prompt) in CheckInPrompts.week(
            from: inputs.context, days: inputs.horizonDays
        ) {
            guard let fireDate = fireDate(dayOffset: day, inputs: inputs) else { continue }

            planned.append(PlannedNotification(
                identifier: "checkin.day\(day)",
                title: prompt.title,
                body: prompt.body,
                fireDate: fireDate,
                coachQuestion: prompt.coachQuestion
            ))
        }

        return planned.sorted { $0.fireDate < $1.fireDate }
    }

    /// When a given day's check-in should fire, or nil if it should not.
    ///
    /// Returns nil for a slot that has already passed. Firing immediately on a
    /// slot the user has missed reads as a bug — they open the app at 8pm and a
    /// 7pm reminder lands in their hand.
    private static func fireDate(dayOffset: Int, inputs: Inputs) -> Date? {
        let calendar = inputs.calendar

        guard let base = calendar.date(byAdding: .day, value: dayOffset, to: inputs.now)
        else { return nil }

        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = inputs.quietHours.adjustedHour(inputs.hour)
        components.minute = 0

        guard let date = calendar.date(from: components) else { return nil }

        // A minute of slack: a slot resolving to "now" is one the user has
        // effectively just missed.
        return date > inputs.now.addingTimeInterval(60) ? date : nil
    }
}
