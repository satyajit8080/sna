import Foundation
import Testing

@testable import BPCoach

@Suite("Medication adherence")
struct MedicationTests {

    private func dose(_ status: DoseStatus, daysAgo: Double = 0) -> MedicationDose {
        let dose = MedicationDose(
            profileID: UUID(),
            medicationID: UUID(),
            scheduledFor: Date.now.addingTimeInterval(-daysAgo * 86_400)
        )
        dose.status = status
        return dose
    }

    @Test("No doses means no percentage, not zero percent")
    func emptyAdherence() {
        #expect(MedicationEngine.adherence(for: []).percentage == nil)
    }

    @Test("Adherence counts taken over resolved doses")
    func basicAdherence() {
        let doses = [
            dose(.taken, daysAgo: 1), dose(.taken, daysAgo: 2),
            dose(.taken, daysAgo: 3), dose(.missed, daysAgo: 4),
        ]
        #expect(MedicationEngine.adherence(for: doses).percentage == 75)
    }

    @Test("Pending doses are excluded from the denominator")
    func pendingExcluded() {
        let doses = [
            dose(.taken, daysAgo: 1),
            dose(.scheduled, daysAgo: -1),   // due in the future
        ]
        let adherence = MedicationEngine.adherence(for: doses)
        #expect(adherence.resolved == 1)
        #expect(adherence.percentage == 100)
    }

    @Test("A dose more than a day overdue counts as missed")
    func overdueCountsAsMissed() {
        let adherence = MedicationEngine.adherence(for: [dose(.scheduled, daysAgo: 3)])
        #expect(adherence.missed == 1)
        #expect(adherence.percentage == 0)
    }

    @Test("Skipped doses count against adherence but are distinct from missed")
    func skippedIsTracked() {
        let adherence = MedicationEngine.adherence(for: [
            dose(.taken, daysAgo: 1), dose(.skipped, daysAgo: 2),
        ])
        #expect(adherence.skipped == 1)
        #expect(adherence.missed == 0)
        #expect(adherence.percentage == 50)
    }

    @Test("Twice-daily generates two dose slots")
    func scheduleGeneration() {
        let medication = Medication(
            profileID: UUID(),
            name: "Test",
            dose: "5 mg",
            frequency: .twiceDaily,
            scheduleMinutes: [8 * 60, 20 * 60],
            startDate: Date.now.addingTimeInterval(-86_400)
        )
        #expect(MedicationEngine.doses(for: medication, on: .now).count == 2)
    }

    @Test("As-needed medications generate no scheduled doses")
    func asNeededHasNoSchedule() {
        let medication = Medication(
            profileID: UUID(),
            name: "Test",
            dose: "5 mg",
            frequency: .asNeeded,
            startDate: Date.now.addingTimeInterval(-86_400)
        )
        #expect(MedicationEngine.doses(for: medication, on: .now).isEmpty)
    }

    @Test("No doses are generated before the start date")
    func respectsStartDate() {
        let medication = Medication(
            profileID: UUID(),
            name: "Test",
            dose: "5 mg",
            startDate: Date.now.addingTimeInterval(86_400 * 7)
        )
        #expect(MedicationEngine.doses(for: medication, on: .now).isEmpty)
    }
}
