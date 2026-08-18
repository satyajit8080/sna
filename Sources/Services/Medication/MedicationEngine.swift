import Foundation

/// Adherence maths and dose scheduling. Pure functions where possible.
///
/// The app never recommends starting, stopping or changing a medication. It
/// records what happened and reports it.
enum MedicationEngine {

    struct Adherence: Equatable, Sendable {
        let taken: Int
        let skipped: Int
        let missed: Int
        let scheduled: Int

        var total: Int { taken + skipped + missed + scheduled }
        /// Pending doses are excluded — counting a dose not yet due as missed
        /// would make adherence look worse than it is.
        var resolved: Int { taken + skipped + missed }

        var percentage: Double? {
            guard resolved > 0 else { return nil }
            return (Double(taken) / Double(resolved)) * 100
        }
    }

    static func adherence(for doses: [MedicationDose], now: Date = .now) -> Adherence {
        var taken = 0, skipped = 0, missed = 0, scheduled = 0
        for dose in doses {
            switch dose.status {
            case .taken: taken += 1
            case .skipped: skipped += 1
            case .missed: missed += 1
            case .scheduled:
                // A scheduled dose more than a day past due counts as missed.
                if dose.scheduledFor < now.addingTimeInterval(-86_400) { missed += 1 }
                else { scheduled += 1 }
            }
        }
        return Adherence(taken: taken, skipped: skipped, missed: missed, scheduled: scheduled)
    }

    /// Generate the dose slots for a medication on a given day.
    static func doses(
        for medication: Medication,
        on day: Date,
        calendar: Calendar = .current
    ) -> [MedicationDose] {
        guard !medication.isArchived, medication.frequency != .asNeeded else { return [] }
        guard day >= calendar.startOfDay(for: medication.startDate) else { return [] }
        if let end = medication.endDate, day > end { return [] }

        if medication.frequency == .everyOtherDay {
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: medication.startDate),
                to: calendar.startOfDay(for: day)
            ).day ?? 0
            guard days % 2 == 0 else { return [] }
        }

        let startOfDay = calendar.startOfDay(for: day)
        return medication.scheduleMinutes.compactMap { minutes in
            guard let time = calendar.date(byAdding: .minute, value: minutes, to: startOfDay) else {
                return nil
            }
            return MedicationDose(
                profileID: medication.profileID,
                medicationID: medication.id,
                scheduledFor: time
            )
        }
    }

    /// The next dose still awaiting an answer.
    static func nextDue(from doses: [MedicationDose], now: Date = .now) -> MedicationDose? {
        doses
            .filter { $0.status == .scheduled && $0.scheduledFor >= now }
            .min { $0.scheduledFor < $1.scheduledFor }
    }
}
