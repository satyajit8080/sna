import Foundation
import PDFKit
import SwiftData
import UIKit

/// Something the user attached to a coach message.
///
/// Every attachment is reduced to **text on the device** before anything is
/// sent. Photos and PDFs go through Vision and PDFKit; nothing but the extracted
/// text crosses the network. This is a deliberate limit rather than a stopgap:
/// no image-analysis provider is configured, and sending a photo of a medical
/// report to be interpreted is a bigger privacy decision than reading its text
/// locally.
struct CoachAttachment: Identifiable, Equatable {

    enum Kind: String, Equatable {
        case photo, document, healthData, report

        var label: String {
            switch self {
            case .photo: "Photo"
            case .document: "File"
            case .healthData: "Health data"
            case .report: "Report"
            }
        }

        var symbol: String {
            switch self {
            case .photo: "photo"
            case .document: "doc"
            case .healthData: "heart.text.square"
            case .report: "doc.text.magnifyingglass"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let name: String
    /// What actually gets sent.
    let text: String
    /// Shown to the user so they can see what was read before sending.
    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Turns files and images into attachment text, on the device.
enum AttachmentReader {

    enum ReaderError: LocalizedError {
        case unreadable
        case noText

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file could not be opened."
            case .noText:
                "No text could be read from that. The coach can only work with text, so try a clearer photo."
            }
        }
    }

    /// OCR a photo. Used for labels, reports and prescriptions.
    static func read(image: UIImage, name: String) async throws -> CoachAttachment {
        let recognised = try await TextRecognition.recognise(in: image)
        guard !recognised.isEmpty else { throw ReaderError.noText }
        return CoachAttachment(kind: .photo, name: name, text: recognised.text)
    }

    /// Read a PDF's text layer, falling back to OCR on the first page when the
    /// PDF is a scan with no text in it.
    static func read(fileAt url: URL) async throws -> CoachAttachment {
        guard let data = try? Data(contentsOf: url) else { throw ReaderError.unreadable }
        let name = url.lastPathComponent

        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(data: data) else { throw ReaderError.unreadable }
            let text = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")

            if text.count > 40 {
                return CoachAttachment(kind: .document, name: name, text: text)
            }
            guard let page = document.page(at: 0) else { throw ReaderError.noText }
            let image = page.thumbnail(of: CGSize(width: 2000, height: 2600), for: .mediaBox)
            let recognised = try await TextRecognition.recognise(in: image)
            guard !recognised.isEmpty else { throw ReaderError.noText }
            return CoachAttachment(kind: .document, name: name, text: recognised.text)
        }

        if let image = UIImage(data: data) {
            return try await read(image: image, name: name)
        }

        // Plain text and similar.
        if let text = String(data: data, encoding: .utf8), text.count > 10 {
            return CoachAttachment(kind: .document, name: name, text: text)
        }
        throw ReaderError.unreadable
    }

    /// A stored document, already read at scan time. No re-processing needed.
    static func read(document: MedicalDocument) -> CoachAttachment {
        var lines = ["Document: \(document.title) (\(document.kind.label))"]
        if let date = document.documentDate {
            lines.append("Dated \(date.formatted(date: .abbreviated, time: .omitted))")
        }

        if !document.values.isEmpty {
            lines.append("Values read from it:")
            for value in document.values {
                var line = "  \(value.name): \(value.value) \(value.unit ?? "")"
                if let range = value.referenceRange { line += " (reference \(range))" }
                if let within = value.isWithinRange {
                    line += within ? " — within range" : " — outside range"
                }
                if value.confidence.needsReview { line += " [read uncertainly]" }
                lines.append(line)
            }
        }

        // The full text is included but capped: a long report would otherwise
        // crowd out the user's actual readings in the request.
        if let text = document.recognisedText, !text.isEmpty {
            lines.append("")
            lines.append("Text from the document:")
            lines.append(String(text.prefix(3_000)))
        }

        return CoachAttachment(
            kind: .report,
            name: document.title,
            text: lines.joined(separator: "\n")
        )
    }
}
