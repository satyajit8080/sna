import Foundation
import Testing

@testable import BPCoach

@Suite("Grouping and export")
struct GroupingExportTests {

    private func reading(
        _ systolic: Int,
        _ diastolic: Int,
        daysAgo: Double = 0,
        notes: String? = nil,
        profileID: UUID = UUID()
    ) -> BPReading {
        BPReading(
            profileID: profileID,
            systolic: systolic,
            diastolic: diastolic,
            recordedAt: Date.now.addingTimeInterval(-daysAgo * 86_400),
            notes: notes
        )
    }

    @Test("Empty input produces no buckets, not an empty bucket")
    func emptyGrouping() {
        #expect(BPGrouping.bucket([], by: .daily).isEmpty)
    }

    @Test("Readings on the same day land in one bucket")
    func dailyGrouping() {
        let buckets = BPGrouping.bucket([
            reading(120, 80, daysAgo: 0.1),
            reading(130, 85, daysAgo: 0.2),
            reading(140, 90, daysAgo: 5),
        ], by: .daily)

        #expect(buckets.count == 2)
        #expect(buckets.first?.average.count == 2)
    }

    @Test("Buckets carry their own highest and lowest")
    func bucketExtremes() {
        let buckets = BPGrouping.bucket([
            reading(120, 80, daysAgo: 0.1),
            reading(160, 95, daysAgo: 0.2),
            reading(110, 70, daysAgo: 0.3),
        ], by: .daily)

        #expect(buckets.first?.highest.systolic == 160)
        #expect(buckets.first?.lowest.systolic == 110)
    }

    @Test("Buckets are ordered newest first")
    func bucketOrdering() {
        let buckets = BPGrouping.bucket([
            reading(120, 80, daysAgo: 10),
            reading(130, 85, daysAgo: 1),
        ], by: .daily)

        #expect(buckets.count == 2)
        #expect(buckets[0].start > buckets[1].start)
    }

    @Test("Extremes across a set are found by systolic")
    func extremes() {
        let result = BPGrouping.extremes([
            reading(120, 80), reading(175, 100), reading(95, 60),
        ])
        #expect(result?.highest.systolic == 175)
        #expect(result?.lowest.systolic == 95)
    }

    @Test("CSV export has a header and one row per reading")
    func csvShape() {
        let csv = DataExporter.readingsCSV(
            [reading(120, 80), reading(130, 85)],
            guideline: ACCAHA2017Guideline()
        )
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("Recorded,Systolic,Diastolic"))
    }

    @Test("Notes containing commas are quoted, not left to corrupt the row")
    func csvEscaping() {
        let csv = DataExporter.readingsCSV(
            [reading(120, 80, notes: "after coffee, before walk")],
            guideline: ACCAHA2017Guideline()
        )
        #expect(csv.contains("\"after coffee, before walk\""))
    }

    @Test("Quotes inside notes are doubled")
    func csvQuoteEscaping() {
        let csv = DataExporter.readingsCSV(
            [reading(120, 80, notes: "felt \"off\"")],
            guideline: ACCAHA2017Guideline()
        )
        #expect(csv.contains("\"\"off\"\""))
    }

    @Test("Export carries the guideline that produced each category")
    func csvIncludesGuideline() {
        let csv = DataExporter.readingsCSV([reading(135, 85)], guideline: ESCESH2023Guideline())
        #expect(csv.contains("ESC/ESH 2023"))
        #expect(csv.contains("High normal"))
    }
}
