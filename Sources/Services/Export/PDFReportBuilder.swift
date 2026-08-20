import Foundation
import PDFKit
import UIKit

/// Renders a doctor-ready PDF.
///
/// Plain text is fine for an email, but a report handed across a desk needs to
/// be printable, paginated and readable at a glance. This draws A4 pages with
/// `UIGraphicsPDFRenderer` — no dependencies, no server round-trip, and nothing
/// leaves the device.
///
/// Everything drawn comes from stored records. There is no interpretation and no
/// generated prose: a clinician needs the numbers and how they were taken, and
/// an app inventing commentary in a document that looks official would be worse
/// than useless.
enum PDFReportBuilder {

    /// A4 at 72dpi, which is what UIKit's PDF context expects.
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 48

    struct Section {
        let title: String
        /// Label/value pairs, rendered as a two-column table.
        let rows: [(String, String)]
        /// Free text drawn below the rows, e.g. a caveat.
        var note: String?
    }

    struct Document {
        let title: String
        let subtitle: String
        let generatedAt: Date
        let sections: [Section]
        /// Printed at the foot of every page.
        let disclaimer: String
    }

    // MARK: - Fonts

    private static let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
    private static let subtitleFont = UIFont.systemFont(ofSize: 11)
    private static let sectionFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    private static let bodyFont = UIFont.systemFont(ofSize: 11)
    /// Monospaced digits keep columns of readings aligned.
    private static let valueFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let footerFont = UIFont.systemFont(ofSize: 8)

    private static let ink = UIColor.black
    private static let muted = UIColor(white: 0.42, alpha: 1)
    private static let rule = UIColor(white: 0.85, alpha: 1)

    // MARK: - Rendering

    static func render(_ document: Document) -> Data {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize)
        )

        return renderer.pdfData { context in
            var cursor = margin
            var pageNumber = 1

            context.beginPage()
            cursor = drawHeader(document, at: cursor)

            for section in document.sections {
                // A heading alone at the foot of a page reads as a mistake, so
                // break before it rather than after.
                let needed = 24 + CGFloat(section.rows.count) * 16
                if cursor + min(needed, 120) > pageSize.height - margin - 30 {
                    drawFooter(document, page: pageNumber)
                    context.beginPage()
                    pageNumber += 1
                    cursor = margin
                }

                cursor = draw(section, at: cursor) { remaining in
                    drawFooter(document, page: pageNumber)
                    context.beginPage()
                    pageNumber += 1
                    return margin
                }
            }

            drawFooter(document, page: pageNumber)
        }
    }

    private static func drawHeader(_ document: Document, at y: CGFloat) -> CGFloat {
        var cursor = y

        document.title.draw(
            at: CGPoint(x: margin, y: cursor),
            withAttributes: [.font: titleFont, .foregroundColor: ink]
        )
        cursor += 28

        document.subtitle.draw(
            at: CGPoint(x: margin, y: cursor),
            withAttributes: [.font: subtitleFont, .foregroundColor: muted]
        )
        cursor += 15

        let stamp = "Prepared \(document.generatedAt.formatted(date: .long, time: .shortened))"
        stamp.draw(
            at: CGPoint(x: margin, y: cursor),
            withAttributes: [.font: subtitleFont, .foregroundColor: muted]
        )
        cursor += 20

        drawRule(at: cursor)
        return cursor + 16
    }

    /// Draws a section, calling `newPage` when it runs out of room.
    private static func draw(
        _ section: Section,
        at y: CGFloat,
        newPage: (CGFloat) -> CGFloat
    ) -> CGFloat {
        var cursor = y

        section.title.uppercased().draw(
            at: CGPoint(x: margin, y: cursor),
            withAttributes: [.font: sectionFont, .foregroundColor: ink]
        )
        cursor += 18

        for (label, value) in section.rows {
            if cursor > pageSize.height - margin - 40 {
                cursor = newPage(cursor)
            }

            label.draw(
                at: CGPoint(x: margin, y: cursor),
                withAttributes: [.font: bodyFont, .foregroundColor: muted]
            )

            // Right-aligned so numbers line up down the page.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: valueFont, .foregroundColor: ink,
            ]
            let width = (value as NSString).size(withAttributes: attributes).width
            value.draw(
                at: CGPoint(x: pageSize.width - margin - width, y: cursor),
                withAttributes: attributes
            )
            cursor += 15
        }

        if let note = section.note {
            cursor += 4
            let box = CGRect(
                x: margin, y: cursor,
                width: pageSize.width - margin * 2, height: 40
            )
            (note as NSString).draw(
                with: box,
                options: .usesLineFragmentOrigin,
                attributes: [.font: footerFont, .foregroundColor: muted],
                context: nil
            )
            cursor += 30
        }

        cursor += 10
        drawRule(at: cursor)
        return cursor + 16
    }

    private static func drawRule(at y: CGFloat) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        rule.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawFooter(_ document: Document, page: Int) {
        let y = pageSize.height - margin + 6

        (document.disclaimer as NSString).draw(
            with: CGRect(x: margin, y: y - 14, width: pageSize.width - margin * 2 - 40, height: 24),
            options: .usesLineFragmentOrigin,
            attributes: [.font: footerFont, .foregroundColor: muted],
            context: nil
        )

        let label = "Page \(page)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: footerFont, .foregroundColor: muted,
        ]
        let width = (label as NSString).size(withAttributes: attributes).width
        label.draw(
            at: CGPoint(x: pageSize.width - margin - width, y: y),
            withAttributes: attributes
        )
    }

    /// Writes the PDF and returns a shareable file URL.
    static func write(_ document: Document, filename: String) throws -> URL {
        let data = render(document)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
