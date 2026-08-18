import Foundation

/// Grouping readings into days, weeks and months for the History views.
enum BPGrouping {

    enum Granularity: String, CaseIterable, Sendable {
        case daily, weekly, monthly

        var label: String {
            switch self {
            case .daily: "Day"
            case .weekly: "Week"
            case .monthly: "Month"
            }
        }

        var component: Calendar.Component {
            switch self {
            case .daily: .day
            case .weekly: .weekOfYear
            case .monthly: .month
            }
        }
    }

    /// Not `Sendable`: it holds `BPReading`, a SwiftData `@Model` bound to the
    /// main-actor context it was fetched on. Declaring it `Sendable` would
    /// promise it can cross actors, which is exactly what SwiftData models must
    /// not do — Swift 6 rejects it, and it would be a data race regardless.
    ///
    /// Everything that uses a bucket runs on the main actor with the views, so
    /// nothing is lost by dropping the conformance.
    struct Bucket: Identifiable {
        let id: Date
        let start: Date
        let readings: [BPReading]
        let average: BPStatistics.Average
        let highest: BPReading
        let lowest: BPReading
    }

    /// Bucket readings by calendar period. Empty periods are omitted rather than
    /// filled with zeros — a day with no reading is not a day at 0/0.
    static func bucket(
        _ readings: [BPReading],
        by granularity: Granularity,
        calendar: Calendar = .current
    ) -> [Bucket] {

        guard !readings.isEmpty else { return [] }

        let grouped = Dictionary(grouping: readings) { reading -> Date in
            switch granularity {
            case .daily:
                calendar.startOfDay(for: reading.recordedAt)
            case .weekly:
                calendar.dateInterval(of: .weekOfYear, for: reading.recordedAt)?.start
                    ?? calendar.startOfDay(for: reading.recordedAt)
            case .monthly:
                calendar.dateInterval(of: .month, for: reading.recordedAt)?.start
                    ?? calendar.startOfDay(for: reading.recordedAt)
            }
        }

        return grouped.compactMap { start, items -> Bucket? in
            guard
                let average = BPStatistics.average(items),
                let highest = items.max(by: { $0.systolic < $1.systolic }),
                let lowest = items.min(by: { $0.systolic < $1.systolic })
            else { return nil }

            return Bucket(
                id: start,
                start: start,
                readings: items.sorted { $0.recordedAt > $1.recordedAt },
                average: average,
                highest: highest,
                lowest: lowest
            )
        }
        .sorted { $0.start > $1.start }
    }

    /// Highest and lowest by systolic across a set.
    static func extremes(_ readings: [BPReading]) -> (highest: BPReading, lowest: BPReading)? {
        guard
            let highest = readings.max(by: { $0.systolic < $1.systolic }),
            let lowest = readings.min(by: { $0.systolic < $1.systolic })
        else { return nil }
        return (highest, lowest)
    }

    static func title(for date: Date, granularity: Granularity, calendar: Calendar = .current) -> String {
        switch granularity {
        case .daily:
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        case .weekly:
            let end = calendar.date(byAdding: .day, value: 6, to: date) ?? date
            return "\(date.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        case .monthly:
            return date.formatted(.dateTime.month(.wide).year())
        }
    }
}
