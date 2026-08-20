import Foundation
import PDFKit
import Testing

@testable import BPCoach

@Suite("Grouping and export")
struct GroupingExportTests {

    /// A fixed reference instant: noon on 15 June 2026, UTC.
    ///
    /// Bucketing tests must not use offsets from `Date.now` — an offset of 0.3
    /// days crosses midnight when the suite runs in the morning, which silently
    /// changes which bucket a reading lands in. This suite failed in CI at
    /// 10:41 local for exactly that reason.
    private static let reference: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }()

    /// Readings positioned relative to the reference instant.
    /// `hoursBefore` stays within one calendar day when under 12.
    private func reading(
        _ systolic: Int,
        _ diastolic: Int,
        hoursBefore: Double = 0,
        daysBefore: Double = 0,
        notes: String? = nil,
        profileID: UUID = UUID()
    ) -> BPReading {
        BPReading(
            profileID: profileID,
            systolic: systolic,
            diastolic: diastolic,
            recordedAt: Self.reference
                .addingTimeInterval(-hoursBefore * 3_600)
                .addingTimeInterval(-daysBefore * 86_400),
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
            reading(120, 80, hoursBefore: 2),
            reading(130, 85, hoursBefore: 4),
            reading(140, 90, daysBefore: 5),
        ], by: .daily)

        #expect(buckets.count == 2)
        #expect(buckets.first?.average.count == 2)
    }

    /// The behaviour the original flaky test was accidentally exercising: a
    /// reading on the other side of midnight belongs to the other day.
    @Test("A reading across midnight lands in a separate bucket")
    func midnightBoundary() {
        let buckets = BPGrouping.bucket([
            reading(120, 80, hoursBefore: 2),    // same day, 10:00
            reading(110, 70, hoursBefore: 14),   // previous day, 22:00
        ], by: .daily)

        #expect(buckets.count == 2)
        #expect(buckets.first?.average.count == 1)
        #expect(buckets.first?.lowest.systolic == 120)
    }

    @Test("Buckets carry their own highest and lowest")
    func bucketExtremes() {
        // All three within the same calendar day, regardless of when this runs.
        let buckets = BPGrouping.bucket([
            reading(120, 80, hoursBefore: 1),
            reading(160, 95, hoursBefore: 2),
            reading(110, 70, hoursBefore: 3),
        ], by: .daily)

        #expect(buckets.count == 1)
        #expect(buckets.first?.highest.systolic == 160)
        #expect(buckets.first?.lowest.systolic == 110)
    }

    @Test("Buckets are ordered newest first")
    func bucketOrdering() {
        let buckets = BPGrouping.bucket([
            reading(120, 80, daysBefore: 10),
            reading(130, 85, daysBefore: 1),
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
            [reading(120, 80), reading(130, 85, hoursBefore: 1)],
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

/// PDF report generation.
///
/// The PDF is what a patient hands to a clinician, so it must contain the
/// numbers they recorded and nothing the app invented.
@Suite("PDF report")
@MainActor
struct PDFReportTests {

    private func document(sections: [PDFReportBuilder.Section]) -> PDFReportBuilder.Document {
        .init(
            title: "Health Summary",
            subtitle: "Test · last 90 days",
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            sections: sections,
            disclaimer: "Contains no diagnosis or interpretation."
        )
    }

    @Test("Renders a non-empty PDF")
    func rendersPDF() {
        let data = PDFReportBuilder.render(document(sections: [
            .init(title: "Averages", rows: [("7-day", "128/82 mmHg")]),
        ]))
        #expect(data.count > 1_000)
    }

    /// A PDF always starts with the %PDF- magic bytes. Anything else is not a
    /// file a clinician's software will open.
    @Test("Output is a real PDF file")
    func hasPDFHeader() {
        let data = PDFReportBuilder.render(document(sections: [
            .init(title: "Averages", rows: [("7-day", "128/82")]),
        ]))
        let header = String(decoding: data.prefix(5), as: UTF8.self)
        #expect(header == "%PDF-")
    }

    @Test("An empty report still produces a valid document")
    func emptyStillValid() {
        let data = PDFReportBuilder.render(document(sections: []))
        #expect(data.count > 500)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
    }

    /// Long reports must paginate rather than draw off the bottom of page one.
    @Test("Many rows produce more than one page")
    func paginates() {
        let rows = (0..<200).map { ("Reading \($0)", "120/80 mmHg  Normal") }
        let data = PDFReportBuilder.render(document(sections: [
            .init(title: "Readings", rows: rows),
        ]))

        guard let pdf = PDFDocument(data: data) else {
            Issue.record("Rendered data was not a readable PDF")
            return
        }
        #expect(pdf.pageCount > 1)
    }

    @Test("The disclaimer appears in the rendered text")
    func disclaimerPresent() {
        let data = PDFReportBuilder.render(document(sections: [
            .init(title: "Averages", rows: [("7-day", "128/82")]),
        ]))
        guard let pdf = PDFDocument(data: data),
              let text = pdf.page(at: 0)?.string else {
            Issue.record("Could not read the rendered PDF")
            return
        }
        #expect(text.contains("no diagnosis"))
    }

    @Test("Section content reaches the page")
    func contentPresent() {
        let data = PDFReportBuilder.render(document(sections: [
            .init(title: "Averages", rows: [("7-day average", "128/82 mmHg")]),
        ]))
        guard let pdf = PDFDocument(data: data),
              let text = pdf.page(at: 0)?.string else {
            Issue.record("Could not read the rendered PDF")
            return
        }
        #expect(text.contains("128/82"))
        #expect(text.lowercased().contains("average"))
    }

    @Test("Writing produces a readable file on disk")
    func writesFile() throws {
        let url = try PDFReportBuilder.write(
            document(sections: [.init(title: "A", rows: [("x", "y")])]),
            filename: "test-report.pdf"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "pdf")
        #expect(PDFDocument(url: url) != nil)
    }
}
