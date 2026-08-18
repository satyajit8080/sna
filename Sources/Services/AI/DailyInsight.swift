import Foundation

/// The one thing worth saying about today's data.
///
/// Deterministic, not generated. An insight on Home appears whether or not the
/// AI coach is configured, and it must be identical every time it is computed —
/// a card that says something different on each launch reads as noise rather
/// than information.
///
/// Rules are ordered by importance: the most consequential observation that
/// applies is the one shown.
enum DailyInsight {

    struct Insight: Equatable {
        let headline: String
        let body: String
        let symbol: String
        /// Set when tapping should open a specific screen.
        let action: Action?

        enum Action: Equatable {
            case history, medication, measure, sodium
        }
    }

    static func forToday(
        readings: [BPReading],
        doses: [MedicationDose],
        sodiumToday: Double,
        sodiumTarget: Int,
        guideline: BPGuideline,
        now: Date = .now
    ) -> Insight? {

        let recent = BPStatistics.within(readings, days: 30, now: now)
        let calendar = Calendar.current

        // 1. Nothing recorded today, and it is late enough to say so.
        let todayCount = readings.filter { calendar.isDateInToday($0.recordedAt) }.count
        if todayCount == 0, calendar.component(.hour, from: now) >= 11, !readings.isEmpty {
            return Insight(
                headline: "No reading yet today",
                body: "A reading at a consistent time is what makes the trend meaningful.",
                symbol: "clock.badge.exclamationmark",
                action: .measure
            )
        }

        // 2. A sustained upward shift matters more than any single number.
        if BPStatistics.hasDrifted(readings, now: now) {
            return Insight(
                headline: "Your average has drifted up",
                body: "The last month is higher than the month before. Worth mentioning at your next appointment.",
                symbol: "arrow.up.right",
                action: .history
            )
        }

        // 3. Missed doses, when there is enough history to be fair about it.
        let adherence = MedicationEngine.adherence(for: doses, now: now)
        if adherence.resolved >= 7, let percent = adherence.percentage, percent < 80 {
            return Insight(
                headline: "\(Int(percent))% of doses taken",
                body: "Missed doses show up in blood pressure. Reminders can help if the timing is awkward.",
                symbol: "pills",
                action: .medication
            )
        }

        // 4. Sodium well over target today.
        if sodiumToday > Double(sodiumTarget) * 1.5 {
            return Insight(
                headline: "Sodium is high today",
                body: "\(Int(sodiumToday)) mg against a \(sodiumTarget) mg target. Its effect usually shows up over days, not hours.",
                symbol: "drop.fill",
                action: .sodium
            )
        }

        // 5. Morning readings meaningfully higher than evening.
        if let comparison = BPStatistics.morningVsEvening(recent),
           comparison.first.count >= 5, comparison.second.count >= 5,
           comparison.first.systolic - comparison.second.systolic >= 8 {
            return Insight(
                headline: "Your mornings run higher",
                body: "About \(comparison.first.systolic - comparison.second.systolic) points above your evenings. Common, and worth your doctor knowing.",
                symbol: "sunrise",
                action: .history
            )
        }

        // 6. Wide variability makes any single reading less meaningful.
        if let variability = BPStatistics.variability(recent), variability.systolicSD > 12 {
            return Insight(
                headline: "Your readings vary a lot",
                body: String(format: "Systolic swings by about ±%.0f. Measuring after five minutes' rest usually steadies it.", variability.systolicSD),
                symbol: "waveform.path",
                action: .history
            )
        }

        // 7. Steady and in range — worth saying, since silence reads as neglect.
        if let average = BPStatistics.homeAverage(readings, days: 7, now: now), average.count >= 4 {
            let category = guideline.category(systolic: average.systolic, diastolic: average.diastolic)
            if category.severity == .normal {
                return Insight(
                    headline: "Steady week",
                    body: "Your 7-day average is \(average.systolic)/\(average.diastolic) — \(category.label) under \(guideline.displayName).",
                    symbol: "checkmark.circle",
                    action: .history
                )
            }
        }

        return nil
    }
}
