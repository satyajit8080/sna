import Foundation
import SwiftData

enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case bloodTest, ecg, doctorReport, prescription, labReport, imaging, consultationNote, other

    var label: String {
        switch self {
        case .bloodTest: "Blood test"
        case .ecg: "ECG"
        case .doctorReport: "Doctor report"
        case .prescription: "Prescription"
        case .labReport: "Lab report"
        case .imaging: "Imaging"
        case .consultationNote: "Consultation note"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .bloodTest: "testtube.2"
        case .ecg: "waveform.path.ecg"
        case .doctorReport: "doc.text"
        case .prescription: "pills"
        case .labReport: "flask"
        case .imaging: "photo"
        case .consultationNote: "note.text"
        case .other: "doc"
        }
    }
}

/// One value pulled out of a document.
///
/// `isWithinRange` is optional on purpose: absent means the document gave no
/// reference range, which is different from "within range". Reporting an unknown
/// as normal is exactly the kind of quiet error this app must not make.
@Model
final class ExtractedValue {
    var id: UUID = UUID()
    var name: String = ""
    var value: String = ""
    var unit: String?
    var referenceRange: String?
    var isWithinRange: Bool?
    /// Where in the source this came from, so a user can check it.
    var sourceLine: String?
    var confidenceRaw: String = ExtractionConfidence.medium.rawValue

    init(
        name: String,
        value: String,
        unit: String? = nil,
        referenceRange: String? = nil,
        isWithinRange: Bool? = nil,
        sourceLine: String? = nil,
        confidence: ExtractionConfidence = .medium
    ) {
        self.id = UUID()
        self.name = name
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
        self.isWithinRange = isWithinRange
        self.sourceLine = sourceLine
        self.confidenceRaw = confidence.rawValue
    }

    var confidence: ExtractionConfidence {
        ExtractionConfidence(rawValue: confidenceRaw) ?? .medium
    }
}

/// How much to trust an extracted value. Surfaced in the UI — a low-confidence
/// reading of a lab number should look different from a certain one.
enum ExtractionConfidence: String, Codable, CaseIterable, Sendable {
    case high, medium, low

    var label: String {
        switch self {
        case .high: "Clear"
        case .medium: "Probable"
        case .low: "Unclear — check the original"
        }
    }

    var needsReview: Bool { self != .high }
}

@Model
final class MedicalDocument {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var kindRaw: String = DocumentKind.other.rawValue
    var title: String = ""
    var documentDate: Date?
    var importedAt: Date = Date.now
    var sourceName: String?

    /// Relative path inside the app's Documents directory. Files live on disk
    /// rather than in the store — a scanned PDF in a SwiftData blob would bloat
    /// the database and slow every query that touches it.
    var fileName: String?
    var fileExtension: String?

    /// Raw OCR text, kept so a user can search and verify against extraction.
    var recognisedText: String?
    var aiSummary: String?

    @Relationship(deleteRule: .cascade) var values: [ExtractedValue] = []

    init(
        profileID: UUID,
        kind: DocumentKind,
        title: String,
        documentDate: Date? = nil,
        sourceName: String? = nil
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.kindRaw = kind.rawValue
        self.title = title
        self.documentDate = documentDate
        self.sourceName = sourceName
    }

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .other }

    /// Values that need a human eye before being trusted.
    var valuesNeedingReview: [ExtractedValue] {
        values.filter { $0.confidence.needsReview }
    }

    var fileURL: URL? {
        guard let fileName else { return nil }
        return DocumentStore.directory?.appendingPathComponent(fileName)
    }
}

/// Where document files live on disk.
enum DocumentStore {
    static var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let folder = base.appendingPathComponent("MedicalDocuments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Writes data and returns the stored file name.
    static func save(_ data: Data, extension ext: String) throws -> String {
        guard let directory else {
            throw AppError.saveFailed("Could not open the documents folder.")
        }
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func delete(fileName: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
