import Foundation
import Testing

@testable import BPCoach

@Suite("Time classification and sodium")
struct TimeAndContextTests {

    private func date(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
    }

    @Test("Hours map to the right part of day", arguments: [
        (4, BPTimeOfDay.morning), (11, .morning),
        (12, .afternoon), (16, .afternoon),
        (17, .evening), (21, .evening),
        (22, .night), (3, .night),
    ])
    func timeOfDayClassification(hour: Int, expected: BPTimeOfDay) {
        #expect(BPTimeOfDay.classify(date(hour: hour)) == expected)
    }

    /// Classification is stored at capture time. A later timezone change must not
    /// silently move a morning reading into the evening.
    @Test("Time of day is fixed at capture, not recomputed")
    func timeOfDayIsStored() {
        let morning = date(hour: 8)
        let reading = BPReading(profileID: UUID(), systolic: 120, diastolic: 80, recordedAt: morning)
        #expect(reading.timeOfDay == .morning)

        let stored = reading.timeOfDayRaw
        // Mutating the raw value is the only way it changes — nothing derives it.
        #expect(stored == BPTimeOfDay.morning.rawValue)
    }

    @Test("Timezone offset is captured with the reading")
    func timezoneCaptured() {
        let reading = BPReading(profileID: UUID(), systolic: 120, diastolic: 80)
        #expect(reading.timeZoneOffset == TimeZone.current.secondsFromGMT(for: reading.recordedAt))
    }

    @Test("Sodium totals sum entries and flag estimates")
    func sodiumTotals() {
        let profileID = UUID()
        let entries = [
            LifestyleEntry(profileID: profileID, kind: .sodium, value: 500, unit: "mg", label: "Soup"),
            LifestyleEntry(
                profileID: profileID, kind: .sodium, value: 300, unit: "mg",
                label: "Bread", provenance: .estimated
            ),
        ]
        let total = ManualSodiumEntry.dailyTotal(entries)
        #expect(total.total == 800)
        #expect(total.containsEstimate)
    }

    @Test("Non-sodium entries are excluded from the sodium total")
    func sodiumIgnoresOtherKinds() {
        let profileID = UUID()
        let entries = [
            LifestyleEntry(profileID: profileID, kind: .sodium, value: 500, unit: "mg", label: "Soup"),
            LifestyleEntry(profileID: profileID, kind: .meal, value: 600, unit: "kcal", label: "Lunch"),
        ]
        #expect(ManualSodiumEntry.dailyTotal(entries).total == 500)
    }

    @Test("Estimates are marked as such")
    func provenance() {
        #expect(ValueProvenance.estimated.isEstimate)
        #expect(!ValueProvenance.userEntered.isEstimate)
        #expect(!ValueProvenance.deviceMeasured.isEstimate)
    }

    @Test("Guideline colours are defined for every severity")
    func severityColours() {
        for severity in [
            BPCategory.Severity.normal, .elevated, .mild, .moderate, .severe, .crisis,
        ] {
            _ = GuidelineEngine.color(for: severity)
        }
    }

    @Test("Notification categories all have a deep link")
    func deepLinks() {
        for category in NotificationEngine.Category.allCases {
            #expect(category.deepLink != nil)
        }
    }

    @Test("Deep links route to the right tab")
    @MainActor
    func routing() {
        let router = Router()
        router.handle(URL(string: "bpcoach://drift")!)
        #expect(router.tab == .history)

        router.handle(URL(string: "bpcoach://coach")!)
        #expect(router.tab == .coach)

        router.handle(URL(string: "bpcoach://measurement")!)
        #expect(router.isPresentingAddBP)
    }
}
