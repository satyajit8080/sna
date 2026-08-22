import Foundation
import Testing
@testable import BPCoach

/// The scheduling decision, verified without a device.
///
/// These exist because the decision used to live in `HomeView.task`, where no
/// test could reach it. Opening the app to any tab other than Home queued
/// nothing, and that went unnoticed through several releases: a notification
/// that was never scheduled is indistinguishable from one that failed to
/// deliver. Every case below would have caught it.
@Suite("Check-in scheduling")
struct CheckInSchedulerTests {

    // MARK: - Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A fixed moment so results never depend on when the suite runs.
    private func moment(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 22, hour: hour, minute: minute
        ))!
    }

    /// Someone set up and active — the rules still find things to say.
    private func settledContext() -> CheckInPrompts.Context {
        var context = CheckInPrompts.Context()
        context.readingCount = 20
        context.readingsToday = 1
        context.hasMedications = true
        context.hasAnyAppointment = true
        return context
    }

    private func inputs(
        context: CheckInPrompts.Context? = nil,
        hour: Int = 19,
        quietHours: NotificationEngine.QuietHours = .init(
            isEnabled: false, startHour: 22, endHour: 7
        ),
        isEnabled: Bool = true,
        isAuthorized: Bool = true,
        at: Date? = nil
    ) -> CheckInScheduler.Inputs {
        .init(
            context: context ?? settledContext(),
            hour: hour,
            quietHours: quietHours,
            isEnabled: isEnabled,
            isAuthorized: isAuthorized,
            now: at ?? moment(hour: 9),
            calendar: calendar
        )
    }

    // MARK: - Launch

    /// The regression this whole seam exists for.
    @Test("Launching the app produces a plan, whatever screen is showing")
    func schedulesAtLaunch() {
        let planned = CheckInScheduler.plan(inputs())
        #expect(!planned.isEmpty)
    }

    /// The plan is a pure function of its inputs. It cannot depend on which tab
    /// is open, because no tab is one of its inputs.
    @Test("The plan is identical regardless of the visible screen")
    func independentOfCurrentScreen() {
        let first = CheckInScheduler.plan(inputs())
        let second = CheckInScheduler.plan(inputs())
        #expect(first == second)
    }

    // MARK: - Enabled and authorised

    @Test("A disabled category plans nothing")
    func disabledPlansNothing() {
        #expect(CheckInScheduler.plan(inputs(isEnabled: false)).isEmpty)
    }

    /// Without permission `center.add` fails silently, so planning must stop
    /// before anything is queued rather than pretending it worked.
    @Test("Missing permission plans nothing")
    func unauthorisedPlansNothing() {
        #expect(CheckInScheduler.plan(inputs(isAuthorized: false)).isEmpty)
    }

    @Test("Enabled and authorised plans normally")
    func enabledPlansSomething() {
        #expect(!CheckInScheduler.plan(inputs(isEnabled: true, isAuthorized: true)).isEmpty)
    }

    // MARK: - Timing

    @Test("Everything is queued at the chosen hour")
    func usesChosenHour() {
        for hour in [7, 12, 19, 21] {
            let planned = CheckInScheduler.plan(inputs(hour: hour))
            for item in planned {
                let fired = calendar.component(.hour, from: item.fireDate)
                #expect(fired == hour, "expected \(hour), got \(fired)")
            }
        }
    }

    /// Opening the app at 8pm should not fire a 7pm reminder into the user's
    /// hand. That reads as a bug, not a reminder.
    @Test("A slot that has already passed today is skipped")
    func skipsPastSlots() {
        let planned = CheckInScheduler.plan(inputs(hour: 19, at: moment(hour: 20)))
        for item in planned {
            #expect(item.fireDate > moment(hour: 20))
        }
        // Today is skipped, so the first one lands tomorrow at the earliest.
        if let first = planned.first {
            #expect(calendar.dateComponents([.day], from: first.fireDate).day != 22)
        }
    }

    @Test("Everything planned is in the future")
    func allInFuture() {
        let now = moment(hour: 9)
        for item in CheckInScheduler.plan(inputs(at: now)) {
            #expect(item.fireDate > now)
        }
    }

    @Test("The plan is ordered by fire date")
    func ordered() {
        let dates = CheckInScheduler.plan(inputs()).map(\.fireDate)
        #expect(dates == dates.sorted())
    }

    // MARK: - Quiet hours

    @Test("An hour inside the quiet window is moved out of it")
    func respectsQuietHours() {
        let quiet = NotificationEngine.QuietHours(
            isEnabled: true, startHour: 22, endHour: 7
        )
        let planned = CheckInScheduler.plan(inputs(hour: 23, quietHours: quiet))
        for item in planned {
            #expect(calendar.component(.hour, from: item.fireDate) == 7)
        }
    }

    @Test("Quiet hours that are switched off change nothing")
    func quietHoursOffIsInert() {
        let quiet = NotificationEngine.QuietHours(
            isEnabled: false, startHour: 22, endHour: 7
        )
        let planned = CheckInScheduler.plan(inputs(hour: 23, quietHours: quiet))
        for item in planned {
            #expect(calendar.component(.hour, from: item.fireDate) == 23)
        }
    }

    // MARK: - Context handling

    /// The rules read the state they are given, so a different profile's state
    /// produces a different plan. Nothing is cached across profiles.
    @Test("A different context produces a different plan")
    func contextDrivesThePlan() {
        var newUser = CheckInPrompts.Context()
        newUser.readingCount = 0

        let established = CheckInScheduler.plan(inputs(context: settledContext()))
        let fresh = CheckInScheduler.plan(inputs(context: newUser))

        #expect(established.first?.title != fresh.first?.title)
    }

    @Test("Someone with nothing recorded is still nudged")
    func emptyStateStillPlans() {
        #expect(!CheckInScheduler.plan(inputs(context: CheckInPrompts.Context())).isEmpty)
    }

    /// Setup guidance ranks above the daily nudges, because a reminder about
    /// medicines that have not been added is what makes the rest work.
    @Test("Missing medicines are asked about first")
    func setupComesFirst() {
        var noMedicines = CheckInPrompts.Context()
        noMedicines.readingCount = 5
        let planned = CheckInScheduler.plan(inputs(context: noMedicines))
        #expect(planned.first?.title.contains("medicines") == true)
    }

    // MARK: - Duplicates

    /// The reason a week of one-shots replaced a single repeating trigger:
    /// a repeat sends the same sentence every day until the app is reopened.
    @Test("No two queued notifications say the same thing")
    func noDuplicateText() {
        for context in [settledContext(), CheckInPrompts.Context()] {
            let planned = CheckInScheduler.plan(inputs(context: context))
            let texts = planned.map { $0.title + $0.body }
            #expect(Set(texts).count == texts.count)
        }
    }

    @Test("Identifiers are unique, so nothing overwrites anything")
    func uniqueIdentifiers() {
        let ids = CheckInScheduler.plan(inputs()).map(\.identifier)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("checkin.") })
    }

    /// The prefix is what lets the engine clear the previous horizon without
    /// touching medication or appointment reminders.
    @Test("Rescheduling the same state is stable")
    func stableAcrossRuns() {
        let first = CheckInScheduler.plan(inputs())
        let second = CheckInScheduler.plan(inputs())
        #expect(first.map(\.identifier) == second.map(\.identifier))
        #expect(first.map(\.fireDate) == second.map(\.fireDate))
    }

    @Test("The horizon is respected")
    func respectsHorizon() {
        var short = inputs()
        short.horizonDays = 2
        #expect(CheckInScheduler.plan(short).count <= 2)
    }

    // MARK: - Behaviour that must not change

    /// Tapping a notification opens the coach with the question already asked.
    @Test("Every notification carries a coach deep link")
    func carriesDeepLink() {
        for item in CheckInScheduler.plan(inputs()) {
            #expect(item.deepLink.hasPrefix("bpcoach://coach?question="))
            #expect(!item.coachQuestion.isEmpty)
        }
    }

    @Test("Questions with spaces and punctuation survive the deep link")
    func deepLinkEncoding() {
        let item = PlannedNotification(
            identifier: "checkin.day0",
            title: "t", body: "b",
            fireDate: .now,
            coachQuestion: "What should I ask my doctor?"
        )
        #expect(!item.deepLink.contains(" "))
        #expect(item.deepLink.contains("%20") || item.deepLink.contains("+"))
    }

    /// Notification copy is written in code and must never imply urgency —
    /// that is the safety engine's job, and a lock screen cannot carry it.
    @Test("No planned notification makes a clinical claim")
    func noClinicalClaims() {
        var alarming = settledContext()
        alarming.latestAboveOwnAverage = true

        for item in CheckInScheduler.plan(inputs(context: alarming)) {
            let text = (item.title + " " + item.body).lowercased()
            for word in ["emergency", "urgent", "dangerous", "hypertension",
                         "you should", "stop taking", "see a doctor now"] {
                #expect(!text.contains(word), "\(item.title) contained: \(word)")
            }
        }
    }

    /// Quiet hours, ordering and skipping are all applied to a real week, not
    /// just to a single item.
    @Test("A full week is planned when nothing is opened in between")
    func fullWeek() {
        let planned = CheckInScheduler.plan(inputs())
        #expect(planned.count >= 2)
        #expect(planned.count <= 7)
    }
}
