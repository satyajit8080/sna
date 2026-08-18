import Foundation
import Testing

@testable import BPCoach

@Suite("BP statistics")
struct StatisticsTests {

    private func reading(
        _ systolic: Int,
        _ diastolic: Int,
        pulse: Int? = nil,
        daysAgo: Double = 0,
        source: BPSource = .manual,
        profileID: UUID = UUID()
    ) -> BPReading {
        BPReading(
            profileID: profileID,
            systolic: systolic,
            diastolic: diastolic,
            pulse: pulse,
            recordedAt: Date.now.addingTimeInterval(-daysAgo * 86_400),
            source: source
        )
    }

    @Test("Average of an empty set is nil, not zero")
    func emptyAverage() {
        #expect(BPStatistics.average([]) == nil)
    }

    @Test("Averages are computed per component")
    func average() {
        let result = BPStatistics.average([
            reading(120, 80), reading(130, 90), reading(140, 100),
        ])
        #expect(result?.systolic == 130)
        #expect(result?.diastolic == 90)
        #expect(result?.count == 3)
    }

    @Test("Clinic readings are excluded from home averages")
    func homeAverageExcludesClinic() {
        let readings = [
            reading(120, 80, source: .manual),
            reading(120, 80, source: .manual),
            reading(180, 110, source: .clinic),
        ]
        let home = BPStatistics.homeAverage(readings, days: 30)
        #expect(home?.systolic == 120)
        #expect(home?.count == 2)
    }

    @Test("Window filtering respects the cutoff")
    func windowing() {
        let readings = [
            reading(120, 80, daysAgo: 1),
            reading(120, 80, daysAgo: 10),
            reading(120, 80, daysAgo: 45),
        ]
        #expect(BPStatistics.within(readings, days: 7).count == 1)
        #expect(BPStatistics.within(readings, days: 30).count == 2)
        #expect(BPStatistics.within(readings, days: 90).count == 3)
    }

    @Test("Standard deviation needs at least two values")
    func standardDeviationFloor() {
        #expect(BPStatistics.standardDeviation([]) == 0)
        #expect(BPStatistics.standardDeviation([120]) == 0)
    }

    @Test("Standard deviation uses the sample formula")
    func standardDeviationValue() {
        // Sample SD of [2, 4, 4, 4, 5, 5, 7, 9] is about 2.138.
        let sd = BPStatistics.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9])
        #expect(abs(sd - 2.138) < 0.01)
    }

    @Test("Identical readings have zero variability")
    func zeroVariability() {
        let readings = (0..<5).map { _ in reading(120, 80) }
        #expect(BPStatistics.variability(readings)?.systolicSD == 0)
    }

    @Test("Mean arterial pressure uses the one-third rule")
    func map() {
        // 120/80 -> 80 + 40/3 = 93.33
        let value = BPStatistics.meanArterialPressure(systolic: 120, diastolic: 80)
        #expect(abs(value - 93.33) < 0.01)
    }

    @Test("Pulse pressure is the difference")
    func pulsePressure() {
        #expect(BPStatistics.pulsePressure(systolic: 140, diastolic: 90) == 50)
    }

    @Test("Rule-of-3 discards the first of three readings")
    func ruleOfThreeDiscardsFirst() {
        let readings = [
            reading(150, 95, daysAgo: 0.003),
            reading(130, 85, daysAgo: 0.002),
            reading(130, 85, daysAgo: 0.001),
        ]
        let average = BPMeasurementSession.average(of: readings)
        // Oldest is 150/95 and is dropped, leaving two at 130/85.
        #expect(average?.systolic == 130)
        #expect(average?.diastolic == 85)
    }

    @Test("Rule-of-3 averages both when only two readings exist")
    func ruleOfThreeWithTwo() {
        let average = BPMeasurementSession.average(of: [
            reading(140, 90, daysAgo: 0.002),
            reading(120, 80, daysAgo: 0.001),
        ])
        #expect(average?.systolic == 130)
    }

    @Test("Drift needs enough data in both windows")
    func driftRequiresData() {
        let sparse = [reading(120, 80, daysAgo: 1), reading(140, 90, daysAgo: 40)]
        #expect(!BPStatistics.hasDrifted(sparse))
    }

    @Test("Sustained upward shift is detected")
    func driftDetected() {
        var readings: [BPReading] = []
        for i in 0..<6 { readings.append(reading(125, 82, daysAgo: Double(i) + 1)) }
        for i in 0..<6 { readings.append(reading(115, 75, daysAgo: Double(i) + 35)) }
        #expect(BPStatistics.hasDrifted(readings))
    }

    @Test("Plausibility rejects inverted and out-of-range values")
    func plausibility() {
        #expect(BPReading.isPlausible(systolic: 120, diastolic: 80))
        #expect(!BPReading.isPlausible(systolic: 80, diastolic: 120))
        #expect(!BPReading.isPlausible(systolic: 400, diastolic: 80))
        #expect(!BPReading.isPlausible(systolic: 120, diastolic: 120))
    }
}
