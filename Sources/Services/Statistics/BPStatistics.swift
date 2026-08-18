import Foundation

/// Pure functions over readings. No storage, no UI, no side effects — which is
/// what makes the boundary cases straightforward to test.
enum BPStatistics {

    struct Average: Equatable, Sendable {
        let systolic: Int
        let diastolic: Int
        let pulse: Int?
        let count: Int
    }

    struct Variability: Equatable, Sendable {
        let systolicSD: Double
        let diastolicSD: Double
        /// Coefficient of variation, percent. Comparable across different means.
        let systolicCV: Double
    }

    struct Comparison: Equatable, Sendable {
        let first: Average
        let second: Average
        var systolicDelta: Int { second.systolic - first.systolic }
        var diastolicDelta: Int { second.diastolic - first.diastolic }
    }

    // MARK: - Averaging

    static func average(_ readings: [BPReading]) -> Average? {
        guard !readings.isEmpty else { return nil }
        let sys = readings.map(\.systolic).reduce(0, +) / readings.count
        let dia = readings.map(\.diastolic).reduce(0, +) / readings.count
        let pulses = readings.compactMap(\.pulse)
        let pulse = pulses.isEmpty ? nil : pulses.reduce(0, +) / pulses.count
        return Average(systolic: sys, diastolic: dia, pulse: pulse, count: readings.count)
    }

    /// Home averages exclude clinic readings. Mixing them in inflates the
    /// baseline and hides the white-coat gap the user is trying to see.
    static func homeAverage(_ readings: [BPReading], days: Int, now: Date = .now) -> Average? {
        average(within(readings, days: days, now: now).filter { $0.source.isHomeMeasurement })
    }

    static func within(_ readings: [BPReading], days: Int, now: Date = .now) -> [BPReading] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return readings.filter { $0.recordedAt >= cutoff && $0.recordedAt <= now }
    }

    // MARK: - Variability

    static func variability(_ readings: [BPReading]) -> Variability? {
        guard readings.count >= 2 else { return nil }
        let sys = readings.map { Double($0.systolic) }
        let dia = readings.map { Double($0.diastolic) }

        let sysSD = standardDeviation(sys)
        let meanSys = sys.reduce(0, +) / Double(sys.count)
        return Variability(
            systolicSD: sysSD,
            diastolicSD: standardDeviation(dia),
            systolicCV: meanSys > 0 ? (sysSD / meanSys) * 100 : 0
        )
    }

    /// Sample standard deviation, n−1. With n < 2 there is nothing to measure.
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSquares = values.reduce(0) { $0 + pow($1 - mean, 2) }
        return sqrt(sumSquares / Double(values.count - 1))
    }

    // MARK: - Patterns

    static func morningVsEvening(_ readings: [BPReading]) -> Comparison? {
        let morning = readings.filter { $0.timeOfDay == .morning }
        let evening = readings.filter { $0.timeOfDay == .evening }
        guard let m = average(morning), let e = average(evening) else { return nil }
        return Comparison(first: m, second: e)
    }

    static func homeVsClinic(_ readings: [BPReading]) -> Comparison? {
        let home = readings.filter { $0.source.isHomeMeasurement }
        let clinic = readings.filter { !$0.source.isHomeMeasurement }
        guard let h = average(home), let c = average(clinic) else { return nil }
        return Comparison(first: h, second: c)
    }

    /// A sustained upward shift over the trailing window, used for the 30-day
    /// drift notification. Deterministic — the AI never triggers this.
    static func hasDrifted(
        _ readings: [BPReading],
        windowDays: Int = 30,
        threshold: Int = 5,
        now: Date = .now
    ) -> Bool {
        let recent = within(readings, days: windowDays, now: now)
        let priorCutoff = now.addingTimeInterval(-Double(windowDays * 2) * 86_400)
        let prior = readings.filter {
            $0.recordedAt >= priorCutoff
                && $0.recordedAt < now.addingTimeInterval(-Double(windowDays) * 86_400)
        }
        guard recent.count >= 5, prior.count >= 5,
              let a = average(prior), let b = average(recent) else { return false }
        return (b.systolic - a.systolic) >= threshold || (b.diastolic - a.diastolic) >= threshold
    }

    // MARK: - Derived metrics

    static func meanArterialPressure(systolic: Int, diastolic: Int) -> Double {
        Double(diastolic) + (Double(systolic - diastolic) / 3.0)
    }

    static func pulsePressure(systolic: Int, diastolic: Int) -> Int {
        systolic - diastolic
    }
}
